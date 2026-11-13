import Foundation

/// Secret material needed to authenticate. Held in memory only for the duration of a connect.
public enum SSHCredential: Sendable {
    case password(String)
    case privateKey(text: String, passphrase: String?)
}

/// A credential plus an optional Keychain write to perform *after* authentication succeeds
/// (so a mistyped password is never saved).
public struct ResolvedCredential: Sendable {
    public let credential: SSHCredential
    public let pendingSave: (key: SecretKey, secret: String)?
}

/// Finds credentials for a host: Keychain first, then user prompts.
///
/// Concurrency: `Sendable` value type of Sendable services; prompts are awaited, not blocked on.
public struct CredentialResolver: Sendable {
    /// Maximum passphrase attempts before giving up with `.invalidPassphrase`.
    public static let maxPassphraseAttempts = 3

    private let keychain: any KeychainProviding
    private let bookmarks: BookmarkService
    private let keys: KeyRepository
    private let prompts: SSHPrompts

    /// Creates a resolver.
    public init(
        keychain: any KeychainProviding, bookmarks: BookmarkService, keys: KeyRepository,
        prompts: SSHPrompts
    ) {
        self.keychain = keychain
        self.bookmarks = bookmarks
        self.keys = keys
        self.prompts = prompts
    }

    /// Resolves the credential for `profile`'s auth method.
    /// - Throws: `SSHError` (`credentialsUnavailable`, `keyFileUnavailable`, `invalidPassphrase`, …).
    public func resolve(for profile: HostProfile) async throws -> ResolvedCredential {
        switch profile.auth {
        case .password:
            return try await resolvePassword(for: profile)
        case .privateKey(let keyID):
            return try await resolveKey(keyID: keyID)
        }
    }

    private func resolvePassword(for profile: HostProfile) async throws -> ResolvedCredential {
        if let saved = try await keychain.get(.hostPassword(profile.id)) {
            return ResolvedCredential(credential: .password(saved), pendingSave: nil)
        }
        try Task.checkCancellation()
        guard let result = await prompts.password(profile) else { throw SSHError.credentialsUnavailable }
        let save = result.saveToKeychain ? (SecretKey.hostPassword(profile.id), result.secret) : nil
        return ResolvedCredential(credential: .password(result.secret), pendingSave: save)
    }

    private func resolveKey(keyID: UUID) async throws -> ResolvedCredential {
        guard let ref = try await keys.get(keyID) else { throw SSHError.keyFileUnavailable }
        let text: String
        do {
            text = try await bookmarks.withAccess(to: ref.bookmarkData) { url in
                try String(contentsOf: url, encoding: .utf8)
            }
        } catch let error as BookmarkError {
            throw SSHError.map(error)
        } catch {
            throw SSHError.keyFileUnavailable
        }

        let info = try PrivateKeyLoader.inspect(text)
        guard info.isEncrypted else {
            return ResolvedCredential(credential: .privateKey(text: text, passphrase: nil), pendingSave: nil)
        }

        // 1. Saved passphrase.
        if let saved = try await keychain.get(.keyPassphrase(ref.id)) {
            if (try? PrivateKeyLoader.validate(keyText: text, passphrase: saved)) != nil {
                return ResolvedCredential(credential: .privateKey(text: text, passphrase: saved), pendingSave: nil)
            }
        }
        // 2. Prompt, up to `maxPassphraseAttempts` times.
        for attempt in 1...Self.maxPassphraseAttempts {
            try Task.checkCancellation()
            guard let result = await prompts.passphrase(ref, attempt) else {
                throw SSHError.credentialsUnavailable
            }
            if (try? PrivateKeyLoader.validate(keyText: text, passphrase: result.secret)) != nil {
                let save = result.saveToKeychain ? (SecretKey.keyPassphrase(ref.id), result.secret) : nil
                return ResolvedCredential(
                    credential: .privateKey(text: text, passphrase: result.secret), pendingSave: save)
            }
        }
        throw SSHError.invalidPassphrase
    }
}
