import Foundation
import Observation
import SSHCore

/// One tab: a host, its SSH connection (owned by the primary terminal), its panes, and the prompts
/// for its connection.
///
/// Panes: the tab starts with one pane (the primary terminal, which owns the session). Splitting adds
/// `ExtraPaneViewModel`s, each an independent shell channel on the same connection.
@MainActor
@Observable
final class SessionTab: Identifiable {
    /// Upper bound for panes in one tab (each is a shell channel).
    static let maxPanes = 8

    let id = UUID()
    let profile: HostProfile
    let terminal: TerminalViewModel
    let prompter: ConnectionPrompter
    /// File browser over this tab's SSH connection; opened lazily when first shown.
    let files: SFTPBrowserViewModel
    /// `true` while the tab shows the file browser instead of the terminal.
    var showsFiles = false
    /// History entry of the current connection (set by the workspace).
    var historyID: UUID?

    /// ID of the primary pane (the one backed by `terminal`).
    let primaryPaneID: UUID
    /// Pane layout tree.
    private(set) var root: PaneNode
    /// The pane that receives keyboard focus.
    var activePaneID: UUID
    /// Split panes by ID (the primary pane is not in here).
    private(set) var extraPanes: [UUID: ExtraPaneViewModel] = [:]
    /// Asks the workspace to close this tab (set by the workspace; used when the last pane ends).
    var onRequestClose: (@MainActor () -> Void)?

    init(
        profile: HostProfile, env: AppEnvironment, showsFiles: Bool = false,
        jumpChain: @escaping @MainActor () throws -> [HostProfile] = { [] }
    ) {
        let prompter = ConnectionPrompter()
        self.profile = profile
        self.prompter = prompter
        let terminal = TerminalViewModel(
            profile: profile,
            makeSession: { env.makeSession(prompts: prompter.sshPrompts) },
            jumpChain: jumpChain)
        terminal.makeLogger = { env.makeSessionLogger(for: profile) }
        self.terminal = terminal
        self.files = SFTPBrowserViewModel(terminal: terminal, env: env)
        self.showsFiles = showsFiles
        let primary = UUID()
        self.primaryPaneID = primary
        self.root = .terminal(primary)
        self.activePaneID = primary
        terminal.onShellEnded = { [weak self] in self?.primaryShellEnded() }
    }

    var paneCount: Int { root.leafIDs.count }

    /// Splitting needs a live connection and room for another pane.
    var canSplit: Bool { terminal.activeSession != nil && paneCount < Self.maxPanes }

    // MARK: - Splitting

    /// Splits the active pane; the new pane opens a new shell on the same SSH connection and gets focus.
    func split(_ axis: SplitAxis) {
        guard canSplit else { return }
        let pane = ExtraPaneViewModel(parent: terminal)
        extraPanes[pane.id] = pane
        pane.onEnded = { [weak self, id = pane.id] in self?.extraPaneEnded(id) }
        root = root.replacing(activePaneID, with: .split(axis, .terminal(activePaneID), .terminal(pane.id)))
        activePaneID = pane.id
        terminal.keepSessionWhenShellEnds = true
    }

    /// Closes pane `id` (only its shell channel). Returns `true` if it was the last pane, in which case
    /// the caller must close the whole tab.
    func closePane(_ id: UUID) -> Bool {
        guard paneCount > 1, let newRoot = root.removing(id) else { return true }
        root = newRoot
        if let extra = extraPanes.removeValue(forKey: id) {
            extra.onEnded = nil
            Task { await extra.close() }
        } else if id == primaryPaneID {
            let terminal = terminal
            Task { await terminal.closeShell() }
        }
        if activePaneID == id { activePaneID = root.leafIDs.first ?? primaryPaneID }
        // Back to a single primary pane: ending its shell may close the session again.
        if extraPanes.isEmpty, root.leafIDs == [primaryPaneID] { terminal.keepSessionWhenShellEnds = false }
        return false
    }

    /// Sends bytes (a snippet) to the focused pane, or to every pane of the tab.
    /// Only panes with an open shell take input; others ignore it.
    func send(_ bytes: [UInt8], toAll: Bool) {
        if toAll {
            terminal.send(bytes)
            for pane in extraPanes.values { pane.send(bytes) }
        } else if let extra = extraPanes[activePaneID] {
            extra.send(bytes)
        } else {
            terminal.send(bytes)
        }
    }

    /// `true` when the tab has a connected session that can take snippet input.
    var canReceiveSnippets: Bool { terminal.isShellOpen }

    /// Moves focus to the next (`step` = 1) or previous (`-1`) pane in layout order.
    func focusNext(by step: Int) {
        let ids = root.leafIDs
        guard ids.count > 1, let index = ids.firstIndex(of: activePaneID) else { return }
        activePaneID = ids[(index + step + ids.count) % ids.count]
    }

    /// Closes every extra shell (the tab is going away; the session itself is closed by the workspace).
    func shutdown() {
        for pane in extraPanes.values {
            pane.onEnded = nil
            Task { await pane.close() }
        }
        extraPanes = [:]
    }

    // MARK: - Private

    private func extraPaneEnded(_ id: UUID) {
        if closePane(id) { onRequestClose?() }
    }

    private func primaryShellEnded() {
        // With several panes the primary pane just disappears; a single pane keeps the usual
        // "session ended / reconnect" overlay.
        guard paneCount > 1 else { return }
        _ = closePane(primaryPaneID)
    }
}
