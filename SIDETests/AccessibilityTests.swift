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

    func testDiffHeaderNamesTheFileAndItsChangeCounts() throws {
        let card = DiffFileCardView(file: makeDiff(path: "src/greeter.ts", added: 12, removed: 3))
        let headerElement = try XCTUnwrap(header(of: card), "the fold control must be in the AX tree")

        let label = try XCTUnwrap(headerElement.accessibilityLabel())
        // "Toggle diff" was the old label: it announced that a control existed and nothing about
        // what it acted on, so a page of a dozen cards read as a dozen identical rows.
        XCTAssertTrue(label.hasPrefix("src/greeter.ts"), "the filename has to lead: \(label)")
        XCTAssertTrue(label.contains("12 lines added"), label)
        XCTAssertTrue(label.contains("3 lines removed"), label)
    }

    func testDiffHeaderPluralizesASingleLine() throws {
        let card = DiffFileCardView(file: makeDiff(path: "a.swift", added: 1, removed: 1))
        let label = try XCTUnwrap(header(of: card)?.accessibilityLabel())
        XCTAssertTrue(label.contains("1 line added"), label)
        XCTAssertTrue(label.contains("1 line removed"), label)
    }

    func testDiffHeaderCallsOutNewAndDeletedFiles() throws {
        let newCard = DiffFileCardView(file: makeDiff(path: "added.swift", added: 4, removed: 0, isNew: true))
        XCTAssertTrue(try XCTUnwrap(header(of: newCard)?.accessibilityLabel()).contains("new file"))

        let goneCard = DiffFileCardView(file: makeDiff(path: "gone.swift", added: 0, removed: 9, isDeleted: true))
        XCTAssertTrue(try XCTUnwrap(header(of: goneCard)?.accessibilityLabel()).contains("deleted file"))
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

    func testDiffBodySpeaksTheGuttersMeaning() throws {
        // The gutter carries added/removed in *color* only — deliberately, since +/- prefixes
        // hurt readability and copy badly. That leaves the text a screen reader receives (or
        // anyone who can't separate those greens and reds) as a flat wall of code with nothing
        // marking what changed.
        let file = makeDiff(path: "a.swift", added: 1, removed: 1)
        let body = DiffBody.makeBodyTextView()
        DiffBody.fill(body, hunks: file.hunks)

        let spoken = try XCTUnwrap(body.accessibilityValue())
        XCTAssertTrue(spoken.contains("added, "), spoken)
        XCTAssertTrue(spoken.contains("removed, "), spoken)
        // The rendered header line is indented, so the marker sits before that indent.
        let headerLine = try XCTUnwrap(spoken.components(separatedBy: "\n").first { $0.contains("@@") })
        XCTAssertTrue(headerLine.hasPrefix("section, "), headerLine)
        XCTAssertEqual(body.accessibilityLabel(), "Diff")
        // The visible text is untouched: markers are for the AX layer only, so copy/paste and
        // the on-screen diff stay exactly as designed.
        XCTAssertFalse(body.string.contains("added, "))
    }

    func testDiffBodyLeavesContextLinesUnmarked() throws {
        var hunk = UnifiedDiff.Hunk(header: "@@ -1,2 +1,2 @@")
        hunk.lines = [
            UnifiedDiff.Line(kind: .context, oldNumber: 1, newNumber: 1, text: "unchanged line"),
            UnifiedDiff.Line(kind: .added, oldNumber: nil, newNumber: 2, text: "new line"),
        ]
        let body = DiffBody.makeBodyTextView()
        DiffBody.fill(body, hunks: [hunk])

        let lines = try XCTUnwrap(body.accessibilityValue()).components(separatedBy: "\n")
        // Marking every line would make the announcement unusable — only changes are news.
        let contextLine = try XCTUnwrap(lines.first { $0.contains("unchanged line") })
        XCTAssertFalse(contextLine.hasPrefix("added"))
        XCTAssertFalse(contextLine.hasPrefix("removed"))
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

    func testTerminalValueReadsBackWhatWasWrittenToTheScreen() {
        let terminal = SideTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        // `feed` writes into the emulator without involving a process, which is exactly the
        // buffer the AX value is meant to expose.
        terminal.feed(text: "hello from the shell\r\n")

        let value = terminal.accessibilityValue() as? String ?? ""
        XCTAssertTrue(value.contains("hello from the shell"), "AX value was: \(value)")
        XCTAssertEqual(terminal.accessibilityNumberOfCharacters(), value.count)
    }

    func testTerminalValueDropsTrailingBlankRows() {
        let terminal = SideTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        terminal.feed(text: "one line\r\n")
        let value = terminal.accessibilityValue() as? String ?? ""
        // A 25-row screen holding one line of output shouldn't read as one line followed by
        // twenty-four empty ones.
        XCTAssertFalse(value.hasSuffix("\n"), "AX value was: \(value.debugDescription)")
        XCTAssertEqual(value.components(separatedBy: "\n").count, 1, value.debugDescription)
    }
}
