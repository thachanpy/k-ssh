import Foundation

/// Parsing and filling of `{{placeholder}}` tokens in snippet commands.
///
/// A placeholder is `{{name}}` where `name` is letters, digits, `_`, `-` or `.` (spaces around it are
/// ignored). The same name used twice is asked for once. Pure value logic, no I/O.
public enum SnippetTemplate {
    /// Unique placeholder names in order of first appearance.
    public static func placeholders(in command: String) -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        for match in matches(in: command) where seen.insert(match.name).inserted {
            names.append(match.name)
        }
        return names
    }

    /// Replaces every placeholder with its value; names without a value are left untouched.
    public static func fill(_ command: String, values: [String: String]) -> String {
        var result = command
        // Replace from the end so earlier ranges stay valid.
        for match in matches(in: command).reversed() {
            guard let value = values[match.name] else { continue }
            result.replaceSubrange(match.range, with: value)
        }
        return result
    }

    /// Bytes to send to the terminal for a (filled) snippet.
    /// - Parameter appendNewline: add a carriage return so the shell runs it (terminals send CR for Enter).
    public static func bytes(for command: String, appendNewline: Bool) -> [UInt8] {
        Array((appendNewline ? command + "\r" : command).utf8)
    }

    private struct Match {
        let name: String
        let range: Range<String.Index>
    }

    private static func matches(in text: String) -> [Match] {
        var result: [Match] = []
        var index = text.startIndex
        while let open = text.range(of: "{{", range: index..<text.endIndex) {
            guard let close = text.range(of: "}}", range: open.upperBound..<text.endIndex) else { break }
            let name = text[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            if isValid(name) {
                result.append(Match(name: name, range: open.lowerBound..<close.upperBound))
                index = close.upperBound
            } else {
                index = open.upperBound
            }
        }
        return result
    }

    private static func isValid(_ name: String) -> Bool {
        !name.isEmpty
            && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }
    }
}
