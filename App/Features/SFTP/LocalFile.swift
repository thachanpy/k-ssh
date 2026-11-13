import Foundation

/// One entry of the local pane.
struct LocalFile: Identifiable, Hashable {
    let url: URL
    let size: Int64
    let modified: Date?
    let isDirectory: Bool

    var id: URL { url }
    var name: String { url.lastPathComponent }

    /// Lists `directory`, folders first then by name; optionally hides dot-files.
    static func list(_ directory: URL, showHidden: Bool) throws -> [LocalFile] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys,
            options: showHidden ? [] : [.skipsHiddenFiles])
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return LocalFile(
                url: url, size: Int64(values?.fileSize ?? 0), modified: values?.contentModificationDate,
                isDirectory: values?.isDirectory ?? false)
        }.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}

/// Holds security-scoped access to a folder for as long as the object lives.
final class ScopedFolderAccess: Sendable {
    let url: URL
    private let started: Bool

    init(url: URL) {
        self.url = url
        self.started = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if started { url.stopAccessingSecurityScopedResource() }
    }
}
