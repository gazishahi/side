import SideTerminal
import XCTest

/// Mouse events as programs asked for them.
final class MouseEncoderTests: XCTestCase {
    private let geometry = MouseEncoder.Geometry(width: 800, height: 480, cellWidth: 10, cellHeight: 20)
    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    func testNothingUntilAProgramAsks() throws {
        let terminal = try Terminal(columns: 80, rows: 24)
        let mouse = MouseEncoder(terminal: terminal)
        XCTAssertFalse(mouse.isTracking)
        XCTAssertEqual(mouse.encode(MouseInput(action: .press, button: .left, x: 5, y: 5), geometry: geometry), [])
    }

    func testClicksAndTheWheelInSGR() throws {
        let terminal = try Terminal(columns: 80, rows: 24)
        let mouse = MouseEncoder(terminal: terminal)
        terminal.feed(bytes("\u{1b}[?1000h\u{1b}[?1006h")) // normal tracking, SGR format (htop, vim)
        XCTAssertTrue(mouse.isTracking)
        // Column 3, row 2 (1-based in the report): pixel 25, 25.
        XCTAssertEqual(mouse.encode(MouseInput(action: .press, button: .left, x: 25, y: 25), geometry: geometry), bytes("\u{1b}[<0;3;2M"))
        XCTAssertEqual(mouse.encode(MouseInput(action: .release, button: .left, x: 25, y: 25), geometry: geometry), bytes("\u{1b}[<0;3;2m"))
        XCTAssertEqual(mouse.encode(MouseInput(action: .press, button: .wheelUp, x: 25, y: 25), geometry: geometry), bytes("\u{1b}[<64;3;2M"))
        XCTAssertEqual(mouse.encode(MouseInput(action: .motion, button: .none, x: 55, y: 25), geometry: geometry), [], "no motion in normal tracking")
    }

    func testDragInButtonTracking() throws {
        let terminal = try Terminal(columns: 80, rows: 24)
        let mouse = MouseEncoder(terminal: terminal)
        terminal.feed(bytes("\u{1b}[?1002h\u{1b}[?1006h")) // button-event tracking (tmux)
        _ = mouse.encode(MouseInput(action: .press, button: .left, x: 5, y: 5), geometry: geometry)
        XCTAssertEqual(mouse.encode(MouseInput(action: .motion, button: .left, x: 35, y: 5), geometry: geometry), bytes("\u{1b}[<32;4;1M"), "a drag")
        XCTAssertEqual(mouse.encode(MouseInput(action: .motion, button: .left, x: 37, y: 5), geometry: geometry), [], "the same cell again")
    }
}
