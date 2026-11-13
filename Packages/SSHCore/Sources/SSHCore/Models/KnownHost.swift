import Foundation

/// A trusted server host key (trust-on-first-use store entry).
///
/// Contains only the server's *public* key; nothing secret.
public struct KnownHost: Sendable, Codable, Hashable, Identifiable {
    /// `"host:port"` pattern; also serves as the identity.
    public var hostPattern: String
    public var keyType: SSHKeyType
    /// Fingerprint in OpenSSH format, `SHA256:<base64>`.
    public var fingerprintSHA256: String
    /// Server public key, base64 encoded.
    public var publicKeyBase64: String
    public var addedAt: Date

    public var id: String { hostPattern }

    /// Creates a known-host entry.
    public init(
        hostPattern: String,
        keyType: SSHKeyType,
        fingerprintSHA256: String,
        publicKeyBase64: String,
        addedAt: Date = Date()
    ) {
        self.hostPattern = hostPattern
        self.keyType = keyType
        self.fingerprintSHA256 = fingerprintSHA256
        self.publicKeyBase64 = publicKeyBase64
        self.addedAt = addedAt
    }
}
