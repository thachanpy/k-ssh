import XCTest

@testable import SSHClient

final class PaneNodeTests: XCTestCase {
    private let a = UUID()
    private let b = UUID()
    private let c = UUID()
    private let d = UUID()

    func testLeafIDsFollowLayoutOrder() {
        let tree = PaneNode.split(.horizontal, .terminal(a), .split(.vertical, .terminal(b), .terminal(c)))
        XCTAssertEqual(tree.leafIDs, [a, b, c])
    }

    func testReplacingALeafWithASplit() {
        let tree = PaneNode.terminal(a).replacing(a, with: .split(.horizontal, .terminal(a), .terminal(b)))
        XCTAssertEqual(tree, .split(.horizontal, .terminal(a), .terminal(b)))
    }

    func testReplacingUnknownIdChangesNothing() {
        let tree = PaneNode.split(.horizontal, .terminal(a), .terminal(b))
        XCTAssertEqual(tree.replacing(c, with: .terminal(d)), tree)
    }

    func testRemovingALeafPromotesItsSibling() {
        let tree = PaneNode.split(.horizontal, .terminal(a), .split(.vertical, .terminal(b), .terminal(c)))
        XCTAssertEqual(tree.removing(b), .split(.horizontal, .terminal(a), .terminal(c)))
        XCTAssertEqual(tree.removing(a), .split(.vertical, .terminal(b), .terminal(c)))
    }

    func testRemovingTheOnlyLeafYieldsNil() {
        XCTAssertNil(PaneNode.terminal(a).removing(a))
    }

    func testRemovingUnknownIdKeepsTree() {
        let tree = PaneNode.split(.horizontal, .terminal(a), .terminal(b))
        XCTAssertEqual(tree.removing(c), tree)
    }

    func testFourPanesBuiltBySuccessiveSplits() {
        var tree = PaneNode.terminal(a)
        tree = tree.replacing(a, with: .split(.horizontal, .terminal(a), .terminal(b)))
        tree = tree.replacing(b, with: .split(.vertical, .terminal(b), .terminal(c)))
        tree = tree.replacing(a, with: .split(.vertical, .terminal(a), .terminal(d)))
        XCTAssertEqual(tree.leafIDs, [a, d, b, c])
        XCTAssertEqual(tree.removing(b)?.leafIDs, [a, d, c])
    }
}
