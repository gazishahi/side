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

        // MARK: Text and editor surfaces
        //
        // The charter named these as tokens; in practice Make, the ruler, and the highlighter
        // each carried their own `NSColor(white:)` literals — which is how the editor's body
        // text and the file tree's ended up a shade apart. One definition each, here.

        /// Editor body text and any label that should read as primary content on a dark surface.
        static let text = NSColor(white: 0.85, alpha: 1)
        /// Emphasized text — the active tab's title, a highlighted completion row.
        static let textStrong = NSColor(white: 0.92, alpha: 1)
        /// Secondary content: directory names in the file tree.
        static let textSecondary = NSColor(white: 0.75, alpha: 1)
        /// Icons and de-emphasized labels.
        static let textMuted = NSColor(white: 0.55, alpha: 1)
        /// Line numbers and diff gutters — quieter than muted, because they repeat on every row.
        static let textFaint = NSColor(white: 0.42, alpha: 1)
        /// Syntax comments.
        static let comment = NSColor(white: 0.45, alpha: 1)
        /// White-on-dark scrims for hover, current-line, and bracket-match fills, by weight.
        static let scrimFaint = NSColor(white: 1, alpha: 0.045)
        static let scrimSoft = NSColor(white: 1, alpha: 0.05)
        static let scrimMedium = NSColor(white: 1, alpha: 0.15)
        static let scrimStrong = NSColor(white: 1, alpha: 0.16)

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

    /// The spacing scale the charter named and the code never had — insets, stack spacing, and
    /// gaps were 57 separate literals, which is why no two stages' padding quite matched.
    /// A 4pt base, since every existing value was already a multiple or half-step of it.
    enum Spacing {
        /// Hairline gaps: between a label and its own badge.
        static let xxs: CGFloat = 2
        /// Within a compound control — icon to its text.
        static let xs: CGFloat = 4
        /// Between tightly related rows (a title over its subtitle).
        static let s: CGFloat = 6
        /// The default gap between sibling controls in a row.
        static let m: CGFloat = 8
        /// Between distinct rows in a stack.
        static let l: CGFloat = 10
        /// Card padding and stage-content insets.
        static let xl: CGFloat = 12
        /// Stage edge margins.
        static let xxl: CGFloat = 14
        /// Between sections that should read as separate.
        static let section: CGFloat = 20
    }

    enum Radius {
        static let chip: CGFloat = 4
        static let control: CGFloat = 6
        static let card: CGFloat = 10
        static let bubble: CGFloat = 17
    }

    /// Text sizes as named roles rather than magic numbers, all scaled by one user-controlled
    /// factor.
    ///
    /// The app was built on ~60 hardcoded `NSFont.systemFont(ofSize:)` calls, which means someone
    /// who needs larger text has no recourse at all: macOS has no app-wide Dynamic Type to fall
    /// back on the way iOS does, so "use the system setting" isn't an answer here. The scale below
    /// is the answer, and these roles are what makes it apply everywhere at once instead of
    /// requiring 60 edits per adjustment.
    ///
    /// Sizes are the ones already in use, named — deliberately not a redesign. `scale` multiplies
    /// them; `Scale.standard` is 1.0, so the default build renders identically to before.
    enum Text {
        /// Multiplier applied to every role below. Persisted, app-wide, and the only knob.
        enum Scale: Double, CaseIterable {
            case compact = 0.9
            case standard = 1.0
            case large = 1.15
            case larger = 1.3

            private static let defaultsKey = "SideTextScale"

            var displayName: String {
                switch self {
                case .compact: return "Compact"
                case .standard: return "Default"
                case .large: return "Large"
                case .larger: return "Larger"
                }
            }

            static var current: Scale {
                get {
                    let stored = UserDefaults.standard.double(forKey: defaultsKey)
                    return Scale(rawValue: stored) ?? .standard
                }
                set {
                    guard newValue != current else { return }
                    UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
                    NotificationCenter.default.post(name: Text.scaleDidChangeNotification, object: nil)
                }
            }
        }

        /// Views that cache fonts (or set them once at build time) listen for this and restyle.
        /// A text-size change that only applied to windows opened afterwards would be the kind of
        /// half-measure that makes the setting untrustworthy.
        static let scaleDidChangeNotification = Notification.Name("SideTextScaleDidChange")

        private static func scaled(_ size: CGFloat) -> CGFloat {
            (size * Scale.current.rawValue).rounded(.toNearestOrEven)
        }

        // MARK: Roles

        /// The one-per-screen empty-state line ("No file open").
        static func display(_ weight: NSFont.Weight = .medium) -> NSFont { .systemFont(ofSize: scaled(25), weight: weight) }
        /// Supporting line under a display headline.
        static func subtitle(_ weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: scaled(14), weight: weight) }
        /// Stage headings — Review's track name, Tracks' title.
        static func title(_ weight: NSFont.Weight = .semibold) -> NSFont { .systemFont(ofSize: scaled(17), weight: weight) }
        /// Section headings inside a stage, and Preferences pane titles.
        static func heading(_ weight: NSFont.Weight = .semibold) -> NSFont { .systemFont(ofSize: scaled(13), weight: weight) }
        /// Default running text: Think bubbles, explainers, list rows.
        static func body(_ weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: scaled(12.5), weight: weight) }
        /// Controls and dense rows where body would crowd — table cells, popup labels.
        static func control(_ weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: scaled(12), weight: weight) }
        /// Secondary/supporting text: captions, status lines, hints.
        static func caption(_ weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: scaled(11), weight: weight) }
        /// The smallest thing allowed to carry meaning — badges, column headers.
        static func micro(_ weight: NSFont.Weight = .medium) -> NSFont { .systemFont(ofSize: scaled(10.5), weight: weight) }
        /// One big number — the Usage pane's figures.
        static func figure(_ weight: NSFont.Weight = .semibold) -> NSFont { .systemFont(ofSize: scaled(20), weight: weight) }
        /// Code, diffs, terminal-adjacent text, and anything that must stay column-aligned.
        static func code(_ size: CGFloat = 12, weight: NSFont.Weight = .regular) -> NSFont {
            .monospacedSystemFont(ofSize: scaled(size), weight: weight)
        }
    }

    /// A Liquid Glass backdrop, with a graceful fallback.
    ///
    /// `NSGlassEffectView` is macOS 26 API and the deployment target is 15, so it's
    /// availability-gated; older systems get an `NSVisualEffectView` — same shape, less
    /// refraction. Returned as a plain `NSView` to be inserted as the *backmost* subview of
    /// whatever it backs: content stays as ordinary siblings above it, which works identically
    /// for both variants.
    static func makeGlass(cornerRadius: CGFloat) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            // The material renders *around a contentView* — an empty glass view draws nothing,
            // which showed up as a transparent composer with unblurred bubbles behind it.
            let content = NSView()
            content.translatesAutoresizingMaskIntoConstraints = false
            glass.contentView = content
            glass.translatesAutoresizingMaskIntoConstraints = false
            return glass
        }
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = cornerRadius
        effect.layer?.masksToBounds = true
        effect.translatesAutoresizingMaskIntoConstraints = false
        return effect
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

    /// Fills the circle with a smooth vertical gradient of one color — lighter at the top,
    /// gently deeper at the bottom — so a colored button reads as a lit surface rather than a
    /// flat disc. Drawn in draw(_:) *under* the symbol; a gradient sublayer would render over
    /// the view's own contents and hide the icon. Replaces `backgroundColor` where used.
    func setGradientFill(_ color: NSColor) {
        gradientFillColor = color
        restingBackground = nil
        layer?.backgroundColor = nil
        needsDisplay = true
    }
    private var gradientFillColor: NSColor?

    /// Optional hover fill (the tab close button's gray circle); nil means no hover change.
    var hoverBackgroundColor: NSColor? {
        didSet { hoverColor = hoverBackgroundColor }
    }

    override func draw(_ dirtyRect: NSRect) {
        if let fill = gradientFillColor {
            let gradient = NSGradient(colorsAndLocations:
                (fill.blended(withFraction: 0.42, of: .white) ?? fill, 1),
                (fill, 0.45),
                (fill.blended(withFraction: 0.28, of: .black) ?? fill, 0)
            )
            gradient?.draw(in: NSBezierPath(ovalIn: bounds), angle: 90)
        }
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

/// The container for a tab strip. Exists as a subclass purely for accessibility: the chips live
/// inside an overflow `NSScrollView`, which does not surface arbitrary custom document-view
/// descendants to the AX tree, and the `setAccessibility*` setters on a plain `NSView` are
/// unreliable for a view AppKit otherwise treats as a non-element pass-through. Overriding the
/// methods works; setting the properties did not.
final class TabStripView: NSView {
    /// The chips to publish, in visual order. Set on every strip rebuild.
    var accessibleTabs: [NSView] = []
    var accessibilityGroupLabel: String = "Tabs"

    override func isAccessibilityElement() -> Bool { !accessibleTabs.isEmpty }
    override func accessibilityRole() -> NSAccessibility.Role? { .tabGroup }
    override func accessibilityLabel() -> String? { accessibilityGroupLabel }
    override func accessibilityChildren() -> [Any]? { accessibleTabs }
    /// AppKit asks for these separately from `accessibilityChildren` for a tab group.
    override func accessibilityTabs() -> [Any]? { accessibleTabs }
}
