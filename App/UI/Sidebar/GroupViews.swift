import SSHCore
import SwiftUI

/// Folder row label: icon, name, host count; highlights while a host is dragged over it.
struct GroupHeaderView: View {
    let group: HostGroup
    let count: Int
    let isTargeted: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: isTargeted ? "folder.fill.badge.plus" : "folder.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
            Text(group.name).font(.headline).lineLimit(1)
            Spacer(minLength: 0)
            Text("\(count)")
                .font(.caption).foregroundStyle(.tertiary).monospacedDigit()
        }
        .padding(.vertical, Theme.Spacing.xxs)
        .padding(.horizontal, Theme.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.small)
                .fill(isTargeted ? AnyShapeStyle(.tint.opacity(0.2)) : AnyShapeStyle(.clear))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "Group \(group.name), \(count) hosts"))
    }
}

/// Small dialog to name a new group or rename one.
struct GroupNameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let prompt: GroupPrompt
    let onSubmit: (String) -> Void
    @State private var name: String

    init(prompt: GroupPrompt, onSubmit: @escaping (String) -> Void) {
        self.prompt = prompt
        self.onSubmit = onSubmit
        switch prompt {
        case .create: _name = State(initialValue: "")
        case .rename(let group): _name = State(initialValue: group.name)
        }
    }

    private var title: String {
        switch prompt {
        case .create: String(localized: "New Group")
        case .rename: String(localized: "Rename Group")
        }
    }

    private var isValid: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text(title).font(.headline)
            TextField(String(localized: "Group name"), text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            HStack {
                Spacer()
                Button(String(localized: "Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Save"), action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(Theme.Spacing.lg)
        .frame(width: 340)
    }

    private func submit() {
        guard isValid else { return }
        onSubmit(name)
        dismiss()
    }
}
