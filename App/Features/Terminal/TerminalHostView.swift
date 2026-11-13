import AppKit
import SSHCore
import SwiftTerm
import SwiftUI

/// Font used by terminals; defaults to SF Mono 13 and follows `AppSettings`.
struct TerminalAppearance: Equatable {
    var fontName: String?
    var fontSize: Double?
    var theme: TerminalTheme

    init(settings: AppSettings) {
        fontName = settings.terminalFontName
        fontSize = settings.terminalFontSize
        theme = TerminalTheme.theme(id: settings.terminalThemeID)
    }

    /// The resolved font (falls back to the system monospaced font).
    var font: NSFont {
        let size = CGFloat(fontSize ?? 13)
        if let fontName, let custom = NSFont(name: fontName, size: size) { return custom }
        return NSFont(name: "SFMono-Regular", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

/// SwiftUI wrapper around SwiftTerm's `TerminalView`.
///
/// A plain `TerminalView` is used (not `LocalProcessTerminalView`): the latter rewires keyboard
/// input to a local pty process and bypasses `TerminalViewDelegate.send`. The `Coordinator` is the
/// `TerminalViewDelegate`, so keystrokes go to the view model and output is fed with `feed(byteArray:)`.
struct TerminalHostView: NSViewRepresentable {
    let viewModel: any TerminalIO
    let appearance: TerminalAppearance
    /// `true` when this terminal's tab is selected; it then takes keyboard focus.
    let isActive: Bool
    /// Called when the user clicks the terminal (split panes use it to track the active pane).
    var onFocus: @MainActor () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel, onFocus: onFocus)
    }

    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        view.font = appearance.font
        Self.apply(appearance.theme, to: view, coordinator: context.coordinator)
        viewModel.outputSink = { [weak view] bytes in
            view?.feed(byteArray: bytes[...])
        }
        // Clicking the terminal always gives it keyboard focus (without delaying selection events).
        let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.focus(_:)))
        click.delaysPrimaryMouseButtonEvents = false
        view.addGestureRecognizer(click)
        return view
    }

    func updateNSView(_ view: TerminalView, context: Context) {
        context.coordinator.onFocus = onFocus
        if view.font != appearance.font {
            view.font = appearance.font
        }
        Self.apply(appearance.theme, to: view, coordinator: context.coordinator)
        // Deferred one turn: the window's responder chain may still be settling (sheet closing,
        // overlay hiding, view just inserted) when SwiftUI calls this.
        if isActive {
            Task { @MainActor [weak view] in
                guard let view, let window = view.window, window.firstResponder !== view else { return }
                window.makeFirstResponder(view)
            }
        }
    }

    /// Applies the color theme once per change (not on every SwiftUI update).
    private static func apply(_ theme: TerminalTheme, to view: TerminalView, coordinator: Coordinator) {
        guard coordinator.appliedThemeID != theme.id else { return }
        coordinator.appliedThemeID = theme.id
        view.nativeBackgroundColor = theme.nsBackground
        view.nativeForegroundColor = theme.nsForeground
        view.caretColor = theme.nsCursor
        view.selectedTextBackgroundColor = theme.nsSelection
        view.installColors(theme.swiftTermPalette)
    }

    static func dismantleNSView(_ view: TerminalView, coordinator: Coordinator) {
        coordinator.viewModel.outputSink = nil
        view.terminalDelegate = nil
    }

    /// Receives keystrokes, size and title events from the terminal and forwards them to the view model.
    ///
    /// Every `TerminalViewDelegate` requirement is implemented explicitly (SwiftTerm 1.99.3 does not
    /// provide defaults for all of them). Links are not opened and the remote can never read the clipboard.
    @MainActor
    final class Coordinator: NSObject, TerminalViewDelegate {
        let viewModel: any TerminalIO
        var onFocus: @MainActor () -> Void
        /// ID of the theme currently installed in the view.
        var appliedThemeID: String?

        init(viewModel: any TerminalIO, onFocus: @escaping @MainActor () -> Void) {
            self.viewModel = viewModel
            self.onFocus = onFocus
        }

        /// Click handler: makes the clicked terminal the first responder and the active pane.
        @objc func focus(_ sender: NSClickGestureRecognizer) {
            guard let view = sender.view else { return }
            view.window?.makeFirstResponder(view)
            onFocus()
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            viewModel.resize(cols: newCols, rows: newRows)
        }

        func setTerminalTitle(source: TerminalView, title: String) {
            viewModel.setTitle(title)
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            viewModel.send(Array(data))
        }

        func scrolled(source: TerminalView, position: Double) {}

        func requestOpenLink(source: TerminalView, request: TerminalLinkRequest) {}

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}

        func bell(source: TerminalView) {
            NSSound.beep()
        }

        func clipboardCopy(source: TerminalView, content: Data) {
            guard let text = String(data: content, encoding: .utf8) else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }

        /// Denied: a remote program must not be able to read the local clipboard.
        func clipboardRead(source: TerminalView) -> Data? { nil }

        func kittyClipboardCapabilities(source: TerminalView) -> KittyClipboardCapabilities { [] }

        func kittyClipboardAvailableMimeTypes(
            source: TerminalView, location: KittyClipboardLocation
        ) -> [String]? { nil }

        func kittyClipboardRead(
            source: TerminalView, location: KittyClipboardLocation, mimeType: String
        ) -> KittyClipboardReadResult? { nil }

        func kittyClipboardWrite(
            source: TerminalView, location: KittyClipboardLocation, content: KittyClipboardWriteContent
        ) -> KittyClipboardWriteResult { .unsupported }

        func kittyClipboardRequestPermission(
            source: TerminalView, request: KittyClipboardPermissionRequest
        ) -> KittyClipboardPermissionResult { .deny }

        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
