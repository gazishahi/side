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
    /// Whether runs of text are shaped together, for a font's ligatures and contextual
    /// alternates (Fira Code's `=>`, JetBrains Mono's `!=`). Off: a glyph a cell, as before.
    public var ligatures = true

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
    /// 0xRRGGBB: a search match's background and text, and the selected match's background, as
    /// Ghostty draws them (its search-background, search-foreground and
    /// search-selected-background defaults).
    public var searchMatch: UInt32
    public var searchText: UInt32
    public var searchSelected: UInt32

    public init(background: SIMD4<Float>, cursor: UInt32, selection: SIMD4<Float> = SIMD4(0.35, 0.55, 1, 0.4),
                searchMatch: UInt32 = 0xFFE082, searchText: UInt32 = 0x000000, searchSelected: UInt32 = 0xF2A57E) {
        self.background = background
        self.cursor = cursor
        self.selection = selection
        self.searchMatch = searchMatch
        self.searchText = searchText
        self.searchSelected = searchSelected
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
    /// Text an input method is composing (marked text), drawn at the cursor over the grid,
    /// underlined, until it's committed or cancelled. Empty: none.
    public var preedit = ""
    /// Whether the terminal has the keyboard. Unfocused, the cursor is a hollow block, as
    /// Ghostty and Terminal draw it, and doesn't blink.
    public var focused = true
    /// The blink's phase: false hides a blinking cursor. The view's timer flips it.
    public var blinkOn = true
    /// The link under the pointer, underlined in its text's colors (⌘ held, as Ghostty shows it).
    public var highlightedLink: [TerminalSpan] = []
    /// A search's matches in the viewport, and the selected one: drawn in the theme's search
    /// colors, the selected match in its own.
    public var searchMatches: [TerminalSpan] = [] { didSet { rowsToRebuild.formUnion((oldValue + searchMatches).map(\.row)) } }
    public var selectedMatch: [TerminalSpan] = [] { didSet { rowsToRebuild.formUnion((oldValue + selectedMatch).map(\.row)) } }
    /// Rows whose highlights changed though their cells didn't.
    private var rowsToRebuild = Set<Int>()

    /// For each column of a row: 0, or 1 in a match, 2 in the selected match.
    private func searchKinds(row y: Int, columns: Int) -> [UInt8]? {
        guard !searchMatches.isEmpty || !selectedMatch.isEmpty else { return nil }
        var kinds: [UInt8]?
        for (spans, kind) in [(searchMatches, UInt8(1)), (selectedMatch, UInt8(2))] {
            for span in spans where span.row == y {
                if kinds == nil { kinds = Array(repeating: 0, count: columns) }
                for x in span.columns where x >= 0 && x < columns { kinds![x] = max(kinds![x], kind) }
            }
        }
        return kinds
    }

    private let gpu: QuadPipeline
    private let atlas: GlyphAtlas
    private let cell: CGSize
    private let ascent: CGFloat
    /// The font's own underline: how far below the baseline, and how thick, in points.
    private let underlineOffset: CGFloat
    private let underlineThickness: CGFloat

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
        underlineOffset = -CTFontGetUnderlinePosition(font.regular)
        underlineThickness = CTFontGetUnderlineThickness(font.regular)
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
            if scale != builtScale || atlas.generation != atlasGeneration { glyphCache.removeAll(); runCache.removeAll() }
            builtScale = scale
            builtRows = grid.rows
            atlasGeneration = atlas.generation
            backgroundQuads = Array(repeating: [], count: grid.rows)
            glyphQuads = Array(repeating: [], count: grid.rows)
            for y in 0..<grid.rows { grid.dirty[y] = true }
        }
        for y in rowsToRebuild where y >= 0 && y < grid.rows { grid.dirty[y] = true }
        rowsToRebuild.removeAll()
        for y in 0..<grid.rows where grid.dirty[y] {
            rebuild(row: y, of: grid, scale: scale)
            grid.dirty[y] = false
        }
        // An atlas that filled while rebuilding dropped entries rows already hold.
        if atlas.generation != atlasGeneration {
            atlasGeneration = atlas.generation
            glyphCache.removeAll()
            runCache.removeAll()
            for y in 0..<grid.rows { rebuild(row: y, of: grid, scale: scale) }
        }
        var quads: [Quad] = []
        quads.reserveCapacity(grid.columns * grid.rows / 2 + 64)
        for row in backgroundQuads { quads += row }
        for row in glyphQuads { quads += row }
        quads += linkQuads(grid, scale: scale)
        // The cursor over the text: a block covers its cell and redraws the character in the
        // background's color, as terminals draw it; a bar or underline just sits there.
        if preedit.isEmpty, let shape = cursorShape(grid.cursor) {
            quads += cursorQuads(grid, shape: shape, scale: scale)
            if shape == .block { quads += cursorGlyph(grid, scale: scale) }
        }
        if !preedit.isEmpty { quads += preeditQuads(grid, scale: scale) }
        return quads
    }

    private func color(_ rgb: UInt32, alpha: Float = 1) -> SIMD4<Float> {
        SIMD4(Float((rgb >> 16) & 0xFF) / 255, Float((rgb >> 8) & 0xFF) / 255, Float(rgb & 0xFF) / 255, alpha)
    }

    private func metrics(_ scale: CGFloat) -> (width: Float, height: Float, baseline: Float) {
        (Float(cell.width * scale), Float((cell.height * scale).rounded()), Float((ascent * scale).rounded()))
    }

    /// The composing text at the cursor: the theme's background under it (hiding the cells it
    /// covers), its glyphs, and an underline, as macOS draws marked text.
    private func preeditQuads(_ grid: TerminalGrid, scale: CGFloat) -> [Quad] {
        let (cw, ch, baselineOffset) = metrics(scale)
        let row = min(max(0, grid.cursor.row), grid.rows - 1)
        let top = Float(row) * ch, baseline = top + baselineOffset
        let line = Float(max(1, scale.rounded()))
        var x = min(max(0, grid.cursor.column), grid.columns - 1)
        var background: [Quad] = [], glyphs: [Quad] = []
        let ink = color(theme.cursor)
        for character in preedit {
            let scalars = character.unicodeScalars
            let wide = scalars.first.map { Self.isWide($0.value) } ?? false
            let width = wide ? 2 : 1
            let left = (Float(x) * cw).rounded(.down), span = (Float(width) * cw).rounded(.up)
            background.append(Quad(rect: SIMD4(left, top, span, ch), uv: .zero, color: SIMD4(theme.background.x, theme.background.y, theme.background.z, 1), kind: 0))
            background.append(Quad(rect: SIMD4(left, baseline + line, span, line), uv: .zero, color: ink, kind: 0))
            var cell = TerminalCell(scalar: scalars.count == 1 ? scalars.first!.value : 0, cluster: scalars.count > 1 ? String(character) : nil, foreground: theme.cursor)
            if wide { cell.style.insert(.wide) }
            for p in placed(cell, scale: scale) where p.entry.region.width > 0 {
                let r = p.entry.region
                glyphs.append(Quad(rect: SIMD4(left + Float(p.dx * scale + p.entry.offset.x), baseline + Float(p.entry.offset.y), Float(r.width), Float(r.height)),
                                   uv: SIMD4(Float(r.minX), Float(r.minY), Float(r.width), Float(r.height)),
                                   color: p.entry.isColor ? SIMD4(1, 1, 1, 1) : ink, kind: p.entry.isColor ? 2 : 1))
            }
            x += width
        }
        return background + glyphs
    }

    /// East Asian wide and fullwidth characters, and emoji: two cells, for composing text that the
    /// terminal hasn't laid out yet.
    static func isWide(_ scalar: UInt32) -> Bool {
        switch scalar {
        case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6,
             0x1F300...0x1FAFF, 0x20000...0x3FFFD: true
        default: false
        }
    }

    /// The character under a block cursor, in the background's color.
    private func cursorGlyph(_ grid: TerminalGrid, scale: CGFloat) -> [Quad] {
        let c = grid[grid.cursor.column, grid.cursor.row]
        guard !c.style.contains(.spacer), c.scalar > 32 || c.cluster != nil else { return [] }
        let (cw, ch, baselineOffset) = metrics(scale)
        let left = (Float(grid.cursor.column) * cw).rounded(.down)
        let baseline = Float(grid.cursor.row) * ch + baselineOffset
        let ink = SIMD4<Float>(theme.background.x, theme.background.y, theme.background.z, 1)
        return placed(c, scale: scale).filter { $0.entry.region.width > 0 }.map { p in
            let r = p.entry.region
            return Quad(rect: SIMD4(left + Float(p.dx * scale + p.entry.offset.x), baseline + Float(p.entry.offset.y), Float(r.width), Float(r.height)),
                        uv: SIMD4(Float(r.minX), Float(r.minY), Float(r.width), Float(r.height)),
                        color: p.entry.isColor ? SIMD4(1, 1, 1, 1) : ink, kind: p.entry.isColor ? 2 : 1)
        }
    }

    /// An underline under each cell of the hovered link, in that cell's color.
    private func linkQuads(_ grid: TerminalGrid, scale: CGFloat) -> [Quad] {
        guard !highlightedLink.isEmpty else { return [] }
        let (cw, ch, baselineOffset) = metrics(scale)
        let y = Float((underlineOffset * scale).rounded()), height = Float(max(1, (underlineThickness * scale).rounded()))
        var quads: [Quad] = []
        for span in highlightedLink where span.row >= 0 && span.row < grid.rows {
            let baseline = Float(span.row) * ch + baselineOffset
            for x in span.columns where x >= 0 && x < grid.columns {
                let left = (Float(x) * cw).rounded(.down), right = (Float(x + 1) * cw).rounded(.down)
                quads.append(Quad(rect: SIMD4(left, baseline + y, right - left, height), uv: .zero, color: color(grid[x, span.row].foreground), kind: 0))
            }
        }
        return quads
    }

    /// The shape drawn this frame, or nil for none: hidden by the program, off the grid, or
    /// blinked off. Unfocused, a hollow block that doesn't blink.
    func cursorShape(_ cursor: TerminalCursor) -> TerminalCursor.Shape? {
        guard cursor.visible else { return nil }
        if !focused { return .hollowBlock }
        if cursor.blinking, !blinkOn { return nil }
        return cursor.shape
    }

    private func cursorQuads(_ grid: TerminalGrid, shape: TerminalCursor.Shape, scale: CGFloat) -> [Quad] {
        let cursor = grid.cursor
        guard cursor.row >= 0, cursor.row < grid.rows, cursor.column >= 0, cursor.column < grid.columns else { return [] }
        let (cw, ch, _) = metrics(scale)
        let x = (Float(cursor.column) * cw).rounded(.down), y = Float(cursor.row) * ch
        // A wide character's cell is two wide, and so is the block over it.
        let w = (grid[cursor.column, cursor.row].style.contains(.wide) ? cw * 2 : cw).rounded(.up)
        let thickness = Float(max(1, (scale * 1.5).rounded()))
        let ink = color(theme.cursor)
        let rects: [SIMD4<Float>] = switch shape {
        case .block: [SIMD4(x, y, w, ch)]
        case .bar: [SIMD4(x, y, thickness, ch)]
        case .underline: [SIMD4(x, y + ch - thickness, w, thickness)]
        case .hollowBlock:
            // An outline as thick as an underline, inside the cell.
            { let t = Float(max(1, (underlineThickness * scale).rounded()))
              return [SIMD4(x, y, w, t), SIMD4(x, y + ch - t, w, t), SIMD4(x, y + t, t, ch - 2 * t), SIMD4(x + w - t, y + t, t, ch - 2 * t)] }()
        }
        return rects.map { Quad(rect: $0, uv: .zero, color: ink, kind: 0) }
    }

    private func rebuild(row y: Int, of grid: TerminalGrid, scale: CGFloat) {
        var backgrounds: [Quad] = [], glyphs: [Quad] = []
        let (cw, ch, baselineOffset) = metrics(scale)
        let top = Float(y) * ch
        let baseline = top + baselineOffset
        let line = Float(max(1, scale.rounded()))
        let rowStart = y * grid.columns
        let underlineY = Float((underlineOffset * scale).rounded()), underlineHeight = Float(max(1, (underlineThickness * scale).rounded()))
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
        // Search matches: a run of cells in one kind of match, over everything else beneath the
        // text, and the text in the theme's search color.
        let search = searchKinds(row: y, columns: grid.columns)
        if let search {
            x = 0
            while x < grid.columns {
                let kind = search[x]
                guard kind != 0 else { x += 1; continue }
                var end = x + 1
                while end < grid.columns, search[end] == kind { end += 1 }
                let left = (Float(x) * cw).rounded(.down), right = (Float(end) * cw).rounded(.down)
                backgrounds.append(Quad(rect: SIMD4(left, top, right - left, ch), uv: .zero,
                                        color: color(kind == 2 ? theme.searchSelected : theme.searchMatch), kind: 0))
                x = end
            }
        }
        /// A cell's text color: its own, or the search's over a match.
        func ink(_ column: Int, _ cell: TerminalCell) -> SIMD4<Float> {
            if let search, search[column] != 0 { return color(theme.searchText) }
            return color(cell.foreground)
        }
        for x in 0..<grid.columns {
            let c = grid.cells[rowStart + x]
            let left = (Float(x) * cw).rounded(.down)
            let span = c.style.contains(.wide) ? cw * 2 : cw
            if c.underline != .none {
                underline(c.underline, color: color(c.underlineColor ?? c.foreground), left: left, width: span.rounded(.up),
                          y: baseline + underlineY, thickness: underlineHeight, cellBottom: top + ch, into: &backgrounds)
            }
            if c.style.contains(.overline) {
                backgrounds.append(Quad(rect: SIMD4(left, top, span.rounded(.up), underlineHeight), uv: .zero, color: color(c.foreground), kind: 0))
            }
            if c.style.contains(.strikethrough) {
                let middle = top + (baselineOffset * 0.65).rounded()
                backgrounds.append(Quad(rect: SIMD4(left, middle, span.rounded(.up), line), uv: .zero, color: color(c.foreground), kind: 0))
            }
        }
        // Glyphs: runs of plain text shaped together (ligatures, contextual alternates), and the
        // rest a cell at a time.
        x = 0
        var unshapedUntil = 0
        while x < grid.columns {
            let c = grid.cells[rowStart + x]
            let left = (Float(x) * cw).rounded(.down)
            if font.ligatures, x >= unshapedUntil, Self.shapeable(c), c.scalar > 32 {
                // The run: plain text in one face, spaces included, trailing spaces left off.
                let face = c.style.intersection([.bold, .italic])
                var end = x + 1
                while end < grid.columns, Self.shapeable(grid.cells[rowStart + end]),
                      grid.cells[rowStart + end].style.intersection([.bold, .italic]) == face { end += 1 }
                while end > x + 1, grid.cells[rowStart + end - 1].scalar <= 32 { end -= 1 }
                if end - x > 1 {
                    let text = String(String.UnicodeScalarView(grid.cells[(rowStart + x)..<(rowStart + end)].compactMap { UnicodeScalar(max(32, $0.scalar)) }))
                    guard let run = shaped(text, face: face, scale: scale) else {
                        unshapedUntil = end
                        continue
                    }
                    for g in run where g.entry.region.width > 0 {
                        let cell = grid.cells[rowStart + x + g.cell]
                        let r = g.entry.region
                        let cellLeft = (Float(x + g.cell) * cw).rounded(.down)
                        glyphs.append(Quad(rect: SIMD4(cellLeft + Float(g.dx * scale + g.entry.offset.x), baseline + Float(g.entry.offset.y), Float(r.width), Float(r.height)),
                                           uv: SIMD4(Float(r.minX), Float(r.minY), Float(r.width), Float(r.height)),
                                           color: g.entry.isColor ? SIMD4(1, 1, 1, 1) : ink(x + g.cell, cell), kind: g.entry.isColor ? 2 : 1))
                    }
                    x = end
                    continue
                }
            }
            defer { x += 1 }
            let span = c.style.contains(.wide) ? cw * 2 : cw
            guard !c.style.contains(.spacer), c.scalar > 32 || c.cluster != nil else { continue }
            if c.cluster == nil, let drawn = sprite(c.scalar, left: left, top: top, width: span, height: ch,
                                                    line: underlineHeight, color: ink(x, c)) {
                glyphs += drawn
                continue
            }
            for p in placed(c, scale: scale) where p.entry.region.width > 0 {
                let r = p.entry.region
                glyphs.append(Quad(rect: SIMD4(left + Float(p.dx * scale + p.entry.offset.x), baseline + Float(p.entry.offset.y), Float(r.width), Float(r.height)),
                                   uv: SIMD4(Float(r.minX), Float(r.minY), Float(r.width), Float(r.height)),
                                   color: p.entry.isColor ? SIMD4(1, 1, 1, 1) : ink(x, c), kind: p.entry.isColor ? 2 : 1))
            }
        }
        backgroundQuads[y] = backgrounds
        glyphQuads[y] = glyphs
    }

    /// An underline of one kind across `width` pixels, as solid quads: two lines for double,
    /// squares for dotted, dashes for dashed, and for curly a wave a pixel column at a time.
    private func underline(_ kind: TerminalCell.Underline, color: SIMD4<Float>, left: Float, width: Float, y: Float, thickness t: Float,
                           cellBottom: Float, into quads: inout [Quad]) {
        func bar(_ x: Float, _ y: Float, _ w: Float, _ h: Float) {
            quads.append(Quad(rect: SIMD4(x, y, w, h), uv: .zero, color: color, kind: 0))
        }
        switch kind {
        case .none:
            return
        case .single:
            bar(left, y, width, t)
        case .double:
            // The second line below the first, kept inside the cell.
            let second = min(y + t * 2, cellBottom - t)
            bar(left, max(y - t, second - t * 2), width, t)
            bar(left, second, width, t)
        case .dotted:
            var x = left
            while x < left + width { bar(x, y, min(t, left + width - x), t); x += t * 2 }
        case .dashed:
            let dash = max(t * 3, (width / 3).rounded()), gap = max(t * 2, (width / 6).rounded())
            var x = left
            while x < left + width { bar(x, y, min(dash, left + width - x), t); x += dash + gap }
        case .curly:
            // One full wave per cell width, its height twice the thickness, in pixel columns.
            let amplitude = max(1, t), step: Float = 1
            var x = left
            while x < left + width {
                let phase = (x - left) / max(1, width) * 2 * .pi
                bar(x, (y + amplitude * (1 - cos(phase))).rounded(), step, t)
                x += step
            }
        }
    }

    /// A cell that can join a shaped run: one Basic Multilingual Plane scalar (so a UTF-16 unit
    /// is a cell), narrow, and not a character drawn to the cell. An empty cell counts as a space.
    static func shapeable(_ c: TerminalCell) -> Bool {
        guard c.cluster == nil, !c.style.contains(.wide), !c.style.contains(.spacer), c.scalar < 0x10000 else { return false }
        switch c.scalar {
        case 0x2500...0x259F, 0x2800...0x28FF, 0xE0B0...0xE0B6: return false
        // Right-to-left scripts: CoreText would reorder them, and a cell's glyph has to stay in
        // its cell. They keep a glyph a cell, as Ghostty does with bidi off.
        case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF: return false
        default: return true
        }
    }

    private struct RunKey: Hashable { let text: String; let face: TerminalCell.Style }
    struct RunGlyph { let glyph: CGGlyph; let entry: AtlasEntry; let cell: Int; let dx: CGFloat }
    /// nil: a run the shaper can't place cell for cell (a fallback font's different advance would
    /// push every glyph after it), drawn a cell at a time instead.
    private var runCache: [RunKey: [RunGlyph]?] = [:]

    /// A run of text shaped by CoreText, with its ligatures and contextual alternates: each glyph
    /// with the cell it starts at (its string index; a UTF-16 unit is a cell here) and its
    /// offset from that cell in points, near zero but for a glyph a font shifts. Cached by text
    /// and face, as Ghostty's shaper caches its runs.
    func shaped(_ text: String, face: TerminalCell.Style, scale: CGFloat) -> [RunGlyph]? {
        let key = RunKey(text: text, face: face)
        if let known = runCache[key] { return known }
        if runCache.count > 4096 { runCache.removeAll() }
        let base = font.face(face)
        let attributed = CFAttributedStringCreate(nil, text as CFString, [kCTFontAttributeName: base, kCTLigatureAttributeName: 1] as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attributed)
        var result: [RunGlyph] = []
        for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let runFont = attributes[kCTFontAttributeName] as! CTFont
            let isColor = CTFontGetSymbolicTraits(runFont).contains(.traitColorGlyphs)
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count), positions = [CGPoint](repeating: .zero, count: count)
            guard CFEqual(runFont, base), !CTRunGetStatus(run).contains(.rightToLeft) else {
                runCache[key] = .some(nil)
                return nil
            }
            var indices = [CFIndex](repeating: 0, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            CTRunGetStringIndices(run, CFRange(location: 0, length: count), &indices)
            for i in 0..<count {
                let cell = indices[i]
                guard let entry = atlas.entry(font: runFont, glyph: glyphs[i], subpixel: 0, scale: scale, isColor: isColor) else { continue }
                result.append(RunGlyph(glyph: glyphs[i], entry: entry, cell: cell, dx: positions[i].x - CGFloat(cell) * self.cell.width))
            }
        }
        runCache[key] = result
        return result
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
