# ADR 0004 — Open shell channels with NIOSSH directly (not Citadel's `withPTY`)

- **Status:** Accepted (pending `swift test` / `SSH_IT=1` verification)
- **Date:** 2026-11-13
- **Task:** T07

## Context

T07 needs a long-lived interactive shell with a PTY: byte output stream, input, resize, close, exit
status, and several independent shells on one connection (T20). Citadel 0.12.1's PTY API
(`SSHClient.withPTY` / `withTTY`) has problems for this app:

1. Both are `@available(macOS 15.0, *)`; the app targets macOS 14.
2. They are closure-scoped (`perform:`), the channel closes when the closure returns, which forces
   awkward Task/continuation bridging for a view-model-owned shell.
3. The underlying channel and `SSHClientSession` are `internal`, so we cannot reach them otherwise.

## Decision

- `SSHClientHandle.connect` now opens the TCP connection itself (`ClientBootstrap`, same options as
  Citadel: connect timeout, `SO_REUSEADDR`, `TCP_NODELAY`) and calls the public
  `SSHClient.connect(on: channel, settings:)`. The handle keeps the (Sendable) TCP `Channel`.
- Session channels are opened with NIOSSH's public API: on the connection's event loop,
  `NIOSSHHandler.createChannel`, then `PseudoTerminalRequest` + `ShellRequest` (both `wantReply: true`,
  awaited so refusals surface as `SSHError.shellOpenFailed`).
- `ShellChannel` (Sendable) exposes `output` (`AsyncSequence` of `[UInt8]`), `send`, `resize`
  (`WindowChangeRequest`), `close`, `waitForExit`/`exitStatus` (`ShellExit.status | .signal`).
- Same mechanism will serve `direct-tcpip` (T17) and gives access to
  `NIOSSHHandler.sendTCPForwardingRequest` for T18.

## Backpressure policy (T07 requirement: "document choice")

Output must never be dropped (that would corrupt terminal escape sequences), and unbounded buffering
could exhaust memory on `cat bigfile`. So: the `AsyncStream` is unbounded, but `ShellFlowControl` bounds
it by pausing network reads. When unread bytes reach 1 MiB the child channel's `autoRead` is turned
off, so NIOSSH stops replenishing the SSH window and the server slows down; when the consumer drains to
256 KiB, `autoRead` is re-enabled and a `read()` issued. Verified offline with `EmbeddedChannel`.

## Consequences

- Our connect path differs slightly from `SSHClient.connect(to:)`; if Citadel changes its bootstrap
  options, update `SSHClientHandle.connect`.
- `send`/`resize` do not throw (spec: `async`); failures are logged because a failing channel is already
  closing and ends `output`.
- No channel-open timeout of our own (Citadel adds a 15 s one internally); the connection-level login
  timeout and keepalive (T12) cover dead connections. Revisit if hangs are observed.
- `SSHSessionProviding` is unchanged: `ShellChannel` is a concrete class. T08 should introduce a small
  protocol for the terminal VM if it needs fakes.
