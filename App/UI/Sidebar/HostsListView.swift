import SSHCore
import SwiftUI

/// "Hosts" section: folders (drop targets) followed by hosts that are in no folder.
///
/// Drag a host row onto a folder to move it there, or onto the plain lists to take it out of its folder.
/// This works for hosts from `~/.ssh/config` as well (assignments are stored separately).
struct HostsListView: View {
    @Bindable var hostList: HostListViewModel
    let workspace: WorkspaceViewModel
    @State private var collapsed: Set<UUID> = []
    @State private var targetedGroup: UUID?

    var body: some View {
        List(selection: $hostList.selection) {
            ForEach(hostList.groupSections) { section in
                groupView(section)
            }
            if !hostList.ungroupedMyHosts.isEmpty {
                Section(String(localized: "My Hosts")) {
                    ForEach(hostList.ungroupedMyHosts) { row(for: $0) }
                }
            }
            if !hostList.ungroupedConfigHosts.isEmpty {
                Section(String(localized: "SSH Config")) {
                    ForEach(hostList.ungroupedConfigHosts) { row(for: $0) }
                }
            }
        }
        .listStyle(.sidebar)
        // Dropping anywhere outside a folder takes the host out of its folder.
        .dropDestination(for: String.self) { items, _ in
            let ids = HostListViewModel.hostIDs(fromDrop: items)
            guard !ids.isEmpty else { return false }
            Task { await hostList.move(hostIDs: ids, to: nil) }
            return true
        }
        .overlay { emptyState }
    }

    @ViewBuilder
    private var emptyState: some View {
        if hostList.hosts.isEmpty && hostList.groupsState.groups.isEmpty {
            ContentUnavailableView(
                String(localized: "No hosts yet"), systemImage: "server.rack",
                description: Text("Click + below to add your first host."))
        } else if hostList.groupSections.isEmpty && hostList.ungroupedMyHosts.isEmpty
            && hostList.ungroupedConfigHosts.isEmpty
        {
            ContentUnavailableView.search(text: hostList.searchText)
        }
    }

    private func groupView(_ section: HostGroupSection) -> some View {
        DisclosureGroup(isExpanded: expandedBinding(section.group.id)) {
            ForEach(section.hosts) { row(for: $0) }
        } label: {
            GroupHeaderView(
                group: section.group, count: section.hosts.count,
                isTargeted: targetedGroup == section.group.id
            )
            .contextMenu { groupMenu(section.group) }
        }
        .dropDestination(for: String.self) { items, _ in
            let ids = HostListViewModel.hostIDs(fromDrop: items)
            guard !ids.isEmpty else { return false }
            Task { await hostList.move(hostIDs: ids, to: section.group.id) }
            return true
        } isTargeted: { targeted in
            if targeted { targetedGroup = section.group.id } else if targetedGroup == section.group.id {
                targetedGroup = nil
            }
        }
    }

    private func expandedBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { !collapsed.contains(id) },
            set: { expanded in
                if expanded { collapsed.remove(id) } else { collapsed.insert(id) }
            })
    }

    private func row(for host: HostProfile) -> some View {
        HostRowView(
            host: host, status: workspace.liveState(for: host.id),
            connect: { workspace.openTab(for: host) }
        )
        .tag(host.id)
        .draggable(HostListViewModel.dragPayload(for: host))
        .simultaneousGesture(TapGesture(count: 2).onEnded { workspace.openTab(for: host) })
        .contextMenu { contextMenu(for: host) }
    }

    @ViewBuilder
    private func groupMenu(_ group: HostGroup) -> some View {
        Button(String(localized: "Rename…"), systemImage: "pencil") { hostList.groupPrompt = .rename(group) }
        Button(String(localized: "Move Up"), systemImage: "arrow.up") {
            Task { await hostList.moveGroup(group, by: -1) }
        }
        Button(String(localized: "Move Down"), systemImage: "arrow.down") {
            Task { await hostList.moveGroup(group, by: 1) }
        }
        Divider()
        Button(String(localized: "Delete Group"), systemImage: "trash", role: .destructive) {
            Task { await hostList.deleteGroup(group) }
        }
    }

    @ViewBuilder
    private func contextMenu(for host: HostProfile) -> some View {
        let readOnly = host.source == .sshConfig
        Button(String(localized: "Connect"), systemImage: "play") { workspace.openTab(for: host) }
        Button(String(localized: "Open SFTP"), systemImage: "folder") {
            workspace.openTab(for: host, showFiles: true)
        }
        Button(String(localized: "Tunnels…"), systemImage: "arrow.left.arrow.right") {
            hostList.tunnelsRequest = TunnelsSheetRequest(hostFilter: host.id)
        }
        Divider()
        moveMenu(for: host)
        Button(String(localized: "Edit…"), systemImage: "pencil") { hostList.editorRequest = .edit(host) }
            .disabled(readOnly)
        Button(
            readOnly ? String(localized: "Duplicate to My Hosts") : String(localized: "Duplicate"),
            systemImage: "plus.square.on.square"
        ) {
            Task { await hostList.duplicate(host) }
        }
        Divider()
        Button(String(localized: "Delete…"), systemImage: "trash", role: .destructive) {
            hostList.hostPendingDelete = host
        }
        .disabled(readOnly)
    }

    private func moveMenu(for host: HostProfile) -> some View {
        Menu(String(localized: "Move to Group"), systemImage: "folder") {
            ForEach(hostList.groupsState.groups) { group in
                Button(group.name) { Task { await hostList.move(hostIDs: [host.id], to: group.id) } }
            }
            if !hostList.groupsState.groups.isEmpty { Divider() }
            Button(String(localized: "New Group…"), systemImage: "folder.badge.plus") {
                hostList.groupPrompt = .create(hostIDs: [host.id])
            }
            if hostList.group(of: host) != nil {
                Button(String(localized: "Remove from Group")) {
                    Task { await hostList.move(hostIDs: [host.id], to: nil) }
                }
            }
        }
    }
}
