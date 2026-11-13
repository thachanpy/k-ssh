import Citadel
import Crypto
import Foundation

/// Key families this app can authenticate with (Citadel limitation: no OpenSSH-format ECDSA parsing).
public enum PrivateKeyKind: Sendable, Equatable {
    case ed25519
    case rsa
}

/// Result of inspecting an OpenSSH private key without decrypting it.
public struct PrivateKeyInfo: Sendable, Equatable {
    public let kind: PrivateKeyKind
    /// `true` if the key is protected by a passphrase.
    public let isEncrypted: Bool
}

/// Public information about a private key file (no secrets).
public struct PublicKeyInfo: Sendable, Equatable {
    public let kind: PrivateKeyKind
    public let isEncrypted: Bool
    /// `"<algorithm> <base64>"`, the form used in `authorized_keys` (without comment).
    public let openSSHLine: String
    /// OpenSSH-style fingerprint, `SHA256:…`.
    public let fingerprintSHA256: String
}

/// Parses OpenSSH private keys into Citadel authentication methods.
///
/// Pure and network-free. Key text and passphrases are only used within each call; nothing is
/// stored, logged, or persisted.
public enum PrivateKeyLoader {
    private static let beginMarker = "-----BEGIN OPENSSH PRIVATE KEY-----"
    private static let endMarker = "-----END OPENSSH PRIVATE KEY-----"
    private static let legacyMarkers = [
        "-----BEGIN RSA PRIVATE KEY-----", "-----BEGIN EC PRIVATE KEY-----",
        "-----BEGIN DSA PRIVATE KEY-----", "-----BEGIN PRIVATE KEY-----",
        "-----BEGIN ENCRYPTED PRIVATE KEY-----",
    ]

    /// Reads the key header to report its type and whether it is encrypted.
    /// - Throws: `SSHError.unsupportedKeyType` (ECDSA, legacy PEM, others) or `.invalidKeyFile`.
    public static func inspect(_ text: String) throws -> PrivateKeyInfo {
        try parseHeader(text).info
    }

    /// Public half of a private key, read from the (unencrypted) header — no passphrase needed.
    /// - Throws: same as `inspect`.
    public static func publicKeyInfo(of text: String) throws -> PublicKeyInfo {
        let header = try parseHeader(text)
        let blob = Data(header.blob)
        return PublicKeyInfo(
            kind: header.info.kind, isEncrypted: header.info.isEncrypted,
            openSSHLine: "\(header.algorithm) \(blob.base64EncodedString())",
            fingerprintSHA256: HostKeyFingerprint.sha256(of: blob))
    }

    private static func parseHeader(_ text: String) throws -> (info: PrivateKeyInfo, algorithm: String, blob: [UInt8]) {
        let normalized = normalize(text)
        if legacyMarkers.contains(where: { normalized.hasPrefix($0) }) {
            throw SSHError.unsupportedKeyType(
                String(localized: "legacy PEM key (convert with: ssh-keygen -p -m OpenSSH -f <key>)"))
        }
        guard normalized.hasPrefix(beginMarker), normalized.hasSuffix(endMarker) else {
            throw SSHError.invalidKeyFile(String(localized: "not an OpenSSH private key"))
        }
        let body = normalized.dropFirst(beginMarker.count).dropLast(endMarker.count)
            .filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: String(body)) else {
            throw SSHError.invalidKeyFile(String(localized: "invalid base64 data"))
        }

        var reader = ByteReader([UInt8](data))
        let magic = Array("openssh-key-v1".utf8) + [0]
        guard reader.readBytes(magic.count) == magic,
            let cipher = reader.readString(), reader.readString() != nil,  // kdf name
            reader.readString() != nil,  // kdf options
            reader.readUInt32() == 1,
            let publicBlob = reader.readString()
        else {
            throw SSHError.invalidKeyFile(String(localized: "unrecognized key layout"))
        }
        var blobReader = ByteReader(publicBlob)
        guard let typeBytes = blobReader.readString() else {
            throw SSHError.invalidKeyFile(String(localized: "missing key type"))
        }
        let keyType = String(decoding: typeBytes, as: UTF8.self)
        let kind: PrivateKeyKind
        switch keyType {
        case "ssh-ed25519": kind = .ed25519
        case "ssh-rsa": kind = .rsa
        case _ where keyType.hasPrefix("ecdsa-sha2-"):
            throw SSHError.unsupportedKeyType("ECDSA")
        default:
            throw SSHError.unsupportedKeyType(keyType)
        }
        let info = PrivateKeyInfo(kind: kind, isEncrypted: String(decoding: cipher, as: UTF8.self) != "none")
        return (info, keyType, publicBlob)
    }

    /// Parses (and for encrypted keys, decrypts) the key and builds an authentication method.
    /// - Parameters:
    ///   - username: SSH login name.
    ///   - keyText: OpenSSH private key text.
    ///   - passphrase: Required for encrypted keys.
    /// - Throws: `SSHError.invalidPassphrase` for a missing/wrong passphrase, plus `inspect` errors.
    public static func authenticationMethod(
        username: String, keyText: String, passphrase: String?
    ) throws -> SSHAuthenticationMethod {
        let info = try inspect(keyText)
        let text = normalize(keyText)
        var decryptionKey: Data?
        if info.isEncrypted {
            guard let passphrase, !passphrase.isEmpty else { throw SSHError.invalidPassphrase }
            decryptionKey = Data(passphrase.utf8)
        }
        do {
            switch info.kind {
            case .ed25519:
                let key = try Curve25519.Signing.PrivateKey(sshEd25519: text, decryptionKey: decryptionKey)
                return .ed25519(username: username, privateKey: key)
            case .rsa:
                let key = try Insecure.RSA.PrivateKey(sshRsa: text, decryptionKey: decryptionKey)
                return .rsa(username: username, privateKey: key)
            }
        } catch {
            // A wrong passphrase decrypts to garbage and fails Citadel's integrity check.
            throw info.isEncrypted
                ? SSHError.invalidPassphrase
                : SSHError.invalidKeyFile(String(localized: "the key could not be read"))
        }
    }

    /// Checks that the key (with `passphrase`) can be parsed, without keeping any key object.
    /// - Returns: The key kind.
    public static func validate(keyText: String, passphrase: String?) throws -> PrivateKeyKind {
        _ = try authenticationMethod(username: "", keyText: keyText, passphrase: passphrase)
        return try inspect(keyText).kind
    }

    /// Normalizes line endings/whitespace (Citadel only strips `\n`).
    private static func normalize(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

/// Minimal big-endian SSH wire-format reader.
private struct ByteReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func readBytes(_ count: Int) -> [UInt8]? {
        guard count >= 0, offset + count <= bytes.count else { return nil }
        defer { offset += count }
        return Array(bytes[offset..<offset + count])
    }

    mutating func readUInt32() -> Int? {
        guard let raw = readBytes(4) else { return nil }
        return raw.reduce(0) { ($0 << 8) | Int($1) }
    }

    mutating func readString() -> [UInt8]? {
        guard let length = readUInt32() else { return nil }
        return readBytes(length)
    }
}
