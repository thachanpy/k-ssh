# ADR 0001 — Third-party dependencies and pinned versions

- **Status:** Accepted
- **Date:** 2026-11-13
- **Task:** T00

## Context

CLAUDE.md fixes the stack: Citadel for SSH/SFTP, SwiftTerm for terminal rendering, XcodeGen for project generation.
Versions must be pinned so builds are reproducible.

## Decision

| Dependency | Pinned version | Consumed by | Notes |
|---|---|---|---|
| [Citadel](https://github.com/orlandos-nl/Citadel) | `exact: 0.12.1` | `SSHCore` package | Latest tag at T00. Manifest is swift-tools 5.9, min macOS 14. |
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | `exactVersion: 1.99.3` (tag `v1.99.3`) | App target (`project.yml`) | Latest tag at T00. Manifest requires swift-tools **6.2** → needs Xcode 26+ / Swift 6.2+ toolchain. |
| XcodeGen | any recent (`brew install xcodegen`) | tooling | Generates `SSHClient.xcodeproj` from `project.yml`. |

Exact pins (rather than `from:`) are used so a transitive-minor bump cannot change behavior silently; upgrade deliberately and update this file.

## Consequences / things to know

- Citadel 0.12.1 depends on a **fork of swift-nio-ssh** (`github.com/Wellz26/swift-nio-ssh`, `0.3.4 ..< 0.4.0`), plus swift-nio, swift-crypto, BigInt, swift-log. Treat this as supply-chain surface; revisit if upstream `apple/swift-nio-ssh` is restored.
- SwiftTerm's default trait `PortableGraphics` pulls `swift-png` on non-Apple platforms only; no impact on macOS.
- `Package.resolved` files should be committed once generated to lock transitive versions.
- **Direct deps added in T05:** `SSHCore` also declares `swift-nio-ssh` (`Wellz26` fork, `0.3.4 ..< 0.4.0`) and `swift-nio` (`from: 2.81.0`) directly, mirroring Citadel's own ranges, because Citadel does not re-export `NIOSSH`/`NIOCore` and the host-key delegate needs them. Keep these ranges in sync when bumping Citadel.
- (Superseded in T05: `SSHCore` now imports Citadel in `HostKeyValidationDelegate.swift`.) `SSHCore` did not `import Citadel` (nothing uses it until T06); it is declared so resolution and linking are exercised from T00.
- Citadel/SwiftTerm APIs change between versions: before using an API, read the resolved source in `.build/checkouts`.
