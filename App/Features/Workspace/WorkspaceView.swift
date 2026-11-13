import SSHCore
import SwiftUI

/// Detail area: tab bar plus the sessions of all open tabs.
///
/// All tabs stay in the view hierarchy (only the selected one is visible) so terminals keep their
/// scrollback and keep receiving output while in the background.
struct WorkspaceView: View {
    @Environment(AppEnvironment.self) private var env
    @Bindable var workspace: WorkspaceViewModel
    /// Opens the "add host" editor (empty-state button).
    var onAddHost: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            if let warning = env.startupWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .font(.callout)
                    .frame(maxWidth: .infinity)
                    .padding(Theme.Spacing.sm)
                    .background(.orange.opacity(0.2))
            }
            if !workspace.tabs.isEmpty { TabBarView(workspace: workspace) }
            ZStack {
                ForEach(workspace.tabs) { tab in
                    let selected = tab.id == workspace.selectedTabID
                    SessionView(tab: tab, workspace: workspace, isActive: selected)
                        .opacity(selected ? 1 : 0)
                        .allowsHitTesting(selected)
                        .accessibilityHidden(!selected)
                }
                if workspace.tabs.isEmpty { EmptyWorkspaceView(onAddHost: onAddHost) }
            }
        }
        .confirmationDialog(
            String(localized: "Close this tab?"),
            isPresented: Binding(
                get: { workspace.closeCandidateID != nil },
                set: { if !$0 { workspace.cancelClose() } }),
            titleVisibility: .visible
        ) {
            Button(String(localized: "Close Tab"), role: .destructive) { workspace.confirmClose() }
            Button(String(localized: "Cancel"), role: .cancel) { workspace.cancelClose() }
        } message: {
            Text("The SSH session is still connected and will be disconnected.")
        }
    }
}

/// Welcome state shown when no tab is open.
private struct EmptyWorkspaceView: View {
    let onAddHost: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(String(localized: "No Open Sessions"), systemImage: "terminal")
                .symbolRenderingMode(.hierarchical)
        } description: {
            Text("Double-click a host in the sidebar, or select one and press ⌘T.")
        } actions: {
            Button(String(localized: "Add Host"), systemImage: "plus", action: onAddHost)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }
}
