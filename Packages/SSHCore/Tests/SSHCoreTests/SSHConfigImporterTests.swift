import XCTest

@testable import SSHCore

final class SSHConfigImporterTests: XCTestCase {
    private struct Fixture {
        let sshFolder: URL
        let bookmarks: BookmarkService
        let keys: KeyRepository
        let importer: SSHConfigImporter
        let folderBookmark: Data
    }

    /// Creates `<tmp>/<uuid>/.ssh` so `~` expansion (parent of the granted folder) lands inside it.
    private func makeFixture(config: String, files: [String: String] = [:]) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SSHConfigImporterTests-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent(".ssh", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try config.write(to: folder.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        for (name, content) in files {
            let url = folder.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        let bookmarks = BookmarkService()
        let keys = KeyRepository(
            store: JSONStore(url: root.appendingPathComponent("keys.json"), defaultValue: []))
        let folderBookmark = try await bookmarks.makeBookmark(for: folder)
        return Fixture(
            sshFolder: folder, bookmarks: bookmarks, keys: keys,
            importer: SSHConfigImporter(bookmarks: bookmarks, keys: keys), folderBookmark: folderBookmark)
    }

    func testImportsHostsAsReadOnlyConfigProfiles() async throws {
        let f = try await makeFixture(
            config: """
                Host web
                    HostName 10.0.0.5
                    User deploy
                    Port 2222
                Host *
                    User fallback
                """)
        let result = try await f.importer.load(folderBookmark: f.folderBookmark, localUser: "me")
        XCTAssertEqual(result.hosts.count, 1)
        let web = try XCTUnwrap(result.hosts.first)
        XCTAssertEqual(web.name, "web")
        XCTAssertEqual(web.hostname, "10.0.0.5")
        XCTAssertEqual(web.username, "deploy")
        XCTAssertEqual(web.port, 2222)
        XCTAssertEqual(web.source, .sshConfig)
        XCTAssertEqual(web.auth, .password)
        XCTAssertEqual(web.id, SSHConfigImporter.stableID(alias: "web"))
    }

    func testStableIDIsDeterministicAndDistinct() {
        XCTAssertEqual(SSHConfigImporter.stableID(alias: "a"), SSHConfigImporter.stableID(alias: "a"))
        XCTAssertNotEqual(SSHConfigImporter.stableID(alias: "a"), SSHConfigImporter.stableID(alias: "b"))
    }

    func testDefaultUserIsLocalUser() async throws {
        let f = try await makeFixture(config: "Host a\n  HostName a.example")
        let result = try await f.importer.load(folderBookmark: f.folderBookmark, localUser: "me")
        XCTAssertEqual(result.hosts.first?.username, "me")
    }

    func testIdentityFileInsideFolderIsRegisteredOnceAndShared() async throws {
        let key = try KeyGenerator.generateEd25519(comment: "t")
        let f = try await makeFixture(
            config: """
                Host a
                    HostName a.example
                    IdentityFile ~/.ssh/id_test
                Host b
                    HostName b.example
                    IdentityFile ~/.ssh/id_test
                """,
            files: ["id_test": key.privateKeyText])
        let result = try await f.importer.load(folderBookmark: f.folderBookmark, localUser: "me")
        let stored = try await f.keys.all()
        XCTAssertEqual(stored.count, 1, "the same key file must be registered once")
        XCTAssertEqual(stored[0].fingerprintSHA256, key.publicKey.fingerprintSHA256)
        for host in result.hosts {
            XCTAssertEqual(host.auth, .privateKey(keyID: stored[0].id))
        }

        // Reloading must not duplicate the key.
        _ = try await f.importer.load(folderBookmark: f.folderBookmark, localUser: "me")
        let again = try await f.keys.all()
        XCTAssertEqual(again.count, 1)
    }

    func testUnreadableIdentityFileFallsBackToPasswordWithWarning() async throws {
        let f = try await makeFixture(
            config: "Host a\n  HostName a.example\n  IdentityFile ~/.ssh/missing")
        let result = try await f.importer.load(folderBookmark: f.folderBookmark, localUser: "me")
        XCTAssertEqual(result.hosts.first?.auth, .password)
        XCTAssertTrue(result.warnings.contains { $0.contains("missing") })
    }

    func testProxyJumpMapsToJumpHostID() async throws {
        let f = try await makeFixture(
            config: """
                Host bastion
                    HostName b.example
                Host target
                    HostName t.example
                    ProxyJump bastion
                Host lost
                    ProxyJump nowhere
                """)
        let result = try await f.importer.load(folderBookmark: f.folderBookmark, localUser: "me")
        let target = try XCTUnwrap(result.hosts.first { $0.name == "target" })
        XCTAssertEqual(target.jumpHostID, SSHConfigImporter.stableID(alias: "bastion"))
        let lost = try XCTUnwrap(result.hosts.first { $0.name == "lost" })
        XCTAssertNil(lost.jumpHostID)
        XCTAssertTrue(result.warnings.contains { $0.contains("nowhere") })
    }

    func testIncludeInsideFolderIsFollowed() async throws {
        let f = try await makeFixture(
            config: "Include config.d/*\nHost main\n  HostName m.example",
            files: ["config.d/extra": "Host extra\n  HostName e.example"])
        let result = try await f.importer.load(folderBookmark: f.folderBookmark, localUser: "me")
        XCTAssertEqual(Set(result.hosts.map(\.name)), ["main", "extra"])
    }

    func testMissingConfigFileGivesWarningAndNoHosts() async throws {
        let f = try await makeFixture(config: "Host a")
        try FileManager.default.removeItem(at: f.sshFolder.appendingPathComponent("config"))
        let result = try await f.importer.load(folderBookmark: f.folderBookmark, localUser: "me")
        XCTAssertTrue(result.hosts.isEmpty)
        XCTAssertFalse(result.warnings.isEmpty)
    }

    func testNothingIsWrittenToTheFolder() async throws {
        let f = try await makeFixture(config: "Host a\n  HostName a.example")
        let before = try FileManager.default.contentsOfDirectory(atPath: f.sshFolder.path).sorted()
        _ = try await f.importer.load(folderBookmark: f.folderBookmark, localUser: "me")
        let after = try FileManager.default.contentsOfDirectory(atPath: f.sshFolder.path).sorted()
        XCTAssertEqual(before, after)
    }
}
