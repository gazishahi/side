import XCTest
@testable import Heron

/// Review's summary: the newest thing an agent said on a track, read from the end of its record.
final class AgentAccountTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("account-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testLastRecordReadsFromTheEndAcrossWindows() throws {
        let url = directory.appendingPathComponent("log.jsonl")
        var records: [OutsideSessionLog.Record] = [.init(kind: .header, agentId: "claude")]
        for turn in 0..<200 {
            records.append(.init(kind: .user, text: "question \(turn)"))
            records.append(.init(kind: .assistant, text: "answer \(turn) " + String(repeating: "x", count: 900)))
            records.append(.init(kind: .tool, text: "read_file", detail: String(repeating: "y", count: 2000)))
        }
        XCTAssertTrue(OutsideSessionLog.append(records, to: url))
        // A small window, so the answer is found only after reading back past a cut line.
        let last = OutsideSessionLog.lastRecord(of: .assistant, in: url, window: 1500)
        XCTAssertEqual(last?.text.hasPrefix("answer 199 "), true)
        XCTAssertEqual(OutsideSessionLog.lastRecord(of: .user, in: url, window: 700)?.text, "question 199")
        XCTAssertNil(OutsideSessionLog.lastRecord(of: .failure, in: url))
        XCTAssertEqual(OutsideSessionLog.agentId(in: url), "claude")
    }

    func testNewestAccountAcrossHeronAndOutsideAgents() throws {
        let store = AgentSessionStore(stateDirectory: directory)
        XCTAssertNil(store.latestAgentAccount(forTrackKey: "feature"))
        _ = store.appendTurn(AgentTurn(role: .assistant, content: [.text("Heron's summary")]), trackKey: "feature", providerId: "p", modelId: "m")
        XCTAssertEqual(store.latestAgentAccount(forTrackKey: "feature")?.text, "Heron's summary")
        XCTAssertNil(store.latestAgentAccount(forTrackKey: "feature")?.agentId)

        let url = store.outsideLogURL(trackKey: "feature", agentId: "codex")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        OutsideSessionLog.append([
            .init(kind: .header, agentId: "codex"),
            .init(kind: .assistant, text: "Codex's summary", at: Date().addingTimeInterval(60)),
            .init(kind: .tool, text: "edit"),
        ], to: url)
        let account = store.latestAgentAccount(forTrackKey: "feature")
        XCTAssertEqual(account?.text, "Codex's summary")
        XCTAssertEqual(account?.agentId, "codex")
        // Another track's record isn't this one's.
        XCTAssertNil(store.latestAgentAccount(forTrackKey: "other"))
    }
}
