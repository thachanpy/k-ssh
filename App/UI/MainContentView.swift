import SwiftUI

/// Outermost layout: a collapsible native sidebar and the detail (tabs) area.
///
/// The sidebar and detail are injected so this view only owns the window chrome. That lets the
/// real `SidebarView` / `WorkspaceView` plug in later, and previews use placeholders today.
struct MainContentView<Sidebar: View, Detail: View>: View {
    @Bindable var ui: MainUIState
    @ViewBuilder let sidebar: () -> Sidebar
    @ViewBuilder let detail: () -> Detail

    var body: some View {
        NavigationSplitView(columnVisibility: $ui.columnVisibility) {
            sidebar()
                // Native sidebar vibrancy comes from the .sidebar list style inside; the column
                // only needs sensible widths.
                .navigationSplitViewColumnWidth(
                    min: Theme.Layout.sidebarMin, ideal: Theme.Layout.sidebarIdeal,
                    max: Theme.Layout.sidebarMax)
        } detail: {
            detail()
                .background(.background)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: Theme.Layout.windowMinWidth, minHeight: Theme.Layout.windowMinHeight)
    }
}

// MARK: - Preview

#Preview("Main window") {
    MainContentView(ui: MainUIState()) {
        PlaceholderSidebar()
    } detail: {
        PlaceholderDetail()
    }
    .frame(width: 1100, height: 700)
}

/// Stand-ins used only until the real sidebar and workspace are built (next steps).
private struct PlaceholderSidebar: View {
    var body: some View {
        List {
            Section("Hosts") {
                ForEach(["prod-web", "staging-db", "home-nas"], id: \.self) { name in
                    Label(name, systemImage: "server.rack")
                        .symbolRenderingMode(.hierarchical)
                }
            }
        }
        .listStyle(.sidebar)
    }
}

private struct PlaceholderDetail: View {
    var body: some View {
        ContentUnavailableView(
            "No Open Sessions", systemImage: "terminal",
            description: Text("Pick a host in the sidebar to connect."))
    }
}
