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
