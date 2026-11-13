import Foundation
import NIOCore
import NIOSSH

extension SSHClientHandle {
    /// Opens a session channel, requests a PTY and a shell, and returns the connected `ShellChannel`.
    ///
    /// Uses NIOSSH's public `NIOSSHHandler.createChannel` on the connection's event loop, so it works on
    /// macOS 14 and is not scoped to a closure (ADR 0004).
    /// - Throws: `SSHError.shellOpenFailed` if the server refuses the channel, PTY, or shell request.
    func openShell(cols: Int, rows: Int, term: String) async throws -> ShellChannel {
        let parts = ShellParts.make()
        let handler = parts.handler
        let connection = tcpChannel
        let eventLoop = connection.eventLoop

        let sessionChannel: Channel
        do {
            sessionChannel = try await eventLoop.flatSubmit {
                let promise = eventLoop.makePromise(of: Channel.self)
                do {
                    let sshHandler = try connection.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                    sshHandler.createChannel(promise) { channel, _ in
                        channel.pipeline.addHandler(handler)
                    }
                } catch {
                    promise.fail(error)
                }
                return promise.futureResult
            }.get()
        } catch {
            throw SSHError.shellOpenFailed(error.localizedDescription)
        }

        do {
            try await sessionChannel.triggerUserOutboundEvent(
                SSHChannelRequestEvent.PseudoTerminalRequest(
                    wantReply: true, term: term,
                    terminalCharacterWidth: cols, terminalRowHeight: rows,
                    terminalPixelWidth: 0, terminalPixelHeight: 0,
                    terminalModes: SSHTerminalModes([:]))
            ).get()
            try await sessionChannel.triggerUserOutboundEvent(
                SSHChannelRequestEvent.ShellRequest(wantReply: true)
            ).get()
        } catch {
            try? await sessionChannel.close()
            throw SSHError.shellOpenFailed(error.localizedDescription)
        }
        return ShellChannel(channel: sessionChannel, output: parts.output, exit: parts.exit)
    }
}
