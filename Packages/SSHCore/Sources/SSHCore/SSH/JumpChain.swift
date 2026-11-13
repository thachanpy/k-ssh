import Foundation

/// Why a jump-host chain cannot be built.
public enum JumpChainError: LocalizedError, Sendable, Equatable {
    /// `jumpHostID` points to a host that no longer exists.
    case missingHost(UUID)
    /// The chain loops back to a host already in it.
    case cycle(hostName: String)
    /// More hops than `JumpChain.maxHops`.
    case tooDeep

    public var errorDescription: String? {
        switch self {
        case .missingHost: String(localized: "A jump host used by this host no longer exists.")
        case .cycle(let name): String(localized: "The jump host chain loops back to “\(name)”.")
        case .tooDeep: String(localized: "The jump host chain is too long.")
        }
    }
}

/// Resolves `HostProfile.jumpHostID` links into an ordered list of hops.
public enum JumpChain {
    /// Maximum number of jump hosts in front of the target.
    public static let maxHops = 8

    /// The jump hosts to connect through before reaching `target`, outermost first
    /// (for `ProxyJump a,b` and target `t`: `[a, b]`). Empty when the host has no jump host.
    /// - Throws: `JumpChainError` for dangling links, cycles, or chains that are too long.
    public static func resolve(for target: HostProfile, hosts: [HostProfile]) throws -> [HostProfile] {
        var chain: [HostProfile] = []
        var visited: Set<UUID> = [target.id]
        var next = target.jumpHostID
        while let id = next {
            guard let hop = hosts.first(where: { $0.id == id }) else { throw JumpChainError.missingHost(id) }
            guard visited.insert(hop.id).inserted else { throw JumpChainError.cycle(hostName: hop.name) }
            chain.append(hop)
            guard chain.count <= maxHops else { throw JumpChainError.tooDeep }
            next = hop.jumpHostID
        }
        return chain.reversed()
    }
}
