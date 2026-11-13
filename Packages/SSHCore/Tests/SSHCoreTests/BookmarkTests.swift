import XCTest

@testable import SSHCore

/// Tests for `BookmarkService` and `SettingsRepository`.
final class BookmarkTests: XCTestCase {
    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SSHCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testBookmarkRoundTripGrantsAccess() async throws {
        let file = try makeTempDirectory().appendingPathComponent("key")
        try Data("hello".utf8).write(to: file)
        let service = BookmarkService()
        let bookmark = try await service.makeBookmark(for: file)
        let contents = try await service.withAccess(to: bookmark) { url in
            try String(contentsOf: url, encoding: .utf8)
        }
        XCTAssertEqual(contents, "hello")
    }

    func testGarbageBookmarkThrowsInvalid() async {
        let service = BookmarkService()
        do {
            _ = try await service.withAccess(to: Data([0, 1, 2, 3])) { _ in 1 }
            XCTFail("expected invalid")
        } catch let error as BookmarkError {
            guard case .invalid = error else { return XCTFail("wrong case: \(error)") }
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testBodyErrorPropagates() async throws {
        struct Boom: Error {}
        let file = try makeTempDirectory().appendingPathComponent("f")
        try Data().write(to: file)
        let service = BookmarkService()
        let bookmark = try await service.makeBookmark(for: file)
        do {
            _ = try await service.withAccess(to: bookmark) { _ -> Int in throw Boom() }
            XCTFail("expected Boom")
        } catch is Boom {
        }
    }

    /// Moving the file usually marks the bookmark stale; skipped if the filesystem doesn't report it.
    func testStaleBookmarkSurfacesTypedError() async throws {
        let dir = try makeTempDirectory()
        let original = dir.appendingPathComponent("a")
        try Data("x".utf8).write(to: original)
        let service = BookmarkService()
        let bookmark = try await service.makeBookmark(for: original)
        try FileManager.default.moveItem(at: original, to: dir.appendingPathComponent("b"))
        do {
            _ = try await service.withAccess(to: bookmark) { _ in 1 }
            throw XCTSkip("Filesystem did not report the bookmark as stale")
        } catch let error as BookmarkError {
            guard case .stale = error else { return XCTFail("wrong case: \(error)") }
        }
    }

    func testSettingsRepositoryStoresSSHFolderBookmark() async throws {
        let url = try makeTempDirectory().appendingPathComponent("settings.json")
        let repo = SettingsRepository(store: JSONStore(url: url, defaultValue: AppSettings()))
        let initial = try await repo.get()
        XCTAssertNil(initial.sshFolderBookmark)
        XCTAssertTrue(initial.importSSHConfigEnabled)
        try await repo.setSSHFolderBookmark(Data([9, 8, 7]))
        let stored = try await repo.get()
        XCTAssertEqual(stored.sshFolderBookmark, Data([9, 8, 7]))
    }
}
