import Foundation

/// A saved command that can be sent to a terminal pane.
///
/// `command` may contain `{{placeholder}}` tokens (handled in T22).
public struct Snippet: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var title: String
    public var command: String
    public var tags: [String]
    /// Append a trailing newline so the command runs immediately.
    public var appendNewline: Bool

    /// Creates a snippet.
    public init(
        id: UUID = UUID(),
        title: String,
        command: String,
        tags: [String] = [],
        appendNewline: Bool = true
    ) {
        self.id = id
        self.title = title
        self.command = command
        self.tags = tags
        self.appendNewline = appendNewline
    }
}
