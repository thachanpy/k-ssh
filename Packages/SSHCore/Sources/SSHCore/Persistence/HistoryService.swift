import Foundation

/// Records connection history in `history.json` and keeps it bounded.
public actor HistoryService {
    /// Entries kept on disk; older ones are dropped.
    public static let maxEntries = 200

    private let repository: HistoryRepository

    /// Creates a service over `repository`.
    public init(repository: HistoryRepository) {
        self.repository = repository
    }

    /// Adds an `.active` entry for a connection that was just established.
    /// - Returns: The entry ID, to pass to `finish`.
    public func begin(hostID: UUID, hostName: String, at date: Date = Date()) async throws -> UUID {
        let entry = HistoryEntry(hostID: hostID, hostDisplayName: hostName, startedAt: date)
        var list = try await repository.all()
        list.append(entry)
        if list.count > Self.maxEntries { list.removeFirst(list.count - Self.maxEntries) }
        try await repository.replaceAll(list)
        return entry.id
    }

    /// Records a failed or cancelled attempt in one step.
    public func recordAttempt(
        hostID: UUID, hostName: String, outcome: HistoryOutcome, at date: Date = Date()
    ) async throws {
        let id = try await begin(hostID: hostID, hostName: hostName, at: date)
        try await finish(id, outcome: outcome, at: date)
    }

    /// Marks an entry as ended.
    public func finish(_ id: UUID, outcome: HistoryOutcome, at date: Date = Date()) async throws {
        guard var entry = try await repository.get(id) else { return }
        entry.endedAt = date
        entry.outcome = outcome
        try await repository.upsert(entry)
    }

    /// Most recent entries first.
    public func recent(limit: Int) async throws -> [HistoryEntry] {
        Array(try await repository.all().sorted { $0.startedAt > $1.startedAt }.prefix(limit))
    }

    /// Removes all history.
    public func clear() async throws {
        try await repository.replaceAll([])
    }

    /// Entries left `.active` by a crash or quit become `.completed` (call once at launch).
    public func closeStaleEntries() async throws {
        let list = try await repository.all()
        guard list.contains(where: { $0.outcome == .active }) else { return }
        try await repository.replaceAll(
            list.map { entry in
                var copy = entry
                if copy.outcome == .active {
                    copy.outcome = .completed
                    copy.endedAt = copy.endedAt ?? copy.startedAt
                }
                return copy
            })
    }
}
