import XCTest

@testable import SSHCore

/// Tests for `CredentialResolver` and offline behavior of `SSHSessionActor`.
final class CredentialResolverTests: XCTestCase {
    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SSHCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// Writes `keyText` to a temp file, bookmarks it, and registers a `SSHKeyRef`.
    private func makeKeyRepository(keyText: String, hasPassphrase: Bool) async throws -> (KeyRepository, SSHKeyRef) {
        let dir = try makeTempDirectory()
        let file = dir.appendingPathComponent("id_test")
        try Data(keyText.utf8).write(to: file)
        let bookmark = try await BookmarkService().makeBookmark(for: file)
        let ref = SSHKeyRef(
            label: "test", keyType: .ed25519, bookmarkData: bookmark, fingerprintSHA256: "SHA256:x",
            hasPassphrase: hasPassphrase)
        let repo = KeyRepository(store: JSONStore(url: dir.appendingPathComponent("keys.json"), defaultValue: []))
        try await repo.upsert(ref)
        return (repo, ref)
    }

    private func makeResolver(
        keychain: InMemoryKeychain = InMemoryKeychain(), keys: KeyRepository? = nil, prompts: SSHPrompts
    ) throws -> CredentialResolver {
        let repo: KeyRepository
        if let keys {
            repo = keys
        } else {
            let url = try makeTempDirectory().appendingPathComponent("keys.json")
            repo = KeyRepository(store: JSONStore(url: url, defaultValue: []))
        }
        return CredentialResolver(keychain: keychain, bookmarks: BookmarkService(), keys: repo, prompts: prompts)
    }

    func testPasswordFromKeychainSkipsPrompt() async throws {
        let keychain = InMemoryKeychain()
        let host = HostProfile(name: "h", hostname: "x", username: "u")
        try await keychain.set("saved", for: .hostPassword(host.id))
        let resolver = try makeResolver(keychain: keychain, prompts: .denyAll)
        let resolved = try await resolver.resolve(for: host)
        guard case .password(let password) = resolved.credential else { return XCTFail("expected password") }
        XCTAssertEqual(password, "saved")
        XCTAssertNil(resolved.pendingSave)
    }

    func testPasswordPromptWithSaveProducesPendingSave() async throws {
        let host = HostProfile(name: "h", hostname: "x", username: "u")
        let prompts = SSHPrompts(
            password: { _ in PasswordPromptResult(secret: "typed", saveToKeychain: true) },
            passphrase: { _, _ in nil }, hostKey: { _ in false })
        let resolved = try await makeResolver(prompts: prompts).resolve(for: host)
        XCTAssertEqual(resolved.pendingSave?.key, .hostPassword(host.id))
        XCTAssertEqual(resolved.pendingSave?.secret, "typed")
    }

    func testCancelledPasswordPromptThrowsCredentialsUnavailable() async throws {
        let host = HostProfile(name: "h", hostname: "x", username: "u")
        do {
            _ = try await makeResolver(prompts: .denyAll).resolve(for: host)
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? SSHError, .credentialsUnavailable)
        }
    }

    func testUnknownKeyReferenceIsUnavailable() async throws {
        let host = HostProfile(name: "h", hostname: "x", username: "u", auth: .privateKey(keyID: UUID()))
        do {
            _ = try await makeResolver(prompts: .denyAll).resolve(for: host)
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? SSHError, .keyFileUnavailable)
        }
    }

    func testUnencryptedKeyNeedsNoPrompt() async throws {
        let (repo, ref) = try await makeKeyRepository(keyText: KeyFixtures.ed25519, hasPassphrase: false)
        let host = HostProfile(name: "h", hostname: "x", username: "u", auth: .privateKey(keyID: ref.id))
        let resolved = try await makeResolver(keys: repo, prompts: .denyAll).resolve(for: host)
        guard case .privateKey(_, let passphrase) = resolved.credential else { return XCTFail("expected key") }
        XCTAssertNil(passphrase)
    }

    func testEncryptedKeyPromptsRetriesThenSucceeds() async throws {
        let (repo, ref) = try await makeKeyRepository(keyText: KeyFixtures.ed25519Encrypted, hasPassphrase: true)
        let host = HostProfile(name: "h", hostname: "x", username: "u", auth: .privateKey(keyID: ref.id))
        let attempts = AttemptLog()
        let prompts = SSHPrompts(
            password: { _ in nil },
            passphrase: { _, attempt in
                await attempts.record(attempt)
                let secret = attempt == 1 ? "wrong" : KeyFixtures.passphrase
                return PasswordPromptResult(secret: secret, saveToKeychain: true)
            }, hostKey: { _ in false })
        let resolved = try await makeResolver(keys: repo, prompts: prompts).resolve(for: host)
        let seen = await attempts.values
        XCTAssertEqual(seen, [1, 2])
        XCTAssertEqual(resolved.pendingSave?.key, .keyPassphrase(ref.id))
    }

    func testEncryptedKeyGivesUpAfterMaxAttempts() async throws {
        let (repo, ref) = try await makeKeyRepository(keyText: KeyFixtures.ed25519Encrypted, hasPassphrase: true)
        let host = HostProfile(name: "h", hostname: "x", username: "u", auth: .privateKey(keyID: ref.id))
        let prompts = SSHPrompts(
            password: { _ in nil },
            passphrase: { _, _ in PasswordPromptResult(secret: "nope", saveToKeychain: false) },
            hostKey: { _ in false })
        do {
            _ = try await makeResolver(keys: repo, prompts: prompts).resolve(for: host)
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? SSHError, .invalidPassphrase)
        }
    }

    func testSavedPassphraseIsUsedWithoutPrompt() async throws {
        let (repo, ref) = try await makeKeyRepository(keyText: KeyFixtures.rsaEncrypted, hasPassphrase: true)
        let keychain = InMemoryKeychain()
        try await keychain.set(KeyFixtures.passphrase, for: .keyPassphrase(ref.id))
        let host = HostProfile(name: "h", hostname: "x", username: "u", auth: .privateKey(keyID: ref.id))
        let resolved = try await makeResolver(keychain: keychain, keys: repo, prompts: .denyAll).resolve(for: host)
        guard case .privateKey(_, let passphrase) = resolved.credential else { return XCTFail("expected key") }
        XCTAssertEqual(passphrase, KeyFixtures.passphrase)
    }

    // MARK: - Session (offline)

    private func makeSession(prompts: SSHPrompts = .denyAll) throws -> SSHSessionActor {
        let dir = try makeTempDirectory()
        return SSHSessionActor(
            keychain: InMemoryKeychain(), bookmarks: BookmarkService(),
            keys: KeyRepository(store: JSONStore(url: dir.appendingPathComponent("keys.json"), defaultValue: [])),
            knownHosts: KnownHostsStore(store: JSONStore(url: dir.appendingPathComponent("kh.json"), defaultValue: [])),
            prompts: prompts, connectTimeoutSeconds: 3)
    }

    func testSessionFailsWithCredentialsUnavailableAndReportsFailedState() async throws {
        let session = try makeSession()
        var iterator = session.state.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first, .idle)

        let host = HostProfile(name: "h", hostname: "127.0.0.1", port: 1, username: "u")
        do {
            try await session.connect(profile: host)
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? SSHError, .credentialsUnavailable)
        }
        // bufferingNewest(1): the latest state must be `.failed`.
        let latest = await session.currentState
        guard case .failed = latest else { return XCTFail("expected failed, got \(latest)") }
    }

    func testSessionConnectionRefusedMapsToConnectionFailed() async throws {
        let session = try makeSession(
            prompts: SSHPrompts(
                password: { _ in PasswordPromptResult(secret: "x", saveToKeychain: false) },
                passphrase: { _, _ in nil }, hostKey: { _ in false }))
        let host = HostProfile(name: "h", hostname: "127.0.0.1", port: 1, username: "u")
        do {
            try await session.connect(profile: host)
            XCTFail("expected error")
        } catch let error as SSHError {
            switch error {
            case .connectionFailed, .connectionTimedOut: break
            default: XCTFail("unexpected \(error)")
            }
        }
    }

    func testDisconnectFinishesStreamAndSessionCannotBeReused() async throws {
        let session = try makeSession()
        await session.disconnect()
        var seen: [ConnectionState] = []
        for await state in session.state { seen.append(state) }
        XCTAssertEqual(seen.last, .disconnected(reason: nil))
        do {
            try await session.connect(profile: HostProfile(name: "h", hostname: "x", username: "u"))
            XCTFail("expected sessionClosed")
        } catch {
            XCTAssertEqual(error as? SSHError, .sessionClosed)
        }
    }
}

private actor AttemptLog {
    private(set) var values: [Int] = []
    func record(_ attempt: Int) { values.append(attempt) }
}
