import SSHCore
import SwiftUI

/// Sidebar: searchable list of hosts in "My Hosts" / "SSH Config" sections with host actions.
struct HostsSidebarView: View {
    @Bindable var hostList: HostListViewModel
    let workspace: WorkspaceViewModel

    var body: some View {
        List(selection: $hostList.selection) {
            if !hostList.recent.isEmpty, hostList.searchText.isEmpty {
                Section {
                    ForEach(hostList.recent) { entry in
                        RecentRow(entry: entry, host: hostList.host(for: entry)) { host in
                            workspace.openTab(for: host)
                        }
                    }
                } header: {
                    HStack {
                        Text("Recent")
                        Spacer()
                        Button(String(localized: "Clear")) { Task { await hostList.clearHistory() } }
                            .buttonStyle(.link).font(.caption)
                            .accessibilityLabel(String(localized: "Clear recent connections"))
                    }
                }
            }
            Section(String(localized: "My Hosts")) {
                ForEach(hostList.myHosts) { host in
                    row(for: host)
                }
            }
            if !hostList.sshConfigHosts.isEmpty {
                Section(String(localized: "SSH Config")) {
                    ForEach(hostList.sshConfigHosts) { host in
                        row(for: host)
                    }
                }
            }
        }
        .searchable(text: $hostList.searchText, placement: .sidebar, prompt: String(localized: "Search hosts"))
        .overlay {
            if hostList.hosts.isEmpty {
                ContentUnavailableView(
                    String(localized: "No hosts yet"), systemImage: "server.rack",
                    description: Text("Click + to add your first host."))
            }
        }
        .safeAreaInset(edge: .bottom) { configBanner }
        .toolbar { toolbarContent }
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

    /// Onboarding / error strip for the `~/.ssh/config` import.
    @ViewBuilder
    private var configBanner: some View {
        if hostList.needsSSHFolderGrant {
            VStack(alignment: .leading, spacing: 6) {
                Text("Import hosts from ~/.ssh/config?").font(.callout.bold())
                Text("Grant read access to your ~/.ssh folder once. The config file is never modified.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(String(localized: "Grant Access…")) { Task { await hostList.grantSSHFolderAccess() } }
                    Button(String(localized: "Not Now")) { Task { await hostList.setConfigImport(enabled: false) } }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
        } else if let error = hostList.configError {
            VStack(alignment: .leading, spacing: 6) {
                Text(error).font(.caption).foregroundStyle(.red)
                Button(String(localized: "Re-grant Access…")) { Task { await hostList.grantSSHFolderAccess() } }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
        }
    }

    private func row(for host: HostProfile) -> some View {
        HostRow(host: host)
            .tag(host.id)
            .simultaneousGesture(TapGesture(count: 2).onEnded { workspace.openTab(for: host) })
            .contextMenu { contextMenu(for: host) }
    }

    @ViewBuilder
    private func contextMenu(for host: HostProfile) -> some View {
        let readOnly = host.source == .sshConfig
        Button(String(localized: "Connect")) { workspace.openTab(for: host) }
        Button(String(localized: "Open SFTP")) { workspace.openTab(for: host, showFiles: true) }
        Button(String(localized: "Tunnels…")) { hostList.tunnelsRequest = TunnelsSheetRequest(hostFilter: host.id) }
        Divider()
        Button(String(localized: "Edit…")) { hostList.editorRequest = .edit(host) }.disabled(readOnly)
        Button(readOnly ? String(localized: "Duplicate to My Hosts") : String(localized: "Duplicate")) {
            Task { await hostList.duplicate(host) }
        }
        Divider()
        Button(String(localized: "Delete…"), role: .destructive) { hostList.hostPendingDelete = host }
            .disabled(readOnly)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Menu {
                Button(String(localized: "All Tags")) { hostList.selectedTag = nil }
                ForEach(hostList.allTags, id: \.self) { tag in
                    Button(tag) { hostList.selectedTag = tag }
                }
            } label: {
                Label(
                    hostList.selectedTag ?? String(localized: "Tags"),
                    systemImage: "tag")
            }
            .disabled(hostList.allTags.isEmpty)
            Menu {
                Toggle(
                    String(localized: "Import ~/.ssh/config"),
                    isOn: Binding(
                        get: { hostList.isConfigImportEnabled },
                        set: { value in Task { await hostList.setConfigImport(enabled: value) } }))
                Button(String(localized: "Reload SSH Config")) { Task { await hostList.reloadSSHConfig() } }
                Button(String(localized: "Choose ~/.ssh Folder…")) {
                    Task { await hostList.grantSSHFolderAccess() }
                }
                if !hostList.configWarnings.isEmpty {
                    Divider()
                    Text("\(hostList.configWarnings.count) config warning(s)")
                    ForEach(hostList.configWarnings, id: \.self) { warning in
                        Text(warning)
                    }
                }
            } label: {
                Label(String(localized: "SSH Config"), systemImage: "doc.text")
            }
            Button {
                hostList.tunnelsRequest = TunnelsSheetRequest(hostFilter: nil)
            } label: {
                Label(String(localized: "Tunnels"), systemImage: "arrow.left.arrow.right")
            }
            Button {
                hostList.showKeyManager = true
            } label: {
                Label(String(localized: "SSH Keys"), systemImage: "key")
            }
            Button {
                hostList.editorRequest = .create
            } label: {
                Label(String(localized: "Add Host"), systemImage: "plus")
            }
        }
    }
}

/// One row: name plus `user@host:port`, with a lock badge for read-only hosts.
private struct HostRow: View {
    let host: HostProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(host.name).font(.headline)
                if host.source == .sshConfig {
                    Image(systemName: "lock")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(String(localized: "Read-only, from ~/.ssh/config"))
                }
            }
            Text("\(host.username)@\(host.hostname)\(host.port == 22 ? "" : ":\(host.port)")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// One "Recent" entry; double-click reconnects when the host still exists.
private struct RecentRow: View {
    let entry: HistoryEntry
    let host: HostProfile?
    let open: (HostProfile) -> Void

    var body: some View {
        HStack {
            Image(systemName: icon).foregroundStyle(color)
            VStack(alignment: .leading) {
                Text(entry.hostDisplayName)
                Text(entry.startedAt, format: .relative(presentation: .named))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .opacity(host == nil ? 0.5 : 1)
        .onTapGesture(count: 2) { if let host { open(host) } }
        .accessibilityElement(children: .combine)
        .accessibilityHint(host == nil ? "" : String(localized: "Double-click to connect again"))
    }

    private var icon: String {
        switch entry.outcome {
        case .failed: "exclamationmark.triangle"
        case .cancelled: "xmark.circle"
        case .active, .completed: "clock.arrow.circlepath"
        }
    }

    private var color: Color { entry.outcome == .failed ? .orange : .secondary }
}
