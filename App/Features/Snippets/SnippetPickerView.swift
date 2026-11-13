import SSHCore
import SwiftUI

/// ⌘⇧P quick picker: type to filter, Return runs the first match in the focused pane.
struct SnippetPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: SnippetsViewModel
    @FocusState private var searchFocused: Bool

    init(env: AppEnvironment, workspace: WorkspaceViewModel) {
        _model = State(initialValue: SnippetsViewModel(env: env, workspace: workspace))
    }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            TextField(String(localized: "Run snippet…"), text: $model.search)
                .textFieldStyle(.plain).font(.title3).padding(12)
                .focused($searchFocused)
                .onSubmit { runFirst() }
            Divider()
            List(model.filtered) { snippet in
                Button {
                    run(snippet)
                } label: {
                    VStack(alignment: .leading) {
                        Text(snippet.title)
                        Text(snippet.command).font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
            }
            if let message = model.errorMessage {
                Text(message).foregroundStyle(.red).padding(8)
            }
        }
        .frame(width: 460, height: 340)
        .task {
            model.start()
            searchFocused = true
        }
        .sheet(item: $model.pending) { item in
            PlaceholderPromptView(item: item) { values in
                model.complete(item, values: values)
                dismiss()
            }
        }
        .onExitCommand { dismiss() }
    }

    private func runFirst() {
        if let first = model.filtered.first { run(first) }
    }

    private func run(_ snippet: Snippet) {
        model.run(snippet)
        // With placeholders the prompt sheet follows; otherwise close unless sending failed.
        if model.pending == nil, model.errorMessage == nil { dismiss() }
    }
}
