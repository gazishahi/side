import XCTest
@testable import Side
@testable import Heron

/// Direction 02 §3: stage pinning, window titles, and the revert-readiness of the floating bar.
@MainActor
final class ChromeTests: XCTestCase {
    typealias Stage = ShellViewController.Stage

    func testTheStageControlShowsPinsThenAttentionThenTheCurrentUnpinnedStage() {
        let cases: [(String, pinned: Set<Stage>, attention: Set<Stage>, dismissed: Set<Stage>, current: Stage?, expected: [Stage])] = [
            ("all pinned", Set(StagePins.pinnable), [], [], .make, [.make, .think, .review, .run]),
            ("agent preset", StagePins.Preset.agent.stages, [], [], .think, [.think, .review]),
            ("unpinned Run needs you", [.think], [.run], [], .think, [.think, .run]),
            ("visited attention leaves", [.think], [.run], [.run], .think, [.think]),
            ("current unpinned stays until you leave", [.think], [], [], .make, [.think, .make]),
            ("Tracks is never in the control", [.think], [], [], .tracks, [.think]),
        ]
        for c in cases {
            XCTAssertEqual(StagePins.visible(pinned: c.pinned, attention: c.attention, dismissed: c.dismissed, current: c.current), c.expected, c.0)
        }
    }

    /// Polish list (2026-11-03): a working agent's tab breathes the Working ring where its × goes;
    /// hovering swaps in the ×, and the ⌘ hints take the slot over both.
    func testAWorkingTabShowsTheRingUntilHoveredAndHintsTakeTheSlot() {
        let chip = TabChipView(frame: NSRect(x: 0, y: 0, width: 140, height: TabChipView.height))
        let close = TabCloseButton()
        chip.addSubview(close)
        chip.closeButton = close
        chip.isActive = true
        chip.updateCloseVisibility()
        XCTAssertFalse(close.isHidden, "the active tab offers its ×")
        chip.isWorking = true
        XCTAssertTrue(close.isHidden)
        XCTAssertEqual(chip.workingRing?.isHidden, false)
        XCTAssertEqual(chip.workingRing?.state, .working)
        XCTAssertTrue(chip.accessibilityLabel()?.contains("working") == true)
        chip.shortcutHint = "\u{2318}1"
        XCTAssertEqual(chip.workingRing?.isHidden, true, "the hint takes the slot")
        XCTAssertTrue(close.isHidden)
        chip.shortcutHint = nil
        chip.isWorking = false
        XCTAssertEqual(chip.workingRing?.isHidden, true)
        XCTAssertFalse(close.isHidden)
    }

    func testShortcutHintsNumberTheFirstEightAndTheLastTab() {
        XCTAssertEqual(TabShortcutHints.hint(at: 0, count: 3), Shortcuts.display("tabs.1"))
        XCTAssertEqual(TabShortcutHints.hint(at: 7, count: 12), Shortcuts.display("tabs.8"))
        XCTAssertNil(TabShortcutHints.hint(at: 9, count: 12), "tabs past the eighth have no shortcut but the last")
        XCTAssertEqual(TabShortcutHints.hint(at: 11, count: 12), Shortcuts.display("tabs.last"))
    }

    /// Claude Code turns a spinner in front of its title while it works: two changes in a moment
    /// is working, one (a turn ending) isn't, and a still glyph ends it.
    func testATerminalIsWorkingWhileItsTitleSpinnerTurns() {
        let terminal = TerminalViewController()
        terminal.noteTitleGlyph("\u{2733} Fix the parser")
        XCTAssertFalse(terminal.isProgramWorking, "one glyph is a still title")
        terminal.noteTitleGlyph("\u{2810} Fix the parser")
        XCTAssertTrue(terminal.isProgramWorking)
        terminal.noteTitleGlyph("\u{2802} Fix the parser")
        XCTAssertTrue(terminal.isProgramWorking)
        // No command running (the shell's own state): the check ends it at its next tick.
        let ended = expectation(description: "working ends")
        terminal.onWorkingChanged = { if !terminal.isProgramWorking { ended.fulfill() } }
        wait(for: [ended], timeout: 2)
    }

    func testAtLeastOneStageStaysPinnedAndPinsPersist() {
        let original = StagePins.defaults
        StagePins.defaults = throwawayDefaults()
        defer { StagePins.defaults = original }
        XCTAssertEqual(StagePins.pinned, Set(StagePins.pinnable), "default is everything")
        StagePins.pinned = [.think]
        StagePins.toggle(.think)
        XCTAssertEqual(StagePins.pinned, [.think], "the last pinned stage can't be unpinned")
        StagePins.toggle(.run)
        XCTAssertEqual(StagePins.pinned, [.think, .run])
    }

    func testClosingABackgroundTabNeverChangesWhichTabYouAreOn() {
        // (closed, active, countBefore) → active after. Tabs: [A, B, C, D], on C (index 2).
        let cases: [(Int, Int?, Int, Int?, String)] = [
            (3, 2, 4, 2, "close a tab to the right: stay on C"),
            (0, 2, 4, 1, "close a tab to the left: still C, one slot left"),
            (2, 2, 4, 2, "close C itself: its right neighbour D"),
            (3, 3, 4, 2, "close the last tab while on it: its left neighbour"),
            (0, 0, 1, nil, "close the only tab: nothing"),
        ]
        for (closed, active, count, expected, why) in cases {
            XCTAssertEqual(TabSelection.indexAfterClosing(closed, active: active, countBefore: count), expected, why)
        }
    }

    func testTheWindowTitleNamesTheFileOnlyInMakeAndNeverAPath() {
        let cases: [(Stage?, String?, String?, String?, String)] = [
            (.make, "App.swift", "Fix the race", "side", "App.swift · Fix the race"),
            (.think, "App.swift", "Fix the race", "side", "Fix the race"),
            (.make, nil, nil, "side", "side"),
            (.review, nil, nil, nil, "Side"),
        ]
        for (stage, file, track, project, expected) in cases {
            XCTAssertEqual(ShellViewController.windowTitle(stage: stage, fileName: file, track: track, project: project), expected)
        }
    }

    func testOnlyTheChromeHostKnowsWhereTheNavigationLives() throws {
        // Revert-readiness (§3.0): reverting the trial is a default change plus deleting one
        // branch, which only holds while no navigation component references the placement.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("SIDE")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        let referencing = try files.filter { try String(contentsOf: $0, encoding: .utf8).contains("floatingBar") }.map(\.lastPathComponent)
        XCTAssertEqual(Set(referencing), ["ChromeHost.swift"])
        XCTAssertEqual(ChromePlacement(rawValue: "topRow"), .topRow)
    }
}

/// 2026-09-30 audit, UX-8: text size reached only the four stages that restyle themselves;
/// Settings, Library, the debugger and the chrome kept the size they were built at.
@MainActor
final class TextScaleFollowerTests: XCTestCase {
    func testTextSizeReachesViewsThatDontRestyleThemselves() {
        TextScaleFollower.start()
        let original = DS.Text.Scale.current
        DS.Text.Scale.current = .standard
        defer { DS.Text.Scale.current = original }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = content
        let label = NSTextField(labelWithString: "Providers")
        label.font = .systemFont(ofSize: 13)
        let table = NSTableView()
        table.rowHeight = 20
        let ownStyle = NSView()
        let sample = NSTextField(labelWithString: "Sample")
        sample.font = .systemFont(ofSize: 13)
        ownStyle.addSubview(sample)
        TextScaleFollower.exempt(ownStyle)
        let detached = NSTextField(labelWithString: "A hidden stage's label")
        detached.font = .systemFont(ofSize: 11)
        TextScaleFollower.addDetachedViews { [detached] in [detached] }
        for view in [label, table, ownStyle] { content.addSubview(view) }

        DS.Text.Scale.current = .larger  // 1.3
        XCTAssertEqual(label.font?.pointSize, 17, "13 × 1.3, to the half point")
        XCTAssertEqual(table.rowHeight, 26)
        XCTAssertEqual(detached.font?.pointSize, 14.5, "views out of a window follow too")
        XCTAssertEqual(sample.font?.pointSize, 13, "a view that restyles itself isn't scaled twice")

        DS.Text.Scale.current = .standard
        XCTAssertEqual(label.font?.pointSize, 13)
        XCTAssertEqual(table.rowHeight, 20)
    }
}

/// 2026-09-30 audit, UX-9: Increase Contrast was ignored; surfaces sat about 1.1:1 apart.
@MainActor
final class IncreaseContrastTests: XCTestCase {
    private func resolved(_ color: NSColor, _ name: NSAppearance.Name) -> NSColor {
        // High-contrast appearances can't be made by name; Increase Contrast is what turns them on.
        let high = name == .accessibilityHighContrastDarkAqua || name == .accessibilityHighContrastAqua
        let saved = DS.Color.increaseContrast
        DS.Color.increaseContrast = { high }
        defer { DS.Color.increaseContrast = saved }
        let base: NSAppearance.Name = (name == .accessibilityHighContrastDarkAqua || name == .darkAqua) ? .darkAqua : .aqua
        var out = color
        NSAppearance(named: base)!.performAsCurrentDrawingAppearance { out = color.usingColorSpace(.sRGB) ?? color }
        return out
    }

    private func luminance(_ c: NSColor) -> CGFloat {
        func channel(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(c.redComponent) + 0.7152 * channel(c.greenComponent) + 0.0722 * channel(c.blueComponent)
    }

    private func contrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    func testHighContrastSeparatesSurfacesAndStrengthensLines() {
        for (normal, high) in [(NSAppearance.Name.darkAqua, NSAppearance.Name.accessibilityHighContrastDarkAqua), (.aqua, .accessibilityHighContrastAqua)] {
            let before = contrast(resolved(DS.Color.canvas, normal), resolved(DS.Color.raised, normal))
            let after = contrast(resolved(DS.Color.canvas, high), resolved(DS.Color.raised, high))
            XCTAssertGreaterThan(after, before + 0.1, "\(high.rawValue): canvas against raised, \(before) → \(after)")
            print(String(format: "CONTRAST %@ canvas/raised %.2f -> %.2f", high.rawValue, before, after))
            XCTAssertGreaterThan(resolved(DS.Color.hairline, high).alphaComponent, resolved(DS.Color.hairline, normal).alphaComponent * 3)
        }
    }
}
