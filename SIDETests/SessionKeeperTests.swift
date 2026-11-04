import XCTest
import SideSessionsKit
@testable import Side

/// Session restore, phase 1 (SIDE_RFC_SESSION_RESTORE.md): a shell in a keeper outlives its
/// project being released, and reopening the project gives back the same shell and screen.
@MainActor
final class SessionKeeperTests: XCTestCase {
    nonisolated(unsafe) private var runDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipIf(SessionKeepers.bundledKeeperURL == nil, "No keeper in the test host's bundle.")
        // Short: a socket path must fit in 103 bytes.
        runDirectory = URL(fileURLWithPath: "/tmp/skt-\(UUID().uuidString.prefix(8))", isDirectory: true)
        setenv("SIDE_SESSIONS_DIR", runDirectory.path, 1)
        SessionKeepers.enabledForTesting = true
    }

    override func tearDown() {
        SessionKeepers.enabledForTesting = false
        for record in SessionPaths.records() { kill(record.childPID, SIGKILL); kill(record.keeperPID, SIGKILL) }
        if let runDirectory { try? FileManager.default.removeItem(at: runDirectory) }
        unsetenv("SIDE_SESSIONS_DIR")
        super.tearDown()
    }

    private func screen(_ session: TerminalSession) -> String {
        String(decoding: session.viewController.terminalView.getTerminal().getBufferAsData(), as: UTF8.self)
    }

    private func waitUntil(_ timeout: TimeInterval = 15, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
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
        session.viewController.terminalView.send(txt: "echo keeper-$((40+2))\r")
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
        XCTAssertFalse(executable.contains(".app/"), executable)

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
        again.viewController.terminalView.send(txt: "echo still-$((1+1))\r")
        XCTAssertTrue(waitUntil { self.screen(again).contains("still-2") }, screen(again))
        XCTAssertEqual(SessionKeepers.liveRecord(id)?.childPID, shell, "a new shell, not the same one")

        // Closing the tab ends it for good.
        second.removeSession(again)
        XCTAssertTrue(waitUntil { kill(shell, 0) != 0 }, "the shell survived its tab closing")
        XCTAssertTrue(waitUntil { SessionKeepers.liveRecord(id) == nil })
    }

    func testWithKeepRunningOffQuittingEndsTheShell() throws {
        let saved = UserDefaults.standard.object(forKey: SessionKeepers.keepRunningKey)
        defer { UserDefaults.standard.set(saved, forKey: SessionKeepers.keepRunningKey) }
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
}
