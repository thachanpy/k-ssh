import Foundation

/// User preferences persisted in `settings.json`. Contains no secrets.
public struct AppSettings: Sendable, Codable, Hashable {
    /// Security-scoped bookmark of the user-granted `~/.ssh` folder (used by T13/T14).
    public var sshFolderBookmark: Data?
    /// Whether hosts from `~/.ssh/config` are merged into the sidebar.
    public var importSSHConfigEnabled: Bool
    /// Terminal font family; `nil` uses the default (SF Mono).
    public var terminalFontName: String?
    /// Terminal font size in points; `nil` uses the default (13).
    public var terminalFontSize: Double?
    /// Security-scoped bookmark of the folder last used in the SFTP local pane.
    public var lastLocalFolderBookmark: Data?
    /// Hosts whose terminal output is logged to disk (opt-in; `nil`/empty = logging off everywhere).
    public var loggedHostIDs: [UUID]?
    /// Keep transcripts this many days (`nil` = 30).
    public var logRetentionDays: Int?
    /// Stop writing a transcript after this many bytes (`nil` = 10 MB).
    public var logMaxBytes: Int?
    /// TCP keepalive idle seconds (`nil` = 30).
    public var keepAliveSeconds: Int?
    /// ID of the terminal color theme (`nil` = Classic).
    public var terminalThemeID: String?

    /// Creates settings with defaults.
    public init(
        sshFolderBookmark: Data? = nil, importSSHConfigEnabled: Bool = true,
        terminalFontName: String? = nil, terminalFontSize: Double? = nil,
        lastLocalFolderBookmark: Data? = nil, loggedHostIDs: [UUID]? = nil,
        logRetentionDays: Int? = nil, logMaxBytes: Int? = nil, keepAliveSeconds: Int? = nil,
        terminalThemeID: String? = nil
    ) {
        self.sshFolderBookmark = sshFolderBookmark
        self.importSSHConfigEnabled = importSSHConfigEnabled
        self.terminalFontName = terminalFontName
        self.terminalFontSize = terminalFontSize
        self.lastLocalFolderBookmark = lastLocalFolderBookmark
        self.loggedHostIDs = loggedHostIDs
        self.logRetentionDays = logRetentionDays
        self.logMaxBytes = logMaxBytes
        self.keepAliveSeconds = keepAliveSeconds
        self.terminalThemeID = terminalThemeID
    }
}
