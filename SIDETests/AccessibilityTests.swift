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
