import Foundation
import Observation
import SSHCore

/// Runtime registry of running port forwards (one `PortForwardActor` per running tunnel).
///
/// A tunnel runs on the SSH connection of one tab; closing the tab or losing the connection stops it.
@MainActor
@Observable
final class TunnelRunner {
    /// A tunnel that is currently running.
    struct Running: Identifiable {
        let config: TunnelConfig
        let tabID: UUID
        var stats: PortForwardStats
        var boundPort: Int?
        var id: UUID { config.id }
    }

    private(set) var running: [UUID: Running] = [:]
    /// Last start error per tunnel (cleared on the next start).
    private(set) var errors: [UUID: String] = [:]

    private var actors: [UUID: PortForwardActor] = [:]
    private let tasks = TaskBag()

    func isRunning(_ id: UUID) -> Bool { running[id] != nil }

    /// Starts `config` on the tab's connection. Failures are recorded in `errors`.
    func start(_ config: TunnelConfig, in tab: SessionTab) async {
        errors[config.id] = nil
        guard running[config.id] == nil else { return }
        guard let session = tab.terminal.activeSession else {
            errors[config.id] = PortForwardError.notConnected.errorDescription
            return
        }
        let forward = PortForwardActor(session: session, config: config)
        do {
            try await forward.start()
        } catch {
            errors[config.id] = error.localizedDescription
            return
        }
        actors[config.id] = forward
        running[config.id] = Running(
            config: config, tabID: tab.id, stats: .zero, boundPort: await forward.boundPort)
        observe(forward, id: config.id)
    }

    /// Stops one tunnel.
    func stop(_ id: UUID) async {
        guard let forward = actors[id] else { return }
        actors[id] = nil
        running[id] = nil
        await forward.stop()
    }

    /// Stops every tunnel that runs on `tabID` (tab closed or disconnected).
    func stopAll(tabID: UUID) async {
        for item in running.values where item.tabID == tabID { await stop(item.id) }
    }

    /// Starts every tunnel of the host that is flagged `autoStart` (called after a successful connect).
    func autoStart(_ configs: [TunnelConfig], in tab: SessionTab) async {
        for config in configs where config.autoStart { await start(config, in: tab) }
    }

    // MARK: - Private

    private func observe(_ forward: PortForwardActor, id: UUID) {
        let stream = forward.stats
        tasks.add(
            Task { [weak self] in
                for await stats in stream {
                    guard let self else { return }
                    self.running[id]?.stats = stats
                    if !(await forward.isRunning) {
                        // The forward ended by itself (connection lost / server cancelled it).
                        self.running[id] = nil
                        self.actors[id] = nil
                        return
                    }
                }
            })
    }
}
