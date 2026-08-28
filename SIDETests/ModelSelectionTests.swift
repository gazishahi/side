import XCTest
@testable import Side

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

    func testHigherEffortMeansABiggerThinkingBudget() {
        let budgets = [AgentEffort.low, .medium, .high].map { $0.anthropicThinkingBudget ?? 0 }
        XCTAssertEqual(budgets, budgets.sorted())
        XCTAssertGreaterThan(budgets[0], 0)
    }

    func testThinkingBudgetAlwaysLeavesRoomForTheAnswer() {
        // The API enforces budget_tokens < max_tokens, so a budget at or above Side's base
        // ceiling has to raise the ceiling rather than produce a rejected request.
        for effort in AgentEffort.allCases {
            let maxTokens = effort.anthropicMaxTokens(base: 8_192)
            guard let budget = effort.anthropicThinkingBudget else {
                XCTAssertEqual(maxTokens, 8_192, "standard shouldn't move the ceiling")
                continue
            }
            XCTAssertGreaterThan(maxTokens, budget, "\(effort) leaves no room for output")
        }
    }

    func testOpenAIEffortNamesMatchTheWireVocabulary() {
        XCTAssertEqual(AgentEffort.low.openAIReasoningEffort, "low")
        XCTAssertEqual(AgentEffort.medium.openAIReasoningEffort, "medium")
        XCTAssertEqual(AgentEffort.high.openAIReasoningEffort, "high")
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

    func testAdaptiveEffortNamesAreDistinctFromBudgets() {
        XCTAssertEqual(AgentEffort.high.anthropicOutputEffort, "high")
        XCTAssertNil(AgentEffort.standard.anthropicOutputEffort)
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

    func testTracksWrittenBeforeThisFeatureStillLoad() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let legacy = """
        {"id":"\(UUID().uuidString)","intent":"old track","branchName":"legacy","status":"active",
         "createdAt":"2026-01-01T00:00:00Z","lastActiveAt":"2026-01-02T00:00:00Z"}
        """
        let track = try decoder.decode(Track.self, from: Data(legacy.utf8))
        XCTAssertEqual(track.branchName, "legacy")
        XCTAssertNil(track.modelId)
        XCTAssertNil(track.effort)
    }

    // MARK: - Adapter resolution

    func testResolvingAModelWithinAProvider() {
        let registry = ProviderRegistryStore.shared
        guard let anthropic = registry.provider(for: "anthropic"), anthropic.models.count > 1 else {
            return XCTFail("expected the built-in Anthropic provider to offer several models")
        }
        let target = anthropic.models.first { $0.id != anthropic.defaultModelId }!

        guard case .ready(_, _, let model) = registry.resolveAdapter(providerId: "anthropic", modelId: target.id, effort: .high) else {
            // A missing key resolves to .missingAPIKey, which is a legitimate environment for
            // this test to run in — skip rather than fail on the tester's key setup.
            return
        }
        XCTAssertEqual(model.id, target.id)
    }

    func testAStaleModelIdFallsBackInsteadOfBrickingTheTrack() {
        let registry = ProviderRegistryStore.shared
        guard case .ready(_, let definition, let model) = registry.resolveAdapter(
            providerId: "anthropic", modelId: "claude-model-that-was-removed", effort: .standard
        ) else { return }
        // A model removed upstream (or from a BYOK list) must not leave the track unable to send.
        XCTAssertEqual(model.id, definition.defaultModelId)
    }
}
