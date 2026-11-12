import XCTest
@testable import Side
@testable import SideSessionsKit

/// Sessions, phase 1 (SIDE_RFC_SESSIONS.md): what a session is doing, and where.
@MainActor
final class SessionRegistryTests: XCTestCase {
    func testAProgramsOwnReportWinsOverSidesReading() {
        var records = ProgramStatusRecords()
        records.put(.init(id: "", state: .blocked, kind: .permission, message: "Run swift test?"))
        // The terminal looks idle to Side, but the program says it's waiting on you.
        let reading = SessionRegistry.state(records: records, working: false, news: nil, program: "claude")
        XCTAssertEqual(reading.state, .needsYou(.permission))
        XCTAssertEqual(reading.state.word, "Needs permission")
        XCTAssertEqual(reading.message, "Run swift test?")
        XCTAssertTrue(reading.reported)
        // No report: Side's own reading, marked as such.
        let read = SessionRegistry.state(records: ProgramStatusRecords(), working: true, news: nil, program: "codex")
        XCTAssertEqual(read.state, .working(progress: nil))
        XCTAssertFalse(read.reported)
        XCTAssertEqual(SessionRegistry.state(records: ProgramStatusRecords(), working: false, news: .needsYou, program: "claude").state, .needsYou(nil))
        XCTAssertEqual(SessionRegistry.state(records: ProgramStatusRecords(), working: false, news: .finished, program: "claude").state, .done)
        // Only child records: the one updated last speaks for it.
        var children = ProgramStatusRecords()
        children.put(.init(id: "build", state: .done, updatedAt: Date(timeIntervalSince1970: 1)))
        children.put(.init(id: "test", state: .working, progress: 30, updatedAt: Date(timeIntervalSince1970: 2)))
        XCTAssertEqual(SessionRegistry.state(records: children, working: false, news: nil, program: nil).state, .working(progress: 30))
    }

    func testNeedsYouComesFirst() {
        let order: [SessionRegistry.State] = [.idle, .working(progress: nil), .done, .failed, .needsYou(nil)]
        XCTAssertEqual(order.sorted { $0.rank < $1.rank }.first, .needsYou(nil))
    }

    func testCheckoutsComeFromGitAndAgentsWorktreesWinInsideTheMainFolder() {
        let porcelain = """
        worktree /Users/me/app
        HEAD 1111111111111111111111111111111111111111
        branch refs/heads/main

        worktree /Users/me/app/.claude/worktrees/fix-pill
        HEAD 2222222222222222222222222222222222222222
        branch refs/heads/worktree-fix-pill

        worktree /Users/me/.cursor/worktrees/app/try
        HEAD 3333333333333333333333333333333333333333
        detached

        """
        let checkouts = SessionRegistry.parseWorktrees(porcelain)
        XCTAssertEqual(checkouts.map(\.branch), ["main", "worktree-fix-pill", nil])
        XCTAssertEqual(checkouts.map(\.isMain), [true, false, false])
        XCTAssertEqual(SessionRegistry.checkout(for: "/Users/me/app/Sources", in: checkouts)?.branch, "main")
        XCTAssertEqual(SessionRegistry.checkout(for: "/Users/me/app/.claude/worktrees/fix-pill/Sources", in: checkouts)?.branch, "worktree-fix-pill",
                       "a session in an agent's own worktree is on that worktree's branch, not the main folder's")
        XCTAssertNil(SessionRegistry.checkout(for: "/Users/me/application", in: checkouts), "a prefix of a name isn't a folder inside it")
        XCTAssertNil(SessionRegistry.checkout(for: "/Users/me/.cursor/worktrees/app/try2", in: checkouts))
    }

    func testClaudesBackgroundSessionsAreReadAndStoppedOnesSkipped() {
        let json = """
        [{"sessionId":"a1","name":"Fix the pill","cwd":"/Users/me/app","state":"blocked","waitingFor":"Approve Bash(swift test)","pid":10},
         {"sessionId":"b2","name":"","cwd":"/Users/me/app","state":"working"},
         {"sessionId":"c3","cwd":"/Users/me/app","state":"stopped"},
         {"name":"no id","cwd":"/x","state":"working"}]
        """
        let sessions = SessionRegistry.parseClaudeAgents(Data(json.utf8))
        XCTAssertEqual(sessions.map(\.sessionId), ["a1", "b2", "c3"])
        XCTAssertEqual(sessions[0].state, .needsYou(nil))
        XCTAssertEqual(sessions[0].waitingFor, "Approve Bash(swift test)")
        XCTAssertNil(sessions[1].name, "an empty name is no name")
        XCTAssertNil(sessions[2].state, "stopped: not shown")
        XCTAssertTrue(SessionRegistry.parseClaudeAgents(Data("not json".utf8)).isEmpty)
        XCTAssertFalse(SessionRegistry.mayAskClaude, "a test never runs the developer's Claude Code")
    }
}
