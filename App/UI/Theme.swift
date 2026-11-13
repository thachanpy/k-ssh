import SwiftUI

/// Shared layout constants so spacing and sizes stay consistent (no magic numbers in views).
enum Theme {
    /// Spacing scale used for stacks and padding.
    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
    }

    /// Corner radii.
    enum Radius {
        static let small: CGFloat = 6
        static let medium: CGFloat = 10
    }

    /// Window and column sizes.
    enum Layout {
        static let windowMinWidth: CGFloat = 960
        static let windowMinHeight: CGFloat = 600
        static let sidebarMin: CGFloat = 220
        static let sidebarIdeal: CGFloat = 260
        static let sidebarMax: CGFloat = 320
        static let hostIcon: CGFloat = 28
        static let statusDot: CGFloat = 8
        static let tabBarHeight: CGFloat = 34
        static let tabMaxWidth: CGFloat = 180
        static let iconButton: CGFloat = 26
        static let terminalMinWidth: CGFloat = 320
        static let sftpMinWidth: CGFloat = 340
        static let sftpIdealWidth: CGFloat = 480
    }
}
