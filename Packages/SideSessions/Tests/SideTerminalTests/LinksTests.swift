import SideTerminal
import XCTest

final class LinksTests: XCTestCase {
    func testOSC8Hyperlinks() throws {
        let terminal = try Terminal(columns: 40, rows: 3)
        terminal.feed(Array("see \u{1b}]8;;https://example.com/docs\u{1b}\\the docs\u{1b}]8;;\u{1b}\\ now".utf8))
        XCTAssertEqual(terminal.hyperlink(column: 5, row: 0), "https://example.com/docs")
        XCTAssertNil(terminal.hyperlink(column: 1, row: 0))
    }

    func testURLsAndPathsInPlainText() throws {
        let terminal = try Terminal(columns: 80, rows: 3)
        terminal.feed(Array("open https://github.com/gazishahi/side, then Sources/App/main.swift:12 or $HOME/x".utf8))
        let row = terminal.rowText(0)
        XCTAssertEqual(ImplicitLinks.link(in: row, at: 10), "https://github.com/gazishahi/side", "the trailing comma isn't part of it")
        XCTAssertEqual(ImplicitLinks.link(in: row, at: 50), "Sources/App/main.swift:12")
        XCTAssertNil(ImplicitLinks.link(in: row, at: 2), "plain words aren't links")
    }

    func testColumnsSurviveWideCharacters() throws {
        let terminal = try Terminal(columns: 40, rows: 2)
        terminal.feed(Array("漢字 ./a/b.txt".utf8))
        let row = terminal.rowText(0)
        // 漢 and 字 take two columns each: ./a/b.txt starts at column 5.
        XCTAssertEqual(ImplicitLinks.link(in: row, at: 5), "./a/b.txt")
        XCTAssertEqual(ImplicitLinks.link(in: row, at: 13), "./a/b.txt")
        XCTAssertNil(ImplicitLinks.link(in: row, at: 1))
    }

    /// The cells a link covers, for underlining it: one row, or the rows a long URL wraps onto.
    func testALinksCellsAcrossWrappedRows() throws {
        let terminal = try Terminal(columns: 20, rows: 4)
        terminal.feed(Array("go https://example.com/a/very/long/path ok\r\nnext".utf8))
        XCTAssertTrue(terminal.isWrapped(row: 0))
        XCTAssertTrue(terminal.isWrapped(row: 1))
        XCTAssertFalse(terminal.isWrapped(row: 2))
        let expected = TerminalLink(url: "https://example.com/a/very/long/path",
                                    spans: [.init(row: 0, columns: 3...19), .init(row: 1, columns: 0...18)])
        XCTAssertEqual(terminal.link(column: 5, row: 0), expected, "from its first row")
        XCTAssertEqual(terminal.link(column: 2, row: 1), expected, "from the row it wraps onto")
        XCTAssertNil(terminal.link(column: 1, row: 2), "\"ok\" isn't part of it")
        XCTAssertNil(terminal.link(column: 1, row: 3), "a hard line break ends the line")
    }

    func testAnOSC8LinksCells() throws {
        let terminal = try Terminal(columns: 12, rows: 3)
        terminal.feed(Array("see \u{1b}]8;;https://example.com\u{1b}\\the long docs\u{1b}]8;;\u{1b}\\ now".utf8))
        // "see " then 13 linked cells: columns 4–11 of row 0, 0–4 of row 1.
        XCTAssertEqual(terminal.link(column: 2, row: 1),
                       TerminalLink(url: "https://example.com", spans: [.init(row: 0, columns: 4...11), .init(row: 1, columns: 0...4)]))
        XCTAssertNil(terminal.link(column: 1, row: 0))
    }
}
