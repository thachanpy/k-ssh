import XCTest

@testable import SSHCore

/// Placeholder test proving the test target builds and runs.
final class SSHCoreTests: XCTestCase {
    /// The package exposes a non-empty version string.
    func testVersionIsNotEmpty() {
        XCTAssertFalse(SSHCore.version.isEmpty)
    }
}
