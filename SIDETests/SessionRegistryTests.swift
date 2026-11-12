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

    func testClaudeCodesOwnListAsItPrintsIt() {
        // Claude Code 2.1.322's `claude agents --json`, trimmed: every live session, in any terminal.
        let json = """
        [{"pid":4409,"cwd":"/Users/me/app","kind":"interactive","startedAt":1793903433822,"sessionId":"c2d4","name":"app-ff","status":"idle"},
         {"pid":4917,"cwd":"/Users/me/app/.claude/worktrees/x","kind":"interactive","startedAt":1793903453837,"sessionId":"a4ba","name":"app-c8","status":"busy"}]
        """
        let sessions = SessionRegistry.parseClaudeAgents(Data(json.utf8))
        XCTAssertEqual(sessions.map(\.pid), [4409, 4917])
        XCTAssertEqual(sessions.map(\.state), [.idle, .working(progress: nil)])
        XCTAssertEqual(sessions.first?.kind, "interactive")
    }

    func testTheDocumentedSpellingIsReadToo() {
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

    /// The switcher: what needs you, then what's working, then the rest; plain shells at their
    /// prompt left out; a search matches title, program, branch, project or what it said.
    func testTheSwitcherGroupsAndFinds() {
        func session(_ title: String, _ program: String?, _ state: SessionRegistry.State, branch: String? = nil, message: String = "") -> SessionRegistry.Session {
            SessionRegistry.Session(id: title, source: .terminal(UUID()), program: program, title: title, state: state, message: message, cwd: nil,
                                    project: URL(fileURLWithPath: "/p/app"), checkout: branch.map { .init(path: "/p/app", branch: $0, isMain: true) }, reportsItself: false)
        }
        let sessions = [
            session("zsh", nil, .idle),
            session("Dev server", "npm", .idle),
            session("Fix pill", "claude", .working(progress: nil), branch: "fix-pill"),
            session("Tests", "codex", .needsYou(.question), message: "Which database?"),
            session("Lint", "cargo", .failed),
        ]
        XCTAssertEqual(SessionSwitcherOverlay.listed(sessions, query: "").map(\.title), ["Tests", "Lint", "Fix pill", "Dev server"],
                       "needs you and failed first, then working, then the rest; an idle shell isn't listed")
        XCTAssertEqual(SessionSwitcherOverlay.listed(sessions, query: "fix-p").map(\.title), ["Fix pill"], "by branch")
        XCTAssertEqual(SessionSwitcherOverlay.listed(sessions, query: "claude code").map(\.title), ["Fix pill"], "by the program's name")
        XCTAssertEqual(SessionSwitcherOverlay.listed(sessions, query: "database").map(\.title), ["Tests"], "by what it said")
        XCTAssertEqual(SessionSwitcherOverlay.listed(sessions, query: "app").count, 4, "by project")
    }
}
