import SSHCore
import SwiftUI

/// One host in the sidebar: icon with live status dot, name, `user@host`, tags, hover Connect button.
struct HostRowView: View {
    let host: HostProfile
    /// Live connection state of an open tab for this host, if any.
    let status: ConnectionState?
    let connect: () -> Void
    @State private var hovering = false

    private var isReadOnly: Bool { host.source == .sshConfig }

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            icon
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                HStack(spacing: Theme.Spacing.xs) {
                    Text(host.name).font(.headline).lineLimit(1)
                    if isReadOnly {
                        Image(systemName: "lock.fill")
                            .font(.caption2).foregroundStyle(.tertiary)
                            .help(String(localized: "Read-only, from ~/.ssh/config"))
                    }
                }
                Text(address).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if !host.tags.isEmpty {
                    HStack(spacing: Theme.Spacing.xs) {
                        ForEach(host.tags.prefix(3), id: \.self) { TagChip(text: $0) }
                    }
                }
            }
            Spacer(minLength: 0)
            if hovering {
                Button(action: connect) {
                    Image(systemName: "play.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Connect"))
                .accessibilityLabel(String(localized: "Connect to \(host.name)"))
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
    }

    private var icon: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: isReadOnly ? "doc.text" : "server.rack")
                .symbolRenderingMode(.hierarchical)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: Theme.Layout.hostIcon, height: Theme.Layout.hostIcon)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Radius.small))
            if let status {
                StatusDot(state: status)
                    .overlay(Circle().stroke(.background, lineWidth: 1.5))
            }
        }
    }

    private var address: String {
        "\(host.username)@\(host.hostname)\(host.port == 22 ? "" : ":\(host.port)")"
    }
}
