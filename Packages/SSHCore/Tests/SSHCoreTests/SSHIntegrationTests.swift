import XCTest

@testable import SSHCore

/// Integration tests against a local OpenSSH server (see docs/integration-testing.md).
/// Skipped unless `SSH_IT=1`.
final class SSHIntegrationTests: XCTestCase {
    private let host = "127.0.0.1"
    private let port = 2222
    private let user = "test"
    private let password = "testpass"

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SSH_IT"] == "1",
            "Set SSH_IT=1 and start the Docker server (docs/integration-testing.md)")
    }

    // MARK: - Helpers

    private struct Env {
        let keychain = InMemoryKeychain()
        let keys: KeyRepository
        let knownHosts: KnownHostsStore
    }

    private func makeEnv() throws -> Env {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SSHCoreIT-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return Env(
            keys: KeyRepository(store: JSONStore(url: dir.appendingPathComponent("keys.json"), defaultValue: [])),
            knownHosts: KnownHostsStore(
                store: JSONStore(url: dir.appendingPathComponent("known_hosts.json"), defaultValue: [])))
    }

    private func makeSession(_ env: Env, prompts: SSHPrompts) -> SSHSessionActor {
        SSHSessionActor(
            keychain: env.keychain, bookmarks: BookmarkService(), keys: env.keys,
            knownHosts: env.knownHosts, prompts: prompts, connectTimeoutSeconds: 15)
    }

    private func passwordProfile() -> HostProfile {
        HostProfile(name: "it", hostname: host, port: port, username: user, auth: .password)
    }

    /// Registers `keyText` as a key reference (file in a temp dir + bookmark) and returns a profile using it.
    private func keyProfile(_ keyText: String, env: Env) async throws -> HostProfile {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SSHCoreITKey-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("id")
        try Data(keyText.utf8).write(to: file)
        let ref = SSHKeyRef(
            label: "it", keyType: .ed25519, bookmarkData: try await BookmarkService().makeBookmark(for: file),
            fingerprintSHA256: "SHA256:x", hasPassphrase: false)
        try await env.keys.upsert(ref)
        return HostProfile(name: "it", hostname: host, port: port, username: user, auth: .privateKey(keyID: ref.id))
    }

    private func prompts(
        password: String? = nil, passphrase: String? = nil, trustHostKey: Bool = true,
        counter: PromptCounter = PromptCounter(), saveSecrets: Bool = false
    ) -> SSHPrompts {
        SSHPrompts(
            password: { _ in password.map { PasswordPromptResult(secret: $0, saveToKeychain: saveSecrets) } },
            passphrase: { _, _ in passphrase.map { PasswordPromptResult(secret: $0, saveToKeychain: saveSecrets) } },
            hostKey: { _ in
                await counter.increment()
                return trustHostKey
            })
    }

    private func assertConnects(_ session: SSHSessionActor, _ profile: HostProfile) async throws {
        try await session.connect(profile: profile)
        let state = await session.currentState
        XCTAssertEqual(state, .connected)
        await session.disconnect()
    }

    private func assertConnectFails(
        _ session: SSHSessionActor, _ profile: HostProfile, expected: SSHError,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            try await session.connect(profile: profile)
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? SSHError, expected, file: file, line: line)
        }
        await session.disconnect()
    }

    // MARK: - Tests

    func testPasswordAuthSucceeds() async throws {
        let env = try makeEnv()
        try await assertConnects(makeSession(env, prompts: prompts(password: password)), passwordProfile())
    }

    func testWrongPasswordFailsWithAuthenticationFailed() async throws {
        let env = try makeEnv()
        await assertConnectFails(
            makeSession(env, prompts: prompts(password: "definitely-wrong")), passwordProfile(),
            expected: .authenticationFailed)
    }

    func testPasswordIsSavedOnlyAfterSuccess() async throws {
        let env = try makeEnv()
        let profile = passwordProfile()
        await assertConnectFails(
            makeSession(env, prompts: prompts(password: "wrong", saveSecrets: true)), profile,
            expected: .authenticationFailed)
        let afterFailure = try await env.keychain.get(.hostPassword(profile.id))
        XCTAssertNil(afterFailure)

        try await assertConnects(makeSession(env, prompts: prompts(password: password, saveSecrets: true)), profile)
        let afterSuccess = try await env.keychain.get(.hostPassword(profile.id))
        XCTAssertEqual(afterSuccess, password)
    }

    func testEd25519KeyAuth() async throws {
        let env = try makeEnv()
        let profile = try await keyProfile(KeyFixtures.ed25519, env: env)
        try await assertConnects(makeSession(env, prompts: prompts()), profile)
    }

    func testRSAKeyAuth() async throws {
        let env = try makeEnv()
        let profile = try await keyProfile(KeyFixtures.rsa, env: env)
        try await assertConnects(makeSession(env, prompts: prompts()), profile)
    }

    func testEncryptedKeyWithPassphrase() async throws {
        let env = try makeEnv()
        let profile = try await keyProfile(KeyFixtures.ed25519Encrypted, env: env)
        try await assertConnects(
            makeSession(env, prompts: prompts(passphrase: KeyFixtures.passphrase)), profile)
    }

    func testEncryptedKeyWithWrongPassphrase() async throws {
        let env = try makeEnv()
        let profile = try await keyProfile(KeyFixtures.ed25519Encrypted, env: env)
        await assertConnectFails(
            makeSession(env, prompts: prompts(passphrase: "wrong")), profile, expected: .invalidPassphrase)
    }

    func testRejectedHostKeyIsRefusedAndNotStored() async throws {
        let env = try makeEnv()
        await assertConnectFails(
            makeSession(env, prompts: prompts(password: password, trustHostKey: false)), passwordProfile(),
            expected: .hostKeyRejected)
        let stored = try await env.knownHosts.all()
        XCTAssertTrue(stored.isEmpty)
    }

    func testTrustedHostKeyIsNotPromptedAgain() async throws {
        let env = try makeEnv()
        let counter = PromptCounter()
        try await assertConnects(
            makeSession(env, prompts: prompts(password: password, counter: counter)), passwordProfile())
        try await assertConnects(
            makeSession(env, prompts: prompts(password: password, counter: counter)), passwordProfile())
        let prompted = await counter.value
        XCTAssertEqual(prompted, 1)
    }

    func testChangedHostKeyIsRefusedWithoutPrompt() async throws {
        let env = try makeEnv()
        // Pre-trust a different key for this host:port to simulate a changed server key.
        try await env.knownHosts.trust(
            KnownHost(
                hostPattern: KnownHost.pattern(host: host, port: port), keyType: .ed25519,
                fingerprintSHA256: "SHA256:AAAA", publicKeyBase64: "AAAA"))
        let counter = PromptCounter()
        let session = makeSession(env, prompts: prompts(password: password, counter: counter))
        do {
            try await session.connect(profile: passwordProfile())
            XCTFail("expected hostKeyChanged")
        } catch let error as SSHError {
            guard case .hostKeyChanged = error else { return XCTFail("unexpected \(error)") }
        }
        let prompted = await counter.value
        XCTAssertEqual(prompted, 0)
        await session.disconnect()
    }

    // MARK: - Shell (T07)

    private actor Transcript {
        private(set) var text = ""
        func append(_ bytes: [UInt8]) { text += String(decoding: bytes, as: UTF8.self) }
    }

    private func startReading(_ shell: ShellChannel) -> (Transcript, Task<Void, Never>) {
        let transcript = Transcript()
        let task = Task {
            for await chunk in shell.output { await transcript.append(chunk) }
        }
        return (transcript, task)
    }

    private func waitFor(_ marker: String, in transcript: Transcript, timeout: TimeInterval = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await transcript.text.contains(marker) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    private func connectedSession() async throws -> SSHSessionActor {
        let session = makeSession(try makeEnv(), prompts: prompts(password: password))
        try await session.connect(profile: passwordProfile())
        return session
    }

    func testShellRunsCommandAndReportsExitStatus() async throws {
        let session = try await connectedSession()
        let shell = try await session.openShell(cols: 80, rows: 24)
        let (transcript, reader) = startReading(shell)

        await shell.send(Array("echo hello-$((40+2))\n".utf8))
        let sawOutput = await waitFor("hello-42", in: transcript)
        XCTAssertTrue(sawOutput, "expected command output")

        await shell.send(Array("exit 3\n".utf8))
        let exit = await shell.waitForExit()
        XCTAssertEqual(exit, .status(3))
        await reader.value  // output stream must end when the channel closes
        await session.disconnect()
    }

    func testResizeIsVisibleToRemote() async throws {
        let session = try await connectedSession()
        let shell = try await session.openShell(cols: 80, rows: 24)
        let (transcript, reader) = startReading(shell)

        await shell.send(Array("stty size\n".utf8))
        let initial = await waitFor("24 80", in: transcript)
        XCTAssertTrue(initial, "remote should report 24 rows x 80 cols")

        await shell.resize(cols: 132, rows: 50)
        await shell.send(Array("stty size\n".utf8))
        let resized = await waitFor("50 132", in: transcript)
        XCTAssertTrue(resized, "remote should report 50 rows x 132 cols after resize")

        await shell.close()
        await reader.value
        await session.disconnect()
    }

    func testClosingShellEndsOutputAndKeepsConnectionAlive() async throws {
        let session = try await connectedSession()
        let shell = try await session.openShell(cols: 80, rows: 24)
        let (_, reader) = startReading(shell)

        await shell.close()
        let finished = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await reader.value
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        XCTAssertTrue(finished, "output must end after close()")

        let state = await session.currentState
        XCTAssertEqual(state, .connected, "closing a shell must not drop the SSH connection")
        let second = try await session.openShell(cols: 80, rows: 24)  // connection still usable
        await second.close()
        await session.disconnect()
    }

    func testTwoShellsAreIndependent() async throws {
        let session = try await connectedSession()
        let first = try await session.openShell(cols: 80, rows: 24)
        let second = try await session.openShell(cols: 80, rows: 24)
        let (firstText, firstReader) = startReading(first)
        let (secondText, secondReader) = startReading(second)

        await first.send(Array("echo only-first-$((1+1))\n".utf8))
        await second.send(Array("echo only-second-$((2+2))\n".utf8))
        let sawFirst = await waitFor("only-first-2", in: firstText)
        let sawSecond = await waitFor("only-second-4", in: secondText)
        XCTAssertTrue(sawFirst)
        XCTAssertTrue(sawSecond)
        let leakedIntoFirst = await firstText.text.contains("only-second-4")
        let leakedIntoSecond = await secondText.text.contains("only-first-2")
        XCTAssertFalse(leakedIntoFirst)
        XCTAssertFalse(leakedIntoSecond)

        await first.close()
        await second.close()
        await firstReader.value
        await secondReader.value
        await session.disconnect()
    }

    func testOpeningShellWithoutConnectionThrowsNotConnected() async throws {
        let session = makeSession(try makeEnv(), prompts: prompts())
        do {
            _ = try await session.openShell(cols: 80, rows: 24)
            XCTFail("expected notConnected")
        } catch {
            XCTAssertEqual(error as? SSHError, .notConnected)
        }
    }

    func testStateSequenceForSuccessfulConnect() async throws {
        let env = try makeEnv()
        let session = makeSession(env, prompts: prompts(password: password))
        let collector = Task { () -> [ConnectionState] in
            var seen: [ConnectionState] = []
            for await state in session.state { seen.append(state) }
            return seen
        }
        try await session.connect(profile: passwordProfile())
        await session.disconnect()
        let seen = await collector.value
        // The stream uses newest-1 buffering, so intermediate states may be coalesced; only the
        // first and last are guaranteed observable.
        XCTAssertEqual(seen.last, .disconnected(reason: nil))
        XCTAssertFalse(seen.contains { if case .failed = $0 { return true } else { return false } })
    }
}

private actor PromptCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}
