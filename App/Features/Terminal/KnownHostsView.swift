import SSHCore
import SwiftUI

/// Sheet listing trusted server host keys, with removal.
struct KnownHostsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: KnownHostsViewModel
    @State private var pendingRemoval: KnownHost?

    init(env: AppEnvironment) {
        _viewModel = State(initialValue: KnownHostsViewModel(env: env))
    }

    var body: some View {
        @Bindable var model = viewModel
        VStack(spacing: 0) {
            if model.hosts.isEmpty {
                ContentUnavailableView(
                    String(localized: "No trusted hosts"), systemImage: "checkmark.shield",
                    description: Text("Hosts you trust when connecting appear here."))
                    .frame(maxHeight: .infinity)
            } else {
                List(model.hosts) { host in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(host.hostPattern).font(.headline)
                            Text("\(host.keyType.rawValue.uppercased())  \(host.fingerprintSHA256)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        Button(role: .destructive) { pendingRemoval = host } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help(String(localized: "Remove trusted key"))
                        .accessibilityLabel(String(localized: "Remove trusted key"))
                    }
                }
            }
            Divider()
            HStack {
                Spacer()
                Button(String(localized: "Done")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 560, minHeight: 320)
        .task { await model.load() }
        .confirmationDialog(
            String(localized: "Remove this trusted key?"),
            isPresented: Binding(
                get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible, presenting: pendingRemoval
        ) { host in
            Button(String(localized: "Remove \(host.hostPattern)"), role: .destructive) {
                Task { await model.remove(host) }
            }
        } message: { _ in
            Text("You will be asked to verify the server’s fingerprint again on the next connection.")
        }
        .alert(
            String(localized: "Error"),
            isPresented: Binding(
                get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}
