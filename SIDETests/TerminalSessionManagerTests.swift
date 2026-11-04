import XCTest
@testable import Side
@testable import Heron

/// RFC R2: terminals belong to the project, not a window.
@MainActor
final class TerminalSessionManagerTests: XCTestCase {
    func testAnAgentCommandRunsWithNoWindowAndInterruptsTheSessionRunningIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("terminals-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manager = TerminalSessionManager(projectRoot: root) { _ in root }
        defer { manager.teardownAll() }

        // No window, no Run view — the case that used to answer "No window is open".
        let finished = expectation(description: "command finished")
        var output = ""
        manager.runAgentCommand("echo side-r2-ok", trackKey: "feature", timeout: 20) { result in
            output = result
            finished.fulfill()
        }
        wait(for: [finished], timeout: 30)
        XCTAssertTrue(output.contains("side-r2-ok"), output)
        let agentSession = try XCTUnwrap(manager.sessions(forTrackKey: "feature").first)
        XCTAssertNil(agentSession.viewController.view.window)

        // The user opens a second tab and selects it: the agent's session stays pinned, so an
        // interrupt reaches the command's own terminal (audit D-4), not the selected one.
        let second = manager.makeSession(forTrackKey: "feature")
        manager.setSessions([agentSession, second], forTrackKey: "feature")
        manager.setActiveIndex(1, forTrackKey: "feature")
        XCTAssertTrue(manager.agentSession(forTrackKey: "feature") === agentSession)

        // Other tracks are untouched, and a deleted track's terminals go with it.
        XCTAssertTrue(manager.sessions(forTrackKey: "").isEmpty)
        manager.discardSessions(forTrackKey: "feature")
        XCTAssertTrue(manager.sessions(forTrackKey: "feature").isEmpty)
    }

    /// Two windows on one project, each bringing the same terminal forward in turn: it moves
    /// to the one that asked, and the other shows a placeholder. The handoff once recursed
    /// until the stack overflowed (2026-11-04, opening Run from a notification).
    func testTwoWindowsHandATerminalBackAndForthWithoutLooping() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("terminals-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manager = TerminalSessionManager(projectRoot: root) { _ in root }
        defer { manager.teardownAll() }
        let session = manager.makeSession(forTrackKey: "")
        manager.setSessions([session], forTrackKey: "")
        manager.setActiveIndex(0, forTrackKey: "")

        let views = (0..<2).map { _ -> RunWorkspaceViewController in
            let run = RunWorkspaceViewController()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = run
            run.attach(to: manager)
            return run
        }
        defer { views.forEach { $0.view.window?.close() } }
        for run in [views[0], views[1], views[0], views[1]] {
            run.activateActiveSession()
            XCTAssertTrue(session.viewController.parent === run)
            let other = views.first { $0 !== run }!
            XCTAssertFalse(other.children.contains { $0 === session.viewController })
        }
    }

    /// Tear-out moves a terminal, never copies or restarts it: it leaves every other window's
    /// list for the torn-out window's, and closing that window hands it back to the track.
    func testATornOutTerminalMovesToItsWindowAndReturnsWhenThatWindowCloses() {
        let root = FileManager.default.temporaryDirectory
        let manager = TerminalSessionManager(projectRoot: root) { _ in root }
        defer { manager.teardownAll() }
        let (a, b, c) = (manager.makeSession(forTrackKey: "t"), manager.makeSession(forTrackKey: "t"), manager.makeSession(forTrackKey: "t"))
        manager.setSessions([a, b, c], forTrackKey: "t")
        manager.setActiveIndex(1, forTrackKey: "t")
        let window = UUID()

        manager.hold(b, forTrackKey: "t", holder: window)
        XCTAssertTrue(manager.sessions(forTrackKey: "t").elementsEqual([a, c], by: ===))
        XCTAssertEqual(manager.activeIndex(forTrackKey: "t"), 1, "the right neighbour takes the torn tab's place")
        XCTAssertTrue(manager.sessions(forTrackKey: "t", holder: window).elementsEqual([b], by: ===))
        XCTAssertEqual(manager.activeIndex(forTrackKey: "t", holder: window), 0)

        manager.release(holder: window)
        XCTAssertTrue(manager.sessions(forTrackKey: "t").elementsEqual([a, c, b], by: ===))
        XCTAssertTrue(manager.sessions(forTrackKey: "t", holder: window).isEmpty)
    }

    /// Direction 03 §4.3: a Run tab takes a name of the person's own, kept with the track's tabs,
    /// and an empty name gives it back the automatic one.
    func testARenamedTabKeepsItsNameAcrossAReopen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("terminals-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manager = TerminalSessionManager(projectRoot: root) { _ in root }
        defer { manager.teardownAll() }
        let first = manager.makeSession(forTrackKey: "feature")
        let second = manager.makeSession(forTrackKey: "feature")
        manager.setSessions([first, second], forTrackKey: "feature")
        let automatic = second.title
        manager.rename(second, to: "dev server")
        XCTAssertEqual(second.title, "dev server")
        XCTAssertEqual(manager.rememberedNames(forTrackKey: "feature"), [nil, "dev server"])
        manager.rename(second, to: nil)
        XCTAssertEqual(second.title, automatic)
        XCTAssertEqual(manager.rememberedNames(forTrackKey: "feature"), [], "no names, nothing kept")
    }
}
