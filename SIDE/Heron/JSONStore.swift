import Foundation

/// One shared, versioned, failure-reporting JSON file format for every persisted store.
///
/// Two problems this exists to fix. First, none of the stores recorded a schema version, so
/// there was no way to tell an old file from a new one and no place for a migration to hook —
/// adding a single non-optional field to `AgentSession` or `Checkpoint` would have made every
/// existing file fail to decode and silently read back as empty. Second, every write was a
/// `try? data.write(...)`: a full disk, a revoked permission, or a read-only volume lost the
/// user's tracks and conversations without a word.
///
/// Files are written as `{"schemaVersion": N, "payload": …}`. A bare payload (no envelope) is
/// read as version 1 — that's every file written before this existed, so no migration pass is
/// needed to adopt it; the next write upgrades the file in place.
enum JSONStore {
    /// Bump when a change can't be expressed as "a new field with a default." Tolerant decoding
    /// (`decodeIfPresent` with a default, which every persisted struct here now uses) covers
    /// additive changes without a version bump; this is for renames, splits, and semantic
    /// changes, where `read`'s reported version tells the caller what shape it's holding.
    static let currentVersion = 2

    private struct Envelope<Payload: Codable>: Codable {
        let schemaVersion: Int
        let payload: Payload
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Returns `nil` when the file doesn't exist yet (the ordinary first-run case) and reports a
    /// failure when it exists but can't be read or decoded — a corrupt file that silently reads
    /// as "no data" is how a user loses work without knowing it happened.
    static func read<Payload: Codable>(_ type: Payload.Type, from url: URL) -> (payload: Payload, version: Int)? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            PersistenceFailureReporter.shared.report(url: url, operation: .read, error: error)
            return nil
        }
        let decoder = decoder()
        if let envelope = try? decoder.decode(Envelope<Payload>.self, from: data) {
            return (envelope.payload, envelope.schemaVersion)
        }
        do {
            // Pre-envelope file: the payload sat at the top level. Version 1 by definition.
            return (try decoder.decode(Payload.self, from: data), 1)
        } catch {
            PersistenceFailureReporter.shared.report(url: url, operation: .read, error: error)
            return nil
        }
    }

    /// Atomic, and loud on failure. Returns whether the write landed, for callers that need to
    /// avoid treating unsaved state as saved.
    @discardableResult
    static func write<Payload: Codable>(_ payload: Payload, to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try encoder().encode(Envelope(schemaVersion: currentVersion, payload: payload))
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            PersistenceFailureReporter.shared.report(url: url, operation: .write, error: error)
            return false
        }
    }
}

/// Where persistence failures go instead of into a `try?`.
///
/// Deliberately deduplicated per file and operation: a store that saves on every keystroke would
/// otherwise produce an unbounded stack of identical alerts the moment a disk fills up. The first
/// failure for a given file is surfaced; later identical ones are counted, not repeated.
final class PersistenceFailureReporter: @unchecked Sendable {
    static let shared = PersistenceFailureReporter()

    enum Operation: String {
        case read
        case write
    }

    struct Failure {
        let url: URL
        let operation: Operation
        let error: Error
        /// How many times this same file/operation has failed, including this one.
        let occurrenceCount: Int
    }

    /// Posted on the main thread for whoever presents failures (`AppDelegate`). A notification
    /// rather than a direct call because persistence lives below the UI layer and shouldn't
    /// reach up into it.
    static let failureNotification = Notification.Name("SidePersistenceFailure")

    private var counts: [String: Int] = [:]

    func report(url: URL, operation: Operation, error: Error) {
        let key = "\(operation.rawValue):\(url.path)"
        let count = (counts[key] ?? 0) + 1
        counts[key] = count
        NSLog("[Side] persistence %@ failed for %@: %@", operation.rawValue, url.path, error.localizedDescription)
        guard count == 1 else { return }
        let failure = Failure(url: url, operation: operation, error: error, occurrenceCount: count)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.failureNotification, object: failure)
        }
    }

    /// Test seam — lets a test observe the first-failure behavior without inheriting counts from
    /// whatever ran before it.
    func resetCounts() { counts.removeAll() }
}
