import Citadel
import Foundation

/// One entry of a remote directory listing.
public struct RemoteFile: Sendable, Hashable, Identifiable {
    public var name: String
    /// Absolute remote path.
    public var path: String
    public var size: UInt64
    /// POSIX permission bits (e.g. `0o644`), without the file-type bits.
    public var permissions: UInt32
    public var modified: Date?
    public var isDirectory: Bool
    public var isSymlink: Bool

    public var id: String { path }

    public init(
        name: String, path: String, size: UInt64 = 0, permissions: UInt32 = 0, modified: Date? = nil,
        isDirectory: Bool = false, isSymlink: Bool = false
    ) {
        self.name = name
        self.path = path
        self.size = size
        self.permissions = permissions
        self.modified = modified
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
    }

    /// `rwxr-xr-x` style string for the permission bits.
    public var permissionString: String {
        let flags = "rwxrwxrwx"
        return String(
            flags.enumerated().map { index, character in
                permissions & (1 << UInt32(8 - index)) != 0 ? character : "-"
            })
    }

    /// Builds an entry from a Citadel listing component.
    static func from(directory: String, component: SFTPPathComponent) -> RemoteFile {
        let mode = component.attributes.permissions ?? 0
        let type = mode & 0o170000
        return RemoteFile(
            name: component.filename,
            path: SFTPPath.join(directory, component.filename),
            size: component.attributes.size ?? 0,
            permissions: mode & 0o7777,
            modified: component.attributes.accessModificationTime?.modificationTime,
            isDirectory: type == 0o040000,
            isSymlink: type == 0o120000)
    }
}

/// Progress of one transfer. `totalBytes` is `nil` when the size is unknown.
public struct TransferProgress: Sendable, Equatable {
    public var bytesTransferred: UInt64
    public var totalBytes: UInt64?

    public init(bytesTransferred: UInt64, totalBytes: UInt64?) {
        self.bytesTransferred = bytesTransferred
        self.totalBytes = totalBytes
    }

    /// 0…1, or `nil` when the total is unknown.
    public var fraction: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, Double(bytesTransferred) / Double(totalBytes))
    }
}

/// Remote path helpers (always `/`-separated, independent of the local OS).
public enum SFTPPath {
    /// Joins a directory and a name with exactly one `/`.
    public static func join(_ directory: String, _ name: String) -> String {
        if directory.isEmpty { return name }
        return directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    /// The parent directory (`/` stays `/`).
    public static func parent(of path: String) -> String {
        guard path != "/" else { return "/" }
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let slash = trimmed.lastIndex(of: "/") else { return "." }
        let parent = String(trimmed[..<slash])
        return parent.isEmpty ? "/" : parent
    }
}

/// SFTP failures with user-readable messages.
public enum SFTPServiceError: LocalizedError, Sendable, Equatable {
    case failed(String)
    case notFound(String)
    case permissionDenied(String)

    public var errorDescription: String? {
        switch self {
        case .failed(let message): return String(localized: "SFTP error: \(message)")
        case .notFound(let path): return String(localized: "Not found: \(path)")
        case .permissionDenied(let path): return String(localized: "Permission denied: \(path)")
        }
    }

    /// Maps Citadel/NIO errors; cancellation is passed through untouched.
    static func map(_ error: Error, path: String = "") -> Error {
        if error is CancellationError || error is SFTPServiceError || error is SSHError { return error }
        // Citadel reports non-OK statuses either wrapped in `SFTPError.errorStatus` or as the bare status.
        var status = error as? SFTPMessage.Status
        if case SFTPError.errorStatus(let wrapped) = error { status = wrapped }
        if let status {
            switch status.errorCode {
            case .noSuchFile: return SFTPServiceError.notFound(path)
            case .permissionDenied: return SFTPServiceError.permissionDenied(path)
            default: return SFTPServiceError.failed(status.message.isEmpty ? "\(status.errorCode)" : status.message)
            }
        }
        return SFTPServiceError.failed(error.localizedDescription)
    }
}
