import XCTest

@testable import SSHCore

final class ANSIStripperTests: XCTestCase {
    private func strip(_ chunks: [String]) -> String {
        var stripper = ANSIStripper()
        var out: [UInt8] = []
        for chunk in chunks { out += stripper.feed(Array(chunk.utf8)) }
        return String(decoding: out, as: UTF8.self)
    }

    func testPlainTextUnchanged() {
        XCTAssertEqual(strip(["hello\tworld\n"]), "hello\tworld\n")
    }

    func testRemovesColorsAndCursorMoves() {
        XCTAssertEqual(strip(["\u{1B}[31mred\u{1B}[0m \u{1B}[2K\u{1B}[1;5Hok"]), "red ok")
    }

    func testRemovesOSCTitleTerminatedByBellOrST() {
        XCTAssertEqual(strip(["a\u{1B}]0;title\u{07}b\u{1B}]2;t2\u{1B}\\c"]), "abc")
    }

    func testSequenceSplitAcrossChunks() {
        XCTAssertEqual(strip(["x\u{1B}", "[3", "1mred", "\u{1B}]0;ti", "tle\u{07}y"]), "xredy")
    }

    func testCRLFBecomesLFAndControlsDropped() {
        XCTAssertEqual(strip(["a\r\nb\u{07}\u{08}c\r"]), "a\nbc")
    }

    func testKeepsMultibyteUTF8() {
        XCTAssertEqual(strip(["xin chào \u{1B}[1mđẹp\u{1B}[0m"]), "xin chào đẹp")
    }
}

final class SessionLoggerTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("logtest-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    func testWritesStrippedTextInOrder() async throws {
        let logger = try SessionLogger(root: root, hostName: "my host/1", maxBytes: 1_000)
        logger.log(Array("one \u{1B}[31m".utf8))
        logger.log(Array("two\r\n".utf8))
        await logger.finish()
        let text = try String(contentsOf: logger.fileURL, encoding: .utf8)
        XCTAssertEqual(text, "one two\n")
        XCTAssertEqual(logger.fileURL.deletingLastPathComponent().lastPathComponent, "my_host_1")
    }

    func testStopsAtSizeCap() async throws {
        let logger = try SessionLogger(root: root, hostName: "h", maxBytes: 10)
        logger.log(Array(String(repeating: "a", count: 50).utf8))
        logger.log(Array("more".utf8))
        await logger.finish()
        let text = try String(contentsOf: logger.fileURL, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix(String(repeating: "a", count: 10)))
        XCTAssertTrue(text.contains("log truncated"))
        XCTAssertFalse(text.contains("more"))
    }

    func testPurgeRemovesOldLogsOnly() throws {
        let folder = root.appendingPathComponent("h", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let old = folder.appendingPathComponent("old.log")
        let fresh = folder.appendingPathComponent("fresh.log")
        try Data("x".utf8).write(to: old)
        try Data("y".utf8).write(to: fresh)
        let past = Date().addingTimeInterval(-40 * 86_400)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: old.path)
        XCTAssertEqual(SessionLogger.purge(root: root, olderThanDays: 30), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
    }

    func testSanitize() {
        XCTAssertEqual(SessionLogger.sanitize("../etc"), "_etc")
        XCTAssertEqual(SessionLogger.sanitize(""), "host")
    }
}

final class HistoryServiceTests: XCTestCase {
    private func makeService() -> HistoryService {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hist-\(UUID().uuidString).json")
        return HistoryService(repository: HistoryRepository(store: JSONStore(url: url, defaultValue: [])))
    }

    func testBeginFinishAndRecentOrder() async throws {
        let service = makeService()
        let host = UUID()
        let first = try await service.begin(hostID: host, hostName: "a", at: Date(timeIntervalSince1970: 100))
        _ = try await service.begin(hostID: host, hostName: "b", at: Date(timeIntervalSince1970: 200))
        try await service.finish(first, outcome: .completed, at: Date(timeIntervalSince1970: 150))
        let recent = try await service.recent(limit: 10)
        XCTAssertEqual(recent.map(\.hostDisplayName), ["b", "a"])
        XCTAssertEqual(recent[1].outcome, .completed)
        XCTAssertNotNil(recent[1].endedAt)
    }

    func testRecentRespectsLimit() async throws {
        let service = makeService()
        for i in 0..<15 {
            _ = try await service.begin(hostID: UUID(), hostName: "h\(i)", at: Date(timeIntervalSince1970: Double(i)))
        }
        let recent = try await service.recent(limit: 10)
        XCTAssertEqual(recent.count, 10)
        XCTAssertEqual(recent.first?.hostDisplayName, "h14")
    }

    func testCapsStoredEntries() async throws {
        let service = makeService()
        for i in 0..<(HistoryService.maxEntries + 5) {
            _ = try await service.begin(hostID: UUID(), hostName: "h\(i)", at: Date(timeIntervalSince1970: Double(i)))
        }
        let all = try await service.recent(limit: 1_000)
        XCTAssertEqual(all.count, HistoryService.maxEntries)
    }

    func testClearAndStaleClose() async throws {
        let service = makeService()
        _ = try await service.begin(hostID: UUID(), hostName: "x")
        try await service.closeStaleEntries()
        let entries = try await service.recent(limit: 5)
        XCTAssertEqual(entries.first?.outcome, .completed)
        try await service.clear()
        let after = try await service.recent(limit: 5)
        XCTAssertTrue(after.isEmpty)
    }

    func testRecordAttemptStoresFailure() async throws {
        let service = makeService()
        try await service.recordAttempt(hostID: UUID(), hostName: "bad", outcome: .failed)
        let recent = try await service.recent(limit: 1)
        XCTAssertEqual(recent.first?.outcome, .failed)
    }
}
