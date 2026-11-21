import SideSessionsKit
import SideTerminal
import XCTest

final class SideTerminalTests: XCTestCase {
    /// The changed rows' cells, by row.
    private func read(_ reader: ScreenReader) -> [Int: [ScreenCell]] {
        var rows: [Int: [ScreenCell]] = [:]
        reader.forEachChangedRow { y, cells in rows[y] = Array(cells) }
        return rows
    }

    private func text(_ cells: [ScreenCell]?) -> String {
        String(String.UnicodeScalarView((cells ?? []).compactMap { $0.scalar == 0 ? " " : UnicodeScalar($0.scalar) }))
            .trimmingCharacters(in: .whitespaces)
    }

    /// The cursor's style and blink as programs set them: DECSCUSR (`CSI n SP q`; odd blinks)
    /// and DEC mode 12.
    func testCursorStyleAndBlink() throws {
        let terminal = try Terminal(columns: 20, rows: 4)
        let reader = ScreenReader(terminal: terminal)
        _ = reader.update()
        XCTAssertEqual(reader.cursor.shape, .block)
        XCTAssertTrue(reader.cursor.blinking, "blinking until a program says otherwise")
        for (sequence, shape, blinking) in [("\u{1B}[2 q", ScreenCursor.Shape.block, false), ("\u{1B}[5 q", .bar, true),
                                            ("\u{1B}[6 q", .bar, false), ("\u{1B}[3 q", .underline, true),
                                            ("\u{1B}[?12l", .underline, false), ("\u{1B}[?12h", .underline, true)] {
            terminal.feed(Array(sequence.utf8))
            _ = reader.update()
            XCTAssertEqual(reader.cursor.shape, shape, sequence.debugDescription)
            XCTAssertEqual(reader.cursor.blinking, blinking, sequence.debugDescription)
        }
        terminal.feed(Array("\u{1B}[0 q".utf8))
        _ = reader.update()
        XCTAssertEqual(reader.cursor.shape, .block, "the default again")
        XCTAssertTrue(reader.cursor.blinking, "the default again")

        let steady = try Terminal(columns: 20, rows: 4, cursorBlinks: false)
        let steadyReader = ScreenReader(terminal: steady)
        _ = steadyReader.update()
        XCTAssertFalse(steadyReader.cursor.blinking)
    }

    /// A program's cursor color (OSC 12), and back to none (OSC 112).
    func testAProgramSetsTheCursorColor() throws {
        let terminal = try Terminal(columns: 20, rows: 4)
        let reader = ScreenReader(terminal: terminal)
        _ = reader.update()
        XCTAssertNil(reader.cursorColor, "no default given")
        terminal.feed(Array("\u{1B}]12;#ff8000\u{07}".utf8))
        _ = reader.update()
        XCTAssertEqual(reader.cursorColor, 0xFF8000)
        terminal.feed(Array("\u{1B}]112\u{07}".utf8))
        _ = reader.update()
        XCTAssertNil(reader.cursorColor, "reset")
        terminal.setDefaultColors(foreground: 0xFFFFFF, background: 0, cursor: 0x00FF00)
        _ = reader.update()
        XCTAssertEqual(reader.cursorColor, 0x00FF00, "a default given")
    }

    func testTextAndTheCursor() throws {
        let terminal = try Terminal(columns: 20, rows: 4)
        let reader = ScreenReader(terminal: terminal)
        terminal.feed(Array("hello\r\nworld".utf8))
        XCTAssertTrue(reader.update())
        let rows = read(reader)
        XCTAssertEqual(text(rows[0]), "hello")
        XCTAssertEqual(text(rows[1]), "world")
        XCTAssertEqual(reader.cursor.column, 5)
        XCTAssertEqual(reader.cursor.row, 1)
        XCTAssertFalse(reader.update(), "nothing new to draw")
        terminal.feed(Array("!".utf8))
        XCTAssertTrue(reader.update())
        XCTAssertEqual(Array(read(reader).keys), [1], "only the row that changed")
    }

    func testColorsAndStyles() throws {
        let terminal = try Terminal(columns: 20, rows: 2)
        terminal.setDefaultColors(foreground: 0xD0D0D0, background: 0x101010)
        let reader = ScreenReader(terminal: terminal)
        // Plain, true-color red, inverse, bold italic struck, curly underline, faint.
        terminal.feed(Array("a\u{1b}[38;2;255;0;0mr\u{1b}[0m\u{1b}[7mi\u{1b}[0m\u{1b}[1;3;9mb\u{1b}[0m\u{1b}[4:3mu\u{1b}[0m\u{1b}[2mf".utf8))
        XCTAssertTrue(reader.update())
        let row = try XCTUnwrap(read(reader)[0])
        XCTAssertEqual(row[0].foreground, 0xD0D0D0)
        XCTAssertNil(row[0].background, "the default background isn't drawn")
        XCTAssertEqual(row[1].foreground, 0xFF0000)
        XCTAssertEqual(row[2].foreground, 0x101010, "inverse: the default background as text")
        XCTAssertEqual(row[2].background, 0xD0D0D0)
        XCTAssertEqual(row[3].style, [.bold, .italic, .strikethrough])
        XCTAssertEqual(row[4].underline, .curly)
        XCTAssertEqual(row[5].foreground, 0x707070, "faint: halfway to the background")
    }

    func testAWideCharacterAndAGraphemeCluster() throws {
        let terminal = try Terminal(columns: 10, rows: 1)
        let reader = ScreenReader(terminal: terminal)
        terminal.feed(Array("漢🇯🇵".utf8))
        XCTAssertTrue(reader.update())
        var row: [ScreenCell] = [], clusters: [Int: String] = [:]
        reader.forEachChangedRow { y, cells in if y == 0 { row = Array(cells); clusters = reader.rowClusters } }
        XCTAssertEqual(row[0].scalar, 0x6F22)
        XCTAssertTrue(row[0].style.contains(.wide))
        XCTAssertTrue(row[1].style.contains(.spacer))
        XCTAssertTrue(row[2].style.contains(.cluster))
        XCTAssertEqual(clusters, [2: "🇯🇵"], "a flag is one cluster (mode 2027), kept beside the cells")
        XCTAssertFalse(row[0].style.contains(.cluster))
    }

    func testRepliesAndEvents() throws {
        let replies = Collected<String>(), titles = Collected<String>(), bells = Collected<Int>(), statuses = Collected<String>()
        var events = Terminal.Events()
        events.reply = { replies.add(String(decoding: $0, as: UTF8.self)) }
        events.title = { titles.add($0) }
        events.bell = { bells.add(1) }
        events.programStatus = { id, record in statuses.add("\(id):\(record?.state.rawValue ?? "clear"):\(record?.progress ?? -1)") }
        let terminal = try Terminal(columns: 20, rows: 4, events: events)
        terminal.feed(Array("ab\u{1b}[6n".utf8))
        XCTAssertEqual(replies.values, ["\u{1b}[1;3R"], "the cursor position, for the program")
        terminal.feed(Array("\u{1b}]2;my title\u{07}\u{07}".utf8))
        XCTAssertEqual(titles.values, ["my title"])
        XCTAssertEqual(terminal.title, "my title")
        XCTAssertEqual(bells.values.count, 1)
        terminal.feed(Array("\u{1b}]7501;state=working:progress=40\u{07}\u{1b}]7501;id=lint:state=clear\u{07}".utf8))
        XCTAssertEqual(statuses.values, [":working:40", "lint:clear:-1"])
    }

    /// Synchronized output: what's drawn while the program holds the screen is the screen from
    /// when the hold began, and the finished one once it ends.
    func testARenderHoldShowsTheScreenFromBeforeIt() throws {
        let terminal = try Terminal(columns: 20, rows: 2)
        let reader = ScreenReader(terminal: terminal)
        terminal.feed(Array("before".utf8))
        XCTAssertTrue(reader.update())
        _ = read(reader)
        terminal.feed(Array("\u{1b}[?2026h\r\u{1b}[2Khalf-drawn".utf8))
        if reader.update() { XCTAssertEqual(text(read(reader)[0]), "before") }
        XCTAssertFalse(reader.update(), "nothing new while held")
        terminal.feed(Array(" done\u{1b}[?2026l".utf8))
        XCTAssertTrue(reader.update())
        XCTAssertEqual(text(read(reader)[0]), "half-drawn done")
    }

    /// Rows changed just before a hold are read once it ends. (2026-11-20, on screen: btop's rows
    /// stayed under lazygit after one quit and the other started; both use synchronized output.
    /// A snapshot taken in a second render state when a hold began had taken those rows' changes.)
    func testRowsChangedAroundAHoldAreAllRead() throws {
        let terminal = try Terminal(columns: 20, rows: 3)
        let reader = ScreenReader(terminal: terminal)
        terminal.feed(Array("one\r\ntwo\r\nthree".utf8))
        XCTAssertTrue(reader.update())
        _ = read(reader)
        // Row 1 changes, then a hold begins and ends before the reader looks.
        terminal.feed(Array("\u{1b}[2;1H\u{1b}[2KTWO".utf8))
        terminal.feed(Array("\u{1b}[?2026h\u{1b}[?2026l".utf8))
        XCTAssertTrue(reader.update())
        XCTAssertEqual(text(read(reader)[1]), "TWO", "the change made before the hold")

        // A change before a hold and one inside it: nothing while held, both once it ends.
        terminal.feed(Array("\u{1b}[3;1H\u{1b}[2KTHREE".utf8))
        terminal.feed(Array("\u{1b}[?2026h\u{1b}[1;1H\u{1b}[2KONE".utf8))
        XCTAssertFalse(reader.update(), "nothing new while held")
        terminal.feed(Array("\u{1b}[?2026l".utf8))
        XCTAssertTrue(reader.update())
        let rows = read(reader)
        XCTAssertEqual(text(rows[0]), "ONE")
        XCTAssertEqual(text(rows[2]), "THREE")
        terminal.feed(Array("\u{1b}[2;5Hx".utf8))
        XCTAssertTrue(reader.update())
        XCTAssertEqual(text(read(reader)[1]), "TWO x", "the reader has the terminal's rows")
    }

    func testResize() throws {
        let terminal = try Terminal(columns: 10, rows: 2)
        let reader = ScreenReader(terminal: terminal)
        terminal.resize(columns: 30, rows: 5)
        XCTAssertTrue(reader.update())
        XCTAssertEqual(reader.columns, 30)
        XCTAssertEqual(reader.rows, 5)
    }

    /// Fed on one thread, read on another, as Side does: the reader's thread and the render thread.
    /// A flood of output mustn't keep the render thread from the lock: with a plain lock, frames
    /// all but stopped until the flood ended (4 in 0.3 s here); HandoffLock keeps them coming.
    func testFramesKeepComingWhileOutputFloods() throws {
        let terminal = try Terminal(columns: 80, rows: 24)
        let line = Array("the quick brown fox jumps over the lazy dog\r\n".utf8)
        // A flood arrives in big reads: a megabyte per feed, parsed in slices.
        let chunk = Array([[UInt8]](repeating: line, count: 1_048_576 / line.count).joined())
        let fed = DispatchSemaphore(value: 0)
        Thread {
            for _ in 0..<64 { terminal.feed(chunk) }
            fed.signal()
        }.start()
        let reader = ScreenReader(terminal: terminal)
        var reads = 0
        let started = Date()
        while fed.wait(timeout: .now() + .milliseconds(1)) == .timedOut {
            if reader.update() { reader.forEachChangedRow { _, _ in }; reads += 1 }
        }
        let seconds = Date().timeIntervalSince(started)
        // About one frame per 1 ms poll; at least one per 5 ms.
        XCTAssertGreaterThan(Double(reads), seconds * 200, "\(reads) frames in \(seconds) s while fed")

        terminal.feed(Array("END".utf8))
        XCTAssertTrue(reader.update())
        var last = ""
        reader.forEachChangedRow { y, cells in if y == 23 { last = self.text(Array(cells)) } }
        XCTAssertEqual(last, "END")
    }
}

/// Values a callback collected, from whatever thread it ran on.
final class Collected<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func add(_ value: T) { lock.lock(); items.append(value); lock.unlock() }
    var values: [T] { lock.lock(); defer { lock.unlock() }; return items }
}

final class UnderlineTests: XCTestCase {
    /// SGR 4:n's kinds and SGR 58's color, by RGB or palette index; SGR 53, overline.
    func testUnderlineKindsColorsAndOverline() throws {
        let terminal = try Terminal(columns: 20, rows: 1)
        terminal.setPalette([0, 0xAA0000])
        let reader = ScreenReader(terminal: terminal)
        terminal.feed(Array("\u{1b}[4:3;58:2::255:0:0mc\u{1b}[0m\u{1b}[4:2;58:5:1md\u{1b}[0m\u{1b}[53mo".utf8))
        XCTAssertTrue(reader.update())
        var row: [ScreenCell] = []
        reader.forEachChangedRow { _, cells in row = Array(cells) }
        XCTAssertEqual(row[0].underline, .curly)
        XCTAssertEqual(row[0].underlineColor, 0xFF0000)
        XCTAssertEqual(row[1].underline, .double)
        XCTAssertEqual(row[1].underlineColor, 0xAA0000, "palette color 1")
        XCTAssertTrue(row[2].style.contains(.overline))
        XCTAssertNil(row[2].underlineColor)
    }
}
