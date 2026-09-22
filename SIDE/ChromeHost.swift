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
}

extension StageChromeProviding {
    func setBottomObstruction(_ height: CGFloat) {}
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
    let pill: TrackPill
    let stageControl: SlidingSegmentedControl
    let searchButton: NSButton
    private let stageSlot = NSView()
    private var stageContent: NSView?
    private var bar: NSView?
    private var barStack: NSStackView?
    private var leadingInset: NSLayoutConstraint?

    init(placement: ChromePlacement, pill: TrackPill, stageControl: SlidingSegmentedControl, searchButton: NSButton) {
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
        root.addSubview(topRow)

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = DS.Spacing.m
        row.translatesAutoresizingMaskIntoConstraints = false
        topRow.addSubview(row)
        switch placement {
        case .topRow:
            stageControl.setContentHuggingPriority(.required, for: .horizontal)
            stageControl.setContentCompressionResistancePriority(.required, for: .horizontal)
            searchButton.setContentCompressionResistancePriority(.required, for: .horizontal)
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
            content.topAnchor.constraint(equalTo: topRow.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
    }

    private func installBar(in root: NSView) {
        let glass = DS.makeGlass(cornerRadius: Self.barHeight / 2)
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(glass)
        let stack = NSStackView(views: [pill, stageControl, searchButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = DS.Spacing.m
        stack.edgeInsets = NSEdgeInsets(top: 0, left: DS.Spacing.s, bottom: 0, right: DS.Spacing.m)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stageControl.setContentCompressionResistancePriority(.required, for: .horizontal)
        container.addSubview(stack)
        root.addSubview(container)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: container.topAnchor), glass.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: container.leadingAnchor), glass.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor), stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor), stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            container.heightAnchor.constraint(equalToConstant: Self.barHeight),
            container.widthAnchor.constraint(lessThanOrEqualToConstant: 640),
            container.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Self.barGap),
        ])
        bar = container
        barStack = stack
    }

    /// Replaces the stage's top-row content (its tabs or header).
    func setStageContent(_ view: NSView?) {
        guard view !== stageContent else { return }
        stageContent?.removeFromSuperview()
        stageContent = view
        guard let view else { return }
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        stageSlot.addSubview(view)
        // Tab strips fill the row so the active tab reaches the content below it; a header
        // sits on the row's centre line, level with the traffic lights.
        let vertical: [NSLayoutConstraint] = view is TabStripView
            ? [view.topAnchor.constraint(equalTo: stageSlot.topAnchor), view.bottomAnchor.constraint(equalTo: stageSlot.bottomAnchor)]
            : [view.centerYAnchor.constraint(equalTo: stageSlot.centerYAnchor)]
        NSLayoutConstraint.activate(vertical + [
            view.leadingAnchor.constraint(equalTo: stageSlot.leadingAnchor),
            view.trailingAnchor.constraint(lessThanOrEqualTo: stageSlot.trailingAnchor),
        ])
    }

    /// While Think's composer holds text, the bar recedes (still operable) so there aren't two
    /// equally loud things at the bottom of the window.
    func setBarRecessed(_ recessed: Bool) {
        guard placement == .floatingBar else { return }
        barStack?.alphaValue = recessed ? 0.55 : 1
    }

    /// Narrow windows: the pill truncates to its dot first, then the stage control goes to icons.
    func adapt(toWidth width: CGFloat) {
        switch placement {
        case .topRow:
            // The stage control fits the row at the 760 pt minimum with its titles, so it never
            // needs to go to icons here; the pill gives way first.
            pill.dotOnly = width < 1040
        case .floatingBar:
            pill.dotOnly = width < 800
            stageControl.compact = false
        }
    }

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

/// The unified top row: traffic lights, then the stage's tabs or header. Every point that isn't
/// a control drags the window, and a double-click does what the system titlebar would.
final class TopRowView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        bindLayerBackground(DS.Color.canvas)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var mouseDownCanMoveWindow: Bool { true }

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
        if view is TrackPill || view is SlidingSegmentedControl || view is TabChipView { return true }
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
