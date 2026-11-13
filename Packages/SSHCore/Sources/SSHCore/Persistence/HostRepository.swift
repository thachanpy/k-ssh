import Foundation

/// Repository of user-owned hosts (`hosts.json`).
///
/// Hosts from `~/.ssh/config` (`source == .sshConfig`) are never persisted. Deleting a host also
/// deletes its Keychain password via the injected `KeychainProviding`.
public actor HostRepository {
    private let list: ListRepository<HostProfile>
    private let keychain: any KeychainProviding

    /// Creates a repository.
    /// - Parameters:
    ///   - store: Backing store for `hosts.json`.
    ///   - keychain: Used to remove the host's password on delete.
    public init(store: JSONStore<[HostProfile]>, keychain: any KeychainProviding) {
        self.list = ListRepository(store: store)
        self.keychain = keychain
    }

    /// All saved hosts.
    public func all() async throws -> [HostProfile] {
        try await list.all()
    }

    /// The host with the given ID, if any.
    public func get(_ id: UUID) async throws -> HostProfile? {
        try await list.get(id)
    }

    /// Inserts or updates a host.
    /// - Throws: `PersistenceError.readOnlySource` if `host.source != .local`.
    @discardableResult
    public func upsert(_ host: HostProfile) async throws -> [HostProfile] {
        guard host.source == .local else { throw PersistenceError.readOnlySource }
        return try await list.upsert(host)
    }

    /// Deletes a host and its Keychain password.
    /// - Returns: The removed host, or `nil` if it did not exist.
    /// - Throws: Persistence or `KeychainError`. The host is removed before the secret.
    @discardableResult
    public func delete(id: UUID) async throws -> HostProfile? {
        let removed = try await list.delete(id: id)
        try await keychain.delete(.hostPassword(id))
        return removed
    }

    /// Stream of the host list (see `ListRepository.changes()`).
    public func changes() async -> AsyncStream<[HostProfile]> {
        await list.changes()
    }
}
