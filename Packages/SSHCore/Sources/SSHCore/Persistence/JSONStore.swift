import Foundation
import os

/// Actor-isolated, atomic JSON persistence for a single `Codable` value.
///
/// On disk the value is wrapped in an envelope `{ "schemaVersion": n, "data": … }`.
/// - A missing file yields `defaultValue`.
/// - A corrupt file is renamed to `<name>.corrupt-<date>` and `defaultValue` is returned.
/// - A file with a newer `schemaVersion` throws `PersistenceError.unsupportedSchema` and is left untouched.
///
/// Concurrency: all file access happens synchronously inside the actor, so `update(_:)` is an
/// atomic read-modify-write with no suspension points (no lost updates).
public actor JSONStore<Value: Codable & Sendable> {
    private struct Envelope: Codable {
        var schemaVersion: Int
        var data: Value
    }

    private let url: URL
    private let defaultValue: Value
    private let schemaVersion: Int
    private let logger = Logger(subsystem: "SSHCore", category: "JSONStore")

    /// Creates a store.
    /// - Parameters:
    ///   - url: File to read/write. Parent directories are created on first save.
    ///   - defaultValue: Returned when the file is missing or corrupt.
    ///   - schemaVersion: Current schema version written to disk.
    public init(url: URL, defaultValue: Value, schemaVersion: Int = 1) {
        self.url = url
        self.defaultValue = defaultValue
        self.schemaVersion = schemaVersion
    }

    /// Loads the stored value.
    /// - Throws: `PersistenceError` on I/O failure or unsupported schema.
    public func load() async throws -> Value {
        try readValue()
    }

    /// Atomically replaces the stored value.
    /// - Throws: `PersistenceError.io` on failure.
    public func save(_ value: Value) async throws {
        try writeValue(value)
    }

    /// Atomic read-modify-write.
    /// - Parameter transform: Mutates the value in place and returns a result.
    /// - Returns: The closure's result (typically the new state).
    /// - Throws: Errors from loading, `transform`, or saving.
    public func update<Result: Sendable>(
        _ transform: @Sendable (inout Value) throws -> Result
    ) async throws -> Result {
        var value = try readValue()
        let result = try transform(&value)
        try writeValue(value)
        return result
    }

    // MARK: - Private

    private func readValue() throws -> Value {
        guard FileManager.default.fileExists(atPath: url.path) else { return defaultValue }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw PersistenceError.io(error.localizedDescription)
        }
        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard envelope.schemaVersion <= schemaVersion else {
                throw PersistenceError.unsupportedSchema(
                    found: envelope.schemaVersion, supported: schemaVersion)
            }
            return envelope.data
        } catch let error as PersistenceError {
            throw error
        } catch {
            quarantineCorruptFile()
            return defaultValue
        }
    }

    private func writeValue(_ value: Value) throws {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(Envelope(schemaVersion: schemaVersion, data: value))
            try data.write(to: url, options: .atomic)
        } catch {
            throw PersistenceError.io(error.localizedDescription)
        }
    }

    private func quarantineCorruptFile() {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let target = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).corrupt-\(stamp)")
        logger.error("Corrupt store file \(self.url.lastPathComponent, privacy: .private); quarantining")
        do {
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.moveItem(at: url, to: target)
        } catch {
            logger.error("Could not quarantine corrupt file: \(error.localizedDescription, privacy: .public)")
        }
    }
}
