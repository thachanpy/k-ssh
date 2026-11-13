import Foundation

/// How a recorded session ended (or that it is still running).
public enum HistoryOutcome: String, Sendable, Codable, Hashable {
    /// Connected and still open (no `endedAt` yet).
    case active
    /// Connected and closed normally.
    case completed
    /// Connection or authentication failed.
    case failed
    /// User cancelled before the connection was established.
    case cancelled
}

/// One connection record shown in the "Recent" list.
public struct HistoryEntry: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var hostID: UUID
    /// Host name at the time of connecting, kept so the entry survives host deletion.
    public var hostDisplayName: String
    public var startedAt: Date
    public var endedAt: Date?
    public var outcome: HistoryOutcome

    /// Creates a history entry.
    public init(
        id: UUID = UUID(),
        hostID: UUID,
        hostDisplayName: String,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        outcome: HistoryOutcome = .active
    ) {
        self.id = id
        self.hostID = hostID
        self.hostDisplayName = hostDisplayName
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.outcome = outcome
    }
}
