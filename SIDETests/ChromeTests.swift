import XCTest
@testable import Side
@testable import SideAgents

/// Direction 02 §3: stage pinning, window titles, and the revert-readiness of the floating bar.
@MainActor
final class ChromeTests: XCTestCase {
    /// 2026-11-21, the owner: the activity list's × was a teardrop. The button kept a push
    /// button's alignment insets (an 18.5 × 20.5 frame), and its fill grew past it by autoresizing.
    func testACircleButtonsFillIsTheButton() {
        let button = DS.CircleButton(symbol: "xmark", diameter: 18, label: "Dismiss")
        let host = NSStackView(views: [button])
        host.frame = NSRect(x: 0, y: 0, width: 60, height: 30)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(button.frame.size, NSSize(width: 18, height: 18))
        XCTAssertEqual(button.fillFrameForTesting, button.bounds)
    }

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

    /// Polish list (2026-11-03, 11-04): a tab shows its icon before its title, a working agent's
    /// tab shows the working indicator, and the ⌘ hints fade in over the ×.
    func testAWorkingTabShowsItsIndicatorAndHintsTakeTheSlot() {
        let chip = TabChipView(frame: NSRect(x: 0, y: 0, width: 140, height: TabChipView.height))
        chip.wantsLayer = true
        let close = TabCloseButton()
        chip.addSubview(close)
        chip.closeButton = close
        chip.title = "a-long-file-name.swift"
        let plain = chip.intrinsicContentSize.width
        chip.dragIcon = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
        XCTAssertGreaterThan(chip.intrinsicContentSize.width, plain, "room for the icon")
        chip.isActive = true
        chip.updateCloseVisibility()
        XCTAssertFalse(close.isHidden, "the active tab offers its ×")
        chip.isWorking = true
        XCTAssertFalse(close.isHidden, "the indicator isn't in the ×'s slot")
        // The shimmer follows the title, so it comes once the title is drawn.
        let rep = chip.bitmapImageRepForCachingDisplay(in: chip.bounds)!
        chip.cacheDisplay(in: chip.bounds, to: rep)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(chip.isShowingWorkingLightForTesting, "the title shimmers")
        XCTAssertTrue(chip.accessibilityLabel()?.contains("working") == true)
        chip.shortcutHint = "\u{2318}1"
        XCTAssertTrue(chip.isShowingHintForTesting, "the hint fades in over the slot")
        chip.shortcutHint = nil
        chip.isWorking = false
        XCTAssertFalse(chip.isShowingWorkingLightForTesting)
    }

    /// Set A (the owner, 2026-11-04): Side's own stage glyphs, an outline at rest and solid when
    /// selected; every stage has one, and anything else is still an SF Symbol.
    func testEveryStageHasItsGlyphInBothStates() throws {
        func ink(_ image: NSImage) -> Int {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                       isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32))
            NSGraphicsContext.restoreGraphicsState()
            var count = 0
            for x in 0..<32 { for y in 0..<32 where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { count += 1 } }
            return count
        }
        for stage in ShellViewController.Stage.allCases {
            XCTAssertTrue(stage.symbol.hasPrefix(DS.Glyph.prefix), "\(stage.title) uses Side's glyph")
            let rest = try XCTUnwrap(DS.Glyph.image(named: stage.symbol, pointSize: 32))
            let selected = try XCTUnwrap(DS.Glyph.image(named: stage.symbol, selected: true, pointSize: 32))
            XCTAssertTrue(rest.isTemplate && selected.isTemplate, "tinted like the symbols they replace")
            let restInk = ink(rest), selectedInk = ink(selected)
            XCTAssertGreaterThan(restInk, 40, "\(stage.title) draws at rest")
            XCTAssertGreaterThan(selectedInk, restInk, "\(stage.title) is solid when selected")
        }
        XCTAssertNotNil(DS.Glyph.image(named: "magnifyingglass"), "other names are SF Symbols")
    }

    /// The project switcher (the owner, 2026-11-04): a query matches its characters in order, as
    /// Quick Open does; a project remembers when it was opened, and putting it away keeps it listed.
    func testTheSwitcherMatchesNamesAndKeepsPutAwayProjects() throws {
        XCTAssertTrue(ProjectSwitcherModel.matches("wb", "webapp"))
        XCTAssertTrue(ProjectSwitcherModel.matches("", "anything"))
        XCTAssertTrue(ProjectSwitcherModel.matches("Web App", "webapp"), "case and spaces don't count")
        XCTAssertFalse(ProjectSwitcherModel.matches("bw", "webapp"), "in order")
        let spaces = ProjectSpaces(store: throwawayDefaults())
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("switcher-\(UUID().uuidString)")
        spaces.space(for: folder)
        XCTAssertNil(spaces.spaces.first?.lastOpenedAt)
        spaces.touch(folder)
        XCTAssertNotNil(spaces.spaces.first?.lastOpenedAt)
        spaces.putAway(folder)
        XCTAssertEqual(spaces.spaces.map(\.path), [folder.standardizedFileURL.path], "put away, not removed")
        XCTAssertFalse(spaces.isHeld(folder))
        XCTAssertEqual(ProjectSwitcherModel.limit, 9, "as many as ⌃1–9 reach")
    }

    func testShortcutHintsNumberTheFirstEightAndTheLastTab() {
        XCTAssertEqual(TabShortcutHints.hint(at: 0, count: 3), Shortcuts.display("tabs.1"))
        XCTAssertEqual(TabShortcutHints.hint(at: 7, count: 12), Shortcuts.display("tabs.8"))
        XCTAssertNil(TabShortcutHints.hint(at: 9, count: 12), "tabs past the eighth have no shortcut but the last")
        XCTAssertEqual(TabShortcutHints.hint(at: 11, count: 12), Shortcuts.display("tabs.last"))
    }

    /// Claude Code's title starts with ✳ while it waits and a half-circle (◐ ◓ ◑ ◒) while it
    /// works, changing only every few seconds (recorded 2026-11-04): the glyph is the state.
    func testATerminalIsWorkingWhileItsTitleShowsASpinner() {
        let terminal = TerminalViewController()
        var changes = 0
        terminal.onWorkingChanged = { changes += 1 }
        terminal.noteTitleGlyph("\u{2733} Claude Code")
        XCTAssertFalse(terminal.isProgramWorking, "✳ is waiting")
        terminal.noteTitleGlyph("\u{25D0} Slow counting from one to five")
        XCTAssertTrue(terminal.isProgramWorking)
        terminal.noteTitleGlyph("\u{25D1} Slow counting from one to five")
        XCTAssertTrue(terminal.isProgramWorking, "still working seconds later, the glyph turned once")
        terminal.noteTitleGlyph("\u{2733} Slow counting from one to five")
        XCTAssertFalse(terminal.isProgramWorking)
        terminal.noteTitleGlyph("\u{2802} npm install")
        XCTAssertTrue(terminal.isProgramWorking, "braille spinners count")
        terminal.noteTitleGlyph("vim main.swift")
        XCTAssertFalse(terminal.isProgramWorking)
        XCTAssertEqual(changes, 4)
    }

    /// The sweep after the visual audit (2026-11-04).
    func testSameNamedTerminalTabsAreNumbered() {
        XCTAssertEqual(RunWorkspaceViewController.distinctTitles(["app", "app", "vim", "app"]), ["app", "app 2", "vim", "app 3"])
    }

    func testTheStatusRowShowsAFolderOnlyAwayFromTheRoot() {
        XCTAssertEqual(RunWorkspaceViewController.statusPath("/p/app", root: "/p/app"), "")
        XCTAssertEqual(RunWorkspaceViewController.statusPath("/p/app/Sources/App", root: "/p/app/"), "Sources/App")
        XCTAssertEqual(RunWorkspaceViewController.statusPath("/elsewhere", root: "/p/app"), "/elsewhere")
    }

    func testPaletteCommandsHaveTheirOwnSymbols() {
        XCTAssertEqual(MakeWorkspaceViewController.commandSymbol("Go to Terminal"), ShellViewController.Stage.run.symbol)
        XCTAssertEqual(MakeWorkspaceViewController.commandSymbol("Quick Open"), "doc.text.magnifyingglass")
        XCTAssertEqual(MakeWorkspaceViewController.commandSymbol("Something new"), "command")
    }

    func testTheActivityPillSaysTheMostPressingThing() {
        typealias Item = ActivityCenter.Item
        let working = Item(id: "a", state: .working, title: "Claude Code", place: "app · tab", program: "claude", target: .update)
        let finished = Item(id: "b", state: .finished, title: "Codex", place: "app · tab 2", program: "codex", target: .update)
        XCTAssertEqual(ActivityPill.summary([working]), "Claude Code working")
        XCTAssertEqual(ActivityPill.summary([finished, working]), "Codex finished")
        XCTAssertEqual(ActivityCenter.programName("/usr/local/bin/claude"), "Claude Code")
        XCTAssertLessThan(Item.State.needsYou.rank, Item.State.working.rank)
    }

    /// The project chip shows a repository's own logo: a web project's favicon, an Icon Composer
    /// bundle (as Side's own repository has), and none for a folder without one.
    func testProjectLogosAreFoundWhereRepositoriesKeepThem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("logos-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let svg = ##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 8 8"><rect width="8" height="8" fill="#123456"/></svg>"##
        let web = root.appendingPathComponent("web/public")
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        try svg.write(to: web.appendingPathComponent("favicon.svg"), atomically: true, encoding: .utf8)
        XCTAssertNotNil(ProjectLogo.find(in: root.appendingPathComponent("web")))
        let app = root.appendingPathComponent("app/AppIcon.icon/Assets")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try svg.write(to: app.appendingPathComponent("mark.svg"), atomically: true, encoding: .utf8)
        let manifest = #"{"fill":{"solid":"srgb:1,1,1,1"},"groups":[{"layers":[{"image-name":"mark.svg","name":"mark"}]}]}"#
        try manifest.write(to: root.appendingPathComponent("app/AppIcon.icon/icon.json"), atomically: true, encoding: .utf8)
        XCTAssertNotNil(ProjectLogo.find(in: root.appendingPathComponent("app")))
        let plain = root.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        XCTAssertNil(ProjectLogo.find(in: plain))
    }

    /// Where Sill and Khidma keep theirs (2026-11-05): a built `.icns` in Resources/, an Expo
    /// app's icon named in its app.json, and a web package's inside a monorepo.
    func testProjectLogosAreFoundInIcnsExpoAndMonorepoPackages() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("logos-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let png = try XCTUnwrap(NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in NSColor.red.setFill(); rect.fill(); return true }
            .tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:]))
        func write(_ path: String, _ data: Data) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        try write("expo/assets/icon.png", png)
        try write("expo/app.json", Data(#"{"expo":{"name":"x","icon":"./assets/icon.png"}}"#.utf8))
        XCTAssertNotNil(ProjectLogo.find(in: root.appendingPathComponent("expo")))
        try write("mono/packages/frontend/public/apple-touch-icon.png", png)
        try write("mono/package.json", Data("{}".utf8))
        XCTAssertNotNil(ProjectLogo.find(in: root.appendingPathComponent("mono")))
        try write("mac/Sources/main.swift", Data())
        let iconset = root.appendingPathComponent("mac/Resources")
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        let built = Process()
        built.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        try write("mac/source.png", png)
        built.arguments = ["-s", "format", "icns", root.appendingPathComponent("mac/source.png").path, "--out", iconset.appendingPathComponent("AppIcon.icns").path]
        built.standardOutput = FileHandle.nullDevice
        try built.run()
        built.waitUntilExit()
        try FileManager.default.removeItem(at: root.appendingPathComponent("mac/source.png"))
        XCTAssertNotNil(ProjectLogo.find(in: root.appendingPathComponent("mac")))
    }

    /// Project switching (prototype, 2026-11-04): every project gets a symbol no other has, the
    /// order wraps for swipes, a choice of color or symbol sticks, and closing takes it out.
    /// ⌃⇥ with many projects: full tiles while they fit, then smaller, never under the minimum
    /// (past it the row slides instead).
    func testTheCycleStripShrinksItsTilesBeforeSliding() {
        let content: CGFloat = ProjectCycleStrip.maxWidth - ProjectCycleStrip.inset * 2
        XCTAssertEqual(ProjectCycleStrip.tileWidth(count: 6, content: content), ProjectCycleStrip.tileWidth)
        let ten = ProjectCycleStrip.tileWidth(count: 10, content: content)
        XCTAssertLessThan(ten, ProjectCycleStrip.tileWidth)
        XCTAssertLessThanOrEqual(ten * 10 + DS.Spacing.xs * 9, content, "ten fit whole")
        XCTAssertEqual(ProjectCycleStrip.tileWidth(count: 30, content: content), ProjectCycleStrip.minimumTileWidth)
        XCTAssertEqual(ProjectCycleStrip.tileWidth(count: 6, content: 300), ProjectCycleStrip.minimumTileWidth, "a narrow window: the smallest, sliding")
    }

    func testProjectSpacesKeepTheirOrderSymbolsAndColors() {
        let defaults = throwawayDefaults()
        let spaces = ProjectSpaces(store: defaults)
        let a = URL(fileURLWithPath: "/tmp/side-spaces/a"), b = URL(fileURLWithPath: "/tmp/side-spaces/b"), c = URL(fileURLWithPath: "/tmp/side-spaces/c/")
        let first = spaces.space(for: a), second = spaces.space(for: b), third = spaces.space(for: c)
        XCTAssertEqual(Set([first.symbol, second.symbol, third.symbol]).count, 3, "shape tells them apart, not only color")
        XCTAssertEqual(spaces.space(for: a), first, "seen again, the same space")
        XCTAssertEqual(spaces.neighbor(of: c, offset: 1)?.path, first.path, "the order wraps")
        XCTAssertEqual(spaces.neighbor(of: a, offset: -1)?.path, third.path)
        spaces.set(symbol: "leaf.fill", colorIndex: 7, for: b)
        let reread = ProjectSpaces(store: defaults)
        XCTAssertEqual(reread.space(for: b).symbol, "leaf.fill")
        XCTAssertEqual(reread.space(for: b).colorIndex, 7)
        reread.remove(b)
        XCTAssertEqual(reread.spaces.map(\.path), [first.path, third.path])
        // The switcher shows nine, and the current one past them.
        for n in 0..<12 { reread.space(for: URL(fileURLWithPath: "/tmp/side-spaces/more-\(n)")) }
        let late = URL(fileURLWithPath: "/tmp/side-spaces/more-11")
        let shown = reread.shown(current: late)
        XCTAssertEqual(shown.count, 10)
        XCTAssertEqual(shown.last?.path, late.path)
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
        let label = NSTextField(labelWithString: "Agents")
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

    /// A long tab title shows the same letters selected or not: cut where the selected (medium)
    /// title would be, whatever its weight (the owner, 2026-11-12).
    @MainActor
    func testATabTitleKeepsItsLettersWhenSelected() {
        let title = "Refactoring the session registry so every terminal reports its state"
        let width: CGFloat = 200
        let regular = TabChipView.cut(TabChipView.label(title: title, detail: "", attributes: [.font: DS.Text.body(.regular)]), title: title, detail: "", width: width)
        let medium = TabChipView.cut(TabChipView.label(title: title, detail: "", attributes: [.font: DS.Text.body(.medium)]), title: title, detail: "", width: width)
        XCTAssertEqual(regular.string, medium.string)
        XCTAssertTrue(regular.string.hasSuffix("\u{2026}"))
        XCTAssertLessThanOrEqual(medium.size().width, width)
        let short = TabChipView.label(title: "zsh", detail: "", attributes: [.font: DS.Text.body(.regular)])
        XCTAssertTrue(TabChipView.cut(short, title: "zsh", detail: "", width: width) === short, "a title that fits is left whole")
    }
}
