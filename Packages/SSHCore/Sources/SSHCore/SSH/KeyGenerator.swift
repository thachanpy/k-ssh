import Citadel
import Crypto
import Foundation

/// A freshly generated key pair, in memory only. The caller writes `privateKeyText` to a
/// user-chosen file and must not keep it afterwards.
public struct GeneratedKey: Sendable {
    /// OpenSSH-format (unencrypted) private key text.
    public let privateKeyText: String
    /// Public key information (fingerprint, `authorized_keys` line without comment).
    public let publicKey: PublicKeyInfo
    public let comment: String

    /// The public key as one `authorized_keys` line including the comment.
    public var publicKeyLine: String {
        comment.isEmpty ? publicKey.openSSHLine : "\(publicKey.openSSHLine) \(comment)"
    }
}

/// Generates SSH keys.
public enum KeyGenerator {
    /// Generates an unencrypted Ed25519 key pair.
    ///
    /// Citadel's serializer occasionally emits padding that its own parser (and strict readers) reject,
    /// so each candidate is re-parsed with `PrivateKeyLoader` and regenerated if it does not round-trip.
    /// - Parameter comment: Stored in the key (e.g. `me@laptop`).
    /// - Throws: `SSHError.invalidKeyFile` if no valid key could be produced (practically never).
    public static func generateEd25519(comment: String) throws -> GeneratedKey {
        for _ in 0..<32 {
            let key = Curve25519.Signing.PrivateKey()
            let text = wrap(key.makeSSHRepresentation(comment: comment))
            guard (try? PrivateKeyLoader.validate(keyText: text, passphrase: nil)) != nil,
                let info = try? PrivateKeyLoader.publicKeyInfo(of: text)
            else { continue }
            return GeneratedKey(privateKeyText: text, publicKey: info, comment: comment)
        }
        throw SSHError.invalidKeyFile(String(localized: "key generation failed"))
    }

    /// Re-wraps the base64 body at 70 columns like `ssh-keygen`.
    private static func wrap(_ openSSHKey: String) -> String {
        let begin = "-----BEGIN OPENSSH PRIVATE KEY-----"
        let end = "-----END OPENSSH PRIVATE KEY-----"
        let body = openSSHKey
            .replacingOccurrences(of: begin, with: "")
            .replacingOccurrences(of: end, with: "")
            .filter { !$0.isWhitespace }
        var lines: [String] = []
        var index = body.startIndex
        while index < body.endIndex {
            let next = body.index(index, offsetBy: 70, limitedBy: body.endIndex) ?? body.endIndex
            lines.append(String(body[index..<next]))
            index = next
        }
        return ([begin] + lines + [end]).joined(separator: "\n") + "\n"
    }
}
