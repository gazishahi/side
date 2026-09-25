import XCTest
@testable import Heron
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
        UserDefaults.standard.set("/usr/bin/python3", forKey: "SideACPAgentPath.\(agent.id)")
    }

    override func tearDown() async throws {
        guard let context else { return }
        for track in context.trackStore.tracks { context.runnerManager.discardRunner(forTrackKey: track.branchName) }
        ProjectContextRegistry.shared.release(projectRoot: root)
        if let agent { ACPAgent.removeCustom(id: agent.id); UserDefaults.standard.removeObject(forKey: "SideACPAgentPath.\(agent.id)") }
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

private extension NSView {
    func firstDescendant<T: NSView>(of type: T.Type) -> T? {
        for view in subviews {
            if let match = view as? T { return match }
            if let match = view.firstDescendant(of: type) { return match }
        }
        return nil
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
