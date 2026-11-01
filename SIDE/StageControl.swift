import AppKit
import Heron

/// Search as its own circular glass button beside the floating bar (or a plain icon in the top
/// row) — a component, placement-agnostic like the rest.
final class GlassCircleButton: NSView {
    let button = PressButton()
    private let diameter: CGFloat

    init(symbol: String, accessibilityLabel: String, diameter: CGFloat = 40) {
        self.diameter = diameter
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibilityLabel)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .medium))
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.setAccessibilityLabel(accessibilityLabel)
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: diameter), heightAnchor.constraint(equalToConstant: diameter),
            button.topAnchor.constraint(equalTo: topAnchor), button.bottomAnchor.constraint(equalTo: bottomAnchor),
            button.leadingAnchor.constraint(equalTo: leadingAnchor), button.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Puts a glass disc behind the icon. Off in the top row, where it is a plain toolbar icon.
    func setGlass(_ on: Bool) {
        subviews.filter { $0 !== button }.forEach { $0.removeFromSuperview() }
        guard on else { return }
        let glass = DS.makeGlass(cornerRadius: diameter / 2)
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass, positioned: .below, relativeTo: button)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor), glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor), glass.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }
}

/// A borderless button that tells its container about the press, so the whole glass piece
/// swells and springs back rather than only the glyph.
final class PressButton: NSButton {
    override func mouseDown(with event: NSEvent) {
        let target = superview ?? self
        target.wantsLayer = true
        DS.Motion.press(target, down: true)
        super.mouseDown(with: event)  // tracks until the mouse is released
        DS.Motion.press(target, down: false)
    }
    override var mouseDownCanMoveWindow: Bool { false }
}

/// The 12 pt progress ring (Direction 03 §6): determinate, or a quarter arc turning while the
/// amount isn't known. `label` at α .6, like the working dot. Under Reduce Motion the
/// indeterminate ring stands still.
final class ProgressRing: NSView {
    static let diameter: CGFloat = 12
    /// nil: indeterminate.
    var fraction: Double? { didSet { if fraction != oldValue { apply() } } }

    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()

    init(fraction: Double? = nil) {
        self.fraction = fraction
        super.init(frame: NSRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter))
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: Self.diameter), heightAnchor.constraint(equalToConstant: Self.diameter)])
        let lineWidth: CGFloat = 1.5
        let rect = NSRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter).insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        for shape in [track, arc] {
            shape.frame = bounds
            // From twelve o'clock, clockwise.
            let path = CGMutablePath()
            path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: rect.width / 2, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
            shape.path = path
            shape.fillColor = nil
            shape.lineWidth = lineWidth
            shape.lineCap = .round
            layer?.addSublayer(shape)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        apply()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            track.strokeColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
            arc.strokeColor = NSColor.labelColor.withAlphaComponent(0.6).cgColor
        }
    }

    private func apply() {
        applyColors()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arc.strokeEnd = fraction.map { CGFloat(max(0, min(1, $0))) } ?? 0.25
        CATransaction.commit()
        setAccessibilityValue(fraction.map { NSNumber(value: $0) })
        guard let layer else { return }
        let spinning = fraction == nil && window != nil && !DS.Motion.reduceMotion
        if spinning, layer.animation(forKey: "spin") == nil {
            // Rotate the arc about the ring's centre (AppKit layers turn about their origin).
            arc.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            arc.frame = bounds
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -2 * CGFloat.pi
            spin.duration = DS.Motion.spinDuration
            spin.repeatCount = .infinity
            arc.add(spin, forKey: "spin")
        } else if !spinning {
            arc.removeAnimation(forKey: "spin")
        }
    }

    var isSpinningForTesting: Bool { arc.animation(forKey: "spin") != nil }
}

/// A glass capsule with an optional leading mark (a status dot or a progress ring) and a title
/// (Direction 03 §6). It grows out of the bar when it comes and shrinks back when it goes, and
/// what it says crossfades in place. Off the bar (the top-row placement) it's plain, like
/// search's icon there.
class GlassPill: NSView {
    enum Mark: Equatable {
        case none
        case dot(DS.StatusState)
        case ring(fraction: Double?)
    }

    var onClick: (() -> Void)?
    private(set) var title = ""
    private(set) var mark: Mark = .none
    private let label = NSTextField(labelWithString: "")
    private let ring = ProgressRing()
    private let dot = DS.StatusDot(state: .failed)
    let row = NSStackView()
    private var glass: NSView?
    private let height: CGFloat

    init(height: CGFloat, glass: Bool) {
        self.height = height
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        if glass {
            let glassView = DS.makeGlass(cornerRadius: height / 2)
            addSubview(glassView)
            NSLayoutConstraint.activate([
                glassView.topAnchor.constraint(equalTo: topAnchor), glassView.bottomAnchor.constraint(equalTo: bottomAnchor),
                glassView.leadingAnchor.constraint(equalTo: leadingAnchor), glassView.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
            self.glass = glassView
        }
        label.font = DS.Text.body(.medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = DS.Spacing.s
        row.detachesHiddenViews = true
        row.translatesAutoresizingMaskIntoConstraints = false
        for view in [ring, dot, label] as [NSView] { row.addArrangedSubview(view) }
        addSubview(row)
        let inset = glass ? DS.Spacing.l : DS.Spacing.s
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: height),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        set(title: "", mark: .none)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var mouseDownCanMoveWindow: Bool { false }

    /// What it says. A change while it's on screen crossfades.
    func set(title: String, mark: Mark) {
        guard title != self.title || mark != self.mark || label.stringValue != title else { return }
        let changingInPlace = !isHidden && window != nil && !self.title.isEmpty
        // Only a change of words fades: a ring counting up isn't a change of what it says.
        let wordsChange = title != self.title
        self.title = title
        self.mark = mark
        if changingInPlace, wordsChange { DS.Motion.crossfade(row) }
        label.stringValue = title
        setAccessibilityLabel(title)
        switch mark {
        case .none:
            ring.isHidden = true
            dot.isHidden = true
        case .dot(let state):
            ring.isHidden = true
            dot.state = state
            dot.isHidden = false
        case .ring(let fraction):
            dot.isHidden = true
            ring.fraction = fraction
            ring.isHidden = false
        }
    }

    /// Comes out of the bar on the smooth spring and goes back on a fade. Purely layer animation
    /// over the settled layout.
    func setShown(_ shown: Bool, animated: Bool) {
        guard shown == isHidden || shownGoingAway else { return }
        shownGoingAway = false
        guard animated, window != nil, !DS.Motion.reduceMotion, let layer else {
            isHidden = !shown
            alphaValue = 1
            return
        }
        if shown {
            isHidden = false
            alphaValue = 1
            superview?.layoutSubtreeIfNeeded()
            let cx = bounds.midX, cy = bounds.midY
            let small = CATransform3DConcat(CATransform3DConcat(CATransform3DMakeTranslation(-cx, -cy, 0), CATransform3DMakeScale(0.6, 0.6, 1)), CATransform3DMakeTranslation(cx, cy, 0))
            let grow = DS.Motion.spring(DS.Motion.smooth, keyPath: "transform")
            grow.fromValue = layer.presentation()?.transform ?? small
            grow.toValue = CATransform3DIdentity
            layer.transform = CATransform3DIdentity
            layer.add(grow, forKey: "grow")
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = DS.Motion.fadeDuration
            fade.timingFunction = DS.Motion.fadeCurve
            layer.add(fade, forKey: "growFade")
        } else {
            shownGoingAway = true
            DS.Motion.fade({ animator().alphaValue = 0 }, completion: { [weak self] in
                guard let self, self.shownGoingAway else { return }
                self.shownGoingAway = false
                self.isHidden = true
                self.alphaValue = 1
            })
        }
    }
    private var shownGoingAway = false
    /// Shown, and not on its way out.
    var isShown: Bool { !isHidden && !shownGoingAway }

    override func mouseDown(with event: NSEvent) {
        DS.Motion.press(self, down: true, amount: 1.04)
    }

    override func mouseUp(with event: NSEvent) {
        DS.Motion.press(self, down: false, amount: 1.04)
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    var ringForTesting: ProgressRing { ring }
}

/// Zoom's pill (⌘= ⌘− ⌘0): − and + around the size, the size itself back to the default. It
/// comes when you zoom and goes a moment later (it stays while the pointer is on it); it's
/// never there otherwise.
final class ZoomPill: GlassPill {
    var onZoomOut: (() -> Void)?
    var onZoomIn: (() -> Void)?
    /// It came or went: what fits beside it changed.
    var onShownChanged: (() -> Void)?
    /// How long it stays after the last zoom, or after the pointer leaves it.
    static let lingering: TimeInterval = 2.5
    private var hideTimer: Timer?
    private var pointerInside = false

    override init(height: CGFloat, glass: Bool) {
        super.init(height: height, glass: glass)
        isHidden = true
        let minus = Self.button("minus", "Zoom Out", #selector(zoomOutPressed))
        let plus = Self.button("plus", "Zoom In", #selector(zoomInPressed))
        minus.target = self
        plus.target = self
        row.insertArrangedSubview(minus, at: 0)
        row.addArrangedSubview(plus)
        toolTip = "Click the size for the default"
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func button(_ symbol: String, _ label: String, _ action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage(), target: nil, action: action)
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold, scale: .medium)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        // One size for both: "minus" is a narrower image than "plus".
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([button.widthAnchor.constraint(equalToConstant: 20), button.heightAnchor.constraint(equalToConstant: 20)])
        button.setAccessibilityLabel(label)
        return button
    }

    @objc private func zoomOutPressed() { onZoomOut?() }
    @objc private func zoomInPressed() { onZoomIn?() }

    /// A zoom happened: say the size, and stay a moment.
    func show(_ title: String) {
        set(title: title, mark: .none)
        let arriving = !isShown
        setShown(true, animated: true)
        if arriving { onShownChanged?() }
        scheduleHide()
    }

    private func scheduleHide() {
        hideTimer?.invalidate()
        guard !pointerInside else { return }
        hideTimer = Timer.scheduledTimer(withTimeInterval: Self.lingering, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.leave() }
        }
    }

    private func leave() {
        setShown(false, animated: true)
        // Measured once it's gone, not mid-fade.
        DispatchQueue.main.asyncAfter(deadline: .now() + DS.Motion.fadeDuration + 0.05) { [weak self] in
            guard let self, !self.isShown else { return }
            self.onShownChanged?()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        pointerInside = true
        hideTimer?.invalidate()
    }

    override func mouseExited(with event: NSEvent) {
        pointerInside = false
        if isShown { scheduleHide() }
    }

    func hideForTesting() { hideTimer?.fire() }
}
