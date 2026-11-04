import XCTest
@testable import Side
@testable import SideAgents

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


    /// Run's status line reads the shell's own marks: C starts, D;code;nonce finishes, a mark
    /// split across reads is joined, and a D without this terminal's nonce is output, not status.
    func testCommandMarksForTheStatusLine() {
        let p = TerminalViewController.markPrefix, t = "\u{07}"
        let cases: [([String], String?, [TerminalViewController.CommandMark])] = [
            (["\(p)C\(t)out\(p)D;0;N\(t)"], "N", [.started, .finished(exitCode: 0)]),
            (["\(p)C\(t)x\(p)D;", "2;N\(t)"], "N", [.started, .finished(exitCode: 2)]),
            (["\(p)D;0;FORGED\(t)"], "N", []),
            (["\(p)D;1\(t)"], nil, [.finished(exitCode: 1)]),
        ]
        for (chunks, nonce, expected) in cases {
            var carry = "", marks: [TerminalViewController.CommandMark] = []
            for chunk in chunks {
                let scan = TerminalViewController.scanCommandMarks(carry: carry, chunk: chunk, nonce: nonce)
                carry = scan.carry
                marks += scan.marks
            }
            XCTAssertEqual(marks, expected, chunks.joined())
        }
        XCTAssertEqual(TerminalViewController.pathFromOSC7("file://mac.local/Users/me/My%20App"), "/Users/me/My App")
        XCTAssertTrue(TerminalSessionManager.isInside("/work/app/src", root: "/work/app"))
        XCTAssertFalse(TerminalSessionManager.isInside("/work/app2", root: "/work/app"))
    }

    /// ⌘K sends a pointer, never content (§5.3 acceptance): the message names `@path#Lx-Ly`
    /// and none of the lines themselves; the mention resolver reads the range back.
    func testInlineInstructSendsAPointerNotContent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("instruct-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        let body = "export function save(){\n  // lock first\n  return true\n}\n"
        try body.write(to: root.appendingPathComponent("src/save.ts"), atomically: true, encoding: .utf8)
        let request = InlineInstruct.Request(verb: .change, instruction: "take the lock", url: root.appendingPathComponent("src/save.ts"),
                                             relativePath: "src/save.ts", lines: 2...3, diagnostic: nil)
        let message = InlineInstruct.message(for: request)
        XCTAssertTrue(message.contains("@src/save.ts#L2-L3"), message)
        XCTAssertFalse(message.contains("lock first") || message.contains("return true"), "file content leaked: \(message)")

        let resolved = FileMentionResolver.resolve(text: message, projectRoot: root)
        XCTAssertEqual(resolved.mentions.first?.relativePath, "src/save.ts")
        XCTAssertEqual(resolved.mentions.first?.lines, 2...3)
        XCTAssertTrue(resolved.unresolved.isEmpty)
        XCTAssertEqual(FileMention.pointer(relativePath: "a.swift", lines: 7...7), "@a.swift#L7")
    }

    /// The first-run sheet shows only on a true first run — no recent projects and no agent
    /// installed — and never again once dismissed (§6 acceptance).
    func testFirstRunShowsOnceAndOnlyOnAFirstRun() {
        let cases: [(dismissed: Bool, recents: Bool, agent: Bool, shows: Bool)] = [
            (false, false, false, true),
            (true, false, false, false),
            (false, true, false, false),
            (false, false, true, false),
        ]
        for c in cases {
            XCTAssertEqual(FirstRun.shouldPresent(dismissed: c.dismissed, hasRecentProjects: c.recents, agentReady: c.agent), c.shows, "\(c)")
        }
    }

    /// Step 2 of the harness RFC: an ACP agent streams into the same transcript Heron fills —
    /// text, tool lines with their results folded in, a permission card whose answer goes back —
    /// and a missing agent fails with its install line, not silence.
    func testAnACPAgentStreamsAsksAndFinishes() throws {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: python.path), "needs python3 for the mock agent")
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("mock-acp-\(UUID().uuidString).py")
        try Self.mockAgent.write(to: script, atomically: true, encoding: .utf8)
        let agent = ACPAgent(id: "mock", displayName: "Mock", binary: "mock", installHint: "install mock")
        let harness = ACPHarness(trackKey: "t", agent: agent,
                                 launchProvider: { ACPLaunch(executable: python, arguments: [script.path], environment: ProcessInfo.processInfo.environment) },
                                 rootProvider: { FileManager.default.temporaryDirectory })
        defer { harness.teardown() }

        let asked = expectation(description: "permission asked")
        let finished = expectation(description: "turn finished")
        // Every event during the wait re-reports the same phase.
        asked.assertForOverFulfill = false
        finished.assertForOverFulfill = false
        harness.addObserver { _ in
            if harness.phase == .awaitingApproval { asked.fulfill() }
            if harness.phase == .finishedTurn { finished.fulfill() }
        }
        harness.send("go")
        wait(for: [asked], timeout: 15)
        guard let card = harness.entries.first(where: { if case .permissionRequest = $0.kind { return true }; return false }) else { return XCTFail("no card") }
        harness.answerPermission(proposalId: card.id, optionId: "yes")
        wait(for: [finished], timeout: 15)

        let texts = harness.entries.compactMap { entry -> String? in
            switch entry.kind {
            case .assistantText(let text): return text
            case .toolCall(let name, let summary): return name + summary
            case .permissionRequest(let p): return "asked:" + (p.chosenOptionName ?? "")
            default: return nil
            }
        }
        XCTAssertEqual(texts, ["Looking.", "Read README.md · ✓ # Fixture", "Edit NOTES.md · ✓ Changed NOTES.md", "asked:Allow", "Done."])
        XCTAssertEqual(harness.contextUsage().usedTokens, 1000)

        // Not installed: a failure that says how to install, and the track shows it failed.
        let missing = ACPHarness(trackKey: "t", agent: agent, launchProvider: { nil }, rootProvider: { FileManager.default.temporaryDirectory })
        let failed = expectation(description: "failed")
        failed.assertForOverFulfill = false
        missing.addObserver { _ in if missing.phase == .blocked(.failed) { failed.fulfill() } }
        missing.send("go")
        wait(for: [failed], timeout: 10)
        guard case .failure(let message)? = missing.entries.last?.kind else { return XCTFail("no failure") }
        XCTAssertTrue(message.contains("install mock"), message)
    }

    private static let mockAgent = #"""
import json, sys
def send(m): sys.stdout.write(json.dumps(m) + "\n"); sys.stdout.flush()
def up(s, u): send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": s, "update": u}})
prompt_id = None
for line in sys.stdin:
    m = json.loads(line); meth = m.get("method"); p = m.get("params", {})
    if meth == "initialize": send({"jsonrpc": "2.0", "id": m["id"], "result": {"protocolVersion": 1}})
    elif meth == "session/new": send({"jsonrpc": "2.0", "id": m["id"], "result": {"sessionId": "s"}})
    elif meth == "session/prompt":
        prompt_id = m["id"]
        up("s", {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "Look"}})
        up("s", {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "ing."}})
        up("s", {"sessionUpdate": "tool_call", "toolCallId": "a", "title": "Read README.md", "kind": "read", "status": "in_progress", "locations": [{"path": "README.md"}]})
        up("s", {"sessionUpdate": "tool_call_update", "toolCallId": "a", "status": "completed", "content": [{"type": "content", "content": {"type": "text", "text": "# Fixture\nmore"}}]})
        up("s", {"sessionUpdate": "tool_call", "toolCallId": "b", "title": "Edit NOTES.md", "kind": "edit", "status": "pending"})
        send({"jsonrpc": "2.0", "id": 77, "method": "session/request_permission", "params": {"sessionId": "s", "toolCall": {"toolCallId": "b", "title": "Edit NOTES.md"}, "options": [{"optionId": "yes", "name": "Allow", "kind": "allow_once"}, {"optionId": "no", "name": "Reject", "kind": "reject_once"}]}})
    elif meth is None and m.get("id") == 77:
        up("s", {"sessionUpdate": "tool_call_update", "toolCallId": "b", "status": "completed", "content": [{"type": "diff", "path": "NOTES.md", "oldText": "a", "newText": "b"}]})
        up("s", {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "Done."}})
        up("s", {"sessionUpdate": "usage_update", "used": 1000, "size": 100000})
        send({"jsonrpc": "2.0", "id": prompt_id, "result": {"stopReason": "end_turn"}})
"""#
}

