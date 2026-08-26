import XCTest
@testable import Side

final class UsageStoreTests: XCTestCase {
    private var storeURL: URL!

    override func setUp() {
        super.setUp()
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-tests-\(UUID().uuidString)")
            .appendingPathComponent("usage.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent())
        super.tearDown()
    }

    private func makeStore() -> UsageStore { UsageStore(storeURL: storeURL) }

    private func usage(input: Int, output: Int, cached: Int? = nil) -> TokenUsage {
        TokenUsage(inputTokens: input, outputTokens: output, cachedInputTokens: cached)
    }

    func testRepeatedRecordsAccumulateIntoOneRow() {
        let store = makeStore()
        store.record(projectPath: "/p", trackKey: "main", providerId: "anthropic", modelId: "claude-sonnet-5", usage: usage(input: 100, output: 20))
        store.record(projectPath: "/p", trackKey: "main", providerId: "anthropic", modelId: "claude-sonnet-5", usage: usage(input: 50, output: 5, cached: 400))

        XCTAssertEqual(store.records.count, 1)
        let totals = store.totals(projectPath: "/p", trackKey: "main")
        XCTAssertEqual(totals.inputTokens, 150)
        XCTAssertEqual(totals.outputTokens, 25)
        XCTAssertEqual(totals.cachedInputTokens, 400)
        // Every streamed turn is billed, so a second report is a second request even on the
        // same track and model.
        XCTAssertEqual(totals.requestCount, 2)
    }

    func testUsageIsSeparatedByTrackProjectAndModel() {
        let store = makeStore()
        store.record(projectPath: "/a", trackKey: "main", providerId: "anthropic", modelId: "claude-sonnet-5", usage: usage(input: 10, output: 1))
        store.record(projectPath: "/a", trackKey: "feature", providerId: "anthropic", modelId: "claude-sonnet-5", usage: usage(input: 20, output: 2))
        store.record(projectPath: "/b", trackKey: "main", providerId: "anthropic", modelId: "claude-opus-5", usage: usage(input: 40, output: 4))

        XCTAssertEqual(store.records.count, 3)
        XCTAssertEqual(store.totals(projectPath: "/a", trackKey: "main").inputTokens, 10)
        XCTAssertEqual(store.totals(projectPath: "/a", trackKey: "feature").inputTokens, 20)
        XCTAssertEqual(store.totalsByModel().count, 2)
        XCTAssertEqual(store.totalsByProject().count, 2)
        XCTAssertEqual(store.grandTotal().inputTokens, 70)
    }

    func testRemovingATrackDropsOnlyThatTracksUsage() {
        let store = makeStore()
        store.record(projectPath: "/a", trackKey: "main", providerId: "anthropic", modelId: "claude-sonnet-5", usage: usage(input: 10, output: 1))
        store.record(projectPath: "/a", trackKey: "gone", providerId: "anthropic", modelId: "claude-sonnet-5", usage: usage(input: 99, output: 9))

        store.removeUsage(projectPath: "/a", trackKey: "gone")

        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(store.grandTotal().inputTokens, 10)
    }

    func testUsageSurvivesReload() {
        let store = makeStore()
        store.record(projectPath: "/a", trackKey: "main", providerId: "anthropic", modelId: "claude-sonnet-5", usage: usage(input: 1_000, output: 200, cached: 50))

        let reloaded = makeStore()
        let totals = reloaded.totals(projectPath: "/a", trackKey: "main")
        XCTAssertEqual(totals.inputTokens, 1_000)
        XCTAssertEqual(totals.outputTokens, 200)
        XCTAssertEqual(totals.cachedInputTokens, 50)
    }

    func testChangeObserverFiresOnRecordAndStopsAfterRemoval() {
        let store = makeStore()
        var fireCount = 0
        let token = store.addChangeObserver { fireCount += 1 }
        store.record(projectPath: "/a", trackKey: "main", providerId: "anthropic", modelId: "claude-sonnet-5", usage: usage(input: 1, output: 1))
        XCTAssertEqual(fireCount, 1)

        store.removeChangeObserver(token)
        store.record(projectPath: "/a", trackKey: "main", providerId: "anthropic", modelId: "claude-sonnet-5", usage: usage(input: 1, output: 1))
        XCTAssertEqual(fireCount, 1)
    }

    // MARK: - Pricing

    func testCostUsesPublishedRatesAndDiscountsCacheReads() {
        var totals = UsageTotals()
        totals.inputTokens = 1_000_000
        totals.outputTokens = 1_000_000
        totals.cachedInputTokens = 1_000_000

        let cost = ModelPricing.estimatedCost(modelId: "claude-sonnet-5", totals: totals)
        // $3 input + $15 output + $0.30 cached.
        XCTAssertEqual(try XCTUnwrap(cost), 18.3, accuracy: 0.0001)
    }

    func testUnknownModelReportsNoCostRatherThanZero() {
        var totals = UsageTotals()
        totals.inputTokens = 5_000_000
        totals.outputTokens = 5_000_000
        // A guessed price is worse than an honest blank — a local or unrecognized model must
        // come back nil so the UI can show tokens with no figure.
        XCTAssertNil(ModelPricing.estimatedCost(modelId: "some-local-model", totals: totals))
        XCTAssertFalse(ModelPricing.isPriced(modelId: "some-local-model"))
    }

    func testEstimatedCostFlagsUnpricedModelsInTheMix() {
        let store = makeStore()
        store.record(projectPath: "/a", trackKey: "main", providerId: "anthropic", modelId: "claude-sonnet-5", usage: usage(input: 1_000_000, output: 0))
        store.record(projectPath: "/a", trackKey: "main", providerId: "local", modelId: "llama-whatever", usage: usage(input: 9_000_000, output: 9_000_000))

        let estimate = store.estimatedCost()
        XCTAssertEqual(estimate.total, 3.0, accuracy: 0.0001)
        // The unpriced model's tokens are real, so the figure is a floor, not a total — the
        // caller has to be able to say so.
        XCTAssertTrue(estimate.hasUnpricedModels)
    }

    func testTokenFormattingScales() {
        XCTAssertEqual(UsageFormatting.tokens(999), "999")
        XCTAssertEqual(UsageFormatting.tokens(1_500), "1.5K")
        XCTAssertEqual(UsageFormatting.tokens(2_500_000), "2.50M")
    }

    func testSubCentCostReadsAsBelowAPennyNotZero() {
        XCTAssertEqual(UsageFormatting.cost(0.004), "<$0.01")
        XCTAssertEqual(UsageFormatting.cost(0), "$0.00")
        XCTAssertEqual(UsageFormatting.cost(12.5), "$12.50")
    }
}
