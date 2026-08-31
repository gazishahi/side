import XCTest
@testable import Side

/// Capturing the model's reasoning off the wire.
///
/// The parser is the component here most able to fail silently: a renamed field in a provider's
/// event shape doesn't crash, it just means the agent stops explaining itself and nobody can say
/// when that started.
final class ThinkingStreamTests: XCTestCase {

    private func events(_ payloads: [String]) -> [AgentStreamEvent] {
        let state = AnthropicMessagesProvider.TurnState()
        var captured: [AgentStreamEvent] = []
        for payload in payloads {
            AnthropicMessagesProvider.handle(sse: SSEEvent(event: nil, data: payload), state: state) {
                captured.append($0)
            }
        }
        return captured
    }

    private func thinking(_ events: [AgentStreamEvent]) -> String {
        events.reduce(into: "") { text, event in
            if case .thinkingDelta(let delta) = event { text += delta }
        }
    }

    private func text(_ events: [AgentStreamEvent]) -> String {
        events.reduce(into: "") { text, event in
            if case .textDelta(let delta) = event { text += delta }
        }
    }

    func testThinkingDeltasAreCaptured() {
        let captured = events([
            #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Let me check "}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"the file first."}}"#,
        ])
        XCTAssertEqual(thinking(captured), "Let me check the file first.")
    }

    func testReasoningAndAnswerStaySeparate() {
        // They arrive interleaved on one stream and must not merge: one goes in the collapsed
        // activity group, the other into the reply bubble.
        let captured = events([
            #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"reasoning"}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"answer"}}"#,
        ])
        XCTAssertEqual(thinking(captured), "reasoning")
        XCTAssertEqual(text(captured), "answer")
    }

    func testASignatureDeltaProducesNothing() {
        // `signature_delta` exists so a thinking block can be passed back intact. Nothing here
        // passes them back, and emitting its opaque blob as reasoning would print noise.
        let captured = events([
            #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"EqQBCgIYAhIA"}}"#,
        ])
        XCTAssertTrue(captured.isEmpty)
    }

    func testAThinkingBlockDoesNotLookLikeAToolCall() {
        // Both arrive via content_block_start; only one has a tool to run.
        let captured = events([
            #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
        ])
        XCTAssertTrue(captured.isEmpty)
    }

    func testAToolCallStillStreamsAlongsideThinking() {
        let captured = events([
            #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"I should edit it"}}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"tu_1","name":"write_file"}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"path\":"}}"#,
            #"{"type":"content_block_stop","index":1}"#,
        ])
        XCTAssertEqual(thinking(captured), "I should edit it")
        XCTAssertTrue(captured.contains { if case .toolUseStart(_, let name) = $0 { return name == "write_file" } else { return false } })
        XCTAssertTrue(captured.contains { if case .toolUseEnd = $0 { return true } else { return false } })
    }

    func testMalformedThinkingIsIgnoredRatherThanCrashing() {
        XCTAssertTrue(events([#"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta"}}"#]).isEmpty)
        XCTAssertTrue(events(["not json at all"]).isEmpty)
    }

    // MARK: - Bounding what gets rendered

    func testShortReasoningIsShownWhole() {
        XCTAssertEqual(ThinkWorkspaceViewController.condensedThinking("  a short thought  "), "a short thought")
    }

    func testBlankLinesAreCollapsed() {
        XCTAssertEqual(ThinkWorkspaceViewController.condensedThinking("one\n\ntwo"), "one\ntwo")
    }

    func testLongReasoningKeepsItsTail() {
        // Reasoning ends where it concluded, and the conclusion is the part worth reading.
        let long = String(repeating: "x", count: 5_000) + "THEREFORE"
        let condensed = ThinkWorkspaceViewController.condensedThinking(long)
        XCTAssertTrue(condensed.hasSuffix("THEREFORE"))
        XCTAssertTrue(condensed.hasPrefix("…"))
        // Bounded: an unbounded label inside a scroll view inside a group drops frames per token.
        XCTAssertLessThan(condensed.count, 2_100)
    }
}
