import XCTest
@testable import Side
@testable import Heron
import AlloyAppKit
import AlloyCore

/// Make reaches its editor only through `EditorEngine` (SIDE_RFC_ALLOY.md). These drive Make's
/// real typing path; they held TextKit and then Alloy to the same behavior across the switch.
@MainActor
final class EditorEngineTests: XCTestCase {
    private var root: URL!
    private var make: MakeWorkspaceViewController!
    private var window: NSWindow!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("editor-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        make = MakeWorkspaceViewController()
        make.loadViewIfNeeded()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        // As the shell hosts it: Make's view, and its tab strip in the window's top row.
        let container = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = container
        for child in [make.view, try XCTUnwrap(make.topRowContent)] {
            child.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(child)
        }
        let tabs = try XCTUnwrap(make.topRowContent)
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: container.topAnchor),
            tabs.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tabs.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tabs.heightAnchor.constraint(equalToConstant: 30),
            make.view.topAnchor.constraint(equalTo: container.topAnchor),
            make.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            make.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            make.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        window.orderFront(nil)
    }

    override func tearDownWithError() throws {
        window.orderOut(nil)
        try? FileManager.default.removeItem(at: root)
    }

    private func open(_ name: String, _ text: String, line: Int? = nil) throws -> EditorEngine {
        let url = root.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        make.revealFile(url, line: line)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, make.editor.document?.string != text { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertEqual(make.editor.document?.string, text)
        // Make ignores changes for the rest of the turn that loaded a tab (so loading never marks
        // it unsaved); let that turn finish, as a person's first keystroke always would.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        return make.editor
    }

    /// Typing as a person does: through the text view's input path, so the delegate's
    /// shouldChangeText and key commands run.
    private func type(_ text: String, into engine: EditorEngine) {
        window.makeFirstResponder(engine.textView)
        let input = engine.textView as! NSTextInputClient
        input.insertText(text, replacementRange: engine.selectedRange)
    }

    func testMakeEditsOnAlloy() {
        XCTAssertTrue(make.editor is AlloyEditorEngine)
    }

    func testOpeningRevealsTheLineAndTheDocumentIsTheTabs() throws {
        let engine = try open("a.swift", "let a = 1\nlet b = 2\nlet c = 3\n", line: 2)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, engine.selectedRange.location != 10 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertEqual(engine.selectedRange, NSRange(location: 10, length: 0), "the caret lands at the start of line 2")
        XCTAssertTrue(engine.isEditable)
        XCTAssertFalse(make.hasUnsavedChanges)
    }

    func testTypingGoesThroughTheSeam() throws {
        let engine = try open("b.swift", "func f() \n")
        engine.selectedRange = NSRange(location: 9, length: 0)
        type("{", into: engine)
        XCTAssertEqual(engine.document?.string, "func f() {}\n", "an opening bracket closes itself")
        XCTAssertEqual(engine.selectedRange, NSRange(location: 10, length: 0), "with the caret between")
        type("}", into: engine)
        XCTAssertEqual(engine.document?.string, "func f() {}\n", "typing the closer steps over it")
        XCTAssertEqual(engine.selectedRange.location, 11)

        engine.selectedRange = NSRange(location: 10, length: 0)
        engine.textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(engine.document?.string, "func f() {\n    \n}\n", "a newline between braces indents the body, not the closer")
        XCTAssertEqual(engine.selectedRange.location, 15, "the caret on the body's line")
        XCTAssertTrue(make.hasUnsavedChanges, "and the tab is unsaved")
    }

    func testTypingSomethingAndDeletingItByHandLeavesTheTabSaved() throws {
        let engine = try open("c.ts", "let a = 1\n")
        engine.selectedRange = NSRange(location: 9, length: 0)
        engine.textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertTrue(make.hasUnsavedChanges)
        engine.textView.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        XCTAssertEqual(engine.document?.string, "let a = 1\n")
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, make.hasUnsavedChanges { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertFalse(make.hasUnsavedChanges, "back to what's on disk: nothing to save")
    }

    func testAServersEditsReachOpenTabsUndoablyAndClosedFilesOnDisk() throws {
        // A rename across three files: the one shown, one open behind it, one not open.
        let engine = try open("a.ts", "let count = 1\nuse(count)\n")
        let other = root.appendingPathComponent("b.ts"), closed = root.appendingPathComponent("c.ts")
        try "import { count } from './a'\n".write(to: other, atomically: true, encoding: .utf8)
        try "count + count\n".write(to: closed, atomically: true, encoding: .utf8)
        make.revealFile(other, line: nil)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, make.editor.document?.string != "import { count } from './a'\n" { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        make.revealFile(root.appendingPathComponent("a.ts"), line: nil)
        while Date() < deadline, make.editor.document?.string != "let count = 1\nuse(count)\n" { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        func edit(_ line: Int, _ from: Int, _ to: Int) -> LSPTextEdit {
            LSPTextEdit(range: LSPRange(start: LSPPosition(line: line, character: from), end: LSPPosition(line: line, character: to)), newText: "total")
        }
        let applied = make.applyWorkspaceEdit(LSPWorkspaceEdit(files: [
            (root.appendingPathComponent("a.ts").absoluteString, [edit(0, 4, 9), edit(1, 4, 9)]),
            (other.absoluteString, [edit(0, 9, 14)]),
            (closed.absoluteString, [edit(0, 0, 5), edit(0, 8, 13)]),
        ]))
        XCTAssertTrue(applied)
        XCTAssertEqual(engine.document?.string, "let total = 1\nuse(total)\n")
        XCTAssertEqual(try String(contentsOf: closed, encoding: .utf8), "total + total\n", "a closed file is rewritten")
        XCTAssertTrue(make.hasUnsavedChanges, "an open file is left unsaved, as typing would")
        engine.textView.perform(#selector(AlloyTextView.undo(_:)), with: nil)
        XCTAssertEqual(engine.document?.string, "let count = 1\nuse(count)\n", "one undo takes the whole file's edits back")
    }

    func testOverlappingEditsAreRefused() {
        let rope = Rope("abcdef")
        let overlapping = [LSPTextEdit(range: LSPRange(start: LSPPosition(line: 0, character: 0), end: LSPPosition(line: 0, character: 3)), newText: "x"),
                           LSPTextEdit(range: LSPRange(start: LSPPosition(line: 0, character: 2), end: LSPPosition(line: 0, character: 4)), newText: "y")]
        XCTAssertNil(MakeWorkspaceViewController.nonOverlapping(overlapping, in: rope))
        XCTAssertEqual(MakeWorkspaceViewController.nonOverlapping(Array(overlapping.prefix(1)), in: rope)?.first?.range, NSRange(location: 0, length: 3))
    }

    func testDecorationsReplaceOnlyTheirOwnKind() {
        let document = AlloyEditorDocument("(a) b")
        document.setDecorations(.bracketMatch, [(NSRange(location: 0, length: 1), .red), (NSRange(location: 2, length: 1), .red)])
        document.setDecorations(.diagnostic, [(NSRange(location: 4, length: 1), .systemYellow)])
        document.setDecorations(.bracketMatch, [])
        XCTAssertEqual(document.decorations[.bracketMatch]?.count ?? 0, 0, "the old bracket tint is gone")
        XCTAssertEqual(document.decorations[.diagnostic]?.count, 1, "the diagnostic stays")
        document.replaceAll(with: "x")
        XCTAssertEqual(document.string, "x")
        XCTAssertTrue(document.decorations.isEmpty, "a new text starts without marks")
    }
}
