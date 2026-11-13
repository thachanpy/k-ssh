import Foundation

/// A secret entered by the user, plus whether to remember it.
public struct PasswordPromptResult: Sendable {
    public var secret: String
    /// Save to the Keychain after the connection succeeds.
    public var saveToKeychain: Bool

    /// Creates a prompt result.
    public init(secret: String, saveToKeychain: Bool) {
        self.secret = secret
        self.saveToKeychain = saveToKeychain
    }
}

/// Async callbacks the session uses to ask the user for input. Injected by the UI layer.
///
/// Returning `nil` / `false` means the user cancelled.
public struct SSHPrompts: Sendable {
    /// Ask for a host's login password.
    public var password: @Sendable (HostProfile) async -> PasswordPromptResult?
    /// Ask for a key's passphrase. `attempt` starts at 1 and increases after each wrong passphrase.
    public var passphrase: @Sendable (SSHKeyRef, _ attempt: Int) async -> PasswordPromptResult?
    /// Ask whether to trust an unknown host key.
    public var hostKey: @Sendable (KnownHost) async -> Bool

    /// Creates a prompt set.
    public init(
        password: @escaping @Sendable (HostProfile) async -> PasswordPromptResult?,
        passphrase: @escaping @Sendable (SSHKeyRef, Int) async -> PasswordPromptResult?,
        hostKey: @escaping @Sendable (KnownHost) async -> Bool
    ) {
        self.password = password
        self.passphrase = passphrase
        self.hostKey = hostKey
    }

    /// Declines every prompt (useful default for non-interactive use and tests).
    public static let denyAll = SSHPrompts(
        password: { _ in nil }, passphrase: { _, _ in nil }, hostKey: { _ in false })
}
