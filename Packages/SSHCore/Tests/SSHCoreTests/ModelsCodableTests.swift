import XCTest

@testable import SSHCore

/// Codable round-trip and "no secrets" checks for all domain models.
final class ModelsCodableTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    private func roundTrip<T: Codable & Equatable>(
        _ value: T, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(T.self, from: data)
        XCTAssertEqual(decoded, value, file: file, line: line)
    }

    func testHostProfileRoundTrip() throws {
        try roundTrip(HostProfile(name: "web", hostname: "example.com", username: "me"))
        try roundTrip(
            HostProfile(
                name: "db", hostname: "10.0.0.5", port: 2222, username: "root",
                auth: .privateKey(keyID: UUID()), jumpHostID: UUID(), tags: ["prod", "db"],
                source: .sshConfig, createdAt: date, lastConnectedAt: date))
    }

    func testHostProfileDefaultPortIs22() {
        XCTAssertEqual(HostProfile(name: "a", hostname: "b", username: "c").port, 22)
    }

    func testAuthMethodRoundTrip() throws {
        try roundTrip(AuthMethod.password)
        try roundTrip(AuthMethod.privateKey(keyID: UUID()))
    }

    func testSSHKeyRefRoundTrip() throws {
        try roundTrip(
            SSHKeyRef(
                label: "laptop", keyType: .ed25519, bookmarkData: Data([1, 2, 3]),
                fingerprintSHA256: "SHA256:abc", hasPassphrase: true, addedAt: date))
    }

    func testTunnelConfigRoundTrip() throws {
        try roundTrip(
            TunnelConfig(
                hostID: UUID(), kind: .local, bindPort: 18080, targetHost: "localhost",
                targetPort: 80, autoStart: true))
        try roundTrip(
            TunnelConfig(
                hostID: UUID(), kind: .remote, bindHost: "0.0.0.0", bindPort: 9000,
                targetHost: "127.0.0.1", targetPort: 3000))
    }

    func testSnippetRoundTrip() throws {
        try roundTrip(Snippet(title: "Disk", command: "df -h", tags: ["ops"], appendNewline: false))
    }

    func testHistoryEntryRoundTrip() throws {
        try roundTrip(
            HistoryEntry(
                hostID: UUID(), hostDisplayName: "web", startedAt: date, endedAt: date,
                outcome: .completed))
        try roundTrip(HistoryEntry(hostID: UUID(), hostDisplayName: "web", startedAt: date))
    }

    func testKnownHostRoundTripAndIdentity() throws {
        let host = KnownHost(
            hostPattern: "example.com:22", keyType: .rsa, fingerprintSHA256: "SHA256:xyz",
            publicKeyBase64: "AAAA", addedAt: date)
        try roundTrip(host)
        XCTAssertEqual(host.id, "example.com:22")
    }

    func testConnectionStateEquatable() {
        XCTAssertEqual(
            ConnectionState.awaitingHostKeyApproval(fingerprint: "SHA256:a"),
            .awaitingHostKeyApproval(fingerprint: "SHA256:a"))
        XCTAssertNotEqual(ConnectionState.disconnected(reason: nil), .disconnected(reason: "x"))
        XCTAssertNotEqual(ConnectionState.connecting, .connected)
    }

    /// No model may expose a field that could hold a password, passphrase, or key bytes.
    func testNoSecretFieldsOnModels() {
        let models: [Any] = [
            HostProfile(name: "a", hostname: "b", username: "c"),
            SSHKeyRef(
                label: "k", keyType: .rsa, bookmarkData: Data(), fingerprintSHA256: "f",
                hasPassphrase: false),
            TunnelConfig(hostID: UUID(), kind: .local, bindPort: 1, targetHost: "h", targetPort: 2),
            Snippet(title: "t", command: "c"),
            HistoryEntry(hostID: UUID(), hostDisplayName: "h"),
            KnownHost(hostPattern: "h:22", keyType: .rsa, fingerprintSHA256: "f", publicKeyBase64: "p"),
        ]
        let forbidden = ["password", "secret", "privatekey", "keybytes", "keydata", "passphrase"]
        for model in models {
            for child in Mirror(reflecting: model).children {
                let label = (child.label ?? "").lowercased()
                // `hasPassphrase` is a Bool flag, not a secret.
                if label == "haspassphrase" { continue }
                XCTAssertFalse(
                    forbidden.contains { label.contains($0) },
                    "\(type(of: model)).\(label) looks like a secret field")
            }
        }
    }
}
