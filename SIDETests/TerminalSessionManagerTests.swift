import XCTest
@testable import Side

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
}
