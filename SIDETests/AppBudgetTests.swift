import XCTest
@testable import Side

/// Side as a whole: a second copy of the app launched on a generated project and driven through
/// its UI-testing commands (`side.uitesting.command`), measured from outside as Activity Monitor
/// would. Limits in `Budgets.table`.
@MainActor
final class AppBudgetTests: XCTestCase {
    private var root: URL!
    private var app: Process?

    override func setUpWithError() throws {
        try Budgets.skipUnlessEnabled()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("appbudget-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app?.waitUntilExit()
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    /// 300 Swift files in modules, a long Markdown document, a git repository with one commit.
    private func makeProject() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Packages/Alloy/Sources/AlloyAppKit/AlloyEditorView.swift"), encoding: .utf8)
        for f in 0..<300 {
            let folder = root.appendingPathComponent("Sources/Module\(f / 30)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try source.replacingOccurrences(of: "AlloyEditorView", with: "View\(f)").write(to: folder.appendingPathComponent("File\(f).swift"), atomically: true, encoding: .utf8)
        }
        var markdown = "# Roadmap\n\n"
        for section in 0..<120 {
            markdown += "## Section \(section)\n\nA paragraph about **section \(section)**, with `inline code` and a [link](https://example.com).\n\n"
            markdown += "- One item\n- Another item, a little longer than the first\n- A third\n\n"
            markdown += "```swift\nfunc section\(section)() -> Int {\n    return \(section)\n}\n```\n\n"
            markdown += "| Column | Value |\n| --- | --- |\n| a | \(section) |\n| b | \(section * 2) |\n\n"
        }
        try markdown.write(to: root.appendingPathComponent("ROADMAP.md"), atomically: true, encoding: .utf8)
        for args in [["init", "-q", "-b", "main"], ["-c", "user.email=t@t", "-c", "user.name=T", "add", "-A"], ["-c", "user.email=t@t", "-c", "user.name=T", "commit", "-qm", "base"]] {
            Budgets.run("/usr/bin/git", ["-C", root.path] + args)
        }
    }

    private func post(_ command: String) {
        DistributedNotificationCenter.default().postNotificationName(Notification.Name("side.uitesting.command"), object: command, userInfo: nil, deliverImmediately: true)
    }

    /// Waits while sampling the app's footprint; returns the highest seen.
    private func sample(_ seconds: TimeInterval, pid: pid_t) -> Double {
        var peak = 0.0
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            peak = max(peak, Budgets.footprintMB(pid: pid))
            Budgets.settle(0.2)
        }
        return peak
    }

    /// `SIDE_APP_SHOTS=1`: the moments worth a picture, announced for a script to capture (a
    /// test can't capture the screen itself), with a pause while it does.
    private func shot(_ name: String) {
        guard ProcessInfo.processInfo.environment["SIDE_APP_SHOTS"] == "1", let pid = app?.processIdentifier else { return }
        print("APPSHOT \(name) \(pid)")
        fflush(stdout)
        Budgets.settle(3)
    }

    /// Launches a second Side on the project, the given arguments added.
    private func launch(_ extra: [String] = []) throws -> pid_t {
        let process = Process()
        process.executableURL = Bundle.main.executableURL
        process.arguments = ["-SideUITesting", "YES", "-SideUITestingProject", root.path, "-ApplePersistenceIgnoreState", "YES"] + extra
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        app = process
        Budgets.settle(8)
        XCTAssertTrue(process.isRunning, "Side launched")
        return process.processIdentifier
    }

    /// Think streaming in the app, from a fake agent at a real agent's pace: thinking, four
    /// file reads, a long answer in small chunks, an update every 4 ms.
    func testStreamingInThink() throws {
        try makeProject()
        let script = root.appendingPathComponent("agent.py")
        try #"""
import json, sys, time
def send(m): sys.stdout.write(json.dumps(m) + "\n"); sys.stdout.flush()
def up(u):
    time.sleep(0.004)
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
        send({"jsonrpc": "2.0", "id": m["id"], "result": {"stopReason": "end_turn"}})
"""#.write(to: script, atomically: true, encoding: .utf8)
        let agents: [[String: Any]] = [["id": "custom-fake", "displayName": "Fake", "binary": "python3", "arguments": [script.path],
                                        "installHint": "", "apiKeyVariables": [String](), "subscriptionName": "", "isCustom": true]]
        let hex = try JSONSerialization.data(withJSONObject: agents).map { String(format: "%02x", $0) }.joined()
        let pid = try launch(["-SideACPCustomAgents", "<\(hex)>", "-SideACPAgentPath.custom-fake", "/usr/bin/python3"])
        post("think-track custom-fake")
        Budgets.settle(4)
        // Messages sent one after another, so the agent streams the whole time it's measured.
        post("think-send Tell me about the store")
        Budgets.settle(1)
        var sent = 1
        let measuring = DispatchQueue(label: "measure")
        var activity: (cpuPercent: Double, wakeupsPerSecond: Double, meanWakeups: Double) = (0, 0, 0)
        let done = expectation(description: "measured")
        measuring.async {
            activity = Budgets.activity(pid: pid, seconds: 20)
            done.fulfill()
        }
        let deadline = Date().addingTimeInterval(21)
        while Date() < deadline {
            Budgets.settle(5.5)
            if sent < 4 { post("think-send And the next part, \(sent)"); sent += 1 }
            if sent == 2 { print("APPSHOT think-streaming \(pid)"); fflush(stdout) }
        }
        wait(for: [done], timeout: 30)
        shot("think")
        Budgets.check("think.cpu", activity.cpuPercent, detail: "20 s of streaming in Side, the transcript on screen; Heron, the view and drawing together")
    }

    func testIdleAndMovingThroughTheStages() throws {
        try makeProject()
        let pid = try launch()

        // Three files open, then left alone in the background (this test's app is in front).
        for f in [0, 150, 299] { post("open \(root.path)/Sources/Module\(f / 30)/File\(f).swift"); Budgets.settle(1) }
        // Past the first minute's one-time work (indexing, the language server starting).
        Budgets.settle(20)
        let idle = Budgets.footprintMB(pid: pid)
        let activity = Budgets.activity(pid: pid, seconds: 20)
        Budgets.check("app.idle.memory", idle, detail: "three 1,000-line Swift files open, 300 files indexed")
        Budgets.check("app.idle.cpu", activity.cpuPercent, detail: "average over 20 s")
        Budgets.check("app.idle.wakeups", activity.wakeupsPerSecond, detail: String(format: "over 20 s; %.1f a second on average", activity.meanWakeups))

        // The Markdown preview scrolled through, every stage twice, back to Make.
        var peak = 0.0
        post("open \(root.path)/ROADMAP.md"); peak = max(peak, sample(1.5, pid: pid))
        post("toggle-preview"); peak = max(peak, sample(1.5, pid: pid))
        post("scroll 40"); peak = max(peak, sample(6, pid: pid))
        for _ in 0..<2 {
            for stage in ["think", "review", "run", "make"] { post("stage \(stage)"); peak = max(peak, sample(1.5, pid: pid)) }
        }
        post("toggle-preview")
        peak = max(peak, sample(2, pid: pid))
        // Then to the background (this test's app in front), as the idle budget is measured: in
        // front, the caret's blink keeps the graphics driver's memory (about 90 MB) warm on
        // purpose, so a key never waits for it.
        NSApp.activate(ignoringOtherApps: true)
        Budgets.settle(40)
        let settled = Budgets.footprintMB(pid: pid)
        let categories = Budgets.run("/usr/bin/footprint", ["\(pid)"]).split(separator: "\n").dropFirst(5).prefix(6)
            .map { $0.split(separator: " ").filter { !$0.isEmpty } }.compactMap { f in f.count > 5 ? "\(f[0]) \(f[1]) \(f[5...].joined(separator: " "))" : nil }
        shot("stages")
        Budgets.check("app.stages.peak", peak, detail: "sampled every 0.2 s; idle was \(Int(idle)) MB")
        Budgets.check("app.stages.settled", settled, detail: "in the background, 40 s after the last switch; " + categories.joined(separator: ", "))
        XCTAssertTrue(app?.isRunning ?? false, "Side is still running")
    }
}
