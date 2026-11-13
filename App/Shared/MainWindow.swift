import SwiftUI

/// Root window: new sidebar + tab workspace inside `MainContentView`, plus the sheets opened from them.
struct MainWindow: View {
    @Environment(AppEnvironment.self) private var env
    @Bindable var hostList: HostListViewModel
    @Bindable var workspace: WorkspaceViewModel
    @State private var ui = MainUIState()

    var body: some View {
        MainContentView(ui: ui) {
            SidebarView(ui: ui, hostList: hostList, workspace: workspace, env: env)
        } detail: {
            WorkspaceView(workspace: workspace, onAddHost: { hostList.editorRequest = .create })
        }
        // Each sheet view creates and owns its view model with @State, so re-rendering this body
        // never resets a form that is being edited.
        .sheet(item: $hostList.editorRequest) { request in
            HostEditorView(request: request, env: env)
        }
        .sheet(isPresented: $hostList.showKeyManager) {
            KeyManagerView(env: env)
        }
        .sheet(isPresented: $hostList.showKnownHosts) {
            KnownHostsView(env: env)
        }
        .sheet(item: $hostList.tunnelsRequest) { request in
            TunnelsView(env: env, hostList: hostList, workspace: workspace, hostFilter: request.hostFilter)
        }
        .sheet(isPresented: $workspace.showSnippets) {
            SnippetsView(env: env, workspace: workspace)
        }
        .sheet(isPresented: $workspace.showSnippetPicker) {
            SnippetPickerView(env: env, workspace: workspace)
        }
        .task {
            hostList.start()
            await env.reloadSettings()
            await hostList.reloadSSHConfig()
        }
    }
}
