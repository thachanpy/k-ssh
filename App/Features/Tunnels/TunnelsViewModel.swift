import Foundation
import Observation
import SSHCore

/// What the tunnel editor sheet should do.
enum TunnelEditorRequest: Identifiable {
    case create
    case edit(TunnelConfig)

    var id: String {
        switch self {
        case .create: "create"
        case .edit(let config): "edit-\(config.id)"
        }
    }
}

/// CRUD for saved tunnels plus start/stop on the connected tab of the tunnel's host.
@MainActor
@Observable
final class TunnelsViewModel {
    private(set) var tunnels: [TunnelConfig] = []
    var editor: TunnelEditorRequest?
    var errorMessage: String?
    /// Limits the list to one host (opened from a host's context menu); `nil` shows all.
    let hostFilter: UUID?

    private let env: AppEnvironment
    private let hostList: HostListViewModel
    private let workspace: WorkspaceViewModel

    init(env: AppEnvironment, hostList: HostListViewModel, workspace: WorkspaceViewModel, hostFilter: UUID?) {
        self.env = env
        self.hostList = hostList
        self.workspace = workspace
        self.hostFilter = hostFilter
    }

    var runner: TunnelRunner { env.tunnelRunner }
    /// Hosts a tunnel can be attached to (own and `~/.ssh/config` hosts).
    var hosts: [HostProfile] { hostList.hosts }

    /// Saved tunnels, optionally limited to `hostFilter`.
    var visibleTunnels: [TunnelConfig] {
        tunnels.filter { hostFilter == nil || $0.hostID == hostFilter }
    }

    func hostName(_ id: UUID) -> String {
        hostList.host(id: id)?.name ?? String(localized: "Unknown host")
    }

    /// A connected tab for the tunnel's host, if any (tunnels run on an existing session).
    func connectedTab(for config: TunnelConfig) -> SessionTab? {
        workspace.tabs.first { $0.profile.id == config.hostID && $0.terminal.activeSession != nil }
    }

    func load() async {
        tunnels = (try? await env.tunnels.all()) ?? []
    }

    func save(_ config: TunnelConfig) async {
        do {
            try await env.tunnels.upsert(config)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ config: TunnelConfig) async {
        await env.tunnelRunner.stop(config.id)
        do {
            try await env.tunnels.delete(id: config.id)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Starts or stops a tunnel.
    func toggle(_ config: TunnelConfig) async {
        if env.tunnelRunner.isRunning(config.id) {
            await env.tunnelRunner.stop(config.id)
        } else if let tab = connectedTab(for: config) {
            await env.tunnelRunner.start(config, in: tab)
        } else {
            errorMessage = String(localized: "Open a connected session to this host first, then start the tunnel.")
        }
    }
}

/// Validation shared by the editor and its tests.
enum TunnelValidation {
    /// Problems with a tunnel definition (empty when valid).
    static func errors(
        kind: TunnelKind, bindHost: String, bindPort: Int?, targetHost: String, targetPort: Int?
    ) -> [String] {
        var result: [String] = []
        if bindHost.trimmingCharacters(in: .whitespaces).isEmpty {
            result.append(String(localized: "Bind address is required."))
        }
        let minimumBind = kind == .remote ? 0 : 1  // port 0 lets the server choose for -R
        if let bindPort {
            if !(minimumBind...65535).contains(bindPort) {
                result.append(String(localized: "Bind port must be between \(minimumBind) and 65535."))
            }
        } else {
            result.append(String(localized: "Bind port must be a number."))
        }
        if targetHost.trimmingCharacters(in: .whitespaces).isEmpty {
            result.append(String(localized: "Target host is required."))
        }
        if let targetPort {
            if !(1...65535).contains(targetPort) {
                result.append(String(localized: "Target port must be between 1 and 65535."))
            }
        } else {
            result.append(String(localized: "Target port must be a number."))
        }
        return result
    }
}
