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
}
