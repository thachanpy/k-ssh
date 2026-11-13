import Foundation

/// Direction of a port forward.
public enum TunnelKind: String, Sendable, Codable, Hashable {
    /// `ssh -L`: listen locally, connect to target via the server.
    case local
    /// `ssh -R`: listen on the server, connect to target from the Mac.
    case remote
}

/// A saved port-forwarding rule attached to a host.
public struct TunnelConfig: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var hostID: UUID
    public var kind: TunnelKind
    public var bindHost: String
    public var bindPort: Int
    public var targetHost: String
    public var targetPort: Int
    /// Start automatically when the host connects.
    public var autoStart: Bool

    /// Creates a tunnel config; `bindHost` defaults to loopback.
    public init(
        id: UUID = UUID(),
        hostID: UUID,
        kind: TunnelKind,
        bindHost: String = "127.0.0.1",
        bindPort: Int,
        targetHost: String,
        targetPort: Int,
        autoStart: Bool = false
    ) {
        self.id = id
        self.hostID = hostID
        self.kind = kind
        self.bindHost = bindHost
        self.bindPort = bindPort
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.autoStart = autoStart
    }
}
