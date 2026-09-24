import AlloyCore
import AlloyRender
import AppKit
import CoreText
import Metal
import QuartzCore

/// The editor Make embeds (SIDE_RFC_ALLOY.md). Step 2: it shows a `TextBuffer` and scrolls it,
/// drawn by `TextRenderer` on the display link. Input arrives in step 3.
///
/// Scrolling is AppKit's own: an `NSScrollView` over a document view as tall as the text, so
/// momentum, rubber-banding, scroll bars and accessibility of the scroll position all behave as
/// everywhere else on the Mac. The Metal layer floats over the visible area and draws whatever
/// the clip view shows.
@MainActor
public final class AlloyEditorView: NSView {
    public let scrollView = NSScrollView()
    public private(set) var buffer: TextBuffer
    public private(set) var documentLayout: DocumentLayout
    public var theme: RenderTheme = .light { didSet { setNeedsRender() } }
    public var styles: ((Int) -> [StyleSpan])? { didSet { setNeedsRender() } }
    /// Wrap to the view's width (Make's default), or not.
    public var wrapsLines = true { didSet { updateWrapWidth() } }

    private let documentView = FlippedDocumentView()
    private let canvas = MetalCanvas()
    private let renderer: TextRenderer
    private var displayLink: CADisplayLink?
    private var needsRender = true
    private var needsRenderWasSet = false

    /// Scrolling health, measured on the display link: frames it drew, and frames where the
    /// gap since the last one was more than 1.5 display intervals.
    public private(set) var framesDrawn = 0
    public private(set) var framesDropped = 0
    public private(set) var worstFrameMilliseconds = 0.0
    private var lastFrameTimestamp: CFTimeInterval?

    public init(buffer: TextBuffer, font: CTFont) throws {
        self.buffer = buffer
        documentLayout = DocumentLayout(text: buffer.text, font: font)
        renderer = try TextRenderer()
        super.init(frame: .zero)
        canvas.metalLayer.device = renderer.device
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.documentView = documentView
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        scrollView.addFloatingSubview(canvas, for: .vertical)
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        buffer.onChange = { [weak self] change in self?.textChanged(change) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows another buffer (a tab switch).
    public func setBuffer(_ buffer: TextBuffer) {
        self.buffer.onChange = nil
        self.buffer = buffer
        buffer.onChange = { [weak self] change in self?.textChanged(change) }
        documentLayout.reset(buffer.text)
        updateDocumentHeight()
        setNeedsRender()
    }

    private func textChanged(_ change: TextChange) {
        documentLayout.update(buffer.text, edits: change.edits)
        updateDocumentHeight()
        setNeedsRender()
    }

    public func setNeedsRender() { needsRender = true }

    public override func layout() {
        super.layout()
        canvas.frame = scrollView.contentView.bounds
        updateWrapWidth()
        updateDocumentHeight()
        setNeedsRender()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        guard window != nil else { return }
        canvas.metalLayer.contentsScale = window?.backingScaleFactor ?? 2
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        setNeedsRender()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        canvas.metalLayer.contentsScale = window?.backingScaleFactor ?? 2
        setNeedsRender()
    }

    private func updateWrapWidth() {
        let width = scrollView.contentView.bounds.width - documentLayout.insets.width * 2
        documentLayout.setWrapWidth(wrapsLines && width > 0 ? width : nil)
    }

    private func updateDocumentHeight() {
        let height = max(documentLayout.contentHeight, scrollView.contentView.bounds.height)
        let width = scrollView.contentView.bounds.width
        if documentView.frame.size != CGSize(width: width, height: height) {
            documentView.frame = CGRect(x: 0, y: 0, width: width, height: height)
        }
    }

    @objc private func scrolled() { setNeedsRender() }

    /// Scrolls so a UTF-16 offset is on screen.
    public func scrollToVisible(offset: Int) {
        let rect = documentLayout.caretRect(at: offset).insetBy(dx: 0, dy: -documentLayout.lineHeight)
        documentView.scrollToVisible(rect)
        setNeedsRender()
    }

    /// The document y at the top of the viewport.
    public var scrollY: CGFloat {
        get { scrollView.contentView.bounds.origin.y }
        set {
            scrollView.contentView.scroll(to: CGPoint(x: 0, y: max(0, min(newValue, documentView.frame.height - scrollView.contentView.bounds.height))))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    /// When each dropped frame happened (seconds since the counters were reset), and every
    /// frame's CPU time, for finding out why.
    public private(set) var dropTimes: [Double] = []
    public private(set) var frameMilliseconds: [Double] = []
    private var countersStart = CACurrentMediaTime()

    /// Runs at the start of every display frame, before drawing (animations, tests).
    public var onFrame: ((CADisplayLink) -> Void)?

    /// When frames actually reached the screen (Metal's presented times): the honest measure of
    /// dropped frames, since a frame that's drawn can still miss its vsync.
    private final class PresentedTimes: @unchecked Sendable {
        let lock = NSLock()
        var times: [CFTimeInterval] = []
        func append(_ time: CFTimeInterval) { lock.lock(); times.append(time); lock.unlock() }
        func take() -> [CFTimeInterval] { lock.lock(); defer { lock.unlock() }; let t = times; times = []; return t }
    }
    private let presented = PresentedTimes()
    public private(set) var displayInterval: CFTimeInterval = 1.0 / 60

    /// Frames that missed their vsync since the counters were reset, from presented times, and
    /// how many were presented.
    public func presentedFrameCounts() -> (presented: Int, missed: Int) {
        let times = presented.take().filter { $0 > 0 }.sorted()
        var missed = 0
        for (a, b) in zip(times, times.dropFirst()) where b - a > displayInterval * 1.5 {
            missed += Int(((b - a) / displayInterval).rounded()) - 1
        }
        return (times.count, missed)
    }

    /// Per frame: the whole tick, and how long `nextDrawable` waited.
    public private(set) var tickMilliseconds: [Double] = []
    public private(set) var drawableWaitMilliseconds: [Double] = []

    @objc private func tick(_ link: CADisplayLink) {
        let tickStart = CACurrentMediaTime()
        defer { if needsRenderWasSet { tickMilliseconds.append((CACurrentMediaTime() - tickStart) * 1000) } }
        needsRenderWasSet = false
        displayInterval = link.targetTimestamp - link.timestamp
        onFrame?(link)
        if let last = lastFrameTimestamp, needsRender {
            let interval = link.targetTimestamp - link.timestamp
            let gap = link.timestamp - last
            if interval > 0, gap > interval * 1.5 {
                framesDropped += 1
                dropTimes.append(link.timestamp - countersStart)
            }
        }
        guard needsRender else { lastFrameTimestamp = nil; return }
        lastFrameTimestamp = link.timestamp
        render()
    }

    /// Draws now.
    public func render() {
        needsRender = false
        let size = scrollView.contentView.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let scale = canvas.metalLayer.contentsScale
        // Only when they change: setting a Metal layer's drawable size, even to the same
        // value, can make Core Animation reallocate its drawables and stall the next frame.
        let frameRect = scrollView.contentView.frame
        if canvas.frame != frameRect { canvas.frame = frameRect }
        let drawableSize = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        if canvas.metalLayer.drawableSize != drawableSize { canvas.metalLayer.drawableSize = drawableSize }
        needsRenderWasSet = true
        let waitStart = CACurrentMediaTime()
        guard let drawable = canvas.metalLayer.nextDrawable() else { needsRender = true; return }
        drawableWaitMilliseconds.append((CACurrentMediaTime() - waitStart) * 1000)
        let frame = RenderFrame(scrollY: scrollY, size: size, scale: scale, selections: buffer.selections,
                                caretVisible: window?.firstResponder === self || window == nil || true, theme: theme, styles: styles)
        let presented = self.presented
        drawable.addPresentedHandler { presented.append($0.presentedTime) }
        renderer.draw(frame, layout: documentLayout, into: drawable.texture, drawable: drawable)
        framesDrawn += 1
        worstFrameMilliseconds = max(worstFrameMilliseconds, renderer.lastStats.cpuMilliseconds)
        frameMilliseconds.append(renderer.lastStats.cpuMilliseconds)
        // The document height can change while drawing (wrapped lines got measured).
        updateDocumentHeight()
    }

    public var lastFrameStats: FrameStats { renderer.lastStats }

    public func resetFrameCounters() {
        framesDrawn = 0
        framesDropped = 0
        worstFrameMilliseconds = 0
        lastFrameTimestamp = nil
        dropTimes = []
        frameMilliseconds = []
        _ = presented.take()
        tickMilliseconds = []
        drawableWaitMilliseconds = []
        countersStart = CACurrentMediaTime()
    }
}

private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// A view backed by a CAMetalLayer that the editor draws into.
private final class MetalCanvas: NSView {
    let metalLayer = CAMetalLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.displaySyncEnabled = true
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func makeBackingLayer() -> CALayer { metalLayer }
    override var isFlipped: Bool { true }
    // Clicks and scrolls go to the scroll view beneath, until step 3 gives the editor input.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
