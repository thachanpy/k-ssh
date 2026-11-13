import SSHCore
import SwiftUI

/// Custom in-window tab bar (ADR 0005): status dot, title, close on hover, drag to reorder,
/// middle-click to close, "+" for a new tab.
struct TabBarView: View {
    let workspace: WorkspaceViewModel

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Spacing.xs) {
                    ForEach(workspace.tabs) { tab in
                        TabItemView(tab: tab, workspace: workspace)
                    }
                }
                .padding(.horizontal, Theme.Spacing.sm)
            }
            ToolbarIconButton(
                symbol: "plus", help: String(localized: "New tab for the selected host (⌘T)")
            ) {
                workspace.openTabForSelectedHost()
            }
            .disabled(!workspace.canOpenSelectedHost)
            .padding(.horizontal, Theme.Spacing.sm)
        }
        .frame(height: Theme.Layout.tabBarHeight)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// One tab in the bar.
private struct TabItemView: View {
    let tab: SessionTab
    let workspace: WorkspaceViewModel
    @State private var hovering = false

    private var isSelected: Bool { workspace.selectedTabID == tab.id }

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            StatusDot(state: tab.terminal.state)
            Text(tab.terminal.title)
                .font(.callout)
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
                .frame(maxWidth: Theme.Layout.tabMaxWidth, alignment: .leading)
            Button {
                workspace.requestClose(tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(hovering || isSelected ? 1 : 0)
            .help(String(localized: "Close tab (⌘W)"))
            .accessibilityLabel(String(localized: "Close tab"))
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.xs)
        .background(background)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { workspace.selectedTabID = tab.id }
        .onMiddleClick { workspace.requestClose(tab.id) }
        .draggable(tab.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first, let dragged = UUID(uuidString: raw) else { return false }
            workspace.moveTab(dragged, before: tab.id)
            return true
        }
        .contextMenu {
            Button(String(localized: "Duplicate Tab"), systemImage: "plus.square.on.square") {
                workspace.duplicateTab(tab.id)
            }
            Button(String(localized: "Close Tab"), systemImage: "xmark") { workspace.requestClose(tab.id) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.small)
        if isSelected {
            shape.fill(.background).shadow(radius: 1, y: 1)
        } else if hovering {
            shape.fill(.quaternary)
        } else {
            shape.fill(.clear)
        }
    }
}

extension ConnectionState {
    /// Color of status dots.
    var statusColor: Color {
        switch self {
        case .connected: .green
        case .connecting, .awaitingHostKeyApproval: .orange
        case .failed: .red
        case .idle, .disconnected: .gray
        }
    }

    /// Short VoiceOver/tooltip description of the state.
    var statusDescription: String {
        switch self {
        case .idle: String(localized: "Not connected")
        case .connecting: String(localized: "Connecting")
        case .awaitingHostKeyApproval: String(localized: "Waiting for host key approval")
        case .connected: String(localized: "Connected")
        case .disconnected: String(localized: "Disconnected")
        case .failed: String(localized: "Connection failed")
        }
    }
}
