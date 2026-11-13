import Foundation

/// Access to `settings.json`.
public actor SettingsRepository {
    private let store: JSONStore<AppSettings>

    /// Creates a repository backed by `store` (default value `AppSettings()`).
    public init(store: JSONStore<AppSettings>) {
        self.store = store
    }

    /// Current settings.
    public func get() async throws -> AppSettings {
        try await store.load()
    }

    /// Atomically mutates settings and returns the new value.
    @discardableResult
    public func update(_ transform: @Sendable (inout AppSettings) -> Void) async throws -> AppSettings {
        try await store.update { settings -> AppSettings in
            transform(&settings)
            return settings
        }
    }

    /// Stores (or clears, with `nil`) the `~/.ssh` folder bookmark.
    public func setSSHFolderBookmark(_ bookmark: Data?) async throws {
        try await update { $0.sshFolderBookmark = bookmark }
    }
}
