import SideTerminal
import XCTest

final class ScrollbackTests: XCTestCase {
    func testScrollingBackAndToTheBottom() throws {
        let terminal = try Terminal(columns: 20, rows: 5)
        terminal.feed(Array((1...30).map { "line \($0)" }.joined(separator: "\r\n").utf8))
        let reader = ScreenReader(terminal: terminal)
        XCTAssertTrue(reader.update())
        var bar = terminal.scrollbar
        XCTAssertEqual(bar.total, 30)
        XCTAssertEqual(bar.length, 5)
        XCTAssertFalse(bar.isScrolledBack)

        terminal.scroll(byRows: -10)
        bar = terminal.scrollbar
        XCTAssertTrue(bar.isScrolledBack)
        XCTAssertEqual(bar.offset, 15)
        XCTAssertTrue(reader.update())
        var top = ""
        reader.forEachChangedRow { y, cells in if y == 0 { top = String(String.UnicodeScalarView(cells.compactMap { $0.scalar == 0 ? nil : UnicodeScalar($0.scalar) })) } }
        XCTAssertEqual(top, "line 16", "the viewport shows older lines")

        terminal.feed(Array("\r\nline 31".utf8))
        XCTAssertTrue(terminal.scrollbar.isScrolledBack, "output doesn't pull a scrolled-back viewport down")
        terminal.scrollToBottom()
        XCTAssertFalse(terminal.scrollbar.isScrolledBack)
        terminal.scroll(toRow: 0)
        XCTAssertEqual(terminal.scrollbar.offset, 0)
    }
}

final class SelectionTests: XCTestCase {
    private let geometry = TerminalSelection.Geometry(columns: 40, cellWidth: 16, screenHeight: 160)

    func testDragSelectsCellsAndMarksThem() throws {
        let terminal = try Terminal(columns: 40, rows: 5)
        terminal.feed(Array("hello world\r\nsecond line".utf8))
        let selection = TerminalSelection(terminal: terminal)
        XCTAssertNil(selection.text)
        selection.press(column: 0, row: 0, x: 2, y: 2, repeatInterval: 0.5, repeatDistance: 4)
        // Past the last cell's middle, which is what takes it in (as in Ghostty).
        selection.drag(column: 4, row: 0, x: 78, y: 2, rectangle: false, geometry: geometry)
        selection.release(column: 4, row: 0)
        XCTAssertEqual(selection.text, "hello")
        let reader = ScreenReader(terminal: terminal)
        XCTAssertTrue(reader.update())
        var selected: [Int] = []
        reader.forEachChangedRow { y, cells in if y == 0 { selected = cells.indices.filter { cells[$0].style.contains(.selected) } } }
        XCTAssertEqual(selected, [0, 1, 2, 3, 4])

        selection.press(column: 20, row: 3, x: 330, y: 100, repeatInterval: 0.5, repeatDistance: 4)
        selection.release(column: 20, row: 3)
        XCTAssertNil(selection.text, "a single click elsewhere clears it")
    }

    func testDoubleAndTripleClicks() throws {
        let terminal = try Terminal(columns: 40, rows: 5)
        terminal.feed(Array("hello world\r\nsecond line".utf8))
        let selection = TerminalSelection(terminal: terminal)
        for _ in 0..<2 {
            selection.press(column: 7, row: 0, x: 120, y: 2, repeatInterval: 0.5, repeatDistance: 4)
            selection.release(column: 7, row: 0)
        }
        XCTAssertEqual(selection.text, "world", "a double click selects the word")
        selection.press(column: 7, row: 0, x: 120, y: 2, repeatInterval: 0.5, repeatDistance: 4)
        selection.release(column: 7, row: 0)
        XCTAssertEqual(selection.text, "hello world", "a triple click, the line")
        selection.selectAll()
        XCTAssertEqual(selection.text, "hello world\nsecond line")
        selection.clear()
        XCTAssertNil(selection.text)
    }
}
