import XCTest
@testable import SideAgents
@testable import Side

/// Think with a long, realistic conversation: memory and CPU, with the transcript on screen and
/// without. A fake ACP agent streams each turn as real ones do: thinking and text in small
/// chunks, file reads with large outputs, an edit. Opt-in (`SIDE_BUDGETS=1`, optimized).
@MainActor
final class ThinkBudgetTests: XCTestCase {
    private var root: URL!
    private var context: ProjectContext!
    private var agent: ACPAgent!

    override func setUp() async throws {
        try Budgets.skipUnlessEnabled()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("thinkbudget-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { _ = GitPaths.runGit(args, cwd: root.path) }
        try "hi\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = GitPaths.runGit(["add", "."], cwd: root.path); _ = GitPaths.runGit(["commit", "-q", "-m", "base"], cwd: root.path)
        context = ProjectContextRegistry.shared.acquire(projectRoot: root)
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("chatty-\(UUID().uuidString).py")
        try #"""
import json, os, sys, time
# CHATTY_PACE: seconds between updates, a real agent's pace (0: as fast as it can).
pace = float(os.environ.get("CHATTY_PACE", "0"))
def send(m): sys.stdout.write(json.dumps(m) + "\n"); sys.stdout.flush()
def up(u):
    if pace: time.sleep(pace)
    send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "c", "update": u}})
answer = ("Here's what I found. The **store** keeps a cache keyed by path, and `refresh()` walks it.\n\n"
          "```swift\nfunc refresh() {\n    for (path, entry) in cache where entry.isStale {\n        cache[path] = load(path)\n    }\n}\n```\n\n"
          "- First, the cache is filled on open.\n- Then each save marks an entry stale.\n- Finally refresh reloads it.\n\n") * 6
source = "".join("let value%d = compute(%d) // a line of the file being read\n" % (i, i) for i in range(700))
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
        agent = ACPAgent.addCustom(name: "Chatty", command: "chatty", arguments: [script.path], apiKeyVariable: nil)
        ACPAgent.defaults.set("/usr/bin/python3", forKey: "SideACPAgentPath.\(agent.id)")
    }

    override func tearDown() async throws {
        guard let context else { return }
        for track in context.trackStore.tracks { context.runnerManager.discardRunner(forTrackKey: track.branchName) }
        ProjectContextRegistry.shared.release(projectRoot: root)
        if let agent { ACPAgent.removeCustom(id: agent.id); ACPAgent.defaults.removeObject(forKey: "SideACPAgentPath.\(agent.id)") }
        try? FileManager.default.removeItem(at: root)
    }

    private func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    /// CPU seconds this process has used, all threads.
    private func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }

    /// Each turn of the run loop in its own autorelease pool, as the app's event loop does: a
    /// bare `RunLoop.run` never drains, and what the transcript autoreleases then piles up in
    /// the test's pool (it read as a hundred megabytes of Think that the app never holds).
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

    /// Per run (on screen or not): growth over the turns, and CPU as a share of a core.
    private var measured: [Bool: (growthMB: Double, cpuPercent: Double)] = [:]

    private func run(turns: Int, onScreen: Bool, scrollAfter: Bool = true) throws -> [String] {
        let track = try makeTrack()
        context.trackStore.setHarness(agent.id, forTrackKey: track.branchName)
        var window: NSWindow?
        var think: ThinkWorkspaceViewController?
        weak var released: ThinkWorkspaceViewController?
        if onScreen { autoreleasepool {
            let vc = ThinkWorkspaceViewController()
            vc.configure(runnerManager: context.runnerManager, trackStore: context.trackStore, projectPath: root.path, trackKey: track.branchName)
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.contentViewController = vc
            w.orderFront(nil)
            window = w; think = vc; released = vc
        } }
        let harness = context.runnerManager.runner(forTrackKey: track.branchName)
        // What setting up left behind (the repository, the track's worktree) settles first,
        // so the baseline is the conversation's.
        waitUntil(1) { false }
        malloc_zone_pressure_relief(nil, 0)
        let before = footprintMB()
        var lines: [String] = []
        let cpuStart = cpuSeconds(), wallStart = CACurrentMediaTime()
        for turn in 1...turns {
            let started = CACurrentMediaTime()
            // In a pool of its own, as a key press is in the app.
            autoreleasepool { harness.send("Tell me about the store, turn \(turn)") }
            waitUntil(60) { harness.phase == .finishedTurn || harness.phase == .idle && CACurrentMediaTime() - started > 0.5 }
            if turn % 20 == 0 {
                lines.append(String(format: "%@ turn %d: +%.0f MB, %d entries, last turn %.0f ms", onScreen ? "on screen" : "off screen", turn, footprintMB() - before, harness.entries.count, (CACurrentMediaTime() - started) * 1000))
            }
        }
        let cpu = cpuSeconds() - cpuStart, wall = CACurrentMediaTime() - wallStart
        measured[onScreen] = (footprintMB() - before, cpu / wall * 100)
        lines.append(String(format: "%@: %.1f CPU s over %.1f s (%.0f%% of a core)", onScreen ? "on screen" : "off screen", cpu, wall, cpu / wall * 100))
        if onScreen, scrollAfter, let vc = think {
            let scroll = vc.transcriptScrollView
            lines.append("on screen: blocks \(vc.transcriptStats)")
            // Through the whole conversation, top to bottom, a screen at a time.
            let clip = scroll.contentView
            let height = scroll.documentView?.frame.height ?? 0
            var peak = footprintMB()
            var y: CGFloat = 0
            clip.scroll(to: .zero); scroll.reflectScrolledClipView(clip)
            var steps = 0
            while y < height, steps < 400 {
                steps += 1
                y += clip.bounds.height
                clip.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(clip)
                waitUntil(0.03) { false }
                peak = max(peak, footprintMB())
            }
            lines.append(String(format: "on screen: scrolled %.0f pt top to bottom, peak +%.0f MB", height, peak - before))
            lines.append("on screen: after scrolling, blocks \(vc.transcriptStats)")
            // Leaving the track and coming back: the whole history rebuilt.
            let start = CACurrentMediaTime()
            autoreleasepool {
                vc.configure(runnerManager: context.runnerManager, trackStore: context.trackStore, projectPath: root.path, trackKey: track.branchName)
                vc.view.layoutSubtreeIfNeeded()
            }
            lines.append(String(format: "on screen: reattached to %d entries in %.0f ms", harness.entries.count, (CACurrentMediaTime() - start) * 1000))
        }
        autoreleasepool {
            if let window {
                window.contentViewController = nil
                window.close()
            }
            think = nil
            window = nil
        }
        for _ in 0..<20 { autoreleasepool { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) } }
        if onScreen { lines.append("on screen: the Think view " + (released == nil ? "was freed" : "is still alive (leaked)")) }
        if onScreen, let alive = released, ProcessInfo.processInfo.environment["SIDE_TRACE_LEAK"] == "1" {
            print("TRACE address \(String(format: "0x%lx", unsafeBitCast(alive, to: Int.self))) pid \(getpid())")
            fflush(stdout)
            waitUntil(40) { false }
        }
        lines.append(String(format: "%@: +%.0f MB after the view is gone", onScreen ? "on screen" : "off screen", footprintMB() - before))
        malloc_zone_pressure_relief(nil, 0)
        lines.append(String(format: "%@: +%.0f MB after malloc gives free pages back", onScreen ? "on screen" : "off screen", footprintMB() - before))
        if onScreen, ProcessInfo.processInfo.environment["SIDE_HEAP_WAIT"] == "1" {
            print("HEAPWAIT pid \(getpid())"); fflush(stdout)
            waitUntil(150) { false }
        }
        return lines
    }

    /// Memory: 200 turns streamed as fast as the agent can, without the view and with it; the
    /// view's cost is the difference. CPU: ten turns at a real agent's pace, on screen.
    func testALongConversation() throws {
        let turns = Int(ProcessInfo.processInfo.environment["SIDE_THINK_TURNS"] ?? "200") ?? 200
        let off = try run(turns: turns, onScreen: false)
        let on = try run(turns: turns, onScreen: true)
        for line in off + on { print("THINK " + line) }
        let offGrowth = measured[false]?.growthMB ?? 0, onGrowth = measured[true]?.growthMB ?? 0
        // Without the view the growth is the conversation's data, a few MB; it reads below zero
        // when memory an earlier suite let go is given back meanwhile, so it counts from zero.
        Budgets.check("think.memory", max(0, onGrowth - max(0, offGrowth)),
                      detail: String(format: "%d turns: +%.0f MB with the view, +%.0f MB without (the conversation's own data)", turns, onGrowth, offGrowth))
        // CPU while streaming is measured in the app itself (AppBudgetTests): in a test process
        // the waiting loop's own turns count as the view's.
    }
}

private extension NSView {
    func descendants<T: NSView>(of type: T.Type) -> [T] {
        subviews.flatMap { ($0 as? T).map { [$0] } ?? [] } + subviews.flatMap { $0.descendants(of: type) }
    }
}
