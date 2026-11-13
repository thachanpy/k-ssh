import XCTest

@testable import SSHCore

final class SnippetTemplateTests: XCTestCase {
    func testFindsUniquePlaceholdersInOrder() {
        let names = SnippetTemplate.placeholders(in: "scp {{src}} {{ host }}:{{dst}} # {{src}}")
        XCTAssertEqual(names, ["src", "host", "dst"])
    }

    func testIgnoresInvalidTokens() {
        XCTAssertEqual(SnippetTemplate.placeholders(in: "echo {{}} {{a b}} {{ok}} {{unclosed"), ["ok"])
        XCTAssertTrue(SnippetTemplate.placeholders(in: "plain command").isEmpty)
    }

    func testFillsAllOccurrences() {
        let out = SnippetTemplate.fill("a {{x}} b {{ x }} c {{y}}", values: ["x": "1", "y": "2"])
        XCTAssertEqual(out, "a 1 b 1 c 2")
    }

    func testMissingValueLeavesToken() {
        XCTAssertEqual(SnippetTemplate.fill("{{x}} {{y}}", values: ["x": "1"]), "1 {{y}}")
    }

    func testValueContainingBracesIsNotReprocessed() {
        XCTAssertEqual(SnippetTemplate.fill("{{x}} {{y}}", values: ["x": "{{y}}", "y": "2"]), "{{y}} 2")
    }

    func testBytesAppendCarriageReturn() {
        XCTAssertEqual(SnippetTemplate.bytes(for: "ls", appendNewline: true), Array("ls\r".utf8))
        XCTAssertEqual(SnippetTemplate.bytes(for: "ls", appendNewline: false), Array("ls".utf8))
    }
}
