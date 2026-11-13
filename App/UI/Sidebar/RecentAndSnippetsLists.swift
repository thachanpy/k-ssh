import SSHCore
import SwiftUI

/// "Recent" section: last connections; double-click or hover button reconnects.
struct RecentListView: View {
    let hostList: HostListViewModel
    let workspace: WorkspaceViewModel

    var body: some View {
        List {
            Section {
                ForEach(hostList.recent) { entry in
                    RecentRowView(entry: entry, host: hostList.host(for: entry)) { host in
                        workspace.openTab(for: host)
                    }
                }
            } header: {
                HStack {
                    Text("Recent connections")
                    Spacer()
                    Button(String(localized: "Clear")) { Task { await hostList.clearHistory() } }
                        .buttonStyle(.link).font(.caption)
                        .help(String(localized: "Clear recent connections"))
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if hostList.recent.isEmpty {
                ContentUnavailableView(
                    String(localized: "No recent connections"), systemImage: "clock",
                    description: Text("Hosts you connect to appear here."))
            }
        }
    }
}

private struct RecentRowView: View {
    let entry: HistoryEntry
    let host: HostProfile?
    let open: (HostProfile) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: icon)
                .symbolRenderingMode(.multicolor)
                .frame(width: Theme.Layout.hostIcon)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(entry.hostDisplayName).font(.headline).lineLimit(1)
                Text(entry.startedAt, format: .relative(presentation: .named))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if hovering, let host {
                Button { open(host) } label: {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .symbolRenderingMode(.hierarchical).font(.title3)
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Connect again"))
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
        .opacity(host == nil ? 0.5 : 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { if let host { open(host) } }
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch entry.outcome {
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle.fill"
        case .active, .completed: "clock.arrow.circlepath"
        }
    }
}

/// "Snippets" section: search results, hover Run, add/manage buttons.
struct SnippetsListView: View {
    @Bindable var model: SnippetsViewModel
    let workspace: WorkspaceViewModel
    @State private var editing: Snippet?

    var body: some View {
        VStack(spacing: 0) {
            List(model.filtered) { snippet in
                SnippetRowView(snippet: snippet, canRun: model.canSend) { model.run(snippet) }
                    .contextMenu {
                        Button(String(localized: "Run in All Panes"), systemImage: "play.rectangle.on.rectangle") {
                            model.run(snippet, toAll: true)
                        }
                        Button(String(localized: "Edit…"), systemImage: "pencil") { editing = snippet }
                        Button(String(localized: "Delete"), systemImage: "trash", role: .destructive) {
                            Task { await model.delete(snippet) }
                        }
                    }
            }
            .listStyle(.sidebar)
            .overlay {
                if model.snippets.isEmpty {
                    ContentUnavailableView(
                        String(localized: "No snippets yet"), systemImage: "text.badge.plus",
                        description: Text("Save commands you run often."))
                }
            }
            HStack {
                Button { editing = Snippet(title: "", command: "") } label: {
                    Label(String(localized: "New Snippet"), systemImage: "plus")
                }
                .buttonStyle(.borderless)
                Spacer()
                if let message = model.errorMessage {
                    Text(message).font(.caption).foregroundStyle(.red).lineLimit(1)
                }
            }
            .padding(Theme.Spacing.sm)
        }
        .sheet(item: $editing) { snippet in
            SnippetEditorView(snippet: snippet) { saved in Task { await model.save(saved) } }
        }
        .sheet(item: $model.pending) { item in
            PlaceholderPromptView(item: item) { values in model.complete(item, values: values) }
        }
    }
}

private struct SnippetRowView: View {
    let snippet: Snippet
    let canRun: Bool
    let run: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(snippet.title).font(.headline).lineLimit(1)
                Text(snippet.command)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if hovering {
                Button(action: run) {
                    Image(systemName: "play.fill").symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.borderless)
                .disabled(!canRun)
                .help(canRun ? String(localized: "Run in the focused pane") : String(localized: "Open a connected terminal first"))
                .accessibilityLabel(String(localized: "Run \(snippet.title)"))
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { if canRun { run() } }
    }
}
