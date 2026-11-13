import SSHCore
import SwiftUI

/// Icon-only switch between Hosts / Recent / Snippets.
struct SidebarSectionPicker: View {
    @Binding var selection: SidebarSection

    var body: some View {
        Picker(String(localized: "Section"), selection: $selection) {
            ForEach(SidebarSection.allCases) { section in
                Label(section.title, systemImage: section.symbol)
                    .labelStyle(.iconOnly)
                    .help(section.title)
                    .tag(section)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.regular)
        .padding(.horizontal, Theme.Spacing.md)
    }
}

/// Rounded search field styled like the native sidebar search.
struct SidebarSearchField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Clear search"))
            }
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.xs)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: Theme.Radius.small))
        .padding(.horizontal, Theme.Spacing.md)
    }
}

/// Onboarding / error strip for the `~/.ssh/config` import.
struct SidebarConfigBanner: View {
    let hostList: HostListViewModel

    var body: some View {
        if hostList.needsSSHFolderGrant {
            card {
                Label(String(localized: "Import hosts from ~/.ssh/config?"), systemImage: "square.and.arrow.down")
                    .font(.callout.bold())
                Text("Grant read access to your ~/.ssh folder once. The config file is never modified.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(String(localized: "Grant Access…")) { Task { await hostList.grantSSHFolderAccess() } }
                        .buttonStyle(.borderedProminent)
                    Button(String(localized: "Not Now")) { Task { await hostList.setConfigImport(enabled: false) } }
                }
                .controlSize(.small)
            }
        } else if let error = hostList.configError {
            card {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor).font(.caption)
                Button(String(localized: "Re-grant Access…")) { Task { await hostList.grantSSHFolderAccess() } }
                    .controlSize(.small)
            }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm, content: content)
            .padding(Theme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
            .padding(Theme.Spacing.sm)
    }
}

/// Bottom bar: add host, keys, tunnels, ssh-config menu, settings.
struct SidebarFooter: View {
    let hostList: HostListViewModel

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            ToolbarIconButton(symbol: "plus", help: String(localized: "Add Host")) {
                hostList.editorRequest = .create
            }
            ToolbarIconButton(symbol: "folder.badge.plus", help: String(localized: "New Group")) {
                hostList.groupPrompt = .create(hostIDs: [])
            }
            ToolbarIconButton(symbol: "key", help: String(localized: "SSH Keys")) {
                hostList.showKeyManager = true
            }
            ToolbarIconButton(symbol: "arrow.left.arrow.right", help: String(localized: "Tunnels")) {
                hostList.tunnelsRequest = TunnelsSheetRequest(hostFilter: nil)
            }
            Spacer()
            tagMenu
            configMenu
            SettingsLink {
                Image(systemName: "gearshape").symbolRenderingMode(.hierarchical)
                    .frame(width: Theme.Layout.iconButton, height: Theme.Layout.iconButton)
            }
            .buttonStyle(.borderless)
            .hoverHighlight()
            .help(String(localized: "Settings"))
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.xs)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var tagMenu: some View {
        Menu {
            Button(String(localized: "All Tags")) { hostList.selectedTag = nil }
            ForEach(hostList.allTags, id: \.self) { tag in
                Button(tag) { hostList.selectedTag = tag }
            }
        } label: {
            Image(systemName: hostList.selectedTag == nil ? "tag" : "tag.fill")
                .symbolRenderingMode(.hierarchical)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .disabled(hostList.allTags.isEmpty)
        .help(hostList.selectedTag.map { String(localized: "Filtering by \($0)") } ?? String(localized: "Filter by tag"))
    }

    private var configMenu: some View {
        Menu {
            Toggle(
                String(localized: "Import ~/.ssh/config"),
                isOn: Binding(
                    get: { hostList.isConfigImportEnabled },
                    set: { value in Task { await hostList.setConfigImport(enabled: value) } }))
            Button(String(localized: "Reload SSH Config")) { Task { await hostList.reloadSSHConfig() } }
            Button(String(localized: "Choose ~/.ssh Folder…")) { Task { await hostList.grantSSHFolderAccess() } }
            if !hostList.configWarnings.isEmpty {
                Divider()
                Text("\(hostList.configWarnings.count) config warning(s)")
                ForEach(hostList.configWarnings, id: \.self) { Text($0) }
            }
        } label: {
            Image(systemName: "doc.text").symbolRenderingMode(.hierarchical)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(String(localized: "SSH Config"))
    }
}
