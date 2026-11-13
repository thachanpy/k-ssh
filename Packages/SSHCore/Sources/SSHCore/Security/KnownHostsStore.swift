import Foundation

extension KnownHost {
    /// Canonical `"host:port"` pattern (host lowercased).
    public static func pattern(host: String, port: Int) -> String {
        "\(host.lowercased()):\(port)"
    }
}

/// Trust-on-first-use store of server host keys, backed by `known_hosts.json`.
///
/// One entry per `"host:port"` pattern. Concurrency: actor over a `JSONStore`.
public actor KnownHostsStore {
    private let store: JSONStore<[KnownHost]>

    /// Creates a store over `store` (default value `[]`).
    public init(store: JSONStore<[KnownHost]>) {
        self.store = store
    }

    /// All trusted hosts.
    public func all() async throws -> [KnownHost] {
        try await store.load()
    }

    /// The trusted key for `host:port`, if any.
    public func lookup(host: String, port: Int) async throws -> KnownHost? {
        let pattern = KnownHost.pattern(host: host, port: port)
        return try await store.load().first { $0.hostPattern == pattern }
    }

    /// Trusts `host`, replacing any existing entry with the same pattern.
    public func trust(_ host: KnownHost) async throws {
        try await store.update { hosts in
            hosts.removeAll { $0.hostPattern == host.hostPattern }
            hosts.append(host)
        }
    }

    /// Removes the entry for `hostPattern` (e.g. after a legitimate server key change).
    public func remove(_ hostPattern: String) async throws {
        try await store.update { hosts in
            hosts.removeAll { $0.hostPattern == hostPattern }
        }
    }
}
