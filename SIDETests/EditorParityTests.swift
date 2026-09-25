import XCTest
import AlloyAppKit
import AlloyRender
@testable import Side
@testable import Heron

/// Alloy RFC step 5, the parity bar: what Make does with its editor, through Make's own entry
/// points. These ran on TextKit and Alloy both until step 7 made Alloy the only editor.
@MainActor
final class EditorParityTests: XCTestCase {
    private var root: URL!
    private var make: MakeWorkspaceViewController!
    private var window: NSWindow!
    private var alloy: AlloyEditorEngine { make.editor as! AlloyEditorEngine }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("parity-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        make = MakeWorkspaceViewController()
        make.loadViewIfNeeded()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        let container = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = container
        let tabs = try XCTUnwrap(make.topRowContent)
        for child in [make.view, tabs] {
            child.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(child)
        }
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: container.topAnchor), tabs.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tabs.trailingAnchor.constraint(equalTo: container.trailingAnchor), tabs.heightAnchor.constraint(equalToConstant: 30),
            make.view.topAnchor.constraint(equalTo: container.topAnchor), make.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            make.view.leadingAnchor.constraint(equalTo: container.leadingAnchor), make.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        window.orderFront(nil)
    }

    override func tearDownWithError() throws {
        window.orderOut(nil)
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func open(_ name: String, _ text: String) throws -> EditorEngine {
        let url = root.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) { try text.write(to: url, atomically: true, encoding: .utf8) }
        make.revealFile(url, line: nil)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, make.editor.document?.string != text { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertEqual(make.editor.document?.string, text, name)
        make.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        return make.editor
    }

    private func type(_ text: String) {
        window.makeFirstResponder(make.editor.textView)
        (make.editor.textView as! NSTextInputClient).insertText(text, replacementRange: make.editor.selectedRange)
    }

    private func undo() {
        alloy.view.textView.undo(nil)
    }

    func testSyntaxColorsTheKeywords() throws {
        try open("colors.swift", "struct A {\n    let x = \"s\" // c\n}\n")
        let spans = try XCTUnwrap(alloy.view.styles?(0))
        XCTAssertTrue(spans.contains { $0.range.contains(0) }, "struct is colored")
        XCTAssertTrue(try XCTUnwrap(alloy.view.styles?(1)).contains { $0.range.contains(14) }, "the string is colored")
    }

    func testDiagnosticsUnderlineAndMarkTheGutter() throws {
        let engine = try open("diag.swift", "let a = 1\nlet b = oops\n")
        engine.document?.setDecorations(.diagnostic, [(NSRange(location: 18, length: 4), .systemRed)])
        engine.lineDiagnostics = [2: .error]
        XCTAssertTrue(alloy.view.decorations.contains { $0.range == 18..<22 && $0.style == .dottedUnderline })
        XCTAssertEqual(alloy.view.gutter.marks[2]?.first?.style, .dot)
        engine.document?.setDecorations(.diagnostic, [])
        XCTAssertTrue(alloy.view.decorations.isEmpty, "cleared")
    }

    func testGutterClicksReachTheDelegate() throws {
        final class Recorder: EditorEngineDelegate {
            var diagnostic: (LSPDiagnosticSeverity, Int)?
            var diff: (GitDiffMark, Int)?
            func editorTextDidChange(_ engine: EditorEngine) {}
            func editorSelectionDidChange(_ engine: EditorEngine) {}
            func editor(_ engine: EditorEngine, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool { true }
            func editor(_ engine: EditorEngine, doCommandBy selector: Selector) -> Bool { false }
            func editor(_ engine: EditorEngine, definitionRequestedAt characterIndex: Int) {}
            func editor(_ engine: EditorEngine, clickedDiffMark mark: GitDiffMark, line: Int, event: NSEvent) { diff = (mark, line) }
            func editor(_ engine: EditorEngine, clickedDiagnostic severity: LSPDiagnosticSeverity, line: Int, event: NSEvent) { diagnostic = (severity, line) }
        }
        let engine = try open("gutter.swift", "one\ntwo\nthree\nfour\n")
        let recorder = Recorder()
        let original = engine.delegate
        engine.delegate = recorder
        defer { engine.delegate = original }
        engine.lineDiagnostics = [2: .warning]
        engine.lineDiffMarks = [3: .added]
        engine.invalidateGutter()
        func click(line: Int) {
            let caret = engine.rect(forCharacterRange: NSRange(location: [0, 0, 4, 8][line], length: 0))
            let inWindow = engine.textView.convert(CGPoint(x: 0, y: caret.midY), to: nil)
            let inGutter = engine.gutterView.convert(inWindow, from: nil)
            let event = NSEvent.mouseEvent(with: .leftMouseDown, location: engine.gutterView.convert(CGPoint(x: 10, y: inGutter.y), to: nil),
                                           modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            engine.gutterView.mouseDown(with: event)
        }
        click(line: 2)
        XCTAssertEqual(recorder.diagnostic?.1, 2)
        click(line: 3)
        XCTAssertEqual(recorder.diff?.1, 3)
    }

    func testPopoverAndCompletionAnchors() throws {
        let engine = try open("anchor.swift", "let value = compute(input)\nsecond\n")
        engine.selectedRange = NSRange(location: 12, length: 7)
        let rect = engine.rect(forCharacterRange: engine.selectedRange)
        XCTAssertGreaterThan(rect.width, 20, "⌘K's popover anchors on the selection")
        XCTAssertTrue(engine.textView.bounds.contains(CGPoint(x: rect.midX, y: rect.midY)))
        let screen = try XCTUnwrap(engine.screenRect(forCharacterRange: NSRange(location: 12, length: 0)), "the completion panel anchors at the caret")
        XCTAssertTrue(window.frame.insetBy(dx: -2, dy: -2).contains(CGPoint(x: screen.midX, y: screen.midY)))
        engine.focus()
        XCTAssertTrue(window.firstResponder === engine.textView)
    }

    func testJumpToDefinitionIsInTheContextMenu() throws {
        let engine = try open("menu.swift", "let value = 1\n")
        let caret = engine.rect(forCharacterRange: NSRange(location: 5, length: 0))
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: engine.textView.convert(CGPoint(x: caret.minX + 2, y: caret.midY), to: nil),
                                       modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        let menu = try XCTUnwrap(engine.textView.menu(for: event))
        XCTAssertEqual(menu.items.first?.title, "Jump to Definition")
    }

    func testUndoIsPerTabAndBackToSavedClearsTheDot() throws {
        let a = "let a = 1\n"
        try open("a.swift", a)
        make.editor.selectedRange = NSRange(location: 9, length: 0)
        type("X")
        XCTAssertTrue(make.hasUnsavedChanges)
        try open("b.swift", "let b = 2\n")
        make.editor.selectedRange = NSRange(location: 0, length: 0)
        type("Y")
        try open("a.swift", "let a = 1X\n")
        undo()
        XCTAssertEqual(make.editor.document?.string, a, "undo in a undoes a's edit")
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        try open("b.swift", "Ylet b = 2\n")
        XCTAssertEqual(make.editor.document?.string, "Ylet b = 2\n", "b's edit is b's")
        undo()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertFalse(make.hasUnsavedChanges, "both are back to what's saved: no unsaved dot")
    }

    func testAnApprovedAgentEditReplacesTheTextAndClearsUndo() throws {
        let url = root.appendingPathComponent("agent.swift")
        try open("agent.swift", "let a = 1\n")
        type("Z")
        let new = "let a = 2 // from the agent\n"
        try new.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertTrue(make.applyApprovedEdit(url: url, newContent: new))
        XCTAssertEqual(make.editor.document?.string, new)
        XCTAssertFalse(make.hasUnsavedChanges)
        undo()
        XCTAssertEqual(make.editor.document?.string, new, "undo can't replay edits against text they don't describe")
        // The view laid the new text out: a caret at its end sits on line 1.
        let end = make.editor.rect(forCharacterRange: NSRange(location: (new as NSString).length - 1, length: 0))
        XCTAssertLessThan(end.minY, make.editor.rect(forCharacterRange: NSRange(location: 0, length: 0)).maxY + 1)
    }

    func testTheTextSizeSettingRelaysOut() throws {
        try open("size.swift", "line one\nline two\n")
        let before = make.editor.rect(forCharacterRange: NSRange(location: 9, length: 0)).minY
        let saved = DS.Text.CodeSize.editor
        defer { DS.Text.CodeSize.editor = saved }
        DS.Text.CodeSize.editor = 24
        NotificationCenter.default.post(name: DS.Text.CodeSize.didChangeNotification, object: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let after = make.editor.rect(forCharacterRange: NSRange(location: 9, length: 0)).minY
        XCTAssertGreaterThan(after, before + 5, "the second line moved down with the bigger text")
    }

    /// VoiceOver reads either editor as a text area: its text, the selection, and lines.
    func testVoiceOverReadsTheText() throws {
        let editor = try open("ax.swift", "let a = 1\nlet b = 2\n")
        editor.selectedRange = NSRange(location: 14, length: 1)
        let view = editor.textView
        XCTAssertEqual(view.accessibilityRole(), .textArea)
        XCTAssertEqual(view.accessibilityValue() as? String, "let a = 1\nlet b = 2\n")
        XCTAssertEqual(view.accessibilityNumberOfCharacters(), 20)
        XCTAssertEqual(view.accessibilitySelectedTextRange(), NSRange(location: 14, length: 1))
        XCTAssertEqual(view.accessibilitySelectedText(), "b")
        editor.selectedRange = NSRange(location: 14, length: 0)
        XCTAssertEqual(view.accessibilityInsertionPointLineNumber(), 1)
        XCTAssertEqual(view.accessibilityRange(forLine: 1), NSRange(location: 10, length: 10))
        XCTAssertEqual(view.accessibilityString(for: NSRange(location: 10, length: 3)), "let")
        XCTAssertGreaterThan(view.accessibilityFrame(for: NSRange(location: 14, length: 1)).width, 1)
    }

    func testAReadOnlyEditorTakesNoTyping() throws {
        try open("ro.swift", "fixed\n")
        make.editor.isEditable = false
        type("nope")
        XCTAssertEqual(make.editor.document?.string, "fixed\n")
        make.editor.isEditable = true
    }
}
