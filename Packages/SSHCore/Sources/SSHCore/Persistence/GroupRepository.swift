import Foundation

/// Why a group operation was rejected.
public enum GroupError: LocalizedError, Sendable, Equatable {
    case emptyName
    case duplicateName(String)
    case notFound

    public var errorDescription: String? {
        switch self {
        case .emptyName: String(localized: "A group needs a name.")
        case .duplicateName(let name): String(localized: "A group named “\(name)” already exists.")
        case .notFound: String(localized: "The group no longer exists.")
        }
    }
}

/// Groups (folders) and host-to-group assignments, persisted in `groups.json`.
///
/// Every mutation is one atomic `JSONStore.update`. `changes()` yields the full state after each
/// mutation (latest wins).
public actor GroupRepository {
    private let store: JSONStore<GroupsState>
    private var continuations: [UUID: AsyncStream<GroupsState>.Continuation] = [:]

    /// Creates a repository over `store`.
    public init(store: JSONStore<GroupsState>) {
        self.store = store
    }

    /// The current state.
    public func state() async throws -> GroupsState {
        try await store.load()
    }

    /// Creates a group at the end of the list.
    /// - Throws: `GroupError.emptyName` / `.duplicateName` (names compare case-insensitively).
    @discardableResult
    public func createGroup(name: String) async throws -> HostGroup {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GroupError.emptyName }
        let group = HostGroup(name: trimmed)
        try await mutate { state in
            if state.groups.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                throw GroupError.duplicateName(trimmed)
            }
            state.groups.append(group)
        }
        return group
    }

    /// Renames a group.
    public func renameGroup(id: UUID, to name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GroupError.emptyName }
        try await mutate { state in
            guard let index = state.groups.firstIndex(where: { $0.id == id }) else { throw GroupError.notFound }
            if state.groups.contains(where: {
                $0.id != id && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
            }) {
                throw GroupError.duplicateName(trimmed)
            }
            state.groups[index].name = trimmed
        }
    }

    /// Deletes a group; its hosts become ungrouped (hosts themselves are untouched).
    public func deleteGroup(id: UUID) async throws {
        try await mutate { state in
            state.groups.removeAll { $0.id == id }
            state.assignments = state.assignments.filter { $0.value != id }
        }
    }

    /// Moves hosts into a group, or out of any group when `groupID` is `nil`.
    /// - Throws: `GroupError.notFound` if the group does not exist.
    public func assign(hostIDs: [UUID], to groupID: UUID?) async throws {
        try await mutate { state in
            if let groupID, !state.groups.contains(where: { $0.id == groupID }) {
                throw GroupError.notFound
            }
            for hostID in hostIDs {
                if let groupID {
                    state.assignments[hostID.uuidString] = groupID
                } else {
                    state.assignments[hostID.uuidString] = nil
                }
            }
        }
    }

    /// Moves a group up or down (`offset` -1 / +1) in the display order.
    public func moveGroup(id: UUID, by offset: Int) async throws {
        try await mutate { state in
            guard let index = state.groups.firstIndex(where: { $0.id == id }) else { throw GroupError.notFound }
            let target = index + offset
            guard state.groups.indices.contains(target) else { return }
            state.groups.swapAt(index, target)
        }
    }

    /// Forgets the assignment of a deleted host.
    public func forget(hostID: UUID) async throws {
        try await mutate { state in state.assignments[hostID.uuidString] = nil }
    }

    /// Stream of the full state: current value first, then after every mutation.
    public func changes() async -> AsyncStream<GroupsState> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: GroupsState.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        if let current = try? await store.load() { continuation.yield(current) }
        return stream
    }

    // MARK: - Private

    private func mutate(_ change: @Sendable (inout GroupsState) throws -> Void) async throws {
        let updated = try await store.update { state -> GroupsState in
            try change(&state)
            return state
        }
        for continuation in continuations.values { continuation.yield(updated) }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }
}
