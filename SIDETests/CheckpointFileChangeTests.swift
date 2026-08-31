import XCTest
@testable import Side

/// Line counts on a checkpoint, and the pill that reads them back.
///
/// The bug these pin: Think's changed-files pill was rebuilt from in-memory state and so vanished
/// on relaunch, while Review went on showing the very same diffs from the durable record. Two
/// surfaces describing one set of changes must not disagree because a process restarted.
final class CheckpointFileChangeTests: XCTestCase {

    private func checkpoint(
        session: UUID, paths: [String], changes: [CheckpointFileChange], at date: Date = Date()
    ) -> Checkpoint {
        Checkpoint(
            trackKey: "main", agentSessionId: session, declaredIntent: "did a thing",
            changedFilePaths: paths, commandsRun: [],
            provenance: AgentProvenance(providerId: "p", modelId: "m", instructionSourceSummary: ""),
            gitCommitSHA: "abc123", fileChanges: changes
        )
    }

    func testLineCountsSurviveAPersistenceRoundTrip() throws {
        let original = checkpoint(
            session: UUID(), paths: ["a.swift"],
            changes: [CheckpointFileChange(path: "a.swift", added: 12, removed: 3)]
        )
        let decoded = try JSONDecoder().decode(Checkpoint.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded.fileChanges, original.fileChanges)
    }

    func testACheckpointWrittenBeforeLineCountsExistedStillDecodes() throws {
        // Tolerant decoding, same contract as every other persisted struct here. Its file list is
        // intact and its counts are simply absent — never zeros pretending to be measurements.
        let json = #"{"trackKey":"main","declaredIntent":"old","changedFilePaths":["a.swift"],"commandsRun":[]}"#
        let decoded = try JSONDecoder().decode(Checkpoint.self, from: Data(json.utf8))
        XCTAssertTrue(decoded.fileChanges.isEmpty)
        XCTAssertEqual(decoded.changedFilePaths, ["a.swift"])
    }

    // MARK: - Counting a diff

    func testTheCounterIgnoresTheFileHeaderLines() {
        // `+++ b/file` and `--- a/file` start with + and -, and counting them inflated every
        // single-file edit by one added and one removed line.
        let diff = """
            --- a/x.swift
            +++ b/x.swift
            @@ -1,2 +1,3 @@
             context
            -gone
            +new
            +also new
            """
        let delta = AgentRunner.lineDelta(in: diff)
        XCTAssertEqual(delta.added, 2)
        XCTAssertEqual(delta.removed, 1)
    }

    func testAnEmptyDiffCountsNothing() {
        let delta = AgentRunner.lineDelta(in: "")
        XCTAssertEqual(delta.added, 0)
        XCTAssertEqual(delta.removed, 0)
    }

    func testContextLinesAreNotCounted() {
        let delta = AgentRunner.lineDelta(in: "@@ -1,3 +1,3 @@\n one\n two\n three")
        XCTAssertEqual(delta.added, 0)
        XCTAssertEqual(delta.removed, 0)
    }

    // MARK: - Accumulating across a conversation

    /// What `AgentRunner.rebuildAppliedEditCounts` has to produce. Expressed against the same data
    /// it reads, since the runner itself needs a provider and a workspace bridge to construct.
    private func accumulate(_ checkpoints: [Checkpoint], session: UUID) -> [(path: String, added: Int, removed: Int)] {
        var counts: [(path: String, added: Int, removed: Int)] = []
        for checkpoint in checkpoints.filter({ $0.agentSessionId == session }).sorted(by: { $0.createdAt < $1.createdAt }) {
            let entries = checkpoint.fileChanges.isEmpty
                ? checkpoint.changedFilePaths.map { CheckpointFileChange(path: $0, added: 0, removed: 0) }
                : checkpoint.fileChanges
            for change in entries {
                if let index = counts.firstIndex(where: { $0.path == change.path }) {
                    counts[index].added += change.added
                    counts[index].removed += change.removed
                } else {
                    counts.append((change.path, change.added, change.removed))
                }
            }
        }
        return counts
    }

    func testTwoCheckpointsTouchingOneFileSumIntoOneRow() {
        let session = UUID()
        let first = checkpoint(session: session, paths: ["a.swift"], changes: [.init(path: "a.swift", added: 4, removed: 1)], at: Date(timeIntervalSince1970: 1))
        let second = checkpoint(session: session, paths: ["a.swift"], changes: [.init(path: "a.swift", added: 6, removed: 2)], at: Date(timeIntervalSince1970: 2))
        let counts = accumulate([first, second], session: session)
        XCTAssertEqual(counts.count, 1)
        XCTAssertEqual(counts.first?.added, 10)
        XCTAssertEqual(counts.first?.removed, 3)
    }

    func testAnotherConversationsCheckpointsAreNotCounted() {
        // The pill says "what *this* conversation changed" — a sibling conversation on the same
        // track has its own.
        let mine = UUID(), theirs = UUID()
        let counts = accumulate([
            checkpoint(session: mine, paths: ["a.swift"], changes: [.init(path: "a.swift", added: 1, removed: 0)]),
            checkpoint(session: theirs, paths: ["b.swift"], changes: [.init(path: "b.swift", added: 99, removed: 0)]),
        ], session: mine)
        XCTAssertEqual(counts.map(\.path), ["a.swift"])
    }

    func testALegacyCheckpointStillContributesItsFileList() {
        let session = UUID()
        let counts = accumulate([checkpoint(session: session, paths: ["old.swift"], changes: [])], session: session)
        XCTAssertEqual(counts.map(\.path), ["old.swift"])
        // No numbers, rather than zeros dressed up as a measurement.
        XCTAssertEqual(counts.first?.added, 0)
    }
}
