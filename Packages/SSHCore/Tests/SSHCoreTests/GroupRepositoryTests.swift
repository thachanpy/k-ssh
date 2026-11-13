import XCTest

@testable import SSHCore

final class GroupRepositoryTests: XCTestCase {
    private func makeRepo() -> GroupRepository {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("groups-\(UUID().uuidString).json")
        return GroupRepository(store: JSONStore(url: url, defaultValue: GroupsState()))
    }

    func testCreateTrimsAndRejectsEmptyOrDuplicate() async throws {
        let repo = makeRepo()
        let group = try await repo.createGroup(name: "  Prod  ")
        XCTAssertEqual(group.name, "Prod")
        do {
            _ = try await repo.createGroup(name: "prod")
            XCTFail("expected duplicate error")
        } catch { XCTAssertEqual(error as? GroupError, .duplicateName("prod")) }
        do {
            _ = try await repo.createGroup(name: "   ")
            XCTFail("expected empty error")
        } catch { XCTAssertEqual(error as? GroupError, .emptyName) }
    }

    func testAssignMoveAndUngroup() async throws {
        let repo = makeRepo()
        let a = try await repo.createGroup(name: "A")
        let b = try await repo.createGroup(name: "B")
        let host = UUID()
        try await repo.assign(hostIDs: [host], to: a.id)
        var state = try await repo.state()
        XCTAssertEqual(state.groupID(of: host), a.id)
        try await repo.assign(hostIDs: [host], to: b.id)
        state = try await repo.state()
        XCTAssertEqual(state.groupID(of: host), b.id)
        try await repo.assign(hostIDs: [host], to: nil)
        state = try await repo.state()
        XCTAssertNil(state.groupID(of: host))
    }

    func testAssignToMissingGroupThrows() async throws {
        let repo = makeRepo()
        do {
            try await repo.assign(hostIDs: [UUID()], to: UUID())
            XCTFail("expected notFound")
        } catch { XCTAssertEqual(error as? GroupError, .notFound) }
    }

    func testDeleteGroupUngroupsHosts() async throws {
        let repo = makeRepo()
        let g = try await repo.createGroup(name: "G")
        let host = UUID()
        try await repo.assign(hostIDs: [host], to: g.id)
        try await repo.deleteGroup(id: g.id)
        let state = try await repo.state()
        XCTAssertTrue(state.groups.isEmpty)
        XCTAssertNil(state.groupID(of: host))
        XCTAssertTrue(state.assignments.isEmpty)
    }

    func testRenameAndOrder() async throws {
        let repo = makeRepo()
        let a = try await repo.createGroup(name: "A")
        let b = try await repo.createGroup(name: "B")
        try await repo.renameGroup(id: a.id, to: "Alpha")
        try await repo.moveGroup(id: b.id, by: -1)
        let state = try await repo.state()
        XCTAssertEqual(state.groups.map(\.name), ["B", "Alpha"])
        do {
            try await repo.renameGroup(id: a.id, to: "b")
            XCTFail("expected duplicate")
        } catch { XCTAssertEqual(error as? GroupError, .duplicateName("b")) }
    }

    func testStaleAssignmentIgnored() {
        let host = UUID()
        let state = GroupsState(groups: [], assignments: [host.uuidString: UUID()])
        XCTAssertNil(state.groupID(of: host))
    }
}
