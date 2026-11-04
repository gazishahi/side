import XCTest
@testable import Heron
@testable import SideAgents
@testable import Side

@MainActor
final class ThinkTranscriptTests: XCTestCase {
    private var root: URL!
    private var context: ProjectContext!
    private var agent: ACPAgent!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("thinktranscript-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { _ = GitPaths.runGit(args, cwd: root.path) }
        try "hi\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = GitPaths.runGit(["add", "."], cwd: root.path); _ = GitPaths.runGit(["commit", "-q", "-m", "base"], cwd: root.path)
        context = ProjectContextRegistry.shared.acquire(projectRoot: root)
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("chatty-\(UUID().uuidString).py")
        try #"""
import json, sys
def send(m): sys.stdout.write(json.dumps(m) + "\n"); sys.stdout.flush()
def up(u): send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "c", "update": u}})
answer = ("Here's what I found. The **store** keeps a cache keyed by path, and `refresh()` walks it.\n\n"
          "```swift\nfunc refresh() {\n    for (path, entry) in cache where entry.isStale {\n        cache[path] = load(path)\n    }\n}\n```\n\n"
          "- First, the cache is filled on open.\n- Then each save marks an entry stale.\n- Finally refresh reloads it.\n\n") * 2
source = "".join("let value%d = compute(%d)\n" % (i, i) for i in range(40))
turn = 0
for line in sys.stdin:
    m = json.loads(line); meth = m.get("method")
    if meth == "initialize": send({"jsonrpc": "2.0", "id": m["id"], "result": {"protocolVersion": 1}})
    elif meth == "session/new": send({"jsonrpc": "2.0", "id": m["id"], "result": {"sessionId": "c"}})
    elif meth == "session/prompt":
        turn += 1
        for i in range(0, 1600, 16): up({"sessionUpdate": "agent_thought_chunk", "content": {"type": "text", "text": ("Considering the store and its cache. " * 50)[i:i+16]}})
        for k in range(4):
            tid = "t%d-%d" % (turn, k)
            up({"sessionUpdate": "tool_call", "toolCallId": tid, "title": "Read Sources/File%d.swift" % k, "kind": "read", "status": "in_progress", "locations": [{"path": "Sources/File%d.swift" % k}]})
            up({"sessionUpdate": "tool_call_update", "toolCallId": tid, "status": "completed", "content": [{"type": "content", "content": {"type": "text", "text": source}}]})
        for i in range(0, len(answer), 12): up({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": answer[i:i+12]}})
        up({"sessionUpdate": "tool_call", "toolCallId": "e%d" % turn, "title": "Edit Store.swift", "kind": "edit", "status": "completed", "content": [{"type": "diff", "path": "Store.swift", "oldText": source[:4000], "newText": source[:4000].replace("compute", "calculate")}]})
        up({"sessionUpdate": "usage_update", "used": 20000 * turn, "size": 200000})
        send({"jsonrpc": "2.0", "id": m["id"], "result": {"stopReason": "end_turn", "usage": {"inputTokens": 1000, "outputTokens": 400}}})
"""#.write(to: script, atomically: true, encoding: .utf8)
        agent = ACPAgent.addCustom(name: "Brief", command: "brief", arguments: [script.path], apiKeyVariable: nil)
        ACPAgent.defaults.set("/usr/bin/python3", forKey: "SideACPAgentPath.\(agent.id)")
    }

    override func tearDown() async throws {
        guard let context else { return }
        for track in context.trackStore.tracks { context.runnerManager.discardRunner(forTrackKey: track.branchName) }
        ProjectContextRegistry.shared.release(projectRoot: root)
        if let agent { ACPAgent.removeCustom(id: agent.id); ACPAgent.defaults.removeObject(forKey: "SideACPAgentPath.\(agent.id)") }
        try? FileManager.default.removeItem(at: root)
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { autoreleasepool { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) } }
    }

    private func makeTrack() throws -> Track {
        final class Box: @unchecked Sendable { var id: UUID? }
        let box = Box()
        let created = expectation(description: "track")
        context.trackStore.createTrack(intent: "Long conversation") { result in
            if case .success(let (track, _)) = result { box.id = track.id }
            created.fulfill()
        }
        wait(for: [created], timeout: 30)
        return try XCTUnwrap(context.trackStore.tracks.first { $0.id == box.id })
    }


    /// SIDE_RFC_HERON_RETIREMENT.md, step 3: a track on Heron with nothing of Heron's to read
    /// moves to the default agent when Agent opens it; one with a Heron conversation keeps it, to
    /// read, with "Continue on <agent>" where Send was, and carrying on moves it.
    func testHeronIsRetiredReadOnlyAndCarriedOnByTheDefaultAgent() throws {
        DefaultAgent.chosenId = agent.id
        defer { DefaultAgent.chosenId = nil }
        let empty = try makeTrack()
        context.trackStore.setHarness(nil, forTrackKey: empty.branchName)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let think = ThinkWorkspaceViewController()
        window.contentViewController = think
        think.configure(runnerManager: context.runnerManager, trackStore: context.trackStore, projectPath: root.path, trackKey: empty.branchName)
        XCTAssertEqual(context.trackStore.harness(forTrackKey: empty.branchName)?.id, agent.id, "nothing to read: on the default agent")
        XCTAssertFalse(think.isRetiredHeron)
        XCTAssertNil(think.sendReplacementForTesting)

        let kept = try makeTrack()
        context.trackStore.setHarness(nil, forTrackKey: kept.branchName)
        context.sessionStore.appendTurn(AgentTurn(role: .user, content: [.text("What did Heron say?")]), trackKey: kept.branchName, providerId: "p", modelId: "m")
        think.reloadForTrackSwitch(trackKey: kept.branchName)
        XCTAssertNil(context.trackStore.harness(forTrackKey: kept.branchName), "a Heron conversation stays where it is")
        XCTAssertTrue(think.isRetiredHeron)
        XCTAssertEqual(think.sendReplacementForTesting, "Continue on \(agent.displayName)")
        XCTAssertTrue(context.trackStore.hasHeronHistory(kept.branchName))
    }

    /// 2026-09-30 audit, UX-7: a reply finishing, on screen, said nothing to VoiceOver (focus
    /// is in the composer). It says so, with how the reply begins.
    func testAFinishedReplyIsAnnounced() throws {
        let track = try makeTrack()
        context.trackStore.setHarness(agent.id, forTrackKey: track.branchName)
        let think = ThinkWorkspaceViewController()
        think.configure(runnerManager: context.runnerManager, trackStore: context.trackStore, projectPath: root.path, trackKey: track.branchName)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = think
        window.orderFront(nil)
        defer { window.close() }
        Spoken.isEnabled = { true }
        Spoken.lastAnnouncement = nil
        defer { Spoken.isEnabled = { NSWorkspace.shared.isVoiceOverEnabled } }
        let harness = context.runnerManager.runner(forTrackKey: track.branchName)
        harness.send("Where is the cache?")
        waitUntil(30) { harness.phase == .finishedTurn }
        waitUntil(0.3) { false }
        XCTAssertTrue(Spoken.lastAnnouncement?.hasPrefix("Reply finished: Here's what I found.") == true, Spoken.lastAnnouncement ?? "nothing said")
    }

    /// A long conversation keeps views only near the viewport; scrolling back builds them again
    /// as they were (an expanded group stays expanded); a released block still reads to VoiceOver.
    func testOnlyBlocksNearTheViewportHoldViews() throws {
        let track = try makeTrack()
        context.trackStore.setHarness(agent.id, forTrackKey: track.branchName)
        let think = ThinkWorkspaceViewController()
        think.configure(runnerManager: context.runnerManager, trackStore: context.trackStore, projectPath: root.path, trackKey: track.branchName)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = think
        window.orderFront(nil)
        defer { window.close() }
        let harness = context.runnerManager.runner(forTrackKey: track.branchName)
        for turn in 1...25 {
            harness.send("Question \(turn)")
            waitUntil(30) { harness.phase == .finishedTurn }
        }
        waitUntil(0.5) { false }
        let stats = think.transcriptStats
        XCTAssertEqual(stats.blocks, 100, "a message, a group, an answer and an edit card a turn")
        XCTAssertLessThan(stats.realized, 30, "only blocks near the end hold views: \(stats)")

        // To the top: the first question is built again, from the conversation.
        let scroll = think.transcriptScrollView
        scroll.contentView.scroll(to: NSPoint(x: 0, y: -scroll.contentInsets.top))
        scroll.reflectScrolledClipView(scroll.contentView)
        waitUntil(0.5) { false }
        let texts = scroll.documentView?.allText() ?? ""
        XCTAssertTrue(texts.contains("Question 1"), "the first message is on screen again")
        XCTAssertLessThan(think.transcriptStats.realized, 30, "and the end has let go: \(think.transcriptStats)")

        // Open the first group, scroll away and back: it comes back open.
        let group = try XCTUnwrap(scroll.documentView?.firstDescendant(of: WorkGroupView.self))
        group.toggle()
        waitUntil(0.4) { false }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: (scroll.documentView?.frame.height ?? 0)))
        scroll.reflectScrolledClipView(scroll.contentView)
        waitUntil(0.4) { false }
        XCTAssertFalse(scroll.documentView?.allText().contains("Question 1") ?? true, "released while far away")
        XCTAssertTrue(scroll.documentView?.spokenPlaceholders().contains("You: Question 1") ?? false, "and still read by VoiceOver")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: -scroll.contentInsets.top))
        scroll.reflectScrolledClipView(scroll.contentView)
        waitUntil(0.4) { false }
        let rebuilt = try XCTUnwrap(scroll.documentView?.firstDescendant(of: WorkGroupView.self))
        XCTAssertTrue(rebuilt.isExpanded, "the group comes back open")
    }
}

/// An outside agent's commands, run in its own process, as command cards whose output arrives
/// as the agent reports it (SIDE_RFC_LIVE_COMMAND_OUTPUT.md). The fake agent behaves as
/// codex-acp and claude-agent-acp do: output on the tool call only when the client asks for it.
@MainActor
final class LiveCommandOutputTests: XCTestCase {
    private var root: URL!
    private var context: ProjectContext!
    private var agent: ACPAgent!
    private var gate: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("livecommand-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { _ = GitPaths.runGit(args, cwd: root.path) }
        try "hi\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = GitPaths.runGit(["add", "."], cwd: root.path); _ = GitPaths.runGit(["commit", "-q", "-m", "base"], cwd: root.path)
        context = ProjectContextRegistry.shared.acquire(projectRoot: root)
        // The agent holds its first command open until the test has looked at it mid-run.
        gate = root.appendingPathComponent(".gate")
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("commands-\(UUID().uuidString).py")
        try (#"""
import json, os, sys, time
GATE = sys.argv[1]
def send(m): sys.stdout.write(json.dumps(m) + "\n"); sys.stdout.flush()
def up(u): send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "c", "update": u}})
streams = False
for line in sys.stdin:
    m = json.loads(line); meth = m.get("method")
    if meth == "initialize":
        streams = m["params"]["clientCapabilities"].get("_meta", {}).get("terminal_output_delta") is True
        send({"jsonrpc": "2.0", "id": m["id"], "result": {"protocolVersion": 1}})
    elif meth == "session/new": send({"jsonrpc": "2.0", "id": m["id"], "result": {"sessionId": "c"}})
    elif meth == "session/prompt":
        # Codex's shape: an argument list, output streamed, then the exit.
        up({"sessionUpdate": "tool_call", "toolCallId": "x1", "title": "Run count", "kind": "execute", "status": "in_progress",
            "rawInput": {"command": ["bash", "-lc", "for i in 1 2 3; do echo $i; done"]}, "_meta": {"terminal_info": {"terminal_id": "x1"}}})
        if streams:
            up({"sessionUpdate": "tool_call_update", "toolCallId": "x1", "_meta": {"terminal_output_delta": {"terminal_id": "x1", "data": "1\n"}}})
            while not os.path.exists(GATE): time.sleep(0.02)
            for n in ("2\n", "3\n"): up({"sessionUpdate": "tool_call_update", "toolCallId": "x1", "_meta": {"terminal_output_delta": {"terminal_id": "x1", "data": n}}})
            up({"sessionUpdate": "tool_call_update", "toolCallId": "x1", "status": "completed", "_meta": {"terminal_exit": {"terminal_id": "x1", "exit_code": 0, "signal": None}}})
        else:
            up({"sessionUpdate": "tool_call_update", "toolCallId": "x1", "status": "completed", "content": [{"type": "content", "content": {"type": "text", "text": "1"}}]})
        # Claude Code's shape: a string command, its whole output and a failing exit at the end.
        up({"sessionUpdate": "tool_call", "toolCallId": "x2", "title": "`npm test`", "kind": "execute", "status": "pending", "rawInput": {"command": "npm test"}})
        up({"sessionUpdate": "tool_call_update", "toolCallId": "x2", "_meta": {"terminal_output_delta": {"terminal_id": "x2", "data": "\u001b[31m1 failing\u001b[0m\n"}}})
        up({"sessionUpdate": "tool_call_update", "toolCallId": "x2", "status": "failed", "_meta": {"terminal_exit": {"terminal_id": "x2", "exit_code": 1, "signal": None}}})
        up({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "One test fails."}})
        send({"jsonrpc": "2.0", "id": m["id"], "result": {"stopReason": "end_turn"}})
"""#).write(to: script, atomically: true, encoding: .utf8)
        agent = ACPAgent.addCustom(name: "Commands", command: "commands", arguments: [script.path, gate.path], apiKeyVariable: nil)
        ACPAgent.defaults.set("/usr/bin/python3", forKey: "SideACPAgentPath.\(agent.id)")
    }

    override func tearDown() async throws {
        guard let context else { return }
        for track in context.trackStore.tracks { context.runnerManager.discardRunner(forTrackKey: track.branchName) }
        ProjectContextRegistry.shared.release(projectRoot: root)
        if let agent { ACPAgent.removeCustom(id: agent.id); ACPAgent.defaults.removeObject(forKey: "SideACPAgentPath.\(agent.id)") }
        try? FileManager.default.removeItem(at: root)
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { autoreleasepool { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) } }
    }

    private func commands(_ runner: any Harness) -> [AgentCommandPresentation] {
        runner.entries.compactMap { if case .agentCommand(let c) = $0.kind { return c } else { return nil } }
    }

    func testACommandShowsItsOutputAsItRunsAndHowItEnded() throws {
        final class Box: @unchecked Sendable { var id: UUID? }
        let box = Box()
        let created = expectation(description: "track")
        context.trackStore.createTrack(intent: "Run the tests") { result in
            if case .success(let (track, _)) = result { box.id = track.id }
            created.fulfill()
        }
        wait(for: [created], timeout: 30)
        let track = try XCTUnwrap(context.trackStore.tracks.first { $0.id == box.id })
        context.trackStore.setHarness(agent.id, forTrackKey: track.branchName)
        let think = ThinkWorkspaceViewController()
        think.configure(runnerManager: context.runnerManager, trackStore: context.trackStore, projectPath: root.path, trackKey: track.branchName)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = think
        window.orderFront(nil)
        defer { window.close() }
        let harness = context.runnerManager.runner(forTrackKey: track.branchName)
        harness.send("Run the tests")

        // Mid-run: the first line is in, the command still running, and the card says so.
        waitUntil(30) { self.commands(harness).first?.output == "1\n" }
        let running = try XCTUnwrap(commands(harness).first)
        XCTAssertEqual(running.command, "for i in 1 2 3; do echo $i; done", "the shell wrapper is dropped")
        XCTAssertEqual(running.state, .running)
        waitUntil(0.3) { false }
        let card = try XCTUnwrap(think.view.firstDescendant(of: CommandProposalView.self))
        XCTAssertEqual(card.liveOutputForTesting, "1")
        XCTAssertTrue(card.agentStatusForTesting.hasPrefix("Running"), card.agentStatusForTesting)

        try "go".write(to: gate, atomically: true, encoding: .utf8)
        waitUntil(30) { harness.phase == .finishedTurn }
        waitUntil(0.3) { false }
        let ended = commands(harness)
        XCTAssertEqual(ended.count, 2)
        XCTAssertEqual(ended[0].output, "1\n2\n3\n")
        XCTAssertEqual(ended[0].state, .finished(exitCode: 0))
        XCTAssertEqual(ended[1].command, "npm test")
        XCTAssertEqual(ended[1].output, "1 failing\n", "colour escapes stripped")
        XCTAssertEqual(ended[1].state, .failed(exitCode: 1))
        XCTAssertEqual(card.liveOutputForTesting, "1\n2\n3", "the same card, grown")
        XCTAssertEqual(card.agentStatusForTesting, "Ran")
        let cards = think.view.allDescendants(of: CommandProposalView.self)
        XCTAssertEqual(cards.last?.agentStatusForTesting, "Failed · exit 1")
        if let directory = ProcessInfo.processInfo.environment["SIDE_PREVIEW_SNAPSHOT"] {
            window.setContentSize(NSSize(width: 760, height: 560))
            let content = try XCTUnwrap(window.contentView)
            content.layoutSubtreeIfNeeded()
            waitUntil(0.5) { false }
            let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds), "\(content.bounds)")
            content.cacheDisplay(in: content.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("agent-commands.png"))
        }

        // Reopened from Side's record: the finished cards, as they ended.
        context.runnerManager.discardRunner(forTrackKey: track.branchName)
        let reopened = context.runnerManager.runner(forTrackKey: track.branchName)
        XCTAssertEqual(commands(reopened).map(\.state), [.finished(exitCode: 0), .failed(exitCode: 1)])
        XCTAssertEqual(commands(reopened).first?.output, "1\n2\n3\n")
    }
}

private extension NSView {
    func firstDescendant<T: NSView>(of type: T.Type) -> T? {
        for view in subviews {
            if let match = view as? T { return match }
            if let match = view.firstDescendant(of: type) { return match }
        }
        return nil
    }
    func allDescendants<T: NSView>(of type: T.Type) -> [T] {
        subviews.flatMap { view -> [T] in ((view as? T).map { [$0] } ?? []) + view.allDescendants(of: type) }
    }
    /// Every piece of text shown under this view.
    func allText() -> String {
        var parts: [String] = []
        if let field = self as? NSTextField { parts.append(field.stringValue) }
        if let text = self as? NSTextView { parts.append(text.string) }
        return (parts + subviews.map { $0.allText() }).joined(separator: "\n")
    }
    /// What released slots say to VoiceOver in place of their views.
    func spokenPlaceholders() -> String {
        let own = subviews.isEmpty && isAccessibilityElement() ? [accessibilityLabel() ?? ""] : []
        return (own + subviews.map { $0.spokenPlaceholders() }).joined(separator: "\n")
    }
}
