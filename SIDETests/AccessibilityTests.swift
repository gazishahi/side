import AppKit
import XCTest
@testable import Side

/// Automated coverage for the AX contracts the audit found broken by inspection. These assert the
/// element properties VoiceOver actually reads — role, label, value, expanded state — because
/// every one of these regressed silently before: the views rendered fine and said nothing.
// Every assertion here touches AppKit views, which are main-actor state.
@MainActor
final class AccessibilityTests: XCTestCase {

    // MARK: - Diff file cards

    private func makeDiff(path: String, added: Int, removed: Int, isNew: Bool = false, isDeleted: Bool = false) -> UnifiedDiff.File {
        var hunk = UnifiedDiff.Hunk(header: "@@ -1,1 +1,\(added) @@")
        for index in 0..<added {
            hunk.lines.append(UnifiedDiff.Line(kind: .added, oldNumber: nil, newNumber: index + 1, text: "new \(index)"))
        }
        for index in 0..<removed {
            hunk.lines.append(UnifiedDiff.Line(kind: .removed, oldNumber: index + 1, newNumber: nil, text: "old \(index)"))
        }
        return UnifiedDiff.File(path: path, isNew: isNew, isDeleted: isDeleted, hunks: [hunk])
    }

    /// The header's click target is a private view class, so it's found the way an assistive
    /// client finds it: by role.
    private func header(of card: NSView) -> NSView? {
        if card.accessibilityRole() == .disclosureTriangle { return card }
        for subview in card.subviews {
            if let found = header(of: subview) { return found }
        }
        return nil
    }

    func testDiffHeaderLabelNamesTheFileItsCountsAndItsFate() throws {
        // "Toggle diff" was the old label: it announced that a control existed and nothing about
        // what it acted on, so a page of a dozen cards read as a dozen identical rows. The file
        // leads, the counts pluralize correctly, and new or deleted files say so.
        let cases: [(path: String, added: Int, removed: Int, isNew: Bool, isDeleted: Bool, expects: [String])] = [
            ("src/greeter.ts", 12, 3, false, false, ["12 lines added", "3 lines removed"]),
            ("a.swift", 1, 1, false, false, ["1 line added", "1 line removed"]),
            ("added.swift", 4, 0, true, false, ["new file"]),
            ("gone.swift", 0, 9, false, true, ["deleted file"]),
        ]
        for c in cases {
            let card = DiffFileCardView(file: makeDiff(path: c.path, added: c.added, removed: c.removed, isNew: c.isNew, isDeleted: c.isDeleted))
            let headerElement = try XCTUnwrap(header(of: card), "\(c.path): the fold control must be in the AX tree")
            let label = try XCTUnwrap(headerElement.accessibilityLabel(), c.path)
            XCTAssertTrue(label.hasPrefix(c.path), "\(c.path): the filename has to lead: \(label)")
            for fragment in c.expects {
                XCTAssertTrue(label.contains(fragment), "\(c.path): expected \"\(fragment)\" in \(label)")
            }
        }
    }

    func testDiffHeaderReportsAndTogglesItsExpandedState() throws {
        let card = DiffFileCardView(file: makeDiff(path: "a.swift", added: 2, removed: 0))
        let headerElement = try XCTUnwrap(header(of: card))

        XCTAssertEqual(headerElement.accessibilityValue() as? String, "expanded")
        XCTAssertTrue(headerElement.isAccessibilityExpanded())
        XCTAssertEqual(headerElement.accessibilityActionDescription(.press), "Collapse")

        XCTAssertTrue(headerElement.accessibilityPerformPress())

        XCTAssertEqual(headerElement.accessibilityValue() as? String, "collapsed")
        XCTAssertFalse(headerElement.isAccessibilityExpanded())
        // The action name describes the effect, which is what a rotor's action list shows.
        XCTAssertEqual(headerElement.accessibilityActionDescription(.press), "Expand")
    }

    // MARK: - Terminal

    func testDiffBodySpeaksTheGuttersMeaningAndLeavesContextUnmarked() throws {
        // The gutter carries added/removed in *color* only — deliberately, since +/- prefixes
        // hurt readability and copy badly. That leaves the text a screen reader receives (or
        // anyone who can't separate those greens and reds) as a flat wall of code with nothing
        // marking what changed. Only changes are news, though: marking every line would make
        // the announcement unusable.
        var hunk = UnifiedDiff.Hunk(header: "@@ -1,2 +1,2 @@")
        hunk.lines = [
            UnifiedDiff.Line(kind: .context, oldNumber: 1, newNumber: 1, text: "unchanged line"),
            UnifiedDiff.Line(kind: .added, oldNumber: nil, newNumber: 2, text: "new line"),
            UnifiedDiff.Line(kind: .removed, oldNumber: 2, newNumber: nil, text: "old line"),
        ]
        let body = DiffBody.makeBodyTextView()
        DiffBody.fill(body, hunks: [hunk])

        let spoken = try XCTUnwrap(body.accessibilityValue())
        XCTAssertTrue(spoken.contains("added, "), spoken)
        XCTAssertTrue(spoken.contains("removed, "), spoken)
        let lines = spoken.components(separatedBy: "\n")
        // The rendered header line is indented, so the marker sits before that indent.
        let headerLine = try XCTUnwrap(lines.first { $0.contains("@@") })
        XCTAssertTrue(headerLine.hasPrefix("section, "), headerLine)
        let contextLine = try XCTUnwrap(lines.first { $0.contains("unchanged line") })
        XCTAssertFalse(contextLine.hasPrefix("added"), contextLine)
        XCTAssertFalse(contextLine.hasPrefix("removed"), contextLine)
        XCTAssertEqual(body.accessibilityLabel(), "Diff")
        // The visible text is untouched: markers are for the AX layer only, so copy/paste and
        // the on-screen diff stay exactly as designed.
        XCTAssertFalse(body.string.contains("added, "))
    }

    // MARK: - Containment

    func testDiffCardsStayInTheAXTreeInsideAWindow() throws {
        // The audit's tab-chip finding was a *containment* failure: the elements had correct
        // labels and still never reached the tree once they were nested in a scroll view. Roles
        // asserted on a detached view can't catch that, so this one walks a real window.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: true)
        let host = NSView(frame: window.contentLayoutRect)
        let scroll = NSScrollView(frame: host.bounds)
        let document = NSView(frame: host.bounds)
        let card = DiffFileCardView(file: makeDiff(path: "in/a/window.swift", added: 3, removed: 1))
        document.addSubview(card)
        scroll.documentView = document
        host.addSubview(scroll)
        window.contentView = host
        window.layoutIfNeeded()

        let found = firstElement(in: window.contentView, role: .disclosureTriangle)
        let label = try XCTUnwrap(found?.accessibilityLabel(), "the fold control vanished once nested in a scroll view")
        XCTAssertTrue(label.hasPrefix("in/a/window.swift"), label)
    }

    private func firstElement(in view: NSView?, role: NSAccessibility.Role) -> NSView? {
        guard let view else { return nil }
        if view.accessibilityRole() == role { return view }
        for child in view.subviews {
            if let found = firstElement(in: child, role: role) { return found }
        }
        return nil
    }

    func testTerminalIsExposedAsAReadableTextArea() {
        // SwiftTerm ships accessibility for UIKit only, so on macOS the entire Run stage was
        // absent from the AX tree — window and scrollbar, no text, no prompt.
        let terminal = SideTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        XCTAssertTrue(terminal.isAccessibilityElement())
        XCTAssertEqual(terminal.accessibilityRole(), .textArea)
        XCTAssertEqual(terminal.accessibilityLabel(), "Terminal")
        XCTAssertNotNil(terminal.accessibilityHelp(), "a text area that accepts input should say so")
    }

    func testTerminalValueReadsBackTheScreenWithoutTrailingBlankRows() {
        let terminal = SideTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        // `feed` writes into the emulator without involving a process, which is exactly the
        // buffer the AX value is meant to expose. A 25-row screen holding one line of output
        // shouldn't read as one line followed by twenty-four empty ones.
        terminal.feed(text: "hello from the shell\r\n")

        let value = terminal.accessibilityValue() as? String ?? ""
        XCTAssertTrue(value.contains("hello from the shell"), "AX value was: \(value)")
        XCTAssertEqual(terminal.accessibilityNumberOfCharacters(), value.count)
        XCTAssertFalse(value.hasSuffix("\n"), "AX value was: \(value.debugDescription)")
        XCTAssertEqual(value.components(separatedBy: "\n").count, 1, value.debugDescription)
    }

    // MARK: - Stage control (2026-09-01 audit, H16; Direction 02 §3.6)

    func testEachStageSegmentIsARadioButtonThatSpeaksItsState() {
        // The stock segmented control exposed no per-segment element, so state rode in a ● glyph
        // VoiceOver read as "black circle". Each segment now names itself and its state.
        let control = SlidingSegmentedControl(titles: ["Make", "Think", "Review", "Run"], style: .overlay)
        control.setBadge(.needsYou, spokenState: "needs you", at: 1)
        control.setBadge(.working, spokenState: "a terminal has new output", at: 3)
        XCTAssertEqual(control.accessibilityRole(), .radioGroup)
        XCTAssertEqual(control.segmentAccessibilityLabels, ["Make", "Think, needs you", "Review", "Run, a terminal has new output"])
        control.setBadge(nil, spokenState: nil, at: 1)
        XCTAssertEqual(control.segmentAccessibilityLabels[1], "Think")
    }
}
