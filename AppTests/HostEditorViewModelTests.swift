import SSHCore
import XCTest

@testable import SSHClient

@MainActor
final class HostEditorViewModelTests: XCTestCase {
    private func filledModel(env: AppEnvironment) -> HostEditorViewModel {
        let model = HostEditorViewModel(request: .create, env: env)
        model.name = "web"
        model.hostname = "example.com"
        model.username = "me"
        return model
    }

    func testValidationRules() throws {
        let (env, _, _) = try TestSupport.makeEnvironment(testCase: self)
        let model = HostEditorViewModel(request: .create, env: env)
        XCTAssertFalse(model.canSave, "empty form must not be savable")

        model.hostname = "example.com"
        model.username = "me"
        XCTAssertTrue(model.canSave)

        for badPort in ["", "0", "65536", "abc", "-1"] {
            model.portText = badPort
            XCTAssertFalse(model.canSave, "port \(badPort) must be rejected")
        }
        for goodPort in ["1", "22", "65535"] {
            model.portText = goodPort
            XCTAssertTrue(model.canSave, "port \(goodPort) must be accepted")
        }

        model.authChoice = .key
        XCTAssertFalse(model.canSave, "key auth needs a key")
        model.keyID = UUID()
        XCTAssertTrue(model.canSave)
    }

    func testPasswordGoesToKeychainAndNeverToHostsJSON() async throws {
        let (env, directory, keychain) = try TestSupport.makeEnvironment(testCase: self)
        let model = filledModel(env: env)
        model.password = "s3cret-pw-do-not-leak"
        let saved = await model.save()
        XCTAssertTrue(saved)

        let hosts = try await env.hosts.all()
        XCTAssertEqual(hosts.count, 1)
        let stored = try await keychain.get(.hostPassword(hosts[0].id))
        XCTAssertEqual(stored, "s3cret-pw-do-not-leak")

        let json = try String(contentsOf: directory.appendingPathComponent("hosts.json"), encoding: .utf8)
        XCTAssertFalse(json.contains("s3cret-pw-do-not-leak"), "hosts.json must not contain the password")
        XCTAssertFalse(json.lowercased().contains("password\":"), "no password field may be persisted")
    }

    func testEditWithBlankPasswordKeepsSavedPassword() async throws {
        let (env, _, keychain) = try TestSupport.makeEnvironment(testCase: self)
        let first = filledModel(env: env)
        first.password = "keep-me"
        _ = await first.save()
        let host = try await env.hosts.all()[0]

        let editor = HostEditorViewModel(request: .edit(host), env: env)
        await editor.load()
        XCTAssertTrue(editor.hasSavedPassword)
        editor.name = "renamed"
        let saved = await editor.save()
        XCTAssertTrue(saved)

        let after = try await env.hosts.get(host.id)
        XCTAssertEqual(after?.name, "renamed")
        let password = try await keychain.get(.hostPassword(host.id))
        XCTAssertEqual(password, "keep-me")
    }

    func testSwitchingToKeyAuthRemovesSavedPassword() async throws {
        let (env, _, keychain) = try TestSupport.makeEnvironment(testCase: self)
        let first = filledModel(env: env)
        first.password = "old"
        _ = await first.save()
        let host = try await env.hosts.all()[0]

        let editor = HostEditorViewModel(request: .edit(host), env: env)
        editor.authChoice = .key
        editor.keyID = UUID()
        let saved = await editor.save()
        XCTAssertTrue(saved)
        let password = try await keychain.get(.hostPassword(host.id))
        XCTAssertNil(password)
    }

    func testEditPreservesIdentityAndCreationDate() async throws {
        let (env, _, _) = try TestSupport.makeEnvironment(testCase: self)
        let first = filledModel(env: env)
        _ = await first.save()
        let host = try await env.hosts.all()[0]
        let editor = HostEditorViewModel(request: .edit(host), env: env)
        editor.hostname = "other.example.com"
        _ = await editor.save()
        let after = try await env.hosts.all()
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after[0].id, host.id)
        XCTAssertEqual(after[0].createdAt, host.createdAt)
        XCTAssertEqual(after[0].hostname, "other.example.com")
    }

    func testParseTags() {
        XCTAssertEqual(HostEditorViewModel.parseTags("prod, db  Prod,,web"), ["prod", "db", "web"])
        XCTAssertEqual(HostEditorViewModel.parseTags("  "), [])
    }
}
