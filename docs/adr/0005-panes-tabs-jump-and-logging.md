# ADR 0005 — Tabs, panes, jump hosts, logging (T16–T23 design choices)

- **Status:** Accepted (unverified: not compiled by the author)
- **Date:** 2026-11-13

## Decisions

1. **Tabs are in-window** (own tab bar + `SessionTab`), not `NSWindow` tabs; one tab = one SSH session.
2. **SFTP shares the tab's connection** (Terminal/Files toggle); `openSFTP()` opens a channel on the existing session.
3. **Split panes** use a binary `PaneNode` tree. The primary pane owns the session; other panes are
   extra shell channels (`ExtraPaneViewModel`). Ending the primary shell with several panes just removes that pane.
4. **Jump hosts** are chained hop by hop with `SSHClientHandle.connect(through:)` (direct-tcpip channel
   to the next hop). Every hop has its own host-key verification and credentials. The final handle keeps
   `upstream` handles and closes them. Chains are resolved by `JumpChain` (cycle/missing/depth ≤ 8).
5. **Connect uses `SSHClient.connect(to:)`** and reads the NIO channel by `Mirror` (ADR 0003 update):
   Citadel's `connect(on:settings:)` needs the event loop and trips a NIO precondition; `withTaskExecutorPreference` needs macOS 15.
6. **Plain `TerminalView`** (not `LocalProcessTerminalView`), because the latter sends keystrokes to a local pty.
7. **Logging is opt-in per host** (`settings.loggedHostIDs`), written by a single background task
   (`SessionLogger`), ANSI stripped, file mode 0600, size cap + retention purge. Only the primary pane is logged.
8. **Keepalive is TCP-level** (`TCP_KEEPALIVE` option), not SSH `keepalive@openssh.com`.

## Consequences

- `Mirror` access to Citadel internals can break on a Citadel upgrade; the pin is 0.12.1.
- Logs can hold secrets; the UI says so and defaults to off.
