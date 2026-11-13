import XCTest

@testable import SSHCore

/// Tests for `PrivateKeyLoader` and `SSHError.map` (no network).
final class PrivateKeyLoaderTests: XCTestCase {
    func testInspectPlainKeys() throws {
        let ed = try PrivateKeyLoader.inspect(KeyFixtures.ed25519)
        XCTAssertEqual(ed, PrivateKeyInfo(kind: .ed25519, isEncrypted: false))
        let rsa = try PrivateKeyLoader.inspect(KeyFixtures.rsa)
        XCTAssertEqual(rsa, PrivateKeyInfo(kind: .rsa, isEncrypted: false))
    }

    func testInspectEncryptedKeys() throws {
        XCTAssertEqual(
            try PrivateKeyLoader.inspect(KeyFixtures.ed25519Encrypted),
            PrivateKeyInfo(kind: .ed25519, isEncrypted: true))
        XCTAssertEqual(
            try PrivateKeyLoader.inspect(KeyFixtures.rsaEncrypted),
            PrivateKeyInfo(kind: .rsa, isEncrypted: true))
    }

    func testInspectToleratesWindowsLineEndings() throws {
        let crlf = KeyFixtures.ed25519.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n"
        XCTAssertEqual(try PrivateKeyLoader.inspect(crlf).kind, .ed25519)
        XCTAssertNoThrow(try PrivateKeyLoader.validate(keyText: crlf, passphrase: nil))
    }

    func testEcdsaIsUnsupported() {
        XCTAssertThrowsError(try PrivateKeyLoader.inspect(KeyFixtures.ecdsa)) {
            XCTAssertEqual($0 as? SSHError, .unsupportedKeyType("ECDSA"))
        }
    }

    func testLegacyPEMIsUnsupported() {
        XCTAssertThrowsError(try PrivateKeyLoader.inspect(KeyFixtures.rsaLegacyPEM)) {
            guard case .unsupportedKeyType = $0 as? SSHError else { return XCTFail("wrong error \($0)") }
        }
    }

    func testGarbageIsInvalidKeyFile() {
        for text in ["", "hello", "-----BEGIN OPENSSH PRIVATE KEY-----\n!!!\n-----END OPENSSH PRIVATE KEY-----"] {
            XCTAssertThrowsError(try PrivateKeyLoader.inspect(text)) {
                guard case .invalidKeyFile = $0 as? SSHError else { return XCTFail("wrong error \($0)") }
            }
        }
    }

    func testPlainKeysBuildAuthMethods() throws {
        XCTAssertEqual(try PrivateKeyLoader.validate(keyText: KeyFixtures.ed25519, passphrase: nil), .ed25519)
        XCTAssertEqual(try PrivateKeyLoader.validate(keyText: KeyFixtures.rsa, passphrase: nil), .rsa)
    }

    func testEncryptedKeysWithCorrectPassphrase() throws {
        XCTAssertEqual(
            try PrivateKeyLoader.validate(keyText: KeyFixtures.ed25519Encrypted, passphrase: KeyFixtures.passphrase),
            .ed25519)
        XCTAssertEqual(
            try PrivateKeyLoader.validate(keyText: KeyFixtures.rsaEncrypted, passphrase: KeyFixtures.passphrase),
            .rsa)
    }

    func testEncryptedKeysWithMissingOrWrongPassphrase() {
        for key in [KeyFixtures.ed25519Encrypted, KeyFixtures.rsaEncrypted] {
            for passphrase: String? in [nil, "", "wrong"] {
                XCTAssertThrowsError(try PrivateKeyLoader.validate(keyText: key, passphrase: passphrase)) {
                    XCTAssertEqual($0 as? SSHError, .invalidPassphrase)
                }
            }
        }
    }

    func testErrorMappingPassesThroughAndMapsKnownTypes() {
        XCTAssertEqual(SSHError.map(SSHError.authenticationFailed), .authenticationFailed)
        XCTAssertEqual(SSHError.map(CancellationError()), .cancelled)
        XCTAssertEqual(SSHError.map(HostKeyError.rejectedByUser), .hostKeyRejected)
        XCTAssertEqual(SSHError.map(BookmarkError.accessDenied), .keyFileUnavailable)
        XCTAssertEqual(SSHError.map(HostKeyError.unsupportedKeyType("x")), .unsupportedKeyType("x"))
    }

    func testEveryErrorHasDescription() {
        let host = KnownHost(hostPattern: "h:22", keyType: .rsa, fingerprintSHA256: "f", publicKeyBase64: "p")
        let errors: [SSHError] = [
            .authenticationFailed, .hostKeyRejected, .hostKeyChanged(expected: host, actual: host),
            .connectionTimedOut, .connectionFailed("x"), .unsupportedKeyType("x"), .invalidKeyFile("x"),
            .keyFileUnavailable, .invalidPassphrase, .credentialsUnavailable, .alreadyConnected,
            .sessionClosed, .cancelled, .notConnected, .shellOpenFailed("x"),
        ]
        for error in errors {
            XCTAssertFalse(error.errorDescription?.isEmpty ?? true, "\(error)")
        }
    }
}
