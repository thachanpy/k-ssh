import NIOCore
import NIOSSH
import os

/// Pipes two channels into each other, both directions, with backpressure and half-close support.
///
/// Both channels MUST be on the same event loop (the forwarding code guarantees this by using the SSH
/// connection's loop as the only loop), which is why the handler needs no locking. Create a pair with
/// `matchedPair()` and add one handler to each channel's pipeline.
final class GlueHandler {
    private var partner: GlueHandler?
    private var context: ChannelHandlerContext?
    private var pendingRead = false

    private init() {}

    /// Two handlers that forward to each other.
    static func matchedPair() -> (GlueHandler, GlueHandler) {
        let first = GlueHandler()
        let second = GlueHandler()
        first.partner = second
        second.partner = first
        return (first, second)
    }

    private func partnerWrite(_ data: NIOAny) {
        context?.write(data, promise: nil)
    }

    private func partnerFlush() {
        context?.flush()
    }

    private func partnerWriteEOF() {
        context?.close(mode: .output, promise: nil)
    }

    private func partnerCloseFull() {
        context?.close(promise: nil)
    }

    private func partnerBecameWritable() {
        if pendingRead {
            pendingRead = false
            context?.read()
        }
    }

    private var partnerWritable: Bool {
        context?.channel.isWritable ?? false
    }
}

extension GlueHandler: ChannelDuplexHandler {
    typealias InboundIn = NIOAny
    typealias OutboundIn = NIOAny
    typealias OutboundOut = NIOAny

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        partner = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        partner?.partnerWrite(data)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        partner?.partnerFlush()
        context.fireChannelReadComplete()
    }

    func channelInactive(context: ChannelHandlerContext) {
        partner?.partnerCloseFull()
        context.fireChannelInactive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, case .inputClosed = event {
            // Remote side finished sending: propagate as half-close.
            partner?.partnerWriteEOF()
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        partner?.partnerCloseFull()
        context.close(promise: nil)
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable {
            partner?.partnerBecameWritable()
        }
        context.fireChannelWritabilityChanged()
    }

    func read(context: ChannelHandlerContext) {
        if let partner, partner.partnerWritable {
            context.read()
        } else {
            pendingRead = true
        }
    }
}

/// Converts between NIOSSH's `SSHChannelData` and plain `ByteBuffer`s on a session/forwarding channel.
final class SSHDataCodec: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    func handlerAdded(context: ChannelHandlerContext) {
        // Needed so a remote EOF does not tear the channel down before pending data is flushed.
        // Synchronous option API: we are on the channel's event loop, and a context must not be
        // captured by a `@Sendable` future callback.
        do {
            try context.channel.syncOptions?.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
        } catch {
            context.fireErrorCaught(error)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer(let bytes) = channelData.data, case .channel = channelData.type else {
            return  // stderr / file-descriptor data does not exist on forwarding channels
        }
        context.fireChannelRead(wrapInboundOut(bytes))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let bytes = unwrapOutboundIn(data)
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(bytes))), promise: promise)
    }
}

/// Thread-safe counters and bookkeeping shared by all connections of one tunnel.
final class ForwardSession: Sendable {
    private struct State {
        var active = 0
        var total = 0
        var bytesIn: UInt64 = 0
        var bytesOut: UInt64 = 0
        var channels: [ObjectIdentifier: Channel] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Registers a local-side channel; it is closed by `closeAll()` and counted until it closes.
    func track(_ channel: Channel) {
        state.withLock {
            $0.active += 1
            $0.total += 1
            $0.channels[ObjectIdentifier(channel)] = channel
        }
        channel.closeFuture.whenComplete { [self] _ in
            state.withLock {
                if $0.channels.removeValue(forKey: ObjectIdentifier(channel)) != nil { $0.active -= 1 }
            }
        }
    }

    func addIn(_ count: Int) { state.withLock { $0.bytesIn += UInt64(count) } }
    func addOut(_ count: Int) { state.withLock { $0.bytesOut += UInt64(count) } }

    func snapshot() -> PortForwardStats {
        state.withLock {
            PortForwardStats(
                activeConnections: $0.active, totalConnections: $0.total, bytesIn: $0.bytesIn,
                bytesOut: $0.bytesOut)
        }
    }

    /// Closes every tracked connection.
    func closeAll() {
        let channels = state.withLock { Array($0.channels.values) }
        for channel in channels { channel.close(promise: nil) }
    }
}

/// Counts bytes passing through the local-side channel: reads are traffic towards the server
/// (`bytesOut`), writes are traffic from the server (`bytesIn`).
final class ByteCountingHandler: ChannelDuplexHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let session: ForwardSession

    init(session: ForwardSession) {
        self.session = session
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        session.addOut(unwrapInboundIn(data).readableBytes)
        context.fireChannelRead(data)
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        session.addIn(unwrapOutboundIn(data).readableBytes)
        context.write(data, promise: promise)
    }
}

/// Live statistics of a tunnel.
public struct PortForwardStats: Sendable, Equatable {
    public var activeConnections: Int
    public var totalConnections: Int
    /// Bytes received from the server side (towards the local application).
    public var bytesIn: UInt64
    /// Bytes sent to the server side.
    public var bytesOut: UInt64

    public static let zero = PortForwardStats(activeConnections: 0, totalConnections: 0, bytesIn: 0, bytesOut: 0)
}
