import XCTest
import os

@testable import SSHCore

/// Fake transport: each transfer sleeps, tracks concurrency, and can be told to fail.
private final class FakeTransfers: SFTPTransferring, Sendable {
    struct State {
        var running = 0
        var maxRunning = 0
        var started: [String] = []
    }

    let state = OSAllocatedUnfairLock(initialState: State())
    let delay: Duration

    init(delay: Duration) {
        self.delay = delay
    }

    func upload(local: URL, remote: String) -> AsyncThrowingStream<TransferProgress, Error> {
        stream(name: remote)
    }

    func download(remote: String, local: URL) -> AsyncThrowingStream<TransferProgress, Error> {
        stream(name: remote)
    }

    private func stream(name: String) -> AsyncThrowingStream<TransferProgress, Error> {
        let state = state
        let delay = delay
        return AsyncThrowingStream { continuation in
            let task = Task {
                state.withLock {
                    $0.running += 1
                    $0.maxRunning = max($0.maxRunning, $0.running)
                    $0.started.append(name)
                }
                do {
                    try await Task.sleep(for: delay)
                    if name.contains("bad") { throw SFTPServiceError.failed("boom") }
                    continuation.yield(TransferProgress(bytesTransferred: 10, totalBytes: 10))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                state.withLock { $0.running -= 1 }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

final class TransferQueueTests: XCTestCase {
    private func job(_ name: String, kind: TransferJob.Kind = .upload) -> TransferJob {
        TransferJob(kind: kind, local: URL(fileURLWithPath: "/tmp/\(name)"), remote: "/remote/\(name)")
    }

    /// Polls the queue (max 10 s) until `condition` holds. Polling instead of `updates`, because an
    /// `AsyncStream` ends for good when one consumer stops iterating, and tests wait several times.
    private func wait(
        for queue: TransferQueue, _ condition: ([TransferItem]) -> Bool
    ) async throws -> [TransferItem] {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            let items = await queue.snapshot
            if condition(items) { return items }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("timed out waiting for the transfer queue")
        return await queue.snapshot
    }

    func testUpdatesStreamPublishesSnapshotsAndProgress() async throws {
        let fake = FakeTransfers(delay: .milliseconds(30))
        let queue = TransferQueue(service: fake, maxConcurrent: 1)
        await queue.enqueue(job("streamed"))
        var sawRunning = false
        for await items in queue.updates {
            if items.first?.state == .running { sawRunning = true }
            if items.first?.isDone == true { break }
        }
        XCTAssertTrue(sawRunning)
    }

    func testRespectsConcurrencyLimitAndFinishesEverything() async throws {
        let fake = FakeTransfers(delay: .milliseconds(80))
        let queue = TransferQueue(service: fake, maxConcurrent: 3)
        for index in 0..<7 { await queue.enqueue(job("f\(index)")) }
        let items = try await wait(for: queue) { $0.count == 7 && $0.allSatisfy(\.isDone) }
        XCTAssertTrue(items.allSatisfy { $0.state == .finished })
        XCTAssertEqual(fake.state.withLock { $0.maxRunning }, 3)
        XCTAssertEqual(items.first?.progress?.fraction, 1)
    }

    func testFailureIsRecordedWithoutStoppingOthers() async throws {
        let fake = FakeTransfers(delay: .milliseconds(20))
        let queue = TransferQueue(service: fake, maxConcurrent: 2)
        await queue.enqueue(job("ok1"))
        await queue.enqueue(job("bad"))
        await queue.enqueue(job("ok2"))
        let items = try await wait(for: queue) { $0.count == 3 && $0.allSatisfy(\.isDone) }
        XCTAssertEqual(items.filter { $0.state == .finished }.count, 2)
        guard case .failed(let message)? = items.first(where: { $0.job.name == "bad" })?.state else {
            return XCTFail("bad job should be failed")
        }
        XCTAssertTrue(message.contains("boom"))
    }

    func testCancelRunningJobFreesTheSlotForQueuedOnes() async throws {
        let fake = FakeTransfers(delay: .seconds(30))
        let queue = TransferQueue(service: fake, maxConcurrent: 1)
        let first = job("slow1")
        await queue.enqueue(first)
        await queue.enqueue(job("slow2"))
        _ = try await wait(for: queue) { $0.first?.state == .running }
        await queue.cancel(id: first.id)
        let items = try await wait(for: queue) {
            $0.first?.state == .cancelled && $0.count == 2 && $0[1].state == .running
        }
        XCTAssertEqual(items[0].state, .cancelled)
        await queue.cancelAll()
        _ = try await wait(for: queue) { $0.allSatisfy(\.isDone) }
    }

    func testCancelQueuedJobNeverStarts() async throws {
        let fake = FakeTransfers(delay: .milliseconds(200))
        let queue = TransferQueue(service: fake, maxConcurrent: 1)
        await queue.enqueue(job("a"))
        let b = job("b")
        await queue.enqueue(b)
        await queue.cancel(id: b.id)
        let items = try await wait(for: queue) { $0.count == 2 && $0.allSatisfy(\.isDone) }
        XCTAssertEqual(items[1].state, .cancelled)
        XCTAssertEqual(fake.state.withLock { $0.started }, ["/remote/a"])
    }

    func testClearFinishedRemovesDoneItemsOnly() async throws {
        let fake = FakeTransfers(delay: .milliseconds(10))
        let queue = TransferQueue(service: fake, maxConcurrent: 3)
        await queue.enqueue(job("x"))
        _ = try await wait(for: queue) { $0.count == 1 && $0.allSatisfy(\.isDone) }
        await queue.clearFinished()
        let remaining = await queue.snapshot
        XCTAssertTrue(remaining.isEmpty)
    }

    func testDownloadJobsUseTheDownloadPath() async throws {
        let fake = FakeTransfers(delay: .milliseconds(10))
        let queue = TransferQueue(service: fake, maxConcurrent: 1)
        let download = TransferJob(
            kind: .download, local: URL(fileURLWithPath: "/tmp/out.bin"), remote: "/remote/in.bin")
        await queue.enqueue(download)
        let items = try await wait(for: queue) { $0.count == 1 && $0.allSatisfy(\.isDone) }
        XCTAssertEqual(items[0].job.name, "in.bin")
        XCTAssertEqual(items[0].state, .finished)
    }
}

final class SFTPModelsTests: XCTestCase {
    func testPathJoinAndParent() {
        XCTAssertEqual(SFTPPath.join("/home/me", "a.txt"), "/home/me/a.txt")
        XCTAssertEqual(SFTPPath.join("/home/me/", "a.txt"), "/home/me/a.txt")
        XCTAssertEqual(SFTPPath.join("/", "etc"), "/etc")
        XCTAssertEqual(SFTPPath.parent(of: "/home/me/a.txt"), "/home/me")
        XCTAssertEqual(SFTPPath.parent(of: "/home"), "/")
        XCTAssertEqual(SFTPPath.parent(of: "/"), "/")
        XCTAssertEqual(SFTPPath.parent(of: "/home/me/"), "/home")
    }

    func testPermissionString() {
        XCTAssertEqual(RemoteFile(name: "a", path: "/a", permissions: 0o755).permissionString, "rwxr-xr-x")
        XCTAssertEqual(RemoteFile(name: "a", path: "/a", permissions: 0o600).permissionString, "rw-------")
        XCTAssertEqual(RemoteFile(name: "a", path: "/a", permissions: 0).permissionString, "---------")
    }

    func testProgressFraction() {
        XCTAssertEqual(TransferProgress(bytesTransferred: 25, totalBytes: 100).fraction, 0.25)
        XCTAssertNil(TransferProgress(bytesTransferred: 25, totalBytes: nil).fraction)
        XCTAssertNil(TransferProgress(bytesTransferred: 0, totalBytes: 0).fraction)
        XCTAssertEqual(TransferProgress(bytesTransferred: 200, totalBytes: 100).fraction, 1)
    }
}
