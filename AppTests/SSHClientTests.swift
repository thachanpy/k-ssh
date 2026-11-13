import SSHCore
import XCTest

@testable import SSHClient

/// Shared helpers for app-level tests.
@MainActor
enum TestSupport {
    /// An environment backed by a fresh temp directory and an in-memory Keychain.
    static func makeEnvironment(testCase: XCTestCase) throws -> (env: AppEnvironment, directory: URL, keychain: InMemoryKeychain) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SSHClientTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        testCase.addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let keychain = InMemoryKeychain()
        let env = AppEnvironment(paths: AppPaths(baseURL: directory), keychain: keychain)
        return (env, directory, keychain)
    }
}

/// Smoke test that the app target links against SSHCore.
final class SSHClientTests: XCTestCase {
    func testCoreVersionIsAvailable() {
        XCTAssertFalse(SSHCore.version.isEmpty)
    }
}
