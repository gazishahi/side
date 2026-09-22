import XCTest
@testable import Side

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
        StagePins.defaults = UserDefaults(suiteName: "ChromeTests-\(UUID().uuidString)")!
        defer { StagePins.defaults = original }
        XCTAssertEqual(StagePins.pinned, Set(StagePins.pinnable), "default is everything")
        StagePins.pinned = [.think]
        StagePins.toggle(.think)
        XCTAssertEqual(StagePins.pinned, [.think], "the last pinned stage can't be unpinned")
        StagePins.toggle(.run)
        XCTAssertEqual(StagePins.pinned, [.think, .run])
    }

    func testTheWindowTitleNamesTheFileOnlyInMakeAndNeverAPath() {
        let cases: [(Stage?, String?, String?, String?, String)] = [
            (.make, "App.swift", "Fix the race", "side", "App.swift — Fix the race"),
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
