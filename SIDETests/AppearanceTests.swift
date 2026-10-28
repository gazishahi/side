import XCTest
@testable import Side
@testable import Heron

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

    func testTerminalColorsComeFromTheTokens() {
        let original = DS.Appearance.preference
        defer { DS.Appearance.preference = original }
        DS.Appearance.preference = .dark
        let darkBackground = TerminalViewController.terminalColor(DS.Color.raised)
        DS.Appearance.preference = .light
        let lightBackground = TerminalViewController.terminalColor(DS.Color.raised)
        XCTAssertLessThan(darkBackground.red, 12_000)
        XCTAssertGreaterThan(lightBackground.red, 60_000)
        // Sixteen ANSI colours either way, and the light set is darker where it matters: yellow.
        XCTAssertEqual(TerminalViewController.ansiPalette(dark: true).count, 16)
        XCTAssertEqual(TerminalViewController.ansiPalette(dark: false).count, 16)
        XCTAssertLessThan(TerminalViewController.ansiPalette(dark: false)[3].green, TerminalViewController.ansiPalette(dark: true)[3].green)
    }
}
