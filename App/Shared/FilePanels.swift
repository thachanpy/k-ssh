import AppKit
import Foundation

/// `NSOpenPanel` / `NSSavePanel` helpers (sandbox access comes from the user's selection).
@MainActor
enum FilePanels {
    /// The user's real `~/.ssh` (the sandbox container home is not what users expect).
    static var sshDirectory: URL {
        let home = NSHomeDirectoryForUser(NSUserName()) ?? NSHomeDirectory()
        return URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(".ssh", isDirectory: true)
    }

    /// Asks the user to pick a private key file; starts in `~/.ssh` with hidden files shown.
    static func chooseKeyFile(message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.message = message
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = sshDirectory
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Asks the user to grant access to a folder (used for `~/.ssh`); starts in `~/.ssh`.
    static func chooseSSHFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.message = String(localized: "Select your ~/.ssh folder to import hosts from its config file")
        panel.prompt = String(localized: "Grant Access")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = sshDirectory
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Asks the user to pick any folder (read-write access is granted for the sandbox).
    static func chooseFolder(message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.message = message
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Asks where to save a new private key; starts in `~/.ssh`.
    static func chooseSaveLocation(suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.message = String(localized: "Choose where to save the new private key")
        panel.nameFieldStringValue = suggestedName
        panel.showsHiddenFiles = true
        panel.directoryURL = sshDirectory
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Copies text to the general pasteboard.
    static func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
