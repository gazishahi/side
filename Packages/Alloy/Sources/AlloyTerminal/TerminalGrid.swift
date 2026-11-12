/// One cell of a terminal's screen, as an emulator resolved it: text, colors already turned into
/// RGB (palette, inverse and dim applied by the emulator), and the style the renderer draws.
public struct TerminalCell: Equatable, Sendable {
    public struct Style: OptionSet, Sendable, Hashable {
        public let rawValue: UInt16
        public init(rawValue: UInt16) { self.rawValue = rawValue }
        public static let bold = Style(rawValue: 1 << 0)
        public static let italic = Style(rawValue: 1 << 1)
        public static let underline = Style(rawValue: 1 << 2)
        public static let strikethrough = Style(rawValue: 1 << 3)
        /// The left half of a wide character (CJK, most emoji): its glyph spans two cells.
        public static let wide = Style(rawValue: 1 << 4)
        /// The right half of a wide character, or a placeholder: nothing drawn of its own.
        public static let spacer = Style(rawValue: 1 << 5)
    }

    /// The cell's text when it's a single scalar; 0 for an empty cell.
    public var scalar: UInt32
    /// The whole grapheme when it's more than one scalar (ZWJ emoji, flags, combining marks).
    public var cluster: String?
    /// 0xRRGGBB.
    public var foreground: UInt32
    /// 0xRRGGBB, or nil for the terminal's default background (not drawn, so the view's own
    /// background, translucent or not, shows through).
    public var background: UInt32?
    public var style: Style

    public init(scalar: UInt32 = 0, cluster: String? = nil, foreground: UInt32, background: UInt32? = nil, style: Style = []) {
        self.scalar = scalar
        self.cluster = cluster
        self.foreground = foreground
        self.background = background
        self.style = style
    }
}

public struct TerminalCursor: Equatable, Sendable {
    public enum Shape: Sendable { case block, bar, underline }
    public var column: Int
    public var row: Int
    public var visible: Bool
    public var shape: Shape

    public init(column: Int = 0, row: Int = 0, visible: Bool = true, shape: Shape = .block) {
        self.column = column
        self.row = row
        self.visible = visible
        self.shape = shape
    }
}

/// The screen an emulator hands the renderer: cells row by row, which rows changed since the
/// renderer last drew them, and the cursor. Touched only on the render thread: the emulator's
/// `TerminalGridSource` copies into it there, the renderer reads it and clears `dirty`.
public final class TerminalGrid {
    public private(set) var columns: Int
    public private(set) var rows: Int
    /// Row-major, `columns × rows`.
    public var cells: [TerminalCell]
    public var dirty: [Bool]
    public var cursor = TerminalCursor()
    let blank: TerminalCell

    public init(columns: Int, rows: Int, foreground: UInt32) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
        blank = TerminalCell(foreground: foreground)
        cells = Array(repeating: blank, count: self.columns * self.rows)
        dirty = Array(repeating: true, count: self.rows)
    }

    public subscript(column: Int, row: Int) -> TerminalCell {
        get { cells[row * columns + column] }
        set { cells[row * columns + column] = newValue }
    }

    /// A new size: blank cells, every row dirty. The emulator refills it on its next snapshot.
    public func resize(columns: Int, rows: Int) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
        cells = Array(repeating: blank, count: self.columns * self.rows)
        dirty = Array(repeating: true, count: self.rows)
        cursor = TerminalCursor()
    }
}

/// An emulator behind the renderer. On the render thread, at each frame: copy what changed into
/// `grid` (setting its rows' `dirty`) and say whether anything did. It must be safe to call there
/// while the emulator parses on its own thread, which is why it's Sendable: libghostty-vt's
/// render state is updated under the terminal's lock and read without it.
public protocol TerminalGridSource: AnyObject, Sendable {
    func snapshot(into grid: TerminalGrid) -> Bool
}
