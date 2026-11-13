import SwiftUI

/// Reusable sheet that asks for a secret (password or key passphrase) with an optional
/// "Save to Keychain" checkbox.
struct SecretPromptSheet: View {
    let title: String
    let message: String
    let fieldLabel: String
    /// Error from a previous attempt, shown in red.
    var errorText: String?
    var onSubmit: (_ secret: String, _ save: Bool) -> Void
    var onCancel: () -> Void

    @State private var secret = ""
    @State private var save = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SecureField(fieldLabel, text: $secret)
                .focused($focused)
                .onSubmit(submit)
            if let errorText {
                Text(errorText).foregroundStyle(.red)
            }
            Toggle(String(localized: "Save to Keychain"), isOn: $save)
            HStack {
                Spacer()
                Button(String(localized: "Cancel"), role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Continue"), action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(secret.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear { focused = true }
    }

    private func submit() {
        guard !secret.isEmpty else { return }
        onSubmit(secret, save)
    }
}
