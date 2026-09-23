import XCTest
@testable import Side
@testable import Heron

@MainActor
final class AgentModeTests: XCTestCase {

    // MARK: - Tool scope is enforced by what the model is shown

    func testEachScopeIsOfferedExactlyTheToolsItAllows() {
        // The enforcement point: a model that never receives a tool can't propose it, so the
        // scope holds even if the model argues with the prompt. Reading is what Ask and Plan are
        // *for*; edits and shell commands are Build-only; run_task and the sibling-track tools are
        // withheld only in Ask, where the conversation is about this track alone.
        let table: [(tool: String, ask: Bool, plan: Bool, build: Bool)] = [
            ("read_file", true, true, true),
            ("search_files", true, true, true),
            ("list_files", true, true, true),
            ("edit_file", false, false, true),
            ("write_file", false, false, true),
            ("run_shell_command", false, false, true),
            ("run_task", false, true, true),
            ("list_tracks", false, true, true),
            ("read_track_overlap", false, true, true),
        ]
        let offered = Dictionary(uniqueKeysWithValues: AgentToolScope.allCases.map { scope in
            (scope, Set(ToolExecutor.specs(for: scope).map(\.name)))
        })
        for row in table {
            let expectations: [(AgentToolScope, Bool)] = [(.ask, row.ask), (.plan, row.plan), (.build, row.build)]
            for (scope, shouldOffer) in expectations {
                XCTAssertEqual(
                    offered[scope]?.contains(row.tool), shouldOffer,
                    "\(scope) \(shouldOffer ? "should offer" : "must not offer") \(row.tool)"
                )
            }
        }
    }

    func testBuildExposesEveryTool() {
        XCTAssertEqual(
            Set(ToolExecutor.specs(for: .build).map(\.name)),
            Set(ToolExecutor.specs.map(\.name)),
            "Build is the pre-modes behavior and must not quietly lose a tool"
        )
    }

    func testReadOnlyScopesExplainThemselvesToTheModel() {
        // Without this the agent retries a tool that isn't there and reports a confusing failure
        // instead of saying "switch this track to Build."
        XCTAssertNotNil(AgentToolScope.ask.systemPromptAddendum)
        XCTAssertNotNil(AgentToolScope.plan.systemPromptAddendum)
        XCTAssertNil(AgentToolScope.build.systemPromptAddendum, "Build shouldn't pay for prompt it doesn't need")
    }

    // MARK: - Autonomy

    func testAutonomyLevelsFormTheExpectedMatrix() {
        // Guarded is exactly what `autoRunCommands == true` meant, which is what it migrates to;
        // Full is the one level that steps past "agents propose; people promote."
        let table: [(autonomy: AgentAutonomy, runsCommands: Bool, appliesEdits: Bool)] = [
            (.manual, false, false),
            (.guarded, true, false),
            (.full, true, true),
        ]
        for row in table {
            XCTAssertEqual(row.autonomy.autoRunsAllowlistedCommands, row.runsCommands, "\(row.autonomy) autoRunsAllowlistedCommands")
            XCTAssertEqual(row.autonomy.autoAppliesEdits, row.appliesEdits, "\(row.autonomy) autoAppliesEdits")
        }
    }

    func testAutonomyIsInertInAReadOnlyScope() {
        // Nothing to auto-approve without write/command tools — reported so the UI can disable
        // the axis instead of implying Full does something in Ask.
        XCTAssertFalse(AgentMode(scope: .ask, autonomy: .full).autonomyIsMeaningful)
        XCTAssertFalse(AgentMode(scope: .plan, autonomy: .guarded).autonomyIsMeaningful)
        XCTAssertTrue(AgentMode(scope: .build, autonomy: .manual).autonomyIsMeaningful)
    }

    // MARK: - Migration from the old bool

    func testATrackWrittenBeforeModesAndModelSelectionStillLoadsAndResolves() throws {
        // The old bool said nothing about tool scope, and silently narrowing an existing track to
        // read-only would break it — so `autoRunCommands: true` resolves to Build/guarded, nothing
        // is invented on disk at decode time, and the model fields the track never had stay nil.
        XCTAssertEqual(AgentMode.migrating(autoRunCommands: true), AgentMode(scope: .build, autonomy: .guarded))
        XCTAssertEqual(AgentMode.migrating(autoRunCommands: false), AgentMode(scope: .build, autonomy: .manual))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let legacy = """
        {"id":"\(UUID().uuidString)","intent":"old","branchName":"legacy","status":"active",
         "createdAt":"2026-01-01T00:00:00Z","lastActiveAt":"2026-01-02T00:00:00Z","autoRunCommands":true}
        """
        let track = try decoder.decode(Track.self, from: Data(legacy.utf8))
        XCTAssertEqual(track.branchName, "legacy")
        XCTAssertNil(track.autonomy, "nothing should be invented on disk at decode time")
        XCTAssertNil(track.modelId)
        XCTAssertNil(track.effort)
        // …but the derived mode has to honor what the user had set.
        XCTAssertEqual(track.mode, AgentMode(scope: .build, autonomy: .guarded))
    }

    func testDefaultModeIsTheSafeOne() {
        XCTAssertEqual(AgentMode.default.autonomy, .manual)
        XCTAssertEqual(AgentMode.default.scope, .build)
    }

    // MARK: - Persistence

    func testModeIsPerTrackAndSurvivesReload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mode-\(UUID().uuidString)")
        let stateDirectory = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        JSONStore.write(
            [Track(intent: "a", branchName: "reader"), Track(intent: "b", branchName: "builder")],
            to: stateDirectory.appendingPathComponent("tracks.json")
        )
        let store = TrackStore(projectRoot: root, stateDirectory: stateDirectory)

        store.setMode(AgentMode(scope: .ask, autonomy: .manual), forTrackKey: "reader")
        store.setMode(AgentMode(scope: .build, autonomy: .full), forTrackKey: "builder")

        let reloaded = TrackStore(projectRoot: root, stateDirectory: stateDirectory)
        XCTAssertEqual(reloaded.mode(forTrackKey: "reader"), AgentMode(scope: .ask, autonomy: .manual))
        XCTAssertEqual(reloaded.mode(forTrackKey: "builder"), AgentMode(scope: .build, autonomy: .full))
    }

    func testWritingAModeKeepsTheLegacyBoolConsistent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mode-\(UUID().uuidString)")
        let stateDirectory = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        JSONStore.write([Track(intent: "a", branchName: "main")], to: stateDirectory.appendingPathComponent("tracks.json"))
        let store = TrackStore(projectRoot: root, stateDirectory: stateDirectory)

        store.setMode(AgentMode(scope: .build, autonomy: .guarded), forTrackKey: "main")
        // The two representations must not disagree about the same track — anything still
        // reading the bool would otherwise see auto-run off while the mode says on.
        XCTAssertEqual(store.tracks.first?.autoRunCommands, true)

        store.setMode(AgentMode(scope: .build, autonomy: .manual), forTrackKey: "main")
        XCTAssertEqual(store.tracks.first?.autoRunCommands, false)
    }
}
