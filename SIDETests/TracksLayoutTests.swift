import XCTest
@testable import SideAgents
@testable import Side

/// Tracks (SIDE_RFC_FIND_REVIEW_TRACKS.md, T1): the switcher on the track pill, and the stage's
/// list with the selected track's detail beside it.
@MainActor
final class TracksLayoutTests: XCTestCase {
    // MARK: The switcher

    private func row(_ title: String, _ key: String, ago: TimeInterval, current: Bool = false, state: DS.StatusState = .idle) -> TrackPill.Row {
        var row = TrackPill.Row(key: key, title: title, detail: key, state: state, isCurrent: current)
        row.lastActive = Date().addingTimeInterval(-ago)
        return row
    }

    private func switcher() -> TrackSwitcherViewController {
        var snapshot = TrackPill.Snapshot.empty
        snapshot.needsYou = [row("Fix the login race", "login", ago: 900, state: .needsYou)]
        snapshot.active = [row("Old refactor", "refactor", ago: 86_400), row("Current work", "current", ago: 10, current: true), row("API cleanup", "api", ago: 3_600)]
        snapshot.parked = [row("Parked idea", "idea", ago: 400_000)]
        let controller = TrackSwitcherViewController(snapshot: snapshot)
        controller.loadViewIfNeeded()
        return controller
    }

    private func titles(_ items: [TrackSwitcherViewController.Item]) -> [String] {
        items.map { item in
            switch item {
            case .track(let row): return row.title
            case .newTrack(let name): return "+ \(name)"
            }
        }
    }

    func testNeedsYouFirstThenMostRecentAndTheFirstOtherTrackReady() {
        let controller = switcher()
        XCTAssertEqual(titles(controller.items), ["Fix the login race", "Current work", "API cleanup", "Old refactor", "Parked idea"])
        XCTAssertEqual(controller.highlighted, 0, "the first track that isn't the current one is ready for Return")
    }

    func testTypingFiltersAndOffersANewTrack() {
        let controller = switcher()
        controller.setFilterForTesting("clean")
        XCTAssertEqual(titles(controller.items), ["API cleanup", "+ clean"], "a match, and the words as a new track")
        controller.setFilterForTesting("api cleanup")
        XCTAssertEqual(titles(controller.items), ["API cleanup"], "an exact name offers nothing new")
        controller.setFilterForTesting("write the docs")
        XCTAssertEqual(titles(controller.items), ["+ write the docs"])
        var named: String?
        controller.onNewTrackNamed = { named = $0 }
        controller.activateForTesting()
        XCTAssertEqual(named, "write the docs")
    }

    func testArrowsMoveAndReturnSwitches() {
        let controller = switcher()
        var chosen: TrackPill.Row?
        controller.onSelect = { chosen = $0 }
        controller.moveForTesting(2)
        controller.activateForTesting()
        XCTAssertEqual(chosen?.key, "api")
        controller.moveForTesting(99)
        XCTAssertEqual(controller.highlighted, controller.items.count - 1, "stops at the end")
    }

    // MARK: The stage

    private final class Box: @unchecked Sendable { var id: UUID? }

    func testTheSelectedTrackShowsBesideTheList() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tracks-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { _ = GitPaths.runGit(args, cwd: root.path) }
        try "hi\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = GitPaths.runGit(["add", "."], cwd: root.path)
        _ = GitPaths.runGit(["commit", "-q", "-m", "base"], cwd: root.path)
        let context = ProjectContextRegistry.shared.acquire(projectRoot: root)
        defer {
            for track in context.trackStore.tracks {
                if let path = track.workingDirectoryPath { _ = GitPaths.runGit(["worktree", "remove", "--force", path], cwd: root.path) }
            }
            ProjectContextRegistry.shared.release(projectRoot: root)
            try? FileManager.default.removeItem(at: root)
        }
        for intent in ["First line of work", "Second line of work"] {
            let done = expectation(description: intent)
            context.trackStore.createTrack(intent: intent) { _ in done.fulfill() }
            wait(for: [done], timeout: 30)
        }

        let tracks = TracksWorkspaceViewController()
        tracks.configure(with: context.trackStore, runnerManager: context.runnerManager, sessionStore: context.sessionStore)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = tracks
        // Setting the controller sizes the window to its view; the stage needs room for the pane.
        window.setContentSize(NSSize(width: 1100, height: 700))
        window.orderFront(nil)
        defer { window.close() }
        Budgets.settle(0.5)

        let current = try XCTUnwrap(context.trackStore.tracks.first { $0.status == .active })
        XCTAssertEqual(tracks.selectedTrackForTesting?.id, current.id, "the current track is selected to begin with")
        XCTAssertTrue(tracks.detailForTesting.shownText.contains(current.intent), "\(tracks.detailForTesting.shownText) / \(current.intent)")
        XCTAssertTrue(tracks.detailForTesting.shownText.contains { $0.contains("the current track") })

        let other = try XCTUnwrap(context.trackStore.tracks.first { $0.id != current.id })
        tracks.selectForTesting(other)
        XCTAssertTrue(tracks.detailForTesting.shownText.contains(other.intent))
        XCTAssertTrue(tracks.detailForTesting.shownText.contains { $0.hasPrefix("Agent:") }, "\(tracks.detailForTesting.shownText)")

        // ↑ and ↓ move through the list.
        let down = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                  context: nil, characters: String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)),
                                                  charactersIgnoringModifiers: String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)), isARepeat: false, keyCode: 125))
        let before = tracks.selectedTrackForTesting?.id
        XCTAssertTrue(tracks.keyForTesting(down), "\(down.specialKey.map { "\($0.rawValue)" } ?? "none")")
        let up = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                context: nil, characters: String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)),
                                                charactersIgnoringModifiers: String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)), isARepeat: false, keyCode: 126))
        _ = tracks.keyForTesting(up)
        XCTAssertNotNil(before)
        XCTAssertEqual(context.trackStore.tracks.count, 2)
    }
}
