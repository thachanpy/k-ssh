import Foundation

/// Identifies a secret stored in the Keychain.
///
/// The account string follows CLAUDE.md §4: `"<kind>:<UUID>"`.
public enum SecretKey: Sendable, Hashable {
    /// Login password of a host profile.
    case hostPassword(UUID)
    /// Passphrase of an encrypted private key.
    case keyPassphrase(UUID)

    /// Keychain `kSecAttrAccount` value, e.g. `password:<hostID>`.
    public var account: String {
        switch self {
        case .hostPassword(let id): "password:\(id.uuidString)"
        case .keyPassphrase(let id): "passphrase:\(id.uuidString)"
        }
    }
}

/// Abstraction over secret storage so ViewModels and repositories can be tested with fakes.
///
/// Implementations must never log secret values.
public protocol KeychainProviding: Sendable {
    /// Stores `secret`, replacing any existing value for `key`.
    /// - Throws: `KeychainError` on failure.
    func set(_ secret: String, for key: SecretKey) async throws

    /// Returns the stored secret, or `nil` if none exists.
    /// - Throws: `KeychainError` on failure other than "not found".
    func get(_ key: SecretKey) async throws -> String?

    /// Deletes the secret for `key`. Deleting a missing item is not an error.
    /// - Throws: `KeychainError` on failure.
    func delete(_ key: SecretKey) async throws
}

/// Errors from Keychain operations. Messages never contain secret values.
public enum KeychainError: LocalizedError, Sendable, Equatable {
    /// A Security framework call failed with the given status.
    case unexpectedStatus(OSStatus)
    /// Stored data could not be decoded as UTF-8 text.
    case invalidData

    public var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            let text = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
            return String(localized: "Keychain error \(status): \(text)")
        case .invalidData:
            return String(localized: "The stored Keychain item is not valid text.")
        }
    }
}

/// In-memory `KeychainProviding` for tests and previews. Nothing touches disk.
public actor InMemoryKeychain: KeychainProviding {
    private var storage: [SecretKey: String] = [:]

    /// Creates an empty fake keychain.
    public init() {}

    public func set(_ secret: String, for key: SecretKey) async throws {
        storage[key] = secret
    }

    public func get(_ key: SecretKey) async throws -> String? {
        storage[key]
    }

    public func delete(_ key: SecretKey) async throws {
        storage[key] = nil
    }
}
