import XCTest

@testable import SSHCore

final class JumpChainTests: XCTestCase {
    private func host(_ name: String, jump: HostProfile? = nil) -> HostProfile {
        HostProfile(
            name: name, hostname: name, port: 22, username: "u", auth: .password, jumpHostID: jump?.id)
    }

    func testDirectHostHasEmptyChain() throws {
        let a = host("a")
        XCTAssertTrue(try JumpChain.resolve(for: a, hosts: [a]).isEmpty)
    }

    func testSingleJump() throws {
        let bastion = host("bastion")
        let target = host("target", jump: bastion)
        let chain = try JumpChain.resolve(for: target, hosts: [bastion, target])
        XCTAssertEqual(chain.map(\.name), ["bastion"])
    }

    func testOrderIsOutermostFirst() throws {
        let a = host("a")
        let b = host("b", jump: a)
        let t = host("t", jump: b)
        let chain = try JumpChain.resolve(for: t, hosts: [a, b, t])
        XCTAssertEqual(chain.map(\.name), ["a", "b"])
    }

    func testMissingHostThrows() {
        let ghost = host("ghost")
        let t = host("t", jump: ghost)
        XCTAssertThrowsError(try JumpChain.resolve(for: t, hosts: [t])) {
            XCTAssertEqual($0 as? JumpChainError, .missingHost(ghost.id))
        }
    }

    func testCycleThrows() {
        var a = host("a")
        let b = host("b", jump: a)
        a.jumpHostID = b.id
        XCTAssertThrowsError(try JumpChain.resolve(for: a, hosts: [a, b])) {
            XCTAssertEqual($0 as? JumpChainError, .cycle(hostName: "a"))
        }
    }

    func testSelfReferenceThrows() {
        var a = host("a")
        a.jumpHostID = a.id
        XCTAssertThrowsError(try JumpChain.resolve(for: a, hosts: [a])) {
            XCTAssertEqual($0 as? JumpChainError, .cycle(hostName: "a"))
        }
    }

    func testTooDeepThrows() {
        var hosts: [HostProfile] = [host("h0")]
        for i in 1...(JumpChain.maxHops + 1) { hosts.append(host("h\(i)", jump: hosts[i - 1])) }
        XCTAssertThrowsError(try JumpChain.resolve(for: hosts[hosts.count - 1], hosts: hosts)) {
            XCTAssertEqual($0 as? JumpChainError, .tooDeep)
        }
    }

    func testMaxDepthAllowed() throws {
        var hosts: [HostProfile] = [host("h0")]
        for i in 1...JumpChain.maxHops { hosts.append(host("h\(i)", jump: hosts[i - 1])) }
        let chain = try JumpChain.resolve(for: hosts[hosts.count - 1], hosts: hosts)
        XCTAssertEqual(chain.count, JumpChain.maxHops)
    }
}
