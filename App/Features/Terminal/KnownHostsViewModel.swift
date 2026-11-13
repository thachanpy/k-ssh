import Foundation
import Observation
import SSHCore

/// Lists trusted host keys and removes entries (e.g. after a legitimate server key change).
@MainActor
@Observable
final class KnownHostsViewModel {
    private(set) var hosts: [KnownHost] = []
    var errorMessage: String?

    private let env: AppEnvironment

    init(env: AppEnvironment) {
        self.env = env
    }

    /// Reloads the list, sorted by host pattern.
    func load() async {
        do {
            hosts = try await env.knownHosts.all().sorted { $0.hostPattern < $1.hostPattern }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Removes the trusted key for `host`; the next connection will ask again.
    func remove(_ host: KnownHost) async {
        do {
            try await env.knownHosts.remove(host.hostPattern)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
