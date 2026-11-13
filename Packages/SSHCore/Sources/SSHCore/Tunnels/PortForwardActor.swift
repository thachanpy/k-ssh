import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// Failures starting or running a tunnel.
public enum PortForwardError: LocalizedError, Sendable, Equatable {
    case portInUse(Int)
    case notConnected
    case alreadyRunning
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .portInUse(let port): String(localized: "Port \(port) is already in use on this Mac.")
        case .notConnected: String(localized: "The session is not connected.")
        case .alreadyRunning: String(localized: "This tunnel is already running.")
        case .failed(let message): String(localized: "Tunnel failed: \(message)")
        }
    }
}

extension SSHSessionActor {
    /// The live connection for forwarding code in this module, or `nil` when not connected.
    func forwardingHandle() -> SSHClientHandle? {
        handle
    }
}

/// One port forward over an existing SSH connection.
///
/// - Local (`-L`): a `ServerBootstrap` listens on `bindHost:bindPort`; each accepted connection opens a
///   `direct-tcpip` channel to `targetHost:targetPort` on the server and the two are piped together.
/// - Remote (`-R`): the server is asked to listen (Citadel's `withRemotePortForward`); each connection it
///   forwards back is connected to `targetHost:targetPort` on this Mac.
///
/// Every channel runs on the SSH connection's event loop, so the piping needs no locking.
public actor PortForwardActor {
    /// Statistics: current value first, then roughly every 0.5 s while running. Single consumer.
    public nonisolated let stats: AsyncStream<PortForwardStats>

    public let config: TunnelConfig
    /// `true` between a successful `start()` and `stop()` (or the end of a remote forward).
    public private(set) var isRunning = false
    /// The port actually bound (the server's choice for remote forwards with port 0).
    public private(set) var boundPort: Int?

    private let continuation: AsyncStream<PortForwardStats>.Continuation
    private let session: SSHSessionActor
    private let counters = ForwardSession()
    private var serverChannel: Channel?
    private var remoteTask: Task<Void, Never>?
    private var ticker: Task<Void, Never>?

    /// Creates a (stopped) tunnel on `session`'s connection.
    public init(session: SSHSessionActor, config: TunnelConfig) {
        self.session = session
        self.config = config
        let (stream, continuation) = AsyncStream.makeStream(
            of: PortForwardStats.self, bufferingPolicy: .bufferingNewest(1))
        self.stats = stream
        self.continuation = continuation
        continuation.yield(.zero)
    }

    deinit {
        continuation.finish()
    }

    /// Current statistics.
    public var currentStats: PortForwardStats { counters.snapshot() }

    /// Starts listening.
    /// - Throws: `PortForwardError` (`.portInUse`, `.notConnected`, `.alreadyRunning`, `.failed`).
    public func start() async throws {
        guard !isRunning else { throw PortForwardError.alreadyRunning }
        guard let handle = await session.forwardingHandle() else { throw PortForwardError.notConnected }
        switch config.kind {
        case .local: try await startLocal(handle)
        case .remote: try await startRemote(handle)
        }
        isRunning = true
        startTicker()
    }

    /// Stops listening and closes every piped connection. Safe to call when not running.
    public func stop() async {
        ticker?.cancel()
        ticker = nil
        if let server = serverChannel {
            serverChannel = nil
            try? await server.close()
        }
        remoteTask?.cancel()
        remoteTask = nil
        counters.closeAll()
        isRunning = false
        continuation.yield(counters.snapshot())
    }

    // MARK: - Local forward

    private func startLocal(_ handle: SSHClientHandle) async throws {
        let connection = handle.tcpChannel
        let loop = connection.eventLoop
        let counters = counters
        let targetHost = config.targetHost
        let targetPort = config.targetPort
        do {
            serverChannel = try await ServerBootstrap(group: loop, childGroup: loop)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelOption(ChannelOptions.autoRead, value: false)
                .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                .childChannelInitializer { local in
                    Self.attachLocal(
                        local, connection: connection, counters: counters, targetHost: targetHost,
                        targetPort: targetPort)
                }
                .bind(host: config.bindHost, port: config.bindPort)
                .get()
            boundPort = serverChannel?.localAddress?.port ?? config.bindPort
        } catch let error as IOError where error.errnoCode == EADDRINUSE {
            throw PortForwardError.portInUse(config.bindPort)
        } catch {
            throw PortForwardError.failed(error.localizedDescription)
        }
    }

    /// Runs on the event loop for each accepted local connection.
    private static func attachLocal(
        _ local: Channel, connection: Channel, counters: ForwardSession, targetHost: String, targetPort: Int
    ) -> EventLoopFuture<Void> {
        let loop = local.eventLoop
        let (localGlue, sshGlue) = GlueHandler.matchedPair()
        do {
            try local.pipeline.syncOperations.addHandlers([ByteCountingHandler(session: counters), localGlue])
        } catch {
            return loop.makeFailedFuture(error)
        }
        counters.track(local)

        let boundGlue = NIOLoopBound(sshGlue, eventLoop: loop)
        let opened = loop.makePromise(of: Channel.self)
        do {
            let sshHandler = try connection.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
            let originator: SocketAddress
            if let address = local.remoteAddress {
                originator = address
            } else {
                originator = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
            }
            sshHandler.createChannel(
                opened,
                channelType: .directTCPIP(
                    .init(targetHost: targetHost, targetPort: targetPort, originatorAddress: originator))
            ) { channel, type in
                guard case .directTCPIP = type else {
                    return channel.eventLoop.makeFailedFuture(PortForwardError.failed("unexpected channel type"))
                }
                do {
                    try channel.pipeline.syncOperations.addHandlers([SSHDataCodec(), boundGlue.value])
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
        } catch {
            opened.fail(error)
        }
        // The local connection stays paused (autoRead off) until the SSH channel is open.
        return opened.futureResult.map { _ in local.read() }
    }

    // MARK: - Remote forward

    private func startRemote(_ handle: SSHClientHandle) async throws {
        let (ready, readyContinuation) = AsyncThrowingStream<Int, Error>.makeStream()
        let counters = counters
        let targetHost = config.targetHost
        let targetPort = config.targetPort
        let bindHost = config.bindHost
        let bindPort = config.bindPort
        remoteTask = Task { [weak self] in
            do {
                try await handle.runRemoteForward(
                    host: bindHost, port: bindPort,
                    onOpen: { port in
                        readyContinuation.yield(port)
                        readyContinuation.finish()
                    },
                    handleChannel: { channel, _ in
                        Self.attachRemote(
                            channel, counters: counters, targetHost: targetHost, targetPort: targetPort)
                    })
                readyContinuation.finish()
            } catch {
                readyContinuation.finish(throwing: error)
            }
            await self?.remoteForwardEnded()
        }
        do {
            var port: Int?
            for try await opened in ready {
                port = opened
                break
            }
            guard let port else { throw PortForwardError.failed(String(localized: "The server refused the forward.")) }
            boundPort = port
        } catch {
            remoteTask?.cancel()
            remoteTask = nil
            if let error = error as? PortForwardError { throw error }
            throw PortForwardError.failed(error.localizedDescription)
        }
    }

    /// Runs on the event loop for each connection the server forwards back.
    private static func attachRemote(
        _ forwarded: Channel, counters: ForwardSession, targetHost: String, targetPort: Int
    ) -> EventLoopFuture<Void> {
        ClientBootstrap(group: forwarded.eventLoop)
            .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .connect(host: targetHost, port: targetPort)
            .flatMapThrowing { local in
                let (sshGlue, localGlue) = GlueHandler.matchedPair()
                try local.pipeline.syncOperations.addHandlers([ByteCountingHandler(session: counters), localGlue])
                try forwarded.pipeline.syncOperations.addHandlers([SSHDataCodec(), sshGlue])
                counters.track(local)
            }
    }

    private func remoteForwardEnded() {
        guard isRunning else { return }
        isRunning = false
        counters.closeAll()
        continuation.yield(counters.snapshot())
    }

    // MARK: - Stats

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                await self.publish()
            }
        }
    }

    private func publish() {
        continuation.yield(counters.snapshot())
    }
}
