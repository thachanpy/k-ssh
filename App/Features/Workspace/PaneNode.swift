import Foundation

/// Direction of a split: `.horizontal` puts panes side by side, `.vertical` stacks them.
enum SplitAxis: Equatable {
    case horizontal, vertical
}

/// Layout tree of the panes inside one tab. Leaves are pane IDs; each split holds two subtrees.
indirect enum PaneNode: Equatable {
    case terminal(UUID)
    case split(SplitAxis, PaneNode, PaneNode)

    /// Pane IDs in layout order (left→right / top→bottom).
    var leafIDs: [UUID] {
        switch self {
        case .terminal(let id): [id]
        case .split(_, let first, let second): first.leafIDs + second.leafIDs
        }
    }

    /// Replaces the leaf `id` with `node` (no-op if absent).
    func replacing(_ id: UUID, with node: PaneNode) -> PaneNode {
        switch self {
        case .terminal(let leaf):
            return leaf == id ? node : self
        case .split(let axis, let first, let second):
            return .split(axis, first.replacing(id, with: node), second.replacing(id, with: node))
        }
    }

    /// The tree without leaf `id`; its sibling takes its place. `nil` when nothing is left.
    func removing(_ id: UUID) -> PaneNode? {
        switch self {
        case .terminal(let leaf):
            return leaf == id ? nil : self
        case .split(let axis, let first, let second):
            let newFirst = first.removing(id)
            let newSecond = second.removing(id)
            switch (newFirst, newSecond) {
            case (nil, nil): return nil
            case (nil, let only?): return only
            case (let only?, nil): return only
            case (let a?, let b?): return .split(axis, a, b)
            }
        }
    }
}
