import Foundation
import Observation
import SSHCore

/// Dependency container wired once at launch and injected with `.environment(...)`.
///
/// Holds the concrete stores/services from `SSHCore`; ViewModels receive what they need from here.
@MainActor
@Observable
final class AppEnvironment {
    let hosts: HostRepository
    let keys: KeyRepository
    let tunnels: TunnelRepository
    let snippets: SnippetRepository
    let history: HistoryRepository
    /// Sidebar folders and host assignments (`groups.json`).
    let groups: GroupRepository
    /// Records connection history (`history.json`).
    let historyService: HistoryService
    /// Where store files and logs live.
    let paths: AppPaths
    /// Runtime registry of running tunnels (not persisted).
    let tunnelRunner = TunnelRunner()
    let knownHosts: KnownHostsStore
    let settingsRepository: SettingsRepository
    let keychain: any KeychainProviding
    let bookmarks: BookmarkService

    /// Loaded settings snapshot (terminal font etc.). Updated via `reloadSettings()`.
    private(set) var settings = AppSettings()
    /// Set when persistent storage could not be opened and a temporary location is used instead.
    let startupWarning: String?

    /// Creates an environment rooted at `paths` with the given keychain (injectable for tests).
    init(paths: AppPaths, keychain: any KeychainProviding, startupWarning: String? = nil) {
        self.keychain = keychain
        self.bookmarks = BookmarkService()
        self.hosts = HostRepository(
            store: JSONStore(url: paths.fileURL(.hosts), defaultValue: []), keychain: keychain)
        self.keys = KeyRepository(store: JSONStore(url: paths.fileURL(.keys), defaultValue: []))
        self.tunnels = TunnelRepository(store: JSONStore(url: paths.fileURL(.tunnels), defaultValue: []))
        self.snippets = SnippetRepository(store: JSONStore(url: paths.fileURL(.snippets), defaultValue: []))
        let historyRepository = HistoryRepository(
            store: JSONStore(url: paths.fileURL(.history), defaultValue: []))
        self.history = historyRepository
        self.groups = GroupRepository(
            store: JSONStore(url: paths.fileURL(.groups), defaultValue: GroupsState()))
        self.historyService = HistoryService(repository: historyRepository)
        self.paths = paths
        self.knownHosts = KnownHostsStore(store: JSONStore(url: paths.fileURL(.knownHosts), defaultValue: []))
        self.settingsRepository = SettingsRepository(
            store: JSONStore(url: paths.fileURL(.settings), defaultValue: AppSettings()))
        self.startupWarning = startupWarning
    }

    /// Production environment: Application Support + the real Keychain.
    /// Falls back to a temporary directory (with a warning) if Application Support is unavailable.
    static func live() -> AppEnvironment {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.kairo.SSHClient"
        let keychain = KeychainService(service: KeychainService.defaultService(bundleID: bundleID))
        do {
            return AppEnvironment(paths: try AppPaths.applicationSupport(bundleID: bundleID), keychain: keychain)
        } catch {
            let fallback = AppPaths(
                baseURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("SSHClient-\(UUID().uuidString)", isDirectory: true))
            return AppEnvironment(
                paths: fallback, keychain: keychain,
                startupWarning: String(
                    localized: "Could not open the data folder. Changes will not be kept after quitting."))
        }
    }

    /// Loads settings from disk into `settings`.
    func reloadSettings() async {
        if let loaded = try? await settingsRepository.get() {
            settings = loaded
        }
    }

    /// Atomically changes settings on disk and refreshes the `settings` snapshot.
    func updateSettings(_ transform: @Sendable (inout AppSettings) -> Void) async {
        if let updated = try? await settingsRepository.update(transform) {
            settings = updated
        }
    }

    /// `true` if the user turned output logging on for this host.
    func isLogging(hostID: UUID) -> Bool {
        settings.loggedHostIDs?.contains(hostID) == true
    }

    /// A transcript logger for `host` when logging is enabled for it, otherwise `nil`.
    /// Also removes transcripts older than the retention setting (default 30 days).
    func makeSessionLogger(for host: HostProfile) -> SessionLogger? {
        guard isLogging(hostID: host.id) else { return nil }
        let root = paths.logsDirectory
        SessionLogger.purge(root: root, olderThanDays: settings.logRetentionDays ?? 30)
        return try? SessionLogger(
            root: root, hostName: host.name, maxBytes: settings.logMaxBytes ?? 10_000_000)
    }

    /// Reader for `~/.ssh/config` (hosts are merged in memory, never persisted).
    var sshConfigImporter: SSHConfigImporter {
        SSHConfigImporter(bookmarks: bookmarks, keys: keys)
    }

    /// Creates a fresh single-use SSH session using the given UI prompts.
    func makeSession(prompts: SSHPrompts) -> SSHSessionActor {
        SSHSessionActor(
            keychain: keychain, bookmarks: bookmarks, keys: keys, knownHosts: knownHosts, prompts: prompts,
            keepAliveSeconds: Int32(clamping: settings.keepAliveSeconds ?? 30))
    }
}
