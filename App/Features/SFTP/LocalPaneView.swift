import SSHCore
import SwiftUI

/// Local side of the file browser (a folder the user granted access to).
struct LocalPaneView: View {
    @Bindable var model: SFTPBrowserViewModel
    @State private var showNewFolder = false
    @State private var pendingTrash: [LocalFile] = []

    var body: some View {
        VStack(spacing: 0) {
            PathBar(
                path: model.localURL?.path ?? "", canGoUp: model.canGoUpLocal,
                onUp: { model.goUpLocal() }, onRefresh: { model.refreshLocal() }
            ) {
                Button(String(localized: "Choose…")) { Task { await model.chooseLocalFolder() } }
                Button { showNewFolder = true } label: { Image(systemName: "folder.badge.plus") }
                    .disabled(model.localURL == nil)
                    .help(String(localized: "New folder"))
                    .accessibilityLabel(String(localized: "New folder"))
            }
            Divider()
            if model.localURL == nil {
                ContentUnavailableView {
                    Label(String(localized: "No local folder"), systemImage: "folder")
                } description: {
                    Text("Choose a folder on this Mac to upload from and download to.")
                } actions: {
                    Button(String(localized: "Choose Folder…")) { Task { await model.chooseLocalFolder() } }
                }
            } else {
                table
            }
        }
        .dropDestination(for: String.self) { items, _ in
            guard let payload = items.first(where: { $0.hasPrefix(SFTPBrowserViewModel.dragPrefix) }) else {
                return false
            }
            Task { await model.handleRemoteDrop(payload) }
            return true
        }
        .sheet(isPresented: $showNewFolder) {
            NamePromptSheet(
                title: String(localized: "New folder"), name: "",
                onSubmit: { name in
                    showNewFolder = false
                    model.makeLocalFolder(named: name)
                }, onCancel: { showNewFolder = false })
        }
        .confirmationDialog(
            String(localized: "Move to Trash?"),
            isPresented: Binding(get: { !pendingTrash.isEmpty }, set: { if !$0 { pendingTrash = [] } }),
            titleVisibility: .visible
        ) {
            Button(String(localized: "Move to Trash"), role: .destructive) {
                model.trashLocal(pendingTrash)
                pendingTrash = []
            }
        }
    }

    private var visibleFiles: [LocalFile] { model.localFiles }

    private var table: some View {
        Table(of: LocalFile.self, selection: $model.localSelection) {
            TableColumn(String(localized: "Name")) { file in
                Label(file.name, systemImage: file.isDirectory ? "folder" : "doc")
            }
            TableColumn(String(localized: "Size")) { file in
                Text(file.isDirectory ? "—" : FileFormat.size(file.size)).foregroundStyle(.secondary)
            }
            .width(80)
            TableColumn(String(localized: "Modified")) { file in
                Text(FileFormat.date(file.modified)).foregroundStyle(.secondary)
            }
            .width(130)
        } rows: {
            ForEach(visibleFiles) { file in
                TableRow(file).draggable(file.url)
            }
        }
        .contextMenu(forSelectionType: URL.self) { urls in
            let files = visibleFiles.filter { urls.contains($0.url) }
            if !files.isEmpty {
                Button(String(localized: "Upload")) { Task { await model.upload(files.map(\.url)) } }
                Divider()
                Button(String(localized: "Move to Trash…"), role: .destructive) { pendingTrash = files }
            }
        } primaryAction: { urls in
            if let file = visibleFiles.first(where: { urls.contains($0.url) }) { model.openLocal(file) }
        }
    }
}
