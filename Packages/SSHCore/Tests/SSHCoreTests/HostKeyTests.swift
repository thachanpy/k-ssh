import XCTest

@testable import SSHCore

/// Tests for fingerprints, `KnownHostsStore`, and `HostKeyValidator`.
final class HostKeyTests: XCTestCase {
    // Generated with ssh-keygen; fingerprints from `ssh-keygen -lf <key>.pub -E sha256`.
    private let ed25519Line =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExlkQ3SxHBK7aPEthc8y1ZDhGjw4dPXoMlXDJ/rj2eZ test"
    private let ed25519Fingerprint = "SHA256:moshLDa7Nmstj9O+G6UrAHIvREliTXBGRT9zsEcgUhk"
    private let otherEd25519Line =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEXN8afaFe+rdGJNx4yH+hYQ05s8ywwuuKYV2YZ35mZS test"
    private let rsaLine =
        "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC87Qd1graIcrLj0g6TyfaMsiWGDsLxaHnS1k06KpNLJsqr9a8b7KI0o/Z8CtKllW5f7ylsMx1AEFY/46wv297A0KHnZrFsmBe9bz0e9iFllW59I7UNfBInCqPJzV2gpf1Y8uLZDl6VZGVocdsEatPsCtVQ6OkvGO3W8VoFfhKMGEB260BpoWbZb6/fuOoSe9ReT78EcGAi51PM7MTK3W+SOsycZXEPAqQIBavBnLl5CiKtW2TLM0tr89V1L/jcQmzuuSHRvcxegYmx1xOdGnPoD+WBwb+5o0KNJ1u6lR+ljoJLJpr2PMWuDZ1D5C2ml5RbEwLPROUjzTBK2BZLUPj7 test"
    private let rsaFingerprint = "SHA256:ZOWZqaIrgP2QfcrZt1GkOKc4wm4u0xVWE3IhIt+nNQk"

    private func makeStore() throws -> KnownHostsStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SSHCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return KnownHostsStore(
            store: JSONStore(url: dir.appendingPathComponent("known_hosts.json"), defaultValue: []))
    }

    func testFingerprintMatchesSSHKeygen() throws {
        let ed = try ParsedHostKey(openSSHLine: ed25519Line)
        XCTAssertEqual(ed.fingerprintSHA256, ed25519Fingerprint)
        XCTAssertEqual(ed.keyType, .ed25519)
        let rsa = try ParsedHostKey(openSSHLine: rsaLine)
        XCTAssertEqual(rsa.fingerprintSHA256, rsaFingerprint)
        XCTAssertEqual(rsa.keyType, .rsa)
    }

    func testParseErrors() {
        XCTAssertThrowsError(try ParsedHostKey(openSSHLine: "garbage")) {
            XCTAssertEqual($0 as? HostKeyError, .malformedKey)
        }
        XCTAssertThrowsError(try ParsedHostKey(openSSHLine: "ssh-ed25519 !!!notbase64")) {
            XCTAssertEqual($0 as? HostKeyError, .malformedKey)
        }
        XCTAssertThrowsError(try ParsedHostKey(openSSHLine: "ssh-dss AAAA")) {
            XCTAssertEqual($0 as? HostKeyError, .unsupportedKeyType("ssh-dss"))
        }
    }

    func testStoreTrustLookupRemoveIsCaseInsensitive() async throws {
        let store = try makeStore()
        let host = KnownHost(
            hostPattern: KnownHost.pattern(host: "Example.COM", port: 22), keyType: .ed25519,
            fingerprintSHA256: "SHA256:x", publicKeyBase64: "AAAA")
        try await store.trust(host)
        try await store.trust(host)  // replaces, no duplicate
        let all = try await store.all()
        XCTAssertEqual(all.count, 1)
        let found = try await store.lookup(host: "example.com", port: 22)
        XCTAssertEqual(found?.hostPattern, "example.com:22")
        let otherPort = try await store.lookup(host: "example.com", port: 2222)
        XCTAssertNil(otherPort)
        try await store.remove("example.com:22")
        let afterRemove = try await store.lookup(host: "example.com", port: 22)
        XCTAssertNil(afterRemove)
    }

    func testUnknownThenApproveThenTrustedWithoutPrompt() async throws {
        let store = try makeStore()
        let counter = Counter()
        let validator = HostKeyValidator(store: store) { _ in
            await counter.increment()
            return true
        }
        let first = try await validator.evaluate(host: "h", port: 22, openSSHPublicKey: ed25519Line)
        guard case .unknown(let key) = first else { return XCTFail("expected unknown") }
        XCTAssertEqual(key.fingerprintSHA256, ed25519Fingerprint)

        try await validator.validate(host: "h", port: 22, openSSHPublicKey: ed25519Line)
        let prompts = await counter.value
        XCTAssertEqual(prompts, 1)

        try await validator.validate(host: "h", port: 22, openSSHPublicKey: ed25519Line)
        let promptsAfter = await counter.value
        XCTAssertEqual(promptsAfter, 1, "trusted host must not prompt again")
        let decision = try await validator.evaluate(host: "h", port: 22, openSSHPublicKey: ed25519Line)
        XCTAssertEqual(decision, .trusted)
    }

    func testRejectedByUserDoesNotStoreKey() async throws {
        let store = try makeStore()
        let validator = HostKeyValidator(store: store) { _ in false }
        do {
            try await validator.validate(host: "h", port: 22, openSSHPublicKey: ed25519Line)
            XCTFail("expected rejection")
        } catch {
            XCTAssertEqual(error as? HostKeyError, .rejectedByUser)
        }
        let stored = try await store.lookup(host: "h", port: 22)
        XCTAssertNil(stored)
    }

    func testMismatchRefusesConnectionAndNeverPrompts() async throws {
        let store = try makeStore()
        let validator = HostKeyValidator(store: store) { _ in true }
        try await validator.validate(host: "h", port: 22, openSSHPublicKey: ed25519Line)

        for changedKey in [otherEd25519Line, rsaLine] {
            let counter = Counter()
            let strict = HostKeyValidator(store: store) { _ in
                await counter.increment()
                return true
            }
            do {
                try await strict.validate(host: "h", port: 22, openSSHPublicKey: changedKey)
                XCTFail("expected mismatch")
            } catch let HostKeyError.changed(expected, actual) {
                XCTAssertEqual(expected.fingerprintSHA256, ed25519Fingerprint)
                XCTAssertNotEqual(actual.fingerprintSHA256, ed25519Fingerprint)
            }
            let prompts = await counter.value
            XCTAssertEqual(prompts, 0)
        }
        let kept = try await store.lookup(host: "h", port: 22)
        XCTAssertEqual(kept?.fingerprintSHA256, ed25519Fingerprint, "stored key must be unchanged")
    }
}

/// Minimal actor counter for `@Sendable` closures in tests.
private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}
