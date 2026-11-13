import Citadel
import Foundation
import NIOCore
import NIOSSH

/// Adapts `HostKeyValidator` to NIOSSH/Citadel's host-key callback.
///
/// The key is converted to OpenSSH text (`String(openSSHPublicKey:)`), then verified asynchronously;
/// the NIO promise is succeeded when trusted and failed (with a `HostKeyError`) otherwise.
/// Concurrency: immutable `Sendable` state; the async work runs in a plain `Task`.
public final class HostKeyValidationDelegate: NIOSSHClientServerAuthenticationDelegate, Sendable {
    private let host: String
    private let port: Int
    private let validator: HostKeyValidator
    private let onFailure: (@Sendable (HostKeyError) -> Void)?

    /// Creates a delegate for one connection target.
    /// - Parameter onFailure: Called with the `HostKeyError` before the promise fails, so callers
    ///   can report the precise cause even if NIO wraps the error.
    public init(
        host: String, port: Int, validator: HostKeyValidator,
        onFailure: (@Sendable (HostKeyError) -> Void)? = nil
    ) {
        self.host = host
        self.port = port
        self.validator = validator
        self.onFailure = onFailure
    }

    public func validateHostKey(
        hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>
    ) {
        let line = String(openSSHPublicKey: hostKey)
        let host = host
        let port = port
        let validator = validator
        let onFailure = onFailure
        Task {
            do {
                try await validator.validate(host: host, port: port, openSSHPublicKey: line)
                validationCompletePromise.succeed(())
            } catch {
                if let hostKeyError = error as? HostKeyError { onFailure?(hostKeyError) }
                validationCompletePromise.fail(error)
            }
        }
    }

    /// This delegate wrapped for use in Citadel's `SSHClientSettings.hostKeyValidator`.
    public var citadelValidator: SSHHostKeyValidator {
        .custom(self)
    }
}
