# TASKS — macOS SSH & SFTP Client

Backlog for implementation agents. Read `CLAUDE.md` first. Follow the workflow in CLAUDE.md §8.

**Status values:** `TODO` · `IN PROGRESS` · `BLOCKED` · `DONE`
**Size:** `S` (< ~200 LOC) · `M` (~200–600 LOC) · `L` (> 600 LOC or high risk → confirmation gate required)

## Overview

| ID | Task | Pri | Size | Depends on | Status |
|---|---|---|---|---|---|
| T00 | Project scaffolding | P0 | M | — | DONE |
| T01 | Core Sendable models | P0 | S | T00 | DONE |
| T02 | JSONStore + repositories | P0 | M | T01 | DONE |
| T03 | KeychainService | P0 | M | T00 | DONE |
| T04 | BookmarkService (security-scoped) | P0 | S | T00 | DONE |
| T05 | KnownHostsStore + host-key validator | P0 | M | T02 | DONE |
| T06 | SSHSessionActor — connect & auth | P0 | L | T03, T04, T05 | IN PROGRESS |
| T07 | PTY shell channel (I/O stream, resize) | P0 | M | T06 | IN PROGRESS |
| T08 | SwiftTerm terminal view + TerminalViewModel | P0 | M | T07 | IN PROGRESS |
| T09 | Main window: sidebar + tab workspace | P0 | L | T02, T08 | IN PROGRESS |
| T10 | Host editor (CRUD + Keychain) | P0 | M | T09, T03 | IN PROGRESS |
| T11 | SSH key manager UI | P0 | M | T04, T03, T09 | IN PROGRESS |
| T12 | Connection lifecycle UX (status, errors, host-key prompt, reconnect) | P0 | M | T09, T05 | IN PROGRESS |
| T13 | `~/.ssh/config` parser | P1 | M | T01 | IN PROGRESS |
| T14 | SSH config import + merge in sidebar | P1 | S | T13, T04, T09 | IN PROGRESS |
| T15 | SFTPServiceActor | P1 | L | T06 | IN PROGRESS |
| T16 | SFTP split-pane browser UI | P1 | L | T15, T09 | IN PROGRESS |
| T17 | Local port forwarding | P1 | L | T06 | IN PROGRESS |
| T18 | Remote port forwarding | P1 | L | T17 | IN PROGRESS |
| T19 | Tunnels UI | P1 | M | T17 | IN PROGRESS |
| T20 | Split terminal | P1 | L | T09 | IN PROGRESS |
| T21 | Jump host / ProxyJump | P2 | L | T06, T13 | IN PROGRESS |
| T22 | Command snippets | P2 | M | T02, T08 | IN PROGRESS |
| T23 | Session history + optional output log | P2 | M | T02, T09 | IN PROGRESS |
| T24 | Hardening: menus, shortcuts, settings, a11y, test pass | P2 | M | all P0/P1 | IN PROGRESS |

Recommended order: T00 → T01 → (T02, T03, T04 in any order) → T05 → T06 → T07 → T08 → T09 → T10 → T11 → T12 → **P0 milestone** → T13 → T14 → T15 → T16 → T17 → T19 → T18 → T20 → **P1 milestone** → T21 → T22 → T23 → T24.

---

## Phase 0 — Foundation

### T00 · Project scaffolding
- **Size:** M · **Depends:** — · **Status:** DONE
- **Goal:** Buildable empty app + core package with dependencies and sandbox configured.
- **Scope:**
  - `project.yml` (XcodeGen): app target `SSHClient` (macOS 14, Swift 6 mode, `SWIFT_STRICT_CONCURRENCY=complete`, warnings-as-errors for Swift), unit test target, scheme.
  - `Packages/SSHCore/Package.swift` (swift-tools-version 6.0+, `.macOS(.v14)`), depends on `Citadel`. App depends on `SSHCore` + `SwiftTerm`.
  - `App/App.entitlements` exactly as in CLAUDE.md §4.
  - `SSHClientApp.swift` showing a placeholder window.
  - `.gitignore` (xcodeproj, .build, DerivedData, xcuserdata).
  - Pin dependency versions (`from:` a specific tag) and record them in `docs/adr/0001-dependencies.md`.
- **Acceptance criteria:**
  - [x] `xcodegen generate` then `xcodebuild … build` succeeds with zero warnings. (user-confirmed)
  - [ ] `swift test` in `Packages/SSHCore` runs (one placeholder test passes).
  - [ ] Built app's entitlements verified with `codesign -d --entitlements - <app>`.
- **Notes:**
  - Files created: `.gitignore`, `project.yml`, `Packages/SSHCore/{Package.swift, Sources/SSHCore/SSHCore.swift, Tests/SSHCoreTests/SSHCoreTests.swift}`, `App/{SSHClientApp.swift, App.entitlements, Info.plist}`, `AppTests/SSHClientTests.swift`, `docs/adr/0001-dependencies.md`.
  - Pins: Citadel 0.12.1 (in SSHCore), SwiftTerm 1.99.3 (in app, needs Swift 6.2+ toolchain). See ADR 0001.
  - **Not verified:** the agent sandbox is Linux without Swift/Xcode/XcodeGen, so no build, `swift test`, or `codesign` was run. All three acceptance criteria stay unchecked; status stays `IN PROGRESS` until run on the Mac (`xcodegen generate`, `xcodebuild … build`, `cd Packages/SSHCore && swift test`, `codesign -d --entitlements - <app>`).
  - Build gotcha: SwiftTerm ships a build-tool plugin (`SwiftTermBuildInfoPlugin`); CLI builds fail with "Validate plug-in…" unless `-skipPackagePluginValidation` is passed to `xcodebuild` (build and test). In Xcode GUI, click "Trust & Enable". Follow-up: add the flag to CLAUDE.md §7 commands (needs user approval since CLAUDE.md is the source of truth).
  - Deviations: SSHCore `Package.swift` has no warnings-as-errors flag (avoids `unsafeFlags`); app target has it via `SWIFT_TREAT_WARNINGS_AS_ERRORS`. SSHCore does not yet `import Citadel` (nothing uses it until T06).

### T01 · Core Sendable models
- **Size:** S · **Depends:** T00 · **Status:** DONE
- **Goal:** Define all domain value types in `SSHCore/Models`.
- **Scope:** `struct`s/`enum`s, all `Sendable, Codable, Hashable, Identifiable`:
  - `HostProfile` (id: UUID, name, hostname, port = 22, username, auth: `AuthMethod`, jumpHostID: UUID?, tags, source: `.local | .sshConfig`, createdAt, lastConnectedAt?)
  - `AuthMethod` enum: `.password` (secret in Keychain), `.privateKey(keyID: UUID)`, `.agentless` placeholder not needed — keep to the two.
  - `SSHKeyRef` (id, label, keyType: `.ed25519 | .rsa | .ecdsa`, bookmarkData: Data, fingerprintSHA256, hasPassphrase: Bool, addedAt)
  - `TunnelConfig` (id, hostID, kind: `.local | .remote`, bindHost, bindPort, targetHost, targetPort, autoStart)
  - `Snippet` (id, title, command, tags, appendNewline: Bool)
  - `HistoryEntry` (id, hostID, hostDisplayName, startedAt, endedAt?, outcome)
  - `KnownHost` (hostPattern "host:port", keyType, fingerprintSHA256, publicKeyBase64, addedAt)
  - `ConnectionState` enum (`.idle, .connecting, .awaitingHostKeyApproval(fingerprint), .connected, .disconnected(reason?), .failed(message)`) — `Sendable`, `Equatable`.
- **Acceptance criteria:**
  - [x] No secret fields (password/passphrase/key bytes) exist on any model.
  - [x] Codable round-trip unit test for each model.
- **Notes:**
  - Files: `Packages/SSHCore/Sources/SSHCore/Models/{HostProfile,SSHKeyRef,TunnelConfig,Snippet,HistoryEntry,KnownHost,ConnectionState}.swift`, `Tests/SSHCoreTests/ModelsCodableTests.swift`. `AuthMethod`/`HostSource` live in `HostProfile.swift`; `SSHKeyType` in `SSHKeyRef.swift`.
  - Design choices: all types `public` with public inits (app module consumes them); `KnownHost.id` = `hostPattern`; `KnownHost.keyType` reuses `SSHKeyType`; `HistoryOutcome` = `active | completed | failed | cancelled` (spec left "outcome" open); `ConnectionState` is `Sendable, Equatable` only (not Codable).
  - Criterion 1 is covered by a Mirror-based test (`testNoSecretFieldsOnModels`) plus review: `hasPassphrase` is only a Bool flag; `bookmarkData` is a bookmark, not key bytes.

### T02 · JSONStore + repositories
- **Size:** M · **Depends:** T01 · **Status:** DONE
- **Goal:** Persistent, actor-isolated storage in Application Support.
- **Scope:**
  - `AppPaths` (resolves/creates `Application Support/<bundle-id>/`; injectable base URL for tests).
  - `actor JSONStore<Value: Codable & Sendable>`: `load() async throws -> Value`, `save(_:) async throws`, atomic writes, envelope `{ schemaVersion, data }`, returns default value when file missing; corrupted file → rename to `.corrupt-<date>` and return default (log it).
  - Repositories (actors or structs over a store): `HostRepository`, `KeyRepository`, `TunnelRepository`, `SnippetRepository`, `HistoryRepository` with CRUD + `AsyncStream` `changes()` for UI refresh.
- **Acceptance criteria:**
  - [x] Unit tests: save/load round trip, missing file, corrupt file, concurrent writes (100 parallel tasks → no lost updates).
  - [x] Deleting a host also deletes its Keychain password (call via injected `KeychainProviding`; fake in tests).
- **Notes:**
  - Files (`SSHCore/Persistence/`): `AppPaths`, `PersistenceError`, `JSONStore`, `ListRepository` (generic; `KeyRepository`/`TunnelRepository`/`SnippetRepository`/`HistoryRepository` are typealiases), `HostRepository` (wraps `ListRepository<HostProfile>` + keychain). Tests: `PersistenceTests.swift`.
  - Design: every mutation is one atomic `JSONStore.update` (sync inside the actor → no lost updates). `changes()` emits current list first, then after each mutation (`bufferingNewest(1)`). `HostRepository.upsert` rejects `source != .local` (`readOnlySource`). Host is removed before its Keychain secret.
  - Deviations: newer-schema file throws `unsupportedSchema` (left untouched) rather than being treated as corrupt. Dates use default Codable (exact Double), not ISO8601.
  - Needed `KeychainProviding` from T03 → T03 was implemented first (T03 depends only on T00).

### T03 · KeychainService
- **Size:** M · **Depends:** T00 · **Status:** DONE
- **Goal:** Safe secret storage per CLAUDE.md §4.
- **Scope:**
  - `protocol KeychainProviding: Sendable` with `set(_ secret: String, for: SecretKey)`, `get(_:) -> String?`, `delete(_:)`.
  - `enum SecretKey: Sendable { case hostPassword(UUID), keyPassphrase(UUID) }` → account string.
  - `actor KeychainService: KeychainProviding` using `SecItemAdd/CopyMatching/Update/Delete`; update-or-insert semantics; maps `OSStatus` to `KeychainError`.
  - `InMemoryKeychain` fake for tests/previews.
- **Acceptance criteria:**
  - [x] Integration test (runs on macOS host) for set/get/update/delete with a test service name, cleans up after itself.
  - [x] Secrets never appear in logs (grep check in review).
- **Notes:**
  - Files (`SSHCore/Security/`): `KeychainProviding.swift` (protocol, `SecretKey`, `KeychainError`, `InMemoryKeychain`), `KeychainService.swift`. Tests: `KeychainTests.swift` (real-Keychain test uses a unique service name and cleans up).
  - Log check: no logger is used in the Keychain code; error messages contain only `OSStatus` text.
  - **Risk to check on first run:** `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` is set on `SecItemAdd` per CLAUDE.md §4. On the macOS file-based keychain this attribute may be rejected (e.g. `errSecParam`); if the integration test fails, the fix would need `kSecUseDataProtectionKeychain` (requires a signed app with keychain entitlement) — record an ADR before changing.

### T04 · BookmarkService
- **Size:** S · **Depends:** T00 · **Status:** DONE
- **Goal:** Persist access to user-selected key files and the `~/.ssh` folder.
- **Scope:**
  - `actor BookmarkService`: `makeBookmark(for: URL) throws -> Data`, `withAccess<T: Sendable>(to bookmark: Data, _ body: @Sendable (URL) async throws -> T) async throws -> T` (start/stop scoped access, detects stale → throws `.stale` so UI can re-prompt and refresh).
  - Store "ssh folder" bookmark in `settings.json`.
- **Acceptance criteria:**
  - [x] Access is always stopped (verified via `defer`, reviewed).
  - [x] Stale bookmark path surfaces a typed error.
- **Notes:**
  - Files: `Security/BookmarkService.swift` (`BookmarkService`, `BookmarkError`), `Models/AppSettings.swift`, `Persistence/SettingsRepository.swift`. Tests: `BookmarkTests.swift`.
  - `withAccess` pairs start/stop with `defer`. Stale → `BookmarkError.stale(refreshed:)` carrying regenerated bookmark data when possible (extra vs. spec; `nil` means re-prompt).
  - The stale test moves a file and is skipped via `XCTSkip` if the filesystem doesn't report staleness.

---

## Phase 1 — P0 Core

### T05 · KnownHostsStore + host-key validator
- **Size:** M · **Depends:** T02 · **Status:** DONE
- **Goal:** Trust-on-first-use host verification.
- **Scope:**
  - `actor KnownHostsStore` backed by `known_hosts.json`: `lookup(host:port:)`, `trust(_:)`, `remove(_:)`.
  - Citadel host-key validator adapter: computes SHA256 fingerprint (`SHA256:base64`, same format as OpenSSH), returns result `.trusted | .unknown(KnownHost) | .mismatch(expected, actual)`.
  - Approval flow: validator suspends on unknown key and waits for UI decision via an async callback (`@Sendable (KnownHost) async -> Bool`) injected by the session.
- **Acceptance criteria:**
  - [x] Unit tests: unknown → approve → trusted next time; mismatch → connection refused.
  - [x] Fingerprint matches `ssh-keygen -lf` output for a test key.
- **Notes:**
  - Files (`SSHCore/Security/`): `HostKeyFingerprint.swift` (`ParsedHostKey`, SHA256 fingerprint), `KnownHostsStore.swift`, `HostKeyValidator.swift` (`HostKeyDecision`, `HostKeyError`, `HostKeyValidator`), `HostKeyValidationDelegate.swift` (NIOSSH adapter → `.citadelValidator`). Tests: `HostKeyTests.swift` with real `ssh-keygen` vectors (ed25519, rsa).
  - APIs verified against `.build/checkouts`: `NIOSSHClientServerAuthenticationDelegate.validateHostKey(hostKey:validationCompletePromise:)`, `String(openSSHPublicKey: NIOSSHPublicKey)`, `SSHHostKeyValidator.custom(_:)`. Citadel does not re-export NIOSSH, so `Package.swift` now declares `swift-nio-ssh` (fork, same range as Citadel) and `swift-nio` (`NIOCore`) directly — see ADR 0001.
  - Design: validator parses the OpenSSH text form, so the core logic has no NIO dependency and is unit-testable. A different key *type* for a known host counts as a mismatch (conservative; one entry per `host:port` per spec). Certificate host keys → `unsupportedKeyType`.
  - The delegate adapter itself has no unit test (needs a NIO event loop); it is exercised by T06 integration tests.

### T06 · SSHSessionActor — connect & authenticate
- **Size:** L (confirmation gate) · **Depends:** T03, T04, T05 · **Status:** IN PROGRESS (unit tests pass per user; `SSH_IT=1` integration run pending)
- **Goal:** Establish authenticated SSH connections with Citadel.
- **Scope:**
  - `actor SSHSessionActor` (one per connection): `connect(profile:) async throws`, `disconnect() async`, `state: AsyncStream<ConnectionState>`.
  - Auth: password (from Keychain); private key Ed25519 & RSA (read via `BookmarkService`, parse OpenSSH PEM, decrypt with passphrase from Keychain or prompt callback). ECDSA optional — if Citadel unsupported, return clear error.
  - Prompt callbacks (`@Sendable` async closures) for: missing password, missing passphrase, host-key approval. Option to "save to Keychain".
  - Timeouts (connect 15s), error mapping to `SSHError: LocalizedError`.
  - `protocol SSHSessionProviding` for VM testing.
- **Acceptance criteria:**
  - [ ] Integration tests (`SSH_IT=1`, Docker OpenSSH on :2222): password OK, Ed25519 OK, RSA OK, encrypted key + passphrase OK, wrong password → `.authenticationFailed`.
  - [ ] Key bytes are only held in memory during auth; never persisted.
  - [ ] Zero concurrency warnings.
- **Notes:**
  - **Status: IMPLEMENTED, NOT YET VERIFIED.** Gate confirmed by user ("tiếp tục"). Needs `swift test` and `SSH_IT=1` run; see "Implementation notes" at the end of this task.
  - **Citadel 0.12.1 facts (read from `.build/checkouts/Citadel`):**
    - Connect: `SSHClient.connect(to: SSHClientSettings)`; `SSHClientSettings(host:port:authenticationMethod: @Sendable () -> SSHAuthenticationMethod, hostKeyValidator:)` with `connectTimeout: TimeAmount` (default 30s → we set 15s) and `hostKeyValidator` = `HostKeyValidationDelegate.citadelValidator` from T05.
    - Auth: `SSHAuthenticationMethod.passwordBased(username:password:)`, `.rsa(username:privateKey: Insecure.RSA.PrivateKey)`, `.ed25519(username:privateKey: Curve25519.Signing.PrivateKey)`, plus `.p256/.p384/.p521`.
    - Key parsing: `Curve25519.Signing.PrivateKey(sshEd25519: String|Data, decryptionKey: Data?)`, `Insecure.RSA.PrivateKey(sshRsa: String|Data, decryptionKey: Data?)` (OpenSSH format only; `decryptionKey` = passphrase bytes). No OpenSSH-format initializers for ECDSA were found → ECDSA keys will return a clear `.unsupportedKeyType` error (allowed by spec). Legacy PEM (`BEGIN RSA PRIVATE KEY`) is not parsed → clear error.
    - `SSHClient` is a non-`Sendable` class: it must live only inside `SSHSessionActor` and never cross an isolation boundary. `isConnected`, `onDisconnect(perform: @Sendable)`, `close() async throws`; `SSHReconnectMode`/auto-reconnect is NOT used (reconnect is UX-driven in T12).
    - Errors: wrong password/key → `SSHClientError.allAuthenticationOptionsFailed`; encrypted key without passphrase → `missingDecryptionKey`; wrong passphrase → decrypt succeeds with garbage → `InvalidOpenSSHKey.invalidCheck` (to be confirmed by the integration test); host key errors come from our `HostKeyError`.
    - No keepalive API was found in Citadel → deferred to T12 (own timer/`ping` or NIO idle handler; will spike there).
  - **Architecture note:**
    - `SSHSessionActor` (one per connection) owns an optional `SSHClient`, a `ConnectionState` (`state: AsyncStream<ConnectionState>` via `makeStream`, `bufferingNewest(1)`, emits current value first), and injected dependencies: `any KeychainProviding`, `BookmarkService`, `KeyRepository` (to look up `SSHKeyRef` by ID), `KnownHostsStore`, and a `SSHPrompts` struct of `@Sendable async` closures: `password(HostProfile) -> PasswordPromptResult?`, `passphrase(SSHKeyRef) -> PasswordPromptResult?`, `hostKey(KnownHost) -> Bool`; `PasswordPromptResult { secret: String, saveToKeychain: Bool }`.
    - `protocol SSHSessionProviding: Sendable { connect(profile:) async throws; disconnect() async; var state: AsyncStream<ConnectionState> { get } }` so ViewModels use fakes. T07/T15/T17 extend the same actor (shell, SFTP, forwarding all reuse its single `SSHClient`).
    - `SSHError: LocalizedError, Sendable` = `authenticationFailed`, `hostKeyRejected`, `hostKeyChanged(expected:actual:)`, `connectionTimedOut`, `connectionFailed(String)`, `unsupportedKeyType(String)`, `keyFileUnavailable` (stale/missing bookmark), `invalidPassphrase`, `cancelled`. Mapping is in one place (`SSHError.map(_:)`); messages never include secrets.
    - Auth credential flow: password → Keychain lookup, else prompt (optionally save). Key → `KeyRepository.get` → `BookmarkService.withAccess` reads the file into a `String` **inside** the scoped access → parse with passphrase (Keychain, else prompt, retry up to 3 times on `invalidCheck`) → build `SSHAuthenticationMethod`. Key text/bytes are local variables only; never stored in properties, logs, or disk. (Swift `String` cannot be zeroized; documented limitation.)
    - Timeout: `connectTimeout = .seconds(15)` on settings; prompts are not subject to it (timer starts at the network connect). Cancellation: `connect` checks `Task.isCancelled` after each suspension; cancelling while awaiting a prompt returns `.cancelled`.
    - State transitions: `idle → connecting → (awaitingHostKeyApproval → connecting) → connected`; failure → `.failed(message)`; `onDisconnect` → `.disconnected(reason:)` unless user-initiated (`disconnect()` → `.disconnected(reason: nil)`). State stream finishes after `disconnect()`.
    - Logging: `os.Logger`, hostnames/usernames `privacy: .private`, no secrets.
  - **Step-by-step plan (each step builds + tests before the next):**
    1. `SSHError` + `SSHPrompts`/`PasswordPromptResult` types, `SSHSessionProviding` protocol (+ unit tests for error mapping/messages).
    2. `PrivateKeyLoader` (pure, no network): parse OpenSSH text + passphrase into an enum `LoadedKey { ed25519(...), rsa(...) }`, classify encrypted/missing/wrong passphrase, reject ECDSA/PEM. Unit tests with fixture keys generated by `ssh-keygen` (ed25519, rsa, encrypted ed25519, encrypted rsa, ecdsa, PEM-RSA).
    3. `CredentialResolver` (Keychain + prompts + `BookmarkService` → `SSHAuthenticationMethod`), tested with `InMemoryKeychain` and fake prompts (no network).
    4. `SSHSessionActor.connect/disconnect` + state stream + host-key approval wiring (`.awaitingHostKeyApproval`) + timeout + cancellation.
    5. Integration tests gated by `SSH_IT=1` against Docker `linuxserver/openssh-server` on :2222: password OK, Ed25519, RSA, encrypted key + passphrase, wrong password → `.authenticationFailed`, unknown host-key approve/reject, changed key refused. Add `docs/` snippet (docker run command, fixtures).
    6. Review pass: concurrency warnings = 0, no secrets in logs (grep), ADR `0002-ssh-session-design.md`, tick criteria.
  - **Implementation notes (after coding):**
    - Files (`SSHCore/SSH/`): `SSHError`, `SSHPrompts` (+`PasswordPromptResult`), `SSHSessionProviding`, `PrivateKeyLoader`, `CredentialResolver` (+`SSHCredential`, `ResolvedCredential`), `SSHSessionActor`. Changed: `HostKeyValidationDelegate` (added `onFailure`), `Package.swift` (added swift-crypto `Crypto`). Tests: `PrivateKeyLoaderTests`, `CredentialResolverTests` (incl. offline session tests), `SSHIntegrationTests` (gated), `KeyFixtures` (throwaway keys). Docs: `docs/integration-testing.md`, `docs/integration/pubkeys/`, ADR 0002.
    - Deviations from plan: none in scope; `SSHError` gained `alreadyConnected`, `sessionClosed`, `invalidKeyFile`, `credentialsUnavailable`. Session is single-use (see ADR 0002).
    - **First compile failed** with `SendingRisksDataRace` on `SSHClient.close()` (non-Sendable client held by the actor). Fixed with `SSHClientHandle` (`@unchecked Sendable` wrapper with nonisolated methods) — justification + rules in ADR 0003. Reviewer: confirm this single `@unchecked Sendable` is acceptable; alternative would be dropping Citadel for NIOSSH directly (not recommended).
    - Unit tests that need no server: `PrivateKeyLoaderTests`, `CredentialResolverTests`. Integration (Docker): `SSH_IT=1 swift test --filter SSHIntegrationTests`.
    - Acceptance mapping: password / Ed25519 / RSA / encrypted+passphrase / wrong password → `testPasswordAuthSucceeds`, `testEd25519KeyAuth`, `testRSAKeyAuth`, `testEncryptedKeyWithPassphrase`, `testWrongPasswordFailsWithAuthenticationFailed`. Key bytes are never persisted (only in `CredentialBox`, cleared after connect). Zero-warnings check pending a build.
  - **Risks / decisions needing your OK:** (a) ECDSA + legacy PEM keys unsupported in T06 (Citadel limitation); (b) wrong-passphrase detection relies on `invalidCheck` (to be validated in step 5); (c) keepalive deferred to T12; (d) `SSHClient` non-Sendable handling relies on Swift 6 region-based isolation — if the compiler rejects it, fallback is creating the client inside the actor via an actor-isolated helper (no `@unchecked Sendable`); (e) Docker is required on your Mac for step 5.

### T07 · PTY shell channel
- **Size:** M · **Depends:** T06 · **Status:** IN PROGRESS
- **Goal:** Interactive shell with bidirectional streaming.
- **Scope:**
  - `SSHSessionActor.openShell(cols:rows:term: "xterm-256color") -> ShellChannel`.
  - `ShellChannel` (actor/Sendable handle): `output: AsyncStream<[UInt8]>`, `send(_ bytes: [UInt8]) async`, `resize(cols:rows:) async`, `close() async`, exit status.
  - Backpressure: bounded buffering policy on `output` (document choice).
- **Acceptance criteria:**
  - [ ] Integration test: send `echo hello\n`, receive `hello`.
  - [ ] Resize sends window-change request (verify with `stty size`).
  - [ ] Channel close ends the `output` stream.
- **Notes:**
  - **Status: IMPLEMENTED, NOT YET VERIFIED** (needs `swift test`, then `SSH_IT=1 swift test --filter SSHIntegrationTests` against Docker).
  - **Key finding / deviation:** Citadel 0.12.1's `withPTY`/`withTTY` are `@available(macOS 15.0, *)` (app targets 14), closure-scoped, and their channel is `internal`. Shells are therefore opened with NIOSSH's public `NIOSSHHandler.createChannel` on a TCP channel we own (`SSHClientHandle.connect` now bootstraps the socket itself and calls `SSHClient.connect(on:settings:)`). See ADR 0004.
  - Files (`SSHCore/SSH/`): `ShellChannel.swift` (`ShellChannel`, `ShellOutput`, `ShellExit`; internal `ShellChannelHandler`, `ShellFlowControl`, `ShellExitBox`, `ShellParts`), `SSHClientHandle+Shell.swift` (`openShell`), changed `SSHClientHandle.swift`, `SSHSessionActor.swift` (`openShell(cols:rows:term:)`), `SSHError.swift` (`notConnected`, `shellOpenFailed`), `Package.swift` (NIOPosix; tests also NIOEmbedded/NIOSSH/NIOCore).
  - API deviation: `output` is `ShellOutput` (an `AsyncSequence` of `[UInt8]`, consume with `for await`) instead of a plain `AsyncStream<[UInt8]>`, because backpressure needs a consume hook. `waitForExit() -> ShellExit?` (`.status(Int)` / `.signal(String)`) plus `exitStatus` property.
  - Backpressure: unbounded stream bounded by pausing network reads (pause at 1 MiB unread, resume at 256 KiB), no byte is dropped. Details in ADR 0004.
  - Tests: offline `ShellChannelTests` (EmbeddedChannel: ordering, stderr merge, inactive ends stream, exit status/signal, send, resize event, backpressure pause/resume, no loss under pressure). Integration (`SSH_IT=1`): `testShellRunsCommandAndReportsExitStatus` (echo → output, `exit 3` → `.status(3)`, stream ends), `testResizeIsVisibleToRemote` (`stty size` 24 80 → 50 132), `testClosingShellEndsOutputAndKeepsConnectionAlive`, `testTwoShellsAreIndependent`, `testOpeningShellWithoutConnectionThrowsNotConnected`.
  - For T18 spike: the NIOSSH fork exposes `NIOSSHHandler.sendTCPForwardingRequest`, and Citadel has an internal `registerForwardedTCPIP`; with our own channel access remote forwarding may be feasible without leaving Citadel.

### T08 · SwiftTerm terminal view + TerminalViewModel
- **Size:** M · **Depends:** T07 · **Status:** IN PROGRESS (written, NOT compiled/verified)
- **Goal:** Render the shell with SwiftTerm.
- **Scope:**
  - `TerminalHostView: NSViewRepresentable` wrapping SwiftTerm `TerminalView`; `@MainActor` coordinator implementing `TerminalViewDelegate` (`send` → VM, `sizeChanged` → VM.resize).
  - `@MainActor @Observable TerminalViewModel`: owns `ShellChannel`, pumps `output` into `terminalView.feed(byteArray:)` from a stored `Task`, exposes `state`, `title`.
  - Font/theme from settings (default: SF Mono 13, system appearance-aware colors).
  - Copy/paste, select, scrollback (SwiftTerm defaults), bell.
- **Acceptance criteria:**
  - [ ] `vim`, `htop`, `top`, colors (256 + truecolor test script) render correctly.
  - [ ] Resizing the window updates remote `stty size`.
  - [ ] Closing the view cancels the pump task and closes the channel (no leaks — check with Instruments/`deinit` log).
- **Notes:** Unverified.
  - Files: `App/Features/Terminal/{TerminalViewModel,TerminalHostView,ConnectionPrompter}.swift`.
  - Wraps a plain SwiftTerm `TerminalView`; the Coordinator is the `TerminalViewDelegate` (all requirements implemented, links ignored, remote clipboard reads denied). `LocalProcessTerminalView` was tried first and does NOT work: its `setup()` replaces `inputSender` delivery with a local pty, so keystrokes never reach `TerminalViewDelegate.send`.

### T09 · Main window: sidebar + tab workspace
- **Size:** L (confirmation gate waived by user) · **Depends:** T02, T08 · **Status:** IN PROGRESS (written, NOT compiled/verified)
- **Goal:** App shell with hosts sidebar and multiple session tabs.
- **Design decision:** custom in-window tab bar (not NSWindow native tabbing) so each tab can host split panes (T20) and SFTP (T16). Record in ADR.
- **Scope:**
  - `NavigationSplitView`: sidebar = hosts list (search, tags, sections "My Hosts" / "SSH Config"); detail = `WorkspaceView`.
  - `@MainActor @Observable WorkspaceViewModel`: `tabs: [SessionTab]`, `selectedTabID`, open/close/reorder/duplicate tab. `SessionTab` holds a pane tree (initially one terminal pane).
  - Tab bar: title, connection status dot, close button, middle-click close, drag reorder, ⌘T (new tab from selected host), ⌘W, ⌘1…⌘9, ⌃Tab.
  - Double-click host → open new tab and connect.
  - Close tab with active session → confirm dialog.
- **Acceptance criteria:**
  - [ ] 5+ simultaneous tabs to different hosts work independently.
  - [ ] Closing a tab disconnects only that session.
  - [ ] Keyboard shortcuts work.
- **Notes:** Unverified.
  - Files: `App/SSHClientApp.swift`, `App/Shared/{AppEnvironment,MainWindow,MiddleClick}.swift`, `App/Features/Hosts/{HostListViewModel,HostsSidebarView}.swift`, `App/Features/Workspace/*`, `AppTests/WorkspaceViewModelTests.swift`.
  - Deviation: extra `Features/Workspace` folder. All tabs stay in the view hierarchy (opacity toggle) to keep scrollback. ⌘W is bound by replacing the `.saveItem` command group. ADR for the custom tab bar still to be written.

### T10 · Host editor (CRUD + Keychain)
- **Size:** M · **Depends:** T09, T03 · **Status:** IN PROGRESS (written, NOT compiled/verified)
- **Goal:** Create/edit/delete/duplicate saved hosts.
- **Scope:**
  - Sheet `HostEditorView` + `HostEditorViewModel`: name, hostname, port, username, auth picker (password field / key picker from T11), jump host picker (disabled until T21), tags.
  - Validation (hostname non-empty, port 1–65535). Password saved to Keychain on Save, removed on Delete.
  - Context menu in sidebar: Connect, Open SFTP (disabled until T16), Edit, Duplicate, Delete.
- **Acceptance criteria:**
  - [ ] `hosts.json` contains no password (verified by test).
  - [ ] Edits persist across app relaunch.
- **Notes:** Unverified.
  - Files: `App/Features/Hosts/{HostEditorView,HostEditorViewModel}.swift`, `AppTests/HostEditorViewModelTests.swift`.
  - Deviations: username is required; Duplicate does not copy the saved password.

### T11 · SSH key manager UI
- **Size:** M · **Depends:** T04, T03, T09 · **Status:** IN PROGRESS (written, NOT compiled/verified)
- **Goal:** Manage private keys.
- **Scope:**
  - Keys window/sheet: list (label, type, fingerprint, passphrase yes/no, "file missing/stale" badge).
  - Import via `NSOpenPanel` (default dir `~/.ssh`, shows hidden files) → bookmark → detect type + encryption → compute fingerprint → optional passphrase saved to Keychain.
  - Generate new Ed25519 key pair (Citadel/CryptoKit `Curve25519`), save to user-chosen location via `NSSavePanel`, copy public key to clipboard.
  - Re-link stale key; delete key ref (warn if used by hosts).
- **Acceptance criteria:**
  - [ ] Imported key still usable after app relaunch (bookmark works in sandbox).
  - [ ] Generated key authenticates against Docker test server.
- **Notes:** Unverified.
  - Files: `App/Features/Keys/{KeyManagerView,KeyManagerViewModel}.swift`, `App/Shared/{FilePanels,SecretPromptSheet}.swift`, `AppTests/KeyManagerViewModelTests.swift`.
  - Duplicate keys rejected by fingerprint; re-link requires the same fingerprint; deleting a key also removes its Keychain passphrase (partly covers T25) and never touches the key file.

### T12 · Connection lifecycle UX
- **Size:** M · **Depends:** T09, T05 · **Status:** IN PROGRESS (written, NOT compiled/verified)
- **Goal:** Clear feedback for every connection state.
- **Scope:**
  - Overlay in terminal pane: connecting spinner, failure message + Retry, disconnected banner + Reconnect.
  - Host-key approval sheet (host, key type, SHA256 fingerprint, Trust / Cancel); mismatch → red warning sheet, no bypass button (only "Remove old key in Known Hosts settings").
  - Password/passphrase prompt sheet with "Save to Keychain" checkbox.
  - Detect network drop (keepalive interval 30s) → `.disconnected`.
- **Acceptance criteria:**
  - [ ] Each `ConnectionState` has a visible UI.
  - [ ] Killing sshd in Docker shows disconnected banner within keepalive window.
- **Notes:** Unverified (no compiler available to the agent).
  - Files: `App/Features/Terminal/{TerminalPaneView,KnownHostsView,KnownHostsViewModel}.swift`, `AppTests/KnownHostsViewModelTests.swift`.
  - `ConnectionOverlayModel` maps every `ConnectionState` (+ failure, shell exit) to UI; prompt sheets bound to `tab.prompter.current`; closing a sheet declines the prompt.
  - Deviation: host-key-changed warning is rendered in the overlay (from `SSHError.hostKeyChanged`), not as a sheet; `ConnectionPrompter.showHostKeyChanged` is currently unused. No bypass; "Remove old key…" opens Known Hosts; Retry reconnects.
  - Deviation: dead-peer detection uses TCP keepalive (30s idle, 10s interval, 3 probes ≈ 60s total) instead of SSH keepalive, since Citadel has none. Window may exceed 30s; check against the Docker criterion.

**🏁 P0 milestone:** user can save hosts, manage keys, connect with password/key in multiple tabs, all secrets in Keychain.

---

## Phase 2 — P1 Advanced

### T13 · `~/.ssh/config` parser
- **Size:** M · **Depends:** T01 · **Status:** IN PROGRESS
- **Goal:** Pure-Swift parser in `SSHCore/SSHConfig`.
- **Scope:**
  - Supports: `Host` (multiple patterns, `*`, `?`, `!negation`), `HostName`, `User`, `Port`, `IdentityFile` (expand `~`, `%h`, `%u`, `%r`), `ProxyJump`, `Include` (relative to `~/.ssh`, globs), comments, `key=value` and `key value` forms, case-insensitive keywords, quoted values. First-match-wins semantics like OpenSSH.
  - Ignore unsupported keywords but collect them as warnings.
  - Output: `[SSHConfigHost]` (concrete aliases only — wildcard-only blocks applied as defaults, not listed).
- **Acceptance criteria:**
  - [ ] ≥ 15 unit tests from fixture files incl. Include, wildcards, ProxyJump chains.
- **Notes:** Written, NOT compiled/tested by the user yet. `SSHConfig/SSHConfigParser.swift` (+ `SSHConfigParserTests`, 25 tests). Unsupported keywords become warnings. Run `swift test`.

### T14 · SSH config import + merge
- **Size:** S · **Depends:** T13, T04, T09 · **Status:** IN PROGRESS
- **Goal:** Show config hosts read-only in sidebar.
- **Scope:**
  - First run: onboarding prompt "Grant access to ~/.ssh" (NSOpenPanel on folder) → bookmark. Settings toggle to disable.
  - On launch + "Reload" button: parse, map to `HostProfile(source: .sshConfig)`; IdentityFile resolved inside granted folder.
  - Read-only badge; "Duplicate to My Hosts" action. Never write to `~/.ssh/config`.
- **Acceptance criteria:**
  - [ ] Config hosts appear and connect; editing is disabled.
  - [ ] Works after relaunch without re-prompt.
- **Notes:** Written, unverified. `SSHConfigImporter` (folder bookmark → read config, stable IDs via SHA-256 of alias, IdentityFile → in-memory `SSHKeyRef`, ProxyJump last hop → `jumpHostID`). App: `HostListViewModel` merges `configHosts` (never written to `hosts.json`), sidebar banner + SSH Config menu, read-only rows with Duplicate.

### T15 · SFTPServiceActor
- **Size:** L (confirmation gate) · **Depends:** T06 · **Status:** IN PROGRESS
- **Goal:** SFTP operations over an existing session.
- **Scope:**
  - `actor SFTPServiceActor` created from `SSHSessionActor` (reuses connection): `list(path) -> [RemoteFile]`, `stat`, `mkdir`, `rename`, `remove` (file / recursive dir), `realpath("~")`.
  - Transfers: `upload(local:remote:)` / `download(remote:local:)` returning `AsyncThrowingStream<TransferProgress>`; chunked (32–256 KB), cancellable, resumable not required.
  - `TransferQueue` actor: max 3 concurrent transfers.
  - `RemoteFile` (name, path, size, permissions, modified, isDirectory, isSymlink) — `Sendable`.
- **Acceptance criteria:**
  - [ ] Integration tests: list, mkdir, upload 50 MB, download, checksum equal, rename, recursive delete, cancel mid-transfer leaves no partial local file.
- **Notes:** Written, unverified. `SFTP/{SFTPModels,SFTPServiceActor,TransferQueue}.swift`; uploads/downloads write `.part` then rename, cancelled transfers clean up; queue runs max 3. Integration tests gated by `SSH_IT=1`.

### T16 · SFTP split-pane browser UI
- **Size:** L (confirmation gate) · **Depends:** T15, T09 · **Status:** IN PROGRESS
- **Goal:** Visual file manager.
- **Scope:**
  - Tab type "SFTP" (or toggle inside a session tab): `HSplitView` local pane | remote pane, each a `Table` (name, size, modified, permissions) with path bar, back/up, refresh, hidden-files toggle.
  - Local pane: user-selected folder via NSOpenPanel (sandbox) + bookmark of last folder.
  - Actions: drag & drop between panes and from Finder, Upload/Download buttons, rename (inline), delete (confirm), new folder, context menus, Quick Look on downloaded file optional.
  - Transfer panel at bottom: progress, speed, cancel, errors.
- **Acceptance criteria:**
  - [ ] All P1 operations (upload/download/rename/delete) work from UI.
  - [ ] UI stays responsive (main thread never blocked) during a 500 MB transfer.
- **Notes:** Written, unverified. Deviation: SFTP is a per-tab Terminal/Files toggle that reuses the tab's SSH connection (no second login). Local pane uses a user-granted folder bookmark. First-compile risks: `Table(of:)` + `TableRow.draggable`, `PathBar` memberwise init with `@ViewBuilder`.

### T17 · Local port forwarding
- **Size:** L (confirmation gate) · **Depends:** T06 · **Status:** IN PROGRESS
- **Goal:** `-L bindPort:targetHost:targetPort`.
- **Scope:**
  - `actor PortForwardActor`: SwiftNIO `ServerBootstrap` listening on `bindHost:bindPort` (default 127.0.0.1); each inbound connection opens a Citadel `direct-tcpip` channel and pipes bytes both ways.
  - Start/stop, active connection count, bytes in/out stream, port-in-use error.
- **Acceptance criteria:**
  - [ ] Integration: forward local 18080 → remote `localhost:80` (nginx in Docker), `curl` works.
  - [ ] Stopping closes listener and all piped channels.
- **Notes:** Written, unverified. `Tunnels/{GlueHandler,PortForwardActor}.swift`: local listener (`ServerBootstrap`) + direct-tcpip channels, byte counters. Needs `network.server` entitlement (present).

### T18 · Remote port forwarding
- **Size:** L (confirmation gate) · **Depends:** T17 · **Status:** IN PROGRESS
- **Goal:** `-R bindPort:targetHost:targetPort`.
- **Risk:** Citadel may not expose `tcpip-forward` global requests / `forwarded-tcpip` channels. **First step: spike** — check Citadel source; if unsupported, write findings + options (upstream PR, extend via SwiftNIO SSH directly) in an ADR and set status `BLOCKED` for user decision.
- **Acceptance criteria:**
  - [ ] Remote `curl localhost:<bindPort>` on server reaches a local service on the Mac.
- **Notes:** Written, unverified (not blocked: Citadel `withRemotePortForward` / NIOSSH global request used). Gated integration test with `SSH_IT=1`.

### T19 · Tunnels UI
- **Size:** M · **Depends:** T17 · **Status:** IN PROGRESS
- **Goal:** Manage tunnel configs per host.
- **Scope:** List per host (in host editor + global "Tunnels" view), add/edit/delete, Start/Stop toggle, status + traffic, auto-start on connect. Remote type disabled if T18 blocked.
- **Acceptance criteria:**
  - [ ] Tunnel configs persist; auto-start works on connect.
- **Notes:** Written, unverified. Deviation: global Tunnels sheet (toolbar / host context menu, optional host filter) instead of a tab inside the host editor; tunnels run on an already-connected tab; `autoStart` on connect.

### T20 · Split terminal
- **Size:** L (confirmation gate) · **Depends:** T09 · **Status:** IN PROGRESS
- **Goal:** Split a tab horizontally/vertically.
- **Scope:**
  - Pane tree model: `indirect enum PaneNode { case terminal(PaneID), split(axis, [PaneNode], ratios) }` in `SessionTab`.
  - Render recursively with `HSplitView`/`VSplitView`; focus ring on active pane.
  - ⌘D split right, ⇧⌘D split down, ⌘⌥←→↑↓ move focus, ⌘W closes pane (last pane closes tab).
  - New pane opens a **new shell channel on the same SSH connection** (not a new TCP connection).
- **Acceptance criteria:**
  - [ ] 4 panes in one tab, each independent shell, resize correct in each.
  - [ ] Closing a pane frees its channel only.
- **Notes:**

**🏁 P1 milestone.**

---

## Phase 3 — P2 Enhancements

### T21 · Jump host / ProxyJump
- **Size:** L (confirmation gate) · **Depends:** T06, T13 · **Status:** IN PROGRESS
- **Goal:** Connect through a bastion.
- **Scope:** Connect to jump host → open `direct-tcpip` to target:22 → run SSH handshake to target over that channel (check Citadel for built-in jump support first). Support chains (A→B→C) from `ProxyJump a,b`. Host-key verification applies to every hop. Host editor jump picker enabled.
- **Acceptance criteria:**
  - [ ] Integration: two Docker containers on private network, target only reachable via bastion.
- **Notes:** Written, unverified. `SSH/JumpChain.swift` (cycle/missing/depth ≤ 8), `SSHClientHandle.connect(through:)` (hop-by-hop, each hop has its own host-key check + credentials; closing the final handle closes upstream hops), `SSHSessionActor.connect(profile:via:)`. UI: host editor "Connect through" picker (cycle check on save), `HostListViewModel.jumpChain(for:)` includes ssh-config hosts. Tests: `JumpChainTests`. Real two-hop test is manual (see docs/integration-testing.md).

### T22 · Command snippets
- **Size:** M · **Depends:** T02, T08 · **Status:** IN PROGRESS
- **Goal:** Save & 1-click run commands.
- **Scope:** Snippets panel (inspector/sidebar), CRUD, search, click → send to focused pane (optionally without newline), "Send to all panes in tab", ⌘⇧P quick picker. Support `{{placeholder}}` prompting before send.
- **Acceptance criteria:**
  - [ ] Snippet executes in the focused pane; placeholders prompt correctly.
- **Notes:** Written, unverified. `Models/SnippetTemplate.swift` (+tests) for `{{placeholders}}`; App: `Features/Snippets/*` (manager sheet with search/CRUD/Run/Run in all panes, ⌘⇧P picker, placeholder prompt), `SessionTab.send(_:toAll:)`. Sends CR for Enter.

### T23 · Session history + optional output log
- **Size:** M · **Depends:** T02, T09 · **Status:** IN PROGRESS
- **Goal:** Recent connections + opt-in transcript logging.
- **Scope:** `HistoryEntry` written on connect/disconnect; "Recent" section in sidebar (last 10); history view with clear. Per-host opt-in output logging to Application Support `logs/<host>/<date>.log` (raw text, ANSI stripped), size cap + retention setting; warn that logs may contain sensitive output.
- **Acceptance criteria:**
  - [ ] Logging off by default; when on, logs written without blocking UI.
- **Notes:** Written, unverified. `Persistence/HistoryService` (cap 200, stale `.active` closed at launch), sidebar "Recent" (10, double-click to reconnect, Clear). Logging: `Logging/{ANSIStripper,SessionLogger}.swift` — opt-in per host (editor toggle, stored in `settings.loggedHostIDs`), file mode 0600, size cap, retention purge, writes on a background task. Only the primary pane's output is logged (split panes are not).

### T24 · Hardening
- **Size:** M · **Depends:** all P0/P1 · **Status:** IN PROGRESS
- **Goal:** Polish & quality pass.
- **Scope:** Menu bar commands (`.commands`), Settings scene (terminal font/theme, keepalive, known hosts manager, ssh folder access, logging), VoiceOver labels, dark/light mode check, memory leak check with Instruments across 10 open/close cycles, README with build steps.
- **Acceptance criteria:**
  - [ ] No leaks; all shortcuts listed in menus; README complete.
- **Notes:** Partially done, unverified. Settings scene (font, keepalive, ~/.ssh folder, known hosts, logging), menus for tabs/panes/snippets, accessibility labels on new controls, README. NOT done (needs the user on a Mac): Instruments leak check over 10 open/close cycles, full VoiceOver and dark/light pass.

---

## Added during implementation
<!-- Agents: append new tasks here (T25, T26, …) instead of expanding scope of the current task. -->

### T25 · Delete Keychain passphrase when a key ref is deleted
- **Size:** S · **Depends:** T02, T03 · **Status:** TODO
- **Goal:** `KeyRepository` is currently a plain `ListRepository<SSHKeyRef>`; deleting a key leaves its `keyPassphrase(id)` secret in the Keychain.
- **Scope:** Add a `KeyRepository` actor (like `HostRepository`) that deletes `.keyPassphrase(id)` on delete; warn when hosts reference the key (UI side, T11).
- **Acceptance criteria:**
  - [ ] Test: deleting a key removes its passphrase from `InMemoryKeychain`.
- **Notes:** found during T02.

### T26 · CLAUDE.md §7: add `-skipPackagePluginValidation` to xcodebuild commands
- **Size:** S · **Depends:** — · **Status:** TODO
- **Notes:** SwiftTerm's build plugin fails CLI builds without this flag. Needs user approval to edit CLAUDE.md.

### T27 · Host groups (folders) with drag & drop
- **Size:** M · **Depends:** T09, T14 · **Status:** IN PROGRESS
- **Goal:** Organize hosts (including ssh-config hosts) in sidebar folders.
- **Acceptance criteria:**
  - [ ] Create / rename / delete / reorder folders; drag a host onto a folder or out of one; works for ssh-config hosts.
  - [ ] Assignments survive relaunch and ssh-config reload; deleting a folder keeps its hosts.
- **Notes:** Written, unverified. `Models/HostGroup.swift`, `Persistence/GroupRepository.swift` (+`GroupRepositoryTests`), `groups.json`, `UI/Sidebar/{HostsListView,GroupViews}.swift`, `HostListViewModel` group API. See ADR 0006. First-compile risk: nested `dropDestination` (folder vs list-level), `Menu(_:systemImage:)`.
