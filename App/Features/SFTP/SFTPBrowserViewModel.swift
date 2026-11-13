import Foundation
import Observation
import SSHCore

/// Drives the two-pane file browser of one session tab: remote listing over SFTP, local listing in a
/// user-granted folder, and the transfer queue.
///
/// The SFTP channel is opened lazily on the tab's existing SSH connection (`TerminalViewModel.openSFTP`).
@MainActor
@Observable
final class SFTPBrowserViewModel {
    enum Phase: Equatable {
        case waiting, connecting, ready
        case failed(String)
    }

    private(set) var phase: Phase = .waiting
    private(set) var remotePath = ""
    private(set) var remoteFiles: [RemoteFile] = []
    private(set) var localURL: URL?
    private(set) var localFiles: [LocalFile] = []
    private(set) var transfers: [TransferItem] = []
    var showHidden = false {
        didSet { Task { await refreshAll() } }
    }
    var remoteSelection = Set<String>()
    var localSelection = Set<URL>()
    var errorMessage: String?
    /// Items awaiting delete confirmation / rename input (drive dialogs in the view).
    var deleteCandidates: [RemoteFile] = []
    var renameCandidate: RemoteFile?

    private let terminal: TerminalViewModel
    private let env: AppEnvironment
    private let tasks = TaskBag()
    private var sftp: SFTPServiceActor?
    private var queue: TransferQueue?
    private var localAccess: ScopedFolderAccess?
    private var localRoot: URL?
    private var seenDone = Set<UUID>()

    init(terminal: TerminalViewModel, env: AppEnvironment) {
        self.terminal = terminal
        self.env = env
    }

    /// Remote entries honoring the hidden-files toggle.
    var visibleRemote: [RemoteFile] {
        showHidden ? remoteFiles : remoteFiles.filter { !$0.name.hasPrefix(".") }
    }

    var canGoUpRemote: Bool { remotePath != "/" && !remotePath.isEmpty }
    var canGoUpLocal: Bool {
        guard let localURL, let localRoot else { return false }
        return localURL.standardizedFileURL.path != localRoot.standardizedFileURL.path
    }

    // MARK: - Lifecycle

    /// Opens SFTP when the terminal is connected and the browser is not ready yet.
    func openIfNeeded() async {
        guard terminal.state == .connected else {
            if phase == .ready { reset() }
            return
        }
        guard phase == .waiting || isFailed else { return }
        phase = .connecting
        do {
            let service = try await terminal.openSFTP()
            sftp = service
            let transferQueue = TransferQueue(service: service)
            queue = transferQueue
            observe(transferQueue)
            remotePath = try await service.homeDirectory()
            restoreLocalFolder()
            await refreshAll()
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Drops the SFTP channel (the connection went away).
    func reset() {
        let oldQueue = queue
        let oldSFTP = sftp
        sftp = nil
        queue = nil
        phase = .waiting
        remoteFiles = []
        Task {
            await oldQueue?.cancelAll()
            await oldSFTP?.close()
        }
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    // MARK: - Remote pane

    func refreshRemote() async {
        guard let sftp else { return }
        do {
            remoteFiles = try await sftp.list(remotePath)
            remoteSelection = remoteSelection.filter { id in remoteFiles.contains { $0.id == id } }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func goRemote(to path: String) async {
        guard let sftp else { return }
        do {
            remotePath = try await sftp.realpath(path)
            remoteSelection = []
            await refreshRemote()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func openRemote(_ file: RemoteFile) async {
        if file.isDirectory { await goRemote(to: file.path) }
    }

    func goUpRemote() async {
        await goRemote(to: SFTPPath.parent(of: remotePath))
    }

    func makeRemoteFolder(named name: String) async {
        guard let sftp, !name.isEmpty else { return }
        do {
            try await sftp.mkdir(SFTPPath.join(remotePath, name))
            await refreshRemote()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func rename(_ file: RemoteFile, to newName: String) async {
        guard let sftp, !newName.isEmpty, newName != file.name else { return }
        do {
            try await sftp.rename(from: file.path, to: SFTPPath.join(SFTPPath.parent(of: file.path), newName))
            await refreshRemote()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteConfirmed() async {
        guard let sftp else { return }
        let items = deleteCandidates
        deleteCandidates = []
        for item in items {
            do {
                try await sftp.remove(item.path, isDirectory: item.isDirectory && !item.isSymlink)
            } catch {
                errorMessage = error.localizedDescription
                break
            }
        }
        await refreshRemote()
    }

    // MARK: - Local pane

    func refreshLocal() {
        guard let localURL else {
            localFiles = []
            return
        }
        do {
            localFiles = try LocalFile.list(localURL, showHidden: showHidden)
        } catch {
            localFiles = []
            errorMessage = error.localizedDescription
        }
    }

    /// Lets the user pick the local folder and remembers it (bookmark in settings).
    func chooseLocalFolder() async {
        guard let url = FilePanels.chooseFolder(message: String(localized: "Choose a local folder for transfers"))
        else { return }
        do {
            let bookmark = try await env.bookmarks.makeBookmark(for: url)
            await env.updateSettings { $0.lastLocalFolderBookmark = bookmark }
            useLocalFolder(url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func openLocal(_ file: LocalFile) {
        guard file.isDirectory else { return }
        localURL = file.url
        localSelection = []
        refreshLocal()
    }

    func goUpLocal() {
        guard canGoUpLocal, let localURL else { return }
        self.localURL = localURL.deletingLastPathComponent()
        localSelection = []
        refreshLocal()
    }

    func makeLocalFolder(named name: String) {
        guard let localURL, !name.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(
                at: localURL.appendingPathComponent(name), withIntermediateDirectories: false)
            refreshLocal()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func trashLocal(_ files: [LocalFile]) {
        for file in files {
            do {
                try FileManager.default.trashItem(at: file.url, resultingItemURL: nil)
            } catch {
                errorMessage = error.localizedDescription
                break
            }
        }
        refreshLocal()
    }

    // MARK: - Transfers

    /// Uploads files/folders (from the local pane or dropped from Finder) into the current remote folder.
    func upload(_ urls: [URL]) async {
        guard let sftp, let queue else { return }
        for url in urls {
            do {
                try await enqueueUpload(url, to: remotePath, sftp: sftp, queue: queue)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Downloads remote files/folders into the current local folder.
    func download(_ files: [RemoteFile]) async {
        guard let sftp, let queue else { return }
        guard let localURL else {
            errorMessage = String(localized: "Choose a local folder first.")
            return
        }
        for file in files {
            do {
                try await enqueueDownload(file, into: localURL, sftp: sftp, queue: queue)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func cancelTransfer(_ id: UUID) {
        guard let queue else { return }
        Task { await queue.cancel(id: id) }
    }

    func clearFinishedTransfers() {
        guard let queue else { return }
        Task { await queue.clearFinished() }
    }

    /// Payload used for dragging remote items onto the local pane.
    static let dragPrefix = "sftp-remote:"

    func dragPayload(for file: RemoteFile) -> String {
        let selected = remoteSelection.contains(file.id) ? visibleRemote.filter { remoteSelection.contains($0.id) } : [file]
        return Self.dragPrefix + selected.map(\.path).joined(separator: "\n")
    }

    /// Handles a string dropped on the local pane (a remote drag).
    func handleRemoteDrop(_ payload: String) async {
        guard payload.hasPrefix(Self.dragPrefix) else { return }
        let paths = Set(payload.dropFirst(Self.dragPrefix.count).split(separator: "\n").map(String.init))
        await download(remoteFiles.filter { paths.contains($0.path) })
    }

    // MARK: - Private

    private func refreshAll() async {
        await refreshRemote()
        refreshLocal()
    }

    private func restoreLocalFolder() {
        guard localURL == nil, let bookmark = env.settings.lastLocalFolderBookmark else { return }
        var stale = false
        guard
            let url = try? URL(
                resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil,
                bookmarkDataIsStale: &stale),
            !stale
        else {
            Task { await env.updateSettings { $0.lastLocalFolderBookmark = nil } }
            return
        }
        useLocalFolder(url)
    }

    private func useLocalFolder(_ url: URL) {
        localAccess = ScopedFolderAccess(url: url)
        localRoot = url
        localURL = url
        localSelection = []
        refreshLocal()
    }

    private func observe(_ queue: TransferQueue) {
        let stream = queue.updates
        tasks.add(
            Task { [weak self] in
                for await items in stream {
                    guard let self else { return }
                    self.apply(items)
                }
            })
    }

    private func apply(_ items: [TransferItem]) {
        transfers = items
        let newlyDone = items.filter { $0.isDone && !seenDone.contains($0.id) }
        guard !newlyDone.isEmpty else { return }
        seenDone.formUnion(newlyDone.map(\.id))
        if newlyDone.contains(where: { $0.job.kind == .upload }) { Task { await refreshRemote() } }
        if newlyDone.contains(where: { $0.job.kind == .download }) { refreshLocal() }
        if let failed = newlyDone.first(where: { if case .failed = $0.state { true } else { false } }),
            case .failed(let message) = failed.state
        {
            errorMessage = "\(failed.job.name): \(message)"
        }
    }

    private func enqueueUpload(_ url: URL, to remoteDirectory: String, sftp: SFTPServiceActor, queue: TransferQueue)
        async throws
    {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let remote = SFTPPath.join(remoteDirectory, url.lastPathComponent)
        if isDirectory {
            if try await sftp.stat(remote) == nil { try await sftp.mkdir(remote) }
            let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            for child in children { try await enqueueUpload(child, to: remote, sftp: sftp, queue: queue) }
        } else {
            await queue.enqueue(TransferJob(kind: .upload, local: url, remote: remote))
        }
    }

    private func enqueueDownload(
        _ file: RemoteFile, into directory: URL, sftp: SFTPServiceActor, queue: TransferQueue
    ) async throws {
        let local = directory.appendingPathComponent(file.name)
        if file.isDirectory && !file.isSymlink {
            try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
            for child in try await sftp.list(file.path) {
                try await enqueueDownload(child, into: local, sftp: sftp, queue: queue)
            }
        } else {
            await queue.enqueue(TransferJob(kind: .download, local: local, remote: file.path))
        }
    }
}
