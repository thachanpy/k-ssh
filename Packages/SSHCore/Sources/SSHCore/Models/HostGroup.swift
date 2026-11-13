import Foundation

/// A folder that organizes hosts in the sidebar.
public struct HostGroup: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var name: String

    /// Creates a group.
    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}

/// Everything stored in `groups.json`: the groups (in display order) and which host is in which group.
///
/// Assignments are kept here, not on `HostProfile`, so hosts imported from `~/.ssh/config` (never
/// written to `hosts.json`) can be organized too. Keys are host IDs as strings; ssh-config host IDs are
/// stable (derived from the alias), so assignments survive a reload.
public struct GroupsState: Sendable, Codable, Hashable {
    public var groups: [HostGroup]
    /// `hostID.uuidString` → group ID. A host without an entry is ungrouped.
    public var assignments: [String: UUID]

    /// Creates a state.
    public init(groups: [HostGroup] = [], assignments: [String: UUID] = [:]) {
        self.groups = groups
        self.assignments = assignments
    }

    /// The group a host belongs to, if any (and the group still exists).
    public func groupID(of hostID: UUID) -> UUID? {
        guard let id = assignments[hostID.uuidString], groups.contains(where: { $0.id == id }) else {
            return nil
        }
        return id
    }
}
