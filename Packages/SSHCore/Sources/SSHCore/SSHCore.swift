/// Namespace and version marker for the `SSHCore` package.
///
/// `SSHCore` holds all non-UI logic (models, persistence, security, SSH, SFTP, tunnels).
/// It must never import SwiftUI or AppKit.
public enum SSHCore {
    /// Semantic version of the core package. Concurrency: immutable constant, safe from any context.
    public static let version = "0.1.0"
}
