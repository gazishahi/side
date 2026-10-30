import AppKit
import Heron

/// A segmented control whose selection *slides*: the thumb moves between segments on
/// the snappy spring instead of the stock control's instant swap. Shared by Think's session
/// popover (glass thumb) and the window's stage control (`overlay` thumb, Direction 02 §3.6).
///
/// Built from real subviews rather than `NSSegmentedControl` because the stock control exposes
/// no per-segment accessibility element — its only child is the cell — so a state like "Think,
/// needs you" could only ride in a glyph. Here each segment is a radio button with its own label.
final class SlidingSegmentedControl: NSView {
    /// `glass`: a glass thumb on a faint track (Think's session popover). `capsule`: the
    /// toolbar segmented look — a soft selected capsule on whatever glass the control sits on,
    /// no track and no separators (the window's stage control).
    enum ThumbStyle { case glass, overlay, capsule }

    var onChange: ((Int) -> Void)?
    private(set) var selectedIndex = 0
    var isEnabledControl = true {
        didSet { alphaValue = isEnabledControl ? 1 : 0.4 }
    }
    /// Narrow windows: symbols instead of titles, with the title kept as tooltip and AX label.
    var compact = false { didSet { if compact != oldValue { rebuildContents() } } }

    private let style: ThumbStyle
    private let height: CGFloat
    /// The glass rides inside a plain container, and the *container* is what animates: glass
    /// views don't reliably animate frame changes themselves.
    private let thumbContainer = NSView()
    private let track = NSView()
    private var buttons: [NSButton] = []
    private var badges: [DS.StatusDot] = []
    private var titles: [String] = []
    private var symbols: [String?] = []
    private var accessibilityStates: [String?] = []
    private var badgeStates: [DS.StatusState?] = []
    private var lastLayoutBounds = NSRect.zero
    private var widthConstraint: NSLayoutConstraint?

    init(titles: [String], style: ThumbStyle = .glass, height: CGFloat = 28) {
        self.style = style
        self.height = height
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)

        track.wantsLayer = true
        track.layer?.cornerRadius = style == .overlay ? DS.Radius.control + 2 : DS.Radius.capsule(height: height)
        if style == .glass { track.bindLayerBackground(DS.Color.scrimFaint) }
        addSubview(track)
        switch style {
        case .glass:
            let glass = DS.makeGlass(cornerRadius: (height - 4) / 2)
            glass.translatesAutoresizingMaskIntoConstraints = true
            glass.autoresizingMask = [.width, .height]
            thumbContainer.addSubview(glass)
        case .overlay:
            thumbContainer.wantsLayer = true
            thumbContainer.layer?.cornerRadius = DS.Radius.control
            thumbContainer.bindLayerBackground(DS.Color.overlay)
        case .capsule:
            thumbContainer.wantsLayer = true
            thumbContainer.layer?.cornerRadius = (height - 4) / 2
            thumbContainer.bindLayerBackground(DS.Color.selectedCapsule)
            thumbContainer.shadow = NSShadow()
            thumbContainer.layer?.shadowOpacity = 0.12
            thumbContainer.layer?.shadowRadius = 2
            thumbContainer.layer?.shadowOffset = CGSize(width: 0, height: -0.5)
        }
        addSubview(thumbContainer)
        heightAnchor.constraint(equalToConstant: height).isActive = true
        setSegments(titles, symbols: titles.map { _ in nil }, selected: 0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Replaces the segments — the stage control's set changes with pins and attention.
    func setSegments(_ titles: [String], symbols: [String?]? = nil, selected: Int) {
        self.titles = titles
        self.symbols = symbols ?? titles.map { _ in nil }
        accessibilityStates = titles.map { _ in nil }
        badgeStates = titles.map { _ in nil }
        selectedIndex = selected < 0 ? -1 : max(0, min(selected, titles.count - 1))
        rebuildContents()
    }

    /// The status dot trailing the segment's title, and the state spoken with its name. A dot
    /// alone still says its word, as a tooltip (Direction 03 §3.2).
    func setBadge(_ state: DS.StatusState?, spokenState: String?, at index: Int) {
        guard badgeStates.indices.contains(index) else { return }
        badgeStates[index] = state
        accessibilityStates[index] = spokenState
        if let state { badges[index].state = state }
        badges[index].isHidden = state == nil
        badges[index].toolTip = state.map { spokenState ?? $0.name }
        needsLayout = true
        refreshAccessibility()
    }

    private func rebuildContents() {
        buttons.forEach { $0.removeFromSuperview() }
        buttons = []
        badges = []
        for (index, title) in titles.enumerated() {
            let button = NSButton(title: title, target: self, action: #selector(segmentTapped(_:)))
            button.isBordered = false
            button.font = DS.Text.body(.medium)
            button.tag = index
            button.menu = menu
            if compact, let symbol = symbols[index], let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
                button.image = image
                button.imagePosition = .imageOnly
                button.toolTip = title
            }
            button.setAccessibilityRole(.radioButton)
            addSubview(button)
            buttons.append(button)
            let badge = DS.StatusDot(state: badgeStates.indices.contains(index) ? (badgeStates[index] ?? .idle) : .idle)
            badge.translatesAutoresizingMaskIntoConstraints = true
            badge.isHidden = !(badgeStates.indices.contains(index) && badgeStates[index] != nil)
            badge.setAccessibilityElement(false)
            button.addSubview(badge)
            badges.append(badge)
        }
        // Hug the titles: segment width is the widest title plus padding, so the control keeps
        // its size as selection changes and never collapses below what it has to say.
        let widest = buttons.map { $0.intrinsicContentSize.width }.max() ?? 0
        let segmentWidth = ceil(widest) + (compact ? 16 : 28)
        widthConstraint?.isActive = false
        widthConstraint = widthAnchor.constraint(equalToConstant: segmentWidth * CGFloat(max(buttons.count, 1)))
        widthConstraint?.priority = .defaultHigh
        widthConstraint?.isActive = true
        refreshTitles()
        refreshAccessibility()
        lastLayoutBounds = .zero
        needsLayout = true
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override var menu: NSMenu? {
        didSet { buttons.forEach { $0.menu = menu } }
    }

    // Manual layout: equal-width segments, thumb under the selected one.
    override func layout() {
        super.layout()
        track.frame = bounds
        let width = bounds.width / CGFloat(max(buttons.count, 1))
        for (index, button) in buttons.enumerated() {
            let titleWidth = min(button.intrinsicContentSize.width, width)
            // On the title's centre line, just after it — a dot riding up like a superscript read
            // as misaligned. Title and dot centre as one group, so the dot never crowds the edge.
            let dot = DS.StatusDot.diameter
            let shift = badges[index].isHidden ? 0 : (DS.Spacing.s + dot) / 2
            button.frame = NSRect(x: CGFloat(index) * width - shift, y: 0, width: width, height: bounds.height)
            badges[index].frame = NSRect(x: (width + titleWidth) / 2 + DS.Spacing.s, y: (bounds.height - dot) / 2, width: dot, height: dot)
        }
        // Snap the thumb only when the control actually resized — selecting re-tints a label,
        // which schedules a layout pass that would otherwise teleport the thumb mid-slide.
        if bounds != lastLayoutBounds {
            lastLayoutBounds = bounds
            thumbContainer.frame = thumbFrame(for: max(selectedIndex, 0))
            thumbContainer.subviews.first?.frame = thumbContainer.bounds
        }
        thumbContainer.isHidden = selectedIndex < 0
    }

    /// Where a segment's title starts and its dot ends, in the control's coordinates.
    func badgeGroupForTesting(_ index: Int) -> (titleMinX: CGFloat, dotMaxX: CGFloat) {
        let button = buttons[index]
        let titleWidth = min(button.intrinsicContentSize.width, button.frame.width)
        return (button.frame.minX + (button.frame.width - titleWidth) / 2, button.frame.minX + badges[index].frame.maxX)
    }

    /// No segment selected (the window is on a stage the control doesn't show): no thumb.
    func clearSelection() {
        selectedIndex = -1
        thumbContainer.isHidden = true
        refreshTitles()
        refreshAccessibility()
    }

    private func thumbFrame(for index: Int) -> NSRect {
        let width = bounds.width / CGFloat(max(buttons.count, 1))
        return NSRect(x: CGFloat(index) * width + 2, y: 2, width: width - 4, height: bounds.height - 4)
    }

    func select(_ index: Int, animated: Bool) {
        guard buttons.indices.contains(index) else { return }
        let wasHidden = thumbContainer.isHidden
        thumbContainer.isHidden = false
        selectedIndex = index
        refreshTitles()
        refreshAccessibility()
        guard animated, !wasHidden else {
            thumbContainer.frame = thumbFrame(for: index)
            thumbContainer.subviews.first?.frame = thumbContainer.bounds
            return
        }
        DS.Motion.animate(DS.Motion.snappy, crossfading: self, {
            thumbContainer.animator().frame = thumbFrame(for: index)
        })
    }

    private func refreshTitles() {
        for (index, button) in buttons.enumerated() {
            button.contentTintColor = index == selectedIndex ? .labelColor : .secondaryLabelColor
        }
    }

    private func refreshAccessibility() {
        for (index, button) in buttons.enumerated() {
            let state = accessibilityStates.indices.contains(index) ? accessibilityStates[index] : nil
            button.setAccessibilityLabel(state.map { "\(titles[index]), \($0)" } ?? titles[index])
            button.setAccessibilityValue(index == selectedIndex ? 1 : 0)
        }
    }

    /// For tests and the AX tree: what each segment says.
    var segmentAccessibilityLabels: [String] { buttons.compactMap { $0.accessibilityLabel() } }

    @objc private func segmentTapped(_ sender: NSButton) {
        guard isEnabledControl, sender.tag != selectedIndex else { return }
        select(sender.tag, animated: true)
        onChange?(sender.tag)
    }
}
