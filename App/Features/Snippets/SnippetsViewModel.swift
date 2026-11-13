import Foundation
import Observation
import SSHCore

/// A snippet waiting for placeholder values before it is sent.
struct PendingSnippet: Identifiable {
    let id = UUID()
    let snippet: Snippet
    let names: [String]
    let toAll: Bool
}

/// Loads snippets, filters them by a search text, and sends them to the selected tab.
///
/// Snippets with `{{placeholders}}` go through `pending` first (the view asks for values, then calls
/// `complete(_:values:)`).
@MainActor
@Observable
final class SnippetsViewModel {
    private(set) var snippets: [Snippet] = []
    var search = ""
    /// Set while the user must fill in placeholders.
    var pending: PendingSnippet?
    var errorMessage: String?

    private let env: AppEnvironment
    private let workspace: WorkspaceViewModel
    private let tasks = TaskBag()

    init(env: AppEnvironment, workspace: WorkspaceViewModel) {
        self.env = env
        self.workspace = workspace
    }

    /// Snippets whose title, command, or a tag contains the search text (case-insensitive).
    var filtered: [Snippet] {
        Self.filter(snippets, by: search)
    }

    /// `true` when the selected tab can take input.
    var canSend: Bool { workspace.selectedTab?.canReceiveSnippets == true }

    /// Starts following the repository (cancelled when the view model is released).
    func start() {
        let repo = env.snippets
        tasks.add(
            Task { [weak self] in
                for await list in await repo.changes() {
                    guard let self else { return }
                    self.snippets = list
                }
            })
    }

    /// Creates or replaces a snippet.
    func save(_ snippet: Snippet) async {
        do { try await env.snippets.upsert(snippet) } catch { errorMessage = error.localizedDescription }
    }

    /// Deletes a snippet.
    func delete(_ snippet: Snippet) async {
        do { _ = try await env.snippets.delete(id: snippet.id) } catch { errorMessage = error.localizedDescription }
    }

    /// Sends `snippet` to the focused pane (or all panes). Asks for placeholder values first if needed.
    func run(_ snippet: Snippet, toAll: Bool = false) {
        let names = SnippetTemplate.placeholders(in: snippet.command)
        if names.isEmpty {
            deliver(snippet.command, snippet: snippet, toAll: toAll)
        } else {
            pending = PendingSnippet(snippet: snippet, names: names, toAll: toAll)
        }
    }

    /// Sends the pending snippet with the entered values.
    func complete(_ item: PendingSnippet, values: [String: String]) {
        pending = nil
        deliver(SnippetTemplate.fill(item.snippet.command, values: values), snippet: item.snippet, toAll: item.toAll)
    }

    /// Case-insensitive filter by title, command or tags; an empty query returns everything.
    static func filter(_ list: [Snippet], by query: String) -> [Snippet] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return list }
        return list.filter {
            $0.title.lowercased().contains(needle) || $0.command.lowercased().contains(needle)
                || $0.tags.contains { $0.lowercased().contains(needle) }
        }
    }

    private func deliver(_ command: String, snippet: Snippet, toAll: Bool) {
        guard let tab = workspace.selectedTab, tab.canReceiveSnippets else {
            errorMessage = String(localized: "Open a connected terminal tab first.")
            return
        }
        tab.send(SnippetTemplate.bytes(for: command, appendNewline: snippet.appendNewline), toAll: toAll)
    }
}
