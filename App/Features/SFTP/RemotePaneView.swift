import SSHCore
import SwiftUI

/// Remote side of the file browser.
struct RemotePaneView: View {
    @Bindable var model: SFTPBrowserViewModel

    private enum Prompt: Identifiable {
        case newFolder
        case rename(RemoteFile)
        var id: String {
            switch self {
            case .newFolder: "new"
            case .rename(let file): "rename-\(file.id)"
            }
        }
    }

    @State private var prompt: Prompt?

    var body: some View {
        VStack(spacing: 0) {
            PathBar(
                path: model.remotePath, canGoUp: model.canGoUpRemote,
                onUp: { Task { await model.goUpRemote() } },
                onRefresh: { Task { await model.refreshRemote() } }
            ) {
                Toggle(isOn: $model.showHidden) { Image(systemName: "eye") }
                    .toggleStyle(.button)
                    .help(String(localized: "Show hidden files"))
                Button { prompt = .newFolder } label: { Image(systemName: "folder.badge.plus") }
                    .help(String(localized: "New folder"))
                    .accessibilityLabel(String(localized: "New folder"))
            }
            Divider()
            table
        }
        .dropDestination(for: URL.self) { urls, _ in
            Task { await model.upload(urls) }
            return true
        }
        .sheet(item: $prompt) { prompt in
            switch prompt {
            case .newFolder:
                NamePromptSheet(
                    title: String(localized: "New folder"), name: "",
                    onSubmit: { name in
                        self.prompt = nil
                        Task { await model.makeRemoteFolder(named: name) }
                    }, onCancel: { self.prompt = nil })
            case .rename(let file):
                NamePromptSheet(
                    title: String(localized: "Rename"), name: file.name,
                    onSubmit: { name in
                        self.prompt = nil
                        Task { await model.rename(file, to: name) }
                    }, onCancel: { self.prompt = nil })
            }
        }
        .confirmationDialog(
            String(localized: "Delete from the server?"),
            isPresented: Binding(
                get: { !model.deleteCandidates.isEmpty }, set: { if !$0 { model.deleteCandidates = [] } }),
            titleVisibility: .visible
        ) {
            Button(String(localized: "Delete"), role: .destructive) { Task { await model.deleteConfirmed() } }
        } message: {
            Text("\(model.deleteCandidates.count) item(s) will be permanently deleted. Folders are deleted with their contents.")
        }
    }

    private var table: some View {
        Table(of: RemoteFile.self, selection: $model.remoteSelection) {
            TableColumn(String(localized: "Name")) { file in
                Label(file.name, systemImage: file.isDirectory ? "folder" : (file.isSymlink ? "link" : "doc"))
            }
            TableColumn(String(localized: "Size")) { file in
                Text(file.isDirectory ? "—" : FileFormat.size(Int64(file.size))).foregroundStyle(.secondary)
            }
            .width(80)
            TableColumn(String(localized: "Modified")) { file in
                Text(FileFormat.date(file.modified)).foregroundStyle(.secondary)
            }
            .width(130)
            TableColumn(String(localized: "Permissions")) { file in
                Text(file.permissionString).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
            .width(90)
        } rows: {
            ForEach(model.visibleRemote) { file in
                TableRow(file).draggable(model.dragPayload(for: file))
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            let files = model.visibleRemote.filter { ids.contains($0.id) }
            if !files.isEmpty {
                Button(String(localized: "Download")) { Task { await model.download(files) } }
                if files.count == 1, let only = files.first {
                    Button(String(localized: "Rename…")) { prompt = .rename(only) }
                }
                Divider()
                Button(String(localized: "Delete…"), role: .destructive) { model.deleteCandidates = files }
            }
        } primaryAction: { ids in
            if let file = model.visibleRemote.first(where: { ids.contains($0.id) }) {
                Task { await model.openRemote(file) }
            }
        }
    }
}
