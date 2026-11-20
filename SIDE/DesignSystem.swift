import AppKit
import SideAgents

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

        /// With System Settings' Increase Contrast on, AppKit draws in a high-contrast appearance;
        /// these tokens take their own values there (2026-09-30 audit, UX-9: they ignored it, and
        /// canvas against raised was about 1.1:1, hairlines 8%).
        static func dynamic(dark: NSColor, light: NSColor, contrastDark: NSColor, contrastLight: NSColor) -> NSColor {
            NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                guard increaseContrast() else { return isDark ? dark : light }
                return isDark ? contrastDark : contrastLight
            }
        }

        /// System Settings › Accessibility › Display › Increase Contrast; a test sets its own.
        nonisolated(unsafe) static var increaseContrast: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }

        fileprivate static func rgb(_ value: UInt32) -> NSColor {
            NSColor(red: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255, blue: CGFloat(value & 0xff) / 255, alpha: 1)
        }

        private static func hex(_ dark: UInt32, _ light: UInt32) -> NSColor { dynamic(dark: rgb(dark), light: rgb(light)) }

        private static func hex(_ dark: UInt32, _ light: UInt32, contrast contrastDark: UInt32, _ contrastLight: UInt32) -> NSColor {
            dynamic(dark: rgb(dark), light: rgb(light), contrastDark: rgb(contrastDark), contrastLight: rgb(contrastLight))
        }

        private static func white(_ dark: CGFloat, black light: CGFloat, contrast contrastDark: CGFloat, _ contrastLight: CGFloat) -> NSColor {
            dynamic(dark: NSColor(white: 1, alpha: dark), light: NSColor(white: 0, alpha: light),
                    contrastDark: NSColor(white: 1, alpha: contrastDark), contrastLight: NSColor(white: 0, alpha: contrastLight))
        }

        // MARK: Surfaces — three tones, no borders (Direction 02 §2.1)
        //
        // Hierarchy comes from tone, weight and position, not from lines. A `raised` tone *is* the
        // card; hairlines separate rows and never enclose them. The old six-step ladder
        // (chrome, tabStrip, bg1–bg4) drew every level with a border because the steps were too
        // close to read on their own.

        /// Stage background.
        static let canvas = surface(.canvas, 0x15171A, 0xF4F4F6, contrast: 0x0B0C0E, 0xE6E6EB)
        /// Cards, the pinned group, the terminal, the diff body, the active tab.
        static let raised = surface(.raised, 0x1C1F23, 0xFFFFFF, contrast: 0x262A30, 0xFFFFFF)
        /// Selected segment, running chip, popover and menu bodies.
        static let overlay = surface(.overlay, 0x25292E, 0xE8E8EC, contrast: 0x363B42, 0xD6D6DD)
        /// Think's received message bubble: the system chat grey in light, the raised tone in dark.
        static let bubbleReceived = surface(.bubble, 0x24272C, 0xE9E9EB)

        /// The four surface tones taken from an editor theme's background (Settings › Appearance,
        /// Interface theme). Nil for an appearance keeps Side's own.
        struct SurfaceTint: Equatable {
            enum Tone { case canvas, raised, overlay, bubble }
            var canvas, raised, overlay, bubble: NSColor

            /// Side's relationships, kept: raised a step lighter than canvas in both appearances,
            /// overlay and the bubble a step away from it (lighter in dark, darker in light). A
            /// near-white light theme has nothing lighter to raise to, so its canvas steps down.
            init(background: NSColor, dark: Bool) {
                let base = background.usingColorSpace(.sRGB) ?? background
                func toward(_ target: NSColor, _ fraction: CGFloat) -> NSColor { base.blended(withFraction: fraction, of: target) ?? base }
                if dark {
                    canvas = base
                    raised = toward(.white, 0.035)
                    overlay = toward(.white, 0.075)
                    bubble = toward(.white, 0.065)
                } else {
                    let nearWhite = base.brightnessComponent > 0.97 && base.saturationComponent < 0.04
                    canvas = nearWhite ? toward(.black, 0.04) : base
                    raised = nearWhite ? base : toward(.white, 0.7)
                    overlay = toward(.black, nearWhite ? 0.09 : 0.06)
                    bubble = toward(.black, nearWhite ? 0.085 : 0.055)
                }
            }

            func color(_ tone: Tone) -> NSColor {
                switch tone {
                case .canvas: return canvas
                case .raised: return raised
                case .overlay: return overlay
                case .bubble: return bubble
                }
            }
        }

        /// Set by `DS.InterfaceTheme`; read wherever a surface token resolves.
        nonisolated(unsafe) static var surfaceTint: (dark: SurfaceTint?, light: SurfaceTint?) = (nil, nil)

        /// A surface tone: Side's own, the editor theme's under Interface theme, and Side's
        /// high-contrast values whenever Increase Contrast is on (a theme's tones don't promise it).
        private static func surface(_ tone: SurfaceTint.Tone, _ dark: UInt32, _ light: UInt32, contrast contrastDark: UInt32? = nil, _ contrastLight: UInt32? = nil) -> NSColor {
            NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                if increaseContrast(), let contrastDark, let contrastLight { return rgb(isDark ? contrastDark : contrastLight) }
                if let tint = isDark ? surfaceTint.dark : surfaceTint.light { return tint.color(tone) }
                return rgb(isDark ? dark : light)
            }
        }

        /// The accent (Settings › Appearance): the system's, Side's own, or a pick. Primary
        /// actions, sent messages, links and the caret; never status (see the status colours).
        static let accent = NSColor(name: nil) { appearance in
            Accent.resolved(dark: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        }
        /// The selected segment of a control sitting on glass — the toolbar segmented look.
        /// On glass, light mode's glass is itself near-white — a white thumb vanished into it, so
        /// light mode selects with a tint of the label colour instead.
        static let selectedCapsule = white(0.18, black: 0.09, contrast: 0.32, 0.2)
        /// Under the pointer on a control on glass, before it's chosen: half the selected one.
        static let hoverCapsule = white(0.09, black: 0.045, contrast: 0.16, 0.1)
        /// The active tab: lifted off the canvas — white with a soft shadow in light, a brighter
        /// tone in dark. Inactive tabs sit on `scrimSoft`.
        static let tabActive = dynamic(dark: NSColor(white: 1, alpha: 0.13), light: NSColor(white: 1, alpha: 1),
                                       contrastDark: NSColor(white: 1, alpha: 0.26), contrastLight: NSColor(white: 1, alpha: 1))
        /// A tab's × on hover — stronger than the selected capsule it sits on.
        static let tabCloseHover = dynamic(dark: NSColor(white: 1, alpha: 0.32), light: NSColor(white: 0, alpha: 0.14))
        /// The overlay scroll thumb Side draws itself where there is no NSScrollView (Run's
        /// terminal) — the system overlay knob's contrast in each appearance.
        static let scrollKnob = dynamic(dark: NSColor(white: 1, alpha: 0.45), light: NSColor(white: 0, alpha: 0.4))
        /// Row separators — only. Never an enclosure.
        static let hairline = white(0.08, black: 0.08, contrast: 0.45, 0.45)
        /// The stacked-track connector.
        static let hairlineStrong = white(0.13, black: 0.14, contrast: 0.6, 0.6)

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
        // colour, colour-blindness, and both appearances. Never the accent — an orange
        // accent would collide with needs-you.
        static let statusNeedsYou = hex(0xD9A441, 0xB8860B)
        /// Built per appearance, not `labelColor.withAlphaComponent(_:)`: that resolves the system
        /// colour once, at launch, so a dot drawn in dark mode came out black.
        static let statusWorking = dynamic(dark: NSColor(white: 1, alpha: 0.6), light: NSColor(white: 0, alpha: 0.6))
        static let statusVerified = hex(0x5FBF7A, 0x2E8B57)
        static let statusFailed = hex(0xE0655C, 0xC9433A)
        /// The update pill ready to restart into (SIDE_DESIGN_POLISH_0.5.md §4): Verified's green
        /// at 18% under words in a deeper green that reads at 4.5:1 or better on it.
        static let updateReadyFill = dynamic(dark: rgb(0x5FBF7A).withAlphaComponent(0.18), light: rgb(0x2E8B57).withAlphaComponent(0.18))
        static let updateReadyText = hex(0x7BD896, 0x17643A)
        static let statusIdle = NSColor.quaternaryLabelColor

        /// Full-row diff tints. No gutter bars, no `+`/`−` fills.
        static let diffAdded = dynamic(dark: NSColor(red: 95/255, green: 191/255, blue: 122/255, alpha: 0.11), light: NSColor(red: 46/255, green: 139/255, blue: 87/255, alpha: 0.10))
        static let diffRemoved = dynamic(dark: NSColor(red: 224/255, green: 101/255, blue: 92/255, alpha: 0.11), light: NSColor(red: 201/255, green: 67/255, blue: 58/255, alpha: 0.09))

        /// File-type icons (FileIcon in FileExplorer.swift): each language in its own colour,
        /// a shade deeper in light mode so pale ones (JavaScript's yellow) still read on white.
        enum FileType {
            static let swift = hex(0xF4704F, 0xE0482A)
            static let typescript = hex(0x5A9BE6, 0x2F6DB5)
            static let javascript = hex(0xE8CF4A, 0xA88A00)
            static let python = hex(0x5B9BD5, 0x2F6A9E)
            static let rust = hex(0xE0915F, 0xB35E2A)
            static let go = hex(0x3CC2E0, 0x0089AD)
            static let ruby = hex(0xE5544C, 0xBF2E26)
            static let java = hex(0xEE8A3A, 0xC2630F)
            static let kotlin = hex(0xA47BFF, 0x7048E0)
            static let csharp = hex(0xB872C2, 0x87478F)
            static let cFamily = hex(0x7E8FE0, 0x4A5CB8)
            static let php = hex(0x9A9DE0, 0x5F62A8)
            static let svelte = hex(0xFF6A3D, 0xDD3A0B)
            static let vue = hex(0x4FCB93, 0x23946A)
            static let astro = hex(0xFF8048, 0xD85314)
            static let html = hex(0xF07650, 0xCF4520)
            static let css = hex(0x9C7FE0, 0x6A47B8)
            static let sass = hex(0xE07AAE, 0xB54A82)
            static let data = hex(0xD9B444, 0x9C7C0E)
            static let config = hex(0x9AA3AF, 0x667080)
            static let markdown = hex(0x6FB4D6, 0x2F7FA8)
            static let tex = hex(0x7FBF6A, 0x3F7F2A)
            static let shell = hex(0x6CCB5F, 0x34922A)
            static let sheet = hex(0x4FBF7F, 0x1E7F4A)
            static let image = hex(0xB592E0, 0x7E57B5)
            static let media = hex(0xE08AB0, 0xB0517E)
            static let document = hex(0xE86A6A, 0xC23A3A)
            static let archive = hex(0xC9A574, 0x8F6B3A)
            static let git = hex(0xF07A5A, 0xD04A2A)
            static let secret = hex(0xE6C25A, 0xA6800E)
            static let folder = hex(0x7D9CCF, 0x5B7DB5)
            static let plain = NSColor.tertiaryLabelColor
        }

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
        /// The palette (⌘P, Find): the floating panel the nav morphs into.
        static let palette: CGFloat = 16
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
                    let stored = HeronDefaults.store.double(forKey: defaultsKey)
                    return Scale(rawValue: stored) ?? .standard
                }
                set {
                    let old = current
                    guard newValue != old else { return }
                    HeronDefaults.store.set(newValue.rawValue, forKey: defaultsKey)
                    NotificationCenter.default.post(name: Text.scaleDidChangeNotification, object: nil,
                                                    userInfo: ["old": old.rawValue, "new": newValue.rawValue])
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
            nonisolated(unsafe) static let defaults: UserDefaults = HeronDefaults.store
            private static func stored(_ key: String) -> CGFloat {
                let value = defaults.double(forKey: key)
                return value > 0 ? CGFloat(value) : standard
            }
            /// Zoom: the next size in `choices` up or down from `size` (one off the list joins it
            /// at the nearest step), holding at the ends.
            static func zoomed(_ size: CGFloat, by steps: Int) -> CGFloat {
                if steps > 0 { return choices.first { $0 > size } ?? choices.last ?? size }
                if steps < 0 { return choices.last { $0 < size } ?? choices.first ?? size }
                return size
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
        /// A file-type icon's letters (TS, PY): rounded and heavy, sized to the 16 pt icon rather
        /// than the interface scale.
        static func iconMonogram(_ size: CGFloat) -> NSFont {
            let base = NSFont.systemFont(ofSize: size, weight: .heavy)
            return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
        }

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
        /// A display title, for the few screens that introduce rather than work (the welcome):
        /// SF at display size, medium, set a little tight (the owner chose it, 2026-11-07; never a
        /// serif). Not a working role.
        static func display(_ size: CGFloat) -> NSFont { .systemFont(ofSize: scaled(size), weight: .medium) }
        /// Display type's tracking, as a fraction of its size.
        static let displayTracking: CGFloat = -0.028
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
        if let solid = view as? SolidSurface { solid.cornerRadius = radius; return }
        view.layer?.cornerRadius = radius
    }

    /// How Side's floating chrome is drawn (Settings › Appearance, 2026-11-06): Liquid Glass,
    /// the blurred material from before it, or solid surfaces, which blur nothing. Glass is made
    /// as views are, so the choice is read once, at launch: a change applies on restart.
    enum Surfaces: String, CaseIterable {
        case glass, vibrancy, solid

        static let key = "appearance.surfaces"
        nonisolated(unsafe) static var defaults: UserDefaults = .standard
        static let didChangeNotification = Notification.Name("SideSurfacesDidChange")

        /// What this launch draws. `SIDE_SURFACES` overrides it, for measuring one against another.
        static let current: Surfaces = {
            if let forced = ProcessInfo.processInfo.environment["SIDE_SURFACES"].flatMap(Surfaces.init(rawValue:)) { return forced }
            // A test launch draws the default, not the person's own choice.
            if AppDelegate.isUITesting { return .glass }
            return chosen
        }()

        /// What Settings has chosen, for the next launch.
        static var chosen: Surfaces {
            get { defaults.string(forKey: key).flatMap(Surfaces.init(rawValue:)) ?? .glass }
            set {
                defaults.set(newValue.rawValue, forKey: key)
                NotificationCenter.default.post(name: didChangeNotification, object: nil)
            }
        }

        /// Liquid Glass is drawn: chosen, and the system has it.
        static var usesGlass: Bool {
            if #available(macOS 26.0, *) { return current == .glass }
            return false
        }

        /// Floating pieces carry their own shadow: glass draws its own edge and depth.
        static var needsShadow: Bool { !usesGlass }
    }

    /// The accent's choices. Orange, yellow, red and green are left out: they're needs-you,
    /// failed and verified, and an accent that looks like a status would say one it doesn't mean.
    enum Accent: String, CaseIterable {
        case system, side, blue, purple, pink, teal, graphite

        static let key = "appearance.accent"
        nonisolated(unsafe) private static var cached: Accent?

        static var chosen: Accent {
            get {
                if let cached { return cached }
                let stored = HeronDefaults.store.string(forKey: key).flatMap(Accent.init(rawValue:)) ?? .system
                cached = stored
                return stored
            }
            set {
                HeronDefaults.store.set(newValue.rawValue, forKey: key)
                cached = newValue
                MainActor.assumeIsolated { Appearance.refreshAll() }
            }
        }

        var displayName: String {
            switch self {
            case .system: return "Match System"
            case .side: return "Side"
            default: return rawValue.capitalized
            }
        }

        /// This choice's colour, dark then light; nil for the system's.
        private var values: (dark: UInt32, light: UInt32)? {
            switch self {
            case .system: return nil
            case .side: return (0x7472F2, 0x5250D8)
            case .blue: return (0x3D8BF5, 0x1A6BE0)
            case .purple: return (0xA77BEA, 0x7E46CF)
            case .pink: return (0xE064B6, 0xC0388F)
            // Deep enough in dark for white text on it (sent messages, Send): 0x34B3BD was 2.5:1.
            case .teal: return (0x1F8F99, 0x0F7F88)
            case .graphite: return (0x8D9198, 0x676B72)
            }
        }

        /// The swatch Settings shows for it.
        var swatch: NSColor {
            guard let values else { return .controlAccentColor }
            return Color.dynamic(dark: Color.rgb(values.dark), light: Color.rgb(values.light))
        }

        static func resolved(dark: Bool) -> NSColor {
            guard let values = chosen.values else { return .controlAccentColor }
            return Color.rgb(dark ? values.dark : values.light)
        }
    }

    /// Interface theme (Settings › Appearance): Side's surfaces take their tones from the editor
    /// theme chosen for the appearance, so the editor and the chrome around it are one surface.
    /// Side's own theme, or a theme of the other appearance (a dark theme in light), leaves that
    /// appearance's tones as they are.
    @MainActor
    enum InterfaceTheme {
        static let key = "appearance.interface-theme"

        static var followsEditorTheme: Bool {
            get { HeronDefaults.store.bool(forKey: key) }
            set {
                HeronDefaults.store.set(newValue, forKey: key)
                refresh()
            }
        }

        /// Recomputes the tint from the editor themes; redraws only when it changed.
        static func refresh() {
            func tint(dark: Bool) -> Color.SurfaceTint? {
                guard followsEditorTheme, let theme = EditorThemes.current(dark: dark), theme.isDark == dark else { return nil }
                return Color.SurfaceTint(background: theme.background.nsColor, dark: dark)
            }
            let next = (dark: tint(dark: true), light: tint(dark: false))
            guard next.dark != Color.surfaceTint.dark || next.light != Color.surfaceTint.light else { return }
            Color.surfaceTint = next
            Appearance.refreshAll()
        }
    }

    /// Translucent background (Settings › Appearance): the window shows what's behind it, blurred
    /// and tinted with the canvas tone. One backdrop per window (the shell's ChromeBackground);
    /// every stage fill above it goes clear (`under`), so the tint is laid once and never stacks.
    /// The editor keeps its solid background unless `includesEditor`: code reads against its
    /// theme, not against the desktop. The Editor stage is the editor's surface either way: one fill
    /// in the editor's color (`editorStage`) under everything, solid or translucent, and the
    /// editor's own backgrounds (`editor`) clear over it when translucent — so the editor, the
    /// gutter, the minimap and the space around them are one tone and the tint is laid once.
    /// The terminal shows the backdrop through its own background.
    /// Reduce Transparency and Increase Contrast ask for solid surfaces, so they turn it off.
    enum Translucency {
        static let key = "appearance.translucent"
        static let editorKey = "appearance.translucent-editor"

        nonisolated(unsafe) private static var cached: (on: Bool, editor: Bool)?
        /// System Settings › Accessibility › Display › Reduce Transparency; a test sets its own.
        nonisolated(unsafe) static var reduceTransparency: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }

        private static var stored: (on: Bool, editor: Bool) {
            if let cached { return cached }
            let read = (on: HeronDefaults.store.bool(forKey: key), editor: HeronDefaults.store.bool(forKey: editorKey))
            cached = read
            return read
        }

        private static func store(on: Bool, editor: Bool) {
            HeronDefaults.store.set(on, forKey: key)
            HeronDefaults.store.set(editor, forKey: editorKey)
            cached = (on, editor)
            MainActor.assumeIsolated { Appearance.refreshAll() }
        }

        /// What Settings has chosen.
        static var chosen: Bool {
            get { stored.on }
            set { store(on: newValue, editor: stored.editor) }
        }
        static var editorChosen: Bool {
            get { stored.editor }
            set { store(on: stored.on, editor: newValue) }
        }

        /// Drawn: chosen, and the Mac's accessibility settings allow it.
        static var isOn: Bool { stored.on && !reduceTransparency() && !Color.increaseContrast() }
        static var includesEditor: Bool { isOn && stored.editor }

        /// The system's own glass for a window's body: it brings the saturation and the light
        /// that make it read as glass. A flat canvas tone laid thickly over a plain blur (how this
        /// began) read as a muddy sheet, not glass (the owner, 2026-11-12).
        static let material: NSVisualEffectView.Material = .sidebar
        /// How much of the canvas tone lies over the material: a breath, to keep secondary labels
        /// legible over a loud wallpaper without flattening the glass.
        static func tintOpacity(dark: Bool) -> CGFloat { dark ? 0.3 : 0.25 }
        /// The terminal's and the editor's own backgrounds over the glass: none. Their text sits
        /// on the window's glass, one surface with the bars and tabs around it; a background of
        /// their own, even faint, drew a second sheet inside the window (the owner, 2026-11-12).
        static let terminalOpacity: CGFloat = 0
        static let editorOpacity: CGFloat = 0
        /// Over something that scrolled under the top row: the canvas tone, nearly opaque, on the
        /// same glass, so the row stays the window's glass and the text under it doesn't show.
        static let coverTint = NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return resolved(Color.canvas, in: appearance).withAlphaComponent(dark ? 0.92 : 0.9)
        }

        /// The window's tint: the canvas tone, translucent.
        static let tint = NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return resolved(Color.canvas, in: appearance).withAlphaComponent(tintOpacity(dark: dark))
        }

        /// A stage's own fill: `color` when solid; nothing when translucent, the backdrop being
        /// the stage.
        static func under(_ color: NSColor) -> NSColor {
            NSColor(name: nil) { appearance in isOn ? .clear : resolved(color, in: appearance) }
        }

        /// The editor's own backgrounds (the text, the gutter, the minimap, the previews): solid,
        /// or clear over `editorStage` when the editor is included.
        static func editor(_ color: NSColor) -> NSColor {
            NSColor(name: nil) { appearance in includesEditor ? .clear : resolved(color, in: appearance) }
        }

        /// The Editor stage's fill, under the editor and around it: the editor's color, translucent only when
        /// the editor is included.
        static func editorStage(_ color: NSColor) -> NSColor {
            NSColor(name: nil) { appearance in
                let solid = resolved(color, in: appearance)
                return includesEditor ? solid.withAlphaComponent(editorOpacity) : solid
            }
        }

        private static func resolved(_ color: NSColor, in appearance: NSAppearance) -> NSColor {
            var out = color
            appearance.performAsCurrentDrawingAppearance { out = color.usingColorSpace(.sRGB) ?? color }
            return out
        }

        /// The window composites what's behind it only while it's translucent: an opaque window
        /// is cheaper for the window server.
        @MainActor
        static func apply(to window: NSWindow) {
            window.isOpaque = !isOn
            window.backgroundColor = isOn ? .clear : Color.canvas
        }
    }

    /// A solid surface: the raised color and a hairline edge, drawn in whatever appearance it's
    /// drawn in. Nothing behind it is read, so nothing is blurred.
    final class SolidSurface: NSView {
        var cornerRadius: CGFloat { didSet { needsDisplay = true } }
        let contentView = NSView()

        init(cornerRadius: CGFloat) {
            self.cornerRadius = cornerRadius
            super.init(frame: .zero)
            wantsLayer = true
            contentView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(contentView)
            NSLayoutConstraint.activate([
                contentView.topAnchor.constraint(equalTo: topAnchor), contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
                contentView.trailingAnchor.constraint(equalTo: trailingAnchor), contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override var isOpaque: Bool { false }

        override func draw(_ dirtyRect: NSRect) {
            let radius = min(cornerRadius, bounds.height / 2, bounds.width / 2)
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
            Color.raised.setFill()
            path.fill()
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    /// A floating panel's surface around `content`: Liquid Glass on macOS 26, the popover
    /// material before it. The palette's, and every panel that grows out of the stage bar.
    static func makeFloatingSurface(embedding content: NSView, cornerRadius: CGFloat = Radius.palette) -> NSView {
        if Surfaces.current == .solid {
            let solid = SolidSurface(cornerRadius: cornerRadius)
            content.translatesAutoresizingMaskIntoConstraints = false
            solid.contentView.addSubview(content)
            NSLayoutConstraint.activate([
                content.topAnchor.constraint(equalTo: solid.topAnchor), content.leadingAnchor.constraint(equalTo: solid.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: solid.trailingAnchor), content.bottomAnchor.constraint(equalTo: solid.bottomAnchor),
            ])
            return solid
        }
        if #available(macOS 26.0, *), Surfaces.usesGlass {
            let glass = NSGlassEffectView()
            glass.contentView = content
            glass.cornerRadius = cornerRadius
            glass.style = .regular
            return glass
        }
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.state = .active
        effect.blendingMode = .withinWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = cornerRadius
        effect.layer?.masksToBounds = true
        content.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: effect.topAnchor), content.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: effect.trailingAnchor), content.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        return effect
    }

    /// A rounded fill in a token color, colored when its layer is drawn: right in whatever
    /// appearance it's drawn in, on screen or not. Selection capsules, hover fills.
    final class Fill: NSView {
        var color: NSColor { didSet { needsDisplay = true } }
        init(_ color: NSColor, cornerRadius: CGFloat) {
            self.color = color
            super.init(frame: .zero)
            wantsLayer = true
            layer?.cornerRadius = cornerRadius
            layer?.cornerCurve = .continuous
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override var wantsUpdateLayer: Bool { true }
        override func updateLayer() { layer?.backgroundColor = color.cgColor }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    /// A round button: width and height equal and required, the layer clipped to a circle, so it
    /// can't come out a pill whatever its content wants (the switcher's ×, 2026-11-05).
    final class CircleButton: NSButton {
        private let fill: Fill
        init(symbol: String, diameter: CGFloat, label: String) {
            fill = Fill(Color.hoverCapsule, cornerRadius: diameter / 2)
            super.init(frame: .zero)
            isBordered = false
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            symbolConfiguration = .init(pointSize: diameter * 0.42, weight: .semibold)
            contentTintColor = .secondaryLabelColor
            imagePosition = .imageOnly
            wantsLayer = true
            layer?.cornerRadius = diameter / 2
            layer?.masksToBounds = true
            translatesAutoresizingMaskIntoConstraints = false
            fill.frame = NSRect(x: 0, y: 0, width: diameter, height: diameter)
            fill.autoresizingMask = [.width, .height]
            addSubview(fill, positioned: .below, relativeTo: nil)
            let width = widthAnchor.constraint(equalToConstant: diameter)
            let height = heightAnchor.constraint(equalToConstant: diameter)
            width.priority = .required
            height.priority = .required
            NSLayoutConstraint.activate([width, height])
            setContentHuggingPriority(.required, for: .horizontal)
            setContentHuggingPriority(.required, for: .vertical)
            setAccessibilityLabel(label)
            toolTip = label
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }
        /// The glyph's color on a tinted surface (the update pill's), at rest and on hover alike.
        var tint: NSColor? { didSet { contentTintColor = tint ?? .secondaryLabelColor } }
        override func mouseEntered(with event: NSEvent) { fill.color = Color.selectedCapsule; contentTintColor = tint ?? .labelColor }
        override func mouseExited(with event: NSEvent) { fill.color = Color.hoverCapsule; contentTintColor = tint ?? .secondaryLabelColor }
    }

    static func makeGlass(cornerRadius: CGFloat) -> NSView {
        if Surfaces.current == .solid {
            let solid = SolidSurface(cornerRadius: cornerRadius)
            solid.translatesAutoresizingMaskIntoConstraints = false
            return solid
        }
        if #available(macOS 26.0, *), Surfaces.usesGlass {
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

    /// Motion (Direction 03 §2): two springs and a fade, and nothing else. Movement goes on
    /// `snappy` or `smooth` through `animate`, opacity on `fade`, and Reduce Motion is consulted
    /// here alone. The old single curve and its duration helper are gone (step 4, 2026-10-31):
    /// every animation in the app now takes one of these three.
    enum Motion {
        /// A spring by feel (Direction 03 §2.2): `response` is how quickly it gets there, `damping`
        /// how much it gives. Below about 0.85 it visibly overshoots and settles, which is the
        /// fluid feel Side aims for; at 0.88 and up it reads as a plain ease-out.
        struct Spring: Equatable, Sendable {
            let response: Double
            let damping: Double
            /// Bézier control points for `curve`; the second's y above 1 is the overshoot.
            let controlPoints: [Float]
            /// The spring as a curve with its overshoot, for `NSAnimationContext` (view frames and
            /// anything else animated through `animator()`), which can't run a real spring.
            var curve: CAMediaTimingFunction {
                CAMediaTimingFunction(controlPoints: controlPoints[0], controlPoints[1], controlPoints[2], controlPoints[3])
            }
            /// How long `curve` runs: about when the spring looks settled.
            var duration: TimeInterval { response * 1.3 }

            /// `curve`'s value `t` of the way through (0–1), overshoot included: for a change
            /// driven frame by frame that must keep step with views moving on `curve`.
            func progress(at t: Double) -> Double {
                let t = min(max(t, 0), 1)
                let (x1, y1, x2, y2) = (Double(controlPoints[0]), Double(controlPoints[1]), Double(controlPoints[2]), Double(controlPoints[3]))
                func bezier(_ s: Double, _ a: Double, _ b: Double) -> Double { 3 * (1 - s) * (1 - s) * s * a + 3 * (1 - s) * s * s * b + s * s * s }
                // The curve's x is monotonic in s: bisect for the s whose x is t.
                var low = 0.0, high = 1.0
                for _ in 0..<24 {
                    let mid = (low + high) / 2
                    if bezier(mid, x1, x2) < t { low = mid } else { high = mid }
                }
                return bezier((low + high) / 2, y1, y2)
            }
        }

        /// Settling after direct manipulation: a tab set down, neighbours sliding aside, a press
        /// releasing. About 1% overshoot.
        static let snappy = Spring(response: 0.26, damping: 0.80, controlPoints: [0.25, 1.1, 0.35, 1])
        /// Presentations: panels, Side's own popovers, the tab's preview morph, a pill growing.
        /// About 2% overshoot.
        static let smooth = Spring(response: 0.40, damping: 0.76, controlPoints: [0.28, 1.18, 0.38, 1])
        /// A presentation's ease without a spring's overshoot: the palette growing out of the nav,
        /// which the owner wanted as it was (2026-10-31).
        static var easeOut: CAMediaTimingFunction { CAMediaTimingFunction(controlPoints: 0.2, 0.85, 0.25, 1.0) }
        /// Opacity only, never a spring: alpha that overshoots flashes.
        static let fadeDuration: TimeInterval = 0.15
        /// A floating panel growing out of the stage bar (the palette, the project switcher, ⌃⇥),
        /// and going back into it; `easeOut` both ways (SIDE_DESIGN_POLISH_0.5.md §1).
        static let presentDuration: TimeInterval = 0.22
        static let dismissDuration: TimeInterval = 0.18
        static var fadeCurve: CAMediaTimingFunction { CAMediaTimingFunction(name: .easeOut) }
        /// A view of the same content changing form (the editor and its Markdown preview, Writer
        /// mode): just enough to soften the cut, short enough to barely register.
        static let glanceDuration: TimeInterval = 0.09
        /// One turn of an indeterminate progress ring: steady, never urgent.
        static let spinDuration: TimeInterval = 1.0

        /// `CASpringAnimation` for a spring. `velocity` and `distance` (in the animated value's
        /// units, per second) carry a gesture's speed into the settle, so a flick lands with
        /// momentum instead of stopping and starting again.
        static func spring(_ spring: Spring, keyPath: String, velocity: CGFloat = 0, distance: CGFloat = 0) -> CASpringAnimation {
            let animation = CASpringAnimation(keyPath: keyPath)
            animation.mass = 1
            animation.stiffness = pow(2 * .pi / spring.response, 2)
            animation.damping = 4 * .pi * spring.damping / spring.response
            // CASpringAnimation wants velocity as a fraction of the distance it travels.
            animation.initialVelocity = distance != 0 ? velocity / distance : 0
            animation.duration = animation.settlingDuration
            return animation
        }

        /// The snappy spring for a layer animation (the press, and older call sites).
        static func spring(keyPath: String) -> CASpringAnimation { spring(snappy, keyPath: keyPath) }

        /// Animates changes made through `animator()` on a spring. Under Reduce Motion nothing
        /// moves: the changes land at once, and `crossfading`'s layer fades from the old look to
        /// the new over 0.1 s, so the change still reads as one (Direction 03 §2.2).
        @MainActor
        static func animate(_ spring: Spring, crossfading view: NSView? = nil, _ changes: () -> Void, completion: (@MainActor () -> Void)? = nil) {
            if reduceMotion {
                if let layer = view?.layer {
                    let fade = CATransition()
                    fade.type = .fade
                    fade.duration = 0.1
                    layer.add(fade, forKey: "dsCrossfade")
                }
                changes()
                completion?()
                return
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = spring.duration
                context.timingFunction = spring.curve
                context.allowsImplicitAnimation = true
                changes()
            } completionHandler: {
                MainActor.assumeIsolated { completion?() }
            }
        }

        /// Opacity changes through `animator()`: hover reveals, crossfades. Fades stay under
        /// Reduce Motion, which is about movement.
        @MainActor
        static func fade(duration: TimeInterval = fadeDuration, _ changes: () -> Void, completion: (@MainActor () -> Void)? = nil) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = fadeCurve
                changes()
            } completionHandler: {
                MainActor.assumeIsolated { completion?() }
            }
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

        /// What `view` shows next replaces what it shows now in a crossfade: for a change of
        /// content that isn't a change of place (a stage switch). Stays under Reduce Motion,
        /// which is about movement.
        static func crossfade(_ view: NSView, duration: TimeInterval = fadeDuration) {
            view.wantsLayer = true
            let fade = CATransition()
            fade.type = .fade
            fade.duration = duration
            fade.timingFunction = fadeCurve
            view.layer?.add(fade, forKey: "dsCrossfade")
        }

        /// A panel at the window's trailing edge comes in: a short slide from the edge on the
        /// smooth spring and a fade. Floating over the stage, it also grows from a touch smaller,
        /// as a popover does. The Agent panel and the companion both (2026-11-07).
        @MainActor
        static func revealEdgePanel(_ view: NSView, floating: Bool) {
            view.isHidden = false
            guard !reduceMotion else { return }
            view.wantsLayer = true
            guard let layer = view.layer else { return }
            layer.removeAnimation(forKey: "edgeOut")
            layer.removeAnimation(forKey: "edgeOutFade")
            let move = spring(smooth, keyPath: "transform")
            move.fromValue = edgeTransform(floating: floating, bounds: view.bounds)
            move.toValue = CATransform3DIdentity
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = presentDuration
            fade.timingFunction = fadeCurve
            layer.add(move, forKey: "edgeIn")
            layer.add(fade, forKey: "edgeInFade")
        }

        /// It leaves the way it came, quicker, then hides and runs `completion`. A reveal before
        /// it's gone takes over, and `completion` doesn't run.
        @MainActor
        static func dismissEdgePanel(_ view: NSView, floating: Bool, completion: @escaping @MainActor () -> Void = {}) {
            guard !view.isHidden else { return completion() }
            view.wantsLayer = true
            guard !reduceMotion, let layer = view.layer else { view.isHidden = true; return completion() }
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak view] in
                MainActor.assumeIsolated {
                    guard let view, let layer = view.layer, layer.animation(forKey: "edgeOut") != nil else { return }
                    view.isHidden = true
                    layer.removeAnimation(forKey: "edgeOut")
                    layer.removeAnimation(forKey: "edgeOutFade")
                    completion()
                }
            }
            let move = CABasicAnimation(keyPath: "transform")
            move.fromValue = layer.presentation()?.transform ?? CATransform3DIdentity
            move.toValue = edgeTransform(floating: floating, bounds: view.bounds)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = layer.presentation()?.opacity ?? 1
            fade.toValue = 0
            for animation in [move, fade] {
                animation.duration = dismissDuration
                animation.timingFunction = fadeCurve
                animation.fillMode = .forwards
                animation.isRemovedOnCompletion = false
            }
            layer.add(move, forKey: "edgeOut")
            layer.add(fade, forKey: "edgeOutFade")
            CATransaction.commit()
        }

        /// A dismissal under way stops: the panel is shown again at once.
        @MainActor
        static func cancelEdgeDismiss(_ view: NSView) {
            view.layer?.removeAnimation(forKey: "edgeOut")
            view.layer?.removeAnimation(forKey: "edgeOutFade")
        }

        private static func edgeTransform(floating: Bool, bounds: CGRect) -> CATransform3D {
            let slide = CATransform3DMakeTranslation(floating ? 12 : 28, 0, 0)
            guard floating else { return slide }
            let cx = bounds.midX, cy = bounds.midY
            let scale = CATransform3DConcat(CATransform3DConcat(CATransform3DMakeTranslation(-cx, -cy, 0), CATransform3DMakeScale(0.97, 0.97, 1)), CATransform3DMakeTranslation(cx, cy, 0))
            return CATransform3DConcat(slide, scale)
        }

        /// The standard arrival: rise and a slight scale on the smooth spring, and a fade, which
        /// never springs. Think's bubbles set the reference feel. Purely a layer animation over
        /// the view's settled Auto Layout position, so it can't fight layout.
        static func appear(_ view: NSView, distance: CGFloat = 16) {
            guard !reduceMotion else { return }
            view.wantsLayer = true
            guard let layer = view.layer else { return }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = fadeDuration
            fade.timingFunction = fadeCurve
            fade.fillMode = .backwards
            let rise = CABasicAnimation(keyPath: "transform.translation.y")
            rise.fromValue = distance
            rise.toValue = 0
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.96
            scale.toValue = 1
            for move in [rise, scale] {
                move.duration = smooth.duration
                move.timingFunction = smooth.curve
            }
            let group = CAAnimationGroup()
            group.animations = [fade, rise, scale]
            group.duration = smooth.duration
            layer.add(group, forKey: "dsAppear")
        }

        /// A piece of glass whose content changed width springs from the width it had to the
        /// one it fits now: held on a width constraint that's animated, then let go. Glass
        /// follows a constraint each frame; an animated frame snapped it to its new size at
        /// once (the update pill, 2026-11-05). One per view: a new change takes over from
        /// wherever the last one has got to.
        @MainActor
        final class WidthSpring {
            private weak var view: NSView?
            private let priority: NSLayoutConstraint.Priority
            private var hold: NSLayoutConstraint?

            /// `priority`: under required, the window's and the bar's own limits win over it.
            init(_ view: NSView, priority: NSLayoutConstraint.Priority = .required) {
                self.view = view
                self.priority = priority
            }

            /// The width it's at now, mid-spring or not: read before the content changes.
            var currentWidth: CGFloat { view?.frame.width ?? 0 }

            /// Lets go of the width it was held at, so `fittingSize` is the content's again.
            func release() {
                hold?.isActive = false
                hold = nil
            }

            func run(from old: CGFloat, to new: CGFloat, completion: (@MainActor () -> Void)? = nil) {
                release()
                guard let view, !reduceMotion, old > 0, abs(old - new) > 0.5 else { completion?(); return }
                let width = view.widthAnchor.constraint(equalToConstant: old)
                width.priority = priority
                width.isActive = true
                hold = width
                animate(snappy, { width.animator().constant = new }, completion: { [weak self] in
                    guard let self, self.hold === width else { return }
                    self.release()
                    completion?()
                })
            }
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
    var accessibleTabs: [NSView] = []
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

    /// What sits at the strip's trailing end (Terminal's new-tab button): the tabs' solo name
    /// stops short of it.
    var trailingReserve: CGFloat = 0

    @objc private func tabsResized() { needsLayout = true }

    /// The track shown or not with the strip (one tab needs no strip), fading when animated.
    func showTrack(_ shown: Bool, animated: Bool) {
        guard let glass = glassTrack else { return }
        guard animated else {
            glass.alphaValue = shown ? 1 : 0
            glass.isHidden = !shown
            return
        }
        if shown {
            if glass.isHidden { glass.alphaValue = 0 }
            glass.isHidden = false
        }
        DS.Motion.fade({ glass.animator().alphaValue = shown ? 1 : 0 }, completion: { [weak glass] in
            guard let glass, !shown, glass.alphaValue == 0 else { return }
            glass.isHidden = true
        })
    }

    /// How wide the tabs are, set by the strip from their laid-out frames; nil until it says.
    private var trackWidth: CGFloat?

    /// The track to `width`, on `spring` from `from` (or from what's on screen) when given. The
    /// strip drives it: sized inside this view's layout pass, the track never moved on a spring
    /// and jumped again once the tabs' frames caught up (2026-10-31).
    func setTrackWidth(_ width: CGFloat, spring: DS.Motion.Spring?, from: CGFloat? = nil) {
        guard glassTrack != nil else { return }
        let shown = from ?? trackMotion?.width ?? glassTrack?.frame.width ?? width
        trackWidth = width
        trackMotion = nil
        applyTrack()
        guard let spring, !DS.Motion.reduceMotion, window != nil, let target = glassTrack?.frame.width, abs(shown - target) > 0.5 else {
            trackLink?.invalidate()
            trackLink = nil
            return
        }
        // Frame by frame, on the tabs' own curve: the glass is drawn from its view's frame, so a
        // layer animation of it never showed (narrowing, it stayed wide and then jumped: the
        // owner, 2026-11-04, closing tabs "choppy and rough"), and a true spring settled well
        // before the tabs moving on `curve`.
        // Growing, it gets there first and fast: a new tab fades in at its place at once and
        // mustn't sit outside the glass. Narrowing, it keeps step with the tabs closing up.
        let curve = target > shown ? DS.Motion.Spring(response: spring.response * 0.7, damping: 1, controlPoints: [0.2, 0.85, 0.25, 1]) : spring
        trackMotion = TrackMotion(from: shown, to: target, start: CACurrentMediaTime(), spring: curve)
        if trackLink == nil {
            let link = displayLink(target: self, selector: #selector(stepTrack(_:)))
            link.add(to: .main, forMode: .common)
            trackLink = link
        }
        applyTrack()
    }

    /// The track on its way from one width to another.
    private struct TrackMotion {
        let from: CGFloat
        let to: CGFloat
        let start: CFTimeInterval
        let spring: DS.Motion.Spring
        var width: CGFloat { width(at: CACurrentMediaTime()) }
        func width(at time: CFTimeInterval) -> CGFloat {
            from + (to - from) * spring.progress(at: (time - start) / spring.duration)
        }
        func isDone(at time: CFTimeInterval) -> Bool { time - start >= spring.duration }
    }
    private var trackMotion: TrackMotion?
    private var trackLink: CADisplayLink?

    @objc private func stepTrack(_ link: CADisplayLink) {
        guard let motion = trackMotion else {
            link.invalidate()
            trackLink = nil
            return
        }
        if motion.isDone(at: CACurrentMediaTime()) {
            trackMotion = nil
            link.invalidate()
            trackLink = nil
        }
        applyTrack()
    }

    override func layout() {
        super.layout()
        applyTrack()
    }

    private func applyTrack() {
        guard let glass = glassTrack, let scroll = trackScroll, let stack = trackStack else { return }
        // The tabs' width as the strip last laid them out, else from their constraints: this
        // layout runs before the scroll view gives the stack its new frame, and sizing from that
        // frame left the track, and the mask below, at the old width. A new tab (or one dropped
        // back from its card) was then cut off by the mask, there in every record but blank on
        // screen until another layout (the owner, 2026-10-31).
        let tabs = min(trackWidth ?? stack.fittingSize.width, scroll.frame.width)
        // On its way (`setTrackWidth`), the glass is where its motion has got to; the mask is the
        // wider of that and the tabs' width, so tabs arriving or sliding in are never cut off.
        let glassWidth = min(trackMotion?.width ?? tabs, scroll.frame.width)
        let width = max(glassWidth, tabs)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            glass.frame = NSRect(x: scroll.frame.minX, y: (bounds.height - Self.trackHeight) / 2, width: glassWidth, height: Self.trackHeight)
        }
        // The tabs are cut off at the track's round ends, not the scroll view's square ones: a
        // selected tab half scrolled out used to poke its pill past the curve. The mask takes its
        // shape at once, never on an animation: a mask that lags the tabs hides them.
        scroll.wantsLayer = true
        let mask = (scroll.layer?.mask as? CAShapeLayer) ?? CAShapeLayer()
        let track = NSRect(x: 0, y: (scroll.bounds.height - Self.trackHeight) / 2, width: width, height: Self.trackHeight)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = scroll.bounds
        mask.path = CGPath(roundedRect: track, cornerWidth: Self.trackHeight / 2, cornerHeight: Self.trackHeight / 2, transform: nil)
        CATransaction.commit()
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
            get { HeronDefaults.store.string(forKey: preferenceKey).flatMap(Preference.init) ?? .system }
            set {
                HeronDefaults.store.set(newValue.rawValue, forKey: preferenceKey)
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
            InterfaceTheme.refresh()
            NotificationCenter.default.addObserver(forName: EditorThemes.didChangeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { InterfaceTheme.refresh() }
            }
            // Match System follows a change of the Mac's accent: what holds a resolved colour
            // (layers, the editor's caret) is told, as for a change of appearance.
            NotificationCenter.default.addObserver(forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { if Accent.chosen == .system { refreshAll() } }
            }
            lastKnownIsDark = isDark
            observation = NSApp.observe(\.effectiveAppearance, options: [.new]) { _, _ in
                DispatchQueue.main.async { appearanceMayHaveChanged() }
            }
            // Increase Contrast turned on or off: the same as a change of appearance.
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { refreshAll() }
            }
        }

        /// Increase Contrast, the accent or the interface theme changed: every token may resolve
        /// differently, as after a change of appearance.
        @MainActor
        static func refreshAll() {
            LayerBindings.reapplyAll()
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
            func redraw(_ view: NSView) { view.needsDisplay = true; view.subviews.forEach(redraw) }
            for window in NSApp.windows { window.contentView.map(redraw) }
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

    /// No background, and none restored by the next appearance change: setting
    /// `layer?.backgroundColor = nil` left the binding in place to paint it back.
    func unbindLayerBackground() {
        objc_setAssociatedObject(self, &boundBackgroundKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        layer?.backgroundColor = nil
    }

    func unbindLayerBorder() {
        objc_setAssociatedObject(self, &boundBorderKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        layer?.borderColor = nil
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
        // The view's own appearance: under an editor theme of the other appearance, Make's chrome
        // and Review's diff take the theme's, and the window's would be the wrong one.
        effectiveAppearance.performAsCurrentDrawingAppearance {
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
        /// quiet filled dot, never the turning arc, which means an agent is working.
        case needsYou, working, verified, failed, idle, unread

        var name: String {
            switch self {
            case .needsYou: return "Needs you"
            case .working: return "Working"
            case .verified: return "Ready for review"
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
            // New output is a mark, not a state: no status colour (Direction 03 §3.1).
            case .unread: return .secondaryLabelColor
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

    /// A 6 pt status dot. Filled for every state but Working, which is a short arc turning
    /// steadily, as a Mac's own spinners do (the owner, 2026-11-12: the breathing ring it replaced
    /// pulsed for attention it didn't need) — the only animated indicator in the app. Exposed to accessibility as an image
    /// whose label is the state's name, so the colour is never the only carrier.
    /// A list's selected row (Quick Open, the palette, Settings' sidebar, mention lists): the
    /// soft selected capsule tabs and the stage control use, inset from the list's edges.
    /// Never the accent: one way of saying "selected" across Side (visual audit, 2026-11-04).
    /// Never emphasized either, so a row's text keeps its own colors on it.
    /// An on/off option in a floating panel (Find's Aa, W, .*): plain until on, then the selected
    /// capsule behind it, as a selected tab or stage. The stock accessory-bar bezel was a gray
    /// square in a panel of capsules (the visual audit, 2026-11-04).
    final class CapsuleToggle: NSButton {
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            setButtonType(.pushOnPushOff)
            isBordered = false
            wantsLayer = true
            layer?.cornerRadius = Radius.control
            contentTintColor = .secondaryLabelColor
            translatesAutoresizingMaskIntoConstraints = false
            heightAnchor.constraint(equalToConstant: 24).isActive = true
            widthAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
        }

        convenience init() { self.init(frame: .zero) }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override var state: NSControl.StateValue { didSet { applyState() } }

        override func mouseUp(with event: NSEvent) {
            super.mouseUp(with: event)
            applyState()
        }

        func applyState() {
            if state == .on { bindLayerBackground(Color.selectedCapsule) } else { unbindLayerBackground() }
            contentTintColor = state == .on ? .labelColor : .secondaryLabelColor
        }
    }

    final class SelectionRowView: NSTableRowView {
        override var isEmphasized: Bool { get { false } set {} }
        override func drawSelection(in dirtyRect: NSRect) {
            guard isSelected else { return }
            Color.selectedCapsule.setFill()
            let rect = bounds.insetBy(dx: Spacing.m, dy: 1)
            NSBezierPath(roundedRect: rect, xRadius: Radius.control + 2, yRadius: Radius.control + 2).fill()
        }
    }

    final class StatusDot: NSView {
        var state: StatusState { didSet { if state != oldValue { apply() } } }
        /// One size everywhere (Direction 03 §3.2): four sizes made the same state look different.
        static let diameter: CGFloat = 6
        private var diameter: CGFloat { Self.diameter }

        init(state: StatusState) {
            self.state = state
            super.init(frame: NSRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter))
            wantsLayer = true
            translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: diameter), heightAnchor.constraint(equalToConstant: diameter)])
            layer?.cornerRadius = diameter / 2
            setAccessibilityElement(true)
            setAccessibilityRole(.image)
            apply()
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        /// Working's arc, turning.
        private var spinner: CAShapeLayer?

        override func layout() {
            super.layout()
            spinner?.frame = bounds
            spinner?.path = CGPath(ellipseIn: bounds.insetBy(dx: 0.75, dy: 0.75), transform: nil)
        }

        private func apply() {
            setAccessibilityLabel(state.name)
            spinner?.removeFromSuperlayer()
            spinner = nil
            layer?.opacity = 1
            if state == .idle {
                // Quiet is a still ring: a filled grey dot read as a dimmed state of the others.
                unbindLayerBackground()
                layer?.borderWidth = 1.5
                layer?.opacity = 1
                bindLayerBorder(state.color)
            } else if state == .working {
                unbindLayerBackground()
                unbindLayerBorder()
                layer?.borderWidth = 0
                // Three quarters of the ring, its ends rounded, turning once a second; still under
                // Reduce Motion.
                let arc = CAShapeLayer()
                arc.frame = bounds
                arc.path = CGPath(ellipseIn: bounds.insetBy(dx: 0.75, dy: 0.75), transform: nil)
                arc.fillColor = nil
                arc.lineWidth = 1.5
                arc.lineCap = .round
                arc.strokeEnd = 0.72
                var color = state.color.cgColor
                effectiveAppearance.performAsCurrentDrawingAppearance { color = self.state.color.cgColor }
                arc.strokeColor = color
                layer?.addSublayer(arc)
                spinner = arc
                guard !Motion.reduceMotion else { return }
                let turn = CABasicAnimation(keyPath: "transform.rotation.z")
                turn.fromValue = 0
                turn.toValue = -2 * CGFloat.pi
                turn.duration = 1.0
                turn.repeatCount = .infinity
                turn.isRemovedOnCompletion = false
                arc.add(turn, forKey: "turn")
            } else {
                unbindLayerBorder()
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
        /// The stage's own symbol, large and quiet above the sentence: an empty stage still says
        /// which stage it is (the visual audit: a sentence and a button in an empty canvas).
        var symbol: String? {
            didSet {
                icon.image = DS.Glyph.image(named: symbol, pointSize: 36)
                icon.isHidden = symbol == nil
            }
        }
        private let icon = NSImageView()
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
            button.bezelColor = DS.Color.accent
            button.target = self
            button.action = #selector(performAction)
            icon.symbolConfiguration = .init(pointSize: 30, weight: .light)
            icon.contentTintColor = .tertiaryLabelColor
            icon.isHidden = true
            icon.setAccessibilityElement(false)
            addArrangedSubview(icon)
            setCustomSpacing(Spacing.xxl, after: icon)
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
            label.font = Text.caption()
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
    case openProject, initializeGit, newTrack, chooseTrack, setUpAgent
    /// The one repository just inside a project folder that isn't one (`TrackStore.soleRepository`).
    case openRepositoryInside
}



/// Speaking what changed where VoiceOver's focus isn't (2026-09-30 audit, UX-7). A list that
/// follows typing (the palette, completions, mentions) keeps focus in the field, so VoiceOver
/// heard nothing as the arrows moved through it; an announcement says the row instead.
@MainActor
enum Spoken {
    /// Says `text` when VoiceOver is on; nothing otherwise.
    static func announce(_ text: String, priority: NSAccessibilityPriorityLevel = .medium) {
        guard !text.isEmpty, isEnabled() else { return }
        lastAnnouncement = text
        NSAccessibility.post(element: NSApp.mainWindow ?? NSApp.keyWindow ?? NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: priority.rawValue])
    }

    /// A list row: what it says, and where it is in the list.
    static func row(_ label: String, at index: Int, of count: Int) {
        announce("\(label), \(index + 1) of \(count)")
    }

    /// Whether anything is listening; a test turns it on.
    nonisolated(unsafe) static var isEnabled: () -> Bool = { NSWorkspace.shared.isVoiceOverEnabled }
    /// The last thing said, for tests.
    nonisolated(unsafe) static var lastAnnouncement: String?
}


/// Text size for the views that don't restyle themselves (2026-09-30 audit, UX-8): Settings,
/// Library, Make's chrome and debugger, Run, the shell's chrome. Fonts there were set once when
/// built, so a size change reached only Think, Review, Tracks and Usage. On a change, every
/// window's views (and the detached ones the providers name: hidden stages, cached Settings
/// panes) have their fonts and table row heights scaled by new ÷ old, except the subtrees that
/// restyle themselves (`exempt`), so nothing is scaled twice.
@MainActor
enum TextScaleFollower {
    private static let exempted = NSHashTable<NSView>.weakObjects()
    /// Views out of any window that still need following.
    private static var detachedProviders: [() -> [NSView]] = []
    private static var observer: NSObjectProtocol?

    /// A view whose own observer restyles it and everything inside it.
    static func exempt(_ view: NSView) { exempted.add(view) }

    static func addDetachedViews(_ provider: @escaping () -> [NSView]) { detachedProviders.append(provider) }

    /// Once, at launch.
    static func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: DS.Text.scaleDidChangeNotification, object: nil, queue: .main) { note in
            guard let old = note.userInfo?["old"] as? Double, let new = note.userInfo?["new"] as? Double, old > 0 else { return }
            MainActor.assumeIsolated { follow(ratio: CGFloat(new / old)) }
        }
    }

    static func follow(ratio: CGFloat) {
        var seen = Set<ObjectIdentifier>()
        let roots = NSApp.windows.compactMap(\.contentView) + detachedProviders.flatMap { $0() }
        for root in roots where seen.insert(ObjectIdentifier(root)).inserted { rescale(root, by: ratio) }
    }

    static func rescale(_ view: NSView, by ratio: CGFloat) {
        guard !exempted.contains(view) else { return }
        if let field = view as? NSTextField {
            scale(field, by: ratio)
        } else if let control = view as? NSControl, let font = control.font {
            control.font = scaled(font, ratio)
        } else if let text = view as? NSTextView {
            if let font = text.font { text.font = scaled(font, ratio) }
            if let storage = text.textStorage, storage.length > 0 { scaleFonts(in: storage, by: ratio) }
        }
        if let table = view as? NSTableView, !(table.rowHeight <= 0) {
            table.rowHeight = (table.rowHeight * ratio).rounded()
        }
        for subview in view.subviews { rescale(subview, by: ratio) }
        view.needsLayout = true
    }

    private static func scaled(_ font: NSFont, _ ratio: CGFloat) -> NSFont {
        NSFont(descriptor: font.fontDescriptor, size: (font.pointSize * ratio * 2).rounded() / 2) ?? font
    }

    /// A field's own font, and the fonts in its attributed text (colors and all kept).
    private static func scale(_ field: NSTextField, by ratio: CGFloat) {
        let attributed = field.attributedStringValue
        if let font = field.font { field.font = scaled(font, ratio) }
        guard !field.isEditable, attributed.length > 0 else { return }
        let copy = NSMutableAttributedString(attributedString: attributed)
        scaleFonts(in: copy, by: ratio)
        field.attributedStringValue = copy
    }

    private static func scaleFonts(in text: NSMutableAttributedString, by ratio: CGFloat) {
        text.beginEditing()
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let font = value as? NSFont { text.addAttribute(.font, value: scaled(font, ratio), range: range) }
        }
        text.endEditing()
    }
}

// MARK: - Stage glyphs

extension DS {
    /// Side's own stage icons (the owner chose set A, 2026-11-04): one family on a 24 pt grid,
    /// 1.75 pt stroke, round caps and joins, 3 pt corners. At rest an outline; selected, the same
    /// shape solid with its detail cut out. Template images, so they take the tint they're given.
    /// Names that aren't a stage's fall through to SF Symbols.
    @MainActor
    enum Glyph {
        nonisolated static let prefix = "side.stage."
        nonisolated static func name(_ stage: String) -> String { prefix + stage }

        /// A stage glyph, or the SF Symbol of that name.
        static func image(named name: String?, selected: Bool = false, pointSize: CGFloat = 16) -> NSImage? {
            guard let name else { return nil }
            guard name.hasPrefix(prefix) else { return NSImage(systemSymbolName: name, accessibilityDescription: nil) }
            let key = "\(name)|\(selected)|\(pointSize)"
            if let cached = cache[key] { return cached }
            let kind = String(name.dropFirst(prefix.count))
            let image = NSImage(size: NSSize(width: pointSize, height: pointSize), flipped: true) { rect in
                guard let context = NSGraphicsContext.current?.cgContext else { return false }
                context.scaleBy(x: rect.width / 24, y: rect.height / 24)
                draw(kind, selected: selected, in: context)
                return true
            }
            image.isTemplate = true
            cache[key] = image
            return image
        }

        private static var cache: [String: NSImage] = [:]
        private static let stroke: CGFloat = 1.75

        private static func line(_ points: [(CGFloat, CGFloat)], in context: CGContext) {
            guard let first = points.first else { return }
            context.move(to: CGPoint(x: first.0, y: first.1))
            for point in points.dropFirst() { context.addLine(to: CGPoint(x: point.0, y: point.1)) }
        }

        private static func strokeDetail(_ context: CGContext, knockout: Bool, _ build: () -> Void) {
            context.saveGState()
            if knockout { context.setBlendMode(.clear) }
            context.setLineWidth(stroke)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.beginPath()
            build()
            context.strokePath()
            context.restoreGState()
        }

        private static func body(_ path: CGPath, selected: Bool, in context: CGContext) {
            context.addPath(path)
            if selected {
                context.fillPath()
            } else {
                context.setLineWidth(stroke)
                context.setLineJoin(.round)
                context.strokePath()
            }
        }

        private static func draw(_ kind: String, selected: Bool, in context: CGContext) {
            context.setFillColor(NSColor.black.cgColor)
            context.setStrokeColor(NSColor.black.cgColor)
            func rounded(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGPath {
                CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: 3, cornerHeight: 3, transform: nil)
            }
            switch kind {
            case "editor":
                body(rounded(4.5, 3, 15, 18), selected: selected, in: context)
                strokeDetail(context, knockout: selected) {
                    line([(8.5, 8.5), (15.5, 8.5)], in: context)
                    line([(8.5, 12), (13.5, 12)], in: context)
                    line([(8.5, 15.5), (11.5, 15.5)], in: context)
                }
            case "agent":
                let spark = CGMutablePath()
                spark.move(to: CGPoint(x: 12, y: 3.5))
                spark.addCurve(to: CGPoint(x: 20.5, y: 12), control1: CGPoint(x: 12.7, y: 8.1), control2: CGPoint(x: 15.9, y: 11.3))
                spark.addCurve(to: CGPoint(x: 12, y: 20.5), control1: CGPoint(x: 15.9, y: 12.7), control2: CGPoint(x: 12.7, y: 15.9))
                spark.addCurve(to: CGPoint(x: 3.5, y: 12), control1: CGPoint(x: 11.3, y: 15.9), control2: CGPoint(x: 8.1, y: 12.7))
                spark.addCurve(to: CGPoint(x: 12, y: 3.5), control1: CGPoint(x: 8.1, y: 11.3), control2: CGPoint(x: 11.3, y: 8.1))
                spark.closeSubpath()
                if selected {
                    context.addPath(spark)
                    context.fillPath()
                }
                context.addPath(spark)
                context.setLineWidth(stroke)
                context.setLineJoin(.round)
                context.strokePath()
            case "changes":
                body(rounded(4, 4, 16, 16), selected: selected, in: context)
                strokeDetail(context, knockout: selected) {
                    line([(12, 7.5), (12, 12.5)], in: context)
                    line([(9.5, 10), (14.5, 10)], in: context)
                    line([(9.5, 16), (14.5, 16)], in: context)
                }
            case "terminal":
                body(rounded(3, 5, 18, 14), selected: selected, in: context)
                strokeDetail(context, knockout: selected) {
                    line([(7.5, 10), (10, 12), (7.5, 14)], in: context)
                    line([(12.5, 14.5), (16.5, 14.5)], in: context)
                }
            case "branches":
                let radius: CGFloat = selected ? 3 : 2.25
                for (x, y) in [(7.5, 6.0), (7.5, 18.0), (16.5, 8.0)] as [(CGFloat, CGFloat)] {
                    let circle = CGPath(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2), transform: nil)
                    body(circle, selected: selected, in: context)
                }
                strokeDetail(context, knockout: false) {
                    line([(7.5, 8.25), (7.5, 15.75)], in: context)
                    context.move(to: CGPoint(x: 16.5, y: 10.25))
                    context.addCurve(to: CGPoint(x: 10, y: 15.5), control1: CGPoint(x: 16.5, y: 13.75), control2: CGPoint(x: 14, y: 14.75))
                }
            default:
                break
            }
        }
    }
}
