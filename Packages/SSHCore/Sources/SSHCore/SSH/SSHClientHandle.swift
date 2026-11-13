import Citadel
import Foundation
import NIOCore
import NIOSSH

/// Sendable handle around Citadel's `SSHClient` and its TCP channel.
///
/// **Justification for `@unchecked Sendable` (see ADR 0003):** `SSHClient` is a non-`Sendable` class
/// from a Swift 5-mode dependency, and its async methods (`close()`, `connect(on:settings:)`, SFTP
/// helpers) are `nonisolated`, so Swift 6 forbids calling them with an actor-isolated instance.
/// All operations go through methods on this handle, which are `nonisolated` themselves, so the client
/// is only ever touched from the caller's `nonisolated` context and never crosses an isolation
/// boundary as a bare value. Safety relies on `SSHClient` being backed by a NIO channel (internally
/// serialized on its event loop) and on us not using its mutable reconnect state
/// (`SSHReconnectMode` is never enabled). Keep this type's surface minimal; add methods here (not
/// accessors that return the client) when later tasks need more of Citadel's API.
///
/// The TCP `Channel` (which is `Sendable`) is kept alongside so session channels (shell, later
/// direct-tcpip) can be opened with NIOSSH's public `NIOSSHHandler.createChannel` — Citadel 0.12.1's
/// own PTY API is macOS 15-only and closure-scoped (ADR 0004).
struct SSHClientHandle: @unchecked Sendable {
    private let client: SSHClient
    /// The connection's TCP channel; its pipeline contains the `NIOSSHHandler`.
    let tcpChannel: Channel

    /// Connections this one is tunnelled through (outermost jump host first); empty for a direct connection.
    /// They are closed together with this connection.
    private let upstream: [SSHClientHandle]

    private init(client: SSHClient, tcpChannel: Channel, upstream: [SSHClientHandle] = []) {
        self.client = client
        self.tcpChannel = tcpChannel
        self.upstream = upstream
    }

    /// Opens an SSH connection to `settings` through an existing connection (`ProxyJump`): Citadel opens a
    /// `direct-tcpip` channel to the target on `upstream` and runs a full SSH handshake over it. Host key
    /// verification and authentication use `settings` of this hop.
    static func connect(through upstream: SSHClientHandle, settings: SSHClientSettings) async throws
        -> SSHClientHandle
    {
        let client = try await upstream.client.jump(to: settings)
        guard let channel = tcpChannel(of: client) else {
            try? await client.close()
            throw SSHError.connectionFailed(
                "internal error: cannot access the SSH transport (unsupported Citadel version)")
        }
        return SSHClientHandle(client: client, tcpChannel: channel, upstream: upstream.upstream + [upstream])
    }

    /// Opens the TCP connection, then performs the SSH handshake and authentication.
    ///
    /// Uses `SSHClient.connect(to:)`, which installs Citadel's handlers from the channel initializer
    /// (on the event loop). Citadel's `connect(on:settings:)` must not be used: it calls
    /// `pipeline.syncOperations` from outside the loop and trips a NIO precondition (ADR 0003).
    /// The TCP channel is then read out of the client via reflection (Citadel 0.12.1 keeps it in
    /// `SSHClient.session.channel`, which is internal); if that fails the connect is aborted with a
    /// clear error rather than silently losing shell support.
    ///
    /// Dead-peer detection uses TCP keepalive (idle `keepAliveSeconds`, then probes every 10 s, 3
    /// misses) because Citadel has no SSH-level keepalive API. The options are applied right after
    /// the handshake (best effort). A server that closes the socket (e.g. sshd killed) is detected
    /// immediately; a silent network drop within about `keepAliveSeconds + 30` s.
    static func connect(settings: SSHClientSettings, keepAliveSeconds: Int32 = 30) async throws -> SSHClientHandle {
        let client = try await SSHClient.connect(to: settings)
        guard let channel = tcpChannel(of: client) else {
            try? await client.close()
            throw SSHError.connectionFailed(
                "internal error: cannot access the SSH transport (unsupported Citadel version)")
        }
        // On Darwin NIO's socket option level/name/value types are all `Int32`.
        let options: [(level: Int32, name: Int32, value: Int32)] = [
            (SOL_SOCKET, SO_KEEPALIVE, 1),
            (IPPROTO_TCP, TCP_KEEPALIVE, keepAliveSeconds),
            (IPPROTO_TCP, TCP_KEEPINTVL, 10),
            (IPPROTO_TCP, TCP_KEEPCNT, 3),
        ]
        for option in options {
            try? await channel.setOption(
                ChannelOptions.socket(SocketOptionLevel(option.level), option.name), value: option.value
            ).get()
        }
        return SSHClientHandle(client: client, tcpChannel: channel)
    }

    /// Reads `client.session.channel` (internal in Citadel 0.12.1, pinned exactly in `Package.swift`).
    private static func tcpChannel(of client: SSHClient) -> Channel? {
        let session = Mirror(reflecting: client).children.first { $0.label == "session" }?.value
        guard let session else { return nil }
        return Mirror(reflecting: session).children.first { $0.label == "channel" }?.value as? Channel
    }

    /// Opens an SFTP subsystem channel on this connection (Citadel's `SFTPClient` is `Sendable`).
    func openSFTP() async throws -> SFTPClient {
        try await client.openSFTP()
    }

    /// Asks the server to listen on `host:port` (`ssh -R`) and calls `handleChannel` for every connection
    /// it forwards back. Runs until the calling task is cancelled (Citadel then cancels the forward) or
    /// the connection ends. `onOpen` receives the port the server actually bound.
    func runRemoteForward(
        host: String, port: Int, onOpen: @escaping @Sendable (Int) -> Void,
        handleChannel: @escaping @Sendable (Channel, SSHChannelType.ForwardedTCPIP) -> EventLoopFuture<Void>
    ) async throws {
        try await client.withRemotePortForward(
            host: host, port: port, onOpen: { onOpen($0.boundPort) }, handleChannel: handleChannel)
    }

    /// Closes the connection, then every jump host it was tunnelled through (nearest first).
    func close() async throws {
        var failure: Error?
        do {
            try await client.close()
        } catch {
            failure = error
        }
        for hop in upstream.reversed() { try? await hop.client.close() }
        if let failure { throw failure }
    }

    /// Registers a callback for when the connection closes (user-initiated or remote).
    func onDisconnect(perform handler: @escaping @Sendable () -> Void) {
        client.onDisconnect(perform: handler)
    }

    /// Whether the underlying channel is still active.
    var isConnected: Bool {
        client.isConnected
    }
}
