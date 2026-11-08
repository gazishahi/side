import AppKit

/// The jump bar (SIDE_DESIGN_SESSIONS_2026-11-06.md, session 2): a thin rail beside Agent's
/// column with one tick per message you sent, placed where it falls in the conversation. Hover
/// shows the message's first line; a click goes to it. A turn that failed, or waits on you,
/// takes that status's color, so the rail also shows where things went wrong.
final class JumpRail: NSView {
    struct Mark: Equatable {
        /// The message's entry index.
        let id: Int
        /// Where it falls, 0 at the conversation's top to 1 at its end.
        let fraction: CGFloat
        let text: String
        let state: DS.StatusState?
    }

    static let width: CGFloat = 18

    var marks: [Mark] = [] {
        didSet {
            guard marks != oldValue else { return }
            if let hovered, !marks.contains(where: { $0.id == hovered }) { self.hovered = nil }
            // The pointer is still over a tick that moved or changed: the tip follows it.
            else if hovered != nil { showTip() }
            needsDisplay = true
            updateAccessibility()
        }
    }
    /// The message the conversation is showing: its tick is drawn longer.
    var current: Int? { didSet { if current != oldValue { needsDisplay = true } } }
    var onJump: ((Int) -> Void)?

    private var hovered: Int? {
        didSet {
            guard hovered != oldValue else { return }
            needsDisplay = true
            showTip()
        }
    }
    private let tip = JumpRailTip()
    private var trackingArea: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Your messages")
        toolTip = nil
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    /// Ticks sit inside a small inset so the first and last aren't cut by the ends.
    private var inset: CGFloat { 4 }

    private func y(of mark: Mark) -> CGFloat {
        inset + (bounds.height - inset * 2) * min(max(mark.fraction, 0), 1)
    }

    override func draw(_ dirtyRect: NSRect) {
        for mark in marks {
            let emphasized = mark.id == hovered || mark.id == current
            let length: CGFloat = emphasized ? 12 : 7
            let rect = NSRect(x: bounds.maxX - length - 3, y: y(of: mark) - 1, width: length, height: 2)
            let color: NSColor
            switch mark.state {
            case .failed?: color = DS.Color.statusFailed
            case .needsYou?: color = DS.Color.statusNeedsYou
            default: color = emphasized ? .secondaryLabelColor : .tertiaryLabelColor
            }
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
        }
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    /// The tick nearest the pointer, within reach.
    private func mark(at point: NSPoint) -> Mark? {
        marks.min { abs(y(of: $0) - point.y) < abs(y(of: $1) - point.y) }.flatMap { abs(y(of: $0) - point.y) <= 8 ? $0 : nil }
    }

    override func mouseMoved(with event: NSEvent) { hovered = mark(at: convert(event.locationInWindow, from: nil))?.id }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { hovered = nil }

    override func mouseUp(with event: NSEvent) {
        guard let mark = mark(at: convert(event.locationInWindow, from: nil)) else { return }
        onJump?(mark.id)
    }

    override func resetCursorRects() { if !marks.isEmpty { addCursorRect(bounds, cursor: .pointingHand) } }

    /// The hovered message's first line, beside its tick, in the rail's superview so it isn't
    /// clipped to the rail.
    private func showTip() {
        guard let hovered, let mark = marks.first(where: { $0.id == hovered }), let host = superview else {
            // Fades out, then goes.
            if tip.superview != nil {
                DS.Motion.fade(duration: DS.Motion.glanceDuration, { tip.animator().alphaValue = 0 }, completion: { [weak self] in
                    guard let self, self.hovered == nil else { return }
                    self.tip.removeFromSuperview()
                })
            }
            return
        }
        tip.text = mark.text
        if tip.superview !== host {
            host.addSubview(tip, positioned: .above, relativeTo: self)
            tip.alphaValue = 0
        }
        DS.Motion.fade(duration: DS.Motion.glanceDuration) { tip.animator().alphaValue = 1 }
        let size = tip.fittingSize
        let anchor = convert(NSPoint(x: bounds.minX, y: y(of: mark)), to: host)
        let originY = host.isFlipped ? anchor.y - size.height / 2 : anchor.y - size.height / 2
        tip.frame = NSRect(x: anchor.x - size.width - 4, y: originY, width: size.width, height: size.height)
    }

    // MARK: Accessibility

    private func updateAccessibility() {
        setAccessibilityChildren(marks.map { mark in
            let element = NSAccessibilityElement()
            element.setAccessibilityRole(.button)
            element.setAccessibilityLabel(mark.text + (mark.state == .failed ? ", failed" : mark.state == .needsYou ? ", needs you" : ""))
            element.setAccessibilityParent(self)
            return element
        })
    }
}

/// A one-line label on the raised tone: the rail's hover.
private final class JumpRailTip: NSView {
    private let label = NSTextField(labelWithString: "")

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = DS.Radius.control
        bindLayerBackground(DS.Color.overlay)
        label.font = DS.Text.caption()
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DS.Spacing.s),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DS.Spacing.s),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
