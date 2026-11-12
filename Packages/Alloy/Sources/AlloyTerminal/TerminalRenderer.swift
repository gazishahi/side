import AlloyRender
import CoreText
import Foundation
import Metal
import QuartzCore

/// The faces a terminal draws with, made from one monospaced font: bold, italic and bold italic
/// come from CoreText's traits, falling back to the regular face where the family has none.
public struct TerminalFont: @unchecked Sendable {
    // @unchecked: CTFont is immutable and thread-safe.
    public let regular: CTFont
    public let bold: CTFont
    public let italic: CTFont
    public let boldItalic: CTFont

    public init(name: String, size: CGFloat) {
        self.init(CTFontCreateWithName(name as CFString, size, nil))
    }

    public init(_ font: CTFont) {
        let size = CTFontGetSize(font)
        regular = font
        bold = CTFontCreateCopyWithSymbolicTraits(font, size, nil, .traitBold, .traitBold) ?? font
        italic = CTFontCreateCopyWithSymbolicTraits(font, size, nil, .traitItalic, .traitItalic) ?? font
        boldItalic = CTFontCreateCopyWithSymbolicTraits(font, size, nil, [.traitBold, .traitItalic], [.traitBold, .traitItalic]) ?? bold
    }

    /// One cell, in points: the advance of "M" by the line's height (ascent, descent, leading).
    public var cellSize: CGSize {
        var glyph: CGGlyph = 0
        var m = UniChar(UInt8(ascii: "M"))
        CTFontGetGlyphsForCharacters(regular, &m, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(regular, .horizontal, &glyph, &advance, 1)
        return CGSize(width: advance.width, height: ceil(CTFontGetAscent(regular) + CTFontGetDescent(regular) + CTFontGetLeading(regular)))
    }

    func face(_ style: TerminalCell.Style) -> CTFont {
        switch (style.contains(.bold), style.contains(.italic)) {
        case (true, true): boldItalic
        case (true, false): bold
        case (false, true): italic
        case (false, false): regular
        }
    }
}

/// The colors the renderer adds of its own: the default background (its alpha is the view's
/// opacity) and the cursor's.
public struct TerminalTheme: Sendable, Equatable {
    /// RGBA, 0…1, not premultiplied.
    public var background: SIMD4<Float>
    /// 0xRRGGBB.
    public var cursor: UInt32
    /// RGBA, 0…1, not premultiplied: laid over selected cells.
    public var selection: SIMD4<Float>

    public init(background: SIMD4<Float>, cursor: UInt32, selection: SIMD4<Float> = SIMD4(0.35, 0.55, 1, 0.4)) {
        self.background = background
        self.cursor = cursor
        self.selection = selection
    }
}

/// Draws a `TerminalGrid` with Alloy's glyph atlas and quad shaders: backgrounds, decorations,
/// the cursor and glyphs as instanced quads in one draw call, a row's quads rebuilt only when that
/// row changed. Confined to one thread, the render thread (`AlloyTerminalView` keeps it on its
/// own): it owns a glyph atlas of its own, apart from the editors' on the main actor.
public final class TerminalRenderer {
    public let device: MTLDevice
    public let font: TerminalFont
    public var theme: TerminalTheme
    /// Frames drawn, for tests and measurements.
    public private(set) var frames = 0

    private let gpu: QuadPipeline
    private let atlas: GlyphAtlas
    private let cell: CGSize
    private let ascent: CGFloat

    /// One quad, laid out as AlloyRender's shaders read it (TextRenderer.shaders): a rectangle in
    /// pixels, its atlas region, a color and a kind (0 solid, 1 tinted glyph, 2 color glyph).
    struct Quad {
        var rect: SIMD4<Float>
        var uv: SIMD4<Float>
        var color: SIMD4<Float>
        var kind: Float
        var padding: SIMD3<Float> = .zero
    }

    private var backgroundQuads: [[Quad]] = []
    private var glyphQuads: [[Quad]] = []
    private var builtScale: CGFloat = 0
    private var builtRows = 0
    private var atlasGeneration = 0

    private struct GlyphKey: Hashable { let scalar: UInt32; let cluster: String?; let style: TerminalCell.Style }
    private struct Placed { let entry: AtlasEntry; let dx: CGFloat }
    private var glyphCache: [GlyphKey: [Placed]] = [:]

    private var ring: [MTLBuffer] = []
    private var ringIndex = 0
    private let framesInFlight = DispatchSemaphore(value: 3)

    public init(device: MTLDevice, font: TerminalFont, theme: TerminalTheme, pixelFormat: MTLPixelFormat = .bgra8Unorm) throws {
        self.device = device
        self.font = font
        self.theme = theme
        gpu = try QuadPipeline.shared(device: device, pixelFormat: pixelFormat)
        atlas = GlyphAtlas(device: device)
        cell = font.cellSize
        ascent = CTFontGetAscent(font.regular)
    }

    /// Encodes `grid` into `target`, presents `drawable` if given, and commits. Rows the grid
    /// marks dirty are rebuilt and marked clean.
    @discardableResult
    public func draw(_ grid: TerminalGrid, scale: CGFloat, into target: MTLTexture, drawable: CAMetalDrawable? = nil,
                     completion: (@Sendable (MTLCommandBuffer) -> Void)? = nil) -> MTLCommandBuffer? {
        let quads = assemble(grid, scale: scale)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let bg = theme.background
        // Premultiplied, as the layer composites it and the quads blend.
        pass.colorAttachments[0].clearColor = MTLClearColor(red: Double(bg.x * bg.w), green: Double(bg.y * bg.w), blue: Double(bg.z * bg.w), alpha: Double(bg.w))
        framesInFlight.wait()
        guard let buffer = gpu.queue.makeCommandBuffer(), let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else {
            framesInFlight.signal()
            return nil
        }
        let inFlight = framesInFlight
        buffer.addCompletedHandler { _ in inFlight.signal() }
        if !quads.isEmpty {
            let length = quads.count * MemoryLayout<Quad>.stride
            if ring.count < 3 {
                ring.append(device.makeBuffer(length: max(length, 1 << 20), options: .storageModeShared)!)
                ringIndex = ring.count - 1
            } else {
                ringIndex = (ringIndex + 1) % ring.count
            }
            if ring[ringIndex].length < length { ring[ringIndex] = device.makeBuffer(length: length * 2, options: .storageModeShared)! }
            quads.withUnsafeBytes { ring[ringIndex].contents().copyMemory(from: $0.baseAddress!, byteCount: length) }
            var viewport = SIMD2<Float>(Float(target.width), Float(target.height))
            var atlasSize = Float(atlas.size)
            encoder.setRenderPipelineState(gpu.pipeline)
            encoder.setVertexBuffer(ring[ringIndex], offset: 0, index: 0)
            encoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
            encoder.setFragmentTexture(atlas.texture, index: 0)
            encoder.setFragmentSamplerState(gpu.sampler, index: 0)
            encoder.setFragmentBytes(&atlasSize, length: MemoryLayout<Float>.size, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: quads.count)
        }
        encoder.endEncoding()
        if let drawable { buffer.present(drawable) }
        if let completion { buffer.addCompletedHandler(completion) }
        buffer.commit()
        frames += 1
        return buffer
    }

    // MARK: - Building quads

    func assemble(_ grid: TerminalGrid, scale: CGFloat) -> [Quad] {
        // A new scale or size invalidates every row; a restarted atlas, every cached glyph too.
        if scale != builtScale || grid.rows != builtRows || atlas.generation != atlasGeneration {
            if scale != builtScale || atlas.generation != atlasGeneration { glyphCache.removeAll() }
            builtScale = scale
            builtRows = grid.rows
            atlasGeneration = atlas.generation
            backgroundQuads = Array(repeating: [], count: grid.rows)
            glyphQuads = Array(repeating: [], count: grid.rows)
            for y in 0..<grid.rows { grid.dirty[y] = true }
        }
        for y in 0..<grid.rows where grid.dirty[y] {
            rebuild(row: y, of: grid, scale: scale)
            grid.dirty[y] = false
        }
        // An atlas that filled while rebuilding dropped entries rows already hold.
        if atlas.generation != atlasGeneration {
            atlasGeneration = atlas.generation
            glyphCache.removeAll()
            for y in 0..<grid.rows { rebuild(row: y, of: grid, scale: scale) }
        }
        var quads: [Quad] = []
        quads.reserveCapacity(grid.columns * grid.rows / 2 + 64)
        for row in backgroundQuads { quads += row }
        if let cursor = cursorQuad(grid, scale: scale) { quads.append(cursor) }
        for row in glyphQuads { quads += row }
        return quads
    }

    private func color(_ rgb: UInt32, alpha: Float = 1) -> SIMD4<Float> {
        SIMD4(Float((rgb >> 16) & 0xFF) / 255, Float((rgb >> 8) & 0xFF) / 255, Float(rgb & 0xFF) / 255, alpha)
    }

    private func metrics(_ scale: CGFloat) -> (width: Float, height: Float, baseline: Float) {
        (Float(cell.width * scale), Float((cell.height * scale).rounded()), Float((ascent * scale).rounded()))
    }

    private func cursorQuad(_ grid: TerminalGrid, scale: CGFloat) -> Quad? {
        let cursor = grid.cursor
        guard cursor.visible, cursor.row >= 0, cursor.row < grid.rows, cursor.column >= 0, cursor.column < grid.columns else { return nil }
        let (cw, ch, _) = metrics(scale)
        let x = (Float(cursor.column) * cw).rounded(.down), y = Float(cursor.row) * ch
        let thickness = Float(max(1, (scale * 1.5).rounded()))
        let rect: SIMD4<Float> = switch cursor.shape {
        case .block: SIMD4(x, y, cw.rounded(.up), ch)
        case .bar: SIMD4(x, y, thickness, ch)
        case .underline: SIMD4(x, y + ch - thickness, cw.rounded(.up), thickness)
        }
        return Quad(rect: rect, uv: .zero, color: color(theme.cursor, alpha: cursor.shape == .block ? 0.7 : 1), kind: 0)
    }

    private func rebuild(row y: Int, of grid: TerminalGrid, scale: CGFloat) {
        var backgrounds: [Quad] = [], glyphs: [Quad] = []
        let (cw, ch, baselineOffset) = metrics(scale)
        let top = Float(y) * ch
        let baseline = top + baselineOffset
        let line = Float(max(1, scale.rounded()))
        let rowStart = y * grid.columns
        // Backgrounds: one quad per run of cells with the same explicit color.
        var x = 0
        while x < grid.columns {
            guard let bg = grid.cells[rowStart + x].background else { x += 1; continue }
            var end = x + 1
            while end < grid.columns, grid.cells[rowStart + end].background == bg { end += 1 }
            let left = (Float(x) * cw).rounded(.down), right = (Float(end) * cw).rounded(.down)
            backgrounds.append(Quad(rect: SIMD4(left, top, right - left, ch), uv: .zero, color: color(bg), kind: 0))
            x = end
        }
        // The selection: one quad per run of selected cells, over their backgrounds.
        x = 0
        while x < grid.columns {
            guard grid.cells[rowStart + x].style.contains(.selected) else { x += 1; continue }
            var end = x + 1
            while end < grid.columns, grid.cells[rowStart + end].style.contains(.selected) { end += 1 }
            let left = (Float(x) * cw).rounded(.down), right = (Float(end) * cw).rounded(.down)
            backgrounds.append(Quad(rect: SIMD4(left, top, right - left, ch), uv: .zero, color: theme.selection, kind: 0))
            x = end
        }
        for x in 0..<grid.columns {
            let c = grid.cells[rowStart + x]
            let left = (Float(x) * cw).rounded(.down)
            let span = c.style.contains(.wide) ? cw * 2 : cw
            if c.style.contains(.underline) {
                backgrounds.append(Quad(rect: SIMD4(left, baseline + line, span.rounded(.up), line), uv: .zero, color: color(c.foreground), kind: 0))
            }
            if c.style.contains(.strikethrough) {
                let middle = top + (baselineOffset * 0.65).rounded()
                backgrounds.append(Quad(rect: SIMD4(left, middle, span.rounded(.up), line), uv: .zero, color: color(c.foreground), kind: 0))
            }
            guard !c.style.contains(.spacer), c.scalar > 32 || c.cluster != nil else { continue }
            for p in placed(c, scale: scale) where p.entry.region.width > 0 {
                let r = p.entry.region
                glyphs.append(Quad(rect: SIMD4(left + Float(p.dx * scale + p.entry.offset.x), baseline + Float(p.entry.offset.y), Float(r.width), Float(r.height)),
                                   uv: SIMD4(Float(r.minX), Float(r.minY), Float(r.width), Float(r.height)),
                                   color: p.entry.isColor ? SIMD4(1, 1, 1, 1) : color(c.foreground), kind: p.entry.isColor ? 2 : 1))
            }
        }
        backgroundQuads[y] = backgrounds
        glyphQuads[y] = glyphs
    }

    /// One cell's glyphs, cached by text and style: straight from the face when it has the
    /// character, else through CoreText, which falls back to another font and shapes clusters.
    private func placed(_ c: TerminalCell, scale: CGFloat) -> [Placed] {
        let style = c.style.intersection([.bold, .italic])
        let key = GlyphKey(scalar: c.scalar, cluster: c.cluster, style: style)
        if let known = glyphCache[key] { return known }
        let face = font.face(style)
        var result: [Placed] = []
        if c.cluster == nil, c.scalar < 0x10000 {
            var character = UniChar(c.scalar), glyph: CGGlyph = 0
            if CTFontGetGlyphsForCharacters(face, &character, &glyph, 1), glyph != 0 {
                if let entry = atlas.entry(font: face, glyph: glyph, subpixel: 0, scale: scale, isColor: false) { result = [Placed(entry: entry, dx: 0)] }
                glyphCache[key] = result
                return result
            }
        }
        let text = c.cluster ?? UnicodeScalar(c.scalar).map { String(Character($0)) } ?? " "
        let attributed = CFAttributedStringCreate(nil, text as CFString, [kCTFontAttributeName: face] as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attributed)
        for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let runFont = attributes[kCTFontAttributeName] as! CTFont
            let isColor = CTFontGetSymbolicTraits(runFont).contains(.traitColorGlyphs)
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count), positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            for i in 0..<count {
                if let entry = atlas.entry(font: runFont, glyph: glyphs[i], subpixel: 0, scale: scale, isColor: isColor) {
                    result.append(Placed(entry: entry, dx: positions[i].x))
                }
            }
        }
        glyphCache[key] = result
        return result
    }
}
