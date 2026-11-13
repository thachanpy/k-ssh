import Citadel
import Foundation
import NIOCore

/// SFTP operations over an existing SSH connection (`SSHSessionActor.openSFTP()`).
///
/// Concurrency: an actor around Citadel's `Sendable` `SFTPClient`. Transfers run in their own tasks
/// and report through `AsyncThrowingStream`; cancelling the stream's consumer cancels the transfer and
/// removes the partial file (the remote one for uploads, `<name>.part` for downloads).
public actor SFTPServiceActor: SFTPTransferring {
    /// Transfer chunk size (128 KiB: large enough for throughput, small enough for responsive progress).
    static let chunkSize = 128 * 1024

    private let client: SFTPClient

    init(client: SFTPClient) {
        self.client = client
    }

    /// Closes the SFTP channel (the SSH connection stays open).
    public func close() async {
        try? await client.close()
    }

    // MARK: - Metadata operations

    /// Home directory of the remote user (SFTP's initial directory).
    public func homeDirectory() async throws -> String {
        try await realpath(".")
    }

    /// Canonical absolute path. `"~"` resolves to the home directory.
    public func realpath(_ path: String) async throws -> String {
        let input = (path == "~" || path.isEmpty) ? "." : path
        do {
            return try await client.getRealPath(atPath: input)
        } catch {
            throw SFTPServiceError.map(error, path: path)
        }
    }

    /// Lists a directory, folders first then by name (case-insensitive); `.`/`..` are omitted.
    public func list(_ path: String) async throws -> [RemoteFile] {
        do {
            let directory = try await client.getRealPath(atPath: path == "~" ? "." : path)
            let names = try await client.listDirectory(atPath: directory)
            let files =
                names
                .flatMap(\.components)
                .filter { $0.filename != "." && $0.filename != ".." }
                .map { RemoteFile.from(directory: directory, component: $0) }
            return files.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        } catch {
            throw SFTPServiceError.map(error, path: path)
        }
    }

    /// Attributes of `path` (following symlinks), or `nil` if it does not exist.
    public func stat(_ path: String) async throws -> RemoteFile? {
        do {
            let attributes = try await client.getAttributes(at: path)
            let component = SFTPPathComponent(
                filename: (path as NSString).lastPathComponent, longname: "", attributes: attributes)
            return RemoteFile.from(directory: SFTPPath.parent(of: path), component: component)
        } catch {
            if case SFTPServiceError.notFound = SFTPServiceError.map(error, path: path) { return nil }
            throw SFTPServiceError.map(error, path: path)
        }
    }

    /// Creates a directory.
    public func mkdir(_ path: String) async throws {
        do {
            try await client.createDirectory(atPath: path)
        } catch {
            throw SFTPServiceError.map(error, path: path)
        }
    }

    /// Renames or moves a file or directory.
    public func rename(from oldPath: String, to newPath: String) async throws {
        do {
            try await client.rename(at: oldPath, to: newPath)
        } catch {
            throw SFTPServiceError.map(error, path: oldPath)
        }
    }

    /// Removes a file, or a directory and everything in it when `recursive` is `true`.
    /// Symlinks are removed, never followed.
    public func remove(_ path: String, isDirectory: Bool, recursive: Bool = true) async throws {
        do {
            if isDirectory {
                if recursive {
                    for child in try await list(path) {
                        try Task.checkCancellation()
                        try await remove(child.path, isDirectory: child.isDirectory && !child.isSymlink)
                    }
                }
                try await client.rmdir(at: path)
            } else {
                try await client.remove(at: path)
            }
        } catch {
            throw SFTPServiceError.map(error, path: path)
        }
    }

    // MARK: - Transfers

    /// Uploads a local file, replacing `remote`. The stream finishes after the last chunk is written.
    public nonisolated func upload(local: URL, remote: String) -> AsyncThrowingStream<TransferProgress, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.performUpload(local: local, remote: remote, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: SFTPServiceError.map(error, path: remote))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Downloads `remote` to `local` (written to `<local>.part`, then moved into place).
    public nonisolated func download(remote: String, local: URL) -> AsyncThrowingStream<TransferProgress, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.performDownload(remote: remote, local: local, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: SFTPServiceError.map(error, path: remote))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // `nonisolated`: Citadel's `SFTPFile` is not `Sendable`, so it must never cross into the actor.
    private nonisolated func performUpload(
        local: URL, remote: String, continuation: AsyncThrowingStream<TransferProgress, Error>.Continuation
    ) async throws {
        let input = try FileHandle(forReadingFrom: local)
        defer { try? input.close() }
        let size = (try FileManager.default.attributesOfItem(atPath: local.path)[.size] as? NSNumber)?.uint64Value

        let file = try await client.openFile(filePath: remote, flags: [.write, .create, .truncate])
        var offset: UInt64 = 0
        do {
            while true {
                try Task.checkCancellation()
                guard let chunk = try input.read(upToCount: Self.chunkSize), !chunk.isEmpty else { break }
                try await file.write(ByteBuffer(bytes: chunk), at: offset)
                offset += UInt64(chunk.count)
                continuation.yield(TransferProgress(bytesTransferred: offset, totalBytes: size))
            }
            try await file.close()
            if offset == 0 { continuation.yield(TransferProgress(bytesTransferred: 0, totalBytes: 0)) }
        } catch {
            try? await file.close()
            try? await client.remove(at: remote)  // never leave a partial remote file
            throw error
        }
    }

    private nonisolated func performDownload(
        remote: String, local: URL, continuation: AsyncThrowingStream<TransferProgress, Error>.Continuation
    ) async throws {
        let partial = local.deletingLastPathComponent().appendingPathComponent(local.lastPathComponent + ".part")
        guard FileManager.default.createFile(atPath: partial.path, contents: nil) else {
            throw SFTPServiceError.failed(String(localized: "Cannot create the local file."))
        }
        let output: FileHandle
        do {
            output = try FileHandle(forWritingTo: partial)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }

        let file: SFTPFile
        do {
            file = try await client.openFile(filePath: remote, flags: .read)
        } catch {
            try? output.close()
            try? FileManager.default.removeItem(at: partial)
            throw error
        }

        do {
            let total = try? await file.readAttributes().size
            var offset: UInt64 = 0
            while true {
                try Task.checkCancellation()
                let buffer = try await file.read(from: offset, length: UInt32(Self.chunkSize))
                if buffer.readableBytes == 0 { break }
                try output.write(contentsOf: Data(buffer.readableBytesView))
                offset += UInt64(buffer.readableBytes)
                continuation.yield(TransferProgress(bytesTransferred: offset, totalBytes: total))
            }
            try await file.close()
            try output.close()
            if FileManager.default.fileExists(atPath: local.path) {
                try FileManager.default.removeItem(at: local)
            }
            try FileManager.default.moveItem(at: partial, to: local)
            if offset == 0 { continuation.yield(TransferProgress(bytesTransferred: 0, totalBytes: 0)) }
        } catch {
            try? await file.close()
            try? output.close()
            try? FileManager.default.removeItem(at: partial)  // never leave a partial local file
            throw error
        }
    }
}
