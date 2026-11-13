import Foundation
import os

/// Writes one session's terminal output to `logs/<host>/<date>.log` as plain text (ANSI removed).
///
/// `log(_:)` never blocks: bytes are queued on an `AsyncStream` (which keeps their order) and a single
/// background task strips and writes them. Writing stops, with a notice line, once `maxBytes` is reached.
/// Logs may contain sensitive output; the UI must make logging opt-in and say so.
public final class SessionLogger: Sendable {
    private let continuation: AsyncStream<[UInt8]>.Continuation
    private let task: Task<Void, Never>
    /// File being written.
    public let fileURL: URL

    /// Opens the log file (creating folders) and starts the writer task.
    /// - Parameters:
    ///   - root: The `logs` folder (`AppPaths.logsDirectory`).
    ///   - hostName: Used for the sub-folder name (sanitised).
    ///   - maxBytes: Size cap for the file.
    ///   - now: Start time, used for the file name.
    /// - Throws: `PersistenceError.io` if the file cannot be created.
    public init(root: URL, hostName: String, maxBytes: Int, now: Date = Date()) throws {
        let folder = root.appendingPathComponent(Self.sanitize(hostName), isDirectory: true)
        let url = folder.appendingPathComponent(Self.fileName(for: now))
        let writer: LogFileWriter
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            writer = try LogFileWriter(url: url, maxBytes: maxBytes)
        } catch {
            throw PersistenceError.io(error.localizedDescription)
        }
        let (stream, continuation) = AsyncStream.makeStream(of: [UInt8].self, bufferingPolicy: .unbounded)
        self.continuation = continuation
        self.fileURL = url
        self.task = Task {
            for await chunk in stream { await writer.append(chunk) }
            await writer.close()
        }
    }

    /// Queues terminal output for logging. Safe to call from any context; returns immediately.
    public func log(_ bytes: [UInt8]) {
        continuation.yield(bytes)
    }

    /// Stops accepting output and waits until everything queued is written and the file is closed.
    public func finish() async {
        continuation.finish()
        await task.value
    }

    /// Deletes `*.log` files older than `days` days under `root`, and empty host folders.
    /// - Returns: Number of files removed.
    @discardableResult
    public static func purge(root: URL, olderThanDays days: Int, now: Date = Date()) -> Int {
        let fileManager = FileManager.default
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        var removed = 0
        guard
            let folders = try? fileManager.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil)
        else { return 0 }
        for folder in folders {
            let files = (try? fileManager.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files where file.pathExtension == "log" {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
                if let modified, modified < cutoff, (try? fileManager.removeItem(at: file)) != nil {
                    removed += 1
                }
            }
            if ((try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? ["x"]).isEmpty {
                try? fileManager.removeItem(at: folder)
            }
        }
        return removed
    }

    /// Folder-safe version of a host name: letters, digits, `.`, `-`, `_`; everything else becomes `_`.
    static func sanitize(_ name: String) -> String {
        let cleaned = String(
            name.unicodeScalars.map { scalar -> Character in
                CharacterSet.alphanumerics.contains(scalar) || "._-".unicodeScalars.contains(scalar)
                    ? Character(scalar) : "_"
            })
        let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return trimmed.isEmpty ? "host" : trimmed
    }

    static func fileName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: date) + ".log"
    }
}

/// Serialises file writes; owns the (non-`Sendable`) `FileHandle`.
private actor LogFileWriter {
    private let handle: FileHandle
    private let maxBytes: Int
    private var written = 0
    private var stripper = ANSIStripper()
    private var capped = false
    private let logger = Logger(subsystem: "SSHCore", category: "SessionLogger")

    init(url: URL, maxBytes: Int) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else { throw PersistenceError.io("Could not create the log file.") }
        self.handle = try FileHandle(forWritingTo: url)
        self.maxBytes = maxBytes
    }

    func append(_ chunk: [UInt8]) {
        guard !capped else { return }
        var text = stripper.feed(chunk)
        guard !text.isEmpty else { return }
        if written + text.count > maxBytes {
            text = Array(text.prefix(max(0, maxBytes - written)))
            text.append(contentsOf: Array("\n[log truncated: size limit reached]\n".utf8))
            capped = true
        }
        do {
            try handle.write(contentsOf: Data(text))
            written += text.count
        } catch {
            capped = true  // stop on I/O errors instead of retrying on every chunk
            logger.error("Log write failed")
        }
    }

    func close() {
        try? handle.close()
    }
}
