import SSHCore
import XCTest

@testable import SSHClient

@MainActor
final class KnownHostsViewModelTests: XCTestCase {
    func testLoadSortsAndRemoveDeletesEntry() async throws {
        let (env, _, _) = try TestSupport.makeEnvironment(testCase: self)
        for name in ["b.example:22", "a.example:22"] {
            try await env.knownHosts.trust(
                KnownHost(
                    hostPattern: name, keyType: .ed25519, fingerprintSHA256: "SHA256:x",
                    publicKeyBase64: "AAAA", addedAt: Date()))
        }
        let model = KnownHostsViewModel(env: env)
        await model.load()
        XCTAssertEqual(model.hosts.map(\.hostPattern), ["a.example:22", "b.example:22"])

        await model.remove(model.hosts[0])
        XCTAssertEqual(model.hosts.map(\.hostPattern), ["b.example:22"])
    }
}
