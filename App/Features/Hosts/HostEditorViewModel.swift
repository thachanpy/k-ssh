import Foundation
import Observation
import SSHCore

/// Form state and save logic for creating/editing a host.
///
/// The password never touches `hosts.json`: on save it goes to the Keychain only. When editing, the
/// stored password is not loaded into the form; a blank field means "keep the saved password".
@MainActor
@Observable
final class HostEditorViewModel {
    enum AuthChoice: String, CaseIterable, Identifiable {
        case password
        case key

        var id: String { rawValue }
    }

    var name = ""
    var hostname = ""
    var portText = "22"
    var username = ""
    var authChoice: AuthChoice = .password
    /// New password; empty means "unchanged" when editing.
    var password = ""
    var keyID: UUID?
    var tagsText = ""
    /// Bastion to connect through (`nil` = direct).
    var jumpHostID: UUID?
    /// Log this host's terminal output to disk (off by default).
    var logOutput = false

    private(set) var availableKeys: [SSHKeyRef] = []
    /// Other hosts that can serve as a jump host.
    private(set) var availableJumpHosts: [HostProfile] = []
    private(set) var hasSavedPassword = false
    private(set) var isSaving = false
    var errorMessage: String?

    let isNew: Bool
    private let original: HostProfile?
    private let env: AppEnvironment

    /// Creates the editor for a new host or an existing one.
    init(request: HostEditorRequest, env: AppEnvironment) {
        self.env = env
        switch request {
        case .create:
            isNew = true
            original = nil
        case .edit(let host):
            isNew = false
            original = host
            name = host.name
            hostname = host.hostname
            portText = String(host.port)
            username = host.username
            tagsText = host.tags.joined(separator: ", ")
            jumpHostID = host.jumpHostID
            switch host.auth {
            case .password:
                authChoice = .password
            case .privateKey(let id):
                authChoice = .key
                keyID = id
            }
        }
    }

    /// Loads the key list and whether a password is already saved.
    func load() async {
        availableKeys = (try? await env.keys.all()) ?? []
        if let original { logOutput = env.isLogging(hostID: original.id) }
        availableJumpHosts = ((try? await env.hosts.all()) ?? []).filter { $0.id != original?.id }
        if let original, case .password = original.auth {
            hasSavedPassword = ((try? await env.keychain.get(.hostPassword(original.id))) ?? nil) != nil
        }
        if authChoice == .key, keyID == nil { keyID = availableKeys.first?.id }
    }

    /// Port parsed from the text field, if valid (1–65535).
    var port: Int? {
        guard let value = Int(portText.trimmingCharacters(in: .whitespaces)), (1...65535).contains(value) else {
            return nil
        }
        return value
    }

    /// Human-readable validation problems; empty when the form can be saved.
    var validationErrors: [String] {
        var errors: [String] = []
        if hostname.trimmingCharacters(in: .whitespaces).isEmpty {
            errors.append(String(localized: "Hostname is required."))
        }
        if port == nil {
            errors.append(String(localized: "Port must be a number from 1 to 65535."))
        }
        if username.trimmingCharacters(in: .whitespaces).isEmpty {
            errors.append(String(localized: "Username is required."))
        }
        if authChoice == .key, keyID == nil {
            errors.append(String(localized: "Choose an SSH key (add one in SSH Keys first)."))
        }
        return errors
    }

    var canSave: Bool {
        validationErrors.isEmpty && !isSaving
    }

    /// Validates and saves. Returns `true` when everything (host and Keychain) succeeded.
    func save() async -> Bool {
        guard canSave, let port else { return false }
        isSaving = true
        defer { isSaving = false }

        let id = original?.id ?? UUID()
        let trimmedHostname = hostname.trimmingCharacters(in: .whitespaces)
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let auth: AuthMethod
        switch authChoice {
        case .password: auth = .password
        case .key: auth = .privateKey(keyID: keyID ?? UUID())
        }
        let profile = HostProfile(
            id: id,
            name: trimmedName.isEmpty ? trimmedHostname : trimmedName,
            hostname: trimmedHostname,
            port: port,
            username: username.trimmingCharacters(in: .whitespaces),
            auth: auth,
            jumpHostID: jumpHostID,
            tags: Self.parseTags(tagsText),
            source: .local,
            createdAt: original?.createdAt ?? Date(),
            lastConnectedAt: original?.lastConnectedAt)

        do {
            // Reject cycles and dangling links before anything is saved.
            _ = try JumpChain.resolve(for: profile, hosts: availableJumpHosts + [profile])
            try await env.hosts.upsert(profile)
            switch authChoice {
            case .password:
                if !password.isEmpty { try await env.keychain.set(password, for: .hostPassword(id)) }
            case .key:
                try await env.keychain.delete(.hostPassword(id))
            }
            password = ""
            let wantsLog = logOutput
            await env.updateSettings { settings in
                var ids = Set(settings.loggedHostIDs ?? [])
                if wantsLog { ids.insert(id) } else { ids.remove(id) }
                settings.loggedHostIDs = ids.isEmpty ? nil : Array(ids)
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Splits "a, b  c" into unique, trimmed tags (order preserved).
    static func parseTags(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map { String($0) }
            .filter { seen.insert($0.lowercased()).inserted }
    }
}
