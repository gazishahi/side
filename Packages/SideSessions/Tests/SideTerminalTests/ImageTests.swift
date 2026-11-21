import CoreGraphics
import Foundation
import ImageIO
import SideTerminal
import UniformTypeIdentifiers
import XCTest

/// Kitty graphics through the reader: placements from the render state, pixels once per
/// generation, PNGs decoded by ImageIO.
final class ImageTests: XCTestCase {
    private func terminal() throws -> Terminal {
        let terminal = try Terminal(columns: 20, rows: 5)
        terminal.resize(columns: 20, rows: 5, cellWidth: 10, cellHeight: 20)
        return terminal
    }

    /// `ESC _ G <control>;<payload> ESC \`.
    private func kitty(_ control: String, _ payload: [UInt8] = []) -> [UInt8] {
        Array("\u{1b}_G\(control);\(Data(payload).base64EncodedString())\u{1b}\\".utf8)
    }

    func testARawImageIsPlacedAndItsPixelsHandedOverOnce() throws {
        let terminal = try terminal()
        let reader = ScreenReader(terminal: terminal)
        // A 2×2 RGB image, red green / blue white, shown at the cursor (row 1, column 3).
        let rgb: [UInt8] = [255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255]
        terminal.feed(Array("\r\n   ".utf8) + kitty("a=T,f=24,s=2,v=2,i=7,q=2", rgb))
        XCTAssertTrue(reader.update())
        XCTAssertEqual(reader.images.count, 1)
        let image = try XCTUnwrap(reader.images.first)
        XCTAssertEqual(image.key.id, 7)
        XCTAssertEqual(image.column, 3)
        XCTAssertEqual(image.row, 1)
        XCTAssertEqual([image.sourceWidth, image.sourceHeight], [2, 2])
        XCTAssertGreaterThan(image.width, 0)
        let pixels = try XCTUnwrap(reader.newImagePixels.first)
        XCTAssertEqual([pixels.width, pixels.height], [2, 2])
        XCTAssertEqual(Array(pixels.rgba.prefix(8)), [255, 0, 0, 255, 0, 255, 0, 255], "RGB comes out as opaque RGBA")

        terminal.feed(Array("more text".utf8))
        XCTAssertTrue(reader.update())
        XCTAssertFalse(reader.imagesChanged, "text alone doesn't change the list")
        XCTAssertTrue(reader.newImagePixels.isEmpty, "pixels handed over once")
        XCTAssertEqual(reader.images.count, 1)

        terminal.feed(kitty("a=d,d=I,i=7,q=2"))
        XCTAssertTrue(reader.update())
        XCTAssertTrue(reader.imagesChanged)
        XCTAssertTrue(reader.images.isEmpty, "deleted")
    }

    func testAPNGIsDecoded() throws {
        // A 3×1 PNG: transparent, half-transparent blue, opaque green.
        var pixels: [UInt8] = [0, 0, 0, 0, 0, 0, 128, 128, 0, 255, 0, 255]
        let context = try XCTUnwrap(CGContext(data: &pixels, width: 3, height: 1, bitsPerComponent: 8, bytesPerRow: 12,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let terminal = try terminal()
        let reader = ScreenReader(terminal: terminal)
        terminal.feed(kitty("a=T,f=100,i=9,q=2", [UInt8](data as Data)))
        XCTAssertTrue(reader.update())
        let decoded = try XCTUnwrap(reader.newImagePixels.first)
        XCTAssertEqual([decoded.width, decoded.height], [3, 1])
        XCTAssertEqual(decoded.rgba[3], 0, "transparent stays transparent")
        XCTAssertEqual(decoded.rgba[7], 128, "half-transparent")
        XCTAssertGreaterThan(decoded.rgba[6], 240, "its blue straightened, not left premultiplied: \(Array(decoded.rgba[4...7]))")
        XCTAssertEqual(Array(decoded.rgba[8...11]), [0, 255, 0, 255])
    }

    /// A PNG's own values, not color-matched: one tagged Display P3 keeps its numbers, as
    /// Ghostty's decoder keeps them (drawing into an sRGB bitmap would convert and dither).
    func testAPNGKeepsItsOwnValues() throws {
        var pixels: [UInt8] = [200, 100, 50, 255, 10, 220, 130, 255]
        let p3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let context = try XCTUnwrap(CGContext(data: &pixels, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 8, space: p3,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let terminal = try terminal()
        let reader = ScreenReader(terminal: terminal)
        terminal.feed(kitty("a=T,f=100,i=4,q=2", try png(XCTUnwrap(context.makeImage()))))
        XCTAssertTrue(reader.update())
        XCTAssertEqual(try XCTUnwrap(reader.newImagePixels.first).rgba, [200, 100, 50, 255, 10, 220, 130, 255])
    }

    func testAGrayPNGWithAlphaIsExpanded() throws {
        var pixels: [UInt8] = [90, 255, 40, 128]
        let gray = CGColorSpaceCreateDeviceGray()
        let context = try XCTUnwrap(CGContext(data: &pixels, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: gray,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let terminal = try terminal()
        let reader = ScreenReader(terminal: terminal)
        terminal.feed(kitty("a=T,f=100,i=5,q=2", try png(XCTUnwrap(context.makeImage()))))
        XCTAssertTrue(reader.update())
        let rgba = try XCTUnwrap(reader.newImagePixels.first).rgba
        XCTAssertEqual(Array(rgba[0...3]), [90, 90, 90, 255])
        XCTAssertEqual(rgba[7], 128)
        XCTAssertEqual(Int(rgba[4]), 80, accuracy: 2, "40 at half alpha, straightened: \(rgba)")
    }

    /// Unicode placeholders: the image is listed by row, and the cells show no text.
    func testPlaceholderCellsShowNoText() throws {
        let terminal = try terminal()
        let reader = ScreenReader(terminal: terminal)
        terminal.feed(kitty("a=T,U=1,f=24,s=2,v=2,i=6,c=2,r=1,q=2", [UInt8](repeating: 200, count: 12)))
        // Row 0's diacritic, then columns 0 and 1; the image id 6 in the foreground color.
        terminal.feed(Array("\u{1b}[38;5;6m\u{10EEEE}\u{0305}\u{0305}\u{10EEEE}\u{0305}\u{030D}\u{1b}[39mok".utf8))
        XCTAssertTrue(reader.update())
        XCTAssertEqual(reader.images.count, 1)
        var texts: [UInt32] = []
        reader.forEachChangedRow { y, cells in if y == 0 { texts = cells.prefix(4).map(\.scalar) } }
        XCTAssertEqual(texts, [0, 0, UInt32(UInt8(ascii: "o")), UInt32(UInt8(ascii: "k"))])
    }

    private func png(_ image: CGImage) throws -> [UInt8] {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return [UInt8](data as Data)
    }
}
