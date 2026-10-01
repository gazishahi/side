import AppKit
import Heron

/// The design charter's token layer (`SIDE_DESIGN.md`, next to the constitution) — the single
/// source of truth for color, radius, and motion. Before this existed, three separately-authored
/// palettes (Tracks', Review's, and Heron's proposal-card grays) had already drifted apart; every
/// surface now points here, and a new visual primitive gets added to the charter first, then here,
/// then used.
enum DS {
    enum Color {
        /// Every token resolves per appearance. Dark values are the ones Side shipped with; light
        /// values keep the same relationships with the contrast direction reversed.
        static func dynamic(dark: CGFloat, light: CGFloat) -> NSColor {
            dynamic(dark: NSColor(white: dark, alpha: 1), light: NSColor(white: light, alpha: 1))
        }

        static func dynamic(dark: NSColor, light: NSColor) -> NSColor {
            NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            }
        }

        private static func hex(_ dark: UInt32, _ light: UInt32) -> NSColor {
            func color(_ value: UInt32) -> NSColor {
                NSColor(red: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255, blue: CGFloat(value & 0xff) / 255, alpha: 1)
            }
            return dynamic(dark: color(dark), light: color(light))
        }

        // MARK: Surfaces — three tones, no borders (Direction 02 §2.1)
        //
        // Hierarchy comes from tone, weight and position, not from lines. A `raised` tone *is* the
        // card; hairlines separate rows and never enclose them. The old six-step ladder
        // (chrome, tabStrip, bg1–bg4) drew every level with a border because the steps were too
        // close to read on their own.

        /// Stage background.
        static let canvas = hex(0x15171A, 0xF4F4F6)
        /// Cards, the pinned group, the terminal, the diff body, the active tab.
        static let raised = hex(0x1C1F23, 0xFFFFFF)
        /// Selected segment, running chip, popover and menu bodies.
        static let overlay = hex(0x25292E, 0xE8E8EC)
        /// Think's received message bubble: the system chat grey in light, the raised tone in dark.
        static let bubbleReceived = hex(0x24272C, 0xE9E9EB)
        /// The selected segment of a control sitting on glass — the toolbar segmented look.
        /// On glass, light mode's glass is itself near-white — a white thumb vanished into it, so
        /// light mode selects with a tint of the label colour instead.
        static let selectedCapsule = dynamic(dark: NSColor(white: 1, alpha: 0.18), light: NSColor(white: 0, alpha: 0.09))
        /// The active tab: lifted off the canvas — white with a soft shadow in light, a brighter
        /// tone in dark. Inactive tabs sit on `scrimSoft`.
        static let tabActive = dynamic(dark: NSColor(white: 1, alpha: 0.13), light: NSColor(white: 1, alpha: 1))
        /// A tab's × on hover — stronger than the selected capsule it sits on.
        static let tabCloseHover = dynamic(dark: NSColor(white: 1, alpha: 0.32), light: NSColor(white: 0, alpha: 0.14))
        /// The overlay scroll thumb Side draws itself where there is no NSScrollView (Run's
        /// terminal) — the system overlay knob's contrast in each appearance.
        static let scrollKnob = dynamic(dark: NSColor(white: 1, alpha: 0.45), light: NSColor(white: 0, alpha: 0.4))
        /// Row separators — only. Never an enclosure.
        static let hairline = dynamic(dark: NSColor(white: 1, alpha: 0.08), light: NSColor(white: 0, alpha: 0.08))
        /// The stacked-track connector.
        static let hairlineStrong = dynamic(dark: NSColor(white: 1, alpha: 0.13), light: NSColor(white: 0, alpha: 0.14))

        // MARK: Text
        //
        // System label colours only — `labelColor`, `secondaryLabelColor`, `tertiaryLabelColor`,
        // `quaternaryLabelColor`. They are already adaptive, and a hand-mixed gray for text is how
        // the editor's body text and the file tree's ended up a shade apart. The one exception is
        // syntax, which is a colour scheme, not a text role.
        static let syntaxComment = dynamic(dark: 0.45, light: 0.50)

        // MARK: Status — dot + text, never a filled pill (§2.4)
        //
        // Meaning is carried by text and shape; colour is reinforcement, so it survives any accent
        // colour, colour-blindness, and both appearances. Never `controlAccentColor` — an orange
        // accent would collide with needs-you.
        static let statusNeedsYou = hex(0xD9A441, 0xB8860B)
        /// Built per appearance, not `labelColor.withAlphaComponent(_:)`: that resolves the system
        /// colour once, at launch, so a dot drawn in dark mode came out black.
        static let statusWorking = dynamic(dark: NSColor(white: 1, alpha: 0.6), light: NSColor(white: 0, alpha: 0.6))
        static let statusVerified = hex(0x5FBF7A, 0x2E8B57)
        static let statusFailed = hex(0xE0655C, 0xC9433A)
        static let statusIdle = NSColor.quaternaryLabelColor

        /// Full-row diff tints. No gutter bars, no `+`/`−` fills.
        static let diffAdded = dynamic(dark: NSColor(red: 95/255, green: 191/255, blue: 122/255, alpha: 0.11), light: NSColor(red: 46/255, green: 139/255, blue: 87/255, alpha: 0.10))
        static let diffRemoved = dynamic(dark: NSColor(red: 224/255, green: 101/255, blue: 92/255, alpha: 0.11), light: NSColor(red: 201/255, green: 67/255, blue: 58/255, alpha: 0.09))

        /// Scrims for hover, current-line, and bracket-match fills, by weight — fills, not text.
        static let scrimFaint = dynamic(dark: NSColor(white: 1, alpha: 0.045), light: NSColor(white: 0, alpha: 0.05))
        static let scrimSoft = dynamic(dark: NSColor(white: 1, alpha: 0.05), light: NSColor(white: 0, alpha: 0.06))
        static let scrimMedium = dynamic(dark: NSColor(white: 1, alpha: 0.15), light: NSColor(white: 0, alpha: 0.1))
        static let scrimStrong = dynamic(dark: NSColor(white: 1, alpha: 0.16), light: NSColor(white: 0, alpha: 0.12))

        /// A track's lifecycle status, on the status scale: waiting is the one that needs a human.
        static func status(for status: TrackStatus) -> NSColor {
            switch status {
            case .active: return statusWorking
            case .waiting: return statusNeedsYou
            case .reviewReady: return statusVerified
            case .parked, .completed, .archived: return statusIdle
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

    /// Two values (Direction 02 §2.5), plus the documented exception.
    enum Radius {
        /// Buttons, chips, segments, tabs, the status dot's container.
        static let control: CGFloat = 6
        /// Cards, the terminal, the diff body, popovers.
        static let surface: CGFloat = 10
        /// Think's message bubbles — the single exception, kept at 17.
        static let bubble: CGFloat = 17
        /// A true capsule: half its height. For glass pills whose height is fixed.
        static func capsule(height: CGFloat) -> CGFloat { height / 2 }
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

        /// The editor's and the terminal's own text sizes (§2.6) — their own settings, separate
        /// from the interface scale: someone who wants 16 pt code rarely wants 16 pt chrome.
        enum CodeSize {
            static let didChangeNotification = Notification.Name("SideCodeSizeDidChange")
            static let choices: [CGFloat] = [11, 12, 13, 14, 15, 16, 18, 20, 24]
            static let standard: CGFloat = 14
            private static let editorKey = "side.editor-text-size"
            private static let terminalKey = "side.terminal-text-size"

            static var editor: CGFloat {
                get { stored(editorKey) }
                set { store(newValue, editorKey) }
            }
            static var terminal: CGFloat {
                get { stored(terminalKey) }
                set { store(newValue, terminalKey) }
            }
            /// Under XCTest, a store of this process's own: test classes run in parallel
            /// processes, and a size one sets mid-test must reach neither the other nor the
            /// person's real setting.
            nonisolated(unsafe) static let defaults: UserDefaults = NSClassFromString("XCTestCase") == nil
                ? .standard : UserDefaults(suiteName: "side.tests.code-size.\(ProcessInfo.processInfo.processIdentifier)") ?? .standard
            private static func stored(_ key: String) -> CGFloat {
                let value = defaults.double(forKey: key)
                return value > 0 ? CGFloat(value) : standard
            }
            private static func store(_ value: CGFloat, _ key: String) {
                defaults.set(Double(value), forKey: key)
                NotificationCenter.default.post(name: didChangeNotification, object: nil)
            }
        }

        /// The typefaces people choose (Appearance): one each for the editor, the terminal and
        /// reading (the Markdown preview). Nil is Side's default for the role. A change posts
        /// `CodeSize.didChangeNotification`, which everything that renders these already follows.
        enum Fonts {
            enum Role: String, CaseIterable { case editor, terminal, reading }

            private static func key(_ role: Role) -> String { "side.font-family.\(role.rawValue)" }
            static func family(_ role: Role) -> String? {
                guard let name = CodeSize.defaults.string(forKey: key(role)), !name.isEmpty else { return nil }
                return name
            }
            static func setFamily(_ family: String?, for role: Role) {
                CodeSize.defaults.set(family, forKey: key(role))
                NotificationCenter.default.post(name: CodeSize.didChangeNotification, object: nil)
            }

            /// Installed families whose regular face is fixed-pitch: the choices for code.
            static func monospacedFamilies() -> [String] {
                let names = Set(NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? [])
                return NSFontManager.shared.availableFontFamilies.filter { family in
                    (NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []).contains { ($0.first as? String).map(names.contains) ?? false }
                }.filter { !$0.hasPrefix(".") }
            }
            static func allFamilies() -> [String] { NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") } }

            /// The role's font at a size: the chosen family if it's installed, else the default
            /// (SF Mono for code, the Meslo Nerd Font for the terminal when present, since themed
            /// prompts draw with its glyphs, and New York for reading).
            static func font(_ role: Role, size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
                if family(role) == "SF Pro" { return .systemFont(ofSize: size, weight: weight) }
                if let family = family(role),
                   let chosen = NSFontManager.shared.font(withFamily: family, traits: weight >= .semibold ? .boldFontMask : [], weight: 5, size: size) {
                    return chosen
                }
                switch role {
                case .editor: return .monospacedSystemFont(ofSize: size, weight: weight)
                case .terminal: return NSFont(name: "MesloLGS-NF-Regular", size: size) ?? .monospacedSystemFont(ofSize: size, weight: weight)
                case .reading: return serif(size, weight: weight)
                }
            }

            /// The system serif (New York).
            static func serif(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
                let base = NSFont.systemFont(ofSize: size, weight: weight)
                return base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } ?? base
            }
        }

        /// Make's editor font, at the editor size setting.
        static func editor(_ weight: NSFont.Weight = .regular) -> NSFont { Fonts.font(.editor, size: CodeSize.editor, weight: weight) }

        private static func scaled(_ size: CGFloat) -> CGFloat {
            (size * Scale.current.rawValue).rounded(.toNearestOrEven)
        }

        // MARK: Roles

        // Five roles (Direction 02 §2.6). Semibold is reserved for the subject of a row; nothing
        // below 15 is ever bold. The old nine (display, subtitle, control, micro, figure…) were
        // sizes named after where they happened to be used, which is how the same kind of text
        // ended up at three sizes on one screen.

        /// The stage header — the track's intent. 20 · semibold.
        static func title(_ weight: NSFont.Weight = .semibold) -> NSFont { .systemFont(ofSize: scaled(20), weight: weight) }
        /// A checkpoint title, a group title. 15 · semibold.
        static func heading(_ weight: NSFont.Weight = .semibold) -> NSFont { .systemFont(ofSize: scaled(15), weight: weight) }
        /// Row content and descriptions. 13.
        static func body(_ weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: scaled(13), weight: weight) }
        /// Timestamps and meta. 11. Section labels use this uppercase with +0.08 em tracking — the
        /// only uppercase on screen.
        static func caption(_ weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: scaled(11), weight: weight) }
        /// A one-off size that still has to scale — markdown headers, the Usage pane's columns.
        /// Not a role; the escape hatch that keeps `ofSize:` out of every other file.
        static func custom(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: scaled(size), weight: weight) }
        /// Attributes for an uppercase section label: caption, tertiary, tracked.
        static var sectionLabelAttributes: [NSAttributedString.Key: Any] {
            [.font: caption(), .foregroundColor: NSColor.tertiaryLabelColor, .kern: scaled(11) * 0.08]
        }
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
    /// Re-rounds a view made by `makeGlass` — for glass whose height changes with its context.
    static func setGlassCornerRadius(_ view: NSView, _ radius: CGFloat) {
        if #available(macOS 26.0, *), let glass = view as? NSGlassEffectView { glass.cornerRadius = radius; return }
        view.layer?.cornerRadius = radius
    }

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
        // `.hudWindow` is a dark-only material; in light it renders as a dark slab on a light page.
        effect.material = Appearance.isDark ? .hudWindow : .popover
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = cornerRadius
        effect.layer?.masksToBounds = true
        effect.translatesAutoresizingMaskIntoConstraints = false
        return effect
    }

    /// One curve, few uses (Direction 02 §2.8). Every animation in the app takes its timing from
    /// here, and every duration passes through `duration(_:)` so Reduce Motion is honoured in one
    /// place rather than forgotten in thirty.
    ///
    /// Decision 2026-09-04 (option B): two named exceptions run on this curve and this duration
    /// helper — Promote's single settle on release, and streaming bubble growth, which is feedback
    /// on live content rather than layout the user waits on. Nothing else is exempt.
    enum Motion {
        /// The system default spring, expressed as a timing curve for `NSAnimationContext`:
        /// response 0.30, damping 0.86 — the same feel macOS 26 uses for its own controls.
        static var curve: CAMediaTimingFunction { CAMediaTimingFunction(controlPoints: 0.2, 0.85, 0.25, 1.0) }

        /// `CASpringAnimation` for the same spring, when a layer animation needs one.
        static func spring(keyPath: String) -> CASpringAnimation {
            let animation = CASpringAnimation(keyPath: keyPath)
            let response = 0.30, damping = 0.86
            animation.mass = 1
            animation.stiffness = pow(2 * .pi / response, 2)
            animation.damping = 4 * .pi * damping / response
            animation.duration = animation.settlingDuration
            return animation
        }

        /// The Liquid Glass press: the control swells under the finger and springs back. Scales
        /// about the view's centre (AppKit layers scale about their origin).
        /// `amount` is how far it swells: search's circle takes the full 1.08; larger pieces
        /// (pills, chips) swell less, so the same gesture reads as the same feel at any size.
        static func press(_ view: NSView, down: Bool, amount: CGFloat = 1.08) {
            guard !reduceMotion, let layer = view.layer else { return }
            let scale: CGFloat = down ? amount : 1
            let cx = view.bounds.midX, cy = view.bounds.midY
            let target = CATransform3DConcat(CATransform3DConcat(CATransform3DMakeTranslation(-cx, -cy, 0), CATransform3DMakeScale(scale, scale, 1)), CATransform3DMakeTranslation(cx, cy, 0))
            let animation = spring(keyPath: "transform")
            animation.damping = down ? animation.damping : animation.damping * 0.55  // a little bounce on release
            animation.fromValue = layer.presentation()?.transform ?? layer.transform
            animation.toValue = target
            layer.transform = target
            layer.add(animation, forKey: "press")
        }

        /// The only place Reduce Motion is consulted. Zero means "just set the final state".
        static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

        static func duration(_ base: TimeInterval) -> TimeInterval { reduceMotion ? 0 : base }

        /// The standard arrival: rise, fade, slight scale — Think's bubbles set the reference
        /// feel, everything else that appears reuses it. Purely a layer animation over the
        /// view's settled Auto Layout position, so it can't fight layout.
        static func appear(_ view: NSView, distance: CGFloat = 16) {
            guard !reduceMotion else { return }
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
            group.duration = duration(0.3)
            group.timingFunction = curve
            layer.add(group, forKey: "dsAppear")
        }
    }
}

extension DS {
    /// The corner mask a behind-window `NSVisualEffectView` actually honours. Its layer's
    /// `cornerRadius` clips the view's subviews but not the material, which the window server
    /// composites itself — so in light mode a panel showed square white corners behind its
    /// rounded content (dark mode hid them).
    static func roundedMask(radius: CGFloat) -> NSImage {
        let size = NSSize(width: radius * 2 + 1, height: radius * 2 + 1)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
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
/// Which tab is active after one closes — shared by Make's files and Run's sessions.
///
/// Closing a tab you are *not* on leaves you where you are; closing the one you're on moves to
/// its right-hand neighbour, else its left, as Safari and Xcode do. Both stages used to take
/// `min(closedIndex, count − 1)` either way, so closing a background tab switched your file.
enum TabSelection {
    /// `active` and `closed` are indices before the close; the result indexes the tabs after it.
    static func indexAfterClosing(_ closed: Int, active: Int?, countBefore: Int) -> Int? {
        let remaining = countBefore - 1
        guard remaining > 0 else { return nil }
        guard let active else { return min(closed, remaining - 1) }
        if closed < active { return active - 1 }
        if closed > active { return active }
        return min(closed, remaining - 1)
    }
}

final class TabStripView: NSView {
    /// The chips to publish, in visual order. Set on every strip rebuild.
    var accessibleTabs: [NSView] = [] { didSet { glassTrack?.isHidden = accessibleTabs.isEmpty } }
    private var glassTrack: NSView?

    /// The strip's tabs sit in one Liquid Glass capsule — the same family as the bar's stage
    /// control, sized for the 38 pt row. It hugs the tabs and never grows past the strip.
    static let trackHeight: CGFloat = 30
    func installGlassTrack(behind scroll: NSScrollView, hugging stack: NSStackView) {
        let glass = DS.makeGlass(cornerRadius: Self.trackHeight / 2)
        glass.isHidden = true
        // Placed by hand in `layout()`, as wide as the tabs up to the strip's width. As a
        // constraint, its pull toward the tabs' full width either outranked the top row's edge
        // (the strip grew past the window and never scrolled) or lost to everything else.
        glass.translatesAutoresizingMaskIntoConstraints = true
        addSubview(glass, positioned: .below, relativeTo: scroll)
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 3, bottom: 0, right: 3)
        glassTrack = glass
        trackScroll = scroll
        trackStack = stack
        stack.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(tabsResized), name: NSView.frameDidChangeNotification, object: stack)
    }
    private weak var trackScroll: NSScrollView?
    private weak var trackStack: NSStackView?

    @objc private func tabsResized() { needsLayout = true }

    override func layout() {
        super.layout()
        guard let glass = glassTrack, let scroll = trackScroll, let stack = trackStack else { return }
        let width = min(stack.frame.width, scroll.frame.width)
        glass.frame = NSRect(x: scroll.frame.minX, y: (bounds.height - Self.trackHeight) / 2, width: width, height: Self.trackHeight)
        // The tabs are cut off at the track's round ends, not the scroll view's square ones: a
        // selected tab half scrolled out used to poke its pill past the curve.
        scroll.wantsLayer = true
        let mask = (scroll.layer?.mask as? CAShapeLayer) ?? CAShapeLayer()
        let track = convert(glass.frame, to: scroll)
        mask.frame = scroll.bounds
        mask.path = CGPath(roundedRect: track, cornerWidth: Self.trackHeight / 2, cornerHeight: Self.trackHeight / 2, transform: nil)
        scroll.layer?.mask = mask
    }
    var accessibilityGroupLabel: String = "Tabs"

    override func isAccessibilityElement() -> Bool { !accessibleTabs.isEmpty }
    override func accessibilityRole() -> NSAccessibility.Role? { .tabGroup }
    override func accessibilityLabel() -> String? { accessibilityGroupLabel }
    override func accessibilityChildren() -> [Any]? { accessibleTabs }
    /// AppKit asks for these separately from `accessibilityChildren` for a tab group.
    override func accessibilityTabs() -> [Any]? { accessibleTabs }
}


/// A view whose hover state follows the pointer even when the view moves, not the pointer.
@MainActor protocol PointerHoverSyncing: AnyObject {
    func syncHover(pointerInWindow: NSPoint)
}

/// The scroll view inside a tab strip. In the title-bar region AppKit works out which parts of
/// the window drag it before any view sees the event, and it treats a transparent scroll view
/// as draggable without looking inside it — so pressing on a tab and dragging moved the window
/// instead of the tab. Empty strip space still drags: the top row's own mouse handling does it.
final class TabStripScrollView: NSScrollView {
    override var mouseDownCanMoveWindow: Bool { false }

    /// After a scroll, each tab says whether the pointer is over it now: scrolling moves tabs
    /// under a pointer that stays still, and AppKit sends no exit for that, so a tab the pointer
    /// passed over stayed highlighted (2026-10-01, the owner).
    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        guard let window, let document = documentView else { return }
        let pointer = window.mouseLocationOutsideOfEventStream
        func visit(_ view: NSView) {
            if let tab = view as? PointerHoverSyncing { tab.syncHover(pointerInWindow: pointer) }
            view.subviews.forEach(visit)
        }
        visit(document)
    }

    /// A mouse wheel (or an up-and-down swipe) moves the strip sideways: it only scrolls one way,
    /// and a wheel has no sideways motion to give it.
    override func scrollWheel(with event: NSEvent) {
        guard abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX), let document = documentView else {
            super.scrollWheel(with: event)
            return
        }
        let limit = max(0, document.frame.width - contentView.bounds.width)
        guard limit > 0 else { return }
        let step = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 12
        var origin = contentView.bounds.origin
        origin.x = min(max(0, origin.x - step), limit)
        contentView.setBoundsOrigin(origin)
        reflectScrolledClipView(contentView)
    }
}

// MARK: - Appearance

extension DS {
    /// Light, dark, or follow the system — and the plumbing that makes a switch actually repaint.
    ///
    /// Dynamic `NSColor`s handle everything AppKit draws itself. `CALayer` colours do not: a layer
    /// holds a `CGColor`, resolved once at the moment `.cgColor` was read, so every card, tab bar,
    /// and chip that set `layer?.backgroundColor` at init would stay its old colour after the
    /// appearance changed. `bindLayerBackground`/`bindLayerBorder` record the *token* on the view
    /// and re-resolve it here when the effective appearance changes.
    enum Appearance {
        enum Preference: String, CaseIterable {
            case system, light, dark
            var displayName: String {
                switch self {
                case .system: return "Match System"
                case .light: return "Light"
                case .dark: return "Dark"
                }
            }
        }

        static let didChangeNotification = Notification.Name("SideAppearanceDidChange")
        private static let preferenceKey = "SideAppearancePreference"
        nonisolated(unsafe) private static var observation: NSKeyValueObservation?
        nonisolated(unsafe) private static var lastKnownIsDark: Bool?

        static var preference: Preference {
            get { UserDefaults.standard.string(forKey: preferenceKey).flatMap(Preference.init) ?? .system }
            set {
                UserDefaults.standard.set(newValue.rawValue, forKey: preferenceKey)
                apply()
            }
        }

        static var isDark: Bool {
            NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }

        /// Applies the stored preference to the application and starts watching for changes —
        /// both a preference change and the system flipping at sunset land in the same place.
        @MainActor
        static func bootstrap() {
            apply()
            guard observation == nil else { return }
            lastKnownIsDark = isDark
            observation = NSApp.observe(\.effectiveAppearance, options: [.new]) { _, _ in
                DispatchQueue.main.async { appearanceMayHaveChanged() }
            }
        }

        private static func apply() {
            switch preference {
            case .system: NSApp.appearance = nil
            case .light: NSApp.appearance = NSAppearance(named: .aqua)
            case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
            }
        }

        @MainActor
        private static func appearanceMayHaveChanged() {
            let dark = isDark
            guard dark != lastKnownIsDark else { return }
            lastKnownIsDark = dark
            LayerBindings.reapplyAll()
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    /// Weak registry of views whose layer colours came from a token.
    @MainActor
    enum LayerBindings {
        private static let views = NSHashTable<NSView>.weakObjects()

        static func register(_ view: NSView) { views.add(view) }

        static func reapplyAll() {
            for view in views.allObjects { view.reapplyBoundLayerColors() }
        }

        /// Test seam.
        static var count: Int { views.count }
    }
}

// Addresses only — never read or written — so the compiler's shared-mutable-state rule doesn't apply.
nonisolated(unsafe) private var boundBackgroundKey: UInt8 = 0
nonisolated(unsafe) private var boundBorderKey: UInt8 = 0

extension NSView {
    /// `layer?.backgroundColor = token.cgColor`, except it survives an appearance change.
    func bindLayerBackground(_ color: NSColor) {
        wantsLayer = true
        objc_setAssociatedObject(self, &boundBackgroundKey, color, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        DS.LayerBindings.register(self)
        layer?.backgroundColor = resolvedCGColor(color)
    }

    func bindLayerBorder(_ color: NSColor) {
        wantsLayer = true
        objc_setAssociatedObject(self, &boundBorderKey, color, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        DS.LayerBindings.register(self)
        layer?.borderColor = resolvedCGColor(color)
    }

    fileprivate func reapplyBoundLayerColors() {
        if let color = objc_getAssociatedObject(self, &boundBackgroundKey) as? NSColor { layer?.backgroundColor = resolvedCGColor(color) }
        if let color = objc_getAssociatedObject(self, &boundBorderKey) as? NSColor { layer?.borderColor = resolvedCGColor(color) }
    }

    /// Resolved against *this view's* effective appearance, which is what a view inside a window
    /// that has its own appearance override needs, and falls back to the app's before the view
    /// has a window.
    private func resolvedCGColor(_ color: NSColor) -> CGColor {
        var resolved = color.cgColor
        (window?.effectiveAppearance ?? NSApp.effectiveAppearance).performAsCurrentDrawingAppearance {
            resolved = color.cgColor
        }
        return resolved
    }
}


// MARK: - Status components (Direction 02 §2.4)

extension DS {
    /// The one vocabulary for "what state is this in", shared by every surface.
    enum StatusState: Equatable {
        /// `unread`: something new to look at (a terminal printed while you were elsewhere) — a
        /// quiet filled dot, never the breathing ring, which means an agent is working.
        case needsYou, working, verified, failed, idle, unread

        var name: String {
            switch self {
            case .needsYou: return "Needs you"
            case .working: return "Working"
            case .verified: return "Verified"
            case .failed: return "Failed"
            case .idle: return "Idle"
            case .unread: return "New output"
            }
        }

        var color: NSColor {
            switch self {
            case .needsYou: return Color.statusNeedsYou
            case .working: return Color.statusWorking
            case .verified: return Color.statusVerified
            case .failed: return Color.statusFailed
            case .idle: return Color.statusIdle
            case .unread: return Color.statusWorking
            }
        }

        /// A track's dot: the agent's activity wins while there is any; otherwise the lifecycle,
        /// where only "waiting" needs a human and only "review ready" is a green result.
        init(track status: TrackStatus, activity: AgentActivity) {
            switch activity {
            case .working: self = .working
            case .needsYou: self = .needsYou
            case .failed: self = .failed
            case .doneUnread: self = .verified
            case .none, .doneSeen:
                switch status {
                case .waiting: self = .needsYou
                case .reviewReady: self = .verified
                case .active, .parked, .completed, .archived: self = .idle
                }
            }
        }

        init(_ activity: AgentActivity) {
            switch activity {
            case .needsYou: self = .needsYou
            case .working: self = .working
            case .failed: self = .failed
            case .doneUnread: self = .verified
            case .none, .doneSeen: self = .idle
            }
        }
    }

    /// A 6 pt status dot. Filled for every state but Working, which is a hollow ring that
    /// breathes — the only animated indicator in the app. Exposed to accessibility as an image
    /// whose label is the state's name, so the colour is never the only carrier.
    final class StatusDot: NSView {
        var state: StatusState { didSet { if state != oldValue { apply() } } }
        private let diameter: CGFloat

        init(state: StatusState, diameter: CGFloat = 6) {
            self.state = state
            self.diameter = diameter
            super.init(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
            wantsLayer = true
            translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: diameter), heightAnchor.constraint(equalToConstant: diameter)])
            layer?.cornerRadius = diameter / 2
            setAccessibilityElement(true)
            setAccessibilityRole(.image)
            apply()
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        private func apply() {
            setAccessibilityLabel(state.name)
            layer?.removeAnimation(forKey: "breathe")
            if state == .working {
                layer?.backgroundColor = nil
                layer?.borderWidth = 1.5
                bindLayerBorder(state.color)
                guard !Motion.reduceMotion else { return }
                let breathe = CABasicAnimation(keyPath: "opacity")
                breathe.fromValue = 1
                breathe.toValue = 0.35
                breathe.duration = 1.0
                breathe.autoreverses = true
                breathe.repeatCount = .infinity
                breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                layer?.add(breathe, forKey: "breathe")
            } else {
                layer?.borderWidth = 0
                layer?.opacity = 1
                bindLayerBackground(state.color)
            }
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            apply()
        }
    }

    /// Dot plus 12 pt secondary text: `● Needs you`.
    /// An empty state (Direction 02 §6): one sentence and the one action that fixes it — never a
    /// paragraph of explainer. The action is the screen's primary, so it takes the accent.
    final class EmptyState: NSStackView {
        private let label = NSTextField(wrappingLabelWithString: "")
        private let button = NSButton(title: "", target: nil, action: nil)
        private var handler: (() -> Void)?

        init() {
            super.init(frame: .zero)
            orientation = .vertical
            alignment = .centerX
            spacing = Spacing.l
            translatesAutoresizingMaskIntoConstraints = false
            label.font = Text.body()
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            label.preferredMaxLayoutWidth = 420
            button.bezelStyle = .push
            button.bezelColor = .controlAccentColor
            button.target = self
            button.action = #selector(performAction)
            addArrangedSubview(label)
            addArrangedSubview(button)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func configure(_ text: String, action title: String?, handler: (() -> Void)?) {
            label.stringValue = text
            button.title = title ?? ""
            button.isHidden = title == nil
            self.handler = handler
        }

        @objc private func performAction() { handler?() }
    }

    final class StatusLabel: NSStackView {
        let dot: StatusDot
        let label = NSTextField(labelWithString: "")

        init(state: StatusState, text: String? = nil) {
            dot = StatusDot(state: state)
            super.init(frame: .zero)
            orientation = .horizontal
            alignment = .centerY
            spacing = Spacing.s
            translatesAutoresizingMaskIntoConstraints = false
            label.font = Text.custom(12)
            label.textColor = .secondaryLabelColor
            label.stringValue = text ?? state.name
            addArrangedSubview(dot)
            addArrangedSubview(label)
            setAccessibilityElement(true)
            setAccessibilityRole(.staticText)
            setAccessibilityLabel(text ?? state.name)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func set(state: StatusState, text: String? = nil) {
            dot.state = state
            label.stringValue = text ?? state.name
            setAccessibilityLabel(text ?? state.name)
        }
    }
}

/// What an empty state's one action does. The shell performs it — a stage can't open a project,
/// initialise git or start a track on its own.
enum EmptyStateAction {
    case openProject, initializeGit, newTrack, chooseTrack, setUpModel
}

