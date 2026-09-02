import XCTest
@testable import Side

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

    func testSurfaceTokensInvertWithTheAppearance() {
        for token in [DS.Color.chrome, DS.Color.tabStrip, DS.Color.bg1, DS.Color.bg2, DS.Color.bg3, DS.Color.bg4, DS.Color.terminalBackground] {
            XCTAssertLessThan(luminance(token, in: .darkAqua), 0.35)
            XCTAssertGreaterThan(luminance(token, in: .aqua), 0.80)
        }
        for token in [DS.Color.text, DS.Color.textStrong, DS.Color.textSecondary, DS.Color.terminalForeground] {
            XCTAssertGreaterThan(luminance(token, in: .darkAqua), 0.6)
            XCTAssertLessThan(luminance(token, in: .aqua), 0.4)
        }
    }

    func testTheSurfaceOrderingHoldsInBothAppearances() {
        // The charter's relationships: chrome is the deepest, cards a step up, the tab strip
        // behind everything. In light that means chrome is *darker* than a card, not lighter.
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let chrome = luminance(DS.Color.chrome, in: appearance)
            let card = luminance(DS.Color.bg1, in: appearance)
            XCTAssertNotEqual(chrome, card, "\(appearance.rawValue)")
            // Text always contrasts with the card it sits on.
            XCTAssertGreaterThan(abs(luminance(DS.Color.text, in: appearance) - card), 0.5, "\(appearance.rawValue)")
        }
    }

    func testAlphaVariantsOfATokenStayDynamic() {
        // Cards use `token.withAlphaComponent(...)`; if that resolved eagerly, half the app would
        // freeze in whichever appearance it launched under.
        let tinted = DS.Color.bg1.withAlphaComponent(0.9)
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
        view.bindLayerBackground(DS.Color.bg1)
        let dark = view.layer?.backgroundColor
        window.appearance = NSAppearance(named: .aqua)
        // What `DS.Appearance` does when the app's appearance flips.
        DS.LayerBindings.reapplyAll()
        let light = view.layer?.backgroundColor
        XCTAssertNotNil(dark); XCTAssertNotNil(light)
        XCTAssertNotEqual(dark.map { NSColor(cgColor: $0)?.whiteComponent }, light.map { NSColor(cgColor: $0)?.whiteComponent })
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
        let darkBackground = TerminalViewController.terminalColor(DS.Color.terminalBackground)
        DS.Appearance.preference = .light
        let lightBackground = TerminalViewController.terminalColor(DS.Color.terminalBackground)
        XCTAssertLessThan(darkBackground.red, 5_000)
        XCTAssertGreaterThan(lightBackground.red, 60_000)
        // Sixteen ANSI colours either way, and the light set is darker where it matters: yellow.
        XCTAssertEqual(TerminalViewController.ansiPalette(dark: true).count, 16)
        XCTAssertEqual(TerminalViewController.ansiPalette(dark: false).count, 16)
        XCTAssertLessThan(TerminalViewController.ansiPalette(dark: false)[3].green, TerminalViewController.ansiPalette(dark: true)[3].green)
    }
}
