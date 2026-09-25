import AlloyAppKit
import Heron
import XCTest
@testable import Side

/// Review's layout (SIDE_RFC_FIND_REVIEW_TRACKS.md, R1): the checkpoint timeline, viewed marks,
/// and the diff's folding and sticky headers that the file list drives.
@MainActor
final class ReviewLayoutTests: XCTestCase {
    private func checkpoint(_ intent: String, sha: String?, passed: Bool? = nil) -> Checkpoint {
        var c = Checkpoint(trackKey: "t", agentSessionId: UUID(), declaredIntent: intent, changedFilePaths: [], commandsRun: [],
                           provenance: AgentProvenance(providerId: "p", modelId: "m", instructionSourceSummary: ""), gitCommitSHA: sha)
        if let passed { c.verification = CheckpointVerification(taskName: "test", command: "t", exitCode: passed ? 0 : 1, output: "") }
        return c
    }

    private func timeline(tip: String? = "ccc") -> CheckpointTimeline {
        CheckpointTimeline.build(baseRef: "main", branch: "feature", checkpoints: [
            (checkpoint("one", sha: "aaa"), 1), (checkpoint("no commit", sha: nil), 2),
            (checkpoint("three", sha: "bbb", passed: true), 3), (checkpoint("four", sha: "ccc", passed: false), 4),
        ], tipSHA: tip)
    }

    // MARK: Timeline

    func testTimelineIsBaseThenCommittedCheckpointsThenNowOnlyWhenTheTipMoved() {
        let t = timeline()
        XCTAssertEqual(t.nodes.map(\.ref), ["main", "aaa", "bbb", "ccc"], "a checkpoint without a commit has nothing to diff")
        XCTAssertEqual(t.nodes.map(\.verification), [nil, nil, true, false])
        XCTAssertTrue(t.isEverything)
        XCTAssertEqual(t.refs.from, "main")
        XCTAssertEqual(t.refs.to, "ccc")

        let moved = timeline(tip: "ddd")
        XCTAssertEqual(moved.nodes.last?.kind, .now)
        XCTAssertEqual(moved.refs.to, "feature", "everything runs to the branch, past the newest checkpoint")

        let none = CheckpointTimeline.build(baseRef: "main", branch: "feature", checkpoints: [], tipSHA: "x")
        XCTAssertEqual(none.nodes.map(\.ref), ["main", "feature"])
        XCTAssertTrue(none.isEverything)
    }

    func testSelectingACheckpointShowsWhatItAloneChanged() {
        var t = timeline()
        t.select(2)
        XCTAssertEqual(t.refs.from, "aaa")
        XCTAssertEqual(t.refs.to, "bbb")
        XCTAssertEqual(t.single?.title, "three")
        XCTAssertEqual(CheckpointTimelineView.describe(t), "Changes in checkpoint 3")

        t.select(3, extending: true)
        XCTAssertEqual(t.refs.from, "aaa")
        XCTAssertEqual(t.refs.to, "ccc")
        XCTAssertNil(t.single)
        XCTAssertEqual(CheckpointTimelineView.describe(t), "Changes from checkpoint 1 to checkpoint 4")

        t.select(from: 3, to: 0)
        XCTAssertTrue(t.isEverything)
        t.select(1)
        t.select(0)
        XCTAssertTrue(t.isEverything, "the base means everything")
    }

    func testArrowKeysStepAndExtend() {
        var t = timeline()
        t.step(-1)
        XCTAssertEqual(t.single?.ref, "ccc", "from everything, ← starts at the newest")
        t.step(-1)
        XCTAssertEqual(t.single?.ref, "bbb")
        t.step(-5)
        XCTAssertEqual(t.single?.ref, "aaa", "stops at the first checkpoint")
        t.step(1, extending: true)
        XCTAssertEqual(t.refs.from, "main")
        XCTAssertEqual(t.refs.to, "bbb")
        t.selectEverything()
        XCTAssertTrue(t.isEverything)
    }

    func testARebuiltTimelineKeepsTheChosenRange() {
        var old = timeline()
        old.select(2)
        var rebuilt = timeline(tip: "ddd")
        rebuilt.keepSelection(of: old)
        XCTAssertEqual(rebuilt.single?.ref, "bbb")
        var fresh = timeline()
        fresh.keepSelection(of: CheckpointTimeline(nodes: []))
        XCTAssertTrue(fresh.isEverything, "an empty old timeline (the first load) keeps nothing")
    }

    func testTheOldestNodesFoldBehindAnEllipsisWhenNarrow() {
        let wide = CheckpointTimelineView.positions(count: 5, width: 400)
        XCTAssertEqual(wide.map(\.index), [0, 1, 2, 3, 4])
        let narrow = CheckpointTimelineView.positions(count: 60, width: 300)
        XCTAssertEqual(narrow.first?.index, 0, "the base stays")
        XCTAssertEqual(narrow.last?.index, 59, "the newest stay")
        XCTAssertLessThan(narrow.count, 60)
        XCTAssertLessThanOrEqual(narrow.last!.x, 300)
    }

    // MARK: Viewed

    func testViewedHoldsUntilTheFilesDiffChanges() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "review-viewed-\(UUID().uuidString)"))
        let store = ReviewViewedStore(defaults: defaults)
        let before = UnifiedDiff.parse("diff --git a/a.swift b/a.swift\n--- a/a.swift\n+++ b/a.swift\n@@ -1,1 +1,1 @@\n-x\n+y").files[0]
        let after = UnifiedDiff.parse("diff --git a/a.swift b/a.swift\n--- a/a.swift\n+++ b/a.swift\n@@ -1,1 +1,1 @@\n-x\n+z").files[0]
        XCTAssertFalse(store.isViewed(before, track: "t"))
        store.set(true, before, track: "t")
        XCTAssertTrue(store.isViewed(before, track: "t"))
        XCTAssertFalse(store.isViewed(before, track: "other"), "per track")
        XCTAssertFalse(store.isViewed(after, track: "t"), "the agent changed it again: not what was seen")
        store.set(false, before, track: "t")
        XCTAssertFalse(store.isViewed(before, track: "t"))
    }

    func testSummaryIsTheAgentsWordsWithoutMarkdown() {
        let text = ReviewWorkspaceViewController.plainText(fromMarkdown: "## Done\n\nAdded **isEmpty** to `Rope`.\n\n\n- one\n```swift\nlet x = 1\n```")
        XCTAssertEqual(text, "Done\n\nAdded isEmpty to Rope.\n\n- one\nlet x = 1")
    }

    // MARK: The diff, driven by the list

    private let diff = (0..<6).map { i in
        "diff --git a/f\(i).swift b/f\(i).swift\n--- a/f\(i).swift\n+++ b/f\(i).swift\n@@ -1,30 +1,30 @@\n" +
            (0..<30).map { " let line\($0) = \(i)" }.joined(separator: "\n")
    }.joined(separator: "\n")

    private func makeDiffView() -> (NSWindow, DiffDocumentView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = DiffDocumentView()
        view.diffLayout = .unified
        window.contentView = NSView()
        window.contentView!.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: window.contentView!.topAnchor), view.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor), view.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
        ])
        window.orderFront(nil)
        return (window, view)
    }

    private func settle(_ window: NSWindow) {
        window.layoutIfNeeded()
        let deadline = Date().addingTimeInterval(0.1)
        while Date() < deadline { autoreleasepool { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) } }
    }

    func testScrollingToAFileAndTheHeaderThatStaysOnTop() throws {
        let (window, view) = makeDiffView()
        defer { window.close() }
        var tops: [Int] = []
        view.onTopFileChange = { tops.append($0) }
        view.render(diffText: diff)
        settle(window)
        view.scrollToFile(3)
        settle(window)
        XCTAssertEqual(tops.last, 3)
        XCTAssertEqual(view.headerFramesForTesting[3]?.minY ?? -1, 0, accuracy: 0.5, "the file's header at the top")

        // Halfway into file 3: its header stays pinned at the top.
        let editor = try XCTUnwrap(view.editors.first)
        editor.scrollY += editor.documentLayout.lineHeight * 12
        settle(window)
        XCTAssertEqual(view.headerFramesForTesting[3]?.minY ?? -1, 0, accuracy: 0.5)
        XCTAssertEqual(tops.last, 3)
    }

    func testViewedFilesStartFoldedAndFoldingFromOutsideKeepsThePlace() throws {
        let (window, view) = makeDiffView()
        defer { window.close() }
        view.render(diffText: diff) { _ in [1] }
        settle(window)
        XCTAssertTrue(view.isFolded(1))
        let rows = view.rowCount
        view.setFolded(1, false)
        XCTAssertEqual(view.rowCount, rows + 31, "a hunk row and 30 lines back")
        view.scrollToFile(2)
        settle(window)
        view.setFolded(2, true)
        settle(window)
        XCTAssertEqual(view.headerFramesForTesting[2]?.minY ?? -1, 0, accuracy: 0.5, "folding the top file keeps its header where it was")
        var folds: [(Int, Bool)] = []
        view.onFoldChange = { folds.append(($0, $1)) }
        view.toggleFoldForTesting(0)
        XCTAssertEqual(folds.first?.0, 0)
        XCTAssertEqual(folds.first?.1, true)
    }

    func testRailCountsViewedAndFollowsWithoutEchoing() {
        let rail = ReviewFileRail()
        rail.frame = NSRect(x: 0, y: 0, width: ReviewFileRail.width, height: 400)
        var selected: [Int] = []
        rail.onSelect = { selected.append($0) }
        rail.items = (0..<5).map { ReviewFileRail.Item(path: "Sources/f\($0).swift", added: 1, removed: 0, isNew: false, isDeleted: false, viewed: $0 == 1) }
        XCTAssertEqual(rail.progressText, "1 of 5 viewed")
        rail.follow(3)
        XCTAssertEqual(rail.selectedIndex, 3)
        XCTAssertTrue(selected.isEmpty, "following the diff doesn't move the diff")
        rail.tableForTesting.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        XCTAssertEqual(selected, [2])
        rail.items[4].viewed = true
        XCTAssertEqual(rail.progressText, "2 of 5 viewed")
    }
}
