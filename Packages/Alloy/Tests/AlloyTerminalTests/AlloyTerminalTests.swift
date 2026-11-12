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
        func snapshot(into grid: TerminalGrid) -> Bool {
            for (i, scalar) in text.unicodeScalars.enumerated() where i < grid.columns {
                grid[i, 0] = TerminalCell(scalar: scalar.value, foreground: 0xFFFFFF)
            }
            grid.dirty[0] = true
            grid.cursor.visible = false
            return true
        }
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
        let font = TerminalFont(name: "Menlo", size: 13)
        let renderer = try TerminalRenderer(device: device, font: font, theme: TerminalTheme(background: SIMD4(0.12, 0.12, 0.13, 1), cursor: 0xD0D0D0))
        let lines: [(String, UInt32, UInt32?, TerminalCell.Style)] = [
            ("$ git status", 0xD0D0D0, nil, []),
            ("On branch main — bold", 0xE5C07B, nil, [.bold]),
            ("italic, underline, strike", 0x61AFEF, nil, [.italic]),
            ("underlined text here", 0x98C379, nil, [.underline]),
            ("struck through text", 0xE06C75, nil, [.strikethrough]),
            (" selection-ish background ", 0x101010, 0x61AFEF, []),
            ("emoji 🙂 flag 🇯🇵 e\u{301}", 0xD0D0D0, nil, []),
        ]
        let grid = TerminalGrid(columns: 40, rows: lines.count + 2, foreground: 0xD0D0D0)
        for (y, line) in lines.enumerated() {
            var x = 0
            for character in line.0 where x < grid.columns {
                let scalars = character.unicodeScalars
                let wide = character.unicodeScalars.first.map { $0.properties.isEmojiPresentation || (0x1100...0x9FFF).contains($0.value) } ?? false
                var style = line.3
                if wide { style.insert(.wide) }
                grid[x, y] = TerminalCell(scalar: scalars.count == 1 ? scalars.first!.value : 0, cluster: scalars.count > 1 ? String(character) : nil,
                                          foreground: line.1, background: line.2, style: style)
                if wide, x + 1 < grid.columns { grid[x + 1, y] = TerminalCell(foreground: line.1, background: line.2, style: .spacer); x += 1 }
                x += 1
            }
        }
        grid[0, 8] = TerminalCell(scalar: UInt32(UInt8(ascii: "$")), foreground: 0xD0D0D0)
        grid.cursor = TerminalCursor(column: 2, row: 8, visible: true, shape: .block)
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
struct Pixels {
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
