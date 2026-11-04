import AppKit
import SideAgents

/// Review's checkpoints as a line you pick a range from (SIDE_RFC_FIND_REVIEW_TRACKS.md, R1):
/// the base, each checkpoint the track is ahead by, and "Now" when the branch has moved past the
/// newest one. The diff below shows the changes between the two ends of the range; by default
/// that's everything (base to the tip), and clicking a checkpoint shows what it alone changed.
struct CheckpointTimeline: Equatable {
    struct Node: Equatable {
        enum Kind: Equatable {
            case base
            case checkpoint(UUID, number: Int)
            case now
        }
        var kind: Kind
        /// What git diffs against: the base ref, a checkpoint's commit, or the branch.
        var ref: String
        var title: String
        var verification: Bool?
    }

    private(set) var nodes: [Node]
    /// Indices into `nodes`, `lo < hi`.
    private(set) var lo: Int
    private(set) var hi: Int

    init(nodes: [Node]) {
        self.nodes = nodes
        lo = 0
        hi = max(0, nodes.count - 1)
    }

    /// Base, the checkpoints (oldest first, each with a commit on the branch), then Now if the
    /// branch's tip isn't the newest checkpoint's commit.
    static func build(baseRef: String, branch: String, checkpoints: [(checkpoint: Checkpoint, number: Int)], tipSHA: String?) -> CheckpointTimeline {
        var nodes = [Node(kind: .base, ref: baseRef, title: baseRef, verification: nil)]
        for (checkpoint, number) in checkpoints {
            guard let sha = checkpoint.gitCommitSHA else { continue }
            nodes.append(Node(
                kind: .checkpoint(checkpoint.id, number: number), ref: sha,
                title: checkpoint.declaredIntent.isEmpty ? "Checkpoint \(number)" : checkpoint.declaredIntent,
                verification: checkpoint.verification.map(\.passed)
            ))
        }
        let newest = nodes.count > 1 ? nodes.last?.ref : nil
        let tipIsNewest = tipSHA.map { tip in newest.map { tip.hasPrefix($0) || $0.hasPrefix(tip) } ?? false } ?? true
        if !tipIsNewest || nodes.count == 1 {
            nodes.append(Node(kind: .now, ref: branch, title: "Now", verification: nil))
        }
        return CheckpointTimeline(nodes: nodes)
    }

    var isEverything: Bool { nodes.count < 2 || (lo == 0 && hi == nodes.count - 1) }
    /// One checkpoint's own changes: the range is it and the node before it.
    var single: Node? { hi == lo + 1 ? nodes[hi] : nil }
    /// What to diff: from the range's start to its end.
    var refs: (from: String, to: String) { (nodes[lo].ref, nodes[hi].ref) }
    func contains(_ index: Int) -> Bool { index > lo && index <= hi }

    /// A click: a checkpoint alone (the step that ends at it), or with Shift, the range grown to
    /// take it in. The base means everything.
    mutating func select(_ index: Int, extending: Bool = false) {
        guard nodes.indices.contains(index), nodes.count > 1 else { return }
        if index == 0 { selectEverything(); return }
        if extending {
            lo = min(lo, index - 1)
            hi = max(hi, index)
        } else {
            lo = index - 1
            hi = index
        }
    }

    /// A drag from one node to another.
    mutating func select(from a: Int, to b: Int) {
        guard nodes.indices.contains(a), nodes.indices.contains(b) else { return }
        if a == b { select(a); return }
        lo = min(a, b)
        hi = max(a, b)
    }

    mutating func selectEverything() {
        lo = 0
        hi = max(0, nodes.count - 1)
    }

    /// ← and →: move a one-step range; with Shift, move the range's end.
    mutating func step(_ delta: Int, extending: Bool = false) {
        guard nodes.count > 1 else { return }
        if extending {
            hi = min(nodes.count - 1, max(lo + 1, hi + delta))
            return
        }
        let end = isEverything && delta < 0 ? nodes.count - 1 : min(nodes.count - 1, max(1, hi + delta))
        lo = end - 1
        hi = end
    }

    /// Keeps the same ends (by ref) in a rebuilt timeline, or everything if they're gone.
    mutating func keepSelection(of old: CheckpointTimeline) {
        guard !old.isEverything, old.nodes.indices.contains(old.lo), old.nodes.indices.contains(old.hi),
              let a = nodes.firstIndex(where: { $0.ref == old.nodes[old.lo].ref }),
              let b = nodes.firstIndex(where: { $0.ref == old.nodes[old.hi].ref }), a < b else { return }
        lo = a
        hi = b
    }
}

/// The timeline, drawn: a hairline through the nodes, the chosen range in the accent color, each
/// checkpoint's ring colored by its verification. Only the base and the range's ends are labeled.
@MainActor
final class CheckpointTimelineView: NSView, NSViewToolTipOwner {
    var timeline = CheckpointTimeline(nodes: []) {
        didSet {
            // Placed now, not at the next layout: drawing, tooltips and accessibility read the
            // positions by node index, and a shorter timeline (another track) ran past its end.
            placeNodes()
            needsDisplay = true
        }
    }
    /// The range changed from here (click, drag, keys).
    var onChange: ((CheckpointTimeline) -> Void)?

    private static let diameter: CGFloat = 10
    private static let minSpacing: CGFloat = 22
    private static let maxSpacing: CGFloat = 64
    private static let trackY: CGFloat = 11
    private static let ellipsisWidth: CGFloat = 26
    static let height: CGFloat = 36

    /// Node index → x center, for the nodes drawn (the oldest go behind "…" when they don't fit).
    private var positions: [(index: Int, x: CGFloat)] = []
    private var dragStart: Int?
    private var axElements: [TimelineNodeElement] = []

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { timeline.nodes.count > 1 }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.height) }

    override func layout() {
        super.layout()
        placeNodes()
    }

    private func placeNodes() {
        positions = Self.positions(count: timeline.nodes.count, width: bounds.width)
        removeAllToolTips()
        for (_, x) in positions {
            addToolTip(NSRect(x: x - 10, y: 0, width: 20, height: bounds.height), owner: self, userData: nil)
        }
        rebuildAccessibility()
    }

    /// Evenly spaced up to `maxSpacing`, from the left; when even `minSpacing` doesn't fit, the
    /// base stays first and the newest take the rest.
    static func positions(count: Int, width: CGFloat) -> [(index: Int, x: CGFloat)] {
        guard count > 0 else { return [] }
        let start = diameter, end = max(start, width - diameter * 4)
        guard count > 1 else { return [(0, start)] }
        let span = end - start
        let spacing = min(maxSpacing, span / CGFloat(count - 1))
        if spacing >= minSpacing {
            return (0..<count).map { ($0, start + CGFloat($0) * spacing) }
        }
        let fitting = max(1, Int((span - ellipsisWidth) / minSpacing))
        let first = count - fitting
        var result = [(index: 0, x: start)]
        for (offset, index) in (first..<count).enumerated() {
            result.append((index, start + ellipsisWidth + CGFloat(offset + 1) * minSpacing))
        }
        return result
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !positions.isEmpty else { return }
        let y = Self.trackY
        let accent = NSColor.controlAccentColor
        // The track, with a break where older nodes are hidden.
        let hidden = positions.count < timeline.nodes.count
        let track = NSBezierPath()
        track.lineWidth = 1
        if hidden, positions.count > 1 {
            track.move(to: NSPoint(x: positions[0].x, y: y))
            track.line(to: NSPoint(x: positions[0].x + 6, y: y))
            track.move(to: NSPoint(x: positions[1].x - Self.minSpacing + 4, y: y))
            track.line(to: NSPoint(x: positions.last!.x, y: y))
            let dots = NSAttributedString(string: "\u{2026}", attributes: [.font: DS.Text.caption(), .foregroundColor: NSColor.tertiaryLabelColor])
            dots.draw(at: NSPoint(x: positions[0].x + 9, y: y - dots.size().height / 2 - 1))
        } else {
            track.move(to: NSPoint(x: positions.first!.x, y: y))
            track.line(to: NSPoint(x: positions.last!.x, y: y))
        }
        DS.Color.hairlineStrong.setStroke()
        track.stroke()

        // The range.
        if timeline.nodes.count > 1, let a = x(of: timeline.lo) ?? positions.first?.x, let b = x(of: timeline.hi) {
            let range = NSBezierPath()
            range.lineWidth = 2
            range.lineCapStyle = .round
            range.move(to: NSPoint(x: a, y: y))
            range.line(to: NSPoint(x: b, y: y))
            accent.setStroke()
            range.stroke()
        }

        let d = Self.diameter
        for (index, x) in positions {
            let node = timeline.nodes[index]
            let rect = NSRect(x: x - d / 2, y: y - d / 2, width: d, height: d)
            let isEnd = timeline.nodes.count > 1 && (index == timeline.hi || index == timeline.lo)
            let inRange = timeline.contains(index)
            let ring: NSColor = {
                switch node.verification {
                case true?: return DS.Color.statusVerified
                case false?: return DS.Color.statusFailed
                case nil: return inRange || isEnd ? accent : .tertiaryLabelColor
                }
            }()
            let circle: NSBezierPath
            switch node.kind {
            case .base:
                circle = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 2, yRadius: 2)
            default:
                circle = NSBezierPath(ovalIn: rect)
            }
            (isEnd && node.kind != .base ? accent : DS.Color.raised).setFill()
            circle.fill()
            circle.lineWidth = 1.5
            (isEnd && node.verification == nil ? accent : ring).setStroke()
            circle.stroke()
        }

        // Labels: the base, and the range's end (and its start when that isn't the base).
        var labeled: [Int] = [0]
        if timeline.nodes.count > 1 {
            labeled.append(timeline.hi)
            if timeline.lo != 0 { labeled.append(timeline.lo) }
        }
        var lastMaxX: CGFloat = -.infinity
        for index in Set(labeled).sorted() {
            guard let x = x(of: index) else { continue }
            let text = label(for: index)
            let isEnd = index == timeline.hi || (index == timeline.lo && index != 0)
            let string = NSAttributedString(string: text, attributes: [
                .font: DS.Text.caption(isEnd ? .semibold : .regular),
                .foregroundColor: isEnd ? NSColor.labelColor : NSColor.secondaryLabelColor,
            ])
            let size = string.size()
            var origin = NSPoint(x: x - size.width / 2, y: y + d / 2 + 3)
            origin.x = min(max(0, origin.x), bounds.width - size.width)
            guard origin.x > lastMaxX + 4 else { continue }
            string.draw(at: origin)
            lastMaxX = origin.x + size.width
        }
    }

    private func label(for index: Int) -> String {
        let node = timeline.nodes[index]
        switch node.kind {
        case .base: return node.ref
        case .checkpoint(_, let number): return "\(number)"
        case .now: return "Now"
        }
    }

    private func x(of index: Int) -> CGFloat? { positions.first { $0.index == index }?.x }

    private func node(at point: NSPoint) -> Int? {
        let nearest = positions.min { abs($0.x - point.x) < abs($1.x - point.x) }
        guard let nearest, abs(nearest.x - point.x) <= max(12, Self.minSpacing / 2) else { return nil }
        return nearest.index
    }

    // MARK: Pointer and keys

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        dragStart = node(at: point)
        guard let index = dragStart else { return }
        var next = timeline
        next.select(index, extending: event.modifierFlags.contains(.shift))
        apply(next)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let index = node(at: convert(event.locationInWindow, from: nil)), index != start else { return }
        var next = timeline
        next.select(from: start, to: index)
        apply(next)
    }

    override func mouseUp(with event: NSEvent) { dragStart = nil }

    override func keyDown(with event: NSEvent) {
        let shift = event.modifierFlags.contains(.shift)
        var next = timeline
        switch event.specialKey {
        case .leftArrow?: next.step(-1, extending: shift)
        case .rightArrow?: next.step(1, extending: shift)
        case .home?: next.selectEverything()
        default:
            if event.charactersIgnoringModifiers == "\u{1B}" { next.selectEverything() } else { super.keyDown(with: event); return }
        }
        apply(next)
    }

    override func cancelOperation(_ sender: Any?) { var next = timeline; next.selectEverything(); apply(next) }

    private func apply(_ next: CheckpointTimeline) {
        guard next != timeline else { return }
        timeline = next
        onChange?(next)
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let index = node(at: point) else { return "" }
        let node = timeline.nodes[index]
        switch node.kind {
        case .base: return "The base, \(node.ref). Click for all changes."
        case .checkpoint(_, let number): return "\(number). \(node.title)"
        case .now: return "Changes since the newest checkpoint"
        }
    }

    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: DS.Radius.control, yRadius: DS.Radius.control).fill() }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { "Checkpoints" }
    override func accessibilityValue() -> Any? { Self.describe(timeline) }
    override func accessibilityChildren() -> [Any]? { axElements }

    /// What the range covers, in words.
    static func describe(_ timeline: CheckpointTimeline) -> String {
        guard timeline.nodes.count > 1 else { return "No checkpoints" }
        if timeline.isEverything { return "All changes" }
        func name(_ node: CheckpointTimeline.Node) -> String {
            switch node.kind {
            case .base: return node.ref
            case .checkpoint(_, let number): return "checkpoint \(number)"
            case .now: return "now"
            }
        }
        if let single = timeline.single { return "Changes in \(name(single))" }
        return "Changes from \(name(timeline.nodes[timeline.lo])) to \(name(timeline.nodes[timeline.hi]))"
    }

    private func rebuildAccessibility() {
        axElements = positions.map { index, x in
            let node = timeline.nodes[index]
            let element = TimelineNodeElement(owner: self, index: index)
            var label: String
            switch node.kind {
            case .base: label = "Base, \(node.ref), all changes"
            case .checkpoint(_, let number): label = "Checkpoint \(number), \(node.title)"
            case .now: label = "Now, changes since the newest checkpoint"
            }
            switch node.verification {
            case true?: label += ", verified"
            case false?: label += ", failed"
            case nil: break
            }
            element.setAccessibilityLabel(label)
            element.setAccessibilityRole(.button)
            element.setAccessibilityParent(self)
            element.setAccessibilityFrameInParentSpace(NSRect(x: x - 11, y: 0, width: 22, height: bounds.height))
            element.setAccessibilityValue(timeline.contains(index) ? "in range" : nil)
            return element
        }
    }

    fileprivate func press(_ index: Int) {
        var next = timeline
        next.select(index)
        apply(next)
    }
}

@MainActor
private final class TimelineNodeElement: NSAccessibilityElement {
    weak var owner: CheckpointTimelineView?
    let index: Int
    init(owner: CheckpointTimelineView, index: Int) {
        self.owner = owner
        self.index = index
        super.init()
    }
    override func accessibilityPerformPress() -> Bool {
        owner?.press(index)
        return true
    }
}
