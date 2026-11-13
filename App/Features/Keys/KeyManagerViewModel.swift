import Foundation
import Observation
import SSHCore

/// Manages SSH key references: import, generate, re-link, delete, status.
///
/// Only a security-scoped bookmark and public metadata are stored; key text is read transiently.
@MainActor
@Observable
final class KeyManagerViewModel {
    enum Status: Equatable {
        case ok
        /// Bookmark is stale and could not be refreshed automatically: re-link the key file.
        case stale
        /// File deleted/moved or access lost: re-link the key file.
        case missing
    }

    struct Row: Identifiable {
        let ref: SSHKeyRef
        let status: Status
        /// Names of hosts that authenticate with this key.
        let usedBy: [String]
        var id: UUID { ref.id }
    }

    /// An imported encrypted key waiting for its passphrase.
    struct PendingImport: Identifiable {
        let id = UUID()
        let bookmark: Data
        let info: PublicKeyInfo
        let label: String
        let keyText: String
    }

    private(set) var rows: [Row] = []
    var errorMessage: String?
    var pendingImport: PendingImport?
    /// Shown inside the passphrase sheet after a wrong attempt.
    private(set) var passphraseError: String?

    private let env: AppEnvironment

    init(env: AppEnvironment) {
        self.env = env
    }

    /// Reloads keys, host usage, and checks each key file's status.
    func load() async {
        let keys = (try? await env.keys.all()) ?? []
        let hosts = (try? await env.hosts.all()) ?? []
        var result: [Row] = []
        for key in keys {
            var current = key
            let status = await checkStatus(of: &current)
            let users = hosts.filter { host in
                if case .privateKey(let id) = host.auth { return id == key.id }
                return false
            }.map(\.name)
            result.append(Row(ref: current, status: status, usedBy: users))
        }
        rows = result
    }

    // MARK: Import

    /// Starts importing the key file at `url` (chosen with `NSOpenPanel`).
    /// Encrypted keys set `pendingImport` to ask for the passphrase.
    func importKey(from url: URL) async {
        errorMessage = nil
        // The panel-selected URL is readable right now; read it directly, then bookmark it.
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let bookmark = try await env.bookmarks.makeBookmark(for: url)
            let info = try PrivateKeyLoader.publicKeyInfo(of: text)
            let label = url.lastPathComponent
            if info.isEncrypted {
                passphraseError = nil
                pendingImport = PendingImport(bookmark: bookmark, info: info, label: label, keyText: text)
            } else {
                try await store(bookmark: bookmark, info: info, label: label, savedPassphrase: nil)
            }
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    /// User-facing text; keeps the specific bookmark/file cause instead of the generic mapped message.
    private static func describe(_ error: Error) -> String {
        if error is BookmarkError || error is CocoaError {
            return error.localizedDescription
        }
        return SSHError.map(error).errorDescription ?? error.localizedDescription
    }

    /// Completes an import of an encrypted key with the entered passphrase.
    func completeImport(passphrase: String, saveToKeychain: Bool) async {
        guard let pending = pendingImport else { return }
        do {
            _ = try PrivateKeyLoader.validate(keyText: pending.keyText, passphrase: passphrase)
        } catch {
            passphraseError = String(localized: "Incorrect passphrase. Try again.")
            return
        }
        do {
            try await store(
                bookmark: pending.bookmark, info: pending.info, label: pending.label,
                savedPassphrase: saveToKeychain ? passphrase : nil)
            pendingImport = nil
        } catch {
            pendingImport = nil
            errorMessage = SSHError.map(error).errorDescription ?? error.localizedDescription
        }
    }

    func cancelImport() {
        pendingImport = nil
        passphraseError = nil
    }

    // MARK: Generate

    /// Generates a new Ed25519 key in memory (the caller writes it with `writeAndRegister`).
    func generate(comment: String) throws -> GeneratedKey {
        try KeyGenerator.generateEd25519(comment: comment)
    }

    /// Writes a generated private key to `url` (mode 0600), registers it, and returns its public line.
    func writeAndRegister(_ generated: GeneratedKey, to url: URL, label: String) async -> String? {
        do {
            try Data(generated.privateKeyText.utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let bookmark = try await env.bookmarks.makeBookmark(for: url)
            try await store(
                bookmark: bookmark, info: generated.publicKey,
                label: label.isEmpty ? url.lastPathComponent : label, savedPassphrase: nil)
            return generated.publicKeyLine
        } catch {
            errorMessage = SSHError.map(error).errorDescription ?? error.localizedDescription
            return nil
        }
    }

    // MARK: Other actions

    /// The `authorized_keys` line for a key (read from its file), or `nil` with `errorMessage` set.
    func publicKeyLine(for ref: SSHKeyRef) async -> String? {
        do {
            let text = try await readKeyText(bookmark: ref.bookmarkData)
            let info = try PrivateKeyLoader.publicKeyInfo(of: text)
            return "\(info.openSSHLine) \(ref.label)"
        } catch {
            errorMessage = SSHError.map(error).errorDescription ?? error.localizedDescription
            return nil
        }
    }

    /// Re-links a stale/missing key to a newly chosen file with the same fingerprint.
    func relink(_ ref: SSHKeyRef, to url: URL) async {
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let bookmark = try await env.bookmarks.makeBookmark(for: url)
            let info = try PrivateKeyLoader.publicKeyInfo(of: text)
            guard info.fingerprintSHA256 == ref.fingerprintSHA256 else {
                errorMessage = String(localized: "That file is a different key (fingerprint does not match).")
                return
            }
            var updated = ref
            updated.bookmarkData = bookmark
            try await env.keys.upsert(updated)
            await load()
        } catch {
            errorMessage = SSHError.map(error).errorDescription ?? error.localizedDescription
        }
    }

    /// Deletes the key reference and its saved passphrase. The key file itself is never touched.
    func delete(_ ref: SSHKeyRef) async {
        do {
            try await env.keys.delete(id: ref.id)
            try await env.keychain.delete(.keyPassphrase(ref.id))
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Private

    private func store(bookmark: Data, info: PublicKeyInfo, label: String, savedPassphrase: String?) async throws {
        let existing = try await env.keys.all()
        guard !existing.contains(where: { $0.fingerprintSHA256 == info.fingerprintSHA256 }) else {
            throw SSHError.invalidKeyFile(String(localized: "this key has already been added"))
        }
        let ref = SSHKeyRef(
            label: label, keyType: info.kind == .ed25519 ? .ed25519 : .rsa, bookmarkData: bookmark,
            fingerprintSHA256: info.fingerprintSHA256, hasPassphrase: info.isEncrypted)
        try await env.keys.upsert(ref)
        if let savedPassphrase { try await env.keychain.set(savedPassphrase, for: .keyPassphrase(ref.id)) }
        await load()
    }

    private func readKeyText(bookmark: Data) async throws -> String {
        try await env.bookmarks.withAccess(to: bookmark) { url in
            try String(contentsOf: url, encoding: .utf8)
        }
    }

    /// Resolves the bookmark; refreshes it in place when only stale and refreshable.
    private func checkStatus(of ref: inout SSHKeyRef) async -> Status {
        do {
            let exists = try await env.bookmarks.withAccess(to: ref.bookmarkData) { url in
                FileManager.default.fileExists(atPath: url.path)
            }
            return exists ? .ok : .missing
        } catch BookmarkError.stale(let refreshed) {
            guard let refreshed else { return .stale }
            ref.bookmarkData = refreshed
            _ = try? await env.keys.upsert(ref)
            return .ok
        } catch {
            return .missing
        }
    }
}
