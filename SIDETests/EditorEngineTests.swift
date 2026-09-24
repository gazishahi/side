import XCTest
@testable import Side
@testable import Heron

/// Alloy RFC step 0: Make reaches its editor only through `EditorEngine`, and today's TextKit
/// editor behaves as it did. These drive Make's real typing path, so the same tests will hold
/// Alloy to the same behavior when it implements the seam.
@MainActor
final class EditorEngineTests: XCTestCase {
    private var root: URL!
    private var make: MakeWorkspaceViewController!
    private var window: NSWindow!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("editor-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        make = MakeWorkspaceViewController()
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
        let view = try! XCTUnwrap(engine.textView as? NSTextView)
        window.makeFirstResponder(view)
        view.insertText(text, replacementRange: engine.selectedRange)
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
        let view = try XCTUnwrap(engine.textView as? NSTextView)
        view.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(engine.document?.string, "func f() {\n    }\n", "a newline after { indents")
        XCTAssertTrue(make.hasUnsavedChanges, "and the tab is unsaved")
    }

    func testDecorationsReplaceOnlyTheirOwnKind() {
        let document = TextStorageDocument("(a) b")
        document.setDecorations(.bracketMatch, [(NSRange(location: 0, length: 1), .red), (NSRange(location: 2, length: 1), .red)])
        document.setDecorations(.diagnostic, [(NSRange(location: 4, length: 1), .systemYellow)])
        document.setDecorations(.bracketMatch, [])
        XCTAssertNil(document.storage.attribute(.backgroundColor, at: 0, effectiveRange: nil), "the old bracket tint is gone")
        XCTAssertNotNil(document.storage.attribute(.underlineStyle, at: 4, effectiveRange: nil), "the diagnostic stays")
        document.replaceAll(with: "x")
        XCTAssertEqual(document.string, "x")
        document.setDecorations(.diagnostic, [(NSRange(location: 4, length: 1), .red)])
        XCTAssertEqual(document.length, 1, "a mark past the end is skipped, not a crash")
    }
}
