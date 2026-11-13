import AppKit
import Metal
import XCTest
@testable import AlloyTerminal

/// Draws grids offscreen and reads the pixels back.
final class TerminalRendererTests: XCTestCase {
    static let black = TerminalTheme(background: SIMD4(0, 0, 0, 1), cursor: 0xFFFFFF)
    let font = TerminalFont(name: "Menlo", size: 13)
    let scale: CGFloat = 2

    private func render(_ grid: TerminalGrid, renderer: TerminalRenderer) throws -> Pixels {
        let cell = font.cellSize
        let width = Int((CGFloat(grid.columns) * cell.width * scale).rounded(.up))
        let height = Int((CGFloat(grid.rows) * cell.height * scale).rounded(.up))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let texture = try XCTUnwrap(renderer.device.makeTexture(descriptor: descriptor))
        let buffer = try XCTUnwrap(renderer.draw(grid, scale: scale, into: texture))
        buffer.waitUntilCompleted()
        return Pixels(texture)
    }

    /// The pixel rectangle of a cell, inset so neighbors don't bleed in.
    private func cellRect(column: Int, row: Int, span: Int = 1) -> (x: Range<Int>, y: Range<Int>) {
        let cell = font.cellSize
        let x0 = Int(CGFloat(column) * cell.width * scale) + 2, x1 = Int(CGFloat(column + span) * cell.width * scale) - 2
        let y0 = Int(CGFloat(row) * (cell.height * scale).rounded()) + 2, y1 = Int(CGFloat(row + 1) * (cell.height * scale).rounded()) - 2
        return (x0..<x1, y0..<y1)
    }

    private func makeRenderer() throws -> TerminalRenderer {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        return try TerminalRenderer(device: device, font: font, theme: Self.black)
    }

    func testGlyphsBackgroundsAndTheDefaultBackground() throws {
        let renderer = try makeRenderer()
        let grid = TerminalGrid(columns: 8, rows: 2, foreground: 0xFFFFFF)
        grid[0, 0] = TerminalCell(scalar: UInt32(UInt8(ascii: "W")), foreground: 0xFF0000)
        grid[2, 0] = TerminalCell(foreground: 0xFFFFFF, background: 0x00FF00)
        grid[3, 0] = TerminalCell(foreground: 0xFFFFFF, background: 0x00FF00)
        grid.cursor.visible = false
        let pixels = try render(grid, renderer: renderer)

        let glyph = cellRect(column: 0, row: 0)
        XCTAssertGreaterThan(pixels.count(in: glyph) { $0.r > 150 && $0.g < 80 && $0.b < 80 }, 20, "a red W")
        let filled = cellRect(column: 2, row: 0, span: 2)
        XCTAssertEqual(pixels.count(in: filled) { $0.g > 240 && $0.r < 20 }, filled.x.count * filled.y.count, "a green run across two cells")
        let empty = cellRect(column: 6, row: 1)
        XCTAssertEqual(pixels.count(in: empty) { $0.r < 5 && $0.g < 5 && $0.b < 5 }, empty.x.count * empty.y.count, "the theme's background")
        XCTAssertEqual(grid.dirty, [false, false], "drawn rows are clean")
    }

    func testAWideCharacterSpansTwoCells() throws {
        let renderer = try makeRenderer()
        let grid = TerminalGrid(columns: 6, rows: 1, foreground: 0xFFFFFF)
        grid[1, 0] = TerminalCell(scalar: 0x6F22, foreground: 0xFFFFFF, style: .wide) // 漢
        grid[2, 0] = TerminalCell(foreground: 0xFFFFFF, style: .spacer)
        grid.cursor.visible = false
        let pixels = try render(grid, renderer: renderer)
        let lit: (Pixels.RGBA) -> Bool = { $0.r > 100 }
        XCTAssertGreaterThan(pixels.count(in: cellRect(column: 1, row: 0), lit), 10)
        XCTAssertGreaterThan(pixels.count(in: cellRect(column: 2, row: 0), lit), 10, "the glyph reaches into its spacer")
        XCTAssertEqual(pixels.count(in: cellRect(column: 4, row: 0), lit), 0)
    }

    func testCursorShapes() throws {
        let renderer = try makeRenderer()
        let grid = TerminalGrid(columns: 4, rows: 1, foreground: 0xFFFFFF)
        let cell = cellRect(column: 1, row: 0)
        let total = cell.x.count * cell.y.count
        let lit: (Pixels.RGBA) -> Bool = { $0.r > 100 }

        grid.cursor = TerminalCursor(column: 1, row: 0, visible: true, shape: .block)
        XCTAssertEqual(try render(grid, renderer: renderer).count(in: cell, lit), total, "a block fills the cell")
        grid.cursor.shape = .bar
        let bar = try render(grid, renderer: renderer).count(in: cell, lit)
        XCTAssertGreaterThan(bar, 0)
        XCTAssertLessThan(bar, total / 3, "a bar is a sliver")
        grid.cursor.visible = false
        XCTAssertEqual(try render(grid, renderer: renderer).count(in: cell, lit), 0)
    }

    /// Search matches in the theme's search colors, the selected one in its own, the text over
    /// them in the search's text color; cleared, the row looks as before.
    func testSearchMatchesAreHighlighted() throws {
        let renderer = try makeRenderer()
        let grid = TerminalGrid(columns: 8, rows: 1, foreground: 0xFFFFFF)
        for x in 0..<8 { grid[x, 0] = TerminalCell(scalar: UInt32(UInt8(ascii: "W")), foreground: 0xFFFFFF) }
        grid.cursor.visible = false
        let before = try render(grid, renderer: renderer)
        renderer.searchMatches = [TerminalSpan(row: 0, columns: 1...2), TerminalSpan(row: 0, columns: 5...6)]
        renderer.selectedMatch = [TerminalSpan(row: 0, columns: 5...6)]
        let after = try render(grid, renderer: renderer)
        let yellow: (Pixels.RGBA) -> Bool = { $0.r > 240 && $0.g > 210 && $0.g < 235 && $0.b > 110 && $0.b < 140 } // 0xFFE082
        let orange: (Pixels.RGBA) -> Bool = { $0.r > 230 && $0.g > 150 && $0.g < 180 && $0.b > 110 && $0.b < 140 } // 0xF2A57E
        let black: (Pixels.RGBA) -> Bool = { $0.r < 40 && $0.g < 40 && $0.b < 40 }
        let match = cellRect(column: 1, row: 0), selected = cellRect(column: 5, row: 0), plain = cellRect(column: 3, row: 0)
        XCTAssertGreaterThan(after.count(in: match, yellow), match.x.count * match.y.count / 3, "a match")
        XCTAssertGreaterThan(after.count(in: match, black), 20, "its W in the search's text color")
        XCTAssertGreaterThan(after.count(in: selected, orange), selected.x.count * selected.y.count / 3, "the selected match")
        XCTAssertEqual(after.count(in: plain, yellow) + after.count(in: plain, orange), 0, "not a match")
        renderer.searchMatches = []
        renderer.selectedMatch = []
        XCTAssertEqual(try render(grid, renderer: renderer), before, "cleared")
    }

    /// The hovered link is underlined, cell by cell in each cell's color, across the rows it covers.
    func testTheHoveredLinkIsUnderlined() throws {
        let renderer = try makeRenderer()
        let grid = TerminalGrid(columns: 6, rows: 2, foreground: 0xFFFFFF)
        for x in 0..<6 { grid[x, 0] = TerminalCell(scalar: UInt32(UInt8(ascii: "a")), foreground: 0x00FF00) }
        for x in 0..<6 { grid[x, 1] = TerminalCell(scalar: UInt32(UInt8(ascii: "a")), foreground: 0x00FF00) }
        grid.cursor.visible = false
        let cell = font.cellSize
        let baseline = (cell.height * scale).rounded()
        // Below the text's baseline, where the underline sits ("a" has no descender).
        let ascent = Int((CTFontGetAscent(font.regular) * scale).rounded())
        func bottom(_ column: Int, _ row: Int) -> (x: Range<Int>, y: Range<Int>) {
            let x0 = Int(CGFloat(column) * cell.width * scale) + 2, x1 = Int(CGFloat(column + 1) * cell.width * scale) - 2
            let rowTop = Int(CGFloat(row) * baseline)
            return (x0..<x1, (rowTop + ascent + 1)..<(rowTop + Int(baseline) - 1))
        }
        let green: (Pixels.RGBA) -> Bool = { $0.g > 150 && $0.r < 100 }
        let before = try render(grid, renderer: renderer)
        XCTAssertEqual(before.count(in: bottom(4, 0), green), 0, "no underline yet")

        renderer.highlightedLink = [TerminalSpan(row: 0, columns: 3...5), TerminalSpan(row: 1, columns: 0...1)]
        let after = try render(grid, renderer: renderer)
        for (column, row) in [(3, 0), (5, 0), (0, 1), (1, 1)] {
            XCTAssertGreaterThan(after.count(in: bottom(column, row), green), 5, "underlined: \(column), \(row)")
        }
        for (column, row) in [(2, 0), (2, 1)] {
            XCTAssertEqual(after.count(in: bottom(column, row), green), 0, "not part of it: \(column), \(row)")
        }
        renderer.highlightedLink = []
        XCTAssertEqual(try render(grid, renderer: renderer), before, "gone again")
    }

    /// A program's cursor color over the theme's.
    func testTheCursorInAProgramsColor() throws {
        let renderer = try makeRenderer()
        let grid = TerminalGrid(columns: 4, rows: 1, foreground: 0xFFFFFF)
        grid.cursor = TerminalCursor(column: 1, row: 0, visible: true, shape: .block, color: 0xFF8000)
        let cell = cellRect(column: 1, row: 0)
        let orange: (Pixels.RGBA) -> Bool = { $0.r > 240 && $0.g > 110 && $0.g < 150 && $0.b < 20 }
        XCTAssertEqual(try render(grid, renderer: renderer).count(in: cell, orange), cell.x.count * cell.y.count)
        grid.cursor.color = nil
        XCTAssertEqual(try render(grid, renderer: renderer).count(in: cell, orange), 0, "the theme's white")
    }

    /// Unfocused, every shape is an outline of its cell; a blinking cursor blinked off isn't drawn,
    /// unless unfocused, where it doesn't blink.
    func testHollowWhenUnfocusedAndBlinkedOff() throws {
        let renderer = try makeRenderer()
        let grid = TerminalGrid(columns: 4, rows: 1, foreground: 0xFFFFFF)
        grid[1, 0] = TerminalCell(scalar: UInt32(UInt8(ascii: "W")), foreground: 0x00FF00)
        grid.cursor = TerminalCursor(column: 1, row: 0, visible: true, shape: .bar, blinking: true)
        let cellPixels = cellRect(column: 1, row: 0)
        let cursorLit: (Pixels.RGBA) -> Bool = { $0.r > 200 && $0.b > 200 }
        let edges: (Pixels) -> (left: Bool, right: Bool, top: Bool, bottom: Bool) = { p in
            let cell = self.font.cellSize
            let x0 = Int(CGFloat(1) * cell.width * self.scale), x1 = Int(CGFloat(2) * cell.width * self.scale) - 1
            let y1 = Int((cell.height * self.scale).rounded()) - 1, mid = y1 / 2, midX = (x0 + x1) / 2
            return (p.count(in: (x0..<x0 + 1, mid..<mid + 1), cursorLit) == 1, p.count(in: (x1..<x1 + 1, mid..<mid + 1), cursorLit) == 1,
                    p.count(in: (midX..<midX + 1, 0..<1), cursorLit) == 1, p.count(in: (midX..<midX + 1, y1..<y1 + 1), cursorLit) == 1)
        }

        renderer.focused = false
        renderer.blinkOn = false
        var pixels = try render(grid, renderer: renderer)
        let e = edges(pixels)
        XCTAssertTrue(e.left && e.right && e.top && e.bottom, "an outline all round: \(e)")
        XCTAssertGreaterThan(pixels.count(in: cellPixels) { $0.g > 150 && $0.r < 100 }, 20, "the W shows through, its own color")
        XCTAssertLessThan(pixels.count(in: cellPixels, cursorLit), cellPixels.x.count * cellPixels.y.count / 3, "hollow")

        renderer.focused = true
        pixels = try render(grid, renderer: renderer)
        XCTAssertEqual(pixels.count(in: cellPixels, cursorLit) + pixels.count(in: (0..<pixels.width, 0..<pixels.height), cursorLit), 0, "blinked off")
        renderer.blinkOn = true
        XCTAssertGreaterThan(try render(grid, renderer: renderer).count(in: (0..<pixels.width, 0..<pixels.height), cursorLit), 0, "blinked on: the bar")
        grid.cursor.blinking = false
        renderer.blinkOn = false
        XCTAssertGreaterThan(try render(grid, renderer: renderer).count(in: (0..<pixels.width, 0..<pixels.height), cursorLit), 0, "a steady cursor ignores the phase")
    }

    func testSelectedCellsAreHighlighted() throws {
        let renderer = try makeRenderer()
        let grid = TerminalGrid(columns: 6, rows: 1, foreground: 0xFFFFFF)
        for x in 1...3 { grid[x, 0] = TerminalCell(foreground: 0xFFFFFF, style: .selected) }
        grid.cursor.visible = false
        let pixels = try render(grid, renderer: renderer)
        let blue: (Pixels.RGBA) -> Bool = { $0.b > 60 && $0.b > $0.r + 30 }
        let selected = cellRect(column: 1, row: 0, span: 3)
        XCTAssertEqual(pixels.count(in: selected, blue), selected.x.count * selected.y.count, "the selection color over the run")
        XCTAssertEqual(pixels.count(in: cellRect(column: 5, row: 0), blue), 0)
    }

    /// Box drawing, braille and powerline are drawn to the cell: lines reach the cell's edges
    /// (so rows and columns join), dots sit where braille puts them.
    func testDrawnCharacters() throws {
        let renderer = try makeRenderer()
        let grid = TerminalGrid(columns: 6, rows: 2, foreground: 0xFFFFFF)
        grid[0, 0] = TerminalCell(scalar: 0x2500, foreground: 0xFFFFFF) // ─
        grid[1, 0] = TerminalCell(scalar: 0x2502, foreground: 0xFFFFFF) // │
        grid[1, 1] = TerminalCell(scalar: 0x2502, foreground: 0xFFFFFF) // │ below it
        grid[2, 0] = TerminalCell(scalar: 0x2801, foreground: 0xFFFFFF) // ⠁ dot 1
        grid[3, 0] = TerminalCell(scalar: 0x28FF, foreground: 0xFFFFFF) // ⣿ all eight
        grid[4, 0] = TerminalCell(scalar: 0xE0B0, foreground: 0xFFFFFF) // powerline right triangle
        grid.cursor.visible = false
        let pixels = try render(grid, renderer: renderer)
        let lit: (Pixels.RGBA) -> Bool = { $0.r > 128 }
        let cell = font.cellSize, w = cell.width * scale, h = (cell.height * scale).rounded()
        func px(_ column: Double, _ row: Double, _ dx: Double, _ dy: Double) -> (x: Range<Int>, y: Range<Int>) {
            let x = Int(column * w + dx * w), y = Int(row * h + dy * h)
            return (x..<(x + 1), y..<(y + 1))
        }
        // ─ reaches both edges at mid height; │ both edges at mid width, and joins the one below.
        XCTAssertEqual(pixels.count(in: px(0, 0, 0.02, 0.5), lit), 1)
        XCTAssertEqual(pixels.count(in: px(0, 0, 0.97, 0.5), lit), 1)
        XCTAssertEqual(pixels.count(in: px(1, 0, 0.5, 0.01), lit), 1)
        XCTAssertEqual(pixels.count(in: px(1, 0, 0.5, 0.99), lit), 1)
        XCTAssertEqual(pixels.count(in: px(1, 1, 0.5, 0.01), lit), 1, "no gap between rows")
        // ⠁: only the top-left dot.
        XCTAssertEqual(pixels.count(in: px(2, 0, 0.25, 0.125), lit), 1)
        XCTAssertEqual(pixels.count(in: px(2, 0, 0.75, 0.125), lit), 0)
        XCTAssertEqual(pixels.count(in: px(2, 0, 0.25, 0.875), lit), 0)
        // ⣿: every dot.
        for (dx, dy) in [(0.25, 0.125), (0.75, 0.125), (0.25, 0.375), (0.75, 0.375), (0.25, 0.625), (0.75, 0.625), (0.25, 0.875), (0.75, 0.875)] {
            XCTAssertEqual(pixels.count(in: px(3, 0, dx, dy), lit), 1, "dot at \(dx), \(dy)")
        }
        // The triangle: full height at the left edge, a point at the right's middle.
        XCTAssertEqual(pixels.count(in: px(4, 0, 0.1, 0.3), lit), 1)
        XCTAssertEqual(pixels.count(in: px(4, 0, 0.9, 0.5), lit), 1)
        XCTAssertEqual(pixels.count(in: px(4, 0, 0.9, 0.1), lit), 0)
    }

    /// A block cursor covers its cell and shows the character under it in the background color.
    func testABlockCursorInvertsItsCharacter() throws {
        let renderer = try makeRenderer()
        let grid = TerminalGrid(columns: 4, rows: 1, foreground: 0xFFFFFF)
        grid[1, 0] = TerminalCell(scalar: UInt32(UInt8(ascii: "W")), foreground: 0xFFFFFF)
        grid.cursor = TerminalCursor(column: 1, row: 0, visible: true, shape: .block)
        let pixels = try render(grid, renderer: renderer)
        let cell = cellRect(column: 1, row: 0)
        XCTAssertGreaterThan(pixels.count(in: cell) { $0.r < 60 }, 20, "the W, dark on the block")
        XCTAssertGreaterThan(pixels.count(in: cell) { $0.r > 200 }, cell.x.count * cell.y.count / 2, "the block itself")
    }

    // MARK: Ligatures

    private func draw(_ text: String, font: TerminalFont) throws -> Pixels {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        let renderer = try TerminalRenderer(device: device, font: font, theme: Self.black)
        let grid = TerminalGrid(columns: text.unicodeScalars.count + 2, rows: 1, foreground: 0xFFFFFF)
        for (x, scalar) in text.unicodeScalars.enumerated() { grid[x + 1, 0] = TerminalCell(scalar: scalar.value, foreground: 0xFFFFFF) }
        grid.cursor.visible = false
        let cell = font.cellSize
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int((CGFloat(grid.columns) * cell.width * scale).rounded(.up)),
                                                                  height: Int((cell.height * scale).rounded(.up)), mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        try XCTUnwrap(renderer.draw(grid, scale: scale, into: texture)).waitUntilCompleted()
        return Pixels(texture)
    }

    /// A font without ligatures (Side's default, Menlo here) looks exactly as it did a glyph a cell.
    func testShapingChangesNothingForAFontWithoutLigatures() throws {
        var unshaped = font
        unshaped.ligatures = false
        for text in ["fn main() -> i32 { a != b }", "*bold* and plain", "x => y  <= z"] {
            XCTAssertEqual(try draw(text, font: font), try draw(text, font: unshaped), text)
        }
    }

    /// "fi" in Helvetica is one glyph for two cells: the run was shaped, not drawn a cell at a time.
    func testARunIsShapedWithItsLigatures() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        let renderer = try TerminalRenderer(device: device, font: TerminalFont(name: "Helvetica", size: 13), theme: Self.black)
        let run = try XCTUnwrap(renderer.shaped("fi", face: [], scale: scale))
        XCTAssertEqual(run.count, 1, "one ligature glyph")
        XCTAssertEqual(run.first?.cell, 0, "starting at the first cell")
    }

    /// A character the font doesn't have comes from a fallback font with its own advance; the run
    /// isn't shaped, so nothing after it drifts out of its cell.
    func testARunWithAFallbackCharacterIsDrawnACellAtATime() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        let renderer = try TerminalRenderer(device: device, font: font, theme: Self.black)
        XCTAssertNil(renderer.shaped("a\u{16A0}b", face: [], scale: scale), "ᚠ isn't in Menlo")
        XCTAssertNotNil(renderer.shaped("ab", face: [], scale: scale))
    }

    /// With a ligature font (Fira Code, where it's installed), `!=` draws as its ligature.
    func testFiraCodesLigaturesAreDrawn() throws {
        let fira = CTFontCreateWithName("FiraCodeNFM-Reg" as CFString, 13, nil)
        try XCTSkipUnless((CTFontCopyPostScriptName(fira) as String).hasPrefix("FiraCodeNFM"), "Fira Code isn't installed")
        var plain = TerminalFont(fira)
        plain.ligatures = false
        XCTAssertNotEqual(try draw("a != b", font: TerminalFont(fira)), try draw("a != b", font: plain))
        XCTAssertEqual(try draw("a b c", font: TerminalFont(fira)), try draw("a b c", font: plain), "no ligature, no change")
    }

    /// Composing text is drawn at the cursor, over what's there, underlined.
    func testComposingTextAtTheCursor() throws {
        let renderer = try makeRenderer()
        let grid = TerminalGrid(columns: 8, rows: 1, foreground: 0xFFFFFF)
        for x in 0..<8 { grid[x, 0] = TerminalCell(scalar: UInt32(UInt8(ascii: "x")), foreground: 0xFF0000) }
        grid.cursor = TerminalCursor(column: 2, row: 0)
        renderer.preedit = "日本"
        let pixels = try render(grid, renderer: renderer)
        let red: (Pixels.RGBA) -> Bool = { $0.r > 150 && $0.g < 80 }
        let white: (Pixels.RGBA) -> Bool = { $0.r > 150 && $0.g > 150 }
        XCTAssertEqual(pixels.count(in: cellRect(column: 2, row: 0, span: 4), red), 0, "the cells under it are covered")
        XCTAssertGreaterThan(pixels.count(in: cellRect(column: 2, row: 0, span: 4), white), 40, "two wide characters across four cells")
        XCTAssertGreaterThan(pixels.count(in: cellRect(column: 0, row: 0), red), 5, "the rest of the row as it was")
    }

    /// The renderer lives on the render thread: made and used there, away from the main actor.
    func testItDrawsOnAThreadOfItsOwn() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        let font = self.font
        let done = expectation(description: "drawn off the main thread")
        nonisolated(unsafe) var lit = 0
        let thread = Thread {
            XCTAssertFalse(Thread.isMainThread)
            guard let renderer = try? TerminalRenderer(device: device, font: font, theme: Self.black) else { return }
            let grid = TerminalGrid(columns: 4, rows: 1, foreground: 0xFFFFFF)
            grid[0, 0] = TerminalCell(scalar: UInt32(UInt8(ascii: "#")), foreground: 0xFFFFFF)
            grid.cursor.visible = false
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 64, height: 40, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .shared
            guard let texture = device.makeTexture(descriptor: descriptor) else { return }
            renderer.draw(grid, scale: 2, into: texture)?.waitUntilCompleted()
            lit = Pixels(texture).count(in: (0..<16, 0..<40)) { $0.r > 100 }
            done.fulfill()
        }
        thread.start()
        wait(for: [done], timeout: 10)
        XCTAssertGreaterThan(lit, 10)
    }
}

@MainActor
final class AlloyTerminalViewTests: XCTestCase {
    final class Screen: TerminalGridSource, @unchecked Sendable {
        var text = ""
        var cursor = TerminalCursor(visible: false)
        func snapshot(into grid: TerminalGrid) -> Bool {
            for (i, scalar) in text.unicodeScalars.enumerated() where i < grid.columns {
                grid[i, 0] = TerminalCell(scalar: scalar.value, foreground: 0xFFFFFF)
            }
            grid.dirty[0] = true
            grid.cursor = cursor
            return true
        }
    }

    /// A focused, blinking cursor blinks on a timer; typing shows it again; unfocused or steady,
    /// no timer runs.
    func testTheCursorBlinksWhileFocused() throws {
        let view = try AlloyTerminalView(frame: NSRect(x: 0, y: 0, width: 200, height: 60), font: TerminalFont(name: "Menlo", size: 13),
                                         theme: TerminalRendererTests.black)
        let screen = Screen()
        screen.cursor = TerminalCursor(column: 0, row: 0, visible: true, shape: .block, blinking: true)
        view.source = screen
        _ = view.renderOffscreen()
        XCTAssertFalse(view.isBlinking, "not focused")

        view.setFocused(true)
        view.setNeedsFrame()
        let off = Date().addingTimeInterval(2)
        while view.blinkOn, Date() < off { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertTrue(view.isBlinking)
        XCTAssertFalse(view.blinkOn, "blinked off within the interval")

        view.resetBlink()
        XCTAssertTrue(view.blinkOn, "typing shows it")

        view.setFocused(false)
        XCTAssertFalse(view.isBlinking)
        XCTAssertTrue(view.blinkOn)

        screen.cursor.blinking = false
        view.setFocused(true)
        view.setNeedsFrame()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertFalse(view.isBlinking, "a steady cursor")
    }

    func testTheGridFollowsTheViewsSize() throws {
        let font = TerminalFont(name: "Menlo", size: 13)
        let cell = font.cellSize
        let view = try AlloyTerminalView(frame: NSRect(x: 0, y: 0, width: cell.width * 80, height: cell.height * 24), font: font,
                                         theme: TerminalRendererTests.black)
        XCTAssertEqual(view.columns, 80)
        XCTAssertEqual(view.rows, 24)
        var reported: (Int, Int)?
        view.onGridResize = { reported = ($0, $1) }
        view.setFrameSize(NSSize(width: cell.width * 100 + 3, height: cell.height * 30 + 3))
        XCTAssertEqual(reported?.0, 100)
        XCTAssertEqual(reported?.1, 30)
    }

    func testItDrawsWhatTheSourceHolds() throws {
        let font = TerminalFont(name: "Menlo", size: 13)
        let view = try AlloyTerminalView(frame: NSRect(x: 0, y: 0, width: 200, height: 60), font: font, theme: TerminalRendererTests.black)
        let screen = Screen()
        screen.text = "####"
        view.source = screen
        let texture = try XCTUnwrap(view.renderOffscreen())
        let lit = Pixels(texture).count(in: (0..<Int(font.cellSize.width * 2 * 4), 0..<Int(font.cellSize.height * 2))) { $0.r > 100 }
        XCTAssertGreaterThan(lit, 40)
    }

    func testMarkedTextUntilItsCommitted() throws {
        let view = try AlloyTerminalView(frame: NSRect(x: 0, y: 0, width: 200, height: 60), font: TerminalFont(name: "Menlo", size: 13),
                                         theme: TerminalRendererTests.black)
        var typed: [String] = []
        view.onText = { typed.append($0) }
        view.setMarkedText("にほ", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertEqual(view.markedRange(), NSRange(location: 0, length: 2))
        XCTAssertEqual(typed, [], "nothing reaches the program while composing")
        view.insertText("日本", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(view.hasMarkedText())
        XCTAssertEqual(typed, ["日本"])
        view.setMarkedText("´", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.unmarkText()
        XCTAssertFalse(view.hasMarkedText(), "cancelled")
    }

    func testTypedTextComesBackThroughOnText() throws {
        let view = try AlloyTerminalView(frame: NSRect(x: 0, y: 0, width: 200, height: 60), font: TerminalFont(name: "Menlo", size: 13),
                                         theme: TerminalRendererTests.black)
        var typed: [String] = []
        view.onText = { typed.append($0) }
        view.insertText("é", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(typed, ["é"])
    }
}

/// ALLOY_TERMINAL_SNAPSHOT=/path.png: a sample screen, written for the eye (skipped otherwise).
final class TerminalSnapshotTests: XCTestCase {
    func testSnapshot() throws {
        guard let path = ProcessInfo.processInfo.environment["ALLOY_TERMINAL_SNAPSHOT"] else { throw XCTSkip("set ALLOY_TERMINAL_SNAPSHOT") }
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        // ALLOY_TERMINAL_SNAPSHOT_FONT: another font, a ligature font's for instance.
        let font = TerminalFont(name: ProcessInfo.processInfo.environment["ALLOY_TERMINAL_SNAPSHOT_FONT"] ?? "Menlo", size: 13)
        let renderer = try TerminalRenderer(device: device, font: font, theme: TerminalTheme(background: SIMD4(0.12, 0.12, 0.13, 1), cursor: 0xD0D0D0))
        let lines: [(String, UInt32, UInt32?, TerminalCell.Style)] = [
            ("$ git status", 0xD0D0D0, nil, []),
            ("a != b => c <= d -> e === f ... www", 0xC678DD, nil, []),
            ("On branch main — bold", 0xE5C07B, nil, [.bold]),
            ("italic, underline, strike", 0x61AFEF, nil, [.italic]),
            ("underlined text here", 0x98C379, nil, []),
            ("struck through text", 0xE06C75, nil, [.strikethrough]),
            (" selection-ish background ", 0x101010, 0x61AFEF, []),
            ("emoji 🙂 flag 🇯🇵 e\u{301}", 0xD0D0D0, nil, []),
            ("╭──┬──╮ ┏━━┓ ┌┄┄┐ ▁▂▃▄▅▆▇█ ░▒▓", 0x98C379, nil, []),
            ("│  ┼  │ ┃  ┃ ╎  ╎ ▖▗▘▙▚▛▜▝▞▟ ▌▐", 0x98C379, nil, []),
            ("╰──┴──╯ ┗━━┛ └┈┈┘ ⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏", 0x98C379, nil, []),
            ("\u{E0B6} repo \u{E0B4}\u{E0B0} main \u{E0B2} \u{E0B1} \u{E0B3}", 0x3B55C9, nil, []),
        ]
        let grid = TerminalGrid(columns: 60, rows: lines.count + 2, foreground: 0xD0D0D0)
        for (y, line) in lines.enumerated() {
            var x = 0
            for character in line.0 where x < grid.columns {
                let scalars = character.unicodeScalars
                let wide = character.unicodeScalars.first.map { $0.properties.isEmojiPresentation || (0x1100...0x9FFF).contains($0.value) } ?? false
                var style = line.3
                if wide { style.insert(.wide) }
                grid[x, y] = TerminalCell(scalar: scalars.count == 1 ? scalars.first!.value : 0, cluster: scalars.count > 1 ? String(character) : nil,
                                          foreground: line.1, background: line.2, style: style,
                                          underline: y == 3 ? [.single, .double, .curly, .dotted][min(3, x / 5)] : .none,
                                          underlineColor: y == 3 && x >= 10 ? 0xE06C75 : nil)
                if wide, x + 1 < grid.columns { grid[x + 1, y] = TerminalCell(foreground: line.1, background: line.2, style: .spacer); x += 1 }
                x += 1
            }
        }
        // The powerline row: text on the segment's color between its caps.
        for x in 1...6 { grid[x, 10].background = 0x3B55C9; grid[x, 10].foreground = 0xFFFFFF }
        grid[0, 12] = TerminalCell(scalar: UInt32(UInt8(ascii: "$")), foreground: 0xD0D0D0)
        grid.cursor = TerminalCursor(column: 2, row: 12, visible: true, shape: .block)
        let cell = font.cellSize
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int(CGFloat(grid.columns) * cell.width * 2),
                                                                  height: Int(CGFloat(grid.rows) * (cell.height * 2).rounded()), mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        renderer.draw(grid, scale: 2, into: texture)?.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        texture.getBytes(&bytes, bytesPerRow: texture.width * 4, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: texture.width, height: texture.height, bitsPerComponent: 8, bytesPerRow: texture.width * 4,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        let png = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage())).representation(using: .png, properties: [:])
        try XCTUnwrap(png).write(to: URL(fileURLWithPath: path))
    }
}

/// A texture's pixels, read back as BGRA.
struct Pixels: Equatable {
    struct RGBA { let r: UInt8, g: UInt8, b: UInt8, a: UInt8 }
    let width: Int, height: Int
    private let bytes: [UInt8]

    init(_ texture: MTLTexture) {
        width = texture.width
        height = texture.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        self.bytes = bytes
    }

    func count(in rect: (x: Range<Int>, y: Range<Int>), _ test: (RGBA) -> Bool) -> Int {
        var n = 0
        for y in rect.y where y >= 0 && y < height {
            for x in rect.x where x >= 0 && x < width {
                let i = (y * width + x) * 4
                if test(RGBA(r: bytes[i + 2], g: bytes[i + 1], b: bytes[i], a: bytes[i + 3])) { n += 1 }
            }
        }
        return n
    }
}
