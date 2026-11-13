import SSHCore
import XCTest

@testable import SSHClient

final class HostGroupsTests: XCTestCase {
    func testDropPayloadRoundTrip() {
        let host = HostProfile(name: "a", hostname: "a", username: "u", auth: .password)
        let payload = HostListViewModel.dragPayload(for: host)
        XCTAssertEqual(HostListViewModel.hostIDs(fromDrop: [payload]), [host.id])
    }

    func testTabDragPayloadsAreIgnored() {
        // Tab drags carry a bare UUID string; they must never be read as a host drop.
        XCTAssertTrue(HostListViewModel.hostIDs(fromDrop: [UUID().uuidString, "host:not-a-uuid"]).isEmpty)
    }
}
