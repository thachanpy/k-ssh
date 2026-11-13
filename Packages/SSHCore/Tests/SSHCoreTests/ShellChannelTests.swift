import NIOCore
import NIOEmbedded
import NIOSSH
import XCTest
import os

@testable import SSHCore

/// Offline tests for the shell channel pieces using `NIOAsyncTestingChannel` (no SSH server needed).
///
/// `EmbeddedChannel` is single-threaded and crashes when an async test resumes on another thread, so
/// the thread-safe async testing channel is used. Its event loop only runs tasks when asked, so
/// anything that waits on the loop goes through `drive`, which pumps the loop while it waits.
final class ShellChannelTests: XCTestCase {
    private struct Harness {
        let channel: NIOAsyncTestingChannel
        let shell: ShellChannel
        let recorder: OutboundRecorder

        /// Runs `operation` while pumping the testing event loop until it completes.
        func drive<T: Sendable>(_ operation: @escaping @Sendable () async -> T) async -> T {
            let loop = channel.testingEventLoop
            let work = Task { await operation() }
            let pump = Task {
                while !Task.isCancelled {
                    await loop.run()
                    await Task.yield()
                }
            }
            let result = await work.value
            pump.cancel()
            await loop.run()
            return result
        }

        /// Current `autoRead` option value.
        func autoRead() async -> Bool {
            let channel = channel
            return await drive { (try? await channel.getOption(ChannelOptions.autoRead)) ?? false }
        }

        /// Fires an event through the pipeline and lets the loop process it.
        func fire(_ event: @escaping @Sendable (ChannelPipeline) -> Void) async {
            event(channel.pipeline)
            await channel.testingEventLoop.run()
        }
    }

    private func makeHarness(highWatermark: Int = 1 << 20, lowWatermark: Int = 1 << 18) async throws -> Harness {
        let parts = ShellParts.make(highWatermark: highWatermark, lowWatermark: lowWatermark)
        let channel = NIOAsyncTestingChannel()
        let recorder = OutboundRecorder()
        try await channel.pipeline.addHandler(recorder)
        try await channel.pipeline.addHandler(parts.handler)
        // The testing channel asserts on deinit if it was never finished.
        addTeardownBlock { _ = try? await channel.finish(acceptAlreadyClosed: true) }
        let shell = ShellChannel(channel: channel, output: parts.output, exit: parts.exit)
        return Harness(channel: channel, shell: shell, recorder: recorder)
    }

    private func data(_ text: String, type: SSHChannelData.DataType = .channel) -> SSHChannelData {
        SSHChannelData(type: type, data: .byteBuffer(ByteBuffer(string: text)))
    }

    func testOutputDeliversChunksInOrderAndMergesStderr() async throws {
        let h = try await makeHarness()
        try await h.channel.writeInbound(data("hello "))
        try await h.channel.writeInbound(data("world", type: .stdErr))
        var iterator = h.shell.output.makeAsyncIterator()
        let first = await iterator.next()
        let second = await iterator.next()
        XCTAssertEqual(first, Array("hello ".utf8))
        XCTAssertEqual(second, Array("world".utf8))
    }

    func testChannelInactiveEndsOutput() async throws {
        let h = try await makeHarness()
        try await h.channel.writeInbound(data("bye"))
        await h.fire { $0.fireChannelInactive() }
        var iterator = h.shell.output.makeAsyncIterator()
        let chunk = await iterator.next()
        XCTAssertEqual(chunk, Array("bye".utf8))
        let end = await iterator.next()
        XCTAssertNil(end, "stream must finish after the channel goes inactive")
    }

    func testExitStatusAndSignalAreRecorded() async throws {
        let h = try await makeHarness()
        XCTAssertNil(h.shell.exitStatus)
        await h.fire { $0.fireUserInboundEventTriggered(SSHChannelRequestEvent.ExitStatus(exitStatus: 3)) }
        XCTAssertEqual(h.shell.exitStatus, .status(3))
        await h.fire {
            $0.fireUserInboundEventTriggered(
                SSHChannelRequestEvent.ExitSignal(
                    signalName: "KILL", errorMessage: "", language: "", dumpedCore: false))
        }
        XCTAssertEqual(h.shell.exitStatus, .signal("KILL"))
    }

    func testWaitForExitReturnsAfterClose() async throws {
        let h = try await makeHarness()
        await h.fire { $0.fireUserInboundEventTriggered(SSHChannelRequestEvent.ExitStatus(exitStatus: 7)) }
        let shell = h.shell
        await h.drive { await shell.close() }
        let exit = await h.drive { await shell.waitForExit() }
        XCTAssertEqual(exit, .status(7))
    }

    func testSendWritesChannelData() async throws {
        let h = try await makeHarness()
        let shell = h.shell
        await h.drive { await shell.send(Array("ls\n".utf8)) }
        let written = try await h.channel.readOutbound(as: SSHChannelData.self)
        guard case .byteBuffer(let buffer)? = written?.data else { return XCTFail("nothing written") }
        XCTAssertEqual(String(buffer: buffer), "ls\n")
        XCTAssertEqual(written?.type, .channel)
    }

    func testSendEmptyBytesWritesNothing() async throws {
        let h = try await makeHarness()
        let shell = h.shell
        await h.drive { await shell.send([]) }
        let written = try await h.channel.readOutbound(as: SSHChannelData.self)
        XCTAssertNil(written)
    }

    func testResizeSendsWindowChange() async throws {
        let h = try await makeHarness()
        let shell = h.shell
        await h.drive { await shell.resize(cols: 132, rows: 50) }
        XCTAssertEqual(h.recorder.windowChanges, [[132, 50]])
    }

    func testFlowControlPausesReadingWhenBufferIsFullAndResumesWhenDrained() async throws {
        let h = try await makeHarness(highWatermark: 10, lowWatermark: 4)
        let initial = await h.autoRead()
        XCTAssertTrue(initial)

        try await h.channel.writeInbound(data("123456"))  // 6 buffered: below high watermark
        let belowHigh = await h.autoRead()
        XCTAssertTrue(belowHigh)

        try await h.channel.writeInbound(data("789012"))  // 12 buffered: pause
        let paused = await h.autoRead()
        XCTAssertFalse(paused, "reading must pause at the high watermark")

        var iterator = h.shell.output.makeAsyncIterator()
        _ = await iterator.next()  // 6 consumed -> 6 left, still above low watermark (4)
        let stillPaused = await h.autoRead()
        XCTAssertFalse(stillPaused)

        _ = await iterator.next()  // 12 consumed -> 0 left: resume
        let resumed = await h.autoRead()
        XCTAssertTrue(resumed, "reading must resume at the low watermark")
    }

    func testNoBytesAreDroppedUnderBackpressure() async throws {
        let h = try await makeHarness(highWatermark: 8, lowWatermark: 2)
        for index in 0..<50 { try await h.channel.writeInbound(data("chunk\(index);")) }
        await h.fire { $0.fireChannelInactive() }
        var received = ""
        for await chunk in h.shell.output { received += String(decoding: chunk, as: UTF8.self) }
        let expected = (0..<50).map { "chunk\($0);" }.joined()
        XCTAssertEqual(received, expected)
    }
}

/// Records user outbound events (window changes) passing through a testing channel pipeline.
private final class OutboundRecorder: ChannelOutboundHandler, Sendable {
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private let storage = OSAllocatedUnfairLock<[[Int]]>(initialState: [])

    var windowChanges: [[Int]] { storage.withLock { $0 } }

    func triggerUserOutboundEvent(context: ChannelHandlerContext, event: Any, promise: EventLoopPromise<Void>?) {
        if let change = event as? SSHChannelRequestEvent.WindowChangeRequest {
            storage.withLock { $0.append([change.terminalCharacterWidth, change.terminalRowHeight]) }
            promise?.succeed(())
        } else {
            context.triggerUserOutboundEvent(event, promise: promise)
        }
    }
}
