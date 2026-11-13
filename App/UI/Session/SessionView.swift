import SSHCore
import SwiftUI

/// One tab: a slim toolbar and a split of terminal panes | optional SFTP file browser.
///
/// Both stay alive while the tab is open (the terminal keeps its scrollback even when the file browser
/// is hidden or the tab is in the background).
struct SessionView: View {
    @Bindable var tab: SessionTab
    let workspace: WorkspaceViewModel
    let isActive: Bool

    var body: some View {
        VStack(spacing: 0) {
            SessionToolbar(tab: tab, workspace: workspace)
            Divider()
            HSplitView {
                PaneTreeView(tab: tab, node: tab.root, isTabActive: isActive)
                    .frame(minWidth: Theme.Layout.terminalMinWidth)
                if tab.showsFiles {
                    SFTPBrowserView(model: tab.files, state: tab.terminal.state)
                        .frame(minWidth: Theme.Layout.sftpMinWidth, idealWidth: Theme.Layout.sftpIdealWidth)
                        .background(.background)
                }
            }
        }
    }
}

/// Connection summary on the left, pane/snippet/file actions on the right.
struct SessionToolbar: View {
    @Bindable var tab: SessionTab
    let workspace: WorkspaceViewModel

    private var state: ConnectionState { tab.terminal.state }

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            // The tab bar above already shows the name and status dot; only add the address here.
            Image(systemName: "network")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
            Text("\(tab.profile.username)@\(tab.profile.hostname)")
                .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            if state != .connected { statePill }
            Spacer()
            if !state.isActive {
                ToolbarIconButton(symbol: "arrow.clockwise", help: String(localized: "Reconnect")) {
                    let terminal = tab.terminal
                    Task { await terminal.reconnect() }
                }
            }
            ToolbarIconButton(symbol: "rectangle.split.2x1", help: String(localized: "Split Right (⌘D)")) {
                tab.split(.horizontal)
            }
            .disabled(!tab.canSplit)
            ToolbarIconButton(symbol: "rectangle.split.1x2", help: String(localized: "Split Down (⇧⌘D)")) {
                tab.split(.vertical)
            }
            .disabled(!tab.canSplit)
            ToolbarIconButton(symbol: "chevron.left.forwardslash.chevron.right", help: String(localized: "Run Snippet (⇧⌘P)")) {
                workspace.showSnippetPicker = true
            }
            .disabled(!tab.canReceiveSnippets)
            Divider().frame(height: Theme.Spacing.lg)
            Toggle(isOn: $tab.showsFiles) {
                Label(String(localized: "Files"), systemImage: "sidebar.right")
                    .symbolRenderingMode(.hierarchical)
            }
            .toggleStyle(.button)
            .labelStyle(.iconOnly)
            .help(tab.showsFiles ? String(localized: "Hide file browser") : String(localized: "Show file browser"))
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.xs)
        .background(.bar)
    }

    private var statePill: some View {
        Text(state.statusDescription)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.xxs)
            .background(.quaternary, in: Capsule())
    }
}
