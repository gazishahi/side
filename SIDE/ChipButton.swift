import AppKit
import UniformTypeIdentifiers

/// A small capsule control: an icon and/or a word, on glass, that presses like the rest of the
/// system. Born as the composer's bottom row and extracted once Review's Promote needed the same
/// press behaviour — a shared control has no business living inside one stage's view controller.
///
/// Not an `NSPopUpButton`. The pull-downs this replaces carried AppKit's arrow-and-bezel
/// styling, crowded titles ("Anthropic · Claude Sonnet 5 · low"), and menus that mixed two
/// decisions each — the visual noise being complained about was mostly *them*. A chip shows one
/// short fact, reveals it's interactive on hover, and owns exactly one menu. The menu pops from
/// the action (mouse-up), which is what makes an upward menu survive — popping from `mouseDown`
/// gets dismissed by its own mouse-up, the failure recorded in the design charter.
final class ChipButton: NSButton {
    var menuProvider: (() -> NSMenu)?
    /// Alternative to `menuProvider` for chips that present something other than a menu.
    var onPress: (() -> Void)?
    /// The glass view rendered behind this button, so the press spring moves both as one object.
    weak var glassBackdrop: NSView?
    /// Anything else layered on the pill (the mode-tint wash) that must dip and spring with it.
    weak var companionOverlay: NSView?
    /// Hover pill for bare chips; off for buttons that sit on their own glass, where a
    /// rounded-rect hover inside a capsule reads as a seam (the exact complaint).
    var showsHover = false
    /// Option B (Direction 02 §2.8): release normally returns straight to rest on `DS.Motion.curve`.
    /// The one control allowed a ceremonial settle — Promote — sets this.
    var settlesOnRelease = false
    private var tracking: NSTrackingArea?
    private var heightConstraint: NSLayoutConstraint!

    /// For a chip that lives in more than one place — Think's pills are composer-sized above the
    /// composer and bar-sized in the window's bar.
    func setHeight(_ height: CGFloat) { heightConstraint.constant = height }

    /// `height` exists for controls larger than a composer chip — Review's Promote is a stage's
    /// primary action, and 24pt of capsule reads as an afterthought at that size.
    init(symbolName: String?, accessibilityLabel: String, height: CGFloat = 24) {
        super.init(frame: .zero)
        isBordered = false
        title = ""  // NSButton's default title is literally "Button"
        imagePosition = symbolName == nil ? .noImage : .imageLeading
        font = DS.Text.caption(.medium)
        contentTintColor = .secondaryLabelColor
        wantsLayer = true
        layer?.cornerRadius = DS.Radius.control
        translatesAutoresizingMaskIntoConstraints = false
        heightConstraint = heightAnchor.constraint(equalToConstant: height)
        heightConstraint.isActive = true
        setAccessibilityLabel(accessibilityLabel)
        if let symbolName { setSymbol(symbolName) }
        target = self
        action = #selector(pressed)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setSymbol(_ name: String, pointSize: CGFloat = 10.5) {
        image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium))
    }

    func setLabel(_ text: String, tint: NSColor = .secondaryLabelColor) {
        title = text.isEmpty ? "" : " \(text) "
        contentTintColor = tint
    }

    /// For a chip whose label is not one colour — the changed-files pill puts its added and
    /// removed counts in green and red, the same way the panel behind it and every diff in the
    /// app already do. `attributedTitle` rather than `contentTintColor`, which can only tint the
    /// whole thing.
    ///
    /// `labelIdentity` is what callers compare against to avoid redundant updates: an
    /// `NSAttributedString` doesn't compare usefully for that, and the pill is refreshed on
    /// every phase change and usage notification.
    private(set) var labelIdentity = ""

    func setAttributedLabel(_ attributed: NSAttributedString, identity: String) {
        labelIdentity = identity
        let padded = NSMutableAttributedString(string: " ")
        padded.append(attributed)
        padded.append(NSAttributedString(string: " "))
        attributedTitle = padded
    }

    /// The Liquid Glass press, in two halves. Press: the pill eases down to 93% and *stays*
    /// there while the mouse is held — the "pushed back" state. Release: it springs out with a
    /// small overshoot. Both halves apply to the button and its glass together, so the whole
    /// pill moves as one object.
    ///
    /// `mouseDown` blocks in NSButton's tracking loop until release, which is exactly the shape
    /// this needs: dip before, release after, action (menu/popover) in between — Core Animation
    /// runs on the render server, so the release bounce plays even while a popped menu blocks
    /// the run loop.
    override func mouseDown(with event: NSEvent) {
        pressDown(self)
        if let glassBackdrop { pressDown(glassBackdrop) }
        if let companionOverlay { pressDown(companionOverlay) }
        super.mouseDown(with: event)
        pressRelease(self)
        if let glassBackdrop { pressRelease(glassBackdrop) }
        if let companionOverlay { pressRelease(companionOverlay) }
    }

    @objc private func pressed() {
        if let onPress { return onPress() }
        guard let menu = menuProvider?() else { return }
        // NSButton is *flipped*, so "above" is negative y.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -menu.size.height - DS.Spacing.s), in: self)
    }

    private func centeredLayer(_ view: NSView) -> CALayer? {
        view.wantsLayer = true
        guard let layer = view.layer else { return nil }
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: view.frame.midX, y: view.frame.midY)
        return layer
    }

    /// The Liquid Glass press, the same one the bar's search button has (owner's call,
    /// 2026-09-23: that is the macOS-native feel): the control swells under the pointer and holds
    /// there, then springs back on release with a little bounce. It used to dip *inward* to 93 %,
    /// which read as a different control family from the glass beside it.
    private func pressDown(_ view: NSView) {
        guard let layer = centeredLayer(view) else { return }
        layer.removeAnimation(forKey: "springRelease")
        guard !DS.Motion.reduceMotion else { return }
        let swell = DS.Motion.spring(keyPath: "transform.scale")
        swell.fromValue = layer.presentation()?.value(forKeyPath: "transform.scale") ?? 1
        swell.toValue = 1.08
        // Held, not removed: the control stays swollen for as long as the mouse is down.
        swell.fillMode = .forwards
        swell.isRemovedOnCompletion = false
        layer.add(swell, forKey: "springDown")
    }

    private func pressRelease(_ view: NSView) {
        guard let layer = centeredLayer(view) else { return }
        let from = layer.presentation()?.value(forKeyPath: "transform.scale") ?? 1.08
        layer.removeAnimation(forKey: "springDown")
        guard !DS.Motion.reduceMotion else { return }
        let spring = DS.Motion.spring(keyPath: "transform.scale")
        spring.damping *= settlesOnRelease ? 0.45 : 0.6  // Promote's settle bounces a touch more
        spring.duration = spring.settlingDuration
        spring.fromValue = from
        spring.toValue = 1
        layer.add(spring, forKey: "springRelease")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        if showsHover { layer?.backgroundColor = DS.Color.scrimSoft.cgColor }
    }
    override func mouseExited(with event: NSEvent) { layer?.backgroundColor = nil }
}
