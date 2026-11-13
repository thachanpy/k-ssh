import Foundation

/// Abstraction over an SSH session so ViewModels can be tested with fakes.
public protocol SSHSessionProviding: Sendable {
    /// Connects and authenticates.
    /// - Throws: `SSHError`.
    func connect(profile: HostProfile) async throws

    /// Closes the connection. Safe to call in any state.
    func disconnect() async

    /// Connection state updates: the current value first, then every change.
    /// Single-consumer; finishes when `disconnect()` is called.
    var state: AsyncStream<ConnectionState> { get }
}
