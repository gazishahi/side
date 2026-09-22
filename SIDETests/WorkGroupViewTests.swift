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

    func testToggleGeometry() {
        // The overflow bug: pinning the content to `fittingSize` under-measured it, so the
        // expanded group was shorter than its own content and drew over the next message.
        // Collapsing again must land back on the original height.
        let group = makeGroup(lines: 3)
        let collapsed = group.fittingSize.height
        group.toggle()
        group.layoutSubtreeIfNeeded()
        let expanded = group.fittingSize.height
        XCTAssertGreaterThan(expanded, collapsed + 30, "expanded \(expanded) vs collapsed \(collapsed)")
        group.toggle()
        group.layoutSubtreeIfNeeded()
        XCTAssertEqual(group.fittingSize.height, collapsed, accuracy: 1)
    }

    func testHeaderHitRegion() {
        // Top of an unflipped view is *high* y. Getting this backwards is what made the group
        // openable but not closable. And content clicks must fall through so a tool line's file
        // links stay reachable.
        let group = makeGroup(lines: 3)
        group.frame = NSRect(x: 0, y: 0, width: 600, height: group.fittingSize.height)
        group.layoutSubtreeIfNeeded()
        XCTAssertFalse(group.isFlipped, "the hit test's sign depends on this")
        XCTAssertTrue(group.isInHeader(NSPoint(x: 100, y: group.bounds.maxY - 2)))

        group.toggle()
        group.layoutSubtreeIfNeeded()
        group.frame = NSRect(x: 0, y: 0, width: 600, height: group.fittingSize.height)
        group.layoutSubtreeIfNeeded()
        XCTAssertTrue(group.isInHeader(NSPoint(x: 100, y: group.bounds.maxY - 2)))
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

    func testElapsedTime() {
        // The elapsed time is always stated — it used to be hidden below one second, which is
        // most of them. The 676-minute bug: renderFull finished every group at the timestamp of
        // the *conversation's* final entry, so a two-step group from last night reported the age
        // of the whole conversation. A group measures its own span or nothing — and with no lines
        // at all, it reports zero.
        let long = Date().addingTimeInterval(-200)
        let stated = WorkGroupView(startedAt: long)
        stated.addLine(NSTextField(labelWithString: "→ run_task"), isStep: true, at: long.addingTimeInterval(95))
        stated.finish()
        let label = stated.accessibilityLabel() ?? ""
        XCTAssertTrue(label.contains("1m 35s"), label)
        XCTAssertTrue(label.contains("Worked for"), label)

        let lastNight = Date().addingTimeInterval(-40_000)
        let own = WorkGroupView(startedAt: lastNight)
        own.addLine(NSTextField(labelWithString: "→ read_file"), isStep: true, at: lastNight.addingTimeInterval(3))
        own.addLine(NSTextField(labelWithString: "✓ read_file"), isStep: false, at: lastNight.addingTimeInterval(9))
        own.finish()
        let reported = own.accessibilityLabel() ?? ""
        XCTAssertTrue(reported.contains("9s"), reported)
        XCTAssertFalse(reported.contains("m "), reported)

        let empty = WorkGroupView(startedAt: Date())
        empty.finish()
        XCTAssertTrue((empty.accessibilityLabel() ?? "").contains("0s"), empty.accessibilityLabel() ?? "")
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

    // MARK: - Accessibility (2026-09-01 audit, H15)

    private func header(of group: WorkGroupView) -> WorkGroupHeaderView? {
        func find(_ view: NSView) -> WorkGroupHeaderView? {
            if let header = view as? WorkGroupHeaderView { return header }
            for child in view.subviews { if let found = find(child) { return found } }
            return nil
        }
        return find(group)
    }

    func testTheHeaderIsADisclosureVoiceOverCanOperate() throws {
        let group = makeGroup()
        let header = try XCTUnwrap(header(of: group))
        XCTAssertTrue(header.isAccessibilityElement())
        XCTAssertEqual(header.accessibilityRole(), .disclosureTriangle)
        XCTAssertFalse(header.isAccessibilityExpanded())
        XCTAssertEqual(header.accessibilityActionDescription(.press), "Expand")
        // Pressing is the same as clicking — and it is reported back as a state change.
        XCTAssertTrue(header.accessibilityPerformPress())
        XCTAssertTrue(group.isExpanded)
        XCTAssertTrue(header.isAccessibilityExpanded())
        XCTAssertEqual(header.accessibilityValue() as? String, "expanded")
        XCTAssertEqual(header.accessibilityActionDescription(.press), "Collapse")
    }

    func testTheHeaderSpeaksTheGroupTitleNotItsParts() throws {
        let group = makeGroup()
        let header = try XCTUnwrap(header(of: group))
        let label = try XCTUnwrap(header.accessibilityLabel())
        XCTAssertTrue(label.contains("Worked") || label.contains("Working"), label)
        // The chevron image and the title text field are parts of the one element, not siblings.
        XCTAssertTrue(header.views.allSatisfy { !$0.isAccessibilityElement() })
    }
}
