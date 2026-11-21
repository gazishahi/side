import XCTest
import SideSessionsKit
@testable import Side

/// Session restore, phase 1 (SIDE_RFC_SESSION_RESTORE.md): a shell in a keeper outlives its
/// project being released, and reopening the project gives back the same shell and screen.
@MainActor
/// Not final: SessionKeeperAlloyTests runs every one of these again on the new terminal engine.
class SessionKeeperTests: XCTestCase {
    nonisolated(unsafe) private var runDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipIf(SessionKeepers.bundledKeeperAppURL == nil, "No keeper in the test host's bundle.")
        // Short: a socket path must fit in 103 bytes.
        runDirectory = URL(fileURLWithPath: "/tmp/skt-\(UUID().uuidString.prefix(8))", isDirectory: true)
        setenv("SIDE_SESSIONS_DIR", runDirectory.path, 1)
        SessionKeepers.enabledForTesting = true
        // The setting lives in this process's own store under XCTest (SessionKeepers); each test
        // starts with it on, whatever the one before left.
        SessionKeepers.keepsRunningOnQuit = true
    }

    override func tearDown() {
        SessionKeepers.enabledForTesting = false
        for record in SessionPaths.records() { kill(record.childPID, SIGKILL); kill(record.keeperPID, SIGKILL) }
        if let runDirectory { try? FileManager.default.removeItem(at: runDirectory) }
        unsetenv("SIDE_SESSIONS_DIR")
        super.tearDown()
    }

    private func screen(_ session: TerminalSession) -> String {
        session.viewController.terminalView.bufferText()
    }

    private func waitUntil(_ timeout: TimeInterval = 15, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    /// The new engine (TerminalEngine.alloy) in a kept shell: typed into, read back, and
    /// reattached from the keeper's snapshot into a fresh surface.
    func testTheAlloyEngineRunsAKeptShellAndReattaches() throws {
        TerminalEngine.overrideForTesting = .alloy
        defer { TerminalEngine.overrideForTesting = nil }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("keepers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let first = TerminalSessionManager(projectRoot: root) { _ in root }
        let session = first.makeSession(forTrackKey: "t")
        first.setSessions([session], forTrackKey: "t")
        XCTAssertTrue(session.viewController.terminalView is AlloyTerminalSurface)
        let id = try XCTUnwrap(session.viewController.keeperID)
        session.viewController.loadViewIfNeeded()
        session.viewController.view.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
        session.viewController.view.layoutSubtreeIfNeeded()
        session.viewController.start()
        XCTAssertTrue(waitUntil { SessionKeepers.liveRecord(id) != nil }, "no keeper")
        XCTAssertTrue(waitUntil { session.viewController.startupSettled })
        session.viewController.terminalView.send(text: "echo alloy-$((40+2))\r")
        XCTAssertTrue(waitUntil { self.screen(session).contains("alloy-42") }, screen(session))
        XCTAssertTrue(waitUntil { session.viewController.terminalView.visibleText().contains("alloy-42") })

        // Released and reopened: a new surface, filled from the keeper.
        first.teardownAll()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let second = TerminalSessionManager(projectRoot: root) { _ in root }
        let again = second.makeSession(forTrackKey: "t", keeperID: id)
        second.setSessions([again], forTrackKey: "t")
        again.viewController.loadViewIfNeeded()
        again.viewController.view.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
        again.viewController.view.layoutSubtreeIfNeeded()
        again.viewController.start()
        XCTAssertTrue(waitUntil { self.screen(again).contains("alloy-42") }, "the screen comes back: \(screen(again))")
        again.viewController.terminalView.send(text: "echo still-$((1+1))\r")
        XCTAssertTrue(waitUntil { self.screen(again).contains("still-2") }, screen(again))
        second.removeSession(again)
        XCTAssertTrue(waitUntil { SessionKeepers.liveRecord(id) == nil })
    }

    func testAShellOutlivesItsProjectAndReattaches() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("keepers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let first = TerminalSessionManager(projectRoot: root) { _ in root }
        let session = first.makeSession(forTrackKey: "t")
        first.setSessions([session], forTrackKey: "t")
        let id = try XCTUnwrap(session.viewController.keeperID)
        session.viewController.loadViewIfNeeded()
        session.viewController.start()
        XCTAssertTrue(waitUntil { SessionKeepers.liveRecord(id) != nil }, "no keeper")
        // Typed once the shell is up: echo the sum, so the screen shows the answer, not the typing.
        XCTAssertTrue(waitUntil { session.viewController.startupSettled })
        session.viewController.terminalView.send(text: "echo keeper-$((40+2))\r")
        XCTAssertTrue(waitUntil { self.screen(session).contains("keeper-42") }, screen(session))
        let shell = try XCTUnwrap(SessionKeepers.liveRecord(id)?.childPID)
        // Run from a copy, never the bundle's own file: a rebuild that rewrites that file kills
        // every keeper running it (2026-11-03).
        let keeperPID = try XCTUnwrap(SessionKeepers.liveRecord(id)?.keeperPID)
        var path = [CChar](repeating: 0, count: 4096)
        proc_pidpath(keeperPID, &path, UInt32(path.count))
        let executable = String(cString: path)
        // `/tmp` is `/private/tmp`: compared by the run directory's own name.
        XCTAssertTrue(executable.contains("/\(runDirectory.lastPathComponent)/bin/"), executable)
        XCTAssertFalse(executable.contains("Side.app/"), executable)
        // The keeper app, answering for its terminals to macOS's privacy settings itself, by a
        // bundle identifier a grant survives updates under; not Side, which it outlives
        // (2026-11-07).
        XCTAssertTrue(executable.hasSuffix("/\(SessionKeepers.keeperAppName)/Contents/MacOS/SideSessionKeeper"), executable)
        let app = URL(fileURLWithPath: executable).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        XCTAssertEqual(Bundle(url: app)?.bundleIdentifier, (Bundle.main.bundleIdentifier ?? "") + ".SessionKeeper")
        if let responsible = KeeperLauncher.responsiblePID(for: keeperPID) {
            XCTAssertEqual(responsible, keeperPID, "the keeper answers for itself")
            XCTAssertEqual(KeeperLauncher.responsiblePID(for: shell), keeperPID, "and for its shell")
        }

        // Quitting, or the project's last window closing: the shell keeps running.
        first.teardownAll()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(kill(shell, 0), 0, "the shell ended with the project")
        XCTAssertNotNil(SessionKeepers.liveRecord(id))

        // The project opens again: same shell, same screen, still taking input.
        let second = TerminalSessionManager(projectRoot: root) { _ in root }
        XCTAssertEqual(SessionKeepers.liveRecords(project: root.path, track: "t").map(\.id), [id])
        let again = second.makeSession(forTrackKey: "t", keeperID: id)
        second.setSessions([again], forTrackKey: "t")
        again.viewController.loadViewIfNeeded()
        again.viewController.start()
        XCTAssertTrue(waitUntil { self.screen(again).contains("keeper-42") }, "the screen didn't come back:\n\(screen(again))")
        again.viewController.terminalView.send(text: "echo still-$((1+1))\r")
        XCTAssertTrue(waitUntil { self.screen(again).contains("still-2") }, screen(again))
        XCTAssertEqual(SessionKeepers.liveRecord(id)?.childPID, shell, "a new shell, not the same one")

        // Closing the tab ends it for good.
        second.removeSession(again)
        XCTAssertTrue(waitUntil { kill(shell, 0) != 0 }, "the shell survived its tab closing")
        XCTAssertTrue(waitUntil { SessionKeepers.liveRecord(id) == nil })
    }

    func testWithKeepRunningOffQuittingEndsTheShell() throws {
        SessionKeepers.keepsRunningOnQuit = false
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("keepers-off-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manager = TerminalSessionManager(projectRoot: root) { _ in root }
        let session = manager.makeSession(forTrackKey: "t")
        manager.setSessions([session], forTrackKey: "t")
        let id = try XCTUnwrap(session.viewController.keeperID)
        session.viewController.loadViewIfNeeded()
        session.viewController.start()
        XCTAssertTrue(waitUntil { SessionKeepers.liveRecord(id) != nil })
        let shell = try XCTUnwrap(SessionKeepers.liveRecord(id)?.childPID)
        manager.teardownAll()
        XCTAssertTrue(waitUntil { kill(shell, 0) != 0 }, "the shell kept running with the setting off")
    }

    func testWhatARecoveredTabDoesWithWhatWasRunning() {
        XCTAssertEqual(SessionKeepers.recovery(foreground: [], agentSession: nil), .nothing)
        XCTAssertEqual(SessionKeepers.recovery(foreground: ["-zsh"], agentSession: nil), .nothing)
        XCTAssertEqual(SessionKeepers.recovery(foreground: ["claude"], agentSession: "1b2c", hasTranscript: { _ in true }), .run("claude --resume 1b2c"))
        // Nothing typed yet: no transcript to resume, so a fresh session under the same id.
        XCTAssertEqual(SessionKeepers.recovery(foreground: ["claude"], agentSession: "1b2c", hasTranscript: { _ in false }), .run("claude --session-id 1b2c"))
        XCTAssertEqual(SessionKeepers.recovery(foreground: ["/opt/homebrew/bin/claude", "--model", "opus"], agentSession: nil), .run("claude --continue"))
        XCTAssertEqual(SessionKeepers.recovery(foreground: ["nvim", "My Notes.md"], agentSession: nil), .run("nvim 'My Notes.md'"))
        XCTAssertEqual(SessionKeepers.recovery(foreground: ["tail", "-f", "log.txt"], agentSession: nil), .run("tail -f log.txt"))
        XCTAssertEqual(SessionKeepers.recovery(foreground: ["npm", "run", "dev"], agentSession: nil), .offer("npm run dev"))
        XCTAssertEqual(SessionKeepers.recovery(foreground: ["lazygit"], agentSession: nil), .run("lazygit"))
        XCTAssertEqual(SessionKeepers.recovery(foreground: ["/opt/homebrew/bin/opencode"], agentSession: nil), .run("opencode --continue"))
        XCTAssertEqual(SessionKeepers.recovery(foreground: ["codex", "--model", "o4"], agentSession: nil), .run("codex resume --last"))
        XCTAssertEqual(SessionKeepers.recovery(foreground: ["gemini"], agentSession: nil), .offer("gemini"))
        XCTAssertEqual(SessionKeepers.recovery(foreground: ["rm", "-rf", "it's"], agentSession: nil), .offer("rm -rf 'it'\\''s'"))
    }

    func testARestartBringsTheTabBackBelowItsOldScreen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("keepers-restart-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let first = TerminalSessionManager(projectRoot: root) { _ in root }
        let session = first.makeSession(forTrackKey: "t")
        first.setSessions([session], forTrackKey: "t")
        let id = try XCTUnwrap(session.viewController.keeperID)
        session.viewController.loadViewIfNeeded()
        session.viewController.start()
        XCTAssertTrue(waitUntil { session.viewController.startupSettled })
        session.viewController.terminalView.send(text: "echo before-$((6*7))\r")
        XCTAssertTrue(waitUntil { self.screen(session).contains("before-42") })
        first.teardownAll()

        // The machine restarts: the keeper saves the screen at SIGTERM, and everything ends.
        let old = try XCTUnwrap(SessionKeepers.liveRecord(id))
        kill(old.keeperPID, SIGTERM)
        XCTAssertTrue(waitUntil { kill(old.keeperPID, 0) != 0 })
        kill(old.childPID, SIGKILL)
        let ended = try XCTUnwrap(SessionKeepers.endedRecord(id), "the ended session should be recoverable")
        XCTAssertEqual(SessionKeepers.endedRecords(project: root.path, track: "t").map(\.id), [id])

        let second = TerminalSessionManager(projectRoot: root) { _ in root }
        let again = second.makeSession(forTrackKey: "t", keeperID: id)
        second.setSessions([again], forTrackKey: "t")
        again.viewController.recovering = ended
        again.viewController.loadViewIfNeeded()
        again.viewController.start()
        XCTAssertTrue(waitUntil { self.screen(again).contains("Restored after a restart") }, screen(again))
        XCTAssertTrue(screen(again).contains("before-42"), "the old screen didn't come back")
        XCTAssertTrue(waitUntil { again.viewController.startupSettled })
        again.viewController.terminalView.send(text: "echo after-$((5*5))\r")
        XCTAssertTrue(waitUntil { self.screen(again).contains("after-25") }, screen(again))
        XCTAssertNotEqual(SessionKeepers.liveRecord(id)?.childPID, old.childPID, "a new shell")
        second.removeSession(again)
    }

    func testTheClaudeWrapperReportsItsSessionWithTheNonceOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("keepers-agent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manager = TerminalSessionManager(projectRoot: root) { _ in root }
        let session = manager.makeSession(forTrackKey: "t")
        manager.setSessions([session], forTrackKey: "t")
        let id = try XCTUnwrap(session.viewController.keeperID)
        defer { manager.forgetAgentSession(forKeeper: id); manager.removeSession(session) }
        session.viewController.loadViewIfNeeded()
        session.viewController.start()
        XCTAssertTrue(waitUntil { session.viewController.startupSettled })
        // The wrapper is defined in Side's zsh (when the shell is zsh).
        guard (ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh").contains("zsh") else { throw XCTSkip("not zsh") }
        session.viewController.terminalView.send(text: "whence -w claude\r")
        XCTAssertTrue(waitUntil { self.screen(session).contains("claude: function") }, screen(session))
        // A report without the shell's nonce is anyone's output, and ignored.
        session.viewController.terminalView.send(text: "printf '\\e]6973;agent;claude;forged;nope\\a'\r")
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertNil(manager.agentSession(forKeeper: id))
        session.viewController.terminalView.send(text: "printf '\\e]6973;agent;claude;0f1e-real;%s\\a' \"$__SIDE_NONCE\"\r")
        XCTAssertTrue(waitUntil { manager.agentSession(forKeeper: id) == "0f1e-real" })
    }

    func testATabSaysWhatsRunningInIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("keepers-running-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manager = TerminalSessionManager(projectRoot: root) { _ in root }
        let session = manager.makeSession(forTrackKey: "t")
        manager.setSessions([session], forTrackKey: "t")
        defer { manager.removeSession(session) }
        session.viewController.loadViewIfNeeded()
        session.viewController.start()
        XCTAssertTrue(waitUntil { session.viewController.startupSettled })
        XCTAssertNil(session.viewController.runningProgramName, "a shell at its prompt isn't running anything")
        session.viewController.terminalView.send(text: "sleep 30\r")
        XCTAssertTrue(waitUntil { session.viewController.runningProgramName == "sleep" }, session.viewController.runningProgramName ?? "nil")
    }

    func testEndingASessionWithNoTabEndsIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("keepers-end-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manager = TerminalSessionManager(projectRoot: root) { _ in root }
        let session = manager.makeSession(forTrackKey: "t")
        manager.setSessions([session], forTrackKey: "t")
        let id = try XCTUnwrap(session.viewController.keeperID)
        session.viewController.loadViewIfNeeded()
        session.viewController.start()
        XCTAssertTrue(waitUntil { SessionKeepers.liveRecord(id) != nil })
        manager.teardownAll() // the project closes; the shell keeps running, with no tab
        let record = try XCTUnwrap(SessionKeepers.liveRecord(id))
        SessionKeepers.end(record)
        XCTAssertTrue(waitUntil { kill(record.childPID, 0) != 0 }, "the shell survived End")
        XCTAssertTrue(waitUntil { SessionKeepers.liveRecord(id) == nil }, "the keeper stayed")
    }
}

/// One Claude Code conversation in two of Side's terminals (`ClaudeConversations`).
final class ClaudeConversationsTests: XCTestCase {
    func testAProcessIsNamedByItsOwnSessionFileOnly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cc-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try #"{"pid": 4242, "sessionId": "abc", "status": "idle"}"#.write(to: dir.appendingPathComponent("4242.json"), atomically: true, encoding: .utf8)
        try #"{"pid": 1, "sessionId": "stale"}"#.write(to: dir.appendingPathComponent("4343.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(ClaudeConversations.conversation(ofProcess: 4242, in: dir), "abc")
        XCTAssertNil(ClaudeConversations.conversation(ofProcess: 4343, in: dir), "a file naming another process isn't this one's")
        XCTAssertNil(ClaudeConversations.conversation(ofProcess: 4444, in: dir), "no file, no conversation")
    }

    func testTwoTerminalsOnOneConversationAreFound() {
        func record(_ id: String, shell: Int32) -> SessionRecord {
            SessionRecord(id: id, keeperPID: 1, childPID: shell, executable: "/bin/zsh", arguments: [], directory: "/", client: [:], createdAt: Date(), lastOutputAt: Date())
        }
        let records = [record("a", shell: 10), record("b", shell: 20), record("c", shell: 30)]
        let conversations: [Int32: String] = [10: "x", 20: "y", 30: "x"]
        let found = ClaudeConversations.duplicate(ofKeeper: "a", records: records, conversationInShell: { conversations[$0] })
        XCTAssertEqual(found, ClaudeConversations.Duplicate(conversation: "x", otherKeeperID: "c"))
        XCTAssertNil(ClaudeConversations.duplicate(ofKeeper: "b", records: records, conversationInShell: { conversations[$0] }), "alone on its conversation")
        XCTAssertNil(ClaudeConversations.duplicate(ofKeeper: "a", records: records, conversationInShell: { _ in nil }), "no Claude Code, nothing to say")
    }
}
