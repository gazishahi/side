import SideTerminal
import XCTest

final class PseudoTerminalProcessTests: XCTestCase {
    func testAProgramRunsInAPseudoTerminalAndExits() throws {
        let process = PseudoTerminalProcess()
        let output = Collected<UInt8>()
        let exited = expectation(description: "exited")
        let status = Collected<Int32>()
        process.onOutput = { bytes in for b in bytes { output.add(b) } }
        process.onExit = { status.add($0); exited.fulfill() }
        XCTAssertTrue(process.start(executable: "/bin/sh", arguments: ["-c", "stty size; printf 'tty:'; test -t 0 && echo yes; exit 3"],
                                    environment: ["TERM=xterm-256color"], directory: "/tmp", columns: 100, rows: 30))
        XCTAssertGreaterThan(process.pid, 0)
        wait(for: [exited], timeout: 10)
        let text = String(decoding: output.values, as: UTF8.self)
        XCTAssertTrue(text.contains("30 100"), "the PTY has the size it was given: \(text)")
        XCTAssertTrue(text.contains("tty:yes"), "stdin is a terminal")
        XCTAssertEqual(status.values.first.map { ($0 >> 8) & 0xFF }, 3, "the raw wait status, exit code 3")
    }

    func testInputAndResize() throws {
        let process = PseudoTerminalProcess()
        let output = Collected<UInt8>()
        let exited = expectation(description: "exited")
        process.onOutput = { bytes in for b in bytes { output.add(b) } }
        process.onExit = { _ in exited.fulfill() }
        XCTAssertTrue(process.start(executable: "/bin/sh", arguments: ["-c", "read line; stty size; echo got:$line"],
                                    environment: [], directory: nil, columns: 80, rows: 24))
        process.resize(columns: 120, rows: 40)
        process.write(ArraySlice(Array("hello\r".utf8)))
        wait(for: [exited], timeout: 10)
        let text = String(decoding: output.values, as: UTF8.self)
        XCTAssertTrue(text.contains("40 120"), text)
        XCTAssertTrue(text.contains("got:hello"), text)
    }

    /// IUTF8: a backspace in canonical input erases a whole multi-byte character (side-c0,
    /// 2026-11-20: Side's PTYs had -iutf8 where Ghostty's have iutf8).
    func testABackspaceErasesAWholeCharacter() throws {
        let process = PseudoTerminalProcess()
        let output = Collected<UInt8>()
        let exited = expectation(description: "exited")
        process.onOutput = { bytes in for b in bytes { output.add(b) } }
        process.onExit = { _ in exited.fulfill() }
        XCTAssertTrue(process.start(executable: "/bin/sh", arguments: ["-c", "stty -a | grep -o ' iutf8' ; read line; printf 'got:%s:\\n' \"$line\""],
                                    environment: [], directory: nil, columns: 80, rows: 24))
        // Typed once the program is waiting: the line discipline edits input as it arrives.
        let deadline = Date().addingTimeInterval(5)
        while !String(decoding: output.values, as: UTF8.self).contains("iutf8"), Date() < deadline { usleep(10_000) }
        process.write(ArraySlice(Array("a日".utf8) + [0x7F] + Array("b\r".utf8)))
        wait(for: [exited], timeout: 10)
        let text = String(decoding: output.values, as: UTF8.self)
        XCTAssertTrue(text.contains(" iutf8"), text)
        XCTAssertTrue(text.contains("got:ab:"), "the whole 日 erased, no bytes of it left: \(text)")
    }

    func testTerminate() throws {
        let process = PseudoTerminalProcess()
        let exited = expectation(description: "exited")
        process.onExit = { _ in exited.fulfill() }
        XCTAssertTrue(process.start(executable: "/bin/sleep", arguments: ["30"], environment: [], directory: nil, columns: 80, rows: 24))
        process.terminate()
        wait(for: [exited], timeout: 10)
    }
}

final class TerminalQueryTests: XCTestCase {
    func testModesTextAndPalette() throws {
        let terminal = try Terminal(columns: 20, rows: 3)
        XCTAssertFalse(terminal.isModeSet(2004))
        terminal.feed(Array("\u{1b}[?2004h".utf8))
        XCTAssertTrue(terminal.isModeSet(2004), "bracketed paste, as shells set it")

        terminal.feed(Array("one\r\ntwo\r\nthree\r\nfour".utf8))
        XCTAssertEqual(terminal.text(), "two\nthree\nfour", "the screen only")
        XCTAssertEqual(terminal.text(scrollback: true), "one\ntwo\nthree\nfour")

        terminal.setPalette([0x111111, 0xAA0000])
        let reader = ScreenReader(terminal: terminal)
        terminal.feed(Array("\r\n\u{1b}[31mR".utf8))
        XCTAssertTrue(reader.update())
        var red: UInt32?
        reader.forEachChangedRow { _, cells in if let c = cells.first(where: { $0.scalar == UInt32(UInt8(ascii: "R")) }) { red = c.foreground } }
        XCTAssertEqual(red, 0xAA0000, "color 1 comes from the palette set")
    }
}
