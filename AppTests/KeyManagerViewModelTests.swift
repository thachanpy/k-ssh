import SSHCore
import XCTest

@testable import SSHClient

@MainActor
final class KeyManagerViewModelTests: XCTestCase {
    private func tempKeyURL(_ name: String = "id_test") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeyManagerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent(name)
    }

    func testGenerateWritesPrivateKeyWith0600AndRegistersIt() async throws {
        let (env, _, _) = try TestSupport.makeEnvironment(testCase: self)
        let model = KeyManagerViewModel(env: env)
        let generated = try model.generate(comment: "me@laptop")
        let url = try tempKeyURL()

        let line = await model.writeAndRegister(generated, to: url, label: "laptop")
        XCTAssertEqual(line, generated.publicKeyLine)

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)

        let keys = try await env.keys.all()
        XCTAssertEqual(keys.count, 1)
        XCTAssertEqual(keys[0].label, "laptop")
        XCTAssertEqual(keys[0].fingerprintSHA256, generated.publicKey.fingerprintSHA256)
        XCTAssertFalse(keys[0].hasPassphrase)
        XCTAssertFalse(keys[0].bookmarkData.isEmpty)
    }

    func testImportRegistersKeyAndRejectsDuplicates() async throws {
        let (env, _, _) = try TestSupport.makeEnvironment(testCase: self)
        let model = KeyManagerViewModel(env: env)
        let generated = try model.generate(comment: "")
        let url = try tempKeyURL()
        try Data(generated.privateKeyText.utf8).write(to: url)

        await model.importKey(from: url)
        XCTAssertNil(model.errorMessage)
        let afterFirst = try await env.keys.all()
        XCTAssertEqual(afterFirst.count, 1)
        XCTAssertEqual(afterFirst[0].label, "id_test")

        await model.importKey(from: url)  // same fingerprint again
        XCTAssertNotNil(model.errorMessage)
        let afterSecond = try await env.keys.all()
        XCTAssertEqual(afterSecond.count, 1)
    }

    func testImportingGarbageShowsErrorAndStoresNothing() async throws {
        let (env, _, _) = try TestSupport.makeEnvironment(testCase: self)
        let model = KeyManagerViewModel(env: env)
        let url = try tempKeyURL("not_a_key")
        try Data("hello".utf8).write(to: url)
        await model.importKey(from: url)
        XCTAssertNotNil(model.errorMessage)
        let keys = try await env.keys.all()
        XCTAssertTrue(keys.isEmpty)
    }

    func testDeleteRemovesKeyAndSavedPassphraseButNotTheFile() async throws {
        let (env, _, keychain) = try TestSupport.makeEnvironment(testCase: self)
        let model = KeyManagerViewModel(env: env)
        let generated = try model.generate(comment: "")
        let url = try tempKeyURL()
        _ = await model.writeAndRegister(generated, to: url, label: "k")
        let ref = try await env.keys.all()[0]
        try await keychain.set("pp", for: .keyPassphrase(ref.id))

        await model.delete(ref)

        let keys = try await env.keys.all()
        XCTAssertTrue(keys.isEmpty)
        let passphrase = try await keychain.get(.keyPassphrase(ref.id))
        XCTAssertNil(passphrase)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "the key file must never be deleted")
    }

    func testLoadReportsMissingFileAndUsage() async throws {
        let (env, _, _) = try TestSupport.makeEnvironment(testCase: self)
        let model = KeyManagerViewModel(env: env)
        let generated = try model.generate(comment: "")
        let url = try tempKeyURL()
        _ = await model.writeAndRegister(generated, to: url, label: "k")
        let ref = try await env.keys.all()[0]
        try await env.hosts.upsert(
            HostProfile(name: "uses-key", hostname: "h", username: "u", auth: .privateKey(keyID: ref.id)))

        await model.load()
        XCTAssertEqual(model.rows.first?.status, .ok)
        XCTAssertEqual(model.rows.first?.usedBy, ["uses-key"])

        try FileManager.default.removeItem(at: url)
        await model.load()
        XCTAssertNotEqual(model.rows.first?.status, .ok, "deleted key file must show a stale/missing badge")
    }

    func testRelinkRequiresSameFingerprint() async throws {
        let (env, _, _) = try TestSupport.makeEnvironment(testCase: self)
        let model = KeyManagerViewModel(env: env)
        let original = try model.generate(comment: "")
        let url = try tempKeyURL()
        _ = await model.writeAndRegister(original, to: url, label: "k")
        let ref = try await env.keys.all()[0]

        let other = try model.generate(comment: "")
        let otherURL = try tempKeyURL("other")
        try Data(other.privateKeyText.utf8).write(to: otherURL)
        await model.relink(ref, to: otherURL)
        XCTAssertNotNil(model.errorMessage, "a different key must not be accepted")

        model.errorMessage = nil
        let sameURL = try tempKeyURL("moved")
        try Data(original.privateKeyText.utf8).write(to: sameURL)
        await model.relink(ref, to: sameURL)
        XCTAssertNil(model.errorMessage)
        let relinked = try await env.keys.get(ref.id)
        XCTAssertNotEqual(relinked?.bookmarkData, ref.bookmarkData)
    }
}
