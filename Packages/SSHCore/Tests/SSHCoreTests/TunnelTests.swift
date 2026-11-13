import NIOCore
import NIOEmbedded
import NIOPosix
import NIOSSH
import XCTest

@testable import SSHCore

/// Synchronous tests (EmbeddedChannel is single-threaded, so none of these are `async`).
final class GlueHandlerTests: XCTestCase {
    private func makePair() throws -> (EmbeddedChannel, EmbeddedChannel) {
        let a = EmbeddedChannel()
        let b = EmbeddedChannel()
        let (glueA, glueB) = GlueHandler.matchedPair()
        try a.pipeline.syncOperations.addHandler(glueA)
        try b.pipeline.syncOperations.addHandler(glueB)
        return (a, b)
    }

    func testBytesFlowBothWays() throws {
        let (a, b) = try makePair()
        try a.writeInbound(ByteBuffer(string: "ping"))
        XCTAssertEqual(try b.readOutbound(as: ByteBuffer.self).map { String(buffer: $0) }, "ping")
        try b.writeInbound(ByteBuffer(string: "pong"))
        XCTAssertEqual(try a.readOutbound(as: ByteBuffer.self).map { String(buffer: $0) }, "pong")
        _ = try? a.finish(acceptAlreadyClosed: true)
        _ = try? b.finish(acceptAlreadyClosed: true)
    }

    func testClosingOneSideClosesTheOther() throws {
        let (a, b) = try makePair()
        a.pipeline.fireChannelInactive()
        XCTAssertFalse(b.isActive, "the partner must be closed when one side goes inactive")
        _ = try? a.finish(acceptAlreadyClosed: true)
        _ = try? b.finish(acceptAlreadyClosed: true)
    }

    func testErrorClosesBothSides() throws {
        let (a, b) = try makePair()
        a.pipeline.fireErrorCaught(ChannelError.ioOnClosedChannel)
        XCTAssertFalse(a.isActive)
        XCTAssertFalse(b.isActive)
        _ = try? a.finish(acceptAlreadyClosed: true)
        _ = try? b.finish(acceptAlreadyClosed: true)
    }
}

final class SSHDataCodecTests: XCTestCase {
    func testInboundChannelDataBecomesByteBufferAndStderrIsDropped() throws {
        let channel = EmbeddedChannel(handler: SSHDataCodec())
        try channel.writeInbound(SSHChannelData(type: .channel, data: .byteBuffer(ByteBuffer(string: "data"))))
        try channel.writeInbound(SSHChannelData(type: .stdErr, data: .byteBuffer(ByteBuffer(string: "err"))))
        XCTAssertEqual(try channel.readInbound(as: ByteBuffer.self).map { String(buffer: $0) }, "data")
        XCTAssertNil(try channel.readInbound(as: ByteBuffer.self))
        _ = try? channel.finish(acceptAlreadyClosed: true)
    }

    func testOutboundByteBufferBecomesChannelData() throws {
        let channel = EmbeddedChannel(handler: SSHDataCodec())
        try channel.writeOutbound(ByteBuffer(string: "out"))
        let written = try channel.readOutbound(as: SSHChannelData.self)
        guard case .byteBuffer(let buffer)? = written?.data else { return XCTFail("nothing written") }
        XCTAssertEqual(String(buffer: buffer), "out")
        XCTAssertEqual(written?.type, .channel)
        _ = try? channel.finish(acceptAlreadyClosed: true)
    }
}

final class ByteCountingTests: XCTestCase {
    func testCountsBothDirections() throws {
        let session = ForwardSession()
        let channel = EmbeddedChannel(handler: ByteCountingHandler(session: session))
        try channel.writeInbound(ByteBuffer(string: "12345"))  // from the local app -> to the server
        try channel.writeOutbound(ByteBuffer(string: "123"))  // from the server -> to the local app
        let stats = session.snapshot()
        XCTAssertEqual(stats.bytesOut, 5)
        XCTAssertEqual(stats.bytesIn, 3)
        _ = try? channel.finish(acceptAlreadyClosed: true)
    }

    func testTrackAndCloseAll() throws {
        let session = ForwardSession()
        let channel = EmbeddedChannel()
        session.track(channel)
        XCTAssertEqual(session.snapshot().activeConnections, 1)
        XCTAssertEqual(session.snapshot().totalConnections, 1)
        session.closeAll()
        XCTAssertFalse(channel.isActive)
        XCTAssertEqual(session.snapshot().activeConnections, 0)
        XCTAssertEqual(session.snapshot().totalConnections, 1)
        _ = try? channel.finish(acceptAlreadyClosed: true)
    }
}

final class PortForwardErrorTests: XCTestCase {
    func testMessagesMentionThePort() {
        XCTAssertTrue(PortForwardError.portInUse(8080).errorDescription?.contains("8080") == true)
        XCTAssertNotNil(PortForwardError.notConnected.errorDescription)
    }

    func testStartWithoutConnectionThrowsNotConnected() async throws {
        let session = SSHSessionActor(
            keychain: InMemoryKeychain(), bookmarks: BookmarkService(),
            keys: KeyRepository(
                store: JSONStore(
                    url: FileManager.default.temporaryDirectory.appendingPathComponent("k-\(UUID()).json"),
                    defaultValue: [])),
            knownHosts: KnownHostsStore(
                store: JSONStore(
                    url: FileManager.default.temporaryDirectory.appendingPathComponent("h-\(UUID()).json"),
                    defaultValue: [])),
            prompts: SSHPrompts(
                password: { _ in nil }, passphrase: { _, _ in nil }, hostKey: { _ in false }))
        let forward = PortForwardActor(
            session: session,
            config: TunnelConfig(hostID: UUID(), kind: .local, bindPort: 18080, targetHost: "localhost", targetPort: 80))
        do {
            try await forward.start()
            XCTFail("expected notConnected")
        } catch {
            XCTAssertEqual(error as? PortForwardError, .notConnected)
        }
        let running = await forward.isRunning
        XCTAssertFalse(running)
    }
}

/// Integration: forwards a local port to the Docker sshd's own port and reads the SSH banner through it.
/// Skipped unless `SSH_IT=1` (docs/integration-testing.md).
final class PortForwardIntegrationTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SSH_IT"] == "1",
            "Set SSH_IT=1 and start the Docker server (docs/integration-testing.md)")
    }

    private func connectedSession() async throws -> SSHSessionActor {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PFIT-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let session = SSHSessionActor(
            keychain: InMemoryKeychain(), bookmarks: BookmarkService(),
            keys: KeyRepository(store: JSONStore(url: dir.appendingPathComponent("keys.json"), defaultValue: [])),
            knownHosts: KnownHostsStore(
                store: JSONStore(url: dir.appendingPathComponent("known_hosts.json"), defaultValue: [])),
            prompts: SSHPrompts(
                password: { _ in PasswordPromptResult(secret: "testpass", saveToKeychain: false) },
                passphrase: { _, _ in nil }, hostKey: { _ in true }))
        try await session.connect(
            profile: HostProfile(name: "it", hostname: "127.0.0.1", port: 2222, username: "test", auth: .password))
        addTeardownBlock { await session.disconnect() }
        return session
    }

    /// Connects to `127.0.0.1:port` and returns the first bytes the peer sends.
    private func readBanner(port: Int) async throws -> String {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let channel = try await ClientBootstrap(group: group)
            .connect(host: "127.0.0.1", port: port)
            .flatMapThrowing { try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: $0) }
            .get()
        return try await channel.executeThenClose { inbound, _ in
            var iterator = inbound.makeAsyncIterator()
            guard let first = try await iterator.next() else { return "" }
            return String(buffer: first)
        }
    }

    func testLocalForwardReachesRemoteServiceAndStopCloses() async throws {
        let session = try await connectedSession()
        let forward = PortForwardActor(
            session: session,
            config: TunnelConfig(
                hostID: UUID(), kind: .local, bindPort: 18022, targetHost: "127.0.0.1", targetPort: 2222))
        try await forward.start()
        let banner = try await readBanner(port: 18022)
        XCTAssertTrue(banner.hasPrefix("SSH-2.0-"), "got: \(banner)")
        let stats = await forward.currentStats
        XCTAssertEqual(stats.totalConnections, 1)
        XCTAssertGreaterThan(stats.bytesIn, 0)

        await forward.stop()
        let running = await forward.isRunning
        XCTAssertFalse(running)
        do {
            _ = try await readBanner(port: 18022)
            XCTFail("listener should be closed after stop()")
        } catch {
            // expected: connection refused
        }
    }

    func testPortInUseIsReported() async throws {
        let session = try await connectedSession()
        let first = PortForwardActor(
            session: session,
            config: TunnelConfig(hostID: UUID(), kind: .local, bindPort: 18023, targetHost: "127.0.0.1", targetPort: 2222))
        try await first.start()
        let second = PortForwardActor(
            session: session,
            config: TunnelConfig(hostID: UUID(), kind: .local, bindPort: 18023, targetHost: "127.0.0.1", targetPort: 2222))
        do {
            try await second.start()
            XCTFail("expected portInUse")
        } catch {
            XCTAssertEqual(error as? PortForwardError, .portInUse(18023))
        }
        await first.stop()
    }
}
