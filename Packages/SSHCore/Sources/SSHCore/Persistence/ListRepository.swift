import Foundation

/// Generic CRUD repository over a `JSONStore<[Element]>` with a change stream for UI refresh.
///
/// Every mutation is a single atomic `JSONStore.update`, so concurrent callers never lose updates.
/// Concurrency: actor; `changes()` yields the full list after each mutation (latest value wins).
public actor ListRepository<Element: Codable & Sendable & Identifiable> where Element.ID: Sendable {
    private let store: JSONStore<[Element]>
    private var continuations: [UUID: AsyncStream<[Element]>.Continuation] = [:]

    /// Creates a repository backed by `store`.
    public init(store: JSONStore<[Element]>) {
        self.store = store
    }

    /// All elements in stored order.
    public func all() async throws -> [Element] {
        try await store.load()
    }

    /// The element with the given ID, if any.
    public func get(_ id: Element.ID) async throws -> Element? {
        try await store.load().first { $0.id == id }
    }

    /// Inserts a new element or replaces the one with the same ID (keeping its position).
    /// - Returns: The list after the change.
    @discardableResult
    public func upsert(_ element: Element) async throws -> [Element] {
        let list = try await store.update { items -> [Element] in
            if let index = items.firstIndex(where: { $0.id == element.id }) {
                items[index] = element
            } else {
                items.append(element)
            }
            return items
        }
        broadcast(list)
        return list
    }

    /// Removes the element with the given ID.
    /// - Returns: The removed element, or `nil` if it did not exist.
    @discardableResult
    public func delete(id: Element.ID) async throws -> Element? {
        let (removed, list) = try await store.update { items -> (Element?, [Element]) in
            guard let index = items.firstIndex(where: { $0.id == id }) else { return (nil, items) }
            let removed = items.remove(at: index)
            return (removed, items)
        }
        if removed != nil { broadcast(list) }
        return removed
    }

    /// Replaces the whole list.
    public func replaceAll(_ elements: [Element]) async throws {
        try await store.save(elements)
        broadcast(elements)
    }

    /// Stream of the full list: current value first, then after every mutation.
    /// Terminate by cancelling the consuming task.
    public func changes() async -> AsyncStream<[Element]> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: [Element].self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        if let current = try? await store.load() {
            continuation.yield(current)
        }
        return stream
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    private func broadcast(_ list: [Element]) {
        for continuation in continuations.values {
            continuation.yield(list)
        }
    }
}

/// Repository of SSH key references (`keys.json`).
public typealias KeyRepository = ListRepository<SSHKeyRef>
/// Repository of tunnel configs (`tunnels.json`).
public typealias TunnelRepository = ListRepository<TunnelConfig>
/// Repository of snippets (`snippets.json`).
public typealias SnippetRepository = ListRepository<Snippet>
/// Repository of connection history (`history.json`).
public typealias HistoryRepository = ListRepository<HistoryEntry>
