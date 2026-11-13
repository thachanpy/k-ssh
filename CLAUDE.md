# CLAUDE.md — macOS SSH & SFTP Client

This file is the source of truth for any agent working in this repo. Read it fully before every task.
The task backlog lives in `docs/TASKS.md`. Work on **one task ID at a time**, in dependency order.

---

## 1. Project Overview

A native macOS SSH + SFTP client (think Termius / Royal TSX, but fully native).

| Item | Value |
|---|---|
| Language | Swift 6.4, Swift 6 language mode, **Strict Concurrency = Complete** |
| UI | SwiftUI (AppKit only via `NSViewRepresentable` when unavoidable, e.g. SwiftTerm) |
| Min target | macOS 14.0 |
| Architecture | MVVM + Swift Concurrency (actors for I/O, `@MainActor` ViewModels) |
| SSH | [Citadel](https://github.com/orlandos-nl/Citadel) (SwiftNIO SSH based — pure Swift, sandbox-friendly) |
| Terminal | [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (`TerminalView`, AppKit) |
| Persistence | Codable JSON in Application Support (see §5) — **not** SwiftData |
| Secrets | Keychain Services (`Security` framework) only |
| Project generation | XcodeGen (`project.yml`) — never hand-edit `.xcodeproj` |

> Do **not** use `Shout` (libssh2 C dependency, poor sandbox/concurrency story). If Citadel lacks a feature,
> stop and report it in the task's "Blockers" section instead of swapping libraries.

---

## 2. Repository Layout

```
ssh-application/
├── CLAUDE.md
├── project.yml                     # XcodeGen spec (app target + test target)
├── docs/
│   ├── TASKS.md                    # backlog, status, acceptance criteria
│   └── adr/                        # architecture decision records (one .md per decision)
├── Packages/
│   └── SSHCore/                    # Swift package: ALL non-UI logic, testable via `swift test`
│       ├── Package.swift
│       ├── Sources/SSHCore/
│       │   ├── Models/             # Sendable value types (HostProfile, SSHKeyRef, Tunnel, Snippet…)
│       │   ├── Persistence/        # JSONStore actor, file locations
│       │   ├── Security/           # KeychainService, BookmarkService, KnownHostsStore
│       │   ├── SSH/                # SSHSessionActor, auth, PTY, jump host
│       │   ├── SFTP/               # SFTPServiceActor
│       │   ├── Tunnels/            # PortForwardActor
│       │   └── SSHConfig/          # ~/.ssh/config parser
│       └── Tests/SSHCoreTests/
└── App/
    ├── SSHClientApp.swift          # @main
    ├── App.entitlements
    ├── Info.plist
    ├── Features/
    │   ├── Hosts/                  # sidebar, host editor (View + ViewModel)
    │   ├── Keys/                   # key manager
    │   ├── Terminal/               # SwiftTerm wrapper, split panes
    │   ├── SFTP/                   # file browser
    │   ├── Tunnels/
    │   ├── Snippets/
    │   └── History/
    ├── Shared/                     # reusable views, modifiers, DI container (AppEnvironment)
    └── Resources/
```

Rule: **`SSHCore` must not import SwiftUI or AppKit.** UI types live only in `App/`.

---

## 3. Concurrency Rules (CRITICAL — build must have zero concurrency warnings)

1. Every model crossing an actor boundary is a `struct`/`enum` conforming to `Sendable` (+ `Codable`, `Hashable`, `Identifiable` where useful).
2. Every ViewModel: `@MainActor @Observable final class XxxViewModel`. Use the Observation framework (`@Observable`), not `ObservableObject`, unless a SwiftUI API requires it.
3. Network / file / Keychain work happens in `actor`s inside `SSHCore`. ViewModels `await` them.
4. Streams from actors to UI use `AsyncStream` / `AsyncThrowingStream` of `Sendable` elements. ViewModels consume them in a `Task` stored on the VM and cancelled in `deinit`/`disconnect()`.
5. **Forbidden** without a written justification comment + ADR: `@unchecked Sendable`, `nonisolated(unsafe)`, `@preconcurrency import`, `MainActor.assumeIsolated`, `DispatchQueue` for new code.
   - Known exception: bridging SwiftTerm's `TerminalViewDelegate` (AppKit, main thread) — isolate the coordinator with `@MainActor`.
6. Do not use `Task.detached` unless you must drop actor context; prefer an actor method.
7. Cancellation must be honored: long loops check `Task.isCancelled` / `try Task.checkCancellation()`.

---

## 4. Security Rules (CRITICAL)

- **Never** write a password, passphrase, or private-key contents to disk, `UserDefaults`, logs, or JSON. Only Keychain.
- Keychain: `kSecClassGenericPassword`, `kSecAttrService = "<bundle-id>.credentials"`, `kSecAttrAccount = "<kind>:<UUID>"` (e.g. `password:<hostID>`, `passphrase:<keyID>`). Accessibility: `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
- Private keys: store a **security-scoped bookmark** (`URL.bookmarkData(options: .withSecurityScope)`) of the user-selected file. Always pair `startAccessingSecurityScopedResource()` with `defer { stop… }`. Handle stale bookmarks by re-prompting.
- Host key verification is mandatory: unknown host → prompt user (show fingerprint SHA256); changed host key → hard error with warning UI. Store in app's own `known_hosts.json`. Never use an "accept all" validator outside of tests.
- Logging: use `os.Logger` with `privacy: .private` for hostnames/usernames; never log secrets.
- Sandbox entitlements (`App/App.entitlements`):
  - `com.apple.security.app-sandbox` = true
  - `com.apple.security.network.client` = true
  - `com.apple.security.network.server` = true (needed for local port forwarding listeners)
  - `com.apple.security.files.user-selected.read-write` = true
  - `com.apple.security.files.bookmarks.app-scope` = true
  - `~/.ssh/config` is **not readable** in the sandbox by default. Use a user-granted folder bookmark (user picks `~/.ssh` once via `NSOpenPanel`). Do not add temporary-exception entitlements without an ADR.

---

## 5. Persistence

- Directory: `FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]/<bundle-id>/`
- Files: `hosts.json`, `keys.json`, `tunnels.json`, `snippets.json`, `history.json`, `known_hosts.json`, `settings.json`.
- Each file is owned by a generic `actor JSONStore<Value: Codable & Sendable>`; writes are atomic (`.atomic`), encoded with a `schemaVersion` field for future migrations.
- Hosts imported from `~/.ssh/config` are **never written** to `hosts.json`; they are merged in memory and flagged `source = .sshConfig` (read-only in UI, "Duplicate to edit" action).

---

## 6. Coding Conventions

- Every public/internal type and every non-trivial function gets a `///` doc comment (purpose, parameters, throws, concurrency notes).
- Errors: one `enum XxxError: LocalizedError, Sendable` per module with user-readable `errorDescription`.
- Dependency injection: protocols for services (`SSHSessionProviding`, `KeychainProviding`, …) so ViewModels can be tested with fakes. An `AppEnvironment` (`@MainActor`) wires concrete instances and is passed via `.environment(...)`.
- No force unwraps / `try!` outside tests.
- SwiftUI views stay small (< ~150 lines); extract subviews.
- Use `swift-format` defaults (4-space indent). Keep files < 400 lines.
- Strings shown to the user go through `String(localized:)`.

---

## 7. Build & Test Commands

```bash
# Generate Xcode project (after any project.yml change)
xcodegen generate

# Core logic tests (fast, run after every SSHCore change)
cd Packages/SSHCore && swift test

# Full app build
xcodebuild -project SSHClient.xcodeproj -scheme SSHClient -destination 'platform=macOS' build

# App tests
xcodebuild -project SSHClient.xcodeproj -scheme SSHClient -destination 'platform=macOS' test
```

A task is **not done** until: build succeeds with **zero warnings in project sources**, `swift test` passes, and every acceptance criterion in `docs/TASKS.md` is checked.

Integration testing against a real server: use a local Docker OpenSSH container (`linuxserver/openssh-server`) on port 2222. Integration tests are gated by env var `SSH_IT=1` and must be skipped otherwise.

---

## 8. Agent Workflow (follow for EVERY task)

1. **Read** `docs/TASKS.md`, pick the lowest-numbered task whose status is `TODO` and whose dependencies are `DONE` (or the task the user names). Set its status to `IN PROGRESS`.
2. **Architecture note** — short explanation of the design: types, actors, views, how VM ↔ Model communicate.
3. **Step-by-step plan** — numbered implementation steps.
4. **Confirmation gate** — if the task is tagged `size: L`, STOP after steps 2–3 and ask the user to confirm before writing code. `S`/`M` tasks proceed directly.
5. **Implement step by step** — one step at a time, building/testing after each meaningful step. Don't dump everything at once.
6. **Document** — `///` comments on all new types/functions; add an ADR in `docs/adr/` for any non-obvious decision.
7. **Verify** — run build + tests (§7), tick each acceptance criterion in `docs/TASKS.md`.
8. **Close** — set status `DONE`, fill the task's "Notes" with files changed, deviations, follow-ups. If blocked, set `BLOCKED` and describe why.

Scope discipline: do only what the task says. If you notice something else that needs doing, add it as a new task at the bottom of `docs/TASKS.md` rather than doing it.

Third-party API caution: Citadel and SwiftTerm APIs change between versions. Before using an API, check the resolved version's source in `.build/checkouts` (or the package's README/tests). Do not guess method signatures.
