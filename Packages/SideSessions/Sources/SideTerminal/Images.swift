import CoreGraphics
import Foundation
import GhosttyVt
import ImageIO

/// One image placement on screen, as the render state lists it (kitty graphics: placed at a
/// cell, by Unicode placeholders, or relative to another image), already positioned and sized.
public struct ScreenImage: Equatable, Sendable {
    public enum Layer: Int, Sendable, Comparable {
        case belowBackground, belowText, aboveText
        public static func < (a: Layer, b: Layer) -> Bool { a.rawValue < b.rawValue }
    }
    public struct Key: Hashable, Sendable {
        public let id: UInt32
        public let generation: UInt64
    }
    public var key: Key
    public var layer: Layer
    /// The order within the layer, lowest first.
    public var z: Int32
    /// The top-left cell, relative to the viewport; above or left of it when negative.
    public var column: Int32
    public var row: Int32
    /// From that cell's top-left corner, in the terminal's cell units (points here).
    public var offsetX: UInt32
    public var offsetY: UInt32
    /// The size to draw at, in the same units.
    public var width: UInt32
    public var height: UInt32
    /// The part of the image to draw, in image pixels.
    public var sourceX: UInt32
    public var sourceY: UInt32
    public var sourceWidth: UInt32
    public var sourceHeight: UInt32
}

/// An image's pixels, handed over once per generation while it's on screen: 8-bit RGBA, rows top
/// first, no padding, alpha not premultiplied.
public struct ScreenImagePixels: Sendable {
    public let key: ScreenImage.Key
    public let width: Int
    public let height: Int
    public let rgba: [UInt8]
}

/// The kitty graphics protocol's setup: PNG images decoded by ImageIO, for every terminal.
enum KittyGraphics {
    /// The storage limit, as Ghostty's default (image-storage-limit).
    static let storageLimit: UInt64 = 320 * 1024 * 1024

    static let installDecoder: Void = {
        let decode: GhosttySysDecodePngFn = { _, allocator, data, length, out in
            guard let data, let out, length > 0,
                  let source = CGImageSourceCreateWithData(Data(bytes: data, count: length) as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }
            let width = image.width, height = image.height
            guard width > 0, height > 0, width <= 16_384, height <= 16_384 else { return false }
            let size = width * height * 4
            guard let buffer = ghostty_alloc(allocator, size) else { return false }
            guard straightRGBA(image, into: buffer) else {
                ghostty_free(allocator, buffer, size)
                return false
            }
            out.pointee = GhosttySysImage(width: UInt32(width), height: UInt32(height), data: buffer, data_len: size)
            return true
        }
        _ = ghostty_sys_set(GHOSTTY_SYS_OPT_DECODE_PNG, unsafeBitCast(decode, to: UnsafeRawPointer.self))
    }()

    /// An image's pixels as 8-bit straight RGBA, with the file's own values: no color matching,
    /// as Ghostty's decoder hands them over. Drawing into a bitmap context would convert them to
    /// the context's color space (and dither), so the decoded bytes are read directly when
    /// they're 8-bit RGB(A) or gray(+alpha), the usual PNGs. Other layouts (16-bit, indexed) are
    /// drawn in the image's own color space where it's RGB, so nothing is converted.
    static func straightRGBA(_ image: CGImage, into buffer: UnsafeMutablePointer<UInt8>) -> Bool {
        let width = image.width, height = image.height
        let alpha = image.alphaInfo
        let order = image.bitmapInfo.intersection(.byteOrderMask)
        let model = image.colorSpace?.model
        let channels = image.bitsPerPixel / 8
        let hasAlpha = alpha == .last || alpha == .premultipliedLast
        let layoutKnown = image.bitsPerComponent == 8 && (order == [] || order == .byteOrder32Big || order == .byteOrderDefault)
            && !image.bitmapInfo.contains(.floatComponents)
            && ((model == .rgb && ((channels == 4 && (hasAlpha || alpha == .noneSkipLast)) || (channels == 3 && alpha == .none)))
                || (model == .monochrome && ((channels == 2 && hasAlpha) || (channels == 1 && alpha == .none))))
        if layoutKnown, let provided = image.dataProvider?.data, CFDataGetLength(provided) >= image.bytesPerRow * (height - 1) + width * channels {
            let bytes = CFDataGetBytePtr(provided)!
            let gray = model == .monochrome
            for y in 0..<height {
                let row = bytes + y * image.bytesPerRow
                for x in 0..<width {
                    let p = row + x * channels, o = buffer + (y * width + x) * 4
                    if gray {
                        o[0] = p[0]; o[1] = p[0]; o[2] = p[0]
                        o[3] = channels == 2 ? p[1] : 255
                    } else {
                        o[0] = p[0]; o[1] = p[1]; o[2] = p[2]
                        o[3] = hasAlpha ? p[3] : 255
                    }
                }
            }
            if alpha == .premultipliedLast { unpremultiply(buffer, count: width * height) }
            return true
        }
        let space = model == .rgb ? image.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: buffer, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Drawn premultiplied (all CoreGraphics offers for RGBA), then straightened.
        unpremultiply(buffer, count: width * height)
        return true
    }

    private static func unpremultiply(_ buffer: UnsafeMutablePointer<UInt8>, count: Int) {
        for i in stride(from: 0, to: count * 4, by: 4) {
            let alpha = Int(buffer[i + 3])
            guard alpha > 0, alpha < 255 else { continue }
            for c in 0..<3 { buffer[i + c] = UInt8(min(255, (Int(buffer[i + c]) * 255 + alpha / 2) / alpha)) }
        }
    }

    /// An image's pixels from the storage, as RGBA, under the terminal's lock.
    static func pixels(_ graphics: GhosttyKittyGraphics, key: ScreenImage.Key) -> ScreenImagePixels? {
        guard let image = ghostty_kitty_graphics_image(graphics, key.id) else { return nil }
        var width: UInt32 = 0, height: UInt32 = 0
        var format = GHOSTTY_KITTY_IMAGE_FORMAT_RGBA
        var data: UnsafePointer<UInt8>?
        var length = 0
        guard ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_WIDTH, &width) == GHOSTTY_SUCCESS,
              ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_HEIGHT, &height) == GHOSTTY_SUCCESS,
              ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_FORMAT, &format) == GHOSTTY_SUCCESS,
              ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_DATA_PTR, &data) == GHOSTTY_SUCCESS,
              ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_DATA_LEN, &length) == GHOSTTY_SUCCESS,
              let data, width > 0, height > 0 else { return nil }
        let count = Int(width) * Int(height)
        let source = UnsafeBufferPointer(start: data, count: length)
        var rgba = [UInt8](repeating: 255, count: count * 4)
        switch format {
        case GHOSTTY_KITTY_IMAGE_FORMAT_RGBA:
            guard length >= count * 4 else { return nil }
            rgba.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: data, count: count * 4) }
        case GHOSTTY_KITTY_IMAGE_FORMAT_RGB:
            guard length >= count * 3 else { return nil }
            for p in 0..<count { for c in 0..<3 { rgba[p * 4 + c] = source[p * 3 + c] } }
        case GHOSTTY_KITTY_IMAGE_FORMAT_GRAY_ALPHA:
            guard length >= count * 2 else { return nil }
            for p in 0..<count { for c in 0..<3 { rgba[p * 4 + c] = source[p * 2] }; rgba[p * 4 + 3] = source[p * 2 + 1] }
        case GHOSTTY_KITTY_IMAGE_FORMAT_GRAY:
            guard length >= count else { return nil }
            for p in 0..<count { for c in 0..<3 { rgba[p * 4 + c] = source[p] } }
        default:
            return nil
        }
        return ScreenImagePixels(key: key, width: Int(width), height: Int(height), rgba: rgba)
    }
}
