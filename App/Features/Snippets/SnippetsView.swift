import SSHCore
import SwiftUI

/// Snippet manager: search, add/edit/delete, and run in the focused pane or all panes.
struct SnippetsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: SnippetsViewModel
    @State private var editing: Snippet?

    init(env: AppEnvironment, workspace: WorkspaceViewModel) {
        _model = State(initialValue: SnippetsViewModel(env: env, workspace: workspace))
    }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack {
                TextField(String(localized: "Search snippets"), text: $model.search)
                    .textFieldStyle(.roundedBorder)
                Button {
                    editing = Snippet(title: "", command: "")
                } label: {
                    Label(String(localized: "New Snippet"), systemImage: "plus")
                }
            }
            .padding()
            Divider()
            if model.filtered.isEmpty {
                ContentUnavailableView(
                    model.snippets.isEmpty ? String(localized: "No snippets yet") : String(localized: "No matches"),
                    systemImage: "text.badge.plus")
            } else {
                List(model.filtered) { snippet in
                    SnippetRow(
                        snippet: snippet, canSend: model.canSend,
                        run: { model.run(snippet) }, runAll: { model.run(snippet, toAll: true) },
                        edit: { editing = snippet },
                        delete: { Task { await model.delete(snippet) } })
                }
            }
            Divider()
            HStack {
                if let message = model.errorMessage {
                    Text(message).foregroundStyle(.red).lineLimit(2)
                }
                Spacer()
                Button(String(localized: "Done")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 520, minHeight: 420)
        .task { model.start() }
        .sheet(item: $editing) { snippet in
            SnippetEditorView(snippet: snippet) { saved in
                Task { await model.save(saved) }
            }
        }
        .sheet(item: $model.pending) { item in
            PlaceholderPromptView(item: item) { values in model.complete(item, values: values) }
        }
    }
}

private struct SnippetRow: View {
    let snippet: Snippet
    let canSend: Bool
    let run: () -> Void
    let runAll: () -> Void
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(snippet.title).font(.headline)
                Text(snippet.command).font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Button(String(localized: "Run"), action: run).disabled(!canSend)
                .accessibilityLabel(String(localized: "Run \(snippet.title) in the focused pane"))
            Menu {
                Button(String(localized: "Run in All Panes"), action: runAll)
                Button(String(localized: "Edit…"), action: edit)
                Button(String(localized: "Delete"), role: .destructive, action: delete)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton).fixedSize()
            .accessibilityLabel(String(localized: "More actions"))
        }
        .contextMenu {
            Button(String(localized: "Edit…"), action: edit)
            Button(String(localized: "Delete"), role: .destructive, action: delete)
        }
    }
}

/// Add/edit form for one snippet.
struct SnippetEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Snippet
    @State private var tagsText: String
    let onSave: (Snippet) -> Void

    init(snippet: Snippet, onSave: @escaping (Snippet) -> Void) {
        _draft = State(initialValue: snippet)
        _tagsText = State(initialValue: snippet.tags.joined(separator: ", "))
        self.onSave = onSave
    }

    private var canSave: Bool {
        !draft.title.trimmingCharacters(in: .whitespaces).isEmpty
            && !draft.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField(String(localized: "Title"), text: $draft.title)
                TextField(String(localized: "Tags"), text: $tagsText, prompt: Text("deploy, docker"))
                Section(String(localized: "Command")) {
                    TextEditor(text: $draft.command)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 90)
                    Text("Use {{name}} for values asked before sending.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle(String(localized: "Press Return after sending"), isOn: $draft.appendNewline)
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button(String(localized: "Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Save")) {
                    var saved = draft
                    saved.title = saved.title.trimmingCharacters(in: .whitespaces)
                    saved.tags = HostEditorViewModel.parseTags(tagsText)
                    onSave(saved)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction).disabled(!canSave)
            }
            .padding()
        }
        .frame(minWidth: 460, minHeight: 380)
    }
}

/// Asks for the value of every `{{placeholder}}` of a snippet.
struct PlaceholderPromptView: View {
    @Environment(\.dismiss) private var dismiss
    let item: PendingSnippet
    let onSend: ([String: String]) -> Void
    @State private var values: [String: String] = [:]

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(item.snippet.title) {
                    ForEach(item.names, id: \.self) { name in
                        TextField(name, text: binding(for: name))
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button(String(localized: "Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Send")) {
                    onSend(values)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 380, minHeight: 200)
    }

    private func binding(for name: String) -> Binding<String> {
        Binding(get: { values[name, default: ""] }, set: { values[name] = $0 })
    }
}
