import Foundation
import Observation
import SSHCore

/// Owns the open tabs and tab operations (open, close, reorder, duplicate, select).
@MainActor
@Observable
final class WorkspaceViewModel {
    private(set) var tabs: [SessionTab] = []
    var selectedTabID: UUID?
    /// Tab awaiting close confirmation (drives the confirmation dialog).
    var closeCandidateID: UUID?
    /// Drives the snippets manager sheet.
    var showSnippets = false
    /// Drives the ⌘⇧P quick snippet picker sheet.
    var showSnippetPicker = false

    private let env: AppEnvironment
    private let hostList: HostListViewModel

    /// Creates the workspace.
    init(env: AppEnvironment, hostList: HostListViewModel) {
        self.env = env
        self.hostList = hostList
    }

    /// The selected tab.
    var selectedTab: SessionTab? {
        tabs.first { $0.id == selectedTabID }
    }

    /// Live connection state of an open tab for this host (for the sidebar status dot).
    func liveState(for hostID: UUID) -> ConnectionState? {
        tabs.first { $0.profile.id == hostID && $0.terminal.state.isActive }?.terminal.state
    }

    /// `true` if a host is selected in the sidebar (⌘T is enabled).
    var canOpenSelectedHost: Bool {
        hostList.selectedHost != nil
    }

    /// Opens a new tab for `profile`, selects it, and starts connecting.
    @discardableResult
    func openTab(for profile: HostProfile, showFiles: Bool = false) -> SessionTab {
        let tab = SessionTab(
            profile: profile, env: env, showsFiles: showFiles,
            jumpChain: { [hostList] in try hostList.jumpChain(for: profile) })
        tab.onRequestClose = { [weak self, id = tab.id] in self?.close(id) }
        tabs.append(tab)
        selectedTabID = tab.id
        let terminal = tab.terminal
        let hostList = hostList
        let env = env
        let history = env.historyService
        Task {
            await terminal.connect()
            if terminal.state == .connected {
                tab.historyID = try? await history.begin(hostID: profile.id, hostName: profile.name)
                await hostList.markConnected(profile)
                let saved = (try? await env.tunnels.all()) ?? []
                await env.tunnelRunner.autoStart(saved.filter { $0.hostID == profile.id }, in: tab)
            } else if case .failed = terminal.state {
                try? await history.recordAttempt(hostID: profile.id, hostName: profile.name, outcome: .failed)
            }
        }
        return tab
    }

    /// ⌘T: new tab for the host selected in the sidebar.
    func openTabForSelectedHost() {
        guard let host = hostList.selectedHost else { return }
        openTab(for: host)
    }

    /// Opens another tab to the same host.
    func duplicateTab(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        openTab(for: tab.profile)
    }

    /// Closes the tab, asking first if its session is still connected.
    func requestClose(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        if tab.terminal.state.isActive {
            closeCandidateID = id
        } else {
            close(id)
        }
    }

    /// ⌘W: closes the active pane when the tab is split, otherwise the tab (after confirmation).
    func requestCloseSelected() {
        guard let tab = selectedTab else { return }
        if tab.paneCount > 1 {
            _ = tab.closePane(tab.activePaneID)
        } else {
            requestClose(tab.id)
        }
    }

    /// ⌘D / ⇧⌘D: splits the active pane of the selected tab.
    func splitSelected(_ axis: SplitAxis) {
        selectedTab?.split(axis)
    }

    /// ⌘⌥←→↑↓: moves pane focus in the selected tab.
    func moveFocus(by step: Int) {
        selectedTab?.focusNext(by: step)
    }

    /// `true` if the selected tab can be split right now.
    var canSplitSelected: Bool {
        selectedTab?.canSplit ?? false
    }

    /// Confirms the pending close.
    func confirmClose() {
        if let id = closeCandidateID { close(id) }
        closeCandidateID = nil
    }

    /// Cancels the pending close.
    func cancelClose() {
        closeCandidateID = nil
    }

    /// Reorders: moves `id` to just before `target`.
    func moveTab(_ id: UUID, before target: UUID) {
        guard id != target, let from = tabs.firstIndex(where: { $0.id == id }),
            let to = tabs.firstIndex(where: { $0.id == target })
        else { return }
        let tab = tabs.remove(at: from)
        let destination = from < to ? to - 1 : to
        tabs.insert(tab, at: destination)
    }

    /// Selects the tab at a zero-based index (⌘1…⌘9); ⌘9-style "last tab" is not special-cased.
    func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        selectedTabID = tabs[index].id
    }

    /// ⌃Tab.
    func selectNext() {
        cycleSelection(by: 1)
    }

    /// ⌃⇧Tab.
    func selectPrevious() {
        cycleSelection(by: -1)
    }

    // MARK: - Private

    private func close(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: index)
        tab.prompter.cancelCurrent()
        tab.shutdown()
        // Disconnect only this tab's session.
        let terminal = tab.terminal
        let runner = env.tunnelRunner
        let tabID = tab.id
        let history = env.historyService
        let historyID = tab.historyID
        Task {
            if let historyID { try? await history.finish(historyID, outcome: .completed) }
            await runner.stopAll(tabID: tabID)  // tunnels live on this tab's connection
            await terminal.disconnect()
        }
        if selectedTabID == id {
            selectedTabID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
        }
    }

    private func cycleSelection(by step: Int) {
        guard !tabs.isEmpty else { return }
        let current = tabs.firstIndex { $0.id == selectedTabID } ?? 0
        let next = (current + step + tabs.count) % tabs.count
        selectedTabID = tabs[next].id
    }
}
