import Foundation

/// Errors raised by the persistence layer.
public enum PersistenceError: LocalizedError, Sendable, Equatable {
    /// A file system operation failed.
    case io(String)
    /// The file was written by a newer app version.
    case unsupportedSchema(found: Int, supported: Int)
    /// Attempted to persist a host that is not user-owned (e.g. imported from `~/.ssh/config`).
    case readOnlySource

    public var errorDescription: String? {
        switch self {
        case .io(let message):
            return String(localized: "Storage error: \(message)")
        case .unsupportedSchema(let found, let supported):
            return String(
                localized: "Data file uses schema version \(found), but this app supports up to \(supported).")
        case .readOnlySource:
            return String(localized: "This host comes from ~/.ssh/config and cannot be saved. Duplicate it first.")
        }
    }
}
