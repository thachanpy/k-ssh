import Foundation
import NIOCore
import NIOSSH
import os

/// How a remote shell ended.
public enum ShellExit: Sendable, Equatable {
    /// Exited with a status code.
    case status(Int)
    /// Terminated by a signal (name without the `SIG` prefix, e.g. `KILL`).
    case signal(String)
}

/// Terminal output from the remote shell (stdout and stderr are merged by the PTY).
///
/// Elements are raw byte chunks, ready to feed a terminal emulator. The sequence ends when the channel
/// closes. **Single consumer.** Backpressure: see `ShellFlowControl` — when more than the high watermark
/// is buffered and unread, reading from the network is paused until the consumer catches up, so memory
/// stays bounded and no bytes are ever dropped (dropping would corrupt escape sequences).
public struct ShellOutput: AsyncSequence, Sendable {
    public typealias Element = [UInt8]

    private let stream: AsyncStream<[UInt8]>
    private let flow: ShellFlowControl

    init(stream: AsyncStream<[UInt8]>, flow: ShellFlowControl) {
        self.stream = stream
        self.flow = flow
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        var base: AsyncStream<[UInt8]>.AsyncIterator
        let flow: ShellFlowControl

        public mutating func next() async -> [UInt8]? {
            guard let chunk = await base.next() else { return nil }
            flow.didConsume(chunk.count)
            return chunk
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: stream.makeAsyncIterator(), flow: flow)
    }
}

/// An interactive shell with a PTY on an established SSH connection.
///
/// Obtain one from `SSHSessionActor.openShell(cols:rows:term:)`. Concurrency: `Sendable`; all methods
/// may be called from any context. Each shell is its own SSH channel on the shared connection.
public final class ShellChannel: Sendable {
    /// Terminal output; ends when the shell closes.
    public let output: ShellOutput

    private let channel: Channel
    private let exit: ShellExitBox
    private let logger = Logger(subsystem: "SSHCore", category: "ShellChannel")

    init(channel: Channel, output: ShellOutput, exit: ShellExitBox) {
        self.channel = channel
        self.output = output
        self.exit = exit
    }

    /// Sends keystrokes / pasted text to the shell. Failures mean the channel is closing (which also
    /// ends `output`), so they are logged rather than thrown.
    public func send(_ bytes: [UInt8]) async {
        guard !bytes.isEmpty else { return }
        do {
            try await channel.writeAndFlush(
                SSHChannelData(type: .channel, data: .byteBuffer(ByteBuffer(bytes: bytes)))
            ).get()
        } catch {
            logger.debug("send failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Tells the server the terminal size changed (SSH `window-change`).
    public func resize(cols: Int, rows: Int) async {
        let request = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: cols, terminalRowHeight: rows,
            terminalPixelWidth: 0, terminalPixelHeight: 0)
        do {
            try await channel.triggerUserOutboundEvent(request).get()
        } catch {
            logger.debug("resize failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Closes this shell's channel (the SSH connection stays up). Ends `output`.
    public func close() async {
        try? await channel.close()
    }

    /// Waits until the channel is closed and returns how the shell ended, if the server reported it.
    public func waitForExit() async -> ShellExit? {
        try? await channel.closeFuture.get()
        return exit.value
    }

    /// The exit information received so far (`nil` until the server reports it).
    public var exitStatus: ShellExit? {
        exit.value
    }
}

// MARK: - Internals

/// Records how the shell exited.
final class ShellExitBox: Sendable {
    private let lock = OSAllocatedUnfairLock<ShellExit?>(initialState: nil)

    func set(_ exit: ShellExit) {
        lock.withLock { $0 = exit }
    }

    var value: ShellExit? {
        lock.withLock { $0 }
    }
}

/// Bounded buffering for shell output via network read pause/resume.
///
/// Policy: when unread bytes reach `highWatermark` the child channel's `autoRead` is turned off (SSH
/// window stops being replenished, so the server slows down); when the consumer drains to
/// `lowWatermark`, reading resumes. Defaults: pause at 1 MiB, resume at 256 KiB.
final class ShellFlowControl: Sendable {
    private struct State {
        var buffered = 0
        var paused = false
        var channel: Channel?
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let highWatermark: Int
    private let lowWatermark: Int

    init(highWatermark: Int = 1 << 20, lowWatermark: Int = 1 << 18) {
        self.highWatermark = highWatermark
        self.lowWatermark = lowWatermark
    }

    /// Called by the handler when added to a channel.
    func attach(_ channel: Channel) {
        lock.withLock { $0.channel = channel }
    }

    /// Called on the event loop for every inbound chunk.
    func didReceive(_ count: Int) {
        let channelToPause: Channel? = lock.withLock { state in
            state.buffered += count
            guard state.buffered >= highWatermark, !state.paused else { return nil }
            state.paused = true
            return state.channel
        }
        channelToPause?.setOption(ChannelOptions.autoRead, value: false).whenFailure { _ in }
    }

    /// Called by the consumer after taking a chunk.
    func didConsume(_ count: Int) {
        let channelToResume: Channel? = lock.withLock { state in
            state.buffered = max(0, state.buffered - count)
            guard state.paused, state.buffered <= lowWatermark else { return nil }
            state.paused = false
            return state.channel
        }
        if let channel = channelToResume {
            channel.setOption(ChannelOptions.autoRead, value: true).whenSuccess { _ in channel.read() }
        }
    }
}

/// Pipeline handler for a shell session channel: forwards data to `ShellOutput`, records exit info,
/// and finishes the stream when the channel goes inactive.
final class ShellChannelHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = SSHChannelData

    private let continuation: AsyncStream<[UInt8]>.Continuation
    private let flow: ShellFlowControl
    private let exit: ShellExitBox

    init(continuation: AsyncStream<[UInt8]>.Continuation, flow: ShellFlowControl, exit: ShellExitBox) {
        self.continuation = continuation
        self.flow = flow
        self.exit = exit
    }

    func handlerAdded(context: ChannelHandlerContext) {
        flow.attach(context.channel)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = channelData.data else { return }
        let bytes = [UInt8](buffer.readableBytesView)
        guard !bytes.isEmpty else { return }
        flow.didReceive(bytes.count)
        continuation.yield(bytes)  // stderr (`.stdErr`) is merged: a PTY has a single stream anyway
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let status as SSHChannelRequestEvent.ExitStatus:
            exit.set(.status(status.exitStatus))
        case let signal as SSHChannelRequestEvent.ExitSignal:
            exit.set(.signal(signal.signalName))
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        continuation.finish()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        continuation.finish()
        context.close(promise: nil)
    }
}

/// Builds the connected pieces of a shell (handler + output + exit box) so production code and tests
/// construct them identically.
struct ShellParts: Sendable {
    let handler: ShellChannelHandler
    let output: ShellOutput
    let exit: ShellExitBox

    static func make(
        highWatermark: Int = 1 << 20, lowWatermark: Int = 1 << 18
    ) -> ShellParts {
        let (stream, continuation) = AsyncStream.makeStream(of: [UInt8].self, bufferingPolicy: .unbounded)
        let flow = ShellFlowControl(highWatermark: highWatermark, lowWatermark: lowWatermark)
        let exit = ShellExitBox()
        return ShellParts(
            handler: ShellChannelHandler(continuation: continuation, flow: flow, exit: exit),
            output: ShellOutput(stream: stream, flow: flow), exit: exit)
    }
}
