import SSHCore
import SwiftUI

/// Sheet listing saved tunnels with status, traffic and Start/Stop.
struct TunnelsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: TunnelsViewModel

    init(env: AppEnvironment, hostList: HostListViewModel, workspace: WorkspaceViewModel, hostFilter: UUID?) {
        _viewModel = State(
            initialValue: TunnelsViewModel(
                env: env, hostList: hostList, workspace: workspace, hostFilter: hostFilter))
    }

    var body: some View {
        @Bindable var model = viewModel
        VStack(spacing: 0) {
            if model.visibleTunnels.isEmpty {
                ContentUnavailableView(
                    String(localized: "No tunnels"), systemImage: "arrow.left.arrow.right",
                    description: Text("Add a port forward to reach a remote service through SSH."))
                    .frame(maxHeight: .infinity)
            } else {
                List(model.visibleTunnels) { config in
                    TunnelRow(
                        config: config, hostName: model.hostName(config.hostID),
                        running: model.runner.running[config.id], error: model.runner.errors[config.id],
                        canStart: model.connectedTab(for: config) != nil,
                        onToggle: { Task { await model.toggle(config) } },
                        onEdit: { model.editor = .edit(config) },
                        onDelete: { Task { await model.delete(config) } })
                }
            }
            Divider()
            HStack {
                Button(String(localized: "Add Tunnel…")) { model.editor = .create }
                Spacer()
                Button(String(localized: "Done")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 640, minHeight: 360)
        .task { await model.load() }
        .sheet(item: $model.editor) { request in
            TunnelEditorView(
                request: request, hosts: model.hosts, defaultHostID: model.hostFilter,
                onSave: { config in
                    model.editor = nil
                    Task { await model.save(config) }
                }, onCancel: { model.editor = nil })
        }
        .alert(
            String(localized: "Error"),
            isPresented: Binding(
                get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

private struct TunnelRow: View {
    let config: TunnelConfig
    let hostName: String
    let running: TunnelRunner.Running?
    let error: String?
    let canStart: Bool
    let onToggle: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: running == nil ? "circle" : "circle.fill")
                .foregroundStyle(running == nil ? Color.secondary : Color.green)
                .accessibilityLabel(running == nil ? String(localized: "Stopped") : String(localized: "Running"))
            VStack(alignment: .leading, spacing: 3) {
                Text(summary).font(.system(.body, design: .monospaced))
                Text("\(hostName) · \(config.kind == .local ? String(localized: "Local (-L)") : String(localized: "Remote (-R)"))\(config.autoStart ? " · " + String(localized: "auto-start") : "")")
                    .font(.caption).foregroundStyle(.secondary)
                if let running {
                    Text("\(running.stats.activeConnections) active · ↓ \(bytes(running.stats.bytesIn)) · ↑ \(bytes(running.stats.bytesOut))")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            Button(running == nil ? String(localized: "Start") : String(localized: "Stop"), action: onToggle)
                .disabled(running == nil && !canStart)
                .help(canStart || running != nil ? "" : String(localized: "Connect to this host in a tab first"))
            Button(action: onEdit) { Image(systemName: "pencil") }
                .accessibilityLabel(String(localized: "Edit tunnel"))
                .disabled(running != nil)
            Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                .accessibilityLabel(String(localized: "Delete tunnel"))
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 3)
    }

    private var summary: String {
        let bind = "\(config.bindHost):\(running?.boundPort ?? config.bindPort)"
        let target = "\(config.targetHost):\(config.targetPort)"
        return config.kind == .local ? "\(bind) → \(target)" : "\(target) ← \(bind)"
    }

    private func bytes(_ count: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}

/// Sheet to create or edit a tunnel.
struct TunnelEditorView: View {
    let request: TunnelEditorRequest
    let hosts: [HostProfile]
    let onSave: (TunnelConfig) -> Void
    let onCancel: () -> Void

    @State private var hostID: UUID?
    @State private var kind: TunnelKind
    @State private var bindHost: String
    @State private var bindPortText: String
    @State private var targetHost: String
    @State private var targetPortText: String
    @State private var autoStart: Bool
    private let existingID: UUID?

    init(
        request: TunnelEditorRequest, hosts: [HostProfile], defaultHostID: UUID?,
        onSave: @escaping (TunnelConfig) -> Void, onCancel: @escaping () -> Void
    ) {
        self.request = request
        self.hosts = hosts
        self.onSave = onSave
        self.onCancel = onCancel
        switch request {
        case .create:
            existingID = nil
            _hostID = State(initialValue: defaultHostID ?? hosts.first?.id)
            _kind = State(initialValue: .local)
            _bindHost = State(initialValue: "127.0.0.1")
            _bindPortText = State(initialValue: "")
            _targetHost = State(initialValue: "localhost")
            _targetPortText = State(initialValue: "")
            _autoStart = State(initialValue: false)
        case .edit(let config):
            existingID = config.id
            _hostID = State(initialValue: config.hostID)
            _kind = State(initialValue: config.kind)
            _bindHost = State(initialValue: config.bindHost)
            _bindPortText = State(initialValue: String(config.bindPort))
            _targetHost = State(initialValue: config.targetHost)
            _targetPortText = State(initialValue: String(config.targetPort))
            _autoStart = State(initialValue: config.autoStart)
        }
    }

    private var problems: [String] {
        TunnelValidation.errors(
            kind: kind, bindHost: bindHost, bindPort: Int(bindPortText), targetHost: targetHost,
            targetPort: Int(targetPortText))
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Picker(String(localized: "Host"), selection: $hostID) {
                    ForEach(hosts) { Text($0.name).tag(Optional($0.id)) }
                }
                Picker(String(localized: "Type"), selection: $kind) {
                    Text("Local (-L): listen on this Mac").tag(TunnelKind.local)
                    Text("Remote (-R): listen on the server").tag(TunnelKind.remote)
                }
                TextField(String(localized: "Bind address"), text: $bindHost)
                TextField(String(localized: "Bind port"), text: $bindPortText)
                TextField(String(localized: "Target host"), text: $targetHost)
                TextField(String(localized: "Target port"), text: $targetPortText)
                Toggle(String(localized: "Start automatically when the host connects"), isOn: $autoStart)
                ForEach(problems, id: \.self) { problem in
                    Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button(String(localized: "Cancel"), role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button(String(localized: "Save"), action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(hostID == nil || !problems.isEmpty)
            }
            .padding()
        }
        .frame(width: 480, height: 460)
    }

    private func save() {
        guard let hostID, problems.isEmpty, let bindPort = Int(bindPortText), let targetPort = Int(targetPortText)
        else { return }
        onSave(
            TunnelConfig(
                id: existingID ?? UUID(), hostID: hostID, kind: kind,
                bindHost: bindHost.trimmingCharacters(in: .whitespaces), bindPort: bindPort,
                targetHost: targetHost.trimmingCharacters(in: .whitespaces), targetPort: targetPort,
                autoStart: autoStart))
    }
}
