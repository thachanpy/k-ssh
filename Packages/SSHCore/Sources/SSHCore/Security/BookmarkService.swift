import Foundation

/// Errors from security-scoped bookmark handling.
public enum BookmarkError: LocalizedError, Sendable, Equatable {
    /// The bookmark data could not be created or resolved (file deleted, data corrupt…).
    case invalid(String)
    /// The bookmark resolved but is stale. `refreshed` holds regenerated bookmark data when it
    /// could be produced; the caller should persist it, or re-prompt the user if `nil`.
    case stale(refreshed: Data?)
    /// The system refused access to the resolved URL.
    case accessDenied

    public var errorDescription: String? {
        switch self {
        case .invalid(let message):
            return String(localized: "The saved file access is no longer valid: \(message)")
        case .stale:
            return String(localized: "The saved file access is out of date. Please select the file again.")
        case .accessDenied:
            return String(localized: "Access to the selected file was denied.")
        }
    }
}

/// Creates and resolves security-scoped bookmarks for user-selected files and folders.
///
/// Concurrency: an actor. `withAccess` always pairs `startAccessingSecurityScopedResource()` with
/// a `defer` that stops access, even when `body` throws.
public actor BookmarkService {
    /// Creates a service.
    public init() {}

    /// Creates security-scoped bookmark data for a user-selected URL.
    /// - Throws: `BookmarkError.invalid` if the bookmark cannot be created.
    public func makeBookmark(for url: URL) throws -> Data {
        do {
            return try url.bookmarkData(
                options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            // A read-write scope is refused for read-only files (e.g. a key with mode 0400).
            // Retry asking for read access only; that is all we ever need.
            do {
                return try url.bookmarkData(
                    options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                    includingResourceValuesForKeys: nil, relativeTo: nil)
            } catch {
                throw BookmarkError.invalid(error.localizedDescription)
            }
        }
    }

    /// Resolves `bookmark`, grants scoped access for the duration of `body`, then stops access.
    /// - Parameters:
    ///   - bookmark: Data from `makeBookmark(for:)`.
    ///   - body: Work to perform while access is active. Do not let the URL escape.
    /// - Throws: `BookmarkError.stale` (UI should re-prompt/refresh), `.invalid`, `.accessDenied`,
    ///   or whatever `body` throws.
    public func withAccess<T: Sendable>(
        to bookmark: Data,
        _ body: @Sendable (URL) async throws -> T
    ) async throws -> T {
        var isStale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil,
                bookmarkDataIsStale: &isStale)
        } catch {
            throw BookmarkError.invalid(error.localizedDescription)
        }
        // `start…` can return false although the file is readable (e.g. access already granted, or the
        // process is not sandboxed). So do not fail here: run `body` and let real read errors surface.
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }

        if isStale {
            throw BookmarkError.stale(refreshed: try? makeBookmark(for: url))
        }
        return try await body(url)
    }
}
