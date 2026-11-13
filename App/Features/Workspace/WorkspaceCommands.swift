import SwiftUI

/// Menu commands and keyboard shortcuts for tabs: ⌘T, ⌘W, ⌘1…⌘9, ⌃Tab / ⌃⇧Tab.
struct WorkspaceCommands: Commands {
    let workspace: WorkspaceViewModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { workspace.openTabForSelectedHost() }
                .keyboardShortcut("t")
                .disabled(!workspace.canOpenSelectedHost)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Close Pane or Tab") { workspace.requestCloseSelected() }
                .keyboardShortcut("w")
                .disabled(workspace.selectedTabID == nil)
        }
        CommandMenu("Pane") {
            Button("Split Right") { workspace.splitSelected(.horizontal) }
                .keyboardShortcut("d")
                .disabled(!workspace.canSplitSelected)
            Button("Split Down") { workspace.splitSelected(.vertical) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(!workspace.canSplitSelected)
            Divider()
            Button("Focus Next Pane") { workspace.moveFocus(by: 1) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Button("Focus Previous Pane") { workspace.moveFocus(by: -1) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Button("Focus Pane Below") { workspace.moveFocus(by: 1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Button("Focus Pane Above") { workspace.moveFocus(by: -1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
        }
        CommandMenu("Snippets") {
            Button("Run Snippet…") { workspace.showSnippetPicker = true }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(workspace.selectedTab?.canReceiveSnippets != true)
            Button("Manage Snippets…") { workspace.showSnippets = true }
        }
        CommandMenu("Tab") {
            Button("Next Tab") { workspace.selectNext() }
                .keyboardShortcut(.tab, modifiers: .control)
            Button("Previous Tab") { workspace.selectPrevious() }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
            Divider()
            ForEach(1...9, id: \.self) { number in
                Button("Tab \(number)") { workspace.selectTab(at: number - 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
                    .disabled(number > workspace.tabs.count)
            }
        }
    }
}
