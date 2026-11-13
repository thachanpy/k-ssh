import XCTest

@testable import SSHClient

final class TunnelValidationTests: XCTestCase {
    func testValidLocalTunnelHasNoErrors() {
        XCTAssertTrue(
            TunnelValidation.errors(
                kind: .local, bindHost: "127.0.0.1", bindPort: 8080, targetHost: "db", targetPort: 5432
            ).isEmpty)
    }

    func testLocalBindPortZeroIsRejectedButRemoteAllowsIt() {
        XCTAssertFalse(
            TunnelValidation.errors(
                kind: .local, bindHost: "127.0.0.1", bindPort: 0, targetHost: "db", targetPort: 1
            ).isEmpty)
        XCTAssertTrue(
            TunnelValidation.errors(
                kind: .remote, bindHost: "127.0.0.1", bindPort: 0, targetHost: "db", targetPort: 1
            ).isEmpty)
    }

    func testRejectsMissingOrOutOfRangeValues() {
        XCTAssertFalse(
            TunnelValidation.errors(kind: .local, bindHost: " ", bindPort: 80, targetHost: "x", targetPort: 80)
                .isEmpty)
        XCTAssertFalse(
            TunnelValidation.errors(kind: .local, bindHost: "h", bindPort: 70000, targetHost: "x", targetPort: 80)
                .isEmpty)
        XCTAssertFalse(
            TunnelValidation.errors(kind: .local, bindHost: "h", bindPort: nil, targetHost: "x", targetPort: 80)
                .isEmpty)
        XCTAssertFalse(
            TunnelValidation.errors(kind: .local, bindHost: "h", bindPort: 80, targetHost: "", targetPort: 80)
                .isEmpty)
        XCTAssertFalse(
            TunnelValidation.errors(kind: .local, bindHost: "h", bindPort: 80, targetHost: "x", targetPort: 0)
                .isEmpty)
    }
}
