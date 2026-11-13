import SSHCore
import SwiftUI

/// Application entry point: builds the environment and the long-lived view models.
@main
struct SSHClientApp: App {
    @State private var env: AppEnvironment
    @State private var hostList: HostListViewModel
    @State private var workspace: WorkspaceViewModel

    init() {
        let env = AppEnvironment.live()
        let hostList = HostListViewModel(env: env)
        _env = State(initialValue: env)
        _hostList = State(initialValue: hostList)
        _workspace = State(initialValue: WorkspaceViewModel(env: env, hostList: hostList))
    }

    var body: some Scene {
        WindowGroup {
            MainWindow(hostList: hostList, workspace: workspace)
                .environment(env)
        }
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            WorkspaceCommands(workspace: workspace)
        }
        Settings {
            SettingsView(env: env, hostList: hostList)
                .environment(env)
        }
    }
}
