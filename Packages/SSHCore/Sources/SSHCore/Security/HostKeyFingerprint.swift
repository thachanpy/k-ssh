import CryptoKit
import Foundation

/// A server host key parsed from OpenSSH public-key text (`"<algorithm> <base64> [comment]"`).
public struct ParsedHostKey: Sendable, Equatable {
    /// SSH algorithm identifier, e.g. `ssh-ed25519`.
    public let algorithm: String
    /// Mapped key family.
    public let keyType: SSHKeyType
    /// SSH wire-format public key blob (the decoded base64 field).
    public let blob: Data

    /// Parses an OpenSSH public key line.
    /// - Throws: `HostKeyError.malformedKey` or `.unsupportedKeyType`.
    public init(openSSHLine: String) throws {
        let parts = openSSHLine.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])), !blob.isEmpty else {
            throw HostKeyError.malformedKey
        }
        let algorithm = String(parts[0])
        switch algorithm {
        case "ssh-ed25519":
            self.keyType = .ed25519
        case "ssh-rsa", "rsa-sha2-256", "rsa-sha2-512":
            self.keyType = .rsa
        case _ where algorithm.hasPrefix("ecdsa-sha2-"):
            self.keyType = .ecdsa
        default:
            throw HostKeyError.unsupportedKeyType(algorithm)
        }
        self.algorithm = algorithm
        self.blob = blob
    }

    /// OpenSSH-style fingerprint: `SHA256:<unpadded base64 of SHA-256(blob)>`.
    public var fingerprintSHA256: String {
        HostKeyFingerprint.sha256(of: blob)
    }
}

/// Fingerprint computation matching `ssh-keygen -lf`.
public enum HostKeyFingerprint {
    /// `SHA256:` followed by the unpadded base64 SHA-256 digest of an SSH public-key blob.
    public static func sha256(of publicKeyBlob: Data) -> String {
        let digest = SHA256.hash(data: publicKeyBlob)
        let base64 = Data(digest).base64EncodedString()
        return "SHA256:" + base64.trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }
}
