import XCTest
@testable import Side
@testable import Heron
@testable import SideAgents

@MainActor
final class ModelSelectionTests: XCTestCase {

    // MARK: - Effort → provider wire format

    func testStandardEffortSendsNothingExtra() {
        // "No thinking" has to mean the field is absent: Anthropic rejects a budget below its
        // minimum, and OpenAI-compatible servers (every local one included) 400 on an unknown
        // field. A zero-valued knob would break both.
        XCTAssertNil(AgentEffort.standard.anthropicThinkingBudget)
        XCTAssertNil(AgentEffort.standard.openAIReasoningEffort)
    }

    func testEachEffortLevelHasAConsistentWireFormat() {
        // Higher effort means a bigger thinking budget; the API enforces budget_tokens <
        // max_tokens, so a budget at or above Side's base ceiling has to raise the ceiling rather
        // than produce a rejected request; and the OpenAI names must match the wire vocabulary.
        // The Claude 5 adaptive form uses effort names too, distinct from budgets.
        let table: [(effort: AgentEffort, openAI: String?)] = [
            (.standard, nil),
            (.low, "low"),
            (.medium, "medium"),
            (.high, "high"),
        ]
        XCTAssertEqual(Set(table.map(\.effort)), Set(AgentEffort.allCases), "every effort level needs a row")

        var previousBudget = 0
        for row in table {
            XCTAssertEqual(row.effort.openAIReasoningEffort, row.openAI, "\(row.effort) OpenAI reasoning_effort")
            let maxTokens = row.effort.anthropicMaxTokens(base: 8_192)
            guard let budget = row.effort.anthropicThinkingBudget else {
                XCTAssertEqual(maxTokens, 8_192, "\(row.effort) shouldn't move the ceiling")
                continue
            }
            XCTAssertGreaterThan(budget, 0, "\(row.effort) has no thinking budget")
            XCTAssertGreaterThanOrEqual(budget, previousBudget, "\(row.effort) budget is smaller than the level below it")
            XCTAssertGreaterThan(maxTokens, budget, "\(row.effort) leaves no room for output")
            previousBudget = budget
        }

        XCTAssertEqual(AgentEffort.high.anthropicOutputEffort, "high")
        XCTAssertNil(AgentEffort.standard.anthropicOutputEffort)
    }

    func testClaude5ModelsUseAdaptiveThinkingAndOlderOnesUseABudget() {
        // Found by a rejected live request, not by reading docs: Claude 5 refuses
        // `thinking.type.enabled` and asks for `thinking.type.adaptive` +
        // `output_config.effort`, while 4.x only knows the budget form. Both shapes stay.
        XCTAssertTrue(AnthropicMessagesProvider.usesAdaptiveThinking(modelId: "claude-opus-5"))
        XCTAssertTrue(AnthropicMessagesProvider.usesAdaptiveThinking(modelId: "claude-sonnet-5"))
        XCTAssertFalse(AnthropicMessagesProvider.usesAdaptiveThinking(modelId: "claude-haiku-4-5-20251001"))
        // Dated variants of a 5-series model must still take the adaptive path.
        XCTAssertTrue(AnthropicMessagesProvider.usesAdaptiveThinking(modelId: "claude-opus-5-20260401"))
    }

    // MARK: - Per-track persistence

    /// Seeds `tracks.json` directly rather than going through `createTrack`, which does real git
    /// work (branch + worktree) this test has no use for.
    private func makeStore(trackKeys: [String]) throws -> (TrackStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("model-sel-\(UUID().uuidString)")
        let stateDirectory = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let tracks = trackKeys.map { Track(intent: "work on \($0)", branchName: $0) }
        JSONStore.write(tracks, to: stateDirectory.appendingPathComponent("tracks.json"))
        return (TrackStore(projectRoot: root, stateDirectory: stateDirectory), root)
    }

    func testSelectionIsPerTrackAndSurvivesReload() throws {
        let (store, root) = try makeStore(trackKeys: ["fast", "deep"])
        defer { try? FileManager.default.removeItem(at: root) }
        let stateDirectory = root.appendingPathComponent("state")

        store.setModelSelection(providerId: "anthropic", modelId: "claude-haiku-4-5-20251001", effort: .standard, for: "fast")
        store.setModelSelection(providerId: "anthropic", modelId: "claude-opus-5", effort: .high, for: "deep")

        let reloaded = TrackStore(projectRoot: root, stateDirectory: stateDirectory)
        XCTAssertEqual(reloaded.modelSelection(forTrackKey: "fast").modelId, "claude-haiku-4-5-20251001")
        XCTAssertEqual(reloaded.modelSelection(forTrackKey: "deep").modelId, "claude-opus-5")
        // The whole point of per-track: two tracks, two models, at the same time.
        XCTAssertEqual(reloaded.modelSelection(forTrackKey: "deep").effort, .high)
        XCTAssertEqual(reloaded.modelSelection(forTrackKey: "fast").effort, .standard)
    }

    func testClearingASelectionReturnsTheTrackToTheAppDefault() throws {
        let (store, root) = try makeStore(trackKeys: ["main"])
        defer { try? FileManager.default.removeItem(at: root) }
        store.setModelSelection(providerId: "anthropic", modelId: "claude-opus-5", effort: .high, for: "main")

        store.setModelSelection(providerId: nil, modelId: nil, effort: nil, for: "main")

        let selection = store.modelSelection(forTrackKey: "main")
        // nil, not "whatever the default is today" — so a later change in Settings still moves
        // this track.
        XCTAssertNil(selection.providerId)
        XCTAssertNil(selection.modelId)
        XCTAssertNil(selection.effort)
    }
}
