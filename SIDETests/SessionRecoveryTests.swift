import XCTest
@testable import Side

/// A session whose `tool_use` blocks aren't all answered by `tool_result` blocks is not merely
/// untidy — the whole turn list is replayed to the provider on every send, and an unanswered
/// tool_use is a protocol violation the API rejects, so the track can never be messaged again.
/// These cover the crash window `teardown()` can't reach.
final class SessionRecoveryTests: XCTestCase {
    private func session(_ turns: [AgentTurn]) -> AgentSession {
        var session = AgentSession(trackKey: "t", providerId: "anthropic", modelId: "m")
        session.turns = turns
        return session
    }

    private func toolUseIds(_ session: AgentSession) -> [String] {
        session.turns.flatMap { turn in
            turn.content.compactMap { block -> String? in
                guard case .toolUse(let id, _, _) = block else { return nil }
                return id
            }
        }
    }

    private func toolResultIds(_ session: AgentSession) -> [String] {
        session.turns.flatMap { turn in
            turn.content.compactMap { block -> String? in
                guard case .toolResult(let id, _, _) = block else { return nil }
                return id
            }
        }
    }

    /// The exact force-quit shape: assistant asked for a tool, process died before the result
    /// was persisted.
    func testRepairsUnansweredToolUse() {
        let broken = session([
            AgentTurn(role: .user, content: [.text("edit the file")]),
            AgentTurn(role: .assistant, content: [
                .text("I'll edit it."),
                .toolUse(id: "call_1", name: "edit_file", input: .object([:])),
            ]),
        ])
        guard let repaired = AgentSessionStore.repairingDanglingToolUses(broken) else {
            return XCTFail("expected a repair")
        }
        XCTAssertEqual(toolResultIds(repaired), ["call_1"])
        // Every tool_use must now be answered.
        XCTAssertTrue(Set(toolUseIds(repaired)).subtracting(Set(toolResultIds(repaired))).isEmpty)
    }

    /// The wire format requires the result in the message *immediately after* the call.
    func testRepairIsInsertedDirectlyAfterTheCallingTurn() {
        let broken = session([
            AgentTurn(role: .assistant, content: [.toolUse(id: "call_1", name: "edit_file", input: .object([:]))]),
            AgentTurn(role: .user, content: [.text("unrelated later message")]),
        ])
        let repaired = AgentSessionStore.repairingDanglingToolUses(broken)
        XCTAssertEqual(repaired?.turns.count, 3)
        guard case .toolResult(let id, _, let isError)? = repaired?.turns[1].content.first else {
            return XCTFail("repair turn not inserted at index 1")
        }
        XCTAssertEqual(id, "call_1")
        XCTAssertTrue(isError, "a never-approved call should read as failed, not as success")
        XCTAssertEqual(repaired?.turns[1].role, .user)
    }

    /// A batch can have several calls; a crash strands all of them.
    func testRepairsEveryUnansweredCallInABatch() {
        let broken = session([
            AgentTurn(role: .assistant, content: [
                .toolUse(id: "call_1", name: "edit_file", input: .object([:])),
                .toolUse(id: "call_2", name: "write_file", input: .object([:])),
                .toolUse(id: "call_3", name: "run_shell_command", input: .object([:])),
            ]),
        ])
        let repaired = AgentSessionStore.repairingDanglingToolUses(broken)
        XCTAssertEqual(toolResultIds(repaired!).sorted(), ["call_1", "call_2", "call_3"])
    }

    /// Partial resolution is the likeliest real crash: one proposal approved, the rest pending.
    func testRepairsOnlyTheUnansweredCalls() {
        let broken = session([
            AgentTurn(role: .assistant, content: [
                .toolUse(id: "answered", name: "read_file", input: .object([:])),
                .toolUse(id: "stranded", name: "edit_file", input: .object([:])),
            ]),
            AgentTurn(role: .user, content: [.toolResult(toolUseId: "answered", content: "ok", isError: false)]),
        ])
        let repaired = AgentSessionStore.repairingDanglingToolUses(broken)
        XCTAssertEqual(toolResultIds(repaired!).sorted(), ["answered", "stranded"])
        XCTAssertEqual(toolResultIds(repaired!).filter { $0 == "answered" }.count, 1, "must not duplicate an existing result")
    }

    /// Healthy sessions must be left completely alone — no rewrite, no spurious save.
    func testHealthySessionNeedsNoRepair() {
        let healthy = session([
            AgentTurn(role: .user, content: [.text("read it")]),
            AgentTurn(role: .assistant, content: [.toolUse(id: "call_1", name: "read_file", input: .object([:]))]),
            AgentTurn(role: .user, content: [.toolResult(toolUseId: "call_1", content: "contents", isError: false)]),
            AgentTurn(role: .assistant, content: [.text("here's what it says")]),
        ])
        XCTAssertNil(AgentSessionStore.repairingDanglingToolUses(healthy))
    }

    func testPlainConversationNeedsNoRepair() {
        let plain = session([
            AgentTurn(role: .user, content: [.text("hello")]),
            AgentTurn(role: .assistant, content: [.text("hi")]),
        ])
        XCTAssertNil(AgentSessionStore.repairingDanglingToolUses(plain))
        XCTAssertNil(AgentSessionStore.repairingDanglingToolUses(session([])))
    }

    /// Repairing must be a fixed point — running it on its own output changes nothing.
    func testRepairIsIdempotent() {
        let broken = session([
            AgentTurn(role: .assistant, content: [.toolUse(id: "call_1", name: "edit_file", input: .object([:]))]),
        ])
        let once = AgentSessionStore.repairingDanglingToolUses(broken)!
        XCTAssertNil(AgentSessionStore.repairingDanglingToolUses(once))
    }
}
