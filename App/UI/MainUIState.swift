import Observation
import SwiftUI

/// What the sidebar currently lists.
enum SidebarSection: String, CaseIterable, Identifiable, Sendable {
    case hosts
    case recent
    case snippets

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hosts: String(localized: "Hosts")
        case .recent: String(localized: "Recent")
        case .snippets: String(localized: "Snippets")
        }
    }

    /// SF Symbol for the section switcher.
    var symbol: String {
        switch self {
        case .hosts: "server.rack"
        case .recent: "clock"
        case .snippets: "text.badge.plus"
        }
    }
}

/// Pure UI state of the main window (no business logic): which sidebar section is shown and whether
/// the sidebar is collapsed. Real view models (hosts, workspace) stay separate and untouched.
@MainActor
@Observable
final class MainUIState {
    var sidebarSection: SidebarSection = .hosts
    var columnVisibility: NavigationSplitViewVisibility = .all

    init() {}
}
