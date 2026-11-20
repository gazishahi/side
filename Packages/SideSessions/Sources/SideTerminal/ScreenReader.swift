import Foundation
import GhosttyVt

/// One cell of the screen as the renderer should draw it: colors resolved to RGB (palette,
/// inverse and faint applied), the text, and the style.
public struct ScreenCell: Equatable, Sendable {
    public struct Style: OptionSet, Sendable, Hashable {
        public let rawValue: UInt16
        public init(rawValue: UInt16) { self.rawValue = rawValue }
        public static let bold = Style(rawValue: 1 << 0)
        public static let italic = Style(rawValue: 1 << 1)
        public static let strikethrough = Style(rawValue: 1 << 2)
        public static let overline = Style(rawValue: 1 << 3)
        public static let blink = Style(rawValue: 1 << 4)
        /// Drawn as blank (its text is still there for copying).
        public static let invisible = Style(rawValue: 1 << 5)
        /// The left half of a wide character.
        public static let wide = Style(rawValue: 1 << 6)
        /// The right half of a wide character: nothing of its own.
        public static let spacer = Style(rawValue: 1 << 7)
        /// Inside the selection.
        public static let selected = Style(rawValue: 1 << 8)
    }

    public enum Underline: Sendable, Equatable { case none, single, double, curly, dotted, dashed }

    public var scalar: UInt32 = 0
    /// The grapheme when it's more than one scalar.
    public var cluster: String?
    public var foreground: UInt32 = 0
    /// nil: the default background.
    public var background: UInt32?
    public var style: Style = []
    public var underline: Underline = .none
    /// 0xRRGGBB (SGR 58), or nil for the text's color.
    public var underlineColor: UInt32?

    public init() {}
}

public struct ScreenCursor: Equatable, Sendable {
    public enum Shape: Sendable, Equatable { case bar, block, underline, hollowBlock }
    public var column = 0
    public var row = 0
    /// In the viewport and not hidden by the program.
    public var visible = true
    public var blinking = false
    public var shape: Shape = .block

    public init() {}
}

/// The render thread's view of a `Terminal`: a render state of its own, updated under the
/// terminal's lock, then read without it. Confined to one thread, the renderer's.
public final class ScreenReader {
    public let terminal: Terminal
    private var state: GhosttyRenderState?
    private var rowIterator: GhosttyRenderStateRowIterator?
    private var rowCells: GhosttyRenderStateRowCells?
    private var row: [ScreenCell] = []

    /// After `update`: the default colors and the cursor.
    public private(set) var foreground: UInt32 = 0xFFFFFF
    public private(set) var background: UInt32 = 0x000000
    public private(set) var cursor = ScreenCursor()
    /// The cursor's color: the default given, or a program's (OSC 12); nil when neither set one.
    public private(set) var cursorColor: UInt32?
    /// The 256 colors in use, for colors cells give by index (an underline's).
    private var palette = [UInt32](repeating: 0, count: 256)
    public private(set) var columns = 0
    public private(set) var rows = 0

    public init(terminal: Terminal) {
        self.terminal = terminal
        ghostty_render_state_new(nil, &state)
        ghostty_render_state_row_iterator_new(nil, &rowIterator)
        ghostty_render_state_row_cells_new(nil, &rowCells)
    }

    deinit {
        ghostty_render_state_row_cells_free(rowCells)
        ghostty_render_state_row_iterator_free(rowIterator)
        ghostty_render_state_free(state)
    }

    /// Takes what changed since the last update, under the terminal's lock. False when there's
    /// nothing new to draw, including while the program holds the screen (synchronized output).
    public func update() -> Bool {
        let t = terminal
        let changed: Bool = t.lock.read {
            if t.holding, DispatchTime.now().uptimeNanoseconds - t.holdStarted < 1_000_000_000 {
                // Held: the screen from when the hold began, once, then nothing new until it ends.
                guard t.holdCaptured else { return false }
                t.holdCaptured = false
                swap(&state, &t.holdCapture)
                return true
            }
            guard t.changedSinceRead else { return false }
            t.changedSinceRead = false
            ghostty_render_state_update(state, t.handle)
            return true
        }
        guard changed else { return false }

        var value: UInt16 = 0
        ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_COLS, &value)
        columns = Int(value)
        ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROWS, &value)
        rows = Int(value)
        var color = GhosttyColorRgb()
        if ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_COLOR_FOREGROUND, &color) == GHOSTTY_SUCCESS { foreground = Self.pack(color) }
        if ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_COLOR_BACKGROUND, &color) == GHOSTTY_SUCCESS { background = Self.pack(color) }
        var hasCursorColor = false
        ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_COLOR_CURSOR_HAS_VALUE, &hasCursorColor)
        cursorColor = hasCursorColor && ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_COLOR_CURSOR, &color) == GHOSTTY_SUCCESS
            ? Self.pack(color) : nil
        var colors = [GhosttyColorRgb](repeating: GhosttyColorRgb(), count: 256)
        if colors.withUnsafeMutableBufferPointer({ ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_COLOR_PALETTE, $0.baseAddress) }) == GHOSTTY_SUCCESS {
            palette = colors.map(Self.pack)
        }

        var c = GhosttyRenderStateCursor()
        c.size = MemoryLayout<GhosttyRenderStateCursor>.size
        ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR, &c)
        cursor.column = Int(c.viewport_x)
        cursor.row = Int(c.viewport_y)
        cursor.visible = c.visible && c.viewport_has_value
        cursor.blinking = c.blinking
        cursor.shape = switch c.visual_style {
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR: .bar
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE: .underline
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW: .hollowBlock
        default: .block
        }
        return true
    }

    /// Each row that changed since it was last read, after `update`, then marks it read. The
    /// cells are valid only during the call.
    public func forEachChangedRow(_ body: (_ row: Int, _ cells: UnsafeBufferPointer<ScreenCell>) -> Void) {
        ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &rowIterator)
        var y: UInt16 = 0
        var graphemes = [UInt32](repeating: 0, count: 16)
        while ghostty_render_state_row_iterator_next_dirty(rowIterator, &y) {
            row.removeAll(keepingCapacity: true)
            ghostty_render_state_row_get(rowIterator, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &rowCells)
            // The row's part of the selection, once, not a question per cell.
            var selection = GhosttyRenderStateRowSelection()
            selection.size = MemoryLayout<GhosttyRenderStateRowSelection>.size
            let selected: ClosedRange<Int>? = ghostty_render_state_row_get(rowIterator, GHOSTTY_RENDER_STATE_ROW_DATA_SELECTION, &selection) == GHOSTTY_SUCCESS
                ? Int(min(selection.start_x, selection.end_x))...Int(max(selection.start_x, selection.end_x)) : nil
            var x = 0
            while ghostty_render_state_row_cells_next(rowCells) {
                row.append(cell(&graphemes, selected: selected?.contains(x) ?? false))
                x += 1
            }
            row.withUnsafeBufferPointer { body(Int(y), $0) }
            var clean = false
            ghostty_render_state_row_set(rowIterator, GHOSTTY_RENDER_STATE_ROW_OPTION_DIRTY, &clean)
        }
        ghostty_render_state_clean(state)
    }

    /// One cell, with as few questions to libghostty as it needs: a plain character's codepoint
    /// from the raw cell, and colors and style only for a cell that has styling or a background
    /// color of its own. Most of a screen is plain text, and asking every cell everything was
    /// most of a frame's CPU (Benchmarks/Terminal/results/2026-11-13-tier1).
    private func cell(_ graphemes: inout [UInt32], selected: Bool) -> ScreenCell {
        var cell = ScreenCell()
        var raw: GhosttyCell = 0
        ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw)
        // Width, content, styling and codepoint in one call.
        var wide = GHOSTTY_CELL_WIDE_NARROW, tag = GHOSTTY_CELL_CONTENT_CODEPOINT, styled = false, codepoint: UInt32 = 0
        withUnsafeMutablePointer(to: &wide) { w in withUnsafeMutablePointer(to: &tag) { t in
            withUnsafeMutablePointer(to: &styled) { st in withUnsafeMutablePointer(to: &codepoint) { c in
                var values: (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) = (UnsafeMutableRawPointer(w), UnsafeMutableRawPointer(t), UnsafeMutableRawPointer(st), UnsafeMutableRawPointer(c))
                withUnsafeMutablePointer(to: &values) { list in
                    list.withMemoryRebound(to: UnsafeMutableRawPointer?.self, capacity: 4) {
                        _ = ghostty_cell_get_multi(raw, 4, Self.cellKeys, $0, nil)
                    }
                }
            } }
        } }
        if wide == GHOSTTY_CELL_WIDE_WIDE { cell.style.insert(.wide) }
        if wide == GHOSTTY_CELL_WIDE_SPACER_TAIL || wide == GHOSTTY_CELL_WIDE_SPACER_HEAD { cell.style.insert(.spacer) }
        if selected { cell.style.insert(.selected) }

        if tag == GHOSTTY_CELL_CONTENT_CODEPOINT {
            cell.scalar = codepoint
        } else if tag == GHOSTTY_CELL_CONTENT_CODEPOINT_GRAPHEME {
            readGraphemes(into: &cell, &graphemes)
        }
        // Default colors and no style: nothing more to ask.
        let hasBackground = tag == GHOSTTY_CELL_CONTENT_BG_COLOR_PALETTE || tag == GHOSTTY_CELL_CONTENT_BG_COLOR_RGB
        guard styled || hasBackground else {
            cell.foreground = foreground
            return cell
        }
        return styledCell(cell)
    }

    private static let cellKeys: [GhosttyCellData] = [GHOSTTY_CELL_DATA_WIDE, GHOSTTY_CELL_DATA_CONTENT_TAG, GHOSTTY_CELL_DATA_HAS_STYLING, GHOSTTY_CELL_DATA_CODEPOINT]

    private func readGraphemes(into cell: inout ScreenCell, _ graphemes: inout [UInt32]) {
        var length: UInt32 = 0
        ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &length)
        if length > 0 {
            if Int(length) > graphemes.count { graphemes = [UInt32](repeating: 0, count: Int(length)) }
            graphemes.withUnsafeMutableBufferPointer { _ = ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, $0.baseAddress) }
            cell.scalar = graphemes[0]
            if length > 1 {
                var scalars = String.UnicodeScalarView()
                for i in 0..<Int(length) { if let u = UnicodeScalar(graphemes[i]) { scalars.append(u) } }
                cell.cluster = String(scalars)
            }
        }
    }

    /// A cell's colors and style, from the render state: its own or the palette's, inverse and
    /// faint applied.
    private func styledCell(_ start: ScreenCell) -> ScreenCell {
        var cell = start
        var style = GhosttyStyle()
        style.size = MemoryLayout<GhosttyStyle>.size
        ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style)
        var fg = GhosttyColorRgb(), bg = GhosttyColorRgb()
        var foreground = ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &fg) == GHOSTTY_SUCCESS ? Self.pack(fg) : self.foreground
        var background: UInt32? = ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &bg) == GHOSTTY_SUCCESS ? Self.pack(bg) : nil
        if style.inverse {
            let f = foreground
            foreground = background ?? self.background
            background = f
        }
        if style.faint { foreground = Self.mix(foreground, background ?? self.background) }
        cell.foreground = foreground
        cell.background = background
        if style.bold { cell.style.insert(.bold) }
        if style.italic { cell.style.insert(.italic) }
        if style.strikethrough { cell.style.insert(.strikethrough) }
        if style.overline { cell.style.insert(.overline) }
        if style.blink { cell.style.insert(.blink) }
        if style.invisible { cell.style.insert(.invisible) }
        switch style.underline_color.tag {
        case GHOSTTY_STYLE_COLOR_RGB: cell.underlineColor = Self.pack(style.underline_color.value.rgb)
        case GHOSTTY_STYLE_COLOR_PALETTE: cell.underlineColor = palette[Int(style.underline_color.value.palette)]
        default: break
        }
        cell.underline = switch Int(style.underline) {
        case Int(GHOSTTY_SGR_UNDERLINE_SINGLE.rawValue): .single
        case Int(GHOSTTY_SGR_UNDERLINE_DOUBLE.rawValue): .double
        case Int(GHOSTTY_SGR_UNDERLINE_CURLY.rawValue): .curly
        case Int(GHOSTTY_SGR_UNDERLINE_DOTTED.rawValue): .dotted
        case Int(GHOSTTY_SGR_UNDERLINE_DASHED.rawValue): .dashed
        default: .none
        }
        return cell
    }

    static func pack(_ c: GhosttyColorRgb) -> UInt32 { UInt32(c.r) << 16 | UInt32(c.g) << 8 | UInt32(c.b) }

    /// Faint text: halfway to the background, as Ghostty draws it.
    static func mix(_ a: UInt32, _ b: UInt32) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 { ((((a >> shift) & 0xFF) + ((b >> shift) & 0xFF)) / 2) << shift }
        return channel(16) | channel(8) | channel(0)
    }
}
