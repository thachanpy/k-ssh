import XCTest

@testable import SSHClient

final class LocalFileTests: XCTestCase {
    private func makeFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalFileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testListsFoldersFirstThenByNameAndReportsSizes() throws {
        let dir = try makeFolder()
        try "12345".write(to: dir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try "1".write(to: dir.appendingPathComponent("A.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("zdir"), withIntermediateDirectories: false)

        let files = try LocalFile.list(dir, showHidden: false)
        XCTAssertEqual(files.map(\.name), ["zdir", "A.txt", "b.txt"])
        XCTAssertTrue(files[0].isDirectory)
        XCTAssertEqual(files[2].size, 5)
    }

    func testHiddenFilesOnlyWhenRequested() throws {
        let dir = try makeFolder()
        try "x".write(to: dir.appendingPathComponent(".secret"), atomically: true, encoding: .utf8)
        try "x".write(to: dir.appendingPathComponent("visible"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try LocalFile.list(dir, showHidden: false).map(\.name), ["visible"])
        XCTAssertEqual(Set(try LocalFile.list(dir, showHidden: true).map(\.name)), [".secret", "visible"])
    }

    func testListingMissingFolderThrows() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString)")
        XCTAssertThrowsError(try LocalFile.list(missing, showHidden: false))
    }
}
