import AppKit

/// The design charter's token layer (`SIDE_DESIGN.md`, next to the constitution) — the single
/// source of truth for color, radius, and motion. Before this existed, three separately-authored
/// palettes (Tracks', Review's, and Heron's proposal-card grays) had already drifted apart; every
/// surface now points here, and a new visual primitive gets added to the charter first, then here,
/// then used.
enum DS {
    enum Color {
        /// Window chrome and the editor's own base — the deepest tone in the app. One value on
        /// purpose: stage backgrounds matching the editor is what makes switching stages feel
        /// like turning your head, not changing rooms.
        static let chrome = NSColor(white: 0.098, alpha: 1)
        /// The tab strip sits *behind* the content surface, so it alone gets to be darker than
        /// `chrome` — that contrast is what lets the active tab read as attached to the editor.
        static let tabStrip = NSColor(white: 0.07, alpha: 1)
        /// Cards and panels.
        static let bg1 = NSColor(white: 0.145, alpha: 1)
        /// Selected/active fills one step above a card.
        static let bg2 = NSColor(white: 0.17, alpha: 1)
        /// Chips and inline-code spans.
        static let bg3 = NSColor(white: 0.21, alpha: 1)
        /// Received bubbles and stronger hover fills.
        static let bg4 = NSColor(white: 0.24, alpha: 1)
        /// The only border color in the app.
        static let hairline = NSColor(white: 0.24, alpha: 1)
        /// The tab strip's bottom hairline *and* the active tab's outline — one token, one
        /// opaque value, because those two lines must read as a single continuous edge where
        /// the tab's flares meet the strip.
        static let tabEdge = NSColor(white: 0.30, alpha: 1)
        static let rowHover = NSColor(white: 0.195, alpha: 1)
        /// The lineage rail connecting a stacked track to its parent in Tracks.
        static let rail = NSColor(white: 0.32, alpha: 1)

        static func status(for status: TrackStatus) -> NSColor {
            switch status {
            case .active: return .systemGreen
            case .waiting: return .systemOrange
            case .reviewReady: return .systemPurple
            case .parked: return .systemGray
            case .completed: return .systemTeal
            case .archived: return .tertiaryLabelColor
            }
        }
    }

    enum Radius {
        static let chip: CGFloat = 4
        static let control: CGFloat = 6
        static let card: CGFloat = 10
        static let bubble: CGFloat = 17
    }

    enum Motion {
        /// The standard arrival: rise, fade, slight scale — Think's bubbles set the reference
        /// feel, everything else that appears reuses it. Purely a layer animation over the
        /// view's settled Auto Layout position, so it can't fight layout.
        static func appear(_ view: NSView, distance: CGFloat = 16) {
            view.wantsLayer = true
            guard let layer = view.layer else { return }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            let rise = CABasicAnimation(keyPath: "transform.translation.y")
            rise.fromValue = distance
            rise.toValue = 0
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.96
            scale.toValue = 1
            let group = CAAnimationGroup()
            group.animations = [fade, rise, scale]
            group.duration = 0.3
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(group, forKey: "dsAppear")
        }
    }
}

/// A truly circular icon button. `NSButton` on modern macOS routes sizing through its cell,
/// which quietly widens the frame past a square width/height constraint — every "circle" built
/// on it rendered as a subtle capsule. This is a bare `NSControl`: fixed square frame, layer
/// circle, a centered SF symbol, no cell anywhere in the path.
class CircularIconButton: NSControl {
    private let diameter: CGFloat
    private var symbolImage: NSImage?
    private var hoverColor: NSColor?
    private var restingBackground: NSColor?
    private var trackingArea: NSTrackingArea?

    init(diameter: CGFloat) {
        self.diameter = diameter
        super.init(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        wantsLayer = true
        layer?.cornerRadius = diameter / 2
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: diameter),
            heightAnchor.constraint(equalToConstant: diameter),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { NSSize(width: diameter, height: diameter) }

    /// The symbol is pre-tinted via a palette configuration, so drawing is just "center the image."
    func setSymbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight, color: NSColor, accessibilityLabel: String) {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
            .applying(.init(paletteColors: [color]))
        symbolImage = NSImage(systemSymbolName: name, accessibilityDescription: accessibilityLabel)?.withSymbolConfiguration(config)
        toolTip = accessibilityLabel
        setAccessibilityLabel(accessibilityLabel)
        needsDisplay = true
    }

    var backgroundColor: NSColor? {
        didSet {
            restingBackground = backgroundColor
            layer?.backgroundColor = backgroundColor?.cgColor
        }
    }

    /// Optional hover fill (the tab close button's gray circle); nil means no hover change.
    var hoverBackgroundColor: NSColor? {
        didSet { hoverColor = hoverBackgroundColor }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let symbolImage else { return }
        let size = symbolImage.size
        let rect = NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        symbolImage.draw(in: rect, from: .zero, operation: .sourceOver, fraction: isEnabled ? 1 : 0.5)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        guard hoverColor != nil else { return }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        if let hoverColor { layer?.backgroundColor = hoverColor.cgColor }
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = restingBackground?.cgColor
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        alphaValue = 0.7
    }

    override func mouseUp(with event: NSEvent) {
        alphaValue = 1
        guard isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        sendAction(action, to: target)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityPerformPress() -> Bool {
        sendAction(action, to: target)
        return true
    }
}
