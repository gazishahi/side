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
    /// Each segment's symbol before its title, not only when compact.
    var showsSymbols = false { didSet { if showsSymbols != oldValue { rebuildContents() } } }
    /// The stage control (the owner, 2026-11-04: less text in the bar): every segment is its
    /// symbol, and only the selected one also says its name. Selecting another widens it as the
    /// last one narrows, the thumb riding along. The selected slot is as wide as the widest
    /// name needs, so the control keeps one width whichever is selected.
    var expandsSelected = false { didSet { if expandsSelected != oldValue { rebuildContents() } } }
    private static let collapsedWidth: CGFloat = 40
    private static let iconGap: CGFloat = 6
    private var expandedWidth: CGFloat = 0
    /// Expanding: each segment's symbol and name, drawn as their own views inside its button so
    /// the symbol slides and the name fades as the segment resizes (a crossfade of the whole
    /// button showed both states at once).
    private var icons: [NSImageView] = []
    private var names: [NSTextField] = []
    /// Button frames are set by layout only when something moved them; a layout pass during a
    /// selection's slide would otherwise snap them to the end.
    private var framesDirty = true

    private let style: ThumbStyle
    private let height: CGFloat
    /// The glass rides inside a plain container, and the *container* is what animates: glass
    /// views don't reliably animate frame changes themselves.
    private let thumbContainer = NSView()
    private let hoverCapsule = NSView()
    private var hoveredIndex: Int?
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
        if style == .capsule {
            // Under the pointer, an unchosen segment shows its own faint capsule: icon-only
            // segments otherwise gave no sign they were there to press (2026-11-04).
            hoverCapsule.wantsLayer = true
            hoverCapsule.layer?.cornerRadius = (height - 4) / 2
            hoverCapsule.bindLayerBackground(DS.Color.hoverCapsule)
            hoverCapsule.alphaValue = 0
            addSubview(hoverCapsule)
        }
        addSubview(thumbContainer)
        heightAnchor.constraint(equalToConstant: height).isActive = true
        setSegments(titles, symbols: titles.map { _ in nil }, selected: 0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Replaces the segments — the stage control's set changes with pins and attention.
    func setSegments(_ titles: [String], symbols: [String?]? = nil, selected: Int, animated: Bool = false) {
        // Animated, the segments that stay slide from where they were, a new one fades in, and
        // the thumb moves to the selection: leaving an unpinned stage (Branches) changes which
        // stages show, and the control used to jump (the owner, 2026-11-04).
        let before = animated && window != nil && !buttons.isEmpty && !DS.Motion.reduceMotion ? placement() : nil
        self.titles = titles
        self.symbols = symbols ?? titles.map { _ in nil }
        accessibilityStates = titles.map { _ in nil }
        badgeStates = titles.map { _ in nil }
        selectedIndex = selected < 0 ? -1 : max(0, min(selected, titles.count - 1))
        rebuildContents()
        guard let before, let root = window?.contentView else { return }
        for (index, title) in titles.enumerated() {
            guard let old = before.segments[title] else {
                buttons[index].alphaValue = 0
                continue
            }
            buttons[index].frame = old.button
            if icons.indices.contains(index), let icon = old.icon, let name = old.name {
                icons[index].frame = icon
                names[index].frame = name
                names[index].alphaValue = old.nameAlpha
            }
        }
        thumbContainer.isHidden = before.thumbHidden
        thumbContainer.frame = before.thumb
        thumbContainer.subviews.first?.frame = thumbContainer.bounds
        let buttons = buttons
        DS.Motion.animate(DS.Motion.snappy, {
            // The control's own width changes with its segments; its layout runs in here, so
            // the bar, the segments and the thumb all move together.
            root.layoutSubtreeIfNeeded()
            buttons.forEach { $0.animator().alphaValue = 1 }
        })
    }

    /// Where every segment and the thumb are, by title.
    private func placement() -> (segments: [String: (button: NSRect, icon: NSRect?, name: NSRect?, nameAlpha: CGFloat)], thumb: NSRect, thumbHidden: Bool) {
        var segments: [String: (button: NSRect, icon: NSRect?, name: NSRect?, nameAlpha: CGFloat)] = [:]
        for (index, title) in titles.enumerated() where buttons.indices.contains(index) {
            let hasParts = icons.indices.contains(index)
            segments[title] = (buttons[index].frame, hasParts ? icons[index].frame : nil, hasParts ? names[index].frame : nil, hasParts ? names[index].alphaValue : 0)
        }
        return (segments, thumbContainer.frame, thumbContainer.isHidden)
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
        framesDirty = true
        needsLayout = true
        refreshAccessibility()
    }

    private func rebuildContents() {
        buttons.forEach { $0.removeFromSuperview() }
        buttons = []
        badges = []
        icons = []
        names = []
        for (index, title) in titles.enumerated() {
            let button = NSButton(title: title, target: self, action: #selector(segmentTapped(_:)))
            button.isBordered = false
            button.font = DS.Text.body(.medium)
            button.tag = index
            button.menu = menu
            if expandsSelected {
                button.title = ""
                let icon = NSImageView()
                icon.image = symbols[index].flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
                icon.symbolConfiguration = .init(pointSize: 13, weight: .medium)
                icon.imageScaling = .scaleProportionallyDown
                // The name fades inside the segment as it narrows, never over its neighbour.
                button.wantsLayer = true
                button.layer?.masksToBounds = true
                let name = NSTextField(labelWithString: title)
                name.font = DS.Text.body(.medium)
                for view in [icon, name] as [NSView] {
                    view.wantsLayer = true
                    view.setAccessibilityElement(false)
                    button.addSubview(view)
                }
                icons.append(icon)
                names.append(name)
                button.toolTip = index == selectedIndex ? nil : title
            } else if compact, let symbol = symbols[index], let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
                button.image = image
                button.imagePosition = .imageOnly
                button.toolTip = title
            } else if showsSymbols, let symbol = symbols[index],
                      let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                        .withSymbolConfiguration(.init(pointSize: 11, weight: .medium)) {
                button.image = image
                button.imagePosition = .imageLeading
                button.imageHugsTitle = true
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
        let total: CGFloat
        if expandsSelected {
            expandedWidth = ceil(buttons.indices.map(expandedContentWidth).max() ?? 0) + 28
            total = Self.collapsedWidth * CGFloat(max(buttons.count - 1, 0)) + expandedWidth
        } else {
            let widest = buttons.map { $0.intrinsicContentSize.width }.max() ?? 0
            total = (ceil(widest) + (compact ? 16 : 28)) * CGFloat(max(buttons.count, 1))
        }
        widthConstraint?.isActive = false
        widthConstraint = widthAnchor.constraint(equalToConstant: total)
        widthConstraint?.priority = .defaultHigh
        widthConstraint?.isActive = true
        refreshTitles()
        refreshAccessibility()
        lastLayoutBounds = .zero
        framesDirty = true
        needsLayout = true
    }

    /// Room for any symbol at 13 pt: sized from the image, symbols drew clipped.
    private func iconSize(_ index: Int) -> NSSize { NSSize(width: 18, height: 18) }
    private func nameSize(_ index: Int) -> NSSize {
        let size = names[index].intrinsicContentSize
        return NSSize(width: ceil(size.width) + 2, height: ceil(size.height))
    }

    /// Symbol and name together.
    private func expandedContentWidth(_ index: Int) -> CGFloat {
        iconSize(index).width + Self.iconGap + nameSize(index).width
    }

    /// Each segment's frame: equal widths, or (expanding) narrow ones with the selected one wide.
    private func segmentFrames() -> [NSRect] {
        let count = buttons.count
        guard count > 0 else { return [] }
        guard expandsSelected else {
            let width = bounds.width / CGFloat(count)
            return (0..<count).map { NSRect(x: CGFloat($0) * width, y: 0, width: width, height: bounds.height) }
        }
        var x: CGFloat = selectedIndex < 0 ? (bounds.width - Self.collapsedWidth * CGFloat(count)) / 2 : 0
        return (0..<count).map { index in
            let width = index == selectedIndex ? expandedWidth : Self.collapsedWidth
            defer { x += width }
            return NSRect(x: x, y: 0, width: width, height: bounds.height)
        }
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override var menu: NSMenu? {
        didSet { buttons.forEach { $0.menu = menu } }
    }

    // Manual layout: the segments, thumb under the selected one.
    override func layout() {
        super.layout()
        track.frame = bounds
        // Snap only when the control actually resized or its segments changed — selecting
        // re-tints a label, which schedules a layout pass that would otherwise teleport the
        // thumb (and, expanding, the segments) mid-slide.
        if bounds != lastLayoutBounds || framesDirty {
            lastLayoutBounds = bounds
            framesDirty = false
            placeSegments()
            thumbContainer.frame = thumbFrame(for: max(selectedIndex, 0))
            thumbContainer.subviews.first?.frame = thumbContainer.bounds
        }
        if !thumbFadingOut { thumbContainer.isHidden = selectedIndex < 0 }
    }

    private func placeSegments(animated: Bool = false) {
        for (index, (button, frame)) in zip(buttons, segmentFrames()).enumerated() {
            var titleWidth = min(button.intrinsicContentSize.width, frame.width)
            if expandsSelected {
                let expanded = index == selectedIndex
                let icon = iconSize(index), name = nameSize(index)
                let contentWidth = expanded ? expandedContentWidth(index) : icon.width
                titleWidth = contentWidth
                let iconX = ((frame.width - contentWidth) / 2).rounded()
                let iconFrame = NSRect(x: iconX, y: ((frame.height - icon.height) / 2).rounded(), width: icon.width, height: icon.height)
                let nameFrame = NSRect(x: iconX + icon.width + Self.iconGap, y: ((frame.height - name.height) / 2).rounded(), width: name.width, height: name.height)
                if animated {
                    let icon = icons[index], name = names[index]
                    DS.Motion.animate(DS.Motion.snappy, {
                        icon.animator().frame = iconFrame
                        name.animator().frame = nameFrame
                        if expanded { name.animator().alphaValue = 1 }
                    })
                    // Gone at once as its segment starts to narrow: even a short fade left a
                    // clipped stub of it behind for a frame or two.
                    if !expanded { name.alphaValue = 0 }
                } else {
                    icons[index].frame = iconFrame
                    names[index].frame = nameFrame
                    names[index].alphaValue = expanded ? 1 : 0
                }
                button.toolTip = expanded ? nil : titles[index]
            }
            // On the title's centre line, just after it — a dot riding up like a superscript read
            // as misaligned. Title and dot centre as one group, so the dot never crowds the edge.
            // A segment that's only its symbol keeps the symbol centred and the dot just after it,
            // inside the segment (it was cut off at the segment's edge, 2026-11-04).
            let dot = DS.StatusDot.diameter
            let iconOnly = expandsSelected && index != selectedIndex
            let shift = badges[index].isHidden || iconOnly ? 0 : (DS.Spacing.s + dot) / 2
            let target = frame.offsetBy(dx: -shift, dy: 0)
            let gap = iconOnly ? 2 : DS.Spacing.s
            if animated {
                DS.Motion.animate(DS.Motion.snappy, { button.animator().frame = target })
            } else {
                button.frame = target
            }
            badges[index].frame = NSRect(x: (frame.width + titleWidth) / 2 + gap, y: (bounds.height - dot) / 2, width: dot, height: dot)
        }
    }

    /// Where a segment's title starts and its dot ends, in the control's coordinates.
    func badgeGroupForTesting(_ index: Int) -> (titleMinX: CGFloat, dotMaxX: CGFloat) {
        let button = buttons[index]
        let titleWidth = min(button.intrinsicContentSize.width, button.frame.width)
        return (button.frame.minX + (button.frame.width - titleWidth) / 2, button.frame.minX + badges[index].frame.maxX)
    }

    /// No segment selected (the window is on a stage the control doesn't show): no thumb.
    func clearSelection() {
        let previous = selectedIndex
        guard previous >= 0 else { return }
        selectedIndex = -1
        refreshTitles()
        refreshAccessibility()
        guard window != nil, !DS.Motion.reduceMotion, buttons.indices.contains(previous) else {
            thumbContainer.isHidden = true
            if expandsSelected { framesDirty = true; needsLayout = true }
            return
        }
        // The selected segment narrows back to its symbol and the thumb fades where it was.
        thumbFadingOut = true
        if expandsSelected { placeSegments(animated: true) }
        let target = segmentFrames()[previous].insetBy(dx: 2, dy: 2)
        DS.Motion.animate(DS.Motion.snappy, {
            thumbContainer.animator().frame = target
            thumbContainer.subviews.first?.animator().frame = NSRect(origin: .zero, size: target.size)
            thumbContainer.animator().alphaValue = 0
        }, completion: { [weak self] in
            guard let self, self.thumbFadingOut else { return }
            self.thumbFadingOut = false
            self.thumbContainer.isHidden = true
            self.thumbContainer.alphaValue = 1
        })
    }
    /// The thumb on its way out after `clearSelection`, still shown until it's faded.
    private var thumbFadingOut = false

    private func thumbFrame(for index: Int) -> NSRect {
        let frames = segmentFrames()
        guard frames.indices.contains(index) else { return .zero }
        return frames[index].insetBy(dx: 2, dy: 2)
    }

    func select(_ index: Int, animated: Bool) {
        guard buttons.indices.contains(index) else { return }
        // The segments move as the selection does: the hover comes back with the pointer's next move.
        hover(at: nil)
        let wasHidden = thumbContainer.isHidden
        let previous = selectedIndex
        thumbContainer.isHidden = false
        selectedIndex = index
        _ = previous
        refreshTitles()
        refreshAccessibility()
        guard animated, window != nil, !DS.Motion.reduceMotion else {
            placeSegments()
            thumbFadingOut = false
            thumbContainer.alphaValue = 1
            thumbContainer.frame = thumbFrame(for: index)
            thumbContainer.subviews.first?.frame = thumbContainer.bounds
            return
        }
        if wasHidden || thumbFadingOut {
            // From no selection (Branches, which the control doesn't show): the segments make
            // room as they do between stages, and the thumb fades in where it lands. It used to
            // appear at once (the owner, 2026-11-04).
            // It grows out of the segment, in step with the segments.
            thumbFadingOut = false
            if wasHidden {
                thumbContainer.frame = buttons[index].frame.insetBy(dx: 2, dy: 2)
                thumbContainer.subviews.first?.frame = thumbContainer.bounds
                thumbContainer.alphaValue = 0
            }
            if expandsSelected { placeSegments(animated: true) }
            let target = thumbFrame(for: index)
            DS.Motion.animate(DS.Motion.snappy, {
                thumbContainer.animator().frame = target
                thumbContainer.subviews.first?.animator().frame = NSRect(origin: .zero, size: target.size)
                thumbContainer.animator().alphaValue = 1
            })
            CATransaction.flush()
            return
        }
        if expandsSelected { placeSegments(animated: true) }
        DS.Motion.animate(DS.Motion.snappy, crossfading: expandsSelected ? nil : self, {
            thumbContainer.animator().frame = thumbFrame(for: index)
        })
        // Committed now: a stage that takes a moment to show (the Terminal's first visit) used
        // to hold the run loop until the slide was over, so it was never seen.
        CATransaction.flush()
    }

    private func refreshTitles() {
        for (index, button) in buttons.enumerated() {
            let color: NSColor = index == selectedIndex ? .labelColor : .secondaryLabelColor
            button.contentTintColor = color
            if icons.indices.contains(index) {
                icons[index].contentTintColor = color
                names[index].textColor = color
            }
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

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        guard style == .capsule else { return }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) { hover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseEntered(with event: NSEvent) { hover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hover(at: nil) }

    /// UI testing: the pointer over segment `index` (nil: off the control).
    func hoverForTesting(_ index: Int?) {
        hover(at: index.flatMap { segmentFrames().indices.contains($0) ? NSPoint(x: segmentFrames()[$0].midX, y: bounds.midY) : nil })
    }

    private func hover(at point: NSPoint?) {
        let index = point.flatMap { point in segmentFrames().firstIndex { $0.contains(point) } }
        let shown = index.flatMap { $0 == selectedIndex ? nil : $0 }
        guard shown != hoveredIndex else { return }
        let wasShown = hoveredIndex != nil
        hoveredIndex = shown
        guard let shown else {
            DS.Motion.fade({ hoverCapsule.animator().alphaValue = 0 })
            return
        }
        let frame = segmentFrames()[shown].insetBy(dx: 2, dy: 2)
        if wasShown, !DS.Motion.reduceMotion {
            // From one segment to the next it slides, as the thumb does.
            DS.Motion.animate(DS.Motion.snappy, { hoverCapsule.animator().frame = frame })
        } else {
            hoverCapsule.frame = frame
            DS.Motion.fade({ hoverCapsule.animator().alphaValue = 1 })
        }
    }

    @objc private func segmentTapped(_ sender: NSButton) {
        guard isEnabledControl, sender.tag != selectedIndex else { return }
        select(sender.tag, animated: true)
        onChange?(sender.tag)
    }
}
