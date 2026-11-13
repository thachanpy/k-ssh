import SSHCore
import SwiftUI

/// One tab's content: the terminal, a connection-status overlay, and the prompt sheets.
struct TerminalPaneView: View {
    @Environment(AppEnvironment.self) private var env
    let tab: SessionTab
    let isActive: Bool
    /// Called when the user clicks this pane (split layouts track the active pane).
    var onFocus: @MainActor () -> Void = {}
    @State private var showKnownHosts = false

    var body: some View {
        let terminal = tab.terminal
        ZStack {
            TerminalHostView(
                viewModel: terminal, appearance: TerminalAppearance(settings: env.settings),
                // Re-evaluated when the shell opens or a prompt sheet closes, which re-grabs focus.
                isActive: isActive && terminal.isShellOpen && tab.prompter.current == nil,
                onFocus: onFocus)
            if let overlay = ConnectionOverlayModel(terminal: terminal) {
                ConnectionOverlay(
                    model: overlay,
                    onRetry: { Task { await terminal.reconnect() } },
                    onManageKnownHosts: { showKnownHosts = true })
            }
        }
        .sheet(item: promptBinding) { prompt in
            PromptSheet(prompt: prompt, prompter: tab.prompter)
        }
        .sheet(isPresented: $showKnownHosts) {
            KnownHostsView(env: env)
        }
    }

    /// Sheet binding; closing the sheet by any means declines the pending prompt.
    private var promptBinding: Binding<ConnectionPrompter.Prompt?> {
        Binding(
            get: { tab.prompter.current },
            set: { if $0 == nil { tab.prompter.cancelCurrent() } })
    }
}

/// What the overlay shows for the current terminal state.
struct ConnectionOverlayModel {
    enum Kind { case progress, failure, hostKeyChanged(expected: KnownHost, actual: KnownHost), ended }
    let kind: Kind
    let title: String
    let detail: String?
    let retryTitle: String?

    /// `nil` while the shell is open and healthy (no overlay).
    @MainActor
    init?(terminal: TerminalViewModel) {
        if let failure = terminal.failure {
            if case .hostKeyChanged(let expected, let actual) = failure {
                kind = .hostKeyChanged(expected: expected, actual: actual)
                title = String(localized: "Host key has changed")
                detail = nil
                retryTitle = nil
            } else {
                kind = .failure
                title = String(localized: "Connection failed")
                detail = failure.errorDescription
                retryTitle = String(localized: "Retry")
            }
            return
        }
        switch terminal.state {
        case .idle, .connecting:
            kind = .progress
            title = String(localized: "Connecting to \(terminal.profile.name)…")
            detail = nil
            retryTitle = nil
        case .awaitingHostKeyApproval:
            kind = .progress
            title = String(localized: "Waiting for host key approval…")
            detail = nil
            retryTitle = nil
        case .failed(let message):
            kind = .failure
            title = String(localized: "Connection failed")
            detail = message
            retryTitle = String(localized: "Retry")
        case .disconnected(let reason):
            kind = .ended
            title = String(localized: "Disconnected")
            detail = reason ?? Self.exitText(terminal.exit)
            retryTitle = String(localized: "Reconnect")
        case .connected:
            if terminal.isShellOpen { return nil }
            if terminal.exit != nil {
                kind = .ended
                title = String(localized: "Session ended")
                detail = Self.exitText(terminal.exit)
                retryTitle = String(localized: "Reconnect")
            } else {
                kind = .progress
                title = String(localized: "Opening shell…")
                detail = nil
                retryTitle = nil
            }
        }
    }

    private static func exitText(_ exit: ShellExit?) -> String? {
        switch exit {
        case .status(let code)?: String(localized: "The shell exited with status \(code).")
        case .signal(let name)?: String(localized: "The shell was terminated by signal \(name).")
        case nil: nil
        }
    }
}

/// Status card drawn over the terminal.
private struct ConnectionOverlay: View {
    let model: ConnectionOverlayModel
    let onRetry: () -> Void
    let onManageKnownHosts: () -> Void

    var body: some View {
        ZStack {
            Rectangle().fill(.background.opacity(0.85))
            card.padding(24)
        }
    }

    @ViewBuilder
    private var card: some View {
        switch model.kind {
        case .progress:
            VStack(spacing: 12) {
                ProgressView()
                Text(model.title).font(.headline)
            }
        case .failure, .ended:
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                Text(model.title).font(.headline)
                if let detail = model.detail {
                    Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .textSelection(.enabled)
                }
                if let retry = model.retryTitle {
                    Button(retry, action: onRetry).keyboardShortcut(.defaultAction)
                }
            }
        case .hostKeyChanged(let expected, let actual):
            HostKeyChangedWarning(
                expected: expected, actual: actual, onManage: onManageKnownHosts, onRetry: onRetry)
        }
    }
}

/// Red warning for a changed host key. There is deliberately no "connect anyway".
private struct HostKeyChangedWarning: View {
    let expected: KnownHost
    let actual: KnownHost
    let onManage: () -> Void
    /// Reconnects; still blocked unless the old key was removed first.
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(String(localized: "WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED"), systemImage: "exclamationmark.octagon.fill")
                .font(.headline).foregroundStyle(.red)
            Text("Someone could be eavesdropping on you (man-in-the-middle attack), or the server was reinstalled. The connection was blocked.")
            fingerprint(String(localized: "Trusted:"), expected.fingerprintSHA256)
            fingerprint(String(localized: "Presented:"), actual.fingerprintSHA256)
            Text("If you are certain the change is legitimate, remove the old key and connect again.")
                .foregroundStyle(.secondary)
            HStack {
                Button(String(localized: "Remove old key…"), role: .destructive, action: onManage)
                Button(String(localized: "Retry"), action: onRetry)
            }
        }
        .frame(maxWidth: 480, alignment: .leading)
        .padding(16)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.red, lineWidth: 2))
    }

    private func fingerprint(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        }
    }
}

/// Sheet for a connection prompt (password, passphrase, or unknown host key).
private struct PromptSheet: View {
    let prompt: ConnectionPrompter.Prompt
    let prompter: ConnectionPrompter

    var body: some View {
        switch prompt {
        case .password(let host):
            SecretPromptSheet(
                title: String(localized: "Password required"),
                message: String(localized: "Enter the password for \(host.username)@\(host.hostname)."),
                fieldLabel: String(localized: "Password"),
                onSubmit: { prompter.submit(secret: $0, saveToKeychain: $1) },
                onCancel: { prompter.cancelCurrent() })
        case .passphrase(let key, let attempt):
            SecretPromptSheet(
                title: String(localized: "Passphrase required"),
                message: String(localized: "Enter the passphrase for the key “\(key.label)”."),
                fieldLabel: String(localized: "Passphrase"),
                errorText: attempt > 1 ? String(localized: "Incorrect passphrase. Try again.") : nil,
                onSubmit: { prompter.submit(secret: $0, saveToKeychain: $1) },
                onCancel: { prompter.cancelCurrent() })
        case .hostKey(let key):
            HostKeyApprovalSheet(key: key, prompter: prompter)
        case .hostKeyChanged:
            EmptyView()
        }
    }
}

/// Trust-on-first-use approval showing the SHA256 fingerprint.
private struct HostKeyApprovalSheet: View {
    let key: KnownHost
    let prompter: ConnectionPrompter

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Unknown host").font(.headline)
            Text("The authenticity of “\(key.hostPattern)” can’t be established. Verify this fingerprint with the server’s administrator before continuing.")
                .fixedSize(horizontal: false, vertical: true)
            Text("\(key.keyType.rawValue.uppercased()) key fingerprint").font(.caption).foregroundStyle(.secondary)
            Text(key.fingerprintSHA256)
                .font(.system(.body, design: .monospaced)).textSelection(.enabled)
            HStack {
                Spacer()
                Button(String(localized: "Cancel"), role: .cancel) { prompter.decideHostKey(trust: false) }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Trust and Connect")) { prompter.decideHostKey(trust: true) }
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
