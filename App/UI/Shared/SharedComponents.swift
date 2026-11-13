import SSHCore
import SwiftUI

/// Small colored dot for a connection state; gray when there is no live connection.
struct StatusDot: View {
    let state: ConnectionState?

    var body: some View {
        Circle()
            .fill(state?.statusColor ?? .gray)
            .frame(width: Theme.Layout.statusDot, height: Theme.Layout.statusDot)
            .accessibilityLabel(state?.statusDescription ?? String(localized: "Not connected"))
    }
}

/// Rounded "pill" for a short tag.
struct TagChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.xxs)
            .background(.quaternary, in: Capsule())
    }
}

/// Subtle background while the pointer is over the view.
private struct HoverHighlight: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.small)
                    .fill(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
            )
            .onHover { hovering = $0 }
    }
}

extension View {
    /// Adds a hover highlight (for icon buttons and list-like rows).
    func hoverHighlight() -> some View { modifier(HoverHighlight()) }
}

/// Borderless icon-only button with tooltip and accessibility label.
struct ToolbarIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .frame(width: Theme.Layout.iconButton, height: Theme.Layout.iconButton)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .hoverHighlight()
        .help(help)
        .accessibilityLabel(help)
    }
}
