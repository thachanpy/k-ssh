import XCTest

@testable import SSHCore

/// Tests for `SecretKey`, `InMemoryKeychain`, and the real `KeychainService`.
final class KeychainTests: XCTestCase {
    func testAccountFormat() {
        let id = UUID()
        XCTAssertEqual(SecretKey.hostPassword(id).account, "password:\(id.uuidString)")
        XCTAssertEqual(SecretKey.keyPassphrase(id).account, "passphrase:\(id.uuidString)")
    }

    func testInMemoryKeychainRoundTrip() async throws {
        let keychain = InMemoryKeychain()
        let key = SecretKey.hostPassword(UUID())
        let initial = try await keychain.get(key)
        XCTAssertNil(initial)
        try await keychain.set("a", for: key)
        try await keychain.set("b", for: key)
        let updated = try await keychain.get(key)
        XCTAssertEqual(updated, "b")
        try await keychain.delete(key)
        let afterDelete = try await keychain.get(key)
        XCTAssertNil(afterDelete)
    }

    /// Integration test against the real login Keychain; uses a unique service and cleans up.
    func testKeychainServiceSetGetUpdateDelete() async throws {
        let service = "com.kairo.SSHClient.tests.\(UUID().uuidString)"
        let keychain = KeychainService(service: service)
        let key = SecretKey.hostPassword(UUID())
        do {
            let initial = try await keychain.get(key)
            XCTAssertNil(initial)

            try await keychain.set("first", for: key)
            let first = try await keychain.get(key)
            XCTAssertEqual(first, "first")

            try await keychain.set("second", for: key)
            let second = try await keychain.get(key)
            XCTAssertEqual(second, "second")

            try await keychain.delete(key)
            let afterDelete = try await keychain.get(key)
            XCTAssertNil(afterDelete)

            // Deleting a missing item must not throw.
            try await keychain.delete(key)
        } catch {
            try? await keychain.delete(key)
            throw error
        }
    }
}
