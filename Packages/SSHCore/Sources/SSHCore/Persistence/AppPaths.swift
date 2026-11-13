import Foundation

/// Names of the JSON files the app persists (CLAUDE.md §5).
public enum StoreFile: String, Sendable, CaseIterable {
    case hosts = "hosts.json"
    case keys = "keys.json"
    case tunnels = "tunnels.json"
    case snippets = "snippets.json"
    case history = "history.json"
    case knownHosts = "known_hosts.json"
    case settings = "settings.json"
    case groups = "groups.json"
}

/// Resolves where persistent files live. The base URL is injectable for tests.
public struct AppPaths: Sendable {
    /// Directory containing all store files.
    public let baseURL: URL

    /// Creates paths rooted at `baseURL` (does not touch the disk).
    public init(baseURL: URL) {
        self.baseURL = baseURL
    }

    /// Paths for `Application Support/<bundleID>/`, creating the directory if needed.
    /// - Throws: `PersistenceError.io` if the directory cannot be created.
    public static func applicationSupport(bundleID: String) throws -> AppPaths {
        let fileManager = FileManager.default
        let root = try fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let paths = AppPaths(baseURL: root.appendingPathComponent(bundleID, isDirectory: true))
        try paths.ensureDirectoryExists()
        return paths
    }

    /// Folder for opt-in session transcripts (`logs/<host>/<date>.log`).
    public var logsDirectory: URL {
        baseURL.appendingPathComponent("logs", isDirectory: true)
    }

    /// URL of the given store file inside `baseURL`.
    public func fileURL(_ file: StoreFile) -> URL {
        baseURL.appendingPathComponent(file.rawValue, isDirectory: false)
    }

    /// Creates `baseURL` (and intermediate directories) if missing.
    /// - Throws: `PersistenceError.io` on failure.
    public func ensureDirectoryExists() throws {
        do {
            try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        } catch {
            throw PersistenceError.io(error.localizedDescription)
        }
    }
}
