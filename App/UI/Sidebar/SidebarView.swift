import SSHCore
import SwiftUI

/// Sidebar: section switcher, search, the active list, config banner, footer actions.
struct SidebarView: View {
    @Bindable var ui: MainUIState
    @Bindable var hostList: HostListViewModel
    let workspace: WorkspaceViewModel
    @State private var snippets: SnippetsViewModel

    init(ui: MainUIState, hostList: HostListViewModel, workspace: WorkspaceViewModel, env: AppEnvironment) {
        self.ui = ui
        self.hostList = hostList
        self.workspace = workspace
        _snippets = State(initialValue: SnippetsViewModel(env: env, workspace: workspace))
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.sm) {
            SidebarSectionPicker(selection: $ui.sidebarSection)
                .padding(.top, Theme.Spacing.sm)
            if ui.sidebarSection != .recent {
                SidebarSearchField(text: searchText, prompt: searchPrompt)
            }
            Group {
                switch ui.sidebarSection {
                case .hosts: HostsListView(hostList: hostList, workspace: workspace)
                case .recent: RecentListView(hostList: hostList, workspace: workspace)
                case .snippets: SnippetsListView(model: snippets, workspace: workspace)
                }
            }
            SidebarConfigBanner(hostList: hostList)
            SidebarFooter(hostList: hostList)
        }
        .background(.regularMaterial)
        .task { snippets.start() }
        .sheet(item: $hostList.groupPrompt) { prompt in
            GroupNameSheet(prompt: prompt) { name in
                Task {
                    switch prompt {
                    case .create(let hostIDs): await hostList.createGroup(named: name, moving: hostIDs)
                    case .rename(let group): await hostList.renameGroup(group, to: name)
                    }
                }
            }
        }
        .confirmationDialog(
            String(localized: "Delete this host?"),
            isPresented: Binding(
                get: { hostList.hostPendingDelete != nil },
                set: { if !$0 { hostList.hostPendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: hostList.hostPendingDelete
        ) { host in
            Button(String(localized: "Delete \(host.name)"), role: .destructive) {
                Task { await hostList.delete(host) }
            }
        } message: { _ in
            Text("Its saved password will also be removed from the Keychain.")
        }
        .alert(
            String(localized: "Error"),
            isPresented: Binding(
                get: { hostList.errorMessage != nil },
                set: { if !$0 { hostList.errorMessage = nil } })
        ) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(hostList.errorMessage ?? "")
        }
    }

    private var searchText: Binding<String> {
        switch ui.sidebarSection {
        case .snippets: Binding(get: { snippets.search }, set: { snippets.search = $0 })
        case .hosts, .recent: Binding(get: { hostList.searchText }, set: { hostList.searchText = $0 })
        }
    }

    private var searchPrompt: String {
        ui.sidebarSection == .snippets ? String(localized: "Search snippets") : String(localized: "Search hosts")
    }
}
