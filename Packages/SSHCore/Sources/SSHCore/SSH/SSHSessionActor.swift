import Citadel
import Foundation
import NIOCore
import os

/// One SSH connection: connect, authenticate, observe state, disconnect.
///
/// Owns the connection to Citadel's non-`Sendable` `SSHClient` through `SSHClientHandle`
/// (ADR 0003). Later tasks extend the actor with shell channels (T07), SFTP (T15) and forwarding (T17)
/// over the same connection, by adding methods to the handle.
/// An instance is single-use: after `disconnect()` the `state` stream finishes and `connect` throws
/// `.sessionClosed`; create a new session to reconnect.
public actor SSHSessionActor: SSHSessionProviding {
    /// Current state first, then every transition. Single consumer.
    public nonisolated let state: AsyncStream<ConnectionState>

    private let continuation: AsyncStream<ConnectionState>.Continuation
    private let resolver: CredentialResolver
    private let knownHosts: KnownHostsStore
    private let keychain: any KeychainProviding
    private let prompts: SSHPrompts
    private let connectTimeout: TimeAmount
    private let keepAliveSeconds: Int32
    private let logger = Logger(subsystem: "SSHCore", category: "SSHSession")

    /// The live connection; `nil` unless connected. Internal so same-module extensions can use it.
    /// Wraps Citadel's non-`Sendable` `SSHClient` (see `SSHClientHandle`, ADR 0003).
    var handle: SSHClientHandle?
    private(set) var currentState: ConnectionState = .idle
    private var userInitiatedDisconnect = false
    private var isClosed = false
    private var isConnecting = false

    /// Creates a session.
    /// - Parameters:
    ///   - keychain: Saved passwords/passphrases.
    ///   - bookmarks: Reads key files via security-scoped bookmarks.
    ///   - keys: Key references.
    ///   - knownHosts: Trusted host keys.
    ///   - prompts: UI callbacks for passwords, passphrases, and host-key approval.
    ///   - connectTimeoutSeconds: Network connect / handshake timeout (default 15 s).
    ///   - keepAliveSeconds: TCP keepalive idle time used to detect a dead network (default 30 s).
    public init(
        keychain: any KeychainProviding, bookmarks: BookmarkService, keys: KeyRepository,
        knownHosts: KnownHostsStore, prompts: SSHPrompts, connectTimeoutSeconds: Int64 = 15,
        keepAliveSeconds: Int32 = 30
    ) {
        self.keepAliveSeconds = keepAliveSeconds
        let (stream, continuation) = AsyncStream.makeStream(
            of: ConnectionState.self, bufferingPolicy: .bufferingNewest(1))
        self.state = stream
        self.continuation = continuation
        self.resolver = CredentialResolver(
            keychain: keychain, bookmarks: bookmarks, keys: keys, prompts: prompts)
        self.knownHosts = knownHosts
        self.keychain = keychain
        self.prompts = prompts
        self.connectTimeout = .seconds(connectTimeoutSeconds)
        continuation.yield(.idle)
    }

    deinit {
        continuation.finish()
    }

    /// Connects and authenticates.
    /// - Throws: `SSHError`. State ends in `.connected`, `.failed`, or (when cancelled) `.idle`.
    public func connect(profile: HostProfile) async throws {
        try await connect(profile: profile, via: [])
    }

    /// Connects through jump hosts (`ProxyJump`), outermost first, then authenticates to `profile`.
    /// Each hop is verified against known hosts and authenticated with its own credentials/prompts.
    /// - Parameter jumpHosts: From `JumpChain.resolve(for:hosts:)`; empty for a direct connection.
    public func connect(profile: HostProfile, via jumpHosts: [HostProfile]) async throws {
        guard !isClosed else { throw SSHError.sessionClosed }
        guard handle == nil, !isConnecting else { throw SSHError.alreadyConnected }
        isConnecting = true
        defer { isConnecting = false }
        userInitiatedDisconnect = false
        setState(.connecting)
        logger.info("Connecting to \(profile.hostname, privacy: .private):\(profile.port)")
        do {
            try await establish(profile: profile, via: jumpHosts)
            setState(.connected)
        } catch {
            let mapped = SSHError.map(error)
            if mapped == .cancelled {
                setState(.idle)
            } else {
                setState(.failed(message: mapped.errorDescription ?? ""))
            }
            logger.error("Connect failed: \(String(describing: mapped), privacy: .private)")
            throw mapped
        }
    }

    /// Closes the connection and finishes the `state` stream. Safe to call in any state.
    public func disconnect() async {
        userInitiatedDisconnect = true
        isClosed = true
        if let existing = handle {
            handle = nil
            try? await existing.close()
        }
        setState(.disconnected(reason: nil))
        continuation.finish()
    }

    /// Opens an interactive shell (PTY) on the connection. Each call is an independent channel over the
    /// same SSH connection, so several can be open at once (split panes, T20).
    /// - Parameters:
    ///   - cols: Terminal width in characters.
    ///   - rows: Terminal height in rows.
    ///   - term: `TERM` value, default `xterm-256color`.
    /// - Throws: `SSHError.notConnected` or `.shellOpenFailed`.
    public func openShell(cols: Int, rows: Int, term: String = "xterm-256color") async throws -> ShellChannel {
        guard let handle else { throw SSHError.notConnected }
        return try await handle.openShell(cols: cols, rows: rows, term: term)
    }

    /// Opens an SFTP channel over the same SSH connection (no new TCP connection or login).
    /// - Throws: `SSHError.notConnected` or an `SFTPServiceError`.
    public func openSFTP() async throws -> SFTPServiceActor {
        guard let handle else { throw SSHError.notConnected }
        do {
            return SFTPServiceActor(client: try await handle.openSFTP())
        } catch {
            throw SFTPServiceError.map(error)
        }
    }

    // MARK: - Private

    /// Connects hop by hop: direct to the first host, then each next hop through the previous one.
    /// Every hop (jump hosts and the target) has its own credentials, prompts and host-key check.
    private func establish(profile: HostProfile, via jumpHosts: [HostProfile]) async throws {
        let hops = jumpHosts + [profile]
        let recorder = HostKeyFailureRecorder()
        var boxes: [CredentialBox] = []
        var pendingSaves: [(key: SecretKey, secret: String)] = []
        defer { boxes.forEach { $0.clear() } }  // secrets live only for the duration of the connect

        var current: SSHClientHandle?
        do {
            for hop in hops {
                try Task.checkCancellation()
                let resolved = try await resolver.resolve(for: hop)
                try Task.checkCancellation()
                let box = CredentialBox(resolved.credential)
                boxes.append(box)
                if let pending = resolved.pendingSave { pendingSaves.append(pending) }
                let settings = makeSettings(for: hop, box: box, recorder: recorder)
                if let upstream = current {
                    current = try await SSHClientHandle.connect(through: upstream, settings: settings)
                } else {
                    current = try await SSHClientHandle.connect(
                        settings: settings, keepAliveSeconds: keepAliveSeconds)
                }
            }
        } catch {
            if let partial = current { try? await partial.close() }  // closes the hops opened so far
            if let hostKeyError = recorder.value { throw SSHError.map(hostKeyError) }
            throw error
        }
        guard let newHandle = current else { throw SSHError.connectionFailed("no connection was opened") }
        if Task.isCancelled || userInitiatedDisconnect {
            try? await newHandle.close()
            throw CancellationError()
        }

        handle = newHandle
        newHandle.onDisconnect { [weak self] in
            Task { await self?.handleRemoteDisconnect() }
        }
        for pending in pendingSaves {
            do {
                try await keychain.set(pending.secret, for: pending.key)
            } catch {
                logger.error("Could not save credential to Keychain")
            }
        }
    }

    /// Citadel settings for one hop (host-key checks are keyed by that hop's own `host:port`).
    private func makeSettings(
        for hop: HostProfile, box: CredentialBox, recorder: HostKeyFailureRecorder
    ) -> SSHClientSettings {
        // Weak: Citadel's client retains this closure; a strong capture would form an actor↔client cycle.
        let validator = HostKeyValidator(store: knownHosts) { [weak self] key in
            await self?.requestHostKeyApproval(key) ?? false
        }
        let delegate = HostKeyValidationDelegate(
            host: hop.hostname, port: hop.port, validator: validator,
            onFailure: { recorder.record($0) })
        let username = hop.username
        var settings = SSHClientSettings(
            host: hop.hostname, port: hop.port,
            authenticationMethod: { box.makeAuthenticationMethod(username: username) },
            hostKeyValidator: delegate.citadelValidator)
        settings.connectTimeout = connectTimeout
        return settings
    }

    private func requestHostKeyApproval(_ key: KnownHost) async -> Bool {
        setState(.awaitingHostKeyApproval(fingerprint: key.fingerprintSHA256))
        let approved = await prompts.hostKey(key)
        if approved { setState(.connecting) }
        return approved
    }

    private func handleRemoteDisconnect() {
        guard !userInitiatedDisconnect, handle != nil else { return }
        handle = nil
        setState(.disconnected(reason: String(localized: "The connection was lost.")))
    }

    private func setState(_ newState: ConnectionState) {
        currentState = newState
        continuation.yield(newState)
    }
}

/// Holds credentials for Citadel's `@Sendable` auth-method factory, and can be wiped after connect.
///
/// Citadel calls the factory more than once and `SSHAuthenticationMethod` is not `Sendable`, so the
/// method is rebuilt from the (Sendable) credential on each call. After `clear()` the factory yields
/// a method that cannot authenticate.
private final class CredentialBox: Sendable {
    private let lock: OSAllocatedUnfairLock<SSHCredential?>

    init(_ credential: SSHCredential) {
        lock = OSAllocatedUnfairLock(initialState: credential)
    }

    func clear() {
        lock.withLock { $0 = nil }
    }

    func makeAuthenticationMethod(username: String) -> SSHAuthenticationMethod {
        let credential = lock.withLock { $0 }
        switch credential {
        case .password(let password):
            return .passwordBased(username: username, password: password)
        case .privateKey(let text, let passphrase):
            if let method = try? PrivateKeyLoader.authenticationMethod(
                username: username, keyText: text, passphrase: passphrase)
            {
                return method
            }
            return .passwordBased(username: username, password: "")
        case nil:
            return .passwordBased(username: username, password: "")
        }
    }
}

/// Remembers the last host-key failure so the precise cause survives NIO error wrapping.
private final class HostKeyFailureRecorder: Sendable {
    private let lock = OSAllocatedUnfairLock<HostKeyError?>(initialState: nil)

    func record(_ error: HostKeyError) {
        lock.withLock { $0 = error }
    }

    var value: HostKeyError? {
        lock.withLock { $0 }
    }
}
