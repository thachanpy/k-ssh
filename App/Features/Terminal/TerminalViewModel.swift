import Foundation
import Observation
import SSHCore
import os

/// Cancels the tasks it holds when it is deallocated, so `@MainActor` view models can satisfy
/// "cancel in deinit" without a main-actor deinit.
final class TaskBag: Sendable {
    private let tasks = OSAllocatedUnfairLock<[Task<Void, Never>]>(initialState: [])

    func add(_ task: Task<Void, Never>) {
        tasks.withLock { $0.append(task) }
    }

    func cancelAll() {
        let all = tasks.withLock { current -> [Task<Void, Never>] in
            defer { current = [] }
            return current
        }
        all.forEach { $0.cancel() }
    }

    deinit { cancelAll() }
}

/// Owns one SSH session and its interactive shell, and bridges bytes between the shell and the
/// terminal view.
///
/// Lifecycle: `connect()` → session + shell → output pump; `disconnect()` or `deinit` cancel all tasks.
/// A session is single-use (`SSHSessionActor`), so `reconnect()` builds a new one via `makeSession`.
@MainActor
@Observable
final class TerminalViewModel {
    let profile: HostProfile
    /// Connection state mirrored from the session (`idle` before the first connect).
    private(set) var state: ConnectionState = .idle
    /// Terminal title (host name until the remote sets one).
    private(set) var title: String
    /// Last connect/shell error, cleared on the next attempt.
    private(set) var failure: SSHError?
    /// How the shell ended, if it did.
    private(set) var exit: ShellExit?
    /// `true` once the shell opened and until it ends.
    private(set) var isShellOpen = false
    /// Set by the tab while it has several panes: the connection must outlive this shell.
    var keepSessionWhenShellEnds = false
    /// Creates a transcript logger when the host has logging enabled (set by the tab).
    var makeLogger: (@MainActor () -> SessionLogger?)?
    /// Called after the primary shell ended by itself (not via `disconnect()`).
    var onShellEnded: (@MainActor () -> Void)?

    /// Receives terminal output on the main actor; set by the terminal view. Output that arrives
    /// before a sink exists is buffered and flushed when it is set.
    var outputSink: (@MainActor ([UInt8]) -> Void)? {
        didSet { flushPending() }
    }

    private let makeSession: @MainActor () -> SSHSessionActor
    private let jumpChain: @MainActor () throws -> [HostProfile]
    private let logger = Logger(subsystem: "SSHClient", category: "TerminalViewModel")
    private let tasks = TaskBag()
    private var session: SSHSessionActor?
    private var shell: ShellChannel?
    private var sessionLogger: SessionLogger?
    private var pendingOutput: [[UInt8]] = []
    private var cols = 80
    private var rows = 24
    private var userInitiatedClose = false
    private var inputContinuation: AsyncStream<[UInt8]>.Continuation?

    /// Creates a view model.
    /// - Parameters:
    ///   - profile: Host to connect to.
    ///   - makeSession: Factory for a fresh session (called on every connect/reconnect).
    ///   - jumpChain: Resolves the jump hosts (outermost first) at connect time; may throw
    ///     `JumpChainError`. Default: direct connection.
    init(
        profile: HostProfile, makeSession: @escaping @MainActor () -> SSHSessionActor,
        jumpChain: @escaping @MainActor () throws -> [HostProfile] = { [] }
    ) {
        self.profile = profile
        self.title = profile.name
        self.makeSession = makeSession
        self.jumpChain = jumpChain
    }

    /// Connects, opens a shell, and starts pumping output. Safe to call again after a failure or
    /// disconnect (use `reconnect()` for clarity).
    func connect() async {
        guard !state.isActive else { return }
        resetForNewAttempt()
        let session = makeSession()
        self.session = session
        observeState(of: session)
        do {
            try await session.connect(profile: profile, via: try jumpChain())
            try Task.checkCancellation()
            let shell = try await session.openShell(cols: cols, rows: rows)
            guard !userInitiatedClose else {
                await shell.close()
                return
            }
            self.shell = shell
            sessionLogger = makeLogger?()
            isShellOpen = true
            startInputQueue(for: shell)
            startOutputPump(for: shell, session: session)
        } catch {
            let mapped = SSHError.map(error)
            if mapped != .cancelled { failure = mapped }
            await session.disconnect()
        }
    }

    /// Drops any previous session and connects again with a new one.
    func reconnect() async {
        await teardown()
        state = .idle
        await connect()
    }

    /// Closes the shell and the session; cancels all tasks.
    func disconnect() async {
        userInitiatedClose = true
        await teardown()
        state = .disconnected(reason: nil)
    }

    /// The live session while connected (used to attach tunnels), otherwise `nil`.
    var activeSession: SSHSessionActor? {
        state == .connected ? session : nil
    }

    /// Opens an SFTP channel on this tab's SSH connection.
    /// - Throws: `SSHError.notConnected` unless the session is connected.
    func openSFTP() async throws -> SFTPServiceActor {
        guard state == .connected, let session else { throw SSHError.notConnected }
        return try await session.openSFTP()
    }

    /// Sends user input (keystrokes/paste). Ordered: bytes reach the shell in call order.
    func send(_ bytes: [UInt8]) {
        logger.debug("vm.send: \(bytes.count) bytes, input queue open: \(self.inputContinuation != nil)")
        inputContinuation?.yield(bytes)
    }

    /// Records the terminal size and informs the remote PTY if a shell is open.
    func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        self.cols = cols
        self.rows = rows
        guard let shell else { return }
        tasks.add(Task { await shell.resize(cols: cols, rows: rows) })
    }

    /// Updates the title (called by the terminal view when the remote sets one).
    func setTitle(_ newTitle: String) {
        title = newTitle.isEmpty ? profile.name : newTitle
    }

    // MARK: - Private

    private func resetForNewAttempt() {
        userInitiatedClose = false
        failure = nil
        exit = nil
        isShellOpen = false
    }

    private func observeState(of session: SSHSessionActor) {
        let stream = session.state
        tasks.add(
            Task { [weak self] in
                for await newState in stream {
                    guard let self else { return }
                    self.state = newState
                }
            })
    }

    private func startInputQueue(for shell: ShellChannel) {
        let (stream, continuation) = AsyncStream.makeStream(of: [UInt8].self, bufferingPolicy: .unbounded)
        inputContinuation = continuation
        tasks.add(
            Task {
                for await bytes in stream { await shell.send(bytes) }
            })
    }

    private func startOutputPump(for shell: ShellChannel, session: SSHSessionActor) {
        tasks.add(
            Task { [weak self] in
                for await chunk in shell.output {
                    guard let self else { return }
                    self.deliver(chunk)
                }
                // Output ended: the shell exited or the connection dropped.
                let result = await shell.waitForExit()
                guard let self else { return }
                self.shellEnded(exit: result)
            })
    }

    private func shellEnded(exit result: ShellExit?) {
        exit = result
        isShellOpen = false
        inputContinuation?.finish()
        inputContinuation = nil
        shell = nil
        finishLogger()
        onShellEnded?()
        // If only the shell ended (e.g. the user typed `exit`) the connection is still up: close it,
        // unless other panes of the tab still use it (`keepSessionWhenShellEnds`).
        // On a network drop the session already reports `.disconnected(reason:)`; keep that reason.
        if !userInitiatedClose, !keepSessionWhenShellEnds, state == .connected, let session {
            tasks.add(Task { await session.disconnect() })
        }
    }

    /// Closes only the primary shell channel, keeping the SSH session (split panes still use it).
    func closeShell() async {
        let old = shell
        shell = nil
        isShellOpen = false
        inputContinuation?.finish()
        inputContinuation = nil
        await old?.close()
    }

    private func finishLogger() {
        guard let old = sessionLogger else { return }
        sessionLogger = nil
        Task { await old.finish() }
    }

    private func deliver(_ chunk: [UInt8]) {
        sessionLogger?.log(chunk)
        if let sink = outputSink {
            sink(chunk)
        } else {
            pendingOutput.append(chunk)
        }
    }

    private func flushPending() {
        guard let sink = outputSink, !pendingOutput.isEmpty else { return }
        let buffered = pendingOutput
        pendingOutput = []
        buffered.forEach(sink)
    }

    private func teardown() async {
        tasks.cancelAll()
        inputContinuation?.finish()
        inputContinuation = nil
        let oldShell = shell
        let oldSession = session
        shell = nil
        session = nil
        isShellOpen = false
        finishLogger()
        await oldShell?.close()
        await oldSession?.disconnect()
    }
}

extension ConnectionState {
    /// `true` while a connection attempt or live connection exists (so `connect()` must not restart).
    var isActive: Bool {
        switch self {
        case .connecting, .awaitingHostKeyApproval, .connected: true
        case .idle, .disconnected, .failed: false
        }
    }
}
