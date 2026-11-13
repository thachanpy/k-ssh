import Crypto
import XCTest

@testable import SSHCore

/// SFTP integration tests against the local Docker OpenSSH server (docs/integration-testing.md).
/// Skipped unless `SSH_IT=1`.
final class SFTPIntegrationTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SSH_IT"] == "1",
            "Set SSH_IT=1 and start the Docker server (docs/integration-testing.md)")
    }

    /// Connects with the test password and returns the session, an SFTP service, and a fresh remote dir.
    private func connect() async throws -> (session: SSHSessionActor, sftp: SFTPServiceActor, dir: String) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SFTPIT-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let session = SSHSessionActor(
            keychain: InMemoryKeychain(), bookmarks: BookmarkService(),
            keys: KeyRepository(store: JSONStore(url: dir.appendingPathComponent("keys.json"), defaultValue: [])),
            knownHosts: KnownHostsStore(
                store: JSONStore(url: dir.appendingPathComponent("known_hosts.json"), defaultValue: [])),
            prompts: SSHPrompts(
                password: { _ in PasswordPromptResult(secret: "testpass", saveToKeychain: false) },
                passphrase: { _, _ in nil },
                hostKey: { _ in true }))
        try await session.connect(
            profile: HostProfile(name: "it", hostname: "127.0.0.1", port: 2222, username: "test", auth: .password))
        let sftp = try await session.openSFTP()
        let home = try await sftp.homeDirectory()
        let remoteDir = SFTPPath.join(home, "sftp-it-\(UUID().uuidString.prefix(8))")
        try await sftp.mkdir(remoteDir)
        addTeardownBlock {
            try? await sftp.remove(remoteDir, isDirectory: true)
            await sftp.close()
            await session.disconnect()
        }
        return (session, sftp, remoteDir)
    }

    private func localTemp(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(name)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func drain(_ stream: AsyncThrowingStream<TransferProgress, Error>) async throws -> TransferProgress? {
        var last: TransferProgress?
        for try await progress in stream { last = progress }
        return last
    }

    private func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    func testMkdirListRenameAndRecursiveRemove() async throws {
        let c = try await connect()
        let sub = SFTPPath.join(c.dir, "sub")
        try await c.sftp.mkdir(sub)
        let file = localTemp("hello.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)
        _ = try await drain(c.sftp.upload(local: file, remote: SFTPPath.join(sub, "hello.txt")))

        let listing = try await c.sftp.list(c.dir)
        XCTAssertEqual(listing.map(\.name), ["sub"])
        XCTAssertTrue(listing[0].isDirectory)

        try await c.sftp.rename(from: SFTPPath.join(sub, "hello.txt"), to: SFTPPath.join(sub, "renamed.txt"))
        let inner = try await c.sftp.list(sub)
        XCTAssertEqual(inner.map(\.name), ["renamed.txt"])
        XCTAssertEqual(inner[0].size, 5)

        try await c.sftp.remove(sub, isDirectory: true)
        let missing = try await c.sftp.stat(sub)
        XCTAssertNil(missing)
    }

    func testUpload50MBAndDownloadHaveEqualChecksums() async throws {
        let c = try await connect()
        let source = localTemp("big.bin")
        let megabyte = Data((0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        FileManager.default.createFile(atPath: source.path, contents: nil)
        let handle = try FileHandle(forWritingTo: source)
        for _ in 0..<50 { try handle.write(contentsOf: megabyte) }
        try handle.close()

        let remote = SFTPPath.join(c.dir, "big.bin")
        let up = try await drain(c.sftp.upload(local: source, remote: remote))
        XCTAssertEqual(up?.bytesTransferred, 50 << 20)

        let destination = localTemp("big-copy.bin")
        let down = try await drain(c.sftp.download(remote: remote, local: destination))
        XCTAssertEqual(down?.bytesTransferred, 50 << 20)
        XCTAssertEqual(try sha256(source), try sha256(destination))
    }

    func testCancelMidDownloadLeavesNoPartialLocalFile() async throws {
        let c = try await connect()
        let source = localTemp("cancel.bin")
        let chunk = Data(repeating: 7, count: 1 << 20)
        FileManager.default.createFile(atPath: source.path, contents: nil)
        let handle = try FileHandle(forWritingTo: source)
        for _ in 0..<30 { try handle.write(contentsOf: chunk) }
        try handle.close()
        let remote = SFTPPath.join(c.dir, "cancel.bin")
        _ = try await drain(c.sftp.upload(local: source, remote: remote))

        let destination = localTemp("cancel-copy.bin")
        let sftp = c.sftp
        let task = Task {
            for try await progress in sftp.download(remote: remote, local: destination)
            where progress.bytesTransferred > 1 << 20 {
                break  // leaving the loop terminates the stream and cancels the transfer
            }
        }
        try await task.value
        try await Task.sleep(for: .milliseconds(500))
        let partial = destination.deletingLastPathComponent()
            .appendingPathComponent(destination.lastPathComponent + ".part")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }

    func testStatMissingReturnsNil() async throws {
        let c = try await connect()
        let result = try await c.sftp.stat(SFTPPath.join(c.dir, "nope"))
        XCTAssertNil(result)
    }
}
