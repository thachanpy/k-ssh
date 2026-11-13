import XCTest

@testable import SSHCore

/// Tests for `JSONStore`, `ListRepository`, and `HostRepository`.
final class PersistenceTests: XCTestCase {
    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SSHCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testAppPathsFileURLs() throws {
        let dir = try makeTempDirectory()
        let paths = AppPaths(baseURL: dir)
        XCTAssertEqual(paths.fileURL(.hosts).lastPathComponent, "hosts.json")
        XCTAssertEqual(paths.fileURL(.knownHosts).lastPathComponent, "known_hosts.json")
        XCTAssertEqual(StoreFile.allCases.count, 8)
    }

    func testSaveLoadRoundTripWritesEnvelope() async throws {
        let url = try makeTempDirectory().appendingPathComponent("v.json")
        let store = JSONStore<[String]>(url: url, defaultValue: [])
        try await store.save(["a", "b"])
        let loaded = try await store.load()
        XCTAssertEqual(loaded, ["a", "b"])
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("schemaVersion"))
    }

    func testMissingFileReturnsDefault() async throws {
        let url = try makeTempDirectory().appendingPathComponent("missing.json")
        let store = JSONStore<[String]>(url: url, defaultValue: ["default"])
        let loaded = try await store.load()
        XCTAssertEqual(loaded, ["default"])
    }

    func testCorruptFileIsQuarantinedAndDefaultReturned() async throws {
        let dir = try makeTempDirectory()
        let url = dir.appendingPathComponent("bad.json")
        try Data("not json".utf8).write(to: url)
        let store = JSONStore<[String]>(url: url, defaultValue: ["default"])
        let loaded = try await store.load()
        XCTAssertEqual(loaded, ["default"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("bad.json.corrupt-") })
    }

    func testNewerSchemaThrowsAndKeepsFile() async throws {
        let url = try makeTempDirectory().appendingPathComponent("new.json")
        try Data(#"{"schemaVersion":99,"data":[]}"#.utf8).write(to: url)
        let store = JSONStore<[String]>(url: url, defaultValue: [])
        do {
            _ = try await store.load()
            XCTFail("expected unsupportedSchema")
        } catch let error as PersistenceError {
            XCTAssertEqual(error, .unsupportedSchema(found: 99, supported: 1))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testConcurrentUpdatesLoseNothing() async throws {
        let url = try makeTempDirectory().appendingPathComponent("counter.json")
        let store = JSONStore<Int>(url: url, defaultValue: 0)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask { _ = try? await store.update { $0 += 1 } }
            }
        }
        let total = try await store.load()
        XCTAssertEqual(total, 100)
    }

    func testConcurrentRepositoryUpsertsLoseNothing() async throws {
        let url = try makeTempDirectory().appendingPathComponent("snippets.json")
        let repo = SnippetRepository(store: JSONStore(url: url, defaultValue: []))
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<100 {
                group.addTask {
                    _ = try? await repo.upsert(Snippet(title: "s\(index)", command: "echo \(index)"))
                }
            }
        }
        let all = try await repo.all()
        XCTAssertEqual(all.count, 100)
    }

    func testUpsertReplacesInPlaceAndDeleteReturnsRemoved() async throws {
        let url = try makeTempDirectory().appendingPathComponent("snippets.json")
        let repo = SnippetRepository(store: JSONStore(url: url, defaultValue: []))
        var first = Snippet(title: "one", command: "1")
        let second = Snippet(title: "two", command: "2")
        try await repo.upsert(first)
        try await repo.upsert(second)
        first.title = "uno"
        try await repo.upsert(first)
        let all = try await repo.all()
        XCTAssertEqual(all.map(\.title), ["uno", "two"])
        let removed = try await repo.delete(id: first.id)
        XCTAssertEqual(removed?.title, "uno")
        let missing = try await repo.delete(id: first.id)
        XCTAssertNil(missing)
    }

    func testChangesStreamEmitsCurrentThenUpdates() async throws {
        let url = try makeTempDirectory().appendingPathComponent("snippets.json")
        let repo = SnippetRepository(store: JSONStore(url: url, defaultValue: []))
        let stream = await repo.changes()
        var iterator = stream.makeAsyncIterator()
        let initial = await iterator.next()
        XCTAssertEqual(initial?.count, 0)
        try await repo.upsert(Snippet(title: "x", command: "x"))
        let updated = await iterator.next()
        XCTAssertEqual(updated?.count, 1)
    }

    func testDeletingHostDeletesKeychainPassword() async throws {
        let url = try makeTempDirectory().appendingPathComponent("hosts.json")
        let keychain = InMemoryKeychain()
        let repo = HostRepository(store: JSONStore(url: url, defaultValue: []), keychain: keychain)
        let host = HostProfile(name: "h", hostname: "example.com", username: "me")
        try await repo.upsert(host)
        try await keychain.set("hunter2", for: .hostPassword(host.id))
        try await repo.delete(id: host.id)
        let secret = try await keychain.get(.hostPassword(host.id))
        XCTAssertNil(secret)
        let hosts = try await repo.all()
        XCTAssertTrue(hosts.isEmpty)
    }

    func testSSHConfigHostsAreNeverPersisted() async throws {
        let url = try makeTempDirectory().appendingPathComponent("hosts.json")
        let repo = HostRepository(store: JSONStore(url: url, defaultValue: []), keychain: InMemoryKeychain())
        let host = HostProfile(name: "h", hostname: "x", username: "u", source: .sshConfig)
        do {
            try await repo.upsert(host)
            XCTFail("expected readOnlySource")
        } catch let error as PersistenceError {
            XCTAssertEqual(error, .readOnlySource)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
