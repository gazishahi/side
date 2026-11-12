import XCTest
@testable import Side

/// Sessions, phase 2 (SIDE_RFC_SESSIONS.md): what Claude Code's hooks say, and the hooks
/// themselves in its settings. Never the developer's real `~/.claude`: every test has its own.
@MainActor
final class AgentHooksTests: XCTestCase {
    private var folder: URL!
    private var savedConfig: URL!
    private var savedHome: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("hooks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        savedConfig = ClaudeHooks.configDirectory
        savedHome = HookPaths.home
        ClaudeHooks.configDirectory = folder.appendingPathComponent("claude", isDirectory: true)
        HookPaths.home = folder.appendingPathComponent("side", isDirectory: true)
    }

    override func tearDownWithError() throws {
        ClaudeHooks.configDirectory = savedConfig
        HookPaths.home = savedHome
        try? FileManager.default.removeItem(at: folder)
    }

    private func event(_ name: String, _ fields: [String: Any] = [:], session: String = "s1", at: TimeInterval = 1) -> HookEvent {
        var body: [String: Any] = ["hook_event_name": name, "session_id": session, "cwd": "/work/app"]
        body.merge(fields) { $1 }
        let data = try! JSONSerialization.data(withJSONObject: ["side": ["agent": "claude", "ppid": 0, "at": at], "event": body])
        return HookEvent.parse(data)!
    }

    func testATurnGoesFromWorkingToNeedsYouToDone() {
        var sessions = HookSessions()
        sessions.apply(event("SessionStart", ["source": "startup"]), agentPID: 42)
        XCTAssertEqual(sessions.sessions["s1"]?.state, .idle)
        sessions.apply(event("UserPromptSubmit", ["prompt": "Fix the login bug\nand add a test"]), agentPID: 42)
        XCTAssertEqual(sessions.sessions["s1"]?.state, .working(progress: nil))
        XCTAssertEqual(sessions.sessions["s1"]?.request, "Fix the login bug")
        sessions.apply(event("PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "swift test --parallel"]]), agentPID: 42)
        XCTAssertEqual(sessions.sessions["s1"]?.state, .needsYou(.permission))
        XCTAssertEqual(sessions.sessions["s1"]?.message, "Wants to run swift test --parallel")
        // Answered: the tool ran, and it's at work again.
        sessions.apply(event("PostToolUse", ["tool_name": "Bash"]), agentPID: 42)
        XCTAssertEqual(sessions.sessions["s1"]?.state, .working(progress: nil))
        XCTAssertEqual(sessions.sessions["s1"]?.message, "")
        sessions.apply(event("Stop"), agentPID: 42)
        XCTAssertEqual(sessions.sessions["s1"]?.state, .done)
        // A tool event sent in the background, landing after the Stop, doesn't undo it.
        sessions.apply(event("PostToolUse", ["tool_name": "Edit"]), agentPID: 42)
        XCTAssertEqual(sessions.sessions["s1"]?.state, .done)
        XCTAssertEqual(sessions.sessions["s1"]?.pid, 42)
    }

    func testQuestionsFailuresMovesAndTheEnd() {
        var sessions = HookSessions()
        sessions.apply(event("UserPromptSubmit", ["prompt": "Ship it"]), agentPID: 7)
        sessions.apply(event("Notification", ["notification_type": "elicitation_dialog", "message": "Which branch?"]), agentPID: 7)
        XCTAssertEqual(sessions.sessions["s1"]?.state, .needsYou(.question))
        XCTAssertEqual(sessions.sessions["s1"]?.message, "Which branch?")
        sessions.apply(event("StopFailure", ["error": "rate_limit"]), agentPID: 7)
        XCTAssertEqual(sessions.sessions["s1"]?.state, .failed)
        XCTAssertEqual(sessions.sessions["s1"]?.message, "Hit a rate limit")
        sessions.apply(event("CwdChanged", ["old_cwd": "/work/app", "new_cwd": "/work/app/.claude/worktrees/fix"]), agentPID: 7)
        XCTAssertEqual(sessions.sessions["s1"]?.cwd, "/work/app/.claude/worktrees/fix")
        sessions.apply(event("SubagentStart", ["agent_id": "a", "agent_type": "Explore"]), agentPID: 7)
        XCTAssertEqual(sessions.sessions["s1"]?.subagents, 1)
        sessions.apply(event("SessionEnd", ["reason": "prompt_input_exit"]), agentPID: 7)
        sessions.prune(isAlive: { _ in true })
        XCTAssertNil(sessions.sessions["s1"], "an ended session is let go")
    }

    func testWhatIsntAnEventIsSkipped() {
        XCTAssertNil(HookEvent.parse(Data("{\"side\":{},\"event\":}".utf8)), "an empty event, as the hook writes for no input")
        XCTAssertNil(HookEvent.parse(Data("{\"side\":{},\"event\":{\"hook_event_name\":\"Stop\"}}".utf8)), "no session")
        XCTAssertNil(HookEvent.parse(Data("{\"side\":{},\"event\":{\"hook_event_name\":\"Stop\",\"session_id\":\"s1\",\"cont".utf8)), "cut short")
    }

    /// The real script, as Claude Code would run it: one file per event, read in order, gone after.
    func testTheHookWritesEventsTheInboxReads() throws {
        let script = try XCTUnwrap(HookPaths.bundled)
        let inbox = HookPaths.inbox
        for (index, body) in [#"{"hook_event_name":"UserPromptSubmit","session_id":"s9","cwd":"/w","prompt":"Hello"}"#,
                              "{\n  \"hook_event_name\": \"Stop\",\n  \"session_id\": \"s9\"\n}"].enumerated() {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [script.path, "claude"]
            process.environment = ["SIDE_HOOKS_DIR": inbox.path, "PATH": "/usr/bin:/bin"]
            let input = Pipe(), output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            try process.run()
            input.fileHandleForWriting.write(Data(body.utf8))
            input.fileHandleForWriting.closeFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertTrue(output.fileHandleForReading.readDataToEndOfFile().isEmpty, "the hook prints nothing: it would land in the conversation")
            if index == 0 { Thread.sleep(forTimeInterval: 0.02) }
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: inbox.path).filter { $0.hasSuffix(".json") }
        XCTAssertEqual(files.count, 2)
        let inboxReader = HookInbox()
        inboxReader.read()
        XCTAssertEqual(inboxReader.sessions.sessions["s9"]?.request, "Hello")
        XCTAssertEqual(inboxReader.sessions.sessions["s9"]?.state, .done)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: inbox.path).filter { $0.hasSuffix(".json") }.isEmpty)
    }

    /// Side's entries go in beside the person's own and come out leaving them as they were.
    func testInstallingKeepsEverythingElseAndRemovingTakesOnlySidesOut() throws {
        let url = ClaudeHooks.userSettings
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let theirs: [String: Any] = [
            "model": "opus",
            "permissions": ["allow": ["Bash(git status)"]],
            "hooks": ["Stop": [["hooks": [["type": "command", "command": "say done"]]]]],
        ]
        try JSONSerialization.data(withJSONObject: theirs).write(to: url)
        chmod(url.path, 0o600)
        XCTAssertEqual(ClaudeHooks.status(at: url), .notInstalled)

        try ClaudeHooks.install(at: url)
        XCTAssertEqual(ClaudeHooks.status(at: url), .installed)
        let installed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(installed["model"] as? String, "opus")
        let hooks = try XCTUnwrap(installed["hooks"] as? [String: Any])
        XCTAssertEqual((hooks["Stop"] as? [Any])?.count, 2, "theirs, then Side's")
        XCTAssertNil(hooks["WorktreeCreate"], "a hook there would replace Claude Code's worktrees")
        XCTAssertNil(hooks["WorktreeRemove"])
        let stop = try XCTUnwrap(((hooks["Stop"] as? [[String: Any]])?.last?["hooks"] as? [[String: Any]])?.first)
        XCTAssertEqual(stop["command"] as? String, "\"\(HookPaths.executable.path)\" claude")
        XCTAssertNil(stop["async"], "a turn's state is reported in step")
        let edit = try XCTUnwrap(((hooks["PostToolUse"] as? [[String: Any]])?.last?["hooks"] as? [[String: Any]])?.first)
        XCTAssertEqual(edit["async"] as? Bool, true, "tool events never hold Claude Code up")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: HookPaths.executable.path))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + ".side-backup"))

        // Installing again doesn't add a second set.
        try ClaudeHooks.install(at: url)
        let again = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(((again["hooks"] as? [String: Any])?["Stop"] as? [Any])?.count, 2)

        // A rewritten file that lost some: incomplete, until put back.
        var lost = again
        var lostHooks = try XCTUnwrap(lost["hooks"] as? [String: Any])
        lostHooks.removeValue(forKey: "Notification")
        lost["hooks"] = lostHooks
        try JSONSerialization.data(withJSONObject: lost).write(to: url)
        XCTAssertEqual(ClaudeHooks.status(at: url), .incomplete)

        try ClaudeHooks.remove(at: url)
        XCTAssertEqual(ClaudeHooks.status(at: url), .notInstalled)
        let removed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual((removed["hooks"] as? [String: Any])?.keys.sorted(), ["Stop"])
        XCTAssertEqual(((removed["hooks"] as? [String: Any])?["Stop"] as? [Any])?.count, 1)
        XCTAssertEqual((removed["permissions"] as? [String: Any])?["allow"] as? [String], ["Bash(git status)"])
    }

    func testAFileThatIsntJSONIsLeftAlone() throws {
        let url = ClaudeHooks.userSettings
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ \"model\": opus, }".utf8).write(to: url)
        XCTAssertThrowsError(try ClaudeHooks.install(at: url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "{ \"model\": opus, }")
        // No file at all: one is made with only the hooks.
        let fresh = ClaudeHooks.projectSettings(folder.appendingPathComponent("project", isDirectory: true))
        try ClaudeHooks.install(at: fresh)
        XCTAssertEqual(ClaudeHooks.status(at: fresh), .installed)
    }

    func testSettingsKeptInADotfilesRepositoryStayLinked() throws {
        let real = folder.appendingPathComponent("dotfiles/settings.json")
        try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: real)
        let url = ClaudeHooks.userSettings
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: real)
        try ClaudeHooks.install(at: url)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: url.path), real.path)
        XCTAssertEqual(ClaudeHooks.status(at: real), .installed)
    }
}
