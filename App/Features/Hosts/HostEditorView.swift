import SSHCore
import SwiftUI

/// Sheet for creating or editing a host.
struct HostEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: HostEditorViewModel

    init(request: HostEditorRequest, env: AppEnvironment) {
        _viewModel = State(initialValue: HostEditorViewModel(request: request, env: env))
    }

    var body: some View {
        @Bindable var model = viewModel
        VStack(spacing: 0) {
            Form {
                Section(String(localized: "Host")) {
                    TextField(String(localized: "Name"), text: $model.name, prompt: Text("Defaults to hostname"))
                    TextField(String(localized: "Hostname"), text: $model.hostname)
                    TextField(String(localized: "Port"), text: $model.portText)
                    TextField(String(localized: "Username"), text: $model.username)
                    TextField(String(localized: "Tags"), text: $model.tagsText, prompt: Text("prod, db"))
                }
                Section(String(localized: "Authentication")) {
                    Picker(String(localized: "Method"), selection: $model.authChoice) {
                        Text("Password").tag(HostEditorViewModel.AuthChoice.password)
                        Text("Private key").tag(HostEditorViewModel.AuthChoice.key)
                    }
                    .pickerStyle(.segmented)
                    authFields($model)
                }
                Section(String(localized: "Jump host")) {
                    Picker(String(localized: "Connect through"), selection: $model.jumpHostID) {
                        Text("None (direct)").tag(UUID?.none)
                        ForEach(model.availableJumpHosts) { host in
                            Text(host.name).tag(UUID?.some(host.id))
                        }
                    }
                    Text("The jump host is verified and authenticated first; this host is reached through it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section(String(localized: "Logging")) {
                    Toggle(String(localized: "Save terminal output to a log file"), isOn: $model.logOutput)
                    Text("Logs are plain text and may contain sensitive output such as passwords typed or printed. They are deleted after the retention period (30 days by default).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !model.validationErrors.isEmpty {
                    Section {
                        ForEach(model.validationErrors, id: \.self) { message in
                            Label(message, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if let message = model.errorMessage {
                    Text(message).foregroundStyle(.red).lineLimit(2)
                }
                Spacer()
                Button(String(localized: "Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(model.isNew ? String(localized: "Add") : String(localized: "Save")) {
                    Task {
                        if await model.save() { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSave)
            }
            .padding()
        }
        .frame(minWidth: 460, minHeight: 480)
        .task { await model.load() }
    }

    @ViewBuilder
    private func authFields(_ model: Bindable<HostEditorViewModel>) -> some View {
        if model.wrappedValue.authChoice == .password {
            SecureField(
                String(localized: "Password"), text: model.password,
                prompt: Text(
                    model.wrappedValue.hasSavedPassword
                        ? "Saved in Keychain — leave blank to keep" : "Stored in the Keychain"))
        } else if model.wrappedValue.availableKeys.isEmpty {
            Text("No SSH keys yet. Add one with the key button in the sidebar.")
                .foregroundStyle(.secondary)
        } else {
            Picker(String(localized: "Key"), selection: model.keyID) {
                ForEach(model.wrappedValue.availableKeys) { key in
                    Text("\(key.label) (\(key.keyType.rawValue))").tag(Optional(key.id))
                }
            }
        }
    }
}
