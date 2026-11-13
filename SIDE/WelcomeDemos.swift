import AppKit

/// The welcome's illustrations (SIDE_DESIGN_WELCOME.md): small drawings of Side at work, made of
/// the design tokens and played as short scripts on a loop. A drawing, not a recording: it stays
/// sharp at any scale, follows light and dark and the accent, and costs nothing to ship.
///
/// A demo builds its layers in a top-left space of `designSize`, centred in the view, and plays
/// `script()`: steps scheduled with `at(_:)`. Under Reduce Motion every step lands at once and
/// nothing moves: the finished picture, still.
@MainActor
class WelcomeDemo: NSView {
    /// The space a demo draws in, centred in the view.
    var designSize: CGSize { CGSize(width: 440, height: 260) }
    /// How long a loop runs before it starts again (0: plays once).
    var loopPeriod: TimeInterval { 0 }

    let canvas = CALayer()
    private var generation = 0
    private(set) var isPlaying = false
    /// Steps land at once, unanimated: Reduce Motion, or a test.
    private var instant = false
    nonisolated(unsafe) static var instantForTesting = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        canvas.isGeometryFlipped = true
        canvas.masksToBounds = false
        layer?.addSublayer(canvas)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { designSize }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        canvas.frame = CGRect(x: ((bounds.width - designSize.width) / 2).rounded(), y: ((bounds.height - designSize.height) / 2).rounded(),
                              width: designSize.width, height: designSize.height)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if isPlaying { play() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stop() }
    }

    // MARK: Playing

    /// Starts from the beginning.
    func play() {
        stop()
        isPlaying = true
        instant = DS.Motion.reduceMotion || Self.instantForTesting
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        canvas.sublayers?.forEach { $0.removeFromSuperlayer() }
        canvas.contentsScale = window?.backingScaleFactor ?? 2
        build()
        CATransaction.commit()
        script()
        let period = loopPeriod
        if period > 0, !instant {
            let current = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + period) { [weak self] in
                guard let self, self.generation == current, self.isPlaying else { return }
                DS.Motion.crossfade(self, duration: DS.Motion.presentDuration)
                self.play()
            }
        }
    }

    func stop() {
        generation += 1
        isPlaying = false
    }

    /// The scaffolding: what's there from the first frame.
    func build() {}
    /// The steps, each at its time.
    func script() {}

    /// Runs `step` `delay` seconds into the script, unless the demo has stopped or restarted.
    func at(_ delay: TimeInterval, _ step: @escaping @MainActor () -> Void) {
        if instant { step(); return }
        let current = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.generation == current else { return }
            step()
        }
    }

    // MARK: Drawing

    /// A token resolved in this view's appearance: a layer holds a CGColor, not a dynamic colour.
    func cg(_ color: NSColor) -> CGColor {
        var resolved = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { resolved = color.cgColor }
        return resolved
    }

    @discardableResult
    func box(_ frame: CGRect, _ color: NSColor, radius: CGFloat = 3, in parent: CALayer? = nil) -> CALayer {
        let layer = CALayer()
        layer.frame = frame
        layer.backgroundColor = cg(color)
        layer.cornerRadius = radius
        layer.cornerCurve = .continuous
        (parent ?? canvas).addSublayer(layer)
        return layer
    }

    @discardableResult
    func label(_ text: String, at origin: CGPoint, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor,
               monospaced: Bool = false, in parent: CALayer? = nil) -> CATextLayer {
        let font = monospaced ? DS.Text.code(size, weight: weight) : DS.Text.custom(size, weight: weight)
        let layer = CATextLayer()
        layer.string = text
        layer.font = font
        layer.fontSize = font.pointSize
        layer.foregroundColor = cg(color)
        layer.contentsScale = canvas.contentsScale
        let width = ceil((text as NSString).size(withAttributes: [.font: font]).width) + 2
        layer.frame = CGRect(x: origin.x, y: origin.y, width: width, height: ceil(font.ascender - font.descender + font.leading) + 1)
        (parent ?? canvas).addSublayer(layer)
        return layer
    }

    /// A template image (a stage glyph, a symbol) in `tint`; an agent's mark as it is.
    @discardableResult
    func image(_ image: NSImage, _ frame: CGRect, tint: NSColor? = nil, in parent: CALayer? = nil) -> CALayer {
        let layer = CALayer()
        layer.frame = frame
        layer.contentsGravity = .resizeAspect
        layer.contentsScale = canvas.contentsScale
        var drawn = image
        if let tint {
            let resolved = NSColor(cgColor: cg(tint)) ?? tint
            drawn = NSImage(size: image.size, flipped: false) { rect in
                image.draw(in: rect)
                resolved.set()
                rect.fill(using: .sourceAtop)
                return true
            }
        }
        layer.contents = drawn.layerContents(forContentsScale: canvas.contentsScale)
        (parent ?? canvas).addSublayer(layer)
        return layer
    }

    /// A line of code as the eye reads it from a distance: coloured runs, no letters.
    @discardableResult
    func codeLine(_ runs: [(CGFloat, NSColor)], at origin: CGPoint, height: CGFloat = 5, in parent: CALayer? = nil) -> [CALayer] {
        var x = origin.x
        return runs.map { width, color in
            defer { x += width + 4 }
            return box(CGRect(x: x, y: origin.y, width: width, height: height), color, radius: height / 2, in: parent)
        }
    }

    // MARK: Motion

    /// Arrives: a fade, with a short rise on the smooth spring.
    func reveal(_ layer: CALayer, rise: CGFloat = 8, scale: CGFloat = 1) {
        guard !instant else { layer.opacity = 1; return }
        layer.opacity = 1
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = DS.Motion.fadeDuration * 1.6
        fade.timingFunction = DS.Motion.fadeCurve
        let move = DS.Motion.spring(DS.Motion.smooth, keyPath: "transform")
        var from = CATransform3DMakeTranslation(0, rise, 0)
        if scale != 1 { from = CATransform3DScale(from, scale, scale, 1) }
        move.fromValue = from
        move.toValue = CATransform3DIdentity
        layer.add(fade, forKey: "revealFade")
        layer.add(move, forKey: "revealMove")
    }

    /// Hidden until revealed.
    func hidden<L: CALayer>(_ layer: L) -> L {
        layer.opacity = 0
        return layer
    }

    /// Grows from its leading edge, as text being typed or a bar filling.
    func grow(_ layer: CALayer, duration: TimeInterval = 0.35) {
        layer.opacity = 1
        guard !instant else { return }
        let frame = layer.frame
        layer.anchorPoint = CGPoint(x: 0, y: 0.5)
        layer.frame = frame
        let animation = CABasicAnimation(keyPath: "transform.scale.x")
        animation.fromValue = 0.001
        animation.toValue = 1
        animation.duration = duration
        animation.timingFunction = DS.Motion.easeOut
        layer.add(animation, forKey: "grow")
    }

    /// Fades out and away.
    func dismiss(_ layer: CALayer, drop: CGFloat = 0) {
        layer.opacity = 0
        guard !instant else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = DS.Motion.dismissDuration * 1.5
        fade.timingFunction = DS.Motion.fadeCurve
        layer.add(fade, forKey: "dismissFade")
        if drop != 0 {
            let move = CABasicAnimation(keyPath: "transform.translation.y")
            move.fromValue = 0
            move.toValue = drop
            move.duration = fade.duration
            move.timingFunction = DS.Motion.fadeCurve
            layer.add(move, forKey: "dismissMove")
        }
    }

    /// Fades in and out, until the loop ends: the editor's caret.
    func breathe(_ layer: CALayer) {
        guard !instant else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1
        animation.toValue = 0.35
        animation.duration = 0.9
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = DS.Motion.fadeCurve
        layer.add(animation, forKey: "breathe")
    }

    /// Working, as Side's own status dot shows it: the dot becomes a short arc turning steadily.
    func spin(_ dot: CALayer, color: NSColor) {
        dot.backgroundColor = nil
        let arc = CAShapeLayer()
        arc.frame = dot.bounds
        arc.path = CGPath(ellipseIn: dot.bounds.insetBy(dx: 0.75, dy: 0.75), transform: nil)
        arc.fillColor = nil
        arc.lineWidth = 1.5
        arc.lineCap = .round
        arc.strokeEnd = 0.72
        arc.strokeColor = cg(color)
        dot.addSublayer(arc)
        guard !instant else { return }
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        turn.toValue = -2 * CGFloat.pi
        turn.duration = 1.0
        turn.repeatCount = .infinity
        arc.add(turn, forKey: "turn")
    }

    /// Springs to a new position (its centre).
    func move(_ layer: CALayer, to position: CGPoint) {
        let from = layer.presentation()?.position ?? layer.position
        layer.position = position
        guard !instant else { return }
        let animation = DS.Motion.spring(DS.Motion.smooth, keyPath: "position")
        animation.fromValue = NSValue(point: from)
        animation.toValue = NSValue(point: position)
        layer.add(animation, forKey: "move")
    }

    /// Travels along an arc to `position`, as a thing handed from one place to another.
    func fly(_ layer: CALayer, to position: CGPoint, lift: CGFloat = 40, duration: TimeInterval = 0.7) {
        let from = layer.position
        layer.position = position
        guard !instant else { return }
        let path = CGMutablePath()
        path.move(to: from)
        path.addQuadCurve(to: position, control: CGPoint(x: (from.x + position.x) / 2, y: min(from.y, position.y) - lift))
        let animation = CAKeyframeAnimation(keyPath: "position")
        animation.path = path
        animation.duration = duration
        animation.timingFunction = DS.Motion.smooth.curve
        layer.add(animation, forKey: "fly")
    }

    /// Draws a path from start to end.
    func stroke(_ shape: CAShapeLayer, duration: TimeInterval = 0.6) {
        shape.strokeEnd = 1
        guard !instant else { return }
        let animation = CABasicAnimation(keyPath: "strokeEnd")
        animation.fromValue = 0
        animation.toValue = 1
        animation.duration = duration
        animation.timingFunction = DS.Motion.easeOut
        shape.add(animation, forKey: "stroke")
    }
}

// MARK: - The five stages, in a miniature Side

/// A miniature Side window: traffic lights, a content area that each stage's sketch fills, and
/// along the bottom the track pill and the stage bar, the selected stage's capsule springing
/// between them as the real bar's does. Branches isn't in the bar, as it isn't in Side's: it's
/// the track pill's, which lights up for it. `show(_:)` moves to a stage.
@MainActor
final class WelcomeStageShowcase: WelcomeDemo {
    enum Stage: Int, CaseIterable {
        case editor, agent, changes, terminal, branches
        var glyph: String { ["editor", "agent", "changes", "terminal", "branches"][rawValue] }
    }

    override var designSize: CGSize { CGSize(width: 460, height: 320) }
    private(set) var stage: Stage = .editor
    private let content = CALayer()
    private var capsule: CALayer?
    private var icons: [CALayer] = []
    private var pill: CALayer?
    private var stageGeneration = 0
    private static let contentFrame = CGRect(x: 14, y: 34, width: 432, height: 232)

    func show(_ stage: Stage) {
        let previous = self.stage
        self.stage = stage
        guard isPlaying else { return }
        guard previous != stage else { return }
        if let capsule, stage != .branches {
            if previous == .branches { reveal(capsule, rise: 0, scale: 0.8) }
            move(capsule, to: capsuleCenter(stage))
        } else if let capsule {
            dismiss(capsule)
        }
        if let pill {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            pill.backgroundColor = cg(stage == .branches ? DS.Color.selectedCapsule : DS.Color.overlay)
            CATransaction.commit()
            DS.Motion.crossfade(self, duration: DS.Motion.presentDuration)
        }
        for (index, icon) in icons.enumerated() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            icon.contents = Self.glyphImage(Stage(rawValue: index)!, selected: index == stage.rawValue, view: self).layerContents(forContentsScale: canvas.contentsScale)
            CATransaction.commit()
        }
        playStage()
    }

    private func capsuleCenter(_ stage: Stage) -> CGPoint {
        CGPoint(x: barFrame.minX + 6 + 20 + CGFloat(min(stage.rawValue, 3)) * 44, y: barFrame.midY)
    }

    /// The stages in the bar: all but Branches.
    private static let barStages: [Stage] = [.editor, .agent, .changes, .terminal]
    private static let pillWidth: CGFloat = 104
    /// The pill and the bar, centred together.
    private var barFrame: CGRect {
        let width: CGFloat = 188
        let left = (designSize.width - Self.pillWidth - 8 - width) / 2 + Self.pillWidth + 8
        return CGRect(x: left, y: designSize.height - 46, width: width, height: 34)
    }
    private var pillFrame: CGRect { CGRect(x: barFrame.minX - 8 - Self.pillWidth, y: barFrame.minY, width: Self.pillWidth, height: 34) }

    private static func glyphImage(_ stage: Stage, selected: Bool, view: WelcomeDemo) -> NSImage {
        let glyph = DS.Glyph.image(named: DS.Glyph.name(stage.glyph), selected: selected, pointSize: 15) ?? NSImage()
        let tint = NSColor(cgColor: view.cg(selected ? .labelColor : .secondaryLabelColor)) ?? .labelColor
        return NSImage(size: glyph.size, flipped: false) { rect in
            glyph.draw(in: rect)
            tint.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    override func build() {
        // The window: canvas tone, its own shadow, the content inset under the traffic lights.
        let window = box(CGRect(origin: .zero, size: designSize), DS.Color.canvas, radius: 14)
        window.shadowColor = cg(.shadowColor)
        window.shadowOpacity = 0.28
        window.shadowRadius = 18
        window.shadowOffset = CGSize(width: 0, height: 8)
        for (index, color) in [DS.Color.statusFailed, DS.Color.statusNeedsYou, DS.Color.statusVerified].enumerated() {
            box(CGRect(x: 14 + CGFloat(index) * 14, y: 12, width: 9, height: 9), color.withAlphaComponent(0.85), radius: 4.5)
        }
        content.frame = Self.contentFrame
        content.masksToBounds = true
        canvas.addSublayer(content)

        let trackPill = box(pillFrame, stage == .branches ? DS.Color.selectedCapsule : DS.Color.overlay, radius: pillFrame.height / 2)
        image(DS.Glyph.image(named: DS.Glyph.name("branches"), pointSize: 12) ?? NSImage(), CGRect(x: 12, y: 11, width: 12, height: 12), tint: .secondaryLabelColor, in: trackPill)
        label("fix-upload", at: CGPoint(x: 30, y: 9), size: 10.5, weight: .semibold, in: trackPill)
        pill = trackPill
        box(barFrame, DS.Color.overlay, radius: barFrame.height / 2)
        capsule = box(CGRect(x: 0, y: 0, width: 40, height: 26), DS.Color.selectedCapsule, radius: 13)
        capsule?.position = capsuleCenter(stage)
        if stage == .branches { capsule?.opacity = 0 }
        icons = Self.barStages.map { item in
            let center = capsuleCenter(item)
            return image(Self.glyphImage(item, selected: item == stage, view: self), CGRect(x: center.x - 8, y: center.y - 8, width: 16, height: 16))
        }
    }

    override func script() { playStage() }

    private func playStage() {
        stageGeneration += 1
        let current = stageGeneration
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.sublayers?.forEach { $0.removeFromSuperlayer() }
        CATransaction.commit()
        DS.Motion.crossfade(self, duration: DS.Motion.presentDuration)
        func step(_ delay: TimeInterval, _ block: @escaping @MainActor () -> Void) {
            at(delay) { [weak self] in
                guard let self, self.stageGeneration == current else { return }
                block()
            }
        }
        switch stage {
        case .editor: editor(step)
        case .agent: agent(step)
        case .changes: changes(step)
        case .terminal: terminal(step)
        case .branches: branches(step)
        }
    }

    typealias Step = (TimeInterval, @escaping @MainActor () -> Void) -> Void

    // MARK: Editor: a file being written

    private func editor(_ step: Step) {
        let side = box(CGRect(x: 0, y: 0, width: 112, height: 232), DS.Color.raised.withAlphaComponent(0.6), radius: 8, in: content)
        let files: [(String, NSColor)] = [("App.swift", DS.Color.FileType.swift), ("Upload.swift", DS.Color.FileType.swift),
                                          ("README.md", DS.Color.FileType.markdown), ("package.json", DS.Color.FileType.data), (".env", DS.Color.FileType.secret)]
        for (index, file) in files.enumerated() {
            let y = 12 + CGFloat(index) * 22
            if index == 1 { box(CGRect(x: 6, y: y - 4, width: 100, height: 20), DS.Color.selectedCapsule, radius: 6, in: side) }
            box(CGRect(x: 12, y: y + 2, width: 8, height: 8), file.1, radius: 2, in: side)
            label(file.0, at: CGPoint(x: 26, y: y - 1), size: 9.5, color: index == 1 ? .labelColor : .secondaryLabelColor, in: side)
        }
        let tab = box(CGRect(x: 124, y: 0, width: 92, height: 22), DS.Color.tabActive, radius: 7, in: content)
        label("Upload.swift", at: CGPoint(x: 10, y: 4), size: 9.5, weight: .medium, in: tab)
        let syntax = EditorThemes.syntax(dark: effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        func color(_ capture: String) -> NSColor {
            guard let rgba = syntax.color(for: capture) else { return .labelColor }
            return NSColor(srgbRed: CGFloat(rgba.x), green: CGFloat(rgba.y), blue: CGFloat(rgba.z), alpha: CGFloat(rgba.w))
        }
        let keyword = color("keyword"), type = color("type"), function = color("function"), string = color("string"), comment = color("comment")
        let plain = NSColor.tertiaryLabelColor
        let lines: [[(CGFloat, NSColor)]] = [
            [(70, comment), (46, comment)],
            [(30, keyword), (40, function), (14, plain), (36, type), (8, plain)],
            [(14, plain), (24, keyword), (30, plain), (8, plain), (52, string)],
            [(14, plain), (28, keyword), (38, function), (20, plain)],
            [(28, plain), (34, function), (10, plain), (44, string), (8, plain)],
            [(14, plain), (10, plain)],
            [(14, plain), (36, keyword), (20, plain), (24, type)],
            [(8, plain)],
        ]
        var y: CGFloat = 38
        var delay: TimeInterval = 0.25
        var last: [CALayer] = []
        for (index, runs) in lines.enumerated() {
            label("\(index + 1)", at: CGPoint(x: 126, y: y - 4), size: 8.5, color: .quaternaryLabelColor, monospaced: true, in: content)
            let indent: CGFloat = runs.first.map { $0.1 == plain && $0.0 <= 28 ? 0 : 0 } ?? 0
            let layers = codeLine(runs, at: CGPoint(x: 146 + indent, y: y), in: content).map(hidden)
            for (runIndex, layer) in layers.enumerated() {
                step(delay + Double(runIndex) * 0.07) { [weak self] in self?.grow(layer, duration: 0.16) }
            }
            delay += Double(layers.count) * 0.07 + 0.08
            last = layers
            y += 18
        }
        // The caret, after the last thing typed, blinking.
        let end = (last.last?.frame.maxX ?? 146) + 3
        let caret = hidden(box(CGRect(x: end, y: y - 18 - 3, width: 1.5, height: 11), DS.Color.accent, radius: 0.75, in: content))
        step(delay) { [weak self] in
            caret.opacity = 1
            self?.breathe(caret)
        }
    }

    // MARK: Agent: a conversation, with a diagram in the answer

    private func agent(_ step: Step) {
        let column = CGRect(x: 66, y: 8, width: 300, height: 224)
        let sent = hidden(box(CGRect(x: column.maxX - 168, y: column.minY, width: 168, height: 26), DS.Color.accent, radius: 13, in: content))
        label("Add a retry to the upload", at: CGPoint(x: 12, y: 6), size: 10, weight: .medium, color: .white, in: sent)
        let received = hidden(box(CGRect(x: column.minX, y: column.minY + 38, width: 236, height: 112), DS.Color.bubbleReceived, radius: 13, in: content))
        let lines = [CGFloat(190), 168, 120].enumerated().map { index, width in
            hidden(box(CGRect(x: 12, y: 12 + CGFloat(index) * 11, width: width, height: 5), .tertiaryLabelColor, radius: 2.5, in: received))
        }
        // A diagram in the answer: three boxes and the arrows between them.
        let nodes = ["upload", "retry", "done"].enumerated().map { index, name -> CALayer in
            let node = hidden(box(CGRect(x: 12 + CGFloat(index) * 74, y: 58, width: 58, height: 22), DS.Color.raised, radius: 6, in: received))
            let text = label(name, at: .zero, size: 9, weight: .medium, in: node)
            text.position = CGPoint(x: 29, y: 11)
            return node
        }
        let arrows = (0..<2).map { index -> CAShapeLayer in
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 70 + CGFloat(index) * 74, y: 69))
            path.addLine(to: CGPoint(x: 86 + CGFloat(index) * 74, y: 69))
            let shape = CAShapeLayer()
            shape.path = path
            shape.strokeColor = cg(.secondaryLabelColor)
            shape.lineWidth = 1.2
            shape.lineCap = .round
            shape.strokeEnd = 0
            received.addSublayer(shape)
            return shape
        }
        let check = hidden(label("✓ Tests pass", at: CGPoint(x: 12, y: 90), size: 9, weight: .medium, color: DS.Color.statusVerified, in: received))
        let composer = box(CGRect(x: column.minX - 20, y: 196, width: column.width + 40, height: 28), DS.Color.raised, radius: 14, in: content)
        label("Ask about this project…", at: CGPoint(x: 14, y: 7), size: 10, color: .tertiaryLabelColor, in: composer)
        box(CGRect(x: composer.bounds.width - 24, y: 4, width: 20, height: 20), DS.Color.accent, radius: 10, in: composer)

        step(0.2) { [weak self] in self?.reveal(sent, rise: 10) }
        step(0.8) { [weak self] in self?.reveal(received, rise: 10) }
        for (index, line) in lines.enumerated() { step(1.1 + Double(index) * 0.12) { [weak self] in self?.grow(line) } }
        for (index, node) in nodes.enumerated() {
            step(1.6 + Double(index) * 0.22) { [weak self] in self?.reveal(node, rise: 4, scale: 0.9) }
            if index < 2 { step(1.75 + Double(index) * 0.22) { [weak self] in self?.stroke(arrows[index], duration: 0.2) } }
        }
        step(2.4) { [weak self] in self?.reveal(check, rise: 4) }
    }

    // MARK: Changes: a diff, read and committed

    private func changes(_ step: Step) {
        let list = box(CGRect(x: 0, y: 0, width: 124, height: 232), DS.Color.raised.withAlphaComponent(0.6), radius: 8, in: content)
        for (index, file) in [("Upload.swift", "+18", "−4"), ("Retry.swift", "+42", ""), ("README.md", "+2", "−1")].enumerated() {
            let y = 12 + CGFloat(index) * 22
            if index == 0 { box(CGRect(x: 6, y: y - 4, width: 112, height: 20), DS.Color.selectedCapsule, radius: 6, in: list) }
            label(file.0, at: CGPoint(x: 12, y: y - 1), size: 9.5, color: index == 0 ? .labelColor : .secondaryLabelColor, in: list)
            label(file.1, at: CGPoint(x: 84, y: y - 1), size: 8.5, color: DS.Color.statusVerified, monospaced: true, in: list)
            if !file.2.isEmpty { label(file.2, at: CGPoint(x: 104, y: y - 1), size: 8.5, color: DS.Color.statusFailed, monospaced: true, in: list) }
        }
        let body = box(CGRect(x: 134, y: 0, width: 298, height: 232), DS.Color.raised, radius: 8, in: content)
        let rows: [(kind: Int, width: CGFloat)] = [(0, 150), (0, 120), (-1, 170), (-1, 90), (1, 200), (1, 160), (1, 120), (0, 140), (1, 180), (0, 100)]
        for (index, row) in rows.enumerated() {
            let y = 12 + CGFloat(index) * 18
            let tint: NSColor? = row.kind > 0 ? DS.Color.diffAdded : row.kind < 0 ? DS.Color.diffRemoved : nil
            let line = hidden(CALayer())
            line.frame = CGRect(x: 0, y: y - 4, width: 298, height: 16)
            if let tint { line.backgroundColor = cg(tint) }
            body.addSublayer(line)
            let mark = row.kind > 0 ? "+" : row.kind < 0 ? "−" : " "
            label(mark, at: CGPoint(x: 8, y: -1), size: 9, color: row.kind > 0 ? DS.Color.statusVerified : DS.Color.statusFailed, monospaced: true, in: line)
            box(CGRect(x: 24, y: 5, width: row.width, height: 5), row.kind == 0 ? NSColor.quaternaryLabelColor : .tertiaryLabelColor, radius: 2.5, in: line)
            step(0.2 + Double(index) * 0.09) { [weak self] in self?.reveal(line, rise: 4) }
        }
        let commit = hidden(box(CGRect(x: 216, y: 196, width: 70, height: 24), DS.Color.accent, radius: 12, in: body))
        let title = label("Commit", at: .zero, size: 10, weight: .semibold, color: .white, in: commit)
        title.position = CGPoint(x: 35, y: 12)
        step(1.5) { [weak self] in self?.reveal(commit, rise: 6, scale: 0.92) }
        let done = hidden(label("Committed to fix-upload", at: CGPoint(x: 16, y: 201), size: 9.5, color: .secondaryLabelColor, in: body))
        step(2.6) { [weak self] in
            self?.dismiss(commit)
            self?.reveal(done, rise: 4)
        }
    }

    // MARK: Terminal: an agent at work, in a tab that says so

    private func terminal(_ step: Step) {
        let tabs: [(NSImage, String)] = [(ProgramMarks.image(forProgram: "claude"), "Claude Code"), (ProgramMarks.image(forProgram: "zsh"), "zsh")]
        var tabBodies: [CALayer] = []
        for (index, tab) in tabs.enumerated() {
            let frame = CGRect(x: CGFloat(index) * 112, y: 0, width: 106, height: 22)
            let body = box(frame, index == 0 ? DS.Color.tabActive : .clear, radius: 7, in: content)
            image(tab.0, CGRect(x: 8, y: 5, width: 12, height: 12), tint: ProgramMarks.hasMark(index == 0 ? "claude" : nil) ? nil : .secondaryLabelColor, in: body)
            label(tab.1, at: CGPoint(x: 26, y: 4), size: 9.5, weight: index == 0 ? .medium : .regular, color: index == 0 ? .labelColor : .secondaryLabelColor, in: body)
            tabBodies.append(body)
        }
        let dot = box(CGRect(x: 92, y: 8, width: 6, height: 6), DS.Color.statusWorking, radius: 3, in: tabBodies[0])
        let pane = box(CGRect(x: 0, y: 30, width: 432, height: 202), DS.Color.raised, radius: 8, in: content)
        let output: [(String, NSColor)] = [
            ("> Add a retry to the upload", .labelColor),
            ("  Reading Upload.swift", .secondaryLabelColor),
            ("  Editing Upload.swift  +18 −4", .secondaryLabelColor),
            ("  Writing Retry.swift  +42", .secondaryLabelColor),
            ("  Running swift test", .secondaryLabelColor),
            ("  ✓ 128 tests passed", DS.Color.statusVerified),
        ]
        for (index, line) in output.enumerated() {
            let text = hidden(label(line.0, at: CGPoint(x: 12, y: 12 + CGFloat(index) * 17), size: 10, color: line.1, monospaced: true, in: pane))
            step(0.25 + Double(index) * 0.32) { [weak self] in self?.reveal(text, rise: 3) }
        }
        spin(dot, color: DS.Color.statusWorking)
        step(0.25 + Double(output.count) * 0.32) { [weak self] in
            dot.sublayers?.forEach { $0.removeFromSuperlayer() }
            dot.backgroundColor = self?.cg(DS.Color.statusVerified)
            self?.reveal(dot, rise: 0, scale: 0.4)
        }
    }

    // MARK: Branches: every branch, live

    private func branches(_ step: Step) {
        let rows: [(String, String, DS.StatusState?, String?)] = [
            ("fix-upload", "Claude Code · 2 terminals", .working, nil),
            ("new-onboarding", "Codex · waiting on you", .needsYou, nil),
            ("faster-search", "+212 −40 · 3 commits", nil, "PR #42"),
            ("main", "up to date", nil, nil),
        ]
        for (index, row) in rows.enumerated() {
            let frame = CGRect(x: 0, y: CGFloat(index) * 52, width: 432, height: 44)
            let card = hidden(box(frame, DS.Color.raised, radius: 10, in: content))
            let color: NSColor
            switch row.2 {
            case .working?: color = DS.Color.statusWorking
            case .needsYou?: color = DS.Color.statusNeedsYou
            default: color = DS.Color.statusIdle
            }
            let dot = box(CGRect(x: 14, y: 19, width: 7, height: 7), color, radius: 3.5, in: card)
            image(DS.Glyph.image(named: DS.Glyph.name("branches"), pointSize: 12) ?? NSImage(), CGRect(x: 30, y: 9, width: 12, height: 12), tint: .secondaryLabelColor, in: card)
            label(row.0, at: CGPoint(x: 48, y: 6), size: 11, weight: .semibold, in: card)
            label(row.1, at: CGPoint(x: 30, y: 24), size: 9.5, color: .secondaryLabelColor, in: card)
            if let pill = row.3 {
                let badge = hidden(box(CGRect(x: 360, y: 13, width: 56, height: 18), DS.Color.statusVerified.withAlphaComponent(0.16), radius: 9, in: card))
                let text = label(pill, at: .zero, size: 9, weight: .semibold, color: DS.Color.statusVerified, in: badge)
                text.position = CGPoint(x: 28, y: 9)
                step(1.3) { [weak self] in self?.reveal(badge, rise: 0, scale: 0.8) }
            }
            step(0.15 + Double(index) * 0.13) { [weak self] in
                self?.reveal(card, rise: 10)
                // As the app shows them: working turns, waiting on you is a still dot.
                if row.2 == .working { self?.spin(dot, color: color) }
            }
        }
    }
}

// MARK: - Three ideas

/// Every branch is a track: a line, and branches drawn off it, each one named as it appears.
@MainActor
final class WelcomeBranchesDemo: WelcomeDemo {
    override var designSize: CGSize { CGSize(width: 220, height: 150) }
    override var loopPeriod: TimeInterval { 6 }

    override func script() {
        let trunk = path([CGPoint(x: 14, y: 110), CGPoint(x: 206, y: 110)], color: .tertiaryLabelColor)
        stroke(trunk, duration: 0.5)
        let branches: [(CGFloat, CGFloat, String, NSColor)] = [(40, 46, "fix-upload", DS.Color.accent), (100, 74, "faster-search", DS.Color.statusVerified)]
        for (index, branch) in branches.enumerated() {
            let start = CGPoint(x: branch.0, y: 110)
            let line = CGMutablePath()
            line.move(to: start)
            line.addCurve(to: CGPoint(x: branch.0 + 36, y: branch.1), control1: CGPoint(x: branch.0 + 18, y: 110), control2: CGPoint(x: branch.0 + 18, y: branch.1))
            line.addLine(to: CGPoint(x: 206, y: branch.1))
            let shape = shapeLayer(line, color: branch.3)
            let tip = hidden(box(CGRect(x: 0, y: 0, width: 8, height: 8), branch.3, radius: 4))
            tip.position = CGPoint(x: 206 - 30, y: branch.1)
            let tag = hidden(box(CGRect(x: branch.0 + 44, y: branch.1 - 22, width: 0, height: 16), DS.Color.raised, radius: 8))
            let text = label(branch.2, at: CGPoint(x: 8, y: 2), size: 9, weight: .medium, in: tag)
            tag.frame.size.width = text.frame.width + 16
            at(0.5 + Double(index) * 0.9) { [weak self] in self?.stroke(shape, duration: 0.6) }
            at(1.0 + Double(index) * 0.9) { [weak self] in
                self?.reveal(tip, rise: 0, scale: 0.4)
                self?.reveal(tag, rise: 4)
            }
        }
    }

    private func path(_ points: [CGPoint], color: NSColor) -> CAShapeLayer {
        let line = CGMutablePath()
        line.addLines(between: points)
        return shapeLayer(line, color: color)
    }

    private func shapeLayer(_ path: CGPath, color: NSColor) -> CAShapeLayer {
        let shape = CAShapeLayer()
        shape.path = path
        shape.strokeColor = cg(color)
        shape.fillColor = nil
        shape.lineWidth = 2
        shape.lineCap = .round
        shape.strokeEnd = 0
        canvas.addSublayer(shape)
        return shape
    }
}

/// Terminals keep running: the window goes, the terminal in it carries on, and it's there when
/// the window comes back.
@MainActor
final class WelcomeKeepsRunningDemo: WelcomeDemo {
    override var designSize: CGSize { CGSize(width: 220, height: 150) }
    override var loopPeriod: TimeInterval { 6.5 }

    override func script() {
        let window = box(CGRect(x: 20, y: 12, width: 180, height: 126), DS.Color.overlay, radius: 10)
        for index in 0..<3 { box(CGRect(x: 8 + CGFloat(index) * 9, y: 7, width: 5, height: 5), .tertiaryLabelColor, radius: 2.5, in: window) }
        let terminal = box(CGRect(x: 34, y: 34, width: 152, height: 92), DS.Color.raised, radius: 7)
        var lines: [CALayer] = []
        for index in 0..<5 {
            let line = hidden(box(CGRect(x: 10, y: 12 + CGFloat(index) * 14, width: [90, 120, 70, 104, 60][index], height: 5), .tertiaryLabelColor, radius: 2.5, in: terminal))
            lines.append(line)
        }
        let dot = box(CGRect(x: 136, y: 8, width: 7, height: 7), DS.Color.statusWorking, radius: 3.5, in: terminal)
        spin(dot, color: DS.Color.statusWorking)
        let caption = hidden(label("Side quit · still running", at: CGPoint(x: 0, y: 132), size: 9, color: .secondaryLabelColor))
        caption.position.x = designSize.width / 2
        for index in 0..<2 { at(0.2 + Double(index) * 0.35) { [weak self] in self?.grow(lines[index]) } }
        at(1.2) { [weak self] in
            self?.dismiss(window)
            self?.reveal(caption, rise: 4)
        }
        for index in 2..<4 { at(1.7 + Double(index - 2) * 0.6) { [weak self] in self?.grow(lines[index]) } }
        at(3.6) { [weak self] in
            self?.reveal(window, rise: 0, scale: 0.96)
            self?.dismiss(caption)
            // The window came back behind its terminal, not over it.
            window.zPosition = -1
        }
        at(4.0) { [weak self] in self?.grow(lines[4]) }
    }
}

/// Agent and Terminal share a chat: a Claude Code conversation in a terminal opens in Agent as
/// the same conversation.
@MainActor
final class WelcomeSharedChatDemo: WelcomeDemo {
    override var designSize: CGSize { CGSize(width: 220, height: 150) }
    override var loopPeriod: TimeInterval { 6 }

    override func script() {
        let terminal = box(CGRect(x: 8, y: 16, width: 96, height: 118), DS.Color.raised, radius: 8)
        image(ProgramMarks.image(forProgram: "claude"), CGRect(x: 8, y: 7, width: 10, height: 10), in: terminal)
        label("Terminal", at: CGPoint(x: 22, y: 5), size: 8.5, weight: .medium, color: .secondaryLabelColor, in: terminal)
        let agent = box(CGRect(x: 116, y: 16, width: 96, height: 118), DS.Color.raised, radius: 8)
        image(DS.Glyph.image(named: DS.Glyph.name("agent"), pointSize: 10) ?? NSImage(), CGRect(x: 8, y: 7, width: 10, height: 10), tint: .secondaryLabelColor, in: agent)
        label("Agent", at: CGPoint(x: 22, y: 5), size: 8.5, weight: .medium, color: .secondaryLabelColor, in: agent)

        let lines = (0..<4).map { index in
            hidden(box(CGRect(x: 8, y: 28 + CGFloat(index) * 13, width: [64, 76, 52, 70][index], height: 5), index == 0 ? .secondaryLabelColor : .tertiaryLabelColor, radius: 2.5, in: terminal))
        }
        for (index, line) in lines.enumerated() { at(0.2 + Double(index) * 0.25) { [weak self] in self?.grow(line) } }
        // The conversation, lifted out and carried across.
        let token = hidden(box(CGRect(x: 0, y: 0, width: 58, height: 18), DS.Color.accent, radius: 9))
        token.position = CGPoint(x: 56, y: 74)
        at(1.5) { [weak self] in self?.reveal(token, rise: 0, scale: 0.7) }
        at(1.9) { [weak self] in self?.fly(token, to: CGPoint(x: 180, y: 51), lift: 18) }
        let sent = hidden(box(CGRect(x: 40, y: 28, width: 48, height: 14), DS.Color.accent, radius: 7, in: agent))
        let received = hidden(box(CGRect(x: 8, y: 48, width: 64, height: 30), DS.Color.bubbleReceived, radius: 9, in: agent))
        at(2.6) { [weak self] in
            self?.dismiss(token)
            self?.reveal(sent, rise: 4)
        }
        at(3.0) { [weak self] in self?.reveal(received, rise: 4) }
        let reply = hidden(box(CGRect(x: 32, y: 86, width: 56, height: 14), DS.Color.accent, radius: 7, in: agent))
        at(3.7) { [weak self] in self?.reveal(reply, rise: 4) }
    }
}
