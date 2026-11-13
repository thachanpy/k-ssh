import Citadel
import Foundation
import NIOCore

/// User-facing errors from establishing an SSH session. Messages never contain secrets.
public enum SSHError: LocalizedError, Sendable, Equatable {
    /// Wrong password/key or the server rejected all offered methods.
    case authenticationFailed
    /// The user declined to trust an unknown host key.
    case hostKeyRejected
    /// The server's host key differs from the trusted one (possible MITM). Never bypassable here.
    case hostKeyChanged(expected: KnownHost, actual: KnownHost)
    /// The connection or handshake did not finish within the timeout.
    case connectionTimedOut
    /// Any other connection failure.
    case connectionFailed(String)
    /// Key algorithm or format not supported (ECDSA, legacy PEM, certificates…).
    case unsupportedKeyType(String)
    /// The key file is malformed.
    case invalidKeyFile(String)
    /// The key reference or its file/bookmark is missing or stale; the user must re-link the key.
    case keyFileUnavailable
    /// Key passphrase missing or wrong.
    case invalidPassphrase
    /// A required password/passphrase was not provided (prompt cancelled).
    case credentialsUnavailable
    /// `connect` was called on a session that is already connected or connecting.
    case alreadyConnected
    /// The session was closed with `disconnect()` and cannot be reused (create a new one).
    case sessionClosed
    /// The task was cancelled.
    case cancelled
    /// An operation needs a connected session.
    case notConnected
    /// The server refused to open the PTY/shell channel.
    case shellOpenFailed(String)

    public var errorDescription: String? {
        switch self {
        case .authenticationFailed:
            return String(localized: "Authentication failed. Check the username and credentials.")
        case .hostKeyRejected:
            return String(localized: "The host key was not trusted.")
        case .hostKeyChanged(let expected, _):
            return String(
                localized:
                    "WARNING: the host key for \(expected.hostPattern) has changed. Connection refused.")
        case .connectionTimedOut:
            return String(localized: "The connection timed out.")
        case .connectionFailed(let message):
            return String(localized: "Connection failed: \(message)")
        case .unsupportedKeyType(let type):
            return String(localized: "Unsupported key type: \(type)")
        case .invalidKeyFile(let reason):
            return String(localized: "The private key file is invalid: \(reason)")
        case .keyFileUnavailable:
            return String(localized: "The private key file is unavailable. Select the key file again.")
        case .invalidPassphrase:
            return String(localized: "The key passphrase is missing or incorrect.")
        case .credentialsUnavailable:
            return String(localized: "No credentials were provided.")
        case .alreadyConnected:
            return String(localized: "The session is already connected.")
        case .sessionClosed:
            return String(localized: "The session was closed. Open a new connection.")
        case .cancelled:
            return String(localized: "The operation was cancelled.")
        case .notConnected:
            return String(localized: "Not connected.")
        case .shellOpenFailed(let reason):
            return String(localized: "Could not open a shell: \(reason)")
        }
    }

    /// Maps any error thrown by Citadel, NIO, or SSHCore services to an `SSHError`.
    public static func map(_ error: Error) -> SSHError {
        switch error {
        case let error as SSHError:
            return error
        case is CancellationError:
            return .cancelled
        case let error as HostKeyError:
            switch error {
            case .rejectedByUser: return .hostKeyRejected
            case .changed(let expected, let actual): return .hostKeyChanged(expected: expected, actual: actual)
            case .unsupportedKeyType(let type): return .unsupportedKeyType(type)
            case .malformedKey: return .connectionFailed(error.localizedDescription)
            }
        case is BookmarkError:
            return .keyFileUnavailable
        case let error as SSHClientError:
            switch error {
            case .allAuthenticationOptionsFailed, .unsupportedPasswordAuthentication,
                .unsupportedPrivateKeyAuthentication, .unsupportedHostBasedAuthentication:
                return .authenticationFailed
            case .channelCreationFailed:
                return .connectionFailed(String(describing: error))
            }
        case is AuthenticationFailed:
            return .authenticationFailed
        case let error as ChannelError:
            if case .connectTimeout = error { return .connectionTimedOut }
            return .connectionFailed(String(describing: error))
        default:
            return .connectionFailed(error.localizedDescription)
        }
    }
}
