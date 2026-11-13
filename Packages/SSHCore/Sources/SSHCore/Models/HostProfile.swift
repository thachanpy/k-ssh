import Foundation

/// How a host profile authenticates.
///
/// Secrets are never stored here: the password lives in the Keychain under
/// `SecretKey.hostPassword(hostID)`, and private keys are referenced by `SSHKeyRef.id`.
public enum AuthMethod: Sendable, Codable, Hashable {
    /// Password authentication; the secret is in the Keychain.
    case password
    /// Public-key authentication using the `SSHKeyRef` with the given ID.
    case privateKey(keyID: UUID)
}

/// Where a host profile originates from.
public enum HostSource: String, Sendable, Codable, Hashable {
    /// Created by the user; persisted in `hosts.json`.
    case local
    /// Imported in memory from `~/.ssh/config`; read-only, never persisted.
    case sshConfig
}

/// A saved SSH destination.
///
/// Concurrency: pure value type, safe to pass across actor boundaries.
public struct HostProfile: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var hostname: String
    public var port: Int
    public var username: String
    public var auth: AuthMethod
    /// Optional bastion host (another profile's ID) used as a jump host.
    public var jumpHostID: UUID?
    public var tags: [String]
    public var source: HostSource
    public var createdAt: Date
    public var lastConnectedAt: Date?

    /// Creates a host profile.
    /// - Parameter port: SSH port, defaults to 22.
    public init(
        id: UUID = UUID(),
        name: String,
        hostname: String,
        port: Int = 22,
        username: String,
        auth: AuthMethod = .password,
        jumpHostID: UUID? = nil,
        tags: [String] = [],
        source: HostSource = .local,
        createdAt: Date = Date(),
        lastConnectedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.port = port
        self.username = username
        self.auth = auth
        self.jumpHostID = jumpHostID
        self.tags = tags
        self.source = source
        self.createdAt = createdAt
        self.lastConnectedAt = lastConnectedAt
    }
}
