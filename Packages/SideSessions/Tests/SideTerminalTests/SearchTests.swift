import SideTerminal
import XCTest

final class SearchTests: XCTestCase {
    /// Matches on screen and in the scrollback; ASCII ignores case; the viewport's matches are
    /// cells to draw, a match that wraps covering both rows.
    func testFindsMatchesAndTheirCells() throws {
        let terminal = try Terminal(columns: 10, rows: 3)
        terminal.feed(Array("needle one\r\nhay\r\nhay\r\nhay\r\nxx NEEDLE\r\nzzzzzzneedle\r\nend".utf8))
        let search = TerminalSearch(terminal: terminal)
        search.needle = "needle"
        XCTAssertEqual(search.total, 3, "two on screen, one in the scrollback")
        XCTAssertNil(search.selectedNumber, "nothing selected yet")

        let (matches, selected) = search.viewportMatches()
        XCTAssertEqual(selected, [])
        // The viewport is "zzzzzzneed", "le" (the same line, wrapped) and "end": only the wrapped
        // match is in view, covering both rows. ("xx NEEDLE" is just above, in the scrollback.)
        XCTAssertEqual(matches, [[.init(row: 0, columns: 6...9), .init(row: 1, columns: 0...1)]])
        terminal.scroll(byRows: -1)
        search.refresh()
        XCTAssertTrue(search.viewportMatches().matches.contains([.init(row: 0, columns: 3...8)]), "scrolled up one row: \(search.viewportMatches().matches)")
    }

    /// Next goes up, toward older text, and scrolls there; previous comes back down.
    func testNextAndPreviousSelectAndScroll() throws {
        let terminal = try Terminal(columns: 20, rows: 3)
        terminal.feed(Array("old match\r\n1\r\n2\r\n3\r\n4\r\nnew match\r\n$ ".utf8))
        let search = TerminalSearch(terminal: terminal)
        let reader = ScreenReader(terminal: terminal)
        _ = reader.update()
        search.needle = "match"
        XCTAssertEqual(search.total, 2)
        search.next()
        XCTAssertEqual(search.selectedNumber, 1, "the newest first")
        XCTAssertEqual(search.viewportMatches().selected.first?.row, 1)
        search.next()
        XCTAssertEqual(search.selectedNumber, 2)
        XCTAssertEqual(search.viewportMatches().selected, [.init(row: 0, columns: 4...8)], "scrolled up to it")
        XCTAssertTrue(terminal.scrollbar.isScrolledBack, "the viewport isn't at the bottom")
        // The screen reads again after the scroll, so what's drawn follows the match.
        XCTAssertTrue(reader.update(), "the scroll marks the screen changed")
        var top = ""
        reader.forEachChangedRow { y, cells in if y == 0 { top = String(String.UnicodeScalarView(cells.compactMap { UnicodeScalar($0.scalar) })) } }
        XCTAssertTrue(top.hasPrefix("old match"), top)
        search.previous()
        XCTAssertEqual(search.selectedNumber, 1)
    }

    /// New output is searched once refreshed; an empty needle finds nothing.
    func testRefreshAndClear() throws {
        let terminal = try Terminal(columns: 20, rows: 3)
        let search = TerminalSearch(terminal: terminal)
        search.needle = "later"
        XCTAssertEqual(search.total, 0)
        terminal.feed(Array("later\r\n".utf8))
        search.refresh()
        XCTAssertEqual(search.total, 1)
        search.needle = ""
        XCTAssertEqual(search.total, 0)
        XCTAssertTrue(search.viewportMatches().matches.isEmpty)
    }
}
