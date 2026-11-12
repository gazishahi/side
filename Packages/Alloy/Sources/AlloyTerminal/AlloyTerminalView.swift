import AppKit
import Metal
import QuartzCore
import Synchronization

/// A terminal's screen: a Metal layer drawn on a render thread of its own. The emulator, through
/// its `TerminalGridSource`, says when output arrived (`setNeedsFrame`), and the next frame is
/// drawn then, not at the next display-link tick: drawing when output arrives is where the
/// latency was (docs/SIDE_RFC_TERMINAL_ENGINE.md, Phase 0). Nothing is drawn on the main thread,
/// which a frame waiting for a drawable would otherwise stall.
///
/// Typed keys go first to `keyHandler` (the emulator's key encoder); keys it leaves go through the
/// text input system, and the text it produces comes back through `onText`.
@MainActor
public final class AlloyTerminalView: NSView {
    /// The emulator's key encoding. Returns true when it handled the key.
    public var keyHandler: ((NSEvent) -> Bool)?
    /// Text from the input system: typed characters, dictation, the emoji picker.
    public var onText: ((String) -> Void)?
    /// The grid's size changed with the view's (columns, rows): resize the emulator to match.
    public var onGridResize: ((Int, Int) -> Void)?
    /// The mouse, over the grid: selection, or the program's own mouse reporting.
    public var mouseHandler: ((TerminalMouseEvent) -> Void)?
    /// The scroll wheel or trackpad, in rows (fractional on a trackpad); positive is up, toward
    /// older output. With where the pointer is (`TerminalMouseEvent`'s x and y).
    public var scrollHandler: ((_ rows: Double, _ x: Double, _ y: Double) -> Void)?

    public var source: TerminalGridSource? {
        get { engine.source }
        set { engine.setSource(newValue) }
    }

    public var theme: TerminalTheme {
        didSet { engine.setTheme(theme); layer?.isOpaque = theme.background.w >= 1 }
    }

    public let font: TerminalFont
    /// What an input method is composing; empty when nothing is.
    public private(set) var markedText = ""
    public var cellSize: CGSize { font.cellSize }
    public private(set) var columns: Int
    public private(set) var rows: Int
    /// Frames drawn so far (read on the main thread, for tests).
    public var frames: Int { engine.frames }

    private let metal = CAMetalLayer()
    private let engine: RenderEngine

    public init(frame: NSRect, font: TerminalFont, theme: TerminalTheme, device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws {
        guard let device else { throw TerminalError.noDevice }
        self.font = font
        self.theme = theme
        let cell = font.cellSize
        columns = max(1, Int(frame.width / cell.width))
        rows = max(1, Int(frame.height / cell.height))
        let renderer = try TerminalRenderer(device: device, font: font, theme: theme)
        engine = RenderEngine(renderer: renderer, layer: metal, grid: TerminalGrid(columns: columns, rows: rows, foreground: 0xFFFFFF))
        super.init(frame: frame)
        metal.device = device
        metal.pixelFormat = .bgra8Unorm
        metal.framebufferOnly = true
        metal.maximumDrawableCount = 2
        metal.isOpaque = theme.background.w >= 1
        // Stretched content during a live resize reads as jitter; anchored top-left, the old frame
        // stays put until the new one lands.
        metal.contentsGravity = .topLeft
        metal.needsDisplayOnBoundsChange = false
        wantsLayer = true
        layer = metal
        updateDrawableSize()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    public enum TerminalError: Error { case noDevice }

    /// The emulator has new output: draw a frame on the render thread. Callable from any thread
    /// (the emulator's reader calls it); requests coalesce to one pending frame.
    public nonisolated func setNeedsFrame() { engine.requestFrame() }

    // MARK: - Size and scale

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDrawableSize()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? 2
        metal.contentsScale = scale
        metal.drawableSize = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        let cell = font.cellSize
        let newColumns = max(1, Int(bounds.width / cell.width)), newRows = max(1, Int(bounds.height / cell.height))
        let resized = newColumns != columns || newRows != rows
        columns = newColumns
        rows = newRows
        engine.setViewport(scale: scale, columns: newColumns, rows: newRows)
        if resized { onGridResize?(newColumns, newRows) }
        engine.requestFrame()
    }

    // MARK: - Keys

    public override var acceptsFirstResponder: Bool { true }

    public override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        interpretKeyEvents([event])
    }

    // MARK: - Mouse

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        mouseHandler?(mouseEvent(event, .down))
    }
    public override func mouseDragged(with event: NSEvent) { mouseHandler?(mouseEvent(event, .dragged)) }
    public override func mouseUp(with event: NSEvent) { mouseHandler?(mouseEvent(event, .up)) }
    public override func rightMouseDown(with event: NSEvent) { mouseHandler?(mouseEvent(event, .rightDown)) }
    public override func rightMouseUp(with event: NSEvent) { mouseHandler?(mouseEvent(event, .rightUp)) }
    public override func otherMouseDown(with event: NSEvent) { mouseHandler?(mouseEvent(event, .middleDown)) }
    public override func otherMouseUp(with event: NSEvent) { mouseHandler?(mouseEvent(event, .middleUp)) }
    public override func mouseMoved(with event: NSEvent) { mouseHandler?(mouseEvent(event, .moved)) }

    /// Plain motion is reported too, for programs that track it (any-event mouse tracking).
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    public override func scrollWheel(with event: NSEvent) {
        guard let scrollHandler else { return super.scrollWheel(with: event) }
        let rows = event.hasPreciseScrollingDeltas ? Double(event.scrollingDeltaY / cellSize.height) : Double(event.scrollingDeltaY)
        let at = mouseEvent(event, .moved)
        if rows != 0 { scrollHandler(rows, at.x, at.y) }
    }

    /// Where an event fell: its cell (clamped to the grid) and its position in the drawable's
    /// pixels from the top-left, unclamped (a drag past an edge is below 0 or past the height).
    private func mouseEvent(_ event: NSEvent, _ kind: TerminalMouseEvent.Kind) -> TerminalMouseEvent {
        let point = convert(event.locationInWindow, from: nil)
        let fromTop = CGPoint(x: point.x, y: bounds.height - point.y)
        let cell = font.cellSize
        let column = min(max(0, Int(fromTop.x / cell.width)), columns - 1)
        let row = min(max(0, Int(fromTop.y / cell.height)), rows - 1)
        let scale = window?.backingScaleFactor ?? 2
        return TerminalMouseEvent(kind: kind, column: column, row: row, x: Double(fromTop.x * scale), y: Double(fromTop.y * scale),
                                  clickCount: event.clickCount, modifiers: event.modifierFlags)
    }

    /// The grid's geometry in the drawable's pixels.
    public var pixelGeometry: (columns: Int, cellWidth: Int, cellHeight: Int, width: Int, height: Int) {
        let scale = window?.backingScaleFactor ?? 2
        return (columns, Int((font.cellSize.width * scale).rounded()), Int((font.cellSize.height * scale).rounded()),
                Int((bounds.width * scale).rounded()), Int((bounds.height * scale).rounded()))
    }

    /// Draws the current grid into a texture and waits for the GPU: for tests and snapshots.
    public func renderOffscreen() -> MTLTexture? { engine.renderOffscreen() }
}

/// A mouse event over the grid.
public struct TerminalMouseEvent: Sendable {
    public enum Kind: Sendable { case down, dragged, up, rightDown, rightUp, middleDown, middleUp, moved }
    public var kind: Kind
    public var column: Int
    public var row: Int
    /// In the drawable's pixels, from the top-left.
    public var x: Double
    public var y: Double
    public var clickCount: Int
    public var modifiers: NSEvent.ModifierFlags
}

/// A text input client: committed text comes back through `onText`; text an input method is
/// still composing (marked text: Japanese, Chinese, Korean, a dead key's accent) is drawn at the
/// cursor until it's committed or cancelled, and the input method's window sits at the cursor.
extension AlloyTerminalView: @preconcurrency NSTextInputClient {
    public func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        if !markedText.isEmpty { setMarked("") }
        if !text.isEmpty { onText?(text) }
    }
    public override func doCommand(by selector: Selector) {}
    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        setMarked((string as? NSAttributedString)?.string ?? (string as? String) ?? "")
    }
    public func unmarkText() { setMarked("") }
    public func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    public func markedRange() -> NSRange {
        markedText.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: markedText.utf16.count)
    }
    public func hasMarkedText() -> Bool { !markedText.isEmpty }
    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [.underlineStyle] }
    /// The cursor's cell, on screen: where the input method puts its candidates.
    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let cursor = engine.cursor
        let cell = font.cellSize
        let inView = NSRect(x: CGFloat(cursor.column) * cell.width, y: bounds.height - CGFloat(cursor.row + 1) * cell.height,
                            width: cell.width, height: cell.height)
        return window?.convertToScreen(convert(inView, to: nil)) ?? .zero
    }
    public func characterIndex(for point: NSPoint) -> Int { 0 }

    private func setMarked(_ text: String) {
        markedText = text
        engine.setPreedit(text)
    }
}

/// The render thread's side: the renderer, the grid and the source, touched only on `queue`.
/// The view reaches it only through these methods, which hop onto the queue.
private final class RenderEngine: @unchecked Sendable {
    // @unchecked: every mutable property below is touched only on `queue`, except `source` and
    // `drawn`, which are behind their own synchronization.
    private let queue = DispatchQueue(label: "alloy.terminal.render", qos: .userInteractive)
    private let renderer: TerminalRenderer
    private let layer: CAMetalLayer
    private let grid: TerminalGrid
    private var scale: CGFloat = 2
    private let lastCursor = Mutex<TerminalCursor>(TerminalCursor())
    /// The cursor as of the last frame (any thread).
    var cursor: TerminalCursor { lastCursor.withLock { $0 } }
    private let pending = Atomic<Bool>(false)
    private let drawn = Atomic<Int>(0)
    private let sourceBox = Mutex<SourceBox>(SourceBox())
    private struct SourceBox: @unchecked Sendable { weak var value: TerminalGridSource? }

    init(renderer: TerminalRenderer, layer: CAMetalLayer, grid: TerminalGrid) {
        self.renderer = renderer
        self.layer = layer
        self.grid = grid
    }

    var source: TerminalGridSource? { sourceBox.withLock { $0.value } }
    var frames: Int { drawn.load(ordering: .relaxed) }

    func setSource(_ source: TerminalGridSource?) {
        sourceBox.withLock { $0.value = source }
        queue.async { for y in 0..<self.grid.rows { self.grid.dirty[y] = true } }
        requestFrame()
    }

    /// A frame is due though the grid hasn't changed (composing text changed). On `queue`.
    private var forced = false

    func setPreedit(_ text: String) {
        queue.async {
            self.renderer.preedit = text
            self.forced = true
        }
        requestFrame()
    }

    func setTheme(_ theme: TerminalTheme) {
        queue.async {
            self.renderer.theme = theme
            for y in 0..<self.grid.rows { self.grid.dirty[y] = true }
        }
        requestFrame()
    }

    func setViewport(scale: CGFloat, columns: Int, rows: Int) {
        queue.async {
            self.scale = scale
            if columns != self.grid.columns || rows != self.grid.rows { self.grid.resize(columns: columns, rows: rows) }
        }
    }

    func requestFrame() {
        guard !pending.exchange(true, ordering: .acquiringAndReleasing) else { return }
        queue.async {
            self.pending.store(false, ordering: .releasing)
            self.frame()
        }
    }

    /// On `queue`: take what changed from the source, and draw if anything did.
    private func frame() {
        let changed = source?.snapshot(into: grid) ?? false
        if changed { lastCursor.withLock { $0 = grid.cursor } }
        guard changed || forced || grid.dirty.contains(true) else { return }
        forced = false
        guard layer.drawableSize.width > 0, let drawable = layer.nextDrawable() else { return }
        renderer.draw(grid, scale: scale, into: drawable.texture, drawable: drawable)
        drawn.wrappingAdd(1, ordering: .relaxed)
    }

    func renderOffscreen() -> MTLTexture? {
        queue.sync {
            _ = source?.snapshot(into: grid)
            let size = layer.drawableSize
            guard size.width > 0, size.height > 0 else { return nil }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int(size.width), height: Int(size.height), mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .shared
            guard let texture = renderer.device.makeTexture(descriptor: descriptor) else { return nil }
            for y in 0..<grid.rows { grid.dirty[y] = true }
            renderer.draw(grid, scale: scale, into: texture)?.waitUntilCompleted()
            return texture
        }
    }
}
