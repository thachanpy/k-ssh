import SSHCore
import SwiftUI

/// Two-pane file manager (remote | local) with a transfer panel, shown in a session tab.
struct SFTPBrowserView: View {
    @Bindable var model: SFTPBrowserViewModel
    /// Connection state of the tab; changes re-run `openIfNeeded` (open on connect, reset on drop).
    let state: ConnectionState

    var body: some View {
        VStack(spacing: 0) {
            content
            Divider()
            TransferPanelView(model: model)
        }
        .task(id: state) { await model.openIfNeeded() }
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

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .ready:
            // Side pane next to the terminal: remote on top, local below.
            VSplitView {
                RemotePaneView(model: model).frame(minHeight: 160)
                LocalPaneView(model: model).frame(minHeight: 120)
            }
        case .waiting:
            ContentUnavailableView(
                String(localized: "Waiting for the connection"), systemImage: "network",
                description: Text("Files become available once the session is connected."))
        case .connecting:
            ProgressView(String(localized: "Opening SFTP…")).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label(String(localized: "Could not open SFTP"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button(String(localized: "Retry")) { Task { await model.openIfNeeded() } }
            }
        }
    }
}

/// Shared formatting for the file tables.
enum FileFormat {
    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func date(_ date: Date?) -> String {
        date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—"
    }
}

/// Asks for a single name (new folder, rename).
struct NamePromptSheet: View {
    let title: String
    @State var name: String
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField(String(localized: "Name"), text: $name).onSubmit(submit)
            HStack {
                Spacer()
                Button(String(localized: "Cancel"), role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "OK"), action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || name.contains("/"))
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func submit() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains("/") else { return }
        onSubmit(trimmed)
    }
}

/// Path bar with back/up, refresh and extra actions, shared by both panes.
struct PathBar<Extra: View>: View {
    let path: String
    let canGoUp: Bool
    let onUp: () -> Void
    let onRefresh: () -> Void
    @ViewBuilder let extra: () -> Extra

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onUp) { Image(systemName: "arrow.up") }
                .disabled(!canGoUp)
                .help(String(localized: "Parent folder"))
                .accessibilityLabel(String(localized: "Parent folder"))
            Text(path.isEmpty ? "—" : path)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1).truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            extra()
            Button(action: onRefresh) { Image(systemName: "arrow.clockwise") }
                .help(String(localized: "Refresh"))
                .accessibilityLabel(String(localized: "Refresh"))
        }
        .buttonStyle(.borderless)
        .padding(8)
    }
}
