import Foundation
import Observation
import SSHCore

/// Bridges `SSHPrompts` (async closures called by the SSH session) to UI sheets for one tab.
///
/// The session awaits a continuation; the sheet resolves it. Only one prompt is shown at a time.
@MainActor
@Observable
final class ConnectionPrompter {
    /// What the tab's sheet should currently show.
    enum Prompt: Identifiable {
        case password(HostProfile)
        case passphrase(SSHKeyRef, attempt: Int)
        case hostKey(KnownHost)
        /// Informational only (no continuation): the server key changed; there is no bypass.
        case hostKeyChanged(expected: KnownHost, actual: KnownHost)

        var id: String {
            switch self {
            case .password(let host): "password-\(host.id)"
            case .passphrase(let key, let attempt): "passphrase-\(key.id)-\(attempt)"
            case .hostKey(let key): "hostkey-\(key.hostPattern)"
            case .hostKeyChanged(let expected, _): "hostkeychanged-\(expected.hostPattern)"
            }
        }
    }

    /// The prompt to present, or `nil`.
    private(set) var current: Prompt?

    private var secretContinuation: CheckedContinuation<PasswordPromptResult?, Never>?
    private var trustContinuation: CheckedContinuation<Bool, Never>?

    init() {}

    /// Prompt callbacks to hand to `SSHSessionActor`.
    var sshPrompts: SSHPrompts {
        SSHPrompts(
            password: { [weak self] host in await self?.askPassword(host) },
            passphrase: { [weak self] key, attempt in await self?.askPassphrase(key, attempt: attempt) },
            hostKey: { [weak self] key in await self?.askHostKey(key) ?? false })
    }

    // MARK: Called by the session (via the closures above)

    func askPassword(_ host: HostProfile) async -> PasswordPromptResult? {
        await ask(.password(host))
    }

    func askPassphrase(_ key: SSHKeyRef, attempt: Int) async -> PasswordPromptResult? {
        await ask(.passphrase(key, attempt: attempt))
    }

    func askHostKey(_ key: KnownHost) async -> Bool {
        await withCheckedContinuation { continuation in
            cancelPending()
            trustContinuation = continuation
            current = .hostKey(key)
        }
    }

    // MARK: Called by the sheets

    /// Completes a password/passphrase prompt.
    func submit(secret: String, saveToKeychain: Bool) {
        let continuation = secretContinuation
        secretContinuation = nil
        current = nil
        continuation?.resume(returning: PasswordPromptResult(secret: secret, saveToKeychain: saveToKeychain))
    }

    /// Completes a host-key prompt.
    func decideHostKey(trust: Bool) {
        let continuation = trustContinuation
        trustContinuation = nil
        current = nil
        continuation?.resume(returning: trust)
    }

    /// Shows the "host key changed" warning (informational, no continuation).
    func showHostKeyChanged(expected: KnownHost, actual: KnownHost) {
        cancelPending()
        current = .hostKeyChanged(expected: expected, actual: actual)
    }

    /// Dismisses/cancels whatever is showing (sheet closed, tab closed). Pending prompts resolve as declined.
    func cancelCurrent() {
        cancelPending()
        current = nil
    }

    // MARK: - Private

    private func ask(_ prompt: Prompt) async -> PasswordPromptResult? {
        await withCheckedContinuation { continuation in
            cancelPending()
            secretContinuation = continuation
            current = prompt
        }
    }

    private func cancelPending() {
        if let continuation = secretContinuation {
            secretContinuation = nil
            continuation.resume(returning: nil)
        }
        if let continuation = trustContinuation {
            trustContinuation = nil
            continuation.resume(returning: false)
        }
    }
}
