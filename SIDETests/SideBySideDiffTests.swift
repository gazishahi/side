import XCTest
@testable import Side

/// Pairing a hunk into two columns.
final class SideBySideRowsTests: XCTestCase {
    private func hunk(_ text: String) -> UnifiedDiff.Hunk {
        UnifiedDiff.parseHunks(text).first!
    }

    private func describe(_ rows: [SideBySideRows.Row]) -> [String] {
        rows.map { row in
            if row.isHeader { return "H" }
            let l = row.left.map { "\($0.kind == .removed ? "-" : " ")\($0.text)" } ?? "·"
            let r = row.right.map { "\($0.kind == .added ? "+" : " ")\($0.text)" } ?? "·"
            return "\(l) | \(r)"
        }
    }

    func testAOneLineEditIsOneRowWithOldLeftAndNewRight() {
        let rows = SideBySideRows.build(hunk("@@ -1,3 +1,3 @@\n a\n-b\n+B\n c"))
        XCTAssertEqual(describe(rows), ["H", " a |  a", "-b | +B", " c |  c"])
    }

    func testUnequalRunsLeaveBlanksOnTheShorterSide() {
        // Two removed, three added: the third addition has nothing opposite it.
        let rows = SideBySideRows.build(hunk("@@ -1,2 +1,3 @@\n-a\n-b\n+A\n+B\n+C"))
        XCTAssertEqual(describe(rows), ["H", "-a | +A", "-b | +B", "· | +C"])
    }

    func testAPureAdditionSitsOnTheRightWithBlanksLeft() {
        let rows = SideBySideRows.build(hunk("@@ -1,1 +1,3 @@\n x\n+y\n+z"))
        XCTAssertEqual(describe(rows), ["H", " x |  x", "· | +y", "· | +z"])
    }

    func testAPureRemovalSitsOnTheLeftWithBlanksRight() {
        let rows = SideBySideRows.build(hunk("@@ -1,3 +1,1 @@\n x\n-y\n-z"))
        XCTAssertEqual(describe(rows), ["H", " x |  x", "-y | ·", "-z | ·"])
    }

    func testARemovalAfterAdditionsStartsANewChange() {
        // `+A` then `-b`: git never emits this within one change, but a parser might; it must not
        // pair b with A. The addition flushes first, then the removal begins its own run.
        let rows = SideBySideRows.build(hunk("@@ -1,2 +1,2 @@\n+A\n-b\n+B"))
        XCTAssertEqual(describe(rows), ["H", "· | +A", "-b | +B"])
    }

    func testBothColumnsHaveTheSameRowCount() {
        let rows = SideBySideRows.build(hunk("@@ -1,5 +1,4 @@\n a\n-b\n-c\n+B\n d\n-e\n+E\n+F"))
        // Every row renders one line per column, so equal row count is equal height.
        let left = DiffBody.attributedColumn(rows: rows, side: .left).string.components(separatedBy: "\n").count
        let right = DiffBody.attributedColumn(rows: rows, side: .right).string.components(separatedBy: "\n").count
        XCTAssertEqual(left, right)
        XCTAssertEqual(left, rows.count + 1)  // trailing newline
    }

    func testTheHeaderTextRendersInTheLeftColumnOnly() {
        let rows = SideBySideRows.build(hunk("@@ -1,1 +1,1 @@\n-a\n+b"))
        XCTAssertTrue(DiffBody.attributedColumn(rows: rows, side: .left).string.contains("@@ -1,1 +1,1 @@"))
        XCTAssertFalse(DiffBody.attributedColumn(rows: rows, side: .right).string.contains("@@"))
    }

    func testEachColumnShowsItsOwnLineNumbers() {
        let rows = SideBySideRows.build(hunk("@@ -10,1 +20,1 @@\n-a\n+b"))
        let left = DiffBody.attributedColumn(rows: rows, side: .left).string
        let right = DiffBody.attributedColumn(rows: rows, side: .right).string
        XCTAssertTrue(left.contains("10  a"), left)
        XCTAssertTrue(right.contains("20  b"), right)
    }

    func testTheLayoutPreferenceRoundTrips() {
        let original = DiffLayout.preferred
        defer { DiffLayout.preferred = original }
        DiffLayout.preferred = .sideBySide
        XCTAssertEqual(DiffLayout.preferred, .sideBySide)
        DiffLayout.preferred = .unified
        XCTAssertEqual(DiffLayout.preferred, .unified)
    }

    @MainActor
    func testASplitCardBuildsAndKeepsColumnsAligned() {
        let file = UnifiedDiff.parse("diff --git a/x b/x\n@@ -1,3 +1,3 @@\n a\n-b\n+B\n c").files[0]
        let card = DiffFileCardView(file: file, layout: .sideBySide)
        card.frame = NSRect(x: 0, y: 0, width: 800, height: 300)
        card.layoutSubtreeIfNeeded()
        let columns = card.subviews.compactMap { ($0 as? NSScrollView)?.documentView as? SideBySideDocumentView }.first
        XCTAssertNotNil(columns, "split layout did not produce a two-column document")
        let texts = columns?.subviews.compactMap { $0 as? NSTextView } ?? []
        XCTAssertEqual(texts.count, 2)
        XCTAssertEqual(texts.first?.string.components(separatedBy: "\n").count, texts.last?.string.components(separatedBy: "\n").count)
    }
}
