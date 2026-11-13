import Foundation

/// Outcome of comparing a presented host key with the known-hosts store.
public enum HostKeyDecision: Sendable, Equatable {
    /// Key matches the stored entry.
    case trusted
    /// No entry for this host; the user must decide.
    case unknown(KnownHost)
    /// A different key than the stored one: possible man-in-the-middle.
    case mismatch(expected: KnownHost, actual: KnownHost)
}

/// Host-key verification errors.
public enum HostKeyError: LocalizedError, Sendable, Equatable {
    /// The server key differs from the trusted one. Never bypassable from the connection flow.
    case changed(expected: KnownHost, actual: KnownHost)
    /// The user declined to trust an unknown key.
    case rejectedByUser
    /// The key text could not be parsed.
    case malformedKey
    /// Key algorithm not supported for verification (e.g. certificates).
    case unsupportedKeyType(String)

    public var errorDescription: String? {
        switch self {
        case .changed(let expected, let actual):
            return String(
                localized:
                    "WARNING: the host key for \(expected.hostPattern) has changed (expected \(expected.fingerprintSHA256), got \(actual.fingerprintSHA256)). Connection refused."
            )
        case .rejectedByUser:
            return String(localized: "The host key was not trusted.")
        case .malformedKey:
            return String(localized: "The server sent an invalid host key.")
        case .unsupportedKeyType(let type):
            return String(localized: "Unsupported host key type: \(type)")
        }
    }
}

/// Verifies host keys against a `KnownHostsStore` with a UI approval hook for unknown keys.
///
/// Concurrency: `Sendable` value; `validate` suspends while awaiting `approve`.
public struct HostKeyValidator: Sendable {
    private let store: KnownHostsStore
    private let approve: @Sendable (KnownHost) async -> Bool

    /// Creates a validator.
    /// - Parameters:
    ///   - store: Trusted keys.
    ///   - approve: Called for unknown keys; return `true` to trust and remember. Injected by the session.
    public init(store: KnownHostsStore, approve: @escaping @Sendable (KnownHost) async -> Bool) {
        self.store = store
        self.approve = approve
    }

    /// Compares the presented key with the store without side effects.
    public func evaluate(host: String, port: Int, openSSHPublicKey: String) async throws -> HostKeyDecision {
        let parsed = try ParsedHostKey(openSSHLine: openSSHPublicKey)
        let actual = KnownHost(
            hostPattern: KnownHost.pattern(host: host, port: port),
            keyType: parsed.keyType,
            fingerprintSHA256: parsed.fingerprintSHA256,
            publicKeyBase64: parsed.blob.base64EncodedString())
        guard let expected = try await store.lookup(host: host, port: port) else {
            return .unknown(actual)
        }
        // A different key type for the same host is treated as a mismatch (conservative).
        if expected.publicKeyBase64 == actual.publicKeyBase64 && expected.keyType == actual.keyType {
            return .trusted
        }
        return .mismatch(expected: expected, actual: actual)
    }

    /// Full verification: trusted passes; unknown asks `approve` and stores on approval;
    /// mismatch throws.
    /// - Throws: `HostKeyError`.
    public func validate(host: String, port: Int, openSSHPublicKey: String) async throws {
        switch try await evaluate(host: host, port: port, openSSHPublicKey: openSSHPublicKey) {
        case .trusted:
            return
        case .unknown(let key):
            guard await approve(key) else { throw HostKeyError.rejectedByUser }
            try await store.trust(key)
        case .mismatch(let expected, let actual):
            throw HostKeyError.changed(expected: expected, actual: actual)
        }
    }
}
