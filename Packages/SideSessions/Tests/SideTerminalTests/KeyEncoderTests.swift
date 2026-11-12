import SideTerminal
import XCTest

/// Keys as the program receives them, by the terminal's modes.
final class KeyEncoderTests: XCTestCase {
    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    func testPlainKeys() throws {
        let terminal = try Terminal(columns: 80, rows: 24)
        let keys = KeyEncoder(terminal: terminal)
        XCTAssertEqual(keys.encode(KeyInput(keycode: 0x00, text: "a", unshifted: 0x61)), bytes("a"))
        XCTAssertEqual(keys.encode(KeyInput(keycode: 0x00, modifiers: .shift, consumed: .shift, text: "A", unshifted: 0x61)), bytes("A"))
        XCTAssertEqual(keys.encode(KeyInput(keycode: 0x24)), bytes("\r"), "return")
        XCTAssertEqual(keys.encode(KeyInput(keycode: 0x33)), [0x7F], "delete sends DEL")
        XCTAssertEqual(keys.encode(KeyInput(keycode: 0x30, text: "\t")), bytes("\t"))
        XCTAssertEqual(keys.encode(KeyInput(keycode: 0x35)), [0x1B], "escape")
        XCTAssertEqual(keys.encode(KeyInput(action: .release, keycode: 0x00, text: "a", unshifted: 0x61)), [], "releases send nothing")
        XCTAssertEqual(keys.encode(KeyInput(keycode: 0x38, modifiers: .shift)), [], "a bare modifier sends nothing")
    }

    func testControlKeys() throws {
        let keys = KeyEncoder(terminal: try Terminal(columns: 80, rows: 24))
        XCTAssertEqual(keys.encode(KeyInput(keycode: 0x08, modifiers: .control, unshifted: 0x63)), [0x03], "control-C")
        XCTAssertEqual(keys.encode(KeyInput(keycode: 0x02, modifiers: .control, unshifted: 0x64)), [0x04], "control-D")
    }

    func testArrowsFollowCursorKeyMode() throws {
        let terminal = try Terminal(columns: 80, rows: 24)
        let keys = KeyEncoder(terminal: terminal)
        XCTAssertEqual(keys.encode(KeyInput(keycode: 0x7E)), bytes("\u{1b}[A"))
        terminal.feed(bytes("\u{1b}[?1h")) // DECCKM, as vim and less set it
        XCTAssertEqual(keys.encode(KeyInput(keycode: 0x7E)), bytes("\u{1b}OA"), "application cursor keys")
        XCTAssertEqual(keys.encode(KeyInput(keycode: 0x7C, modifiers: .option)), bytes("\u{1b}[1;3C"), "option-right")
    }

    func testOptionTypesOrSendsMeta() throws {
        let keys = KeyEncoder(terminal: try Terminal(columns: 80, rows: 24))
        let optionF = KeyInput(keycode: 0x03, modifiers: .option, consumed: .option, text: "ƒ", unshifted: 0x66)
        XCTAssertEqual(keys.encode(optionF), bytes("ƒ"), "by default, option types the layout's character")
        XCTAssertEqual(keys.translationModifiers(for: .option), .option)

        // As Meta, the view translates without option: "f", option not used up.
        keys.optionAsAlt = .always
        XCTAssertEqual(keys.translationModifiers(for: .option), [])
        let meta = KeyInput(keycode: 0x03, modifiers: .option, consumed: [], text: "f", unshifted: 0x66)
        XCTAssertEqual(keys.encode(meta), bytes("\u{1b}f"), "escape, then the key")

        keys.optionAsAlt = .left
        XCTAssertEqual(keys.translationModifiers(for: .option), [], "the left option is Meta")
        XCTAssertEqual(keys.translationModifiers(for: [.option, .rightOption]), [.option, .rightOption], "the right one types")
    }

    func testTheKittyKeyboardProtocol() throws {
        let terminal = try Terminal(columns: 80, rows: 24)
        let keys = KeyEncoder(terminal: terminal)
        terminal.feed(bytes("\u{1b}[>1u")) // push: disambiguate escape codes
        XCTAssertEqual(keys.encode(KeyInput(keycode: 0x35)), bytes("\u{1b}[27u"), "escape, unambiguous")
        XCTAssertEqual(keys.encode(KeyInput(keycode: 0x00, text: "a", unshifted: 0x61)), bytes("a"), "plain text stays text")
        terminal.feed(bytes("\u{1b}[<u")) // pop
        XCTAssertEqual(keys.encode(KeyInput(keycode: 0x35)), [0x1B])
    }
}
