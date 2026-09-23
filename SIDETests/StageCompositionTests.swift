import XCTest
@testable import Side

/// Direction 02 §4: what each stage says, as tables.
@MainActor
final class StageCompositionTests: XCTestCase {
    /// Tracks' trailing action is the specific verb — never a stage name that goes elsewhere
    /// (audit A-3). Activity outranks lifecycle: a parked track whose run failed says Retry.
    func testTrackRowVerbs() {
        let cases: [(TrackStatus, AgentActivity, TrackRowVerb)] = [
            (.waiting, .needsYou, .respond),
            (.active, .failed, .retry),
            (.parked, .failed, .retry),
            (.active, .doneUnread, .review),
            (.reviewReady, .none, .review),
            (.active, .working, .open),
            (.waiting, .doneSeen, .open),
            (.parked, .none, .resume),
            (.completed, .none, .resume),
            (.archived, .none, .resume),
        ]
        for (status, activity, expected) in cases {
            XCTAssertEqual(TrackRowVerb.primary(status: status, activity: activity), expected, "\(status) / \(activity)")
        }
    }

    /// Review's decision header states verification recency relative to the newest checkpoint,
    /// for all four cases (§4.2 acceptance).
    func testReviewVerificationLine() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func checkpoint(_ minutesAgo: Double, _ exit: Int?? = nil) -> Checkpoint {
            var c = Checkpoint(trackKey: "t", agentSessionId: UUID(), declaredIntent: "", changedFilePaths: [], commandsRun: [],
                               provenance: AgentProvenance(providerId: "", modelId: "", instructionSourceSummary: ""), gitCommitSHA: nil)
            c = Self.dated(c, now.addingTimeInterval(-minutesAgo * 60))
            if let exit { c.verification = CheckpointVerification(taskName: "swift test", command: "swift test", exitCode: exit, output: "", ranAt: now.addingTimeInterval(-minutesAgo * 60 + 30)) }
            return c
        }
        let cases: [([Checkpoint], DS.StatusState?, String?)] = [
            ([], nil, nil),
            ([checkpoint(10), checkpoint(20)], .idle, "Unverified"),
            ([checkpoint(4, 0), checkpoint(20)], .verified, "Verified · swift test passed"),
            ([checkpoint(2), checkpoint(3), checkpoint(9, 0)], .idle, "Verified 2 checkpoints ago · 2 unverified since"),
            ([checkpoint(12, 1), checkpoint(30, 0)], .failed, "Failed · swift test exit 1"),
        ]
        for (checkpoints, state, prefix) in cases {
            let summary = ReviewWorkspaceViewController.verificationSummary(checkpoints: checkpoints, now: now)
            XCTAssertEqual(summary?.state, state)
            if let prefix { XCTAssertTrue(summary?.text.hasPrefix(prefix) == true, summary?.text ?? "nil") } else { XCTAssertNil(summary) }
        }
    }

    /// `Checkpoint.createdAt` is set at init; tests need it in the past.
    private static func dated(_ checkpoint: Checkpoint, _ date: Date) -> Checkpoint {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var object = try! JSONSerialization.jsonObject(with: encoder.encode(checkpoint)) as! [String: Any]
        object["createdAt"] = ISO8601DateFormatter().string(from: date)
        return try! decoder.decode(Checkpoint.self, from: JSONSerialization.data(withJSONObject: object))
    }

    /// Run's task chips go through the existing command-approval path (§4.3 acceptance): a click
    /// produces a ProposedCommand card, Manual autonomy waits for Run / Cancel, only one task
    /// holds the terminal at a time, and approving types it into the track's terminal.
    @MainActor
    func testATaskChipProposesACommandThroughTheApprovalPath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tasks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var typed: [String] = []
        var bridge = WorkspaceBridge.none
        bridge.runShellCommand = { command, _, completion in typed.append(command); completion("ok\n[exit code: 0]") }
        let runner = AgentRunner(trackKey: "t", sessionStore: AgentSessionStore(stateDirectory: root), projectPath: root.path,
                                 bridgeProvider: { bridge }, rootProvider: { root })

        let id = try XCTUnwrap(runner.proposeUserTask(ProjectTask(name: "test", command: "swift test")))
        guard case .commandProposal(let card)? = runner.entries.last?.kind else { return XCTFail("no command card") }
        XCTAssertEqual(card.command.command, "swift test")
        XCTAssertEqual(card.command.taskName, "test")
        XCTAssertEqual(runner.pendingUserTaskProposalId, id, "Manual autonomy asks first")
        XCTAssertNil(runner.proposeUserTask(ProjectTask(name: "build", command: "swift build")), "one task at a time")
        XCTAssertTrue(typed.isEmpty)

        runner.resolve(proposalId: id, decision: .apply)
        XCTAssertEqual(typed, ["swift test"])
        XCTAssertNil(runner.pendingUserTaskProposalId)
        XCTAssertNil(runner.runningUserTaskName)
        guard case .commandProposal(let done)? = runner.entries.first(where: { $0.id == id })?.kind, case .executed? = done.resolution else {
            return XCTFail("card not resolved")
        }
    }
}

