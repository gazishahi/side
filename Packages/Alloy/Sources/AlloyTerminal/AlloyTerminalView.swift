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

    public var source: TerminalGridSource? {
        get { engine.source }
        set { engine.setSource(newValue) }
    }

    public var theme: TerminalTheme {
        didSet { engine.setTheme(theme); layer?.isOpaque = theme.background.w >= 1 }
    }

    public let font: TerminalFont
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

    /// Draws the current grid into a texture and waits for the GPU: for tests and snapshots.
    public func renderOffscreen() -> MTLTexture? { engine.renderOffscreen() }
}

/// The least a terminal view needs to be a text input client: text is inserted, nothing is
/// marked yet (inline IME preedit is Tier 1 work, docs/SIDE_RFC_TERMINAL_ENGINE.md).
extension AlloyTerminalView: @preconcurrency NSTextInputClient {
    public func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        if !text.isEmpty { onText?(text) }
    }
    public override func doCommand(by selector: Selector) {}
    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {}
    public func unmarkText() {}
    public func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    public func markedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    public func hasMarkedText() -> Bool { false }
    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        window?.convertToScreen(convert(bounds, to: nil)) ?? .zero
    }
    public func characterIndex(for point: NSPoint) -> Int { 0 }
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
        guard changed || grid.dirty.contains(true) else { return }
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
