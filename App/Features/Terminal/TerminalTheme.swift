import AppKit
import SwiftTerm

/// A terminal color scheme: background, text, cursor, selection and the 16 ANSI colors.
/// Colors are `0xRRGGBB` values so themes stay plain data.
struct TerminalTheme: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let background: UInt32
    let foreground: UInt32
    let cursor: UInt32
    let selection: UInt32
    /// Exactly 16 entries: 8 normal, then 8 bright.
    let ansi: [UInt32]

    /// `true` for schemes with a light background (used for previews and contrast).
    var isLight: Bool {
        let r = Double((background >> 16) & 0xFF)
        let g = Double((background >> 8) & 0xFF)
        let b = Double(background & 0xFF)
        return (0.299 * r + 0.587 * g + 0.114 * b) > 140
    }

    var nsBackground: NSColor { Self.ns(background) }
    var nsForeground: NSColor { Self.ns(foreground) }
    var nsCursor: NSColor { Self.ns(cursor) }
    var nsSelection: NSColor { Self.ns(selection) }

    /// The 16 ANSI colors in SwiftTerm's color type.
    var swiftTermPalette: [SwiftTerm.Color] {
        ansi.map { value in
            SwiftTerm.Color(
                red8: UInt16((value >> 16) & 0xFF), green8: UInt16((value >> 8) & 0xFF),
                blue8: UInt16(value & 0xFF))
        }
    }

    static func ns(_ value: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    /// The theme with this ID, or the default when unknown or `nil`.
    static func theme(id: String?) -> TerminalTheme {
        all.first { $0.id == id } ?? classic
    }

    static let classic = TerminalTheme(
        id: "classic", name: "Classic", background: 0x000000, foreground: 0xCBCCCD, cursor: 0xFFFFFF,
        selection: 0x3A4A5E,
        ansi: [
            0x000000, 0xC23621, 0x25BC24, 0xADAD27, 0x492EE1, 0xD338D3, 0x33BBC8, 0xCBCCCD,
            0x818383, 0xFC391F, 0x31E722, 0xEAEC23, 0x5833FF, 0xF935F8, 0x14F0F0, 0xE9EBEB,
        ])

    static let dracula = TerminalTheme(
        id: "dracula", name: "Dracula", background: 0x282A36, foreground: 0xF8F8F2, cursor: 0xF8F8F2,
        selection: 0x44475A,
        ansi: [
            0x21222C, 0xFF5555, 0x50FA7B, 0xF1FA8C, 0xBD93F9, 0xFF79C6, 0x8BE9FD, 0xF8F8F2,
            0x6272A4, 0xFF6E6E, 0x69FF94, 0xFFFFA5, 0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xFFFFFF,
        ])

    static let oneDark = TerminalTheme(
        id: "one-dark", name: "One Dark", background: 0x282C34, foreground: 0xABB2BF, cursor: 0x528BFF,
        selection: 0x3E4451,
        ansi: [
            0x282C34, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xABB2BF,
            0x545862, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xC8CCD4,
        ])

    static let nord = TerminalTheme(
        id: "nord", name: "Nord", background: 0x2E3440, foreground: 0xD8DEE9, cursor: 0xD8DEE9,
        selection: 0x434C5E,
        ansi: [
            0x3B4252, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x88C0D0, 0xE5E9F0,
            0x4C566A, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x8FBCBB, 0xECEFF4,
        ])

    static let tokyoNight = TerminalTheme(
        id: "tokyo-night", name: "Tokyo Night", background: 0x1A1B26, foreground: 0xC0CAF5,
        cursor: 0xC0CAF5, selection: 0x33467C,
        ansi: [
            0x15161E, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xA9B1D6,
            0x414868, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xC0CAF5,
        ])

    static let solarizedDark = TerminalTheme(
        id: "solarized-dark", name: "Solarized Dark", background: 0x002B36, foreground: 0x839496,
        cursor: 0x93A1A1, selection: 0x073642, ansi: solarizedAnsi)

    static let solarizedLight = TerminalTheme(
        id: "solarized-light", name: "Solarized Light", background: 0xFDF6E3, foreground: 0x657B83,
        cursor: 0x586E75, selection: 0xEEE8D5, ansi: solarizedAnsi)

    static let githubLight = TerminalTheme(
        id: "github-light", name: "GitHub Light", background: 0xFFFFFF, foreground: 0x24292F,
        cursor: 0x0969DA, selection: 0xB6D6FD,
        ansi: [
            0x24292F, 0xCF222E, 0x116329, 0x4D2D00, 0x0969DA, 0x8250DF, 0x1B7C83, 0x6E7781,
            0x57606A, 0xA40E26, 0x1A7F37, 0x633C01, 0x218BFF, 0xA475F9, 0x3192AA, 0x8C959F,
        ])

    private static let solarizedAnsi: [UInt32] = [
        0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
        0x002B36, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3,
    ]

    /// Built-in themes in menu order.
    static let all: [TerminalTheme] = [
        classic, dracula, oneDark, nord, tokyoNight, solarizedDark, solarizedLight, githubLight,
    ]
}
