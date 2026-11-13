import AppKit
import SSHCore
import SwiftUI

/// Preferences window (⌘,): terminal font, connection, SSH folder, known hosts, logging.
struct SettingsView: View {
    let env: AppEnvironment
    let hostList: HostListViewModel

    var body: some View {
        TabView {
            TerminalSettingsTab(env: env)
                .tabItem { Label(String(localized: "Terminal"), systemImage: "terminal") }
            ConnectionSettingsTab(env: env, hostList: hostList)
                .tabItem { Label(String(localized: "Connection"), systemImage: "network") }
            LoggingSettingsTab(env: env)
                .tabItem { Label(String(localized: "Logging"), systemImage: "doc.text") }
        }
        .frame(width: 480, height: 380)
    }
}

private struct TerminalSettingsTab: View {
    let env: AppEnvironment

    var body: some View {
        Form {
            Picker(
                String(localized: "Theme"),
                selection: Binding(
                    get: { env.settings.terminalThemeID ?? TerminalTheme.classic.id },
                    set: { value in Task { await env.updateSettings { $0.terminalThemeID = value } } })
            ) {
                ForEach(TerminalTheme.all) { theme in
                    Label {
                        Text(theme.name)
                    } icon: {
                        ThemeSwatch(theme: theme)
                    }
                    .tag(theme.id)
                }
            }
            TextField(
                String(localized: "Font"),
                text: Binding(
                    get: { env.settings.terminalFontName ?? "" },
                    set: { value in
                        let name = value.trimmingCharacters(in: .whitespaces)
                        Task { await env.updateSettings { $0.terminalFontName = name.isEmpty ? nil : name } }
                    }),
                prompt: Text("SF Mono (default)"))
            Stepper(
                value: Binding(
                    get: { env.settings.terminalFontSize ?? 13 },
                    set: { value in Task { await env.updateSettings { $0.terminalFontSize = value } } }),
                in: 8...32
            ) {
                Text("Size: \(Int(env.settings.terminalFontSize ?? 13)) pt")
            }
            Text("Theme and font apply to open terminals immediately. The font must be installed (use its PostScript name).")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

private struct ConnectionSettingsTab: View {
    let env: AppEnvironment
    let hostList: HostListViewModel
    @State private var showKnownHosts = false

    var body: some View {
        Form {
            Stepper(
                value: Binding(
                    get: { env.settings.keepAliveSeconds ?? 30 },
                    set: { value in Task { await env.updateSettings { $0.keepAliveSeconds = value } } }),
                in: 5...300, step: 5
            ) {
                Text("Keepalive: every \(env.settings.keepAliveSeconds ?? 30) s")
            }
            Text("Applies to connections opened afterwards. Detects a dead network.")
                .font(.caption).foregroundStyle(.secondary)
            Section(String(localized: "SSH folder")) {
                Text(
                    env.settings.sshFolderBookmark == nil
                        ? String(localized: "No access granted to ~/.ssh")
                        : String(localized: "Access to ~/.ssh granted"))
                Button(String(localized: "Choose ~/.ssh Folder…")) {
                    Task { await hostList.grantSSHFolderAccess() }
                }
            }
            Section(String(localized: "Known hosts")) {
                Button(String(localized: "Manage Known Hosts…")) { showKnownHosts = true }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showKnownHosts) { KnownHostsView(env: env) }
    }
}

private struct LoggingSettingsTab: View {
    let env: AppEnvironment

    var body: some View {
        Form {
            Text("Logging is off by default and is enabled per host in the host editor.")
            Stepper(
                value: Binding(
                    get: { env.settings.logRetentionDays ?? 30 },
                    set: { value in Task { await env.updateSettings { $0.logRetentionDays = value } } }),
                in: 1...365
            ) {
                Text("Keep logs for \(env.settings.logRetentionDays ?? 30) days")
            }
            Stepper(
                value: Binding(
                    get: { (env.settings.logMaxBytes ?? 10_000_000) / 1_000_000 },
                    set: { value in Task { await env.updateSettings { $0.logMaxBytes = value * 1_000_000 } } }),
                in: 1...500
            ) {
                Text("Max size per log: \((env.settings.logMaxBytes ?? 10_000_000) / 1_000_000) MB")
            }
            Button(String(localized: "Show Logs in Finder")) {
                let folder = env.paths.logsDirectory
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            }
            Text("Logs may contain sensitive output.").font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

/// Small preview: background with the foreground and six ANSI colors.
private struct ThemeSwatch: View {
    let theme: TerminalTheme

    var body: some View {
        HStack(spacing: 1) {
            ForEach([theme.foreground, theme.ansi[1], theme.ansi[2], theme.ansi[3], theme.ansi[4]], id: \.self) { value in
                Circle().fill(Color(nsColor: TerminalTheme.ns(value))).frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, Theme.Spacing.xs)
        .padding(.vertical, Theme.Spacing.xs)
        .background(Color(nsColor: theme.nsBackground), in: RoundedRectangle(cornerRadius: Theme.Radius.small))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.small).stroke(.separator))
    }
}
