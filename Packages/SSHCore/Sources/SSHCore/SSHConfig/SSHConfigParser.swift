import Foundation

/// One concrete host alias from an `ssh_config` file with all matching options applied.
public struct SSHConfigHost: Sendable, Hashable, Identifiable {
    /// The alias exactly as written after `Host` (never a wildcard pattern).
    public var alias: String
    /// `HostName`, or `nil` when absent (then the alias is the host name).
    public var hostName: String?
    public var user: String?
    public var port: Int?
    /// `IdentityFile` values in order, with `~`, `%h`, `%n`, `%r`, `%u` expanded.
    public var identityFiles: [String]
    /// `ProxyJump` entries (`[user@]host[:port]`), in hop order; empty when absent or `none`.
    public var proxyJump: [String]

    public var id: String { alias }

    public init(
        alias: String, hostName: String? = nil, user: String? = nil, port: Int? = nil,
        identityFiles: [String] = [], proxyJump: [String] = []
    ) {
        self.alias = alias
        self.hostName = hostName
        self.user = user
        self.port = port
        self.identityFiles = identityFiles
        self.proxyJump = proxyJump
    }

    /// The host name to connect to.
    public var effectiveHostName: String { hostName ?? alias }
}

/// Result of parsing: concrete hosts plus human-readable warnings about ignored content.
public struct SSHConfigResult: Sendable, Equatable {
    public var hosts: [SSHConfigHost]
    public var warnings: [String]
}

/// Parser for OpenSSH client configuration (`~/.ssh/config`).
///
/// Supported: `Host` (patterns, `*`, `?`, `!negation`), `HostName`, `User`, `Port`, `IdentityFile`,
/// `ProxyJump`, `Include` (globs, relative to the config directory), comments, `key=value` and
/// `key value`, quoting, case-insensitive keywords. OpenSSH's first-match-wins rule applies per keyword
/// (`IdentityFile` accumulates). Other keywords, and `Match` blocks, are ignored with a warning.
///
/// Concurrency: pure value logic, no I/O; file access for `Include` is injected.
public enum SSHConfigParser {
    /// Resolves an `Include` pattern (already stripped of quotes) to the contents of the matching files.
    public typealias IncludeLoader = @Sendable (_ pattern: String) -> [String]

    private static let maxIncludeDepth = 8

    /// Parses `text`.
    /// - Parameters:
    ///   - text: Config file contents.
    ///   - homeDirectory: Used to expand `~` in `IdentityFile`.
    ///   - localUser: Used for `%u` in `IdentityFile`.
    ///   - includeLoader: Returns the contents of files matching an `Include` pattern. Default: none.
    public static func parse(
        _ text: String,
        homeDirectory: String = NSHomeDirectory(),
        localUser: String = NSUserName(),
        includeLoader: IncludeLoader = { _ in [] }
    ) -> SSHConfigResult {
        var warnings = OrderedSet()
        let lines = flatten(text, loader: includeLoader, depth: 0)
        let blocks = buildBlocks(lines: lines, warnings: &warnings)

        var aliases: [String] = []
        for block in blocks {
            for pattern in block.patterns where isConcrete(pattern) && !aliases.contains(pattern) {
                aliases.append(pattern)
            }
        }
        let hosts = aliases.map {
            resolve(alias: $0, blocks: blocks, home: homeDirectory, localUser: localUser)
        }
        return SSHConfigResult(hosts: hosts, warnings: warnings.values)
    }

    // MARK: - Include flattening

    private static func flatten(_ text: String, loader: IncludeLoader, depth: Int) -> [String] {
        var result: [String] = []
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if let (keyword, value) = splitKeyword(line), keyword == "include" {
                guard depth < maxIncludeDepth else { continue }
                for pattern in tokens(of: value) {
                    for content in loader(pattern) {
                        result.append(contentsOf: flatten(content, loader: loader, depth: depth + 1))
                    }
                }
            } else {
                result.append(line)
            }
        }
        return result
    }

    // MARK: - Blocks

    private struct Block {
        /// `nil` for the global section before any `Host`.
        var patterns: [String]
        var isMatchBlock = false
        var options: [(key: String, value: String)] = []
    }

    private static func buildBlocks(lines: [String], warnings: inout OrderedSet) -> [Block] {
        var blocks = [Block(patterns: ["*"])]  // global options behave like `Host *` at the top
        let supported: Set<String> = ["hostname", "user", "port", "identityfile", "proxyjump"]
        for line in lines {
            guard let (keyword, value) = splitKeyword(line) else { continue }
            switch keyword {
            case "host":
                blocks.append(Block(patterns: tokens(of: value)))
            case "match":
                blocks.append(Block(patterns: [], isMatchBlock: true))
                warnings.insert("Match blocks are not supported and were ignored.")
            default:
                if supported.contains(keyword) {
                    blocks[blocks.count - 1].options.append((keyword, firstToken(of: value) ?? ""))
                } else {
                    warnings.insert("Unsupported option “\(keyword)” was ignored.")
                }
            }
        }
        return blocks
    }

    // MARK: - Resolution

    private static func resolve(alias: String, blocks: [Block], home: String, localUser: String) -> SSHConfigHost {
        var host = SSHConfigHost(alias: alias)
        var identity: [String] = []
        var sawProxy = false
        for block in blocks where matches(alias: alias, patterns: block.patterns, isMatch: block.isMatchBlock) {
            for option in block.options {
                switch option.key {
                case "hostname": if host.hostName == nil { host.hostName = option.value }
                case "user": if host.user == nil { host.user = option.value }
                case "port": if host.port == nil { host.port = Int(option.value) }
                case "identityfile": identity.append(option.value)
                case "proxyjump":
                    if !sawProxy {
                        sawProxy = true
                        host.proxyJump =
                            option.value.lowercased() == "none"
                            ? []
                            : option.value.split(separator: ",").map {
                                String($0).trimmingCharacters(in: .whitespaces)
                            }.filter { !$0.isEmpty }
                    }
                default: break
                }
            }
        }
        let hostName = host.effectiveHostName
        host.identityFiles = identity.map {
            expand($0, alias: alias, hostName: hostName, user: host.user ?? localUser, localUser: localUser, home: home)
        }
        return host
    }

    private static func expand(
        _ value: String, alias: String, hostName: String, user: String, localUser: String, home: String
    ) -> String {
        var result = value
        if result == "~" {
            result = home
        } else if result.hasPrefix("~/") {
            result = home + String(result.dropFirst(1))
        }
        return
            result
            .replacingOccurrences(of: "%%", with: "\u{0}")
            .replacingOccurrences(of: "%h", with: hostName)
            .replacingOccurrences(of: "%n", with: alias)
            .replacingOccurrences(of: "%r", with: user)
            .replacingOccurrences(of: "%u", with: localUser)
            .replacingOccurrences(of: "\u{0}", with: "%")
    }

    // MARK: - Pattern matching

    private static func isConcrete(_ pattern: String) -> Bool {
        !pattern.isEmpty && !pattern.hasPrefix("!") && !pattern.contains("*") && !pattern.contains("?")
    }

    /// OpenSSH: a block applies if some positive pattern matches and no negated pattern matches.
    private static func matches(alias: String, patterns: [String], isMatch: Bool) -> Bool {
        if isMatch { return false }
        var positive = false
        for pattern in patterns {
            if pattern.hasPrefix("!") {
                if globMatch(String(pattern.dropFirst()), alias) { return false }
            } else if globMatch(pattern, alias) {
                positive = true
            }
        }
        return positive
    }

    /// Case-insensitive `*` / `?` matching.
    static func globMatch(_ pattern: String, _ text: String) -> Bool {
        let p = Array(pattern.lowercased())
        let t = Array(text.lowercased())
        var pi = 0
        var ti = 0
        var star = -1
        var mark = 0
        while ti < t.count {
            if pi < p.count, p[pi] == "?" || p[pi] == t[ti] {
                pi += 1
                ti += 1
            } else if pi < p.count, p[pi] == "*" {
                star = pi
                mark = ti
                pi += 1
            } else if star != -1 {
                pi = star + 1
                mark += 1
                ti = mark
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    // MARK: - Line tokenizing

    /// Splits a line into a lowercase keyword and the remaining value text; `nil` for blank/comment lines.
    private static func splitKeyword(_ line: String) -> (String, String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        var keyword = ""
        var index = trimmed.startIndex
        while index < trimmed.endIndex, !trimmed[index].isWhitespace, trimmed[index] != "=" {
            keyword.append(trimmed[index])
            index = trimmed.index(after: index)
        }
        var rest = trimmed[index...].drop { $0.isWhitespace }
        if rest.first == "=" { rest = rest.dropFirst().drop { $0.isWhitespace } }
        guard !keyword.isEmpty else { return nil }
        return (keyword.lowercased(), String(rest))
    }

    /// Splits a value into tokens: whitespace separated, double quotes group, unquoted `#` starts a comment.
    private static func tokens(of value: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false
        var hasToken = false
        for character in value {
            if character == "\"" {
                inQuotes.toggle()
                hasToken = true
            } else if character == "#", !inQuotes, !hasToken || current.isEmpty {
                break
            } else if character.isWhitespace, !inQuotes {
                if hasToken { result.append(current) }
                current = ""
                hasToken = false
            } else {
                current.append(character)
                hasToken = true
            }
        }
        if hasToken { result.append(current) }
        return result
    }

    private static func firstToken(of value: String) -> String? {
        tokens(of: value).first
    }
}

/// Insertion-ordered set of strings for warnings.
private struct OrderedSet {
    private(set) var values: [String] = []

    mutating func insert(_ value: String) {
        if !values.contains(value) { values.append(value) }
    }
}
