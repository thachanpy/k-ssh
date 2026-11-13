# SSH Client (macOS)

Native macOS SSH + SFTP client: SwiftUI, Citadel (SSH), SwiftTerm (terminal). Hosts, keys and settings
are stored locally; passwords and key passphrases live only in the Keychain.

## Requirements

- macOS 14+, Xcode with Swift 6.x, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Build

```bash
xcodegen generate                       # after any project.yml change
cd Packages/SSHCore && swift test       # core tests
cd ../..
xcodebuild -project SSHClient.xcodeproj -scheme SSHClient -destination 'platform=macOS' \
  -skipPackagePluginValidation build
xcodebuild -project SSHClient.xcodeproj -scheme SSHClient -destination 'platform=macOS' \
  -skipPackagePluginValidation test
```

Integration tests need a Docker OpenSSH server: see `docs/integration-testing.md` (`SSH_IT=1`).

## Features

Hosts and tags, password / private-key auth (security-scoped key bookmarks), host-key verification,
tabs, split panes, SFTP browser with transfer queue, local/remote port forwarding, `~/.ssh/config`
import, jump hosts, snippets with `{{placeholders}}`, connection history, opt-in session logs.

## Shortcuts

| Shortcut | Action |
|---|---|
| ⌘T / ⌘W | New tab / close pane or tab |
| ⌘1…⌘9, ⌃Tab, ⌃⇧Tab | Switch tabs |
| ⌘D / ⇧⌘D | Split right / down |
| ⌥⌘ arrows | Move pane focus |
| ⇧⌘P | Run snippet |
| ⌘, | Settings |

## Layout and rules

See `CLAUDE.md` (architecture, concurrency, security rules), `docs/TASKS.md` (backlog and status) and
`docs/adr/` (decisions). Status: most tasks are written but not yet verified on a Mac.
