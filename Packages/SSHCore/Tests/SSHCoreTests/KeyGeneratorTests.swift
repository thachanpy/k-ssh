import XCTest

@testable import SSHCore

final class KeyGeneratorTests: XCTestCase {
    func testGeneratedKeyRoundTripsThroughLoader() throws {
        for _ in 0..<20 {  // padding quirk is probabilistic: exercise many keys
            let generated = try KeyGenerator.generateEd25519(comment: "me@laptop")
            XCTAssertTrue(generated.privateKeyText.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----\n"))
            XCTAssertTrue(generated.privateKeyText.hasSuffix("-----END OPENSSH PRIVATE KEY-----\n"))
            let info = try PrivateKeyLoader.inspect(generated.privateKeyText)
            XCTAssertEqual(info, PrivateKeyInfo(kind: .ed25519, isEncrypted: false))
            XCTAssertNoThrow(try PrivateKeyLoader.validate(keyText: generated.privateKeyText, passphrase: nil))
        }
    }

    func testPublicKeyInfoFormat() throws {
        let generated = try KeyGenerator.generateEd25519(comment: "me@laptop")
        XCTAssertTrue(generated.publicKey.openSSHLine.hasPrefix("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5"))
        XCTAssertTrue(generated.publicKey.fingerprintSHA256.hasPrefix("SHA256:"))
        XCTAssertFalse(generated.publicKey.fingerprintSHA256.contains("="), "OpenSSH fingerprints are unpadded")
        XCTAssertTrue(generated.publicKeyLine.hasSuffix(" me@laptop"))
        // The public part read back from the private file matches.
        let readBack = try PrivateKeyLoader.publicKeyInfo(of: generated.privateKeyText)
        XCTAssertEqual(readBack, generated.publicKey)
    }

    func testTwoKeysDiffer() throws {
        let first = try KeyGenerator.generateEd25519(comment: "")
        let second = try KeyGenerator.generateEd25519(comment: "")
        XCTAssertNotEqual(first.publicKey.fingerprintSHA256, second.publicKey.fingerprintSHA256)
        XCTAssertEqual(first.publicKeyLine, first.publicKey.openSSHLine, "no trailing space without a comment")
    }

    func testPublicKeyInfoMatchesSSHKeygenForFixtures() throws {
        // Fingerprints produced by `ssh-keygen -lf <fixture>.pub -E sha256`.
        XCTAssertEqual(
            try PrivateKeyLoader.publicKeyInfo(of: KeyFixtures.ed25519).fingerprintSHA256,
            "SHA256:YH5VsWR8p4RB5lfdzdTQf8FdPnOOZX6/XPusucR03Pw")
        XCTAssertEqual(
            try PrivateKeyLoader.publicKeyInfo(of: KeyFixtures.rsa).fingerprintSHA256,
            "SHA256:/PuEIjcE760Ehv0WSH9+rTTfsJavdt/TFwDQpmlATNU")
        // Works for encrypted keys too (the header is not encrypted).
        let encrypted = try PrivateKeyLoader.publicKeyInfo(of: KeyFixtures.ed25519Encrypted)
        XCTAssertTrue(encrypted.isEncrypted)
        XCTAssertEqual(encrypted.fingerprintSHA256, "SHA256:1XP/qKkCkcDVvUXnBA4f8mcB9B/SwTOa+BozjvuFkNc")
    }
}
