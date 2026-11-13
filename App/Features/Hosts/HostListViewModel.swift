import Foundation
import Observation
import SSHCore

/// What the host editor sheet should do.
enum HostEditorRequest: Identifiable {
    case create
    case edit(HostProfile)

    var id: String {
        switch self {
        case .create: "create"
        case .edit(let host): "edit-\(host.id)"
        }
    }
}

/// Naming dialog for groups.
enum GroupPrompt: Identifiable {
    case create(hostIDs: [UUID])
    case rename(HostGroup)

    var id: String {
        switch self {
        case .create: "create"
        case .rename(let group): "rename-\(group.id)"
        }
    }
}

/// One folder in the sidebar with its (filtered) hosts.
struct HostGroupSection: Identifiable {
    let group: HostGroup
    let hosts: [HostProfile]
    var id: UUID { group.id }
}

/// Opens the tunnels sheet, optionally limited to one host.
struct TunnelsSheetRequest: Identifiable {
    let id = UUID()
    let hostFilter: UUID?
}

/// Drives the hosts sidebar: list, search/tag filter, selection, and host actions.
@MainActor
@Observable
final class HostListViewModel {
    /// User-owned hosts from `hosts.json`.
    private(set) var storedHosts: [HostProfile] = []
    /// Hosts parsed from `~/.ssh/config`: in memory only, read-only.
    private(set) var configHosts: [HostProfile] = []
    /// Parser/import warnings from the last reload (shown in the sidebar menu).
    private(set) var configWarnings: [String] = []
    /// Shown when the config import failed (e.g. the folder bookmark went stale).
    private(set) var configError: String?
    /// User-owned hosts followed by `~/.ssh/config` hosts.
    var hosts: [HostProfile] { storedHosts + configHosts }

    /// Jump hosts (outermost first) for `host`, looked up among stored and ssh-config hosts.
    /// - Throws: `JumpChainError`.
    func jumpChain(for host: HostProfile) throws -> [HostProfile] {
        try JumpChain.resolve(for: host, hosts: hosts)
    }
    /// Sidebar folders in display order and which host is in which folder.
    private(set) var groupsState = GroupsState()
    /// Shown while naming or renaming a group.
    var groupPrompt: GroupPrompt?
    /// Last 10 connections, newest first.
    private(set) var recent: [HistoryEntry] = []
    var searchText = ""
    var selectedTag: String?
    var selection: UUID?
    /// Sheet/dialog state bound by the views.
    var editorRequest: HostEditorRequest?
    var showKeyManager = false
    var showKnownHosts = false
    /// Drives the tunnels sheet (`hostFilter == nil` lists every tunnel).
    var tunnelsRequest: TunnelsSheetRequest?
    var hostPendingDelete: HostProfile?
    var errorMessage: String?

    private let env: AppEnvironment
    private let tasks = TaskBag()
    private var started = false

    /// Creates the view model; call `start()` once to begin observing storage.
    init(env: AppEnvironment) {
        self.env = env
    }

    /// Starts observing the host repository (current list first, then every change).
    func start() {
        guard !started else { return }
        started = true
        let repository = env.hosts
        tasks.add(
            Task { [weak self] in
                let stream = await repository.changes()
                for await list in stream {
                    guard let self else { return }
                    self.storedHosts = list
                }
            })
        let groupRepository = env.groups
        tasks.add(
            Task { [weak self] in
                for await state in await groupRepository.changes() {
                    guard let self else { return }
                    self.groupsState = state
                }
            })
        let history = env.history
        tasks.add(
            Task { [weak self] in
                let stream = await history.changes()
                for await list in stream {
                    guard let self else { return }
                    self.recent = Self.latest(list, limit: 10)
                }
            })
        let service = env.historyService
        tasks.add(Task { _ = try? await service.closeStaleEntries() })
    }

    /// Newest `limit` entries, newest first.
    nonisolated static func latest(_ list: [HistoryEntry], limit: Int) -> [HistoryEntry] {
        Array(list.sorted { $0.startedAt > $1.startedAt }.prefix(limit))
    }

    /// The host a history entry refers to, if it still exists.
    func host(for entry: HistoryEntry) -> HostProfile? {
        hosts.first { $0.id == entry.hostID }
    }

    /// Removes all history entries.
    func clearHistory() async {
        do { try await env.historyService.clear() } catch { errorMessage = error.localizedDescription }
    }

    // MARK: - ~/.ssh/config

    /// `true` when importing is enabled but the user has not granted the `~/.ssh` folder yet.
    var needsSSHFolderGrant: Bool {
        env.settings.importSSHConfigEnabled && env.settings.sshFolderBookmark == nil
    }

    /// Whether the config import is switched on.
    var isConfigImportEnabled: Bool { env.settings.importSSHConfigEnabled }

    /// Re-reads `~/.ssh/config` (no-op when disabled or not granted). Keeps the last list on failure.
    func reloadSSHConfig() async {
        configError = nil
        guard env.settings.importSSHConfigEnabled else {
            configHosts = []
            configWarnings = []
            return
        }
        guard let bookmark = env.settings.sshFolderBookmark else { return }
        do {
            let result = try await env.sshConfigImporter.load(folderBookmark: bookmark)
            configHosts = result.hosts
            configWarnings = result.warnings
        } catch {
            configError =
                (error as? BookmarkError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Asks the user to pick `~/.ssh`, stores the bookmark, and imports.
    func grantSSHFolderAccess() async {
        guard let url = FilePanels.chooseSSHFolder() else { return }
        do {
            let bookmark = try await env.bookmarks.makeBookmark(for: url)
            await env.updateSettings { $0.sshFolderBookmark = bookmark }
            await reloadSSHConfig()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Turns the config import on or off (hosts disappear immediately when off).
    func setConfigImport(enabled: Bool) async {
        await env.updateSettings { $0.importSSHConfigEnabled = enabled }
        await reloadSSHConfig()
    }

    // MARK: - Groups

    /// Folders with their hosts (stored and ssh-config hosts alike). While searching or filtering by tag,
    /// folders without a match are hidden; otherwise empty folders stay visible as drop targets.
    var groupSections: [HostGroupSection] {
        let isFiltering = !searchText.trimmingCharacters(in: .whitespaces).isEmpty || selectedTag != nil
        let visible = filtered(hosts)
        return groupsState.groups.compactMap { group in
            let members = visible.filter { groupsState.groupID(of: $0.id) == group.id }
            return isFiltering && members.isEmpty ? nil : HostGroupSection(group: group, hosts: members)
        }
    }

    /// User-owned hosts that are in no folder.
    var ungroupedMyHosts: [HostProfile] {
        myHosts.filter { groupsState.groupID(of: $0.id) == nil }
    }

    /// ssh-config hosts that are in no folder.
    var ungroupedConfigHosts: [HostProfile] {
        sshConfigHosts.filter { groupsState.groupID(of: $0.id) == nil }
    }

    /// The folder a host is in, if any.
    func group(of host: HostProfile) -> HostGroup? {
        guard let id = groupsState.groupID(of: host.id) else { return nil }
        return groupsState.groups.first { $0.id == id }
    }

    /// Moves hosts into a folder (`nil` = out of any folder). Works for ssh-config hosts too.
    func move(hostIDs: [UUID], to groupID: UUID?) async {
        do { try await env.groups.assign(hostIDs: hostIDs, to: groupID) } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Creates a folder, optionally moving hosts into it right away.
    func createGroup(named name: String, moving hostIDs: [UUID] = []) async {
        do {
            let group = try await env.groups.createGroup(name: name)
            if !hostIDs.isEmpty { try await env.groups.assign(hostIDs: hostIDs, to: group.id) }
        } catch { errorMessage = error.localizedDescription }
    }

    /// Renames a folder.
    func renameGroup(_ group: HostGroup, to name: String) async {
        do { try await env.groups.renameGroup(id: group.id, to: name) } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Deletes a folder; its hosts become ungrouped.
    func deleteGroup(_ group: HostGroup) async {
        do { try await env.groups.deleteGroup(id: group.id) } catch { errorMessage = error.localizedDescription }
    }

    /// Moves a folder up or down in the list.
    func moveGroup(_ group: HostGroup, by offset: Int) async {
        do { try await env.groups.moveGroup(id: group.id, by: offset) } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Drag payload for a host row (prefixed so it is never confused with a tab drag).
    static func dragPayload(for host: HostProfile) -> String { "host:\(host.id.uuidString)" }

    /// Host IDs in dropped strings produced by `dragPayload(for:)`; other strings are ignored.
    nonisolated static func hostIDs(fromDrop items: [String]) -> [UUID] {
        items.compactMap { item in
            item.hasPrefix("host:") ? UUID(uuidString: String(item.dropFirst(5))) : nil
        }
    }

    /// User-owned hosts matching the search text and tag filter.
    var myHosts: [HostProfile] {
        filtered(storedHosts)
    }

    /// Hosts imported from `~/.ssh/config` (read-only) matching the search text and tag filter.
    var sshConfigHosts: [HostProfile] {
        filtered(configHosts)
    }

    /// Every tag in use, sorted.
    var allTags: [String] {
        Array(Set(hosts.flatMap(\.tags))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// The host selected in the sidebar.
    var selectedHost: HostProfile? {
        guard let selection else { return nil }
        return hosts.first { $0.id == selection }
    }

    /// Looks up a host by ID.
    func host(id: UUID) -> HostProfile? {
        hosts.first { $0.id == id }
    }

    /// Duplicates a host (new ID, "… copy"). The Keychain password is intentionally not copied.
    func duplicate(_ host: HostProfile) async {
        var copy = host
        copy.id = UUID()
        copy.name = String(localized: "\(host.name) copy")
        copy.source = .local
        copy.createdAt = Date()
        copy.lastConnectedAt = nil
        do {
            try await env.hosts.upsert(copy)
            selection = copy.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Deletes a host and its Keychain password.
    func delete(_ host: HostProfile) async {
        do {
            try await env.hosts.delete(id: host.id)
            try? await env.groups.forget(hostID: host.id)
            if selection == host.id { selection = nil }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Records a successful connection time (best effort).
    func markConnected(_ host: HostProfile) async {
        guard var stored = try? await env.hosts.get(host.id) else { return }
        stored.lastConnectedAt = Date()
        _ = try? await env.hosts.upsert(stored)
    }

    // MARK: - Private

    private func filtered(_ list: [HostProfile]) -> [HostProfile] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        return list.filter { host in
            if let selectedTag, !host.tags.contains(selectedTag) { return false }
            guard !query.isEmpty else { return true }
            return host.name.localizedCaseInsensitiveContains(query)
                || host.hostname.localizedCaseInsensitiveContains(query)
                || host.username.localizedCaseInsensitiveContains(query)
                || host.tags.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }
}
