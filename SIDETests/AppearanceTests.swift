import XCTest
@testable import Side
@testable import SideAgents

/// Light mode. Every token is dynamic, layer colours re-resolve on an appearance change, and the
/// terminal derives its colours from the same tokens.
@MainActor
final class AppearanceTests: XCTestCase {
    private func resolved(_ color: NSColor, in appearance: NSAppearance.Name) -> NSColor {
        var out = color
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            out = color.usingColorSpace(.deviceRGB) ?? color
        }
        return out
    }

    private func luminance(_ color: NSColor, in appearance: NSAppearance.Name) -> CGFloat {
        let rgb = resolved(color, in: appearance)
        return 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
    }

    func testSurfaceTokensInvertWithTheAppearanceAndKeepTheirOrdering() {
        // Surfaces are dark in dark and light in light, text the reverse. The charter's
        // relationships hold in both: chrome is the deepest, cards a step up, the tab strip
        // behind everything — in light that means chrome is *darker* than a card, not lighter —
        // and text always contrasts with the card it sits on.
        for token in [DS.Color.canvas, DS.Color.raised, DS.Color.overlay] {
            XCTAssertLessThan(luminance(token, in: .darkAqua), 0.35)
            XCTAssertGreaterThan(luminance(token, in: .aqua), 0.80)
        }
        for token in [NSColor.labelColor, NSColor.secondaryLabelColor] {
            XCTAssertGreaterThan(luminance(token, in: .darkAqua), 0.6)
            XCTAssertLessThan(luminance(token, in: .aqua), 0.4)
        }
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let chrome = luminance(DS.Color.canvas, in: appearance)
            let card = luminance(DS.Color.raised, in: appearance)
            XCTAssertNotEqual(chrome, card, "\(appearance.rawValue)")
            XCTAssertGreaterThan(abs(luminance(NSColor.labelColor, in: appearance) - card), 0.5, "\(appearance.rawValue)")
        }
    }

    func testAlphaVariantsOfATokenStayDynamic() {
        // Cards use `token.withAlphaComponent(...)`; if that resolved eagerly, half the app would
        // freeze in whichever appearance it launched under.
        let tinted = DS.Color.raised.withAlphaComponent(0.9)
        XCTAssertNotEqual(luminance(tinted, in: .darkAqua), luminance(tinted, in: .aqua))
    }

    func testDiffAndSyntaxColorsHaveALightCounterpart() {
        for token in [DiffBody.addedText, DiffBody.removedText, DiffBody.hunkColor] {
            XCTAssertLessThan(luminance(token, in: .aqua), luminance(token, in: .darkAqua), "light-mode text must be darker")
        }
    }

    func testBoundLayerColorsFollowTheWindowsAppearance() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        let view = NSView(frame: window.contentView!.bounds)
        window.contentView?.addSubview(view)
        window.appearance = NSAppearance(named: .darkAqua)
        view.bindLayerBackground(DS.Color.raised)
        let dark = view.layer?.backgroundColor
        window.appearance = NSAppearance(named: .aqua)
        // What `DS.Appearance` does when the app's appearance flips.
        DS.LayerBindings.reapplyAll()
        let light = view.layer?.backgroundColor
        XCTAssertNotNil(dark); XCTAssertNotNil(light)
        XCTAssertNotEqual(dark.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB)?.redComponent }, light.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB)?.redComponent })
    }

    /// 2026-10-27, the themes pass: a dark editor theme in light appearance puts Make's chrome in
    /// dark, and its bound colors resolved in the window's light one (white labels on light).
    func testBoundLayerColorsFollowTheViewsOwnAppearance() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        let parent = NSView(frame: window.contentView!.bounds)
        let view = NSView(frame: parent.bounds)
        parent.addSubview(view)
        window.contentView?.addSubview(parent)
        view.bindLayerBackground(DS.Color.raised)
        let light = view.layer?.backgroundColor
        parent.appearance = NSAppearance(named: .darkAqua)
        DS.LayerBindings.reapplyAll()
        let dark = view.layer?.backgroundColor
        func red(_ color: CGColor?) -> CGFloat? { color.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB)?.redComponent } }
        XCTAssertLessThan(red(dark) ?? 1, red(light) ?? 0, "the parent's dark appearance, not the window's light one")
    }

    /// Customization (session 3): the accent is one dynamic token, so a pick reaches every use
    /// at once; none of the picks is a status colour.
    func testTheAccentFollowsTheChoiceAndNeverLooksLikeAStatus() {
        let original = DS.Accent.chosen
        defer { DS.Accent.chosen = original }
        DS.Accent.chosen = .system
        XCTAssertEqual(resolved(DS.Color.accent, in: .darkAqua), resolved(.controlAccentColor, in: .darkAqua))
        DS.Accent.chosen = .teal
        XCTAssertEqual(resolved(DS.Color.accent, in: .aqua), resolved(DS.Accent.teal.swatch, in: .aqua))
        XCTAssertNotEqual(resolved(DS.Color.accent, in: .aqua), resolved(DS.Color.accent, in: .darkAqua))
        func hue(_ color: NSColor, _ appearance: NSAppearance.Name) -> CGFloat { resolved(color, in: appearance).hueComponent * 360 }
        for pick in DS.Accent.allCases where pick != .system && pick != .graphite {
            for status in [DS.Color.statusNeedsYou, DS.Color.statusFailed, DS.Color.statusVerified] {
                let apart = abs(hue(pick.swatch, .darkAqua) - hue(status, .darkAqua))
                XCTAssertGreaterThan(min(apart, 360 - apart), 25, "\(pick) is too close to a status")
            }
        }
    }

    /// The interface theme: tones from the theme's background, Side's ordering kept, and Side's
    /// own whenever Increase Contrast is on.
    func testSurfaceTintKeepsTheOrderingAndYieldsToIncreaseContrast() {
        let original = DS.Color.surfaceTint
        let contrast = DS.Color.increaseContrast
        defer { DS.Color.surfaceTint = original; DS.Color.increaseContrast = contrast }
        let oneDark = NSColor(srgbRed: 40 / 255, green: 44 / 255, blue: 52 / 255, alpha: 1)
        DS.Color.surfaceTint = (dark: DS.Color.SurfaceTint(background: oneDark, dark: true), light: DS.Color.SurfaceTint(background: .white, dark: false))
        DS.Color.increaseContrast = { false }
        XCTAssertEqual(resolved(DS.Color.canvas, in: .darkAqua).redComponent * 255, 40, accuracy: 0.5)
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            XCTAssertGreaterThan(luminance(DS.Color.raised, in: appearance), luminance(DS.Color.canvas, in: appearance), "\(appearance.rawValue)")
            XCTAssertNotEqual(luminance(DS.Color.overlay, in: appearance), luminance(DS.Color.raised, in: appearance))
        }
        DS.Color.increaseContrast = { true }
        XCTAssertEqual(resolved(DS.Color.canvas, in: .darkAqua).redComponent * 255, 11, accuracy: 0.5, "Side's high-contrast canvas")
    }

    /// Translucent background: stage fills go clear over the backdrop, the editor only when it's
    /// included, and Reduce Transparency or Increase Contrast give the solid surfaces back.
    func testTranslucencyClearsStageFillsAndYieldsToAccessibility() {
        let (on, editor) = (DS.Translucency.chosen, DS.Translucency.editorChosen)
        let (reduce, contrast) = (DS.Translucency.reduceTransparency, DS.Color.increaseContrast)
        defer {
            DS.Translucency.chosen = on; DS.Translucency.editorChosen = editor
            DS.Translucency.reduceTransparency = reduce; DS.Color.increaseContrast = contrast
        }
        DS.Translucency.reduceTransparency = { false }
        DS.Color.increaseContrast = { false }
        let stage = DS.Translucency.under(DS.Color.canvas)
        let editorFill = DS.Translucency.editor(DS.Color.canvas)

        DS.Translucency.chosen = false
        XCTAssertEqual(resolved(stage, in: .darkAqua), resolved(DS.Color.canvas, in: .darkAqua))
        XCTAssertEqual(resolved(editorFill, in: .darkAqua).alphaComponent, 1)

        DS.Translucency.chosen = true
        DS.Translucency.editorChosen = false
        XCTAssertEqual(resolved(stage, in: .darkAqua).alphaComponent, 0)
        XCTAssertEqual(resolved(editorFill, in: .aqua).alphaComponent, 1, "the editor stays solid unless included")
        XCTAssertEqual(resolved(DS.Translucency.tint, in: .darkAqua).alphaComponent, DS.Translucency.tintOpacity(dark: true), accuracy: 0.001)
        DS.Translucency.editorChosen = true
        XCTAssertEqual(resolved(editorFill, in: .aqua).alphaComponent, 0, "clear over the Editor stage's fill")
        XCTAssertEqual(resolved(DS.Translucency.editorStage(DS.Color.canvas), in: .aqua).alphaComponent, DS.Translucency.editorOpacity, accuracy: 0.001)

        DS.Translucency.reduceTransparency = { true }
        XCTAssertFalse(DS.Translucency.isOn)
        XCTAssertEqual(resolved(stage, in: .darkAqua).alphaComponent, 1)
        DS.Translucency.reduceTransparency = { false }
        DS.Color.increaseContrast = { true }
        XCTAssertFalse(DS.Translucency.includesEditor)
    }

    func testThePreferenceRoundTripsAndMapsToAnAppAppearance() {
        let original = DS.Appearance.preference
        defer { DS.Appearance.preference = original }
        DS.Appearance.preference = .light
        XCTAssertEqual(DS.Appearance.preference, .light)
        XCTAssertEqual(NSApp.appearance?.name, .aqua)
        DS.Appearance.preference = .dark
        XCTAssertEqual(NSApp.appearance?.name, .darkAqua)
        DS.Appearance.preference = .system
        XCTAssertNil(NSApp.appearance)
    }

    /// Dark, then Light: the change is told, and a layer bound to a token in a window ends up
    /// in the new appearance's colour. A guard: the case seen (Dark back to Match System left the
    /// window's background dark, 2026-11-23) didn't happen here.
    func testAChangeOfPreferenceIsToldAndLayersFollowIt() {
        let original = DS.Appearance.preference
        defer { DS.Appearance.preference = original }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = NSView(frame: window.contentView!.bounds)
        view.wantsLayer = true
        window.contentView!.addSubview(view)
        view.bindLayerBackground(DS.Color.canvas)
        func brightness() -> CGFloat { NSColor(cgColor: view.layer!.backgroundColor!)!.usingColorSpace(.sRGB)!.redComponent }

        DS.Appearance.preference = .dark
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertLessThan(brightness(), 0.3)

        var told = 0
        let observer = NotificationCenter.default.addObserver(forName: DS.Appearance.didChangeNotification, object: nil, queue: nil) { _ in told += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        DS.Appearance.preference = .light
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertGreaterThan(told, 0)
        XCTAssertGreaterThan(brightness(), 0.8)
    }

    func testTerminalColorsComeFromTheTokens() {
        let original = DS.Appearance.preference
        defer { DS.Appearance.preference = original }
        DS.Appearance.preference = .dark
        // In sRGB, as either terminal engine is handed them (not SwiftTerm's own color type).
        let darkBackground = TerminalViewController.resolved(DS.Color.raised)
        DS.Appearance.preference = .light
        let lightBackground = TerminalViewController.resolved(DS.Color.raised)
        XCTAssertLessThan(darkBackground.redComponent, 0.19)
        XCTAssertGreaterThan(lightBackground.redComponent, 0.91)
        // Sixteen ANSI colours either way, and the light set is darker where it matters: yellow.
        let dark = TerminalViewController.ansiPaletteColors(dark: true), light = TerminalViewController.ansiPaletteColors(dark: false)
        XCTAssertEqual(dark.count, 16)
        XCTAssertEqual(light.count, 16)
        XCTAssertLessThan(light[3].greenComponent, dark[3].greenComponent)
    }
}
