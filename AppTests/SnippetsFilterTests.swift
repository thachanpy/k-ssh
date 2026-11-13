import SSHCore
import XCTest

@testable import SSHClient

final class SnippetsFilterTests: XCTestCase {
    private let list = [
        Snippet(title: "Disk usage", command: "df -h", tags: ["disk"]),
        Snippet(title: "Restart", command: "sudo systemctl restart {{svc}}", tags: ["ops"]),
    ]

    func testEmptyQueryReturnsAll() {
        XCTAssertEqual(SnippetsViewModel.filter(list, by: "  ").count, 2)
    }

    func testMatchesTitleCommandAndTags() {
        XCTAssertEqual(SnippetsViewModel.filter(list, by: "DISK").map(\.title), ["Disk usage"])
        XCTAssertEqual(SnippetsViewModel.filter(list, by: "systemctl").map(\.title), ["Restart"])
        XCTAssertEqual(SnippetsViewModel.filter(list, by: "ops").map(\.title), ["Restart"])
        XCTAssertTrue(SnippetsViewModel.filter(list, by: "zzz").isEmpty)
    }
}
