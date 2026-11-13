import Foundation

/// Something that can run transfers (`SFTPServiceActor`; a fake in tests).
public protocol SFTPTransferring: Sendable {
    func upload(local: URL, remote: String) -> AsyncThrowingStream<TransferProgress, Error>
    func download(remote: String, local: URL) -> AsyncThrowingStream<TransferProgress, Error>
}

/// A queued upload or download.
public struct TransferJob: Sendable, Identifiable, Equatable {
    public enum Kind: Sendable, Equatable { case upload, download }

    public let id: UUID
    public let kind: Kind
    public let local: URL
    public let remote: String

    public init(id: UUID = UUID(), kind: Kind, local: URL, remote: String) {
        self.id = id
        self.kind = kind
        self.local = local
        self.remote = remote
    }

    /// Display name (the file name).
    public var name: String {
        kind == .upload ? local.lastPathComponent : (remote as NSString).lastPathComponent
    }
}

/// A job plus its live state, as published by `TransferQueue`.
public struct TransferItem: Sendable, Identifiable, Equatable {
    public enum State: Sendable, Equatable {
        case queued, running, finished, cancelled
        case failed(String)
    }

    public let job: TransferJob
    public var state: State
    public var progress: TransferProgress?
    /// Average bytes per second while running or after finishing.
    public var bytesPerSecond: Double?

    public var id: UUID { job.id }

    /// `true` once the item will not change any more.
    public var isDone: Bool {
        switch state {
        case .queued, .running: false
        case .finished, .cancelled, .failed: true
        }
    }
}

/// Runs transfers through an `SFTPServiceActor` with a concurrency cap (default 3).
///
/// Observers consume `updates` (full snapshots, newest wins). Single consumer.
public actor TransferQueue {
    public nonisolated let updates: AsyncStream<[TransferItem]>

    private let continuation: AsyncStream<[TransferItem]>.Continuation
    private let service: any SFTPTransferring
    private let maxConcurrent: Int
    private var items: [TransferItem] = []
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var startDates: [UUID: Date] = [:]

    /// Creates a queue.
    /// - Parameter maxConcurrent: Maximum simultaneous transfers (at least 1).
    public init(service: any SFTPTransferring, maxConcurrent: Int = 3) {
        self.service = service
        self.maxConcurrent = max(1, maxConcurrent)
        let (stream, continuation) = AsyncStream.makeStream(
            of: [TransferItem].self, bufferingPolicy: .bufferingNewest(1))
        self.updates = stream
        self.continuation = continuation
        continuation.yield([])
    }

    deinit {
        continuation.finish()
    }

    /// Adds a job; it starts as soon as a slot is free.
    public func enqueue(_ job: TransferJob) {
        items.append(TransferItem(job: job, state: .queued))
        pump()
    }

    /// Cancels a queued or running job (partial files are removed by the service).
    public func cancel(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        switch items[index].state {
        case .queued:
            items[index].state = .cancelled
            publish()
        case .running:
            tasks[id]?.cancel()
        default:
            break
        }
    }

    /// Cancels everything that is not finished yet.
    public func cancelAll() {
        for item in items where !item.isDone { cancel(id: item.id) }
    }

    /// Removes finished, failed and cancelled entries from the list.
    public func clearFinished() {
        items.removeAll { $0.isDone }
        publish()
    }

    /// Current snapshot (mostly for tests).
    public var snapshot: [TransferItem] { items }

    // MARK: - Private

    private func pump() {
        var free = maxConcurrent - items.filter { $0.state == .running }.count
        for index in items.indices where free > 0 && items[index].state == .queued {
            items[index].state = .running
            free -= 1
            let job = items[index].job
            startDates[job.id] = Date()
            tasks[job.id] = Task { await self.run(job) }
        }
        publish()
    }

    private func run(_ job: TransferJob) async {
        let stream =
            job.kind == .upload
            ? service.upload(local: job.local, remote: job.remote)
            : service.download(remote: job.remote, local: job.local)
        do {
            for try await progress in stream {
                update(job.id) { $0.progress = progress }
            }
            finish(job.id, cancelled ? .cancelled : .finished)
        } catch {
            finish(job.id, .failed(error.localizedDescription))
        }
    }

    private var cancelled: Bool { Task.isCancelled }

    private func update(_ id: UUID, _ change: (inout TransferItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
        if let progress = items[index].progress, let start = startDates[id] {
            let elapsed = Date().timeIntervalSince(start)
            if elapsed > 0.2 { items[index].bytesPerSecond = Double(progress.bytesTransferred) / elapsed }
        }
        publish()
    }

    private func finish(_ id: UUID, _ state: TransferItem.State) {
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].state = state
        }
        tasks[id] = nil
        startDates[id] = nil
        pump()
    }

    private func publish() {
        continuation.yield(items)
    }
}
