import Foundation

/// Lifecycle state of an SSH connection, streamed from `SSHSessionActor` to the UI.
///
/// Not persisted, so intentionally not `Codable`.
public enum ConnectionState: Sendable, Equatable {
    case idle
    case connecting
    /// Waiting for the user to trust an unknown host key (SHA256 fingerprint).
    case awaitingHostKeyApproval(fingerprint: String)
    case connected
    /// Connection ended; `reason` is nil for a user-initiated disconnect.
    case disconnected(reason: String?)
    case failed(message: String)
}
