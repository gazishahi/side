import XCTest
@testable import Side
@testable import Heron
@testable import SideAgents

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

    func testRowPairing() {
        // Removed and added runs pair up row by row; the shorter side gets blanks. `+A` then `-b`
        // is a shape git never emits within one change, but a parser might; it must not pair b
        // with A — the addition flushes first, then the removal begins its own run.
        let cases: [(name: String, hunk: String, rows: [String])] = [
            ("one-line edit: old left, new right", "@@ -1,3 +1,3 @@\n a\n-b\n+B\n c", ["H", " a |  a", "-b | +B", " c |  c"]),
            ("unequal runs leave blanks on the shorter side", "@@ -1,2 +1,3 @@\n-a\n-b\n+A\n+B\n+C", ["H", "-a | +A", "-b | +B", "· | +C"]),
            ("pure addition sits right with blanks left", "@@ -1,1 +1,3 @@\n x\n+y\n+z", ["H", " x |  x", "· | +y", "· | +z"]),
            ("pure removal sits left with blanks right", "@@ -1,3 +1,1 @@\n x\n-y\n-z", ["H", " x |  x", "-y | ·", "-z | ·"]),
            ("a removal after additions starts a new change", "@@ -1,2 +1,2 @@\n+A\n-b\n+B", ["H", "· | +A", "-b | +B"]),
        ]
        for row in cases {
            XCTAssertEqual(describe(SideBySideRows.build(hunk(row.hunk))), row.rows, row.name)
        }
    }

    func testBothColumnsHaveTheSameRowCount() {
        let rows = SideBySideRows.build(hunk("@@ -1,5 +1,4 @@\n a\n-b\n-c\n+B\n d\n-e\n+E\n+F"))
        // Every row renders one line per column, so equal row count is equal height.
        let left = DiffBody.attributedColumn(rows: rows, side: .left).string.components(separatedBy: "\n").count
        let right = DiffBody.attributedColumn(rows: rows, side: .right).string.components(separatedBy: "\n").count
        XCTAssertEqual(left, right)
        XCTAssertEqual(left, rows.count + 1)  // trailing newline
    }

    func testColumnRendering() {
        // The hunk header renders in the left column only, and each column carries its own
        // line numbers.
        let rows = SideBySideRows.build(hunk("@@ -10,1 +20,1 @@\n-a\n+b"))
        let left = DiffBody.attributedColumn(rows: rows, side: .left).string
        let right = DiffBody.attributedColumn(rows: rows, side: .right).string
        XCTAssertTrue(left.contains("@@ -10,1 +20,1 @@"), left)
        XCTAssertFalse(right.contains("@@"), right)
        XCTAssertTrue(left.contains("10  a"), left)
        XCTAssertTrue(right.contains("20  b"), right)
    }

    @MainActor
    func testASplitCardBuildsAndKeepsColumnsAligned() {
        let file = UnifiedDiff.parse("diff --git a/x b/x\n@@ -1,3 +1,3 @@\n a\n-b\n+B\n c").files[0]
        let card = DiffFileCardView(file: file, layout: .sideBySide)
        card.frame = NSRect(x: 0, y: 0, width: 800, height: 300)
        card.layoutSubtreeIfNeeded()
        let columns = card.subviews.flatMap { [$0] + $0.subviews }.compactMap { ($0 as? NSScrollView)?.documentView as? SideBySideDocumentView }.first
        XCTAssertNotNil(columns, "split layout did not produce a two-column document")
        let texts = columns?.subviews.compactMap { $0 as? NSTextView } ?? []
        XCTAssertEqual(texts.count, 2)
        XCTAssertEqual(texts.first?.string.components(separatedBy: "\n").count, texts.last?.string.components(separatedBy: "\n").count)
    }
}
