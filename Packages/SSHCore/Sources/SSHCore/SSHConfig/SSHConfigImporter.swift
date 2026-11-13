import Crypto
import Foundation

/// Hosts read from `~/.ssh/config`, ready to merge into the sidebar (in memory only).
public struct SSHConfigImport: Sendable, Equatable {
    /// Profiles with `source == .sshConfig` and stable IDs derived from the alias.
    public var hosts: [HostProfile]
    /// Parser warnings plus import problems (unreadable key, unknown jump host…).
    public var warnings: [String]
}

/// Reads the user-granted `~/.ssh` folder and turns `config` into read-only `HostProfile`s.
///
/// Nothing is ever written to `~/.ssh`. Private keys referenced by `IdentityFile` inside the granted
/// folder are registered as `SSHKeyRef`s (a bookmark plus public metadata, like a manual import) so the
/// imported hosts can authenticate. Config hosts themselves are never persisted (CLAUDE.md §5).
///
/// Concurrency: an actor; folder access is scoped with `BookmarkService.withAccess`.
public actor SSHConfigImporter {
    private let bookmarks: BookmarkService
    private let keys: KeyRepository

    /// Creates an importer.
    public init(bookmarks: BookmarkService, keys: KeyRepository) {
        self.bookmarks = bookmarks
        self.keys = keys
    }

    /// Deterministic host ID for a config alias, so selection and saved passwords survive reloads.
    public static func stableID(alias: String) -> UUID {
        let digest = SHA256.hash(data: Data("sshconfig:\(alias)".utf8))
        let bytes = Array(digest.prefix(16))
        return UUID(uuid: bytes.withUnsafeBytes { $0.load(as: uuid_t.self) })
    }

    /// Parses `<folder>/config` (and its `Include`s inside the folder).
    /// - Parameters:
    ///   - folderBookmark: Security-scoped bookmark of the `~/.ssh` folder.
    ///   - localUser: Default user name when the config sets none.
    /// - Throws: `BookmarkError` when the folder bookmark is stale/invalid (the UI should re-prompt).
    public func load(folderBookmark: Data, localUser: String = NSUserName()) async throws -> SSHConfigImport {
        let bookmarks = bookmarks
        let keys = keys
        return try await bookmarks.withAccess(to: folderBookmark) { folder in
            await Self.build(folder: folder, bookmarks: bookmarks, keys: keys, localUser: localUser)
        }
    }

    // MARK: - Private

    private static func build(
        folder: URL, bookmarks: BookmarkService, keys: KeyRepository, localUser: String
    ) async -> SSHConfigImport {
        let configURL = folder.appendingPathComponent("config")
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else {
            return SSHConfigImport(
                hosts: [], warnings: [String(localized: "No readable “config” file in the selected folder.")])
        }
        let parsed = SSHConfigParser.parse(
            text, homeDirectory: folder.deletingLastPathComponent().path, localUser: localUser,
            includeLoader: { readIncludes($0, folder: folder) })
        var warnings = parsed.warnings

        var knownKeys = (try? await keys.all()) ?? []
        var keyIDByPath: [String: UUID] = [:]
        let aliases = Set(parsed.hosts.map(\.alias))
        var hosts: [HostProfile] = []

        for entry in parsed.hosts {
            var auth = AuthMethod.password
            for path in entry.identityFiles where path.hasPrefix(folder.path + "/") {
                if let id = keyIDByPath[path] {
                    auth = .privateKey(keyID: id)
                    break
                }
                if let id = await registerKey(
                    path: path, bookmarks: bookmarks, keys: keys, known: &knownKeys, warnings: &warnings)
                {
                    keyIDByPath[path] = id
                    auth = .privateKey(keyID: id)
                    break
                }
            }

            var jump: UUID?
            if let last = entry.proxyJump.last {
                if aliases.contains(last) {
                    jump = stableID(alias: last)
                } else {
                    warnings.append("ProxyJump “\(last)” for \(entry.alias) is not a host in the config; ignored.")
                }
            }
            hosts.append(
                HostProfile(
                    id: stableID(alias: entry.alias), name: entry.alias, hostname: entry.effectiveHostName,
                    port: entry.port ?? 22, username: entry.user ?? localUser, auth: auth, jumpHostID: jump,
                    tags: [], source: .sshConfig))
        }
        return SSHConfigImport(hosts: hosts, warnings: warnings)
    }

    /// Registers the key file as an `SSHKeyRef` (or finds the existing one with the same fingerprint).
    private static func registerKey(
        path: String, bookmarks: BookmarkService, keys: KeyRepository, known: inout [SSHKeyRef],
        warnings: inout [String]
    ) async -> UUID? {
        let url = URL(fileURLWithPath: path)
        guard let text = try? String(contentsOf: url, encoding: .utf8),
            let info = try? PrivateKeyLoader.publicKeyInfo(of: text)
        else {
            warnings.append("IdentityFile \(url.lastPathComponent) could not be read as a supported key.")
            return nil
        }
        if let existing = known.first(where: { $0.fingerprintSHA256 == info.fingerprintSHA256 }) {
            return existing.id
        }
        do {
            let bookmark = try await bookmarks.makeBookmark(for: url)
            let ref = SSHKeyRef(
                label: url.lastPathComponent, keyType: info.kind == .ed25519 ? .ed25519 : .rsa,
                bookmarkData: bookmark, fingerprintSHA256: info.fingerprintSHA256,
                hasPassphrase: info.isEncrypted)
            try await keys.upsert(ref)
            known.append(ref)
            return ref.id
        } catch {
            warnings.append("IdentityFile \(url.lastPathComponent) could not be registered: \(error.localizedDescription)")
            return nil
        }
    }

    /// `Include` support: patterns relative to the folder (or `~/.ssh/…`), with `*`/`?` in the file name.
    private static func readIncludes(_ pattern: String, folder: URL) -> [String] {
        var path = pattern
        if path.hasPrefix("~/.ssh/") {
            path = folder.path + "/" + String(path.dropFirst("~/.ssh/".count))
        } else if !path.hasPrefix("/") {
            path = folder.path + "/" + path
        }
        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent()
        let filePattern = url.lastPathComponent
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.sorted().filter { SSHConfigParser.globMatch(filePattern, $0) }.compactMap {
            try? String(contentsOf: directory.appendingPathComponent($0), encoding: .utf8)
        }
    }
}
