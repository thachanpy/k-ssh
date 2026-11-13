import Foundation

/// Supported key algorithms.
public enum SSHKeyType: String, Sendable, Codable, Hashable {
    case ed25519
    case rsa
    case ecdsa
}

/// Reference to a user-selected private key file.
///
/// Holds only a security-scoped bookmark to the file and public metadata. Key bytes and
/// the passphrase are never stored (passphrase lives in the Keychain as
/// `SecretKey.keyPassphrase(id)`).
public struct SSHKeyRef: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var label: String
    public var keyType: SSHKeyType
    /// Security-scoped bookmark data for the key file.
    public var bookmarkData: Data
    /// Fingerprint in OpenSSH format, e.g. `SHA256:abc…`.
    public var fingerprintSHA256: String
    /// Whether the key is encrypted; the passphrase itself is in the Keychain.
    public var hasPassphrase: Bool
    public var addedAt: Date

    /// Creates a key reference.
    public init(
        id: UUID = UUID(),
        label: String,
        keyType: SSHKeyType,
        bookmarkData: Data,
        fingerprintSHA256: String,
        hasPassphrase: Bool,
        addedAt: Date = Date()
    ) {
        self.id = id
        self.label = label
        self.keyType = keyType
        self.bookmarkData = bookmarkData
        self.fingerprintSHA256 = fingerprintSHA256
        self.hasPassphrase = hasPassphrase
        self.addedAt = addedAt
    }
}
