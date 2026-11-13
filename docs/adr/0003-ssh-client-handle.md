# ADR 0003 — `SSHClientHandle`: one justified `@unchecked Sendable`

- **Status:** Accepted
- **Date:** 2026-11-13
- **Task:** T06 (found at first compile)
- **Supersedes:** the "fallback" note in ADR 0002 ("create the client through an actor-isolated helper")

## Context

CLAUDE.md §3 forbids `@unchecked Sendable` without a justification comment and an ADR.

Citadel's `SSHClient` is a non-`Sendable` class from a Swift 5-mode package. Its async API (`close()`,
`connect(to:)`, and later exec/PTY/SFTP/forwarding helpers) is `nonisolated`. Storing the client in
`SSHSessionActor` and calling those methods fails under Swift 6 region isolation:

```
error: sending 'existing' risks causing data races [#RegionIsolation::SendingRisksDataRace]
note: sending 'self'-isolated 'existing' to @concurrent instance method 'close()' …
```

An actor-isolated helper does not help: the value is still actor-isolated at the call.
`@preconcurrency import Citadel` (also gated by §3) does not address region-isolation errors and would hide
unrelated diagnostics module-wide, so it was rejected.

## Decision

Introduce `SSHClientHandle` (`SSH/SSHClientHandle.swift`), an `@unchecked Sendable` struct that wraps the
client. Rules:

1. The client is created inside `SSHClientHandle.connect(settings:)` (a `nonisolated` static function) and
   never returned bare.
2. Every operation on the client is a method of the handle; none of them hand the client out. Because the
   handle's methods are `nonisolated`, the client is only used from that nonisolated context.
3. `SSHSessionActor` stores and passes only the (Sendable) handle.
4. Later tasks (T07 PTY, T15 SFTP, T17 forwarding) add methods to the handle; they must not add accessors
   that return the `SSHClient`.

## Why it is safe in practice

- `SSHClient` is backed by a NIO `Channel`; operations are futures serialized on the connection's event loop.
- Its mutable Swift state (`session`, `userInitiatedClose`, `onDisconnect`) is only mutated by `close()`,
  `onDisconnect(perform:)` (called once, right after connect) and Citadel's reconnect path, which we never
  enable (`SSHReconnectMode` unused).
- The actor serializes who holds/drops the handle; `close()` is idempotent at the channel level.

## Update (T07)

The handle now also stores the connection's TCP `Channel` (a genuinely `Sendable` NIO type) so session
channels can be opened with NIOSSH directly — see ADR 0004. The `SSHClient` itself is still private to
the handle.

## Consequences

- One reviewed `@unchecked Sendable` in the codebase, localized to a single small file.
- If Citadel later adds `Sendable` conformance, delete the `@unchecked` and keep the type.
- Reviewers must reject any change that makes the wrapped client escape the handle.
