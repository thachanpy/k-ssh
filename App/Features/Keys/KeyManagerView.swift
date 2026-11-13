import SSHCore
import SwiftUI

/// Sheet listing SSH keys with import / generate / re-link / delete.
struct KeyManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: KeyManagerViewModel
    @State private var showGenerate = false
    @State private var keyPendingDelete: SSHKeyRef?
    @State private var notice: String?

    init(env: AppEnvironment) {
        _viewModel = State(initialValue: KeyManagerViewModel(env: env))
    }

    var body: some View {
        @Bindable var model = viewModel
        VStack(spacing: 0) {
            if model.rows.isEmpty {
                ContentUnavailableView(
                    String(localized: "No SSH keys"), systemImage: "key",
                    description: Text("Import an existing private key or generate a new one."))
                    .frame(maxHeight: .infinity)
            } else {
                List(model.rows) { row in
                    KeyRow(
                        row: row,
                        onCopy: { copyPublicKey(row.ref) },
                        onRelink: { relink(row.ref) },
                        onDelete: { keyPendingDelete = row.ref })
                }
            }
            Divider()
            HStack {
                Button(String(localized: "Import…")) { importKey() }
                Button(String(localized: "Generate…")) { showGenerate = true }
                Spacer()
                Button(String(localized: "Done")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 620, minHeight: 380)
        .task { await model.load() }
        .sheet(item: $model.pendingImport) { pending in
            SecretPromptSheet(
                title: String(localized: "Passphrase required"),
                message: String(localized: "“\(pending.label)” is encrypted. Enter its passphrase to add it."),
                fieldLabel: String(localized: "Passphrase"),
                errorText: model.passphraseError,
                onSubmit: { secret, save in
                    Task { await model.completeImport(passphrase: secret, saveToKeychain: save) }
                },
                onCancel: { model.cancelImport() })
        }
        .sheet(isPresented: $showGenerate) {
            GenerateKeySheet { label, comment in
                showGenerate = false
                generate(label: label, comment: comment)
            } onCancel: {
                showGenerate = false
            }
        }
        .confirmationDialog(
            String(localized: "Delete this key?"),
            isPresented: Binding(
                get: { keyPendingDelete != nil },
                set: { if !$0 { keyPendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: keyPendingDelete
        ) { ref in
            Button(String(localized: "Delete \(ref.label)"), role: .destructive) {
                Task { await model.delete(ref) }
            }
        } message: { ref in
            let users = model.rows.first { $0.ref.id == ref.id }?.usedBy ?? []
            if users.isEmpty {
                Text("The key file itself is not deleted.")
            } else {
                Text("Used by: \(users.joined(separator: ", ")). Those hosts will fail to authenticate until you choose another key. The key file itself is not deleted.")
            }
        }
        .alert(
            String(localized: "Error"),
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert(
            String(localized: "Done"),
            isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })
        ) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(notice ?? "")
        }
    }

    // MARK: Actions

    private func importKey() {
        guard let url = FilePanels.chooseKeyFile(message: String(localized: "Select a private key file")) else {
            return
        }
        Task { await viewModel.importKey(from: url) }
    }

    private func relink(_ ref: SSHKeyRef) {
        guard
            let url = FilePanels.chooseKeyFile(
                message: String(localized: "Select the private key file for “\(ref.label)”"))
        else { return }
        Task { await viewModel.relink(ref, to: url) }
    }

    private func copyPublicKey(_ ref: SSHKeyRef) {
        Task {
            if let line = await viewModel.publicKeyLine(for: ref) {
                FilePanels.copyToPasteboard(line)
                notice = String(localized: "Public key copied to the clipboard.")
            }
        }
    }

    private func generate(label: String, comment: String) {
        do {
            let generated = try viewModel.generate(comment: comment)
            let name = label.isEmpty ? "id_ed25519" : label
            guard let url = FilePanels.chooseSaveLocation(suggestedName: name) else { return }
            Task {
                if let line = await viewModel.writeAndRegister(generated, to: url, label: label) {
                    FilePanels.copyToPasteboard(line)
                    notice = String(localized: "Key created. The public key was copied to the clipboard.")
                }
            }
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }
    }
}

/// One key in the list.
private struct KeyRow: View {
    let row: KeyManagerViewModel.Row
    let onCopy: () -> Void
    let onRelink: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(row.ref.label).font(.headline)
                    Text(row.ref.keyType.rawValue.uppercased()).font(.caption).foregroundStyle(.secondary)
                    if row.ref.hasPassphrase {
                        Label(String(localized: "Passphrase"), systemImage: "lock").font(.caption)
                    }
                    statusBadge
                }
                Text(row.ref.fingerprintSHA256)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if !row.usedBy.isEmpty {
                    Text("Used by \(row.usedBy.count) host(s)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(action: onCopy) { Image(systemName: "doc.on.doc") }
                .help(String(localized: "Copy public key"))
                .accessibilityLabel(String(localized: "Copy public key"))
                .disabled(row.status != .ok)
            if row.status != .ok {
                Button(action: onRelink) { Image(systemName: "link") }
                    .help(String(localized: "Re-link key file"))
                    .accessibilityLabel(String(localized: "Re-link key file"))
            }
            Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                .help(String(localized: "Delete key"))
                .accessibilityLabel(String(localized: "Delete key"))
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch row.status {
        case .ok: EmptyView()
        case .stale:
            Label(String(localized: "Access expired"), systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        case .missing:
            Label(String(localized: "File missing"), systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.red)
        }
    }
}

/// Asks for the key's file name and comment before generating.
private struct GenerateKeySheet: View {
    @State private var label = "id_ed25519"
    @State private var comment = "\(NSUserName())@\(ProcessInfo.processInfo.hostName)"
    let onGenerate: (_ label: String, _ comment: String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Generate Ed25519 key").font(.headline)
            TextField(String(localized: "Name"), text: $label)
            TextField(String(localized: "Comment"), text: $comment)
            Text("You will choose where to save the private key next. The public key is copied to the clipboard.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(String(localized: "Cancel"), role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Generate…")) { onGenerate(label, comment) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
