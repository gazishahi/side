import XCTest
@testable import Side

/// The menu bar's list while Side is closed (SIDE/BackgroundSessions.swift): which kept terminals
/// it shows, in what state, and how hook events since Side quit move them along.
final class BackgroundSessionsTests: XCTestCase {
    private typealias BS = BackgroundSessions

    private func keeper(_ id: String, shell: Int32, project: String = "/p/side", foreground: [String] = [],
                        status: [BS.Keeper.Status]? = nil, exited: Bool = false) -> BS.Keeper {
        BS.Keeper(id: id, keeperPID: 1000 + shell, childPID: shell, executable: "/bin/zsh", directory: project,
                  client: ["project": project], exit: exited ? .init(status: 0) : nil, foreground: foreground, programStatus: status)
    }

    /// claude (500) runs under the shell 50; the hook ran through sh (5000) under claude.
    private let tree: [Int32: Int32] = [500: 50, 5000: 500, 600: 60]
    private func parent(_ pid: Int32) -> Int32 { tree[pid] ?? 1 }

    private func event(_ name: String, session: String = "s1", ppid: Int32 = 5000, at: TimeInterval, _ extra: [String: Any] = [:]) -> Data {
        var event: [String: Any] = ["hook_event_name": name, "session_id": session]
        event.merge(extra) { $1 }
        return try! JSONSerialization.data(withJSONObject: ["side": ["agent": "claude", "ppid": ppid, "pid": 1, "at": at], "event": event])
    }

    func testIdleShellsAndEndedOnesAreLeftOut() {
        let rows = BS.rows(keepers: [keeper("a", shell: 50), keeper("b", shell: 60, exited: true)], agents: [], parent: parent)
        XCTAssertEqual(rows, [])
    }

    func testAProgramInFrontIsWorkingAndNamedByItsCommand() {
        let rows = BS.rows(keepers: [keeper("a", shell: 50, project: "/p/web", foreground: ["/usr/local/bin/npm", "run", "dev"])], agents: [], parent: parent)
        XCTAssertEqual(rows, [.init(id: "a", project: "web", label: "npm run dev", detail: "", state: .working, since: nil)])
    }

    func testAnAgentInTheShellGivesItsRequestAndState() {
        var agents: [String: BS.Agent] = [:]
        BS.apply(event("UserPromptSubmit", at: 100, ["prompt": "Fix the flaky login test\nand more"]), to: &agents) { $0 == 5000 ? 500 : $0 }
        BS.apply(event("PermissionRequest", at: 160, ["tool_name": "Bash", "tool_input": ["command": "swift test"]]), to: &agents) { $0 == 5000 ? 500 : $0 }
        let rows = BS.rows(keepers: [keeper("a", shell: 50, foreground: ["claude"])], agents: Array(agents.values), parent: parent)
        XCTAssertEqual(rows.first?.label, "Fix the flaky login test")
        XCTAssertEqual(rows.first?.state, .needsYou)
        XCTAssertEqual(rows.first?.detail, "Wants to run swift test")
        XCTAssertEqual(rows.first?.since, Date(timeIntervalSince1970: 160))

        BS.apply(event("PostToolUse", at: 170), to: &agents) { $0 == 5000 ? 500 : $0 }
        XCTAssertEqual(BS.rows(keepers: [keeper("a", shell: 50)], agents: Array(agents.values), parent: parent).first?.state, .working)
        BS.apply(event("Stop", at: 200), to: &agents) { $0 == 5000 ? 500 : $0 }
        let done = BS.rows(keepers: [keeper("a", shell: 50)], agents: Array(agents.values), parent: parent)
        XCTAssertEqual(done.first?.state, .finished)
        // A tool event landing after Stop leaves it finished.
        BS.apply(event("PostToolUse", at: 199), to: &agents) { $0 == 5000 ? 500 : $0 }
        XCTAssertEqual(BS.rows(keepers: [keeper("a", shell: 50)], agents: Array(agents.values), parent: parent).first?.state, .finished)
    }

    func testAnAgentInAnotherShellIsntThisOnes() {
        let agent = BS.Agent(id: "s1", pid: 600, state: .working, request: "Elsewhere", message: "", updatedAt: Date())
        XCTAssertEqual(BS.rows(keepers: [keeper("a", shell: 50)], agents: [agent], parent: parent), [])
    }

    func testWhatAProgramReportsCountsWhenNoAgentDoes() {
        let status = BS.Keeper.Status(id: "", state: "blocked", title: "Deploy", message: "Approve the release?", app: "deployer", updatedAt: Date(timeIntervalSince1970: 50))
        let rows = BS.rows(keepers: [keeper("a", shell: 50, status: [status])], agents: [], parent: parent)
        XCTAssertEqual(rows, [.init(id: "a", project: "side", label: "Deploy", detail: "Approve the release?", state: .needsYou, since: Date(timeIntervalSince1970: 50))])
    }

    func testNeedsYouFirstThenWorkingThenFinishedThenFailed() {
        let agents = [
            BS.Agent(id: "1", pid: 501, state: .failed, request: "f", message: "", updatedAt: Date()),
            BS.Agent(id: "2", pid: 502, state: .finished, request: "d", message: "", updatedAt: Date()),
            BS.Agent(id: "3", pid: 503, state: .needsYou, request: "n", message: "", updatedAt: Date()),
        ]
        let parents: [Int32: Int32] = [501: 51, 502: 52, 503: 53]
        let keepers = [keeper("a", shell: 51), keeper("b", shell: 52), keeper("c", shell: 53), keeper("d", shell: 54, foreground: ["make"])]
        let rows = BS.rows(keepers: keepers, agents: agents) { parents[$0] ?? 1 }
        XCTAssertEqual(rows.map(\.label), ["n", "make", "d", "f"])
        let summary = BS.summary(rows)
        XCTAssertEqual(summary.state, .needsYou)
        XCTAssertEqual(summary.needsYou, 1)
    }

    func testDurations() {
        XCTAssertEqual(BS.duration(20), "now")
        XCTAssertEqual(BS.duration(4 * 60), "4m")
        XCTAssertEqual(BS.duration(72 * 60), "1h 12m")
        XCTAssertEqual(BS.duration(120 * 60), "2h")
        XCTAssertEqual(BS.duration(3 * 86400), "3d")
    }

    func testTheSnapshotRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("menu-bar-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let agents = [BS.Agent(id: "s1", pid: 500, state: .working, request: "Fix it", message: "", updatedAt: Date(timeIntervalSince1970: 1_700_000_000))]
        BS.writeSnapshot(agents, to: url)
        XCTAssertEqual(BS.readSnapshot(url), agents)
    }

    func testHookStatesMapAsTheMenuShowsThem() {
        XCTAssertEqual(BS.State(SessionRegistry.State.working(progress: nil)), .working)
        XCTAssertEqual(BS.State(SessionRegistry.State.needsYou(nil)), .needsYou)
        XCTAssertEqual(BS.State(SessionRegistry.State.done), .finished)
        XCTAssertNil(BS.State(SessionRegistry.State.idle))
    }
}
