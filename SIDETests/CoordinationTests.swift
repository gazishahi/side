import XCTest
@testable import Side
@testable import SideAgents

/// Multi-agent RFC step 2: a coordinator track creates subtracks on any agent, messages them,
/// waits for them and reads their results, under M1–M4 and the R3 ceiling.
@MainActor
final class CoordinationTests: XCTestCase {
    private var root: URL!
    private var context: ProjectContext!
    private var worker: ACPAgent!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("coord-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { _ = GitPaths.runGit(args, cwd: root.path) }
        try "hi\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = GitPaths.runGit(["add", "."], cwd: root.path); _ = GitPaths.runGit(["commit", "-q", "-m", "base"], cwd: root.path)
        context = ProjectContextRegistry.shared.acquire(projectRoot: root)

        // A worker agent: answers every prompt with "done:" and its first line.
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("worker-\(UUID().uuidString).py")
        try #"""
import json, sys, os
def send(m): sys.stdout.write(json.dumps(m) + "\n"); sys.stdout.flush()
cwd = "."
for line in sys.stdin:
    m = json.loads(line); meth = m.get("method"); p = m.get("params", {})
    if meth == "initialize": send({"jsonrpc": "2.0", "id": m["id"], "result": {"protocolVersion": 1}})
    elif meth == "session/new":
        cwd = p.get("cwd", ".")
        # What Side handed over, beside the working copy so no checkpoint takes it.
        open(cwd.rstrip("/") + ".mcp-seen.json", "w").write(json.dumps(p.get("mcpServers", [])))
        send({"jsonrpc": "2.0", "id": m["id"], "result": {"sessionId": "w"}})
    elif meth == "session/prompt":
        text = p["prompt"][0]["text"]
        last = text.splitlines()[-1]
        if last.startswith("write "):
            # A direct write, like an agent with its own file tools; the turn's checkpoint takes it.
            open(os.path.join(cwd, last[6:]), "w").write("from the worker\n")
            send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "w", "update": {"sessionUpdate": "tool_call", "toolCallId": "w1", "title": "Write", "kind": "edit", "status": "completed", "locations": [{"path": os.path.join(cwd, last[6:])}]}}})
        send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "w", "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "done: " + last}}}})
        send({"jsonrpc": "2.0", "id": m["id"], "result": {"stopReason": "end_turn", "usage": {"inputTokens": 100, "outputTokens": 20, "cachedReadTokens": 5}}})
"""#.write(to: script, atomically: true, encoding: .utf8)
        worker = ACPAgent.addCustom(name: "Worker", command: "worker", arguments: [script.path], apiKeyVariable: nil)
        ACPAgent.defaults.set("/usr/bin/python3", forKey: "SideACPAgentPath.\(worker.id)")
    }

    override func tearDown() async throws {
        for track in context.trackStore.tracks {
            context.runnerManager.discardRunner(forTrackKey: track.branchName)
            if let path = track.workingDirectoryPath { _ = GitPaths.runGit(["worktree", "remove", "--force", path], cwd: root.path) }
        }
        ProjectContextRegistry.shared.release(projectRoot: root)
        ACPAgent.removeCustom(id: worker.id)
        ACPAgent.defaults.removeObject(forKey: "SideACPAgentPath.\(worker.id)")
        try? FileManager.default.removeItem(at: root)
    }

    private func createTrack(_ intent: String, parent: Track? = nil, spawned: Bool = false) throws -> Track {
        let done = expectation(description: intent)
        let box = TrackBox()
        context.trackStore.createTrack(intent: intent, baseTrack: parent, spawnedByCoordinator: spawned) { result in
            if case .success(let (track, _)) = result { box.id = track.id }
            done.fulfill()
        }
        wait(for: [done], timeout: 30)
        return try XCTUnwrap(context.trackStore.tracks.first { $0.id == box.id })
    }

    private func createTrackAsync(_ intent: String) async throws -> Track {
        let done = expectation(description: intent)
        let box = TrackBox()
        context.trackStore.createTrack(intent: intent) { result in
            if case .success(let (track, _)) = result { box.id = track.id }
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 30)
        return try XCTUnwrap(context.trackStore.tracks.first { $0.id == box.id })
    }

    private func offMain(_ body: @escaping @Sendable () -> String) -> String {
        let done = expectation(description: "off main")
        let box = ResultBox()
        DispatchQueue.global().async { box.value = body(); done.fulfill() }
        wait(for: [done], timeout: 90)
        return box.value
    }

    func testACoordinatorHandsWorkToASubtrackOnAnotherAgentAndReadsItBack() throws {
        let coordinatorTrack = try createTrack("Ship the thing")
        let coordinator = context.coordinator
        XCTAssertTrue(coordinator.canCoordinate(trackKey: coordinatorTrack.branchName))
        let bridge = CoordinationBridge(parentKey: coordinatorTrack.branchName, coordinator: coordinator)

        let input: JSONValue = .object(["intent": .string("Write the docs"), "agent": .string(worker.id), "instructions": .string("Document a.txt")])
        guard case .success(let request) = bridge.request(from: input) else { return XCTFail("not a request") }
        XCTAssertEqual(request.agentId, worker.id)

        // Approved: the subtrack is created, stacked, on the worker, and started.
        let created = expectation(description: "created")
        var report = ""
        coordinator.createSubtrack(parentKey: coordinatorTrack.branchName, request: request) { report = $0; created.fulfill() }
        wait(for: [created], timeout: 30)
        XCTAssertTrue(report.contains("Created subtrack"), report)
        let child = try XCTUnwrap(context.trackStore.tracks.first { $0.spawnedByCoordinator })
        XCTAssertEqual(child.parentTrackId, coordinatorTrack.id)
        XCTAssertEqual(child.harnessId, worker.id)
        XCTAssertEqual(context.trackStore.tracks.first { $0.id == coordinatorTrack.id }?.status, .active, "creating a subtrack doesn't switch the coordinator away")
        XCTAssertFalse(coordinator.canCoordinate(trackKey: child.branchName), "one level deep")

        // Waiting and reading happen off the main thread, as the executor and MCP server do.
        let childKey = child.branchName
        let waited = offMain { bridge.wait(tracks: [childKey], timeout: 60) }
        XCTAssertTrue(waited.contains("finished its turn"), waited)
        XCTAssertTrue(waited.contains("done: Document a.txt"), waited)

        // A follow-up reaches it, marked as the coordinator's.
        XCTAssertTrue(bridge.message(track: childKey, text: "Also mention the date").contains("started"))
        let second = offMain { bridge.wait(tracks: [childKey], timeout: 60) }
        XCTAssertTrue(second.contains("done: Also mention the date"), second)
        let childTurns = context.runnerManager.existingRunner(forTrackKey: childKey)?.entries.compactMap { entry -> String? in
            if case .userText(let text) = entry.kind { return text } else { return nil }
        } ?? []
        XCTAssertTrue(childTurns.allSatisfy { $0.hasPrefix("From the coordinator") }, "\(childTurns)")

        // M4: only its own subtracks.
        XCTAssertTrue(bridge.message(track: coordinatorTrack.branchName, text: "x").contains("isn't one of this track's subtracks"))
    }

    /// Opt-in live: Claude Code coordinates. It creates a subtrack on another agent through Side's
    /// MCP tools, waits for it, and reports the subtrack's reply.
    func testLiveClaudeCodeCoordinatesAnotherAgent() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SIDE_LIVE_ACP"] == "1", "live agent test is opt-in")
        let coordinatorTrack = try createTrack("Coordinate live")
        context.trackStore.setHarness("claude-code", forTrackKey: coordinatorTrack.branchName)
        context.trackStore.setMode(AgentMode(scope: .build, autonomy: .full), forTrackKey: coordinatorTrack.branchName)
        let harness = context.runnerManager.runner(forTrackKey: coordinatorTrack.branchName)
        XCTAssertEqual(harness.harnessName, "Claude Code")
        let done = expectation(description: "answered")
        done.assertForOverFulfill = false
        harness.addObserver { _ in
            for entry in harness.entries {
                if case .permissionRequest(let p) = entry.kind, p.chosenOptionName == nil,
                   let allow = p.options.first(where: { $0.kind == .allowOnce || $0.kind == .allowAlways }) {
                    DispatchQueue.main.async { harness.answerPermission(proposalId: entry.id, optionId: allow.id) }
                }
            }
            if harness.phase == .finishedTurn || harness.phase == .blocked(.failed) || harness.phase == .blocked(.stalled) { done.fulfill() }
        }
        harness.send("""
        Use the "side" MCP server's create_subtrack tool: intent "Say the word", agent "\(worker.id)", instructions "Say: pelican". \
        Then call its wait_for_tracks tool on that subtrack, and reply with only the subtrack's last reply.
        """)
        wait(for: [done], timeout: 240)
        let answer = harness.entries.compactMap { if case .assistantText(let t) = $0.kind { return t } else { return nil } }.joined()
        XCTAssertTrue(answer.contains("done: Say: pelican"), "\(answer)\n\(harness.entries.map(\.kind))")
        let child = context.trackStore.tracks.first { $0.spawnedByCoordinator }
        XCTAssertEqual(child?.harnessId, worker.id)
        XCTAssertEqual(child?.parentTrackId, coordinatorTrack.id)
    }

    /// Library step 2, live: Claude Code starts the user's stdio MCP server and calls its tool.
    func testLiveClaudeCodeUsesTheUsersMCPServer() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SIDE_LIVE_ACP"] == "1", "live agent test is opt-in")
        let saved = MCPServerStore.defaults
        MCPServerStore.defaults = throwawayDefaults()
        defer { MCPServerStore.defaults = saved }
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-\(UUID().uuidString).py")
        try #"""
import json, os, sys
def send(m): sys.stdout.write(json.dumps(m) + "\n"); sys.stdout.flush()
for line in sys.stdin:
    m = json.loads(line); meth = m.get("method")
    if meth == "initialize": send({"jsonrpc": "2.0", "id": m["id"], "result": {"protocolVersion": m["params"]["protocolVersion"], "capabilities": {"tools": {}}, "serverInfo": {"name": "vault", "version": "1"}}})
    elif meth == "tools/list": send({"jsonrpc": "2.0", "id": m["id"], "result": {"tools": [{"name": "secret_word", "description": "Returns the secret word.", "inputSchema": {"type": "object", "properties": {}}}]}})
    elif meth == "tools/call": send({"jsonrpc": "2.0", "id": m["id"], "result": {"content": [{"type": "text", "text": os.environ.get("VAULT_WORD", "missing")}]}})
    elif "id" in m: send({"jsonrpc": "2.0", "id": m["id"], "result": {}})
"""#.write(to: script, atomically: true, encoding: .utf8)
        let server = MCPServerStore.save(MCPServerStore.newServer(name: "vault", command: "/usr/bin/python3", arguments: [script.path]), environment: ["VAULT_WORD": "heliotrope"])
        defer { MCPServerStore.remove(id: server.id) }
        MCPServerStore.setEnabled(true, id: server.id, projectPath: root.path)

        let track = try createTrack("Use the vault")
        context.trackStore.setHarness("claude-code", forTrackKey: track.branchName)
        context.trackStore.setMode(AgentMode(scope: .build, autonomy: .full), forTrackKey: track.branchName)
        let harness = context.runnerManager.runner(forTrackKey: track.branchName)
        let done = expectation(description: "answered")
        done.assertForOverFulfill = false
        harness.addObserver { _ in
            for entry in harness.entries {
                if case .permissionRequest(let p) = entry.kind, p.chosenOptionName == nil,
                   let allow = p.options.first(where: { $0.kind == .allowOnce || $0.kind == .allowAlways }) {
                    DispatchQueue.main.async { harness.answerPermission(proposalId: entry.id, optionId: allow.id) }
                }
            }
            if harness.phase == .finishedTurn || harness.phase == .blocked(.failed) || harness.phase == .blocked(.stalled) { done.fulfill() }
        }
        harness.send("Call the \"vault\" MCP server's secret_word tool and reply with only the word it returns.")
        wait(for: [done], timeout: 240)
        let answer = harness.entries.compactMap { if case .assistantText(let t) = $0.kind { return t } else { return nil } }.joined()
        XCTAssertTrue(answer.lowercased().contains("heliotrope"), "\(answer)\n\(harness.entries.map(\.kind))")
    }

    /// Step 3: a subtrack's work comes back by promotion into its coordinator (M2), its tokens
    /// count toward the coordinator's, and the UI lists it.
    func testASubtracksWorkIsPromotedIntoItsCoordinator() throws {
        let coordinatorTrack = try createTrack("Coordinate and promote")
        let coordinator = context.coordinator
        let bridge = CoordinationBridge(parentKey: coordinatorTrack.branchName, coordinator: coordinator)
        let created = expectation(description: "created")
        coordinator.createSubtrack(parentKey: coordinatorTrack.branchName,
                                   request: SubtrackRequest(intent: "Add notes", agentId: worker.id, instructions: "write notes.txt")) { _ in created.fulfill() }
        wait(for: [created], timeout: 30)
        let child = try XCTUnwrap(context.trackStore.tracks.first { $0.spawnedByCoordinator })
        let childKey = child.branchName
        _ = offMain { bridge.wait(tracks: [childKey], timeout: 60) }
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, context.sessionStore.checkpoints(forTrackKey: childKey).isEmpty { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        XCTAssertEqual(context.sessionStore.checkpoints(forTrackKey: childKey).first?.changedFilePaths, ["notes.txt"], "the worker's write became a checkpoint on its own branch")

        // The strip and rollup see it; its tokens are filed under the subtrack.
        XCTAssertEqual(coordinator.subtracks(of: coordinatorTrack.branchName).map(\.branchName), [childKey])
        XCTAssertEqual(UsageStore.shared.totals(projectPath: root.path, trackKey: childKey).totalTokens, 125)

        // M2: unverified, so the user decides even on Full.
        guard case .success(let unverified) = offMainCheck(bridge, childKey) else { return XCTFail("check failed") }
        XCTAssertFalse(unverified.fullMayApply)
        XCTAssertTrue(unverified.note.contains("hasn't passed verification"), unverified.note)

        // Verified and sharing nothing: Full may promote without a card.
        _ = context.sessionStore.attachVerification(CheckpointVerification(taskName: "test", command: "t", exitCode: 0, output: ""), toLatestCheckpointFor: childKey)
        guard case .success(let verified) = offMainCheck(bridge, childKey) else { return XCTFail("check failed") }
        XCTAssertTrue(verified.fullMayApply, verified.note)

        // A sibling that also changed notes.txt: back to the user.
        let sibling = try createTrack("Also notes", parent: context.trackStore.tracks.first { $0.id == coordinatorTrack.id }, spawned: true)
        let siblingPath = try XCTUnwrap(sibling.workingDirectoryPath)
        try "sibling\n".write(toFile: siblingPath + "/notes.txt", atomically: true, encoding: .utf8)
        _ = GitPaths.runGit(["add", "notes.txt"], cwd: siblingPath); _ = GitPaths.runGit(["commit", "-q", "-m", "sibling"], cwd: siblingPath)
        guard case .success(let overlapping) = offMainCheck(bridge, childKey) else { return XCTFail("check failed") }
        XCTAssertFalse(overlapping.fullMayApply)
        XCTAssertTrue(overlapping.note.contains("shares files with another subtrack"), overlapping.note)

        // Promoted: the file is in the coordinator's working copy, and the subtrack is done.
        let promoted = expectation(description: "promoted")
        var report = ""
        coordinator.promote(parentKey: coordinatorTrack.branchName, trackKey: childKey) { report = $0; promoted.fulfill() }
        wait(for: [promoted], timeout: 30)
        XCTAssertTrue(report.hasPrefix("Promoted"), report)
        let parentPath = try XCTUnwrap(context.trackStore.tracks.first { $0.id == coordinatorTrack.id }?.workingDirectoryPath)
        XCTAssertEqual(try String(contentsOfFile: parentPath + "/notes.txt", encoding: .utf8), "from the worker\n")
        XCTAssertEqual(context.trackStore.tracks.first { $0.branchName == childKey }?.status, .completed)
        XCTAssertEqual(coordinator.stateText(of: childKey).text, "promoted")
    }

    private func offMainCheck(_ bridge: CoordinationBridge, _ track: String) -> Result<(facts: PromotionFacts, fullMayApply: Bool, note: String), CoordinationError> {
        let done = expectation(description: "check")
        let box = CheckBox()
        DispatchQueue.global().async { box.value = bridge.promotionCheck(track: track); done.fulfill() }
        wait(for: [done], timeout: 30)
        return box.value ?? .failure(CoordinationError(message: "no answer"))
    }

    /// Library step 2: the user's MCP servers switched on for this project reach an outside
    /// agent's session, environment and all; one that's off doesn't.
    func testTheUsersMCPServersReachOutsideAgents() throws {
        let saved = MCPServerStore.defaults
        MCPServerStore.defaults = throwawayDefaults()
        defer { MCPServerStore.defaults = saved }
        let on = MCPServerStore.save(MCPServerStore.newServer(name: "notes", command: "python3", arguments: ["-m", "notes server"]), environment: ["NOTES_TOKEN": "t0ken"])
        let off = MCPServerStore.save(MCPServerStore.newServer(name: "side", command: "/bin/echo", arguments: []), environment: nil)
        defer { MCPServerStore.remove(id: on.id); MCPServerStore.remove(id: off.id) }
        XCTAssertEqual(off.name, "side-2", "Side's own server keeps its name")
        MCPServerStore.setEnabled(true, id: on.id, projectPath: root.path)

        let coordinatorTrack = try createTrack("Use my tools")
        let created = expectation(description: "created")
        context.coordinator.createSubtrack(parentKey: coordinatorTrack.branchName,
                                           request: SubtrackRequest(intent: "Look", agentId: worker.id, instructions: "look")) { _ in created.fulfill() }
        wait(for: [created], timeout: 30)
        let child = try XCTUnwrap(context.trackStore.tracks.first { $0.spawnedByCoordinator })
        let seenURL = URL(fileURLWithPath: try XCTUnwrap(child.workingDirectoryPath) + ".mcp-seen.json")
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, !FileManager.default.fileExists(atPath: seenURL.path) { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        let servers = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: seenURL)) as? [[String: Any]])
        defer { try? FileManager.default.removeItem(at: seenURL) }
        XCTAssertEqual(servers.count, 1, "\(servers)")
        let notes = try XCTUnwrap(servers.first)
        XCTAssertEqual(notes["name"] as? String, "notes")
        XCTAssertTrue((notes["command"] as? String)?.hasPrefix("/") == true, "a bare command is resolved to a path")
        XCTAssertEqual(notes["args"] as? [String], ["-m", "notes server"])
        XCTAssertEqual((notes["env"] as? [[String: String]])?.first, ["name": "NOTES_TOKEN", "value": "t0ken"])
    }

    func testCapsAndDepthAreRefused() throws {
        let parent = try createTrack("Coordinate")
        for index in 1...4 { _ = try createTrack("Part \(index)", parent: parent, spawned: true) }
        let refusal = try XCTUnwrap(context.coordinator.spawnRefusal(parentKey: parent.branchName))
        XCTAssertTrue(refusal.contains("already has 4 subtracks"), refusal)
        let child = try XCTUnwrap(context.trackStore.tracks.first { $0.spawnedByCoordinator })
        XCTAssertTrue(context.coordinator.spawnRefusal(parentKey: child.branchName)?.contains("can't create subtracks of its own") == true)
    }

    /// The same tools over MCP, for an outside coordinator; a declined spawn creates nothing.
    func testOutsideCoordinatorsGetTheToolsOverMCP() async throws {
        let parent = try await createTrackAsync("Coordinate over MCP")
        let bridge = CoordinationBridge(parentKey: parent.branchName, coordinator: context.coordinator)
        let server = SideToolServer()
        let registration = try XCTUnwrap(server.register(.init(
            trackKey: parent.branchName, tracks: { [] }, coordination: bridge, agentChoices: context.coordinator.agentChoices,
            authorize: { _, _, _, decided in decided(false) })))
        func post(_ body: [String: Any]) async throws -> [String: Any] {
            var request = URLRequest(url: registration.url)
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, _) = try await URLSession.shared.data(for: request)
            return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        }
        let list = try await post(["jsonrpc": "2.0", "id": 1, "method": "tools/list"])
        let names = ((list["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        XCTAssertEqual(Set(names), ["list_tracks", "read_track_overlap", "create_subtrack", "message_track", "read_track", "promote_subtrack", "wait_for_tracks"])
        let call = try await post(["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "create_subtrack", "arguments": ["intent": "No", "agent": worker.id, "instructions": "x"]]])
        let text = (((call["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertTrue(text.contains("declined"), text)
        XCTAssertFalse(context.trackStore.tracks.contains { $0.spawnedByCoordinator })
    }

    /// SIDE_RFC_HERON_RETIREMENT.md, step 1: new tracks, subtracks and the base take the default
    /// agent; nothing chosen (and tests never detect one), Heron.
    func testNewTracksSubtracksAndTheBaseTakeTheDefaultAgent() throws {
        XCTAssertNil(DefaultAgent.chosenId, "a test's settings start empty")
        let before = try createTrack("Before a default")
        XCTAssertEqual(before.harnessId, Track.heronId)
        XCTAssertNil(context.trackStore.harness(forTrackKey: before.branchName), "Heron")

        DefaultAgent.chosenId = worker.id
        defer { DefaultAgent.chosenId = nil }
        let track = try createTrack("With a default")
        XCTAssertEqual(track.harnessId, worker.id)
        XCTAssertEqual(context.trackStore.harness(forTrackKey: track.branchName)?.id, worker.id)
        XCTAssertEqual(context.trackStore.harness(forTrackKey: before.branchName)?.id, nil, "a track already on Heron stays there")
        XCTAssertEqual(context.coordinator.agentChoices.first?.id, worker.id, "offered first, as the default")
        let child = try createTrack("A subtrack", parent: track, spawned: true)
        XCTAssertEqual(child.harnessId, worker.id)

        // The base, with no Heron conversations: the default, until a choice of its own.
        XCTAssertEqual(context.trackStore.harness(forTrackKey: "")?.id, worker.id)
        context.trackStore.setHarness(nil, forTrackKey: "")
        XCTAssertNil(context.trackStore.harness(forTrackKey: ""), "Heron, chosen for the base")
        context.trackStore.setHarness(worker.id, forTrackKey: "")
        XCTAssertEqual(context.trackStore.harness(forTrackKey: "")?.id, worker.id)
    }

    /// A track stored before there was a default agent has no agent id: it was Heron's, and stays.
    func testATrackStoredBeforeTheDefaultStaysOnHeron() throws {
        let old = Track(intent: "Old", branchName: "old")
        XCTAssertNil(old.harnessId)
        let decoded = try JSONDecoder().decode(Track.self, from: JSONEncoder().encode(old))
        XCTAssertEqual(decoded.harnessId, Track.heronId)
        XCTAssertTrue(decoded.runsOnHeron)
    }
}

private final class ResultBox: @unchecked Sendable { var value = "" }
private final class TrackBox: @unchecked Sendable { var id: UUID? }
private final class CheckBox: @unchecked Sendable { var value: Result<(facts: PromotionFacts, fullMayApply: Bool, note: String), CoordinationError>? }
