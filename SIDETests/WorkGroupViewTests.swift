import XCTest
@testable import Side

/// The tool-activity disclosure. Its layout has been wrong three separate ways — a tall empty
/// gap when collapsed, content overflowing onto the next message when expanded, and a header
/// that could be opened but never closed — and each time the only check was a screenshot, which
/// is both slow and ambiguous. These pin the geometry instead.
// AppKit views are main-actor; the whole class runs there.
@MainActor
final class WorkGroupViewTests: XCTestCase {

    private func makeGroup(lines: Int = 2) -> WorkGroupView {
        let group = WorkGroupView(startedAt: Date())
        for index in 0..<lines {
            let label = NSTextField(labelWithString: "→ read_file (path: src/file\(index).swift)")
            label.translatesAutoresizingMaskIntoConstraints = false
            group.addLine(label, isStep: true, at: Date())
        }
        // A definite width, as the transcript gives it.
        group.widthAnchor.constraint(equalToConstant: 600).isActive = true
        group.layoutSubtreeIfNeeded()
        return group
    }

    func testCollapsedIsHeaderHeightWithNoGap() {
        let group = makeGroup()
        let height = group.fittingSize.height
        // The gap bug: a hidden view positioned by explicit constraints still contributed its
        // full intrinsic height, so this was header + every tool line even while collapsed.
        XCTAssertLessThan(height, 30, "collapsed group is \(height)pt tall — the gap is back")
        XCTAssertGreaterThan(height, 8, "collapsed group has no header")
    }

    func testExpandingAddsRoomForEveryLine() {
        let group = makeGroup(lines: 3)
        let collapsed = group.fittingSize.height
        group.toggle()
        group.layoutSubtreeIfNeeded()
        let expanded = group.fittingSize.height
        // The overflow bug: pinning the content to `fittingSize` under-measured it, so the
        // expanded group was shorter than its own content and drew over the next message.
        XCTAssertGreaterThan(expanded, collapsed + 30, "expanded \(expanded) vs collapsed \(collapsed)")
    }

    func testCollapsingReturnsToTheOriginalHeight() {
        let group = makeGroup()
        let original = group.fittingSize.height
        group.toggle()
        group.layoutSubtreeIfNeeded()
        group.toggle()
        group.layoutSubtreeIfNeeded()
        XCTAssertEqual(group.fittingSize.height, original, accuracy: 1)
    }

    func testTheHeaderRegionIsAtHighYBecauseTheViewIsUnflipped() {
        let group = makeGroup()
        group.frame = NSRect(x: 0, y: 0, width: 600, height: group.fittingSize.height)
        group.layoutSubtreeIfNeeded()
        XCTAssertFalse(group.isFlipped, "the hit test's sign depends on this")
        // Top of an unflipped view is *high* y. Getting this backwards is what made the group
        // openable but not closable.
        XCTAssertTrue(group.isInHeader(NSPoint(x: 100, y: group.bounds.maxY - 2)))
    }

    func testAPointBelowTheHeaderIsNotTheHeader() {
        let group = makeGroup(lines: 3)
        group.toggle()
        group.layoutSubtreeIfNeeded()
        group.frame = NSRect(x: 0, y: 0, width: 600, height: group.fittingSize.height)
        group.layoutSubtreeIfNeeded()
        // Content clicks must fall through so a tool line's file links stay reachable.
        XCTAssertFalse(group.isInHeader(NSPoint(x: 100, y: 2)))
    }

    func testHitTestClaimsTheHeaderSoTheLabelCannotSwallowIt() {
        let group = makeGroup()
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        host.addSubview(group)
        group.frame = NSRect(x: 0, y: 0, width: 600, height: group.fittingSize.height)
        group.layoutSubtreeIfNeeded()
        // NSTextField hit-tests to itself; without the override the title label absorbed every
        // press and `mouseDown` was never called at all.
        let hit = group.hitTest(NSPoint(x: 100, y: group.frame.maxY - 2))
        XCTAssertTrue(hit === group, "header click would be swallowed by \(String(describing: hit))")
    }

    func testTheElapsedTimeIsAlwaysStated() {
        let started = Date().addingTimeInterval(-200)
        let group = WorkGroupView(startedAt: started)
        group.addLine(NSTextField(labelWithString: "→ run_task"), isStep: true, at: started.addingTimeInterval(95))
        group.finish()
        let label = group.accessibilityLabel() ?? ""
        // It used to be hidden below one second, which is most of them.
        XCTAssertTrue(label.contains("1m 35s"), label)
        XCTAssertTrue(label.contains("Worked for"), label)
    }

    func testTheDurationIsMeasuredToTheGroupsOwnLastLine() {
        // The 676-minute bug: renderFull finished every group at the timestamp of the
        // *conversation's* final entry, so a two-step group from last night reported the age of
        // the whole conversation. A group measures its own span or nothing.
        let started = Date().addingTimeInterval(-40_000)
        let group = WorkGroupView(startedAt: started)
        group.addLine(NSTextField(labelWithString: "→ read_file"), isStep: true, at: started.addingTimeInterval(3))
        group.addLine(NSTextField(labelWithString: "✓ read_file"), isStep: false, at: started.addingTimeInterval(9))
        group.finish()
        let reported = group.accessibilityLabel() ?? ""
        XCTAssertTrue(reported.contains("9s"), reported)
        XCTAssertFalse(reported.contains("m "), reported)
    }

    func testALaterLineNeverMovesTheDurationBackwards() {
        let started = Date()
        let group = WorkGroupView(startedAt: started)
        group.addLine(NSTextField(labelWithString: "b"), isStep: true, at: started.addingTimeInterval(12))
        // Out-of-order arrival must not shrink the measured span.
        group.addLine(NSTextField(labelWithString: "a"), isStep: true, at: started.addingTimeInterval(4))
        group.finish()
        XCTAssertTrue((group.accessibilityLabel() ?? "").contains("12s"), group.accessibilityLabel() ?? "")
    }

    func testAReloadedGroupReportsTheTimeItActuallyTook() {
        // The bug: RunTranscriptEntry.createdAt defaulted to Date() at construction, and
        // rehydration constructs fresh entries — so a group that really took seven seconds
        // reported one, because both its start and end were stamped at the moment of the
        // reload. Rehydration now passes the persisted turn's timestamp, and finish(at:) takes
        // the last entry's rather than "now".
        let started = Date().addingTimeInterval(-3600)      // an hour ago
        let group = WorkGroupView(startedAt: started)
        let label = NSTextField(labelWithString: "→ read_file")
        group.addLine(label, isStep: true, at: started.addingTimeInterval(7))
        group.finish()
        let reported = group.accessibilityLabel() ?? ""
        XCTAssertTrue(reported.contains("7s"), reported)
        // And emphatically not an hour, which is what finishing at "now" would have produced.
        XCTAssertFalse(reported.contains("m "), reported)
    }

    func testAGroupWithNoLinesReportsNoElapsedTime() {
        let group = WorkGroupView(startedAt: Date())
        group.finish()
        XCTAssertTrue((group.accessibilityLabel() ?? "").contains("0s"), group.accessibilityLabel() ?? "")
    }
}
