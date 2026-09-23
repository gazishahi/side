import AppKit

/// Where the navigation components live (Direction 02 §3.0). The floating bar is on trial; the
/// seamless frame and top row are permanent and correct under both. Reverting = default this to
/// `.topRow`, then delete the `.floatingBar` branch and the key.
enum ChromePlacement: String {
    case floatingBar, topRow

    /// A hidden key so both layouts can be compared on one build — not a user setting.
    static var current: ChromePlacement {
        UserDefaults.standard.string(forKey: "SideChromePlacement").flatMap(Self.init(rawValue:)) ?? .floatingBar
    }
}

/// What a stage contributes to the window's chrome. Nothing here knows where the chrome is.
@MainActor
protocol StageChromeProviding: AnyObject {
    /// The stage's own top-row content — its tabs, or its header.
    var topRowContent: NSView? { get }
    /// Height at the bottom of the stage that something else is drawn over. Scrolling content
    /// scrolls clear of it; content that must never be covered (a prompt) ends above it.
    func setBottomObstruction(_ height: CGFloat)
    /// The same at the top: the window's top row floats over the stage, which runs to the top
    /// edge. Content starts below it and scrolls up underneath it.
    func setTopObstruction(_ height: CGFloat)
    /// The stage's own surface, which the top row takes on so the two read as one sheet.
    var topRowBackground: NSColor { get }
}

extension StageChromeProviding {
    func setBottomObstruction(_ height: CGFloat) {}
    func setTopObstruction(_ height: CGFloat) {}
    var topRowBackground: NSColor { DS.Color.canvas }
}

/// Owns placement: the top row every window has, and — under `.floatingBar` — the glass bar.
/// The components it places (track pill, stage control, search button) are plain views that
/// never read this class or their own position.
@MainActor
final class ChromeHost {
    static let rowHeight: CGFloat = 38
    static let barHeight: CGFloat = 40
    static let barGap: CGFloat = 12

    let placement: ChromePlacement
    let topRow = TopRowView()
    private let topRowBackdrop = TopRowBackdrop()
    let pill: TrackPill
    let stageControl: SlidingSegmentedControl
    let searchButton: GlassCircleButton
    private let stageSlot = NSView()
    private var stageContent: NSView?
    private var bar: NSView?
    private var barPieces: [NSView] = []
    private var leadingInset: NSLayoutConstraint?

    init(placement: ChromePlacement, pill: TrackPill, stageControl: SlidingSegmentedControl, searchButton: GlassCircleButton) {
        self.placement = placement
        self.pill = pill
        self.stageControl = stageControl
        self.searchButton = searchButton
    }

    /// The covered band at the bottom of every stage — the bar and the gap beneath it.
    var bottomObstruction: CGFloat { placement == .floatingBar ? Self.barHeight + Self.barGap : 0 }

    func install(in root: NSView, content: NSView) {
        content.translatesAutoresizingMaskIntoConstraints = false
        topRow.translatesAutoresizingMaskIntoConstraints = false
        stageSlot.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)
        root.addSubview(topRowBackdrop)
        root.addSubview(topRow)

        let row = NSStackView()
        // Never let the row's contents size the window: a stack view's default clipping
        // resistance is *required*, so a long conversation title or track intent widened the
        // whole window the moment Think or Review came forward.
        row.setClippingResistancePriority(.defaultLow, for: .horizontal)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = DS.Spacing.m
        row.translatesAutoresizingMaskIntoConstraints = false
        topRow.addSubview(row)
        switch placement {
        case .topRow:
            searchButton.setGlass(false)
            for view in [pill, stageSlot, stageControl, searchButton] as [NSView] { row.addArrangedSubview(view) }
            row.setCustomSpacing(DS.Spacing.l, after: stageSlot)
        case .floatingBar:
            row.addArrangedSubview(stageSlot)
            installBar(in: root)
        }
        stageSlot.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stageSlot.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let inset = row.leadingAnchor.constraint(equalTo: topRow.leadingAnchor, constant: Self.trafficLightInset)
        leadingInset = inset
        NSLayoutConstraint.activate([
            topRow.topAnchor.constraint(equalTo: root.topAnchor),
            topRow.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topRow.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            topRow.heightAnchor.constraint(equalToConstant: Self.rowHeight),
            inset,
            row.trailingAnchor.constraint(equalTo: topRow.trailingAnchor, constant: -DS.Spacing.m),
            row.topAnchor.constraint(equalTo: topRow.topAnchor),
            row.bottomAnchor.constraint(equalTo: topRow.bottomAnchor),
            stageSlot.topAnchor.constraint(equalTo: row.topAnchor),
            stageSlot.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            // Edge to edge: the stage runs under the top row, which fades into it.
            content.topAnchor.constraint(equalTo: root.topAnchor),
            topRowBackdrop.topAnchor.constraint(equalTo: root.topAnchor),
            topRowBackdrop.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topRowBackdrop.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            topRowBackdrop.heightAnchor.constraint(equalToConstant: Self.rowHeight + TopRowBackdrop.fade),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
    }

    /// The bar: three pieces of glass spread across the bottom — the track pill at the leading
    /// margin, the stage control centred, search at the trailing margin — so under Think's
    /// full-width composer the row spans the same width and no corner is left empty. On a
    /// narrow window the pill gives way (truncates, then dot only) before anything overlaps.
    private func installBar(in root: NSView) {
        let pillCapsule = Self.glassCapsule(around: pill, insets: NSEdgeInsets(top: 0, left: DS.Spacing.xs, bottom: 0, right: DS.Spacing.xs))
        let stagesCapsule = Self.glassCapsule(around: stageControl, insets: NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4))
        searchButton.setGlass(true)
        for piece in [pillCapsule, stagesCapsule, searchButton] as [NSView] { root.addSubview(piece) }
        NSLayoutConstraint.activate([
            pillCapsule.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.barMargin),
            pillCapsule.trailingAnchor.constraint(lessThanOrEqualTo: stagesCapsule.leadingAnchor, constant: -DS.Spacing.m),
            stagesCapsule.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            searchButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Self.barMargin),
            searchButton.leadingAnchor.constraint(greaterThanOrEqualTo: stagesCapsule.trailingAnchor, constant: DS.Spacing.m),
            pillCapsule.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Self.barGap),
            stagesCapsule.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Self.barGap),
            searchButton.centerYAnchor.constraint(equalTo: stagesCapsule.centerYAnchor),
        ])
        bar = stagesCapsule
        barPieces = [pillCapsule, stagesCapsule, searchButton]
    }

    /// Lines the bar up with Think's composer row (the + button and the composer's edge).
    static let barMargin: CGFloat = DS.Spacing.xxl

    private static func glassCapsule(around content: NSView, insets: NSEdgeInsets) -> NSView {
        let capsule = NSView()
        capsule.translatesAutoresizingMaskIntoConstraints = false
        let glass = DS.makeGlass(cornerRadius: barHeight / 2)
        capsule.addSubview(glass)
        content.translatesAutoresizingMaskIntoConstraints = false
        capsule.addSubview(content)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: capsule.topAnchor), glass.bottomAnchor.constraint(equalTo: capsule.bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: capsule.leadingAnchor), glass.trailingAnchor.constraint(equalTo: capsule.trailingAnchor),
            content.leadingAnchor.constraint(equalTo: capsule.leadingAnchor, constant: insets.left),
            content.trailingAnchor.constraint(equalTo: capsule.trailingAnchor, constant: -insets.right),
            content.centerYAnchor.constraint(equalTo: capsule.centerYAnchor),
            capsule.heightAnchor.constraint(equalToConstant: barHeight),
        ])
        return capsule
    }

    /// The row takes the stage's own surface, so the top of the window and the stage are one
    /// sheet: canvas for most stages, the terminal's tone for Run.
    func setRowBackground(_ color: NSColor) { topRowBackdrop.tint = color }

    /// Replaces the stage's top-row content (its tabs or header).
    func setStageContent(_ view: NSView?) {
        guard view !== stageContent else { return }
        stageContent?.removeFromSuperview()
        stageContent = view
        guard let view else { return }
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        stageSlot.addSubview(view)
        defer {
            // A strip re-parented into the row keeps the layout it had in its old home until
            // something resizes the window — why the tabs sometimes didn't draw until a resize.
            topRow.layoutSubtreeIfNeeded()
            Self.markNeedsDisplay(view)
        }
        // Tab strips fill the row so the active tab reaches the content below it; a header
        // sits on the row's centre line, level with the traffic lights.
        //
        // A strip must *fill* the slot: its scroll view has no intrinsic width, so pinned with
        // `≤` it collapsed to zero the second time it was placed here — the tabs that vanished
        // after a trip to another stage and came back on resize. A header hugs its text.
        let isStrip = view is TabStripView
        NSLayoutConstraint.activate([
            isStrip ? view.topAnchor.constraint(equalTo: stageSlot.topAnchor) : view.centerYAnchor.constraint(equalTo: stageSlot.centerYAnchor),
            isStrip ? view.bottomAnchor.constraint(equalTo: stageSlot.bottomAnchor) : view.heightAnchor.constraint(lessThanOrEqualTo: stageSlot.heightAnchor),
            view.leadingAnchor.constraint(equalTo: stageSlot.leadingAnchor),
            isStrip ? view.trailingAnchor.constraint(equalTo: stageSlot.trailingAnchor) : view.trailingAnchor.constraint(lessThanOrEqualTo: stageSlot.trailingAnchor),
        ])
    }

    private static func markNeedsDisplay(_ view: NSView) {
        view.needsLayout = true
        view.needsDisplay = true
        view.subviews.forEach(markNeedsDisplay)
    }

    /// Where the palette grows from, in `root`'s coordinates: the stage bar under
    /// `.floatingBar`, the search button in the top row.
    func paletteSource(in root: NSView) -> NSRect {
        if let bar { return bar.convert(bar.bounds, to: root) }
        return searchButton.convert(searchButton.bounds, to: root)
    }

    /// While Think's composer holds text, the bar recedes (still operable) so there aren't two
    /// equally loud things at the bottom of the window.
    func setBarRecessed(_ recessed: Bool) {
        guard placement == .floatingBar else { return }
        barPieces.forEach { $0.alphaValue = recessed ? 0.55 : 1 }
    }

    /// Narrow windows: the pill's intent truncates with an ellipsis — layout decides, not a width
    /// threshold. The old threshold flipped the pill to dot-only on a transient layout pass and
    /// could stay there, so the track name "suddenly disappeared".
    func adapt(toWidth width: CGFloat) {}

    /// Where the palette goes, in `root`'s coordinates: expanding upward from the bar, or
    /// centred in the window under the top row.
    func paletteFrame(size: NSSize, in root: NSView) -> NSRect {
        var origin: NSPoint
        if placement == .floatingBar, let bar {
            let barFrame = bar.convert(bar.bounds, to: root)
            origin = NSPoint(x: barFrame.midX - size.width / 2, y: barFrame.maxY + DS.Spacing.m)
        } else {
            origin = NSPoint(x: root.bounds.midX - size.width / 2, y: root.bounds.maxY - Self.rowHeight - 60 - size.height)
        }
        origin.x = max(12, min(origin.x, root.bounds.maxX - size.width - 12))
        return NSRect(origin: origin, size: size)
    }

    // MARK: Traffic lights

    /// Content starts after the lights; in full screen, where they hide, the inset collapses.
    static let trafficLightInset: CGFloat = 78
    func setFullScreen(_ fullScreen: Bool) {
        leadingInset?.constant = fullScreen ? 12 : Self.trafficLightInset
    }

    /// Centres the lights vertically in the 38 pt row. AppKit lays them out for a 28 pt title
    /// bar and re-lays them on resize and full-screen transitions, so this runs from layout.
    func positionTrafficLights(in window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen) else { return }
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(type), let container = button.superview else { continue }
            let height = container.bounds.height
            let y = max(0, height - Self.rowHeight / 2 - button.frame.height / 2)
            if abs(button.frame.origin.y - y) > 0.5 { button.setFrameOrigin(NSPoint(x: button.frame.origin.x, y: y)) }
        }
    }
}

/// Behind the top row: the stage's own tone, translucent and blurred over whatever has scrolled
/// beneath, fading out below the row's edge — a seamless frame, the way a translucent web
/// header melts into the page instead of ending at a line.
final class TopRowBackdrop: NSView {
    static let fade: CGFloat = 22
    private let blur = NSVisualEffectView()
    private let tintView = NSView()
    var tint: NSColor = DS.Color.canvas { didSet { tintView.bindLayerBackground(tint.withAlphaComponent(0.78)) } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        blur.material = .headerView
        blur.blendingMode = .withinWindow
        blur.state = .active
        tintView.wantsLayer = true
        for view in [blur, tintView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: topAnchor), view.bottomAnchor.constraint(equalTo: bottomAnchor),
                view.leadingAnchor.constraint(equalTo: leadingAnchor), view.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
        }
        tint = DS.Color.canvas
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Opaque through the row, then a smooth fall-off over `fade`.
    override func layout() {
        super.layout()
        let height = bounds.height, fadeFraction = Self.fade / max(height, 1)
        let mask = NSImage(size: bounds.size, flipped: false) { rect in
            let gradient = NSGradient(colors: [NSColor.black.withAlphaComponent(0), NSColor.black.withAlphaComponent(0.5), .black],
                                      atLocations: [0, fadeFraction * 0.55, fadeFraction], colorSpace: .sRGB)
            gradient?.draw(in: rect, angle: 90)
            return true
        }
        blur.maskImage = mask
        let gradientLayer = CAGradientLayer()
        gradientLayer.frame = tintView.bounds
        gradientLayer.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor]
        gradientLayer.locations = [0, NSNumber(value: Double(fadeFraction)), 1]
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 0)
        gradientLayer.endPoint = CGPoint(x: 0.5, y: 1)
        tintView.layer?.mask = gradientLayer
    }
}

/// The unified top row: traffic lights, then the stage's tabs or header. Every point that isn't
/// a control drags the window, and a double-click does what the system titlebar would.
final class TopRowView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// False, deliberately: a `true` here marks the whole row as a window-drag region that
    /// AppKit honours before any subview sees the press, so dragging a tab dragged the window.
    /// Empty space still drags — `mouseDown` below calls `performDrag` itself.
    override var mouseDownCanMoveWindow: Bool { false }

    /// Controls keep their clicks; everything else — empty tab-strip space, labels, stack
    /// padding — belongs to the row, so it drags.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        var view: NSView? = hit
        while let current = view, current !== self {
            if Self.isInteractive(current) { return hit }
            view = current.superview
        }
        return self
    }

    static func isInteractive(_ view: NSView) -> Bool {
        if view is TrackPill || view is TabChipView { return true }
        if let field = view as? NSTextField { return field.isEditable || field.isSelectable }
        return view is NSControl
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.clickCount == 2 {
            Self.performTitlebarDoubleClick(on: window)
        } else {
            window.performDrag(with: event)
        }
    }

    /// Scrolling over a tab strip's empty space still scrolls the strip.
    override func scrollWheel(with event: NSEvent) {
        guard let superview else { return super.scrollWheel(with: event) }
        let point = superview.convert(event.locationInWindow, from: nil)
        if let scroll = super.hitTest(point)?.enclosingScrollView { scroll.scrollWheel(with: event) } else { super.scrollWheel(with: event) }
    }

    /// Honours System Settings → Desktop & Dock → "Double-click a window's title bar to".
    static func performTitlebarDoubleClick(on window: NSWindow) {
        let action = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleActionOnDoubleClick"] as? String
        switch action {
        case "Minimize": window.miniaturize(nil)
        case "None", "No Action": break
        default: window.zoom(nil)
        }
    }
}
