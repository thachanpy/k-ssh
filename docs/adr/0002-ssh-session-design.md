# ADR 0002 — SSH session design (T06)

- **Status:** Accepted (pending verification by `swift test` and `SSH_IT=1` run)
- **Date:** 2026-11-13
- **Task:** T06

## Decisions

1. **One actor per connection.** `SSHSessionActor` owns the Citadel `SSHClient` (non-`Sendable`) and never lets it escape. It is single-use: `disconnect()` finishes the `state` stream and later `connect` throws `.sessionClosed`. Reconnect (T12) creates a new session.
2. **Credentials in a locked box, wiped after connect.** Citadel calls `SSHClientSettings.authenticationMethod` more than once, and `SSHAuthenticationMethod` is not `Sendable`. `CredentialBox` (`Sendable`, `OSAllocatedUnfairLock<SSHCredential?>`) rebuilds the method from the credential on each call and is cleared (`defer`) when `connect` finishes. No `@unchecked Sendable` was needed. Limitation: Swift `String` secrets cannot be zeroized.
3. **Own OpenSSH header parsing.** Citadel's `OpenSSH.KeyError` is internal, so "needs passphrase" is determined by reading the cipher name from the key header (`PrivateKeyLoader.inspect`). A wrong passphrase makes Citadel's parse fail; for encrypted keys any parse failure maps to `.invalidPassphrase`.
4. **Unsupported key formats fail clearly.** Citadel 0.12.1 has OpenSSH-format initializers only for Ed25519 and RSA. ECDSA and legacy PEM keys → `SSHError.unsupportedKeyType` (PEM message tells the user to convert with `ssh-keygen -p -m OpenSSH`).
5. **Save secrets only after success.** `CredentialResolver` returns a `pendingSave`; the session writes it to the Keychain after authentication, so mistyped passwords are never stored. A *saved* password that later fails is not auto-deleted (T12 should offer "forget saved password").
6. **Host-key errors survive NIO wrapping.** `HostKeyValidationDelegate` reports `HostKeyError` to an `onFailure` hook stored in a lock-protected recorder; `connect` prefers it over whatever error NIO surfaces.
7. **No Citadel reconnect, no keepalive in T06.** Citadel has no keepalive API (deferred to T12).
8. **Weak self in the approval closure** because Citadel's client retains the validator, which would otherwise create an actor ↔ client cycle.

## Consequences

- `state` uses `bufferingNewest(1)`: slow consumers may miss intermediate states (documented).
- **Update (first compile):** holding `SSHClient` directly in the actor does not compile under Swift 6 (region isolation). Resolved by `SSHClientHandle` — see ADR 0003. The "client never leaves the actor" wording in decision 1 is superseded by it.
- Each connect parses the key up to three times (validate + Citadel's two factory calls); bcrypt cost makes this noticeable only for high `-a` values.
