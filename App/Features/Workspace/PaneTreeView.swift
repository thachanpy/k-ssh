import SSHCore
import SwiftUI

/// Renders a tab's pane tree recursively with `HSplitView` / `VSplitView`.
struct PaneTreeView: View {
    let tab: SessionTab
    let node: PaneNode
    /// `true` when the tab is selected and showing terminals (not files).
    let isTabActive: Bool

    var body: some View {
        switch node {
        case .terminal(let id):
            leaf(id)
        case .split(let axis, let first, let second):
            if axis == .horizontal {
                HSplitView {
                    PaneTreeView(tab: tab, node: first, isTabActive: isTabActive)
                    PaneTreeView(tab: tab, node: second, isTabActive: isTabActive)
                }
            } else {
                VSplitView {
                    PaneTreeView(tab: tab, node: first, isTabActive: isTabActive)
                    PaneTreeView(tab: tab, node: second, isTabActive: isTabActive)
                }
            }
        }
    }

    @ViewBuilder
    private func leaf(_ id: UUID) -> some View {
        let isActivePane = tab.activePaneID == id
        let focus: @MainActor () -> Void = { tab.activePaneID = id }
        Group {
            if id == tab.primaryPaneID {
                TerminalPaneView(tab: tab, isActive: isTabActive && isActivePane, onFocus: focus)
            } else if let pane = tab.extraPanes[id] {
                ExtraTerminalPaneView(
                    pane: pane, parent: tab.terminal, isActive: isTabActive && isActivePane, onFocus: focus)
            }
        }
        .frame(minWidth: 120, minHeight: 80)
        .overlay {
            // Focus ring, only meaningful when there is more than one pane.
            if tab.paneCount > 1 && isActivePane {
                RoundedRectangle(cornerRadius: 2)
                    .stroke(Color.accentColor.opacity(0.8), lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// A split pane: its own shell on the tab's SSH connection, with a status overlay.
struct ExtraTerminalPaneView: View {
    @Environment(AppEnvironment.self) private var env
    let pane: ExtraPaneViewModel
    let parent: TerminalViewModel
    let isActive: Bool
    let onFocus: @MainActor () -> Void

    private var connected: Bool { parent.activeSession != nil }

    var body: some View {
        ZStack {
            TerminalHostView(
                viewModel: pane, appearance: TerminalAppearance(settings: env.settings),
                isActive: isActive && pane.phase == .open, onFocus: onFocus)
            overlay
        }
        // Opens the shell once the connection is up (and again after a reconnect).
        .task(id: connected) {
            if connected { await pane.open() }
        }
    }

    @ViewBuilder
    private var overlay: some View {
        if !connected {
            statusCard(
                icon: "network.slash", title: String(localized: "Waiting for the connection"), detail: nil,
                action: nil)
        } else {
            switch pane.phase {
            case .open:
                EmptyView()
            case .opening:
                ZStack {
                    Rectangle().fill(.background.opacity(0.85))
                    ProgressView(String(localized: "Opening shell…"))
                }
            case .ended:
                statusCard(
                    icon: "terminal", title: String(localized: "Shell ended"), detail: nil,
                    action: (String(localized: "Reopen"), { Task { await pane.open() } }))
            case .failed(let message):
                statusCard(
                    icon: "exclamationmark.triangle", title: String(localized: "Could not open a shell"),
                    detail: message, action: (String(localized: "Retry"), { Task { await pane.open() } }))
            }
        }
    }

    private func statusCard(
        icon: String, title: String, detail: String?, action: (String, () -> Void)?
    ) -> some View {
        ZStack {
            Rectangle().fill(.background.opacity(0.85))
            VStack(spacing: 10) {
                Image(systemName: icon).font(.title).foregroundStyle(.secondary)
                Text(title).font(.headline)
                if let detail { Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                if let action { Button(action.0, action: action.1) }
            }
            .padding()
        }
    }
}
