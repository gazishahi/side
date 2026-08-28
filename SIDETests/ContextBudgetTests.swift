import XCTest
@testable import Side

final class ContextBudgetTests: XCTestCase {

    private func turn(_ role: AgentMessage.Role, text: String) -> AgentTurn {
        AgentTurn(role: role, content: [.text(text)])
    }

    private func toolResultTurn(characters: Int) -> AgentTurn {
        AgentTurn(role: .user, content: [
            .toolResult(toolUseId: "t", content: String(repeating: "x", count: characters), isError: false)
        ])
    }

    // MARK: - Estimation

    func testEstimateGrowsWithTheConversation() {
        let short = [turn(.user, text: "hello")]
        let long = short + [turn(.assistant, text: String(repeating: "a reply ", count: 500))]
        XCTAssertGreaterThan(
            ContextBudget.estimatedTokens(in: long),
            ContextBudget.estimatedTokens(in: short)
        )
    }

    func testToolResultsCountTowardTheEstimate() {
        // A single read_file can be tens of thousands of characters — an estimate that only
        // counted prose would report a nearly-empty window on a conversation about to fail.
        let withResult = [turn(.user, text: "read it"), toolResultTurn(characters: 40_000)]
        XCTAssertGreaterThan(ContextBudget.estimatedTokens(in: withResult), 9_000)
    }

    func testImagesCountTowardTheEstimate() {
        // Priced by pixels server-side; the estimate charges a flat figure per image so the
        // gauge moves when screenshots pile up.
        let withImage = [AgentTurn(role: .user, content: [.image(mediaType: "image/png", base64: "aGk=")])]
        XCTAssertGreaterThan(ContextBudget.estimatedTokens(in: withImage), 1_000)
    }

    func testImageBlocksSurviveAPersistenceRoundTrip() throws {
        let turn = AgentTurn(role: .user, content: [
            .image(mediaType: "image/jpeg", base64: "c2NyZWVuc2hvdA=="),
            .text("what's wrong with this UI?"),
        ])
        let decoded = try JSONDecoder().decode(AgentTurn.self, from: JSONEncoder().encode(turn))
        guard case .image(let mediaType, let base64) = decoded.content.first else {
            return XCTFail("image block lost in round trip")
        }
        XCTAssertEqual(mediaType, "image/jpeg")
        XCTAssertEqual(base64, "c2NyZWVuc2hvdA==")
    }

    func testEmptyConversationCostsNothing() {
        XCTAssertEqual(ContextBudget.estimatedTokens(in: []), 0)
    }

    // MARK: - Thresholds

    func testStatusCrossesAtTheDocumentedFractions() {
        let window = 100_000
        func status(atFraction fraction: Double) -> ContextBudget.Status {
            ContextBudget.usage(turns: [], windowTokens: window, lastReportedInputTokens: Int(Double(window) * fraction)).status
        }
        XCTAssertEqual(status(atFraction: 0.5), .comfortable)
        XCTAssertEqual(status(atFraction: 0.69), .comfortable)
        XCTAssertEqual(status(atFraction: 0.70), .approaching)
        XCTAssertEqual(status(atFraction: 0.89), .approaching)
        XCTAssertEqual(status(atFraction: 0.90), .critical)
        XCTAssertEqual(status(atFraction: 1.5), .critical)
    }

    func testFractionIsClampedSoTheGaugeCantExceedFull() {
        let usage = ContextBudget.usage(turns: [], windowTokens: 1_000, lastReportedInputTokens: 5_000)
        XCTAssertEqual(usage.fraction, 1)
    }

    func testOnlyNonComfortableStatusesSuggestCompaction() {
        XCTAssertFalse(ContextBudget.Status.comfortable.shouldSuggestCompaction)
        XCTAssertTrue(ContextBudget.Status.approaching.shouldSuggestCompaction)
        XCTAssertTrue(ContextBudget.Status.critical.shouldSuggestCompaction)
    }

    // MARK: - Measured vs estimated

    func testAReportedCountBeatsALowerEstimate() {
        // The provider's own number is measured; the estimate is arithmetic on character counts.
        // Prompt-cache and system-prompt overhead mean the real figure is usually higher.
        let turns = [turn(.user, text: "hi")]
        let usage = ContextBudget.usage(turns: turns, windowTokens: 200_000, lastReportedInputTokens: 50_000)
        XCTAssertEqual(usage.usedTokens, 50_000)
    }

    func testTurnsAddedSinceTheLastRequestArentInvisible() {
        // The measured count describes the *previous* request. A huge tool result arriving after
        // it has to move the gauge, or the warning comes too late to be useful.
        let turns = [turn(.user, text: "read it"), toolResultTurn(characters: 800_000)]
        let usage = ContextBudget.usage(turns: turns, windowTokens: 200_000, lastReportedInputTokens: 1_000)
        XCTAssertGreaterThan(usage.usedTokens, 1_000)
        XCTAssertEqual(usage.status, .critical)
    }

    func testAnUnknownWindowDoesNotProduceAFalseWarning() {
        // A BYOK provider can report 0; claiming "critical" on no information would train people
        // to ignore the gauge.
        let usage = ContextBudget.usage(turns: [turn(.user, text: "hello")], windowTokens: 0, lastReportedInputTokens: nil)
        XCTAssertEqual(usage.status, .comfortable)
        XCTAssertEqual(usage.fraction, 0)
    }

    // MARK: - The summary contract

    func testCompactionInstructionAsksForWhatAContinuationNeeds() {
        let instruction = ContextBudget.compactionInstruction.lowercased()
        for expected in ["decisions", "paths", "unfinished"] {
            XCTAssertTrue(instruction.contains(expected), "missing \(expected)")
        }
        // Re-inlining file contents into the summary would defeat the point of compacting.
        XCTAssertTrue(instruction.contains("leave out"), instruction)
    }

    func testSummaryTurnSaysDetailIsGone() {
        let text = ContextBudget.summaryTurnText("Fixed the off-by-one in sumRange.")
        XCTAssertTrue(text.contains("Fixed the off-by-one in sumRange."))
        // The next turn has to know it's reading a summary, not the conversation — otherwise the
        // agent asserts things it no longer actually knows.
        XCTAssertTrue(text.lowercased().contains("compacted"))
        XCTAssertTrue(text.lowercased().contains("re-read"))
    }
}

/// Compaction replaces a conversation wholesale. These cover the store-level contract it relies
/// on — anything less and a half-written replacement could leave a conversation the API rejects.
final class ConversationCompactionTests: XCTestCase {
    private var stateDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        stateDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("compact-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: stateDirectory)
        super.tearDown()
    }

    func testReplacingTurnsPersistsAndSurvivesReload() {
        let store = AgentSessionStore(stateDirectory: stateDirectory)
        store.appendTurn(AgentTurn(role: .user, content: [.text("first")]), trackKey: "main", providerId: "anthropic", modelId: "claude-sonnet-5")
        store.appendTurn(AgentTurn(role: .assistant, content: [.text("second")]), trackKey: "main", providerId: "anthropic", modelId: "claude-sonnet-5")

        let summary = AgentTurn(role: .user, content: [.text(ContextBudget.summaryTurnText("we did things"))])
        store.replaceTurns([summary], trackKey: "main", providerId: "anthropic", modelId: "claude-sonnet-5")

        let reloaded = AgentSessionStore(stateDirectory: stateDirectory)
        let turns = reloaded.session(forTrackKey: "main")?.turns ?? []
        XCTAssertEqual(turns.count, 1)
        XCTAssertTrue(turns.first?.content.first.map { block in
            if case .text(let text) = block { return text.contains("we did things") } else { return false }
        } ?? false)
    }

    func testCompactedConversationHasNoDanglingToolUse() {
        let store = AgentSessionStore(stateDirectory: stateDirectory)
        // A conversation caught mid-tool-call: the assistant asked, nothing answered yet.
        store.appendTurn(AgentTurn(role: .user, content: [.text("read it")]), trackKey: "main", providerId: "anthropic", modelId: "claude-sonnet-5")
        store.appendTurn(AgentTurn(role: .assistant, content: [
            .toolUse(id: "tool1", name: "read_file", input: .object(["path": .string("a.swift")]))
        ]), trackKey: "main", providerId: "anthropic", modelId: "claude-sonnet-5")

        let summary = AgentTurn(role: .user, content: [.text(ContextBudget.summaryTurnText("read a.swift"))])
        let session = store.replaceTurns([summary], trackKey: "main", providerId: "anthropic", modelId: "claude-sonnet-5")

        // Replacing *everything* (rather than keeping a tail of recent turns) is what guarantees
        // this: an unanswered tool_use is a protocol violation the API rejects outright, and a
        // tail-preserving compaction could easily cut between a call and its result.
        XCTAssertNil(AgentSessionStore.repairingDanglingToolUses(session), "compaction left a tool_use needing repair")
        XCTAssertEqual(session.turns.count, 1)
    }

    func testCompactionShrinksTheEstimate() {
        let big = (0..<40).map { index in
            AgentTurn(role: .user, content: [
                .toolResult(toolUseId: "t\(index)", content: String(repeating: "x", count: 5_000), isError: false)
            ])
        }
        let compacted = [AgentTurn(role: .user, content: [.text(ContextBudget.summaryTurnText("summary"))])]
        XCTAssertLessThan(
            ContextBudget.estimatedTokens(in: compacted),
            ContextBudget.estimatedTokens(in: big) / 10
        )
    }
}
