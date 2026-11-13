import Foundation
import Observation
import SSHCore

/// What the terminal view needs from a model: output goes in, keystrokes/size/title come out.
@MainActor
protocol TerminalIO: AnyObject {
    /// Receives terminal output on the main actor; output that arrives before a sink exists is buffered.
    var outputSink: (@MainActor ([UInt8]) -> Void)? { get set }
    func send(_ bytes: [UInt8])
    func resize(cols: Int, rows: Int)
    func setTitle(_ title: String)
}

extension TerminalViewModel: TerminalIO {}

/// An additional shell (split pane) on the same SSH connection as the tab's primary terminal.
///
/// The connection and its lifecycle belong to the primary `TerminalViewModel`; this model only opens
/// and closes one extra shell channel on it (`SSHSessionActor.openShell`).
@MainActor
@Observable
final class ExtraPaneViewModel: TerminalIO, Identifiable {
    enum Phase: Equatable {
        case opening, open, ended
        case failed(String)
    }

    let id: UUID
    private(set) var title: String
    private(set) var phase: Phase = .opening

    var outputSink: (@MainActor ([UInt8]) -> Void)? {
        didSet { flushPending() }
    }

    /// Called when the shell ended by itself (e.g. the user typed `exit`), not when `close()` is used.
    var onEnded: (@MainActor () -> Void)?

    private let parent: TerminalViewModel
    private let tasks = TaskBag()
    private var shell: ShellChannel?
    private var inputContinuation: AsyncStream<[UInt8]>.Continuation?
    private var pendingOutput: [[UInt8]] = []
    private var cols = 80
    private var rows = 24
    private var closedByUs = false

    init(id: UUID = UUID(), parent: TerminalViewModel) {
        self.id = id
        self.parent = parent
        self.title = parent.profile.name
    }

    /// Opens the shell if the parent connection is up and no shell is open yet.
    func open() async {
        guard shell == nil, phase != .open else { return }
        guard let session = parent.activeSession else {
            phase = .failed(String(localized: "The session is not connected."))
            return
        }
        phase = .opening
        closedByUs = false
        do {
            let opened = try await session.openShell(cols: cols, rows: rows)
            guard !closedByUs else {
                await opened.close()
                return
            }
            shell = opened
            phase = .open
            startInput(for: opened)
            startPump(for: opened)
        } catch {
            phase = .failed(SSHError.map(error).errorDescription ?? error.localizedDescription)
        }
    }

    /// Closes this pane's shell channel only (the SSH connection stays up).
    func close() async {
        closedByUs = true
        tasks.cancelAll()
        inputContinuation?.finish()
        inputContinuation = nil
        let old = shell
        shell = nil
        phase = .ended
        await old?.close()
    }

    func send(_ bytes: [UInt8]) {
        inputContinuation?.yield(bytes)
    }

    func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        self.cols = cols
        self.rows = rows
        guard let shell else { return }
        tasks.add(Task { await shell.resize(cols: cols, rows: rows) })
    }

    func setTitle(_ newTitle: String) {
        title = newTitle.isEmpty ? parent.profile.name : newTitle
    }

    // MARK: - Private

    private func startInput(for shell: ShellChannel) {
        let (stream, continuation) = AsyncStream.makeStream(of: [UInt8].self, bufferingPolicy: .unbounded)
        inputContinuation = continuation
        tasks.add(
            Task {
                for await bytes in stream { await shell.send(bytes) }
            })
    }

    private func startPump(for shell: ShellChannel) {
        tasks.add(
            Task { [weak self] in
                for await chunk in shell.output {
                    guard let self else { return }
                    self.deliver(chunk)
                }
                _ = await shell.waitForExit()
                guard let self else { return }
                self.shellEnded()
            })
    }

    private func shellEnded() {
        guard !closedByUs else { return }
        inputContinuation?.finish()
        inputContinuation = nil
        shell = nil
        phase = .ended
        onEnded?()
    }

    private func deliver(_ chunk: [UInt8]) {
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
}
