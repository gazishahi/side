import XCTest
@testable import Side

/// RFC R4: two read-only tools, same project only. Structure, not conversation.
final class TrackContextToolsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tracks-tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func git(_ args: [String]) { XCTAssertTrue(GitPaths.runGit(args, cwd: root.path).success, args.joined(separator: " ")) }
        git(["init", "-q", "-b", "main"]); git(["config", "user.email", "t@t"]); git(["config", "user.name", "T"])
        try "shared\n".write(to: root.appendingPathComponent("shared.swift"), atomically: true, encoding: .utf8)
        try "only\n".write(to: root.appendingPathComponent("only-a.swift"), atomically: true, encoding: .utf8)
        git(["add", "."]); git(["commit", "-q", "-m", "base"])
        // Track A changes shared + only-a; track B changes shared; track C changes nothing shared.
        git(["checkout", "-q", "-b", "track-a"])
        try "shared A\n".write(to: root.appendingPathComponent("shared.swift"), atomically: true, encoding: .utf8)
        try "only A\n".write(to: root.appendingPathComponent("only-a.swift"), atomically: true, encoding: .utf8)
        git(["commit", "-q", "-am", "a"])
        git(["checkout", "-q", "main"]); git(["checkout", "-q", "-b", "track-b"])
        try "shared B\n".write(to: root.appendingPathComponent("shared.swift"), atomically: true, encoding: .utf8)
        git(["commit", "-q", "-am", "b"])
        git(["checkout", "-q", "main"]); git(["checkout", "-q", "-b", "track-c"])
        try "c\n".write(to: root.appendingPathComponent("c.swift"), atomically: true, encoding: .utf8)
        git(["add", "."]); git(["commit", "-q", "-m", "c"])
        git(["checkout", "-q", "main"])
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func summary(_ branch: String, intent: String, current: Bool = false) -> AgentTrackSummary {
        AgentTrackSummary(branchName: branch, intent: intent, status: "active", baseRef: "main", isCurrent: current, gitDirectory: root.path)
    }

    private func executor(current: String) -> ToolExecutor {
        var executor = ToolExecutor(projectRoot: root, liveBufferProvider: { _ in nil })
        executor.trackContextProvider = { [
            self.summary("track-a", intent: "Refactor shared", current: current == "track-a"),
            self.summary("track-b", intent: "Fix the bug in shared", current: current == "track-b"),
            self.summary("track-c", intent: "Add C", current: current == "track-c"),
        ] }
        return executor
    }

    func testOverlapNamesTheSiblingAndTheSharedFileOnly() {
        guard case .completed(let output, let isError) = executor(current: "track-a").execute(name: "read_track_overlap", input: .object([:]), toolUseId: "t", scope: .build) else { return XCTFail() }
        XCTAssertFalse(isError)
        XCTAssertTrue(output.contains("Fix the bug in shared (track-b) also changed:"), output)
        XCTAssertTrue(output.contains("  shared.swift"), output)
        XCTAssertFalse(output.contains("only-a.swift"), "a file only this track changed is not an overlap")
        XCTAssertFalse(output.contains("track-c"), "a track with no shared files is not reported")
    }

    func testNoOverlapSaysSoInsteadOfReturningNothing() {
        guard case .completed(let output, _) = executor(current: "track-c").execute(name: "read_track_overlap", input: .object([:]), toolUseId: "t", scope: .build) else { return XCTFail() }
        XCTAssertTrue(output.contains("No other track"), output)
    }

    func testListingMarksTheCurrentTrackAndCountsChangedFiles() {
        guard case .completed(let output, _) = executor(current: "track-b").execute(name: "list_tracks", input: .object([:]), toolUseId: "t", scope: .plan) else { return XCTFail() }
        let lines = output.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].contains("track-a [active] — Refactor shared · base main · 2 changed files"), lines[0])
        XCTAssertTrue(lines[1].contains("1 changed file  ← this track"), lines[1])
    }

    func testTheToolsAreOfferedInPlanAndBuildButNotAsk() {
        let names: (AgentToolScope) -> Set<String> = { Set(ToolExecutor.specs(for: $0).map(\.name)) }
        XCTAssertTrue(names(.build).isSuperset(of: ["list_tracks", "read_track_overlap"]))
        XCTAssertTrue(names(.plan).isSuperset(of: ["list_tracks", "read_track_overlap"]))
        XCTAssertTrue(names(.ask).isDisjoint(with: ["list_tracks", "read_track_overlap"]))
    }

    func testWithoutAProjectThereAreNoTracks() {
        let executor = ToolExecutor(projectRoot: root, liveBufferProvider: { _ in nil })
        guard case .completed(let output, _) = executor.execute(name: "list_tracks", input: .object([:]), toolUseId: "t", scope: .build) else { return XCTFail() }
        XCTAssertEqual(output, "This project has no tracks.")
    }
}
