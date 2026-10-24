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

    /// Code scrolls on under the tab strip and the bottom bar, as the Markdown preview does: the
    /// editor draws its whole clip view, not just the part inside Make's content insets.
    func testCodeFlowsUnderTheFloatingChrome() throws {
        try open("flow.swift", String(repeating: "let line = 1\n", count: 400))
        // As the shell does: the top row and the bottom bar float over the editor.
        make.setBottomObstruction(56)
        make.view.layoutSubtreeIfNeeded()
        let insets = alloy.view.scrollView.contentView.contentInsets
        XCTAssertGreaterThan(insets.top + insets.bottom, 0, "Make insets the editor for its chrome")
        alloy.view.render()
        XCTAssertEqual(alloy.view.canvasFrame, alloy.view.scrollView.contentView.frame, "drawn under the insets too")
    }

    /// Editor ⇄ preview on a long document: each switch is immediate, and the editor keeps its
    /// place.
    func testMarkdownPreviewSwitchesQuickly() throws {
        let doc = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/SIDE_PRODUCT_CONSTITUTION.md"), encoding: .utf8)
        try open("long.md", doc)
        var times: [Double] = []
        for _ in 0..<6 {
            let start = CACurrentMediaTime()
            make.perform(Selector(("toggleMarkdownPreview")))
            make.view.layoutSubtreeIfNeeded()
            times.append((CACurrentMediaTime() - start) * 1000)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        // The first switch to the preview renders and lays it out; after that the unchanged
        // document is reused, so every switch is immediate.
        // Limits only where timings mean something (the budgets): on a loaded machine the
        // ordinary suite missed 30 ms and passed alone.
        guard Budgets.enabled else { return }
        XCTAssertLessThan(times[0], 250, "first preview")
        XCTAssertLessThan(times.dropFirst().max()!, 30, "switches after that: \(times)")
    }

    /// ⇧⌘V works again straight away: the view shown takes focus, so the menu item still finds
    /// Make in the responder chain (hiding the focused editor used to leave the window focused,
    /// and the shortcut did nothing until a click).
    func testMarkdownPreviewKeepsTheShortcutReachable() throws {
        try open("focus.md", "# Title\n\nSome text.\n")
        window.makeKey()
        make.editor.focus()
        for _ in 0..<4 {
            make.perform(Selector(("toggleMarkdownPreview")))
            let responder = try XCTUnwrap(window.firstResponder as? NSView, "focus is on a view, not the window")
            XCTAssertTrue(responder.isDescendant(of: make.view), "inside Make, so its menu actions resolve")
            XCTAssertFalse(responder.isHiddenOrHasHiddenAncestor, "and it's the one showing")
        }
    }

    /// 2026-10-23, the owner: ⌘W didn't close an image. An image or spreadsheet tab now takes
    /// focus as it shows, so Close Tab finds Make in the responder chain.
    func testAnImageOrSpreadsheetTabTakesFocusSoCloseTabWorks() throws {
        try open("notes.md", "# Notes\n")
        let png = root.appendingPathComponent("pixel.png")
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 4, height: 4).fill(); image.unlockFocus()
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        try rep.representation(using: .png, properties: [:])!.write(to: png)
        try "a,b\n1,2\n".write(to: root.appendingPathComponent("table.csv"), atomically: true, encoding: .utf8)
        window.makeKey()
        for name in ["pixel.png", "table.csv"] {
            make.revealFile(root.appendingPathComponent(name), line: nil)
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline, make.activeTabURLForTesting?.lastPathComponent != name { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            let responder = try XCTUnwrap(window.firstResponder as? NSView, "\(name): focus is on a view, not the window")
            XCTAssertTrue(responder.isDescendant(of: make.view), "\(name): inside Make")
            XCTAssertFalse(responder.isHiddenOrHasHiddenAncestor, "\(name): the one showing")
            // The menu's route: up the responder chain from the focused view to whoever answers.
            let close = Selector(("closeActiveTab"))
            var target: NSResponder? = responder
            while let current = target, !current.responds(to: close) { target = current.nextResponder }
            XCTAssertTrue(target === make, "\(name): Close Tab reaches Make")
            make.perform(close)
            let closed = Date().addingTimeInterval(5)
            while Date() < closed, make.activeTabURLForTesting?.lastPathComponent == name { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            XCTAssertNotEqual(make.activeTabURLForTesting?.lastPathComponent, name, "\(name) closed")
        }
    }

    /// 2026-10-23, the owner: a sheet didn't follow its file. A sheet can't be edited here, so a
    /// change on disk reloads it, and the sheet keeps its sort.
    func testASheetReloadsWhenItsFileChanges() throws {
        let url = root.appendingPathComponent("scores.tsv")
        try "name\tscore\nb\t10\na\t9\n".write(to: url, atomically: true, encoding: .utf8)
        // From no tabs at all: closing the last tab once hid the grid for good (the owner saw
        // the row count with no rows).
        make.closeAllTabsForTesting()
        make.revealFile(url, line: nil)
        let sheet = make.sheetViewForTesting
        let opened = Date().addingTimeInterval(10)
        while Date() < opened, sheet.rows.count != 2 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertFalse(sheet.scrollView.isHiddenOrHasHiddenAncestor, "the grid shows, not just the footer")
        XCTAssertEqual(sheet.header, ["name", "score"], "tab-separated, sniffed from the extension")
        sheet.sort(by: 1, ascending: true)
        XCTAssertEqual(sheet.rows.map(\.cells[0]), ["a", "b"])
        try "name\tscore\nb\t10\na\t9\nc\t1\n".write(to: url, atomically: true, encoding: .utf8)
        make.reconcileWithDiskForTesting()
        let reloaded = Date().addingTimeInterval(10)
        while Date() < reloaded, sheet.rows.count != 3 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertEqual(sheet.rows.map(\.cells[0]), ["c", "a", "b"], "the new row, still sorted by score")
        if let directory = ProcessInfo.processInfo.environment["SIDE_PREVIEW_SNAPSHOT"] {
            make.view.layoutSubtreeIfNeeded()
            let rep = make.view.bitmapImageRepForCachingDisplay(in: make.view.bounds)!
            make.view.cacheDisplay(in: make.view.bounds, to: rep)
            try? rep.representation(using: NSBitmapImageRep.FileType.png, properties: [:])?
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("make-sheet.png"))
        }
    }

    /// 2026-10-23, the owner: a tab dragged out should become a small window of itself, as
    /// Safari's and Ghostty's do. Each kind of tab has something to show, active or not.
    func testATabHasAPreviewForItsSmallWindow() throws {
        let csv = root.appendingPathComponent("people.csv")
        try "name,city\nAda,London\n".write(to: csv, atomically: true, encoding: .utf8)
        make.revealFile(csv, line: nil)
        let opened = Date().addingTimeInterval(10)
        while Date() < opened, make.activeTabURLForTesting?.lastPathComponent != "people.csv" { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        _ = try open("notes.txt", "a background tab's first lines\n")
        _ = try open("main.swift", (1...40).map { "let value\($0) = \($0) * 2  // a line long enough to see" }.joined(separator: "\n"))
        make.setBottomObstruction(0)

        let active = try XCTUnwrap(make.tabPreviewContent(2), "the tab on screen")
        let rep = try XCTUnwrap(NSBitmapImageRep(data: active.tiffRepresentation!))
        let background = rep.colorAt(x: rep.pixelsWide - 4, y: rep.pixelsHigh - 4)
        var drawn = 0
        for y in stride(from: 0, to: rep.pixelsHigh / 3, by: 3) {
            for x in stride(from: 0, to: rep.pixelsWide / 2, by: 3) where rep.colorAt(x: x, y: y) != background { drawn += 1 }
        }
        XCTAssertGreaterThan(drawn, 100, "the editor's text is in it, though Metal draws it")
        XCTAssertNotNil(make.tabPreviewContent(0), "a sheet in the background")
        XCTAssertNotNil(make.tabPreviewContent(1), "text in the background")

        if let directory = ProcessInfo.processInfo.environment["SIDE_PREVIEW_SNAPSHOT"] {
            for (index, name) in [(2, "drag-window-text.png"), (0, "drag-window-sheet.png"), (1, "drag-window-background.png")] {
                let url = make.activeTabURLForTesting!
                let content = make.tabPreviewContent(index)!
                let image = TabChipView.miniWindow(content: content, title: index == 2 ? url.lastPathComponent : "tab", icon: FileIcon.image(for: url, isDirectory: false))
                let out = MakeWorkspaceViewController.rendered(NSSize(width: image.size.width + 40, height: image.size.height + 40), appearance: make.view.effectiveAppearance) {
                    NSColor.windowBackgroundColor.setFill()
                    NSRect(x: 0, y: 0, width: image.size.width + 40, height: image.size.height + 40).fill()
                    image.draw(at: NSPoint(x: 20, y: 20), from: .zero, operation: .sourceOver, fraction: 1)
                }
                try? NSBitmapImageRep(data: out.tiffRepresentation!)?.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
            }
        }
    }

    /// 2026-10-23, the owner: Writer mode, Make alone, with word count, typewriter scrolling
    /// and the other paragraphs dimmed, each a toggle.
    func testWriterModeLeavesTheTextAlone() throws {
        let text = (1...60).map { "Paragraph \($0) has a few words in it." + ($0 % 3 == 0 ? "\n" : "") }.joined(separator: "\n")
        _ = try open("essay.md", text)
        let alloy = (make.editor as! AlloyEditorEngine).view
        make.setWriterMode(true)
        make.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(make.isWriting)
        XCTAssertNotNil(alloy.readingColumnWidth, "one centered column")
        XCTAssertEqual(make.editor.gutterView.frame.width, 0, "no line numbers")
        XCTAssertTrue(alloy.minimap.isHidden)
        XCTAssertEqual(make.wordCountForTesting, "480 words \u{00B7} 2 min read")

        // The caret in the 5th paragraph's line: that paragraph alone at full strength, held mid-screen.
        let document = try XCTUnwrap(make.editor.document)
        let target = (document.string as NSString).range(of: "Paragraph 14 has")
        make.editor.selectedRange = NSRange(location: target.location, length: 0)
        let line = document.rope.position(of: target.location).line
        XCTAssertEqual(alloy.focusedLines, MakeWorkspaceViewController.paragraphLines(around: line, in: document.text))
        XCTAssertEqual(alloy.focusedLines?.count, 3)
        let caretY = alloy.rect(forCharacterRange: target.location..<target.location).minY - alloy.scrollView.contentView.bounds.minY
        let height = alloy.scrollView.contentView.bounds.height
        XCTAssertEqual(caretY / height, 0.45, accuracy: 0.06, "the typing line mid-screen")
        XCTAssertEqual(alloy.scrollView.contentView.contentInsets.top, 0, "the margin is in the document, so the scroller spans the window")
        XCTAssertGreaterThan(alloy.documentPadding ?? 0, height * 0.3)

        if let directory = ProcessInfo.processInfo.environment["SIDE_PREVIEW_SNAPSHOT"], let image = make.tabPreviewContent(0) {
            try? NSBitmapImageRep(data: image.tiffRepresentation!)?.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("writer-mode.png"))
        }
        make.editor.selectedRange = target
        XCTAssertEqual(make.wordCountForTesting, "3 of 480 words")

        WriterPreferences.set(.dimOthers, false)
        WriterPreferences.set(.wordCount, false)
        defer { WriterPreferences.set(.dimOthers, true); WriterPreferences.set(.wordCount, true) }
        XCTAssertNil(alloy.focusedLines, "a toggle in Settings takes effect at once")
        XCTAssertNil(make.wordCountForTesting)

        make.setWriterMode(false)
        make.view.layoutSubtreeIfNeeded()
        XCTAssertNil(alloy.readingColumnWidth)
        XCTAssertNil(alloy.focusedLines)
        XCTAssertEqual(make.editor.gutterView.frame.width, AlloyGutterView.width, accuracy: 0.5)
    }

    func testParagraphsAndWords() {
        let text = "One two.\nThree four\n\nFive\n" as NSString
        XCTAssertEqual(MakeWorkspaceViewController.paragraphLines(around: 1, in: text), 0...1)
        XCTAssertEqual(MakeWorkspaceViewController.paragraphLines(around: 3, in: text), 3...3)
        XCTAssertEqual(MakeWorkspaceViewController.paragraphLines(around: 2, in: text), 2...2, "a blank line is its own")
        XCTAssertEqual(MakeWorkspaceViewController.wordCount(text, in: NSRange(location: 0, length: text.length)), 5)
        XCTAssertEqual(WriterPreferences.Aid.allCases.filter { !WriterPreferences.isOn($0) }, [.fullScreen], "full screen is the one off by default")
    }

    func testTheShellHidesItsChromeAndLeavesForOtherStages() throws {
        let shell = ShellViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { shell.setWriterMode(false); window.close() }
        window.contentViewController = shell
        shell.showStageForTesting("think")
        shell.setWriterMode(true)
        XCTAssertEqual(shell.currentStageForTesting, "make", "Writer mode is Make")
        XCTAssertTrue(shell.chromeHiddenForTesting)
        XCTAssertEqual(window.standardWindowButton(.closeButton)?.isHidden, true)
        shell.showStageForTesting("think")
        XCTAssertFalse(shell.isWriting, "going to another stage leaves it")
        XCTAssertFalse(shell.chromeHiddenForTesting)
        XCTAssertEqual(window.standardWindowButton(.closeButton)?.isHidden, false)
    }

    /// 2026-10-23, the owner: clicking doesn't always move the caret. Real clicks through the
    /// window, at lines all over the screen, each must land the caret on the line clicked.
    func testEveryClickMovesTheCaret() throws {
        let text = (1...200).map { "line \($0) with some text on it" }.joined(separator: "\n")
        _ = try open("clicks.txt", text)
        window.makeKeyAndOrderFront(nil)
        make.setTopObstruction(ChromeHost.rowHeight)
        make.setBottomObstruction(52)
        let alloy = (make.editor as! AlloyEditorEngine).view
        var misses: [String] = []
        func click(atWindow point: NSPoint) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                window.sendEvent(event)
            }
        }
        for scroll in [0.0, 1200.0] {
            alloy.scrollY = scroll
            alloy.layout()
            for fraction in stride(from: 0.15, through: 0.8, by: 0.05) {
                let clip = alloy.scrollView.contentView
                let local = NSPoint(x: clip.bounds.minX + 120, y: clip.bounds.minY + clip.bounds.height * fraction)
                let expected = alloy.documentLayout.line(atY: local.y).line
                let inWindow = clip.convert(local, to: nil)
                make.editor.selectedRange = NSRange(location: 0, length: 0)
                click(atWindow: inWindow)
                let line = (make.editor.document?.rope.position(of: make.editor.selectedRange.location).line) ?? -1
                if line != expected { misses.append("scroll \(scroll), \(Int(fraction * 100))%: line \(line), expected \(expected), hit \(String(describing: window.contentView?.hitTest(inWindow).map { Swift.type(of: $0) }))") }
            }
        }
        XCTAssertEqual(misses, [], misses.joined(separator: "\n"))

        // Writer mode's typewriter margin above the first line: the caret goes to the first line.
        make.setWriterMode(true)
        defer { make.setWriterMode(false) }
        make.editor.selectedRange = NSRange(location: 0, length: 0)
        make.view.layoutSubtreeIfNeeded()
        make.editor.selectedRange = NSRange(location: 500, length: 0)
        alloy.scrollY = 0
        let clip = alloy.scrollView.contentView
        click(atWindow: clip.convert(NSPoint(x: clip.bounds.midX, y: clip.bounds.minY + 120), to: nil))
        let marginPoint = clip.convert(NSPoint(x: clip.bounds.midX, y: clip.bounds.minY + 120), to: nil)
        XCTAssertEqual(make.editor.document?.rope.position(of: make.editor.selectedRange.location).line, 0,
                       "a click above the text lands on its first line; hit \(String(describing: window.contentView?.hitTest(marginPoint).map { v in sequence(first: v, next: { $0.superview }).map { String(describing: Swift.type(of: $0)) }.joined(separator: " < ") })), clip \(clip.bounds), insets \(clip.contentInsets), doc \(alloy.textView.frame)")
    }

    /// Live Markdown, step 1: a Markdown file switched to Live (and any in Writer Mode) is set
    /// in the reading font, its bold, italic and code in their own fonts; source otherwise.
    func testLiveMarkdownSetsProseInTheReadingFont() throws {
        let url = root.appendingPathComponent("live.md")
        defer { MakeWorkspaceViewController.preferences.removeObject(forKey: MakeWorkspaceViewController.liveMarkdownKey) }
        _ = try open("live.md", "# A title\n\nSome **bold** words, *slanted* ones, and `code`.\n")
        let engine = make.editor as! AlloyEditorEngine
        let layout = { engine.view.documentLayout }
        XCTAssertFalse(engine.isProse, "source until switched")
        make.toggleLiveMarkdown(nil)
        XCTAssertTrue(engine.isProse)
        XCTAssertEqual(CTFontGetSize(layout().font), AlloyEditorEngine.proseSize)
        XCTAssertNotEqual(CTFontCopyFamilyName(layout().font) as String, CTFontCopyFamilyName(DS.Text.editor() as CTFont) as String, "the reading font, not code's")
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, layout().layout(line: 2).fontSpans.count < 3 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let runs = layout().layout(line: 2).fontSpans
        XCTAssertEqual(runs.count, 3, "bold, italic, code")
        XCTAssertTrue(CTFontGetSymbolicTraits(runs[0].font).contains(.traitBold))
        XCTAssertTrue(CTFontGetSymbolicTraits(runs[1].font).contains(.traitItalic))
        XCTAssertTrue(CTFontGetSymbolicTraits(runs[2].font).contains(.traitMonoSpace))
        XCTAssertTrue(CTFontGetSymbolicTraits(layout().layout(line: 0).fontSpans.first!.font).contains(.traitBold), "the heading")
        let heading = layout().layout(line: 0).fontSpans.first!.font
        XCTAssertEqual(CTFontGetSize(heading), (AlloyEditorEngine.proseSize * 1.75).rounded(), "a first-level heading at the preview's size")
        XCTAssertGreaterThan(layout().layout(line: 0).height, layout().layout(line: 2).height, "and its line taller")

        // Step 3: the markup hides away from the caret.
        make.editor.selectedRange = NSRange(location: (make.editor.document!.string as NSString).length, length: 0)
        let hiddenDeadline = Date().addingTimeInterval(5)
        while Date() < hiddenDeadline, layout().layout(line: 2).concealed.count < 6 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let line2 = make.editor.document!.string.components(separatedBy: "\n")[2] as NSString
        XCTAssertEqual(layout().layout(line: 2).concealed.map { line2.substring(with: NSRange($0)) }, ["**", "**", "*", "*", "`", "`"])
        XCTAssertEqual(layout().layout(line: 0).concealed, [0..<2], "the heading's # and its space")
        if let directory = ProcessInfo.processInfo.environment["SIDE_PREVIEW_SNAPSHOT"], let image = make.tabPreviewContent(0) {
            try? NSBitmapImageRep(data: image.tiffRepresentation!)?.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("live-step3.png"))
        }
        make.editor.selectedRange = NSRange(location: (make.editor.document!.string as NSString).range(of: "bold").location, length: 0)
        XCTAssertEqual(layout().layout(line: 2).concealed, [], "the caret's line shows its markup")
        XCTAssertEqual(layout().layout(line: 0).concealed, [0..<2], "the others keep theirs hidden")

        make.toggleLiveMarkdown(nil)
        XCTAssertFalse(engine.isProse, "back to source, remembered")
        make.setWriterMode(true)
        XCTAssertTrue(engine.isProse, "Writer Mode sets Markdown as prose")
        if let directory = ProcessInfo.processInfo.environment["SIDE_PREVIEW_SNAPSHOT"], let image = make.tabPreviewContent(0) {
            try? NSBitmapImageRep(data: image.tiffRepresentation!)?.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("live-step1.png"))
        }
        make.setWriterMode(false)
        XCTAssertFalse(engine.isProse)
        _ = url
    }

    /// Live Markdown, step 4: TeX math typeset in its place away from the caret.
    func testLiveMarkdownTypesetsMath() throws {
        defer { MakeWorkspaceViewController.preferences.removeObject(forKey: MakeWorkspaceViewController.liveMarkdownKey) }
        let text = "# Quadratics\n\nThe roots of $ax^2 + bx + c = 0$ are\n\n$$x = \\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}$$\n\nand it costs $5 to $10.\n\nBroken: $\\notacommand{x}$\n"
        _ = try open("math.md", text)
        let engine = make.editor as! AlloyEditorEngine
        make.toggleLiveMarkdown(nil)
        make.editor.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        let layout = { engine.view.documentLayout }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, layout().layout(line: 2).replacements.isEmpty { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let inline = layout().layout(line: 2)
        XCTAssertEqual(inline.replacements.count, 1, "the inline formula")
        XCTAssertEqual(inline.replacements.first?.range, 13..<32)
        XCTAssertEqual(layout().layout(line: 4).replacements.count, 1, "the displayed one")
        XCTAssertGreaterThan(layout().layout(line: 4).height, layout().layout(line: 2).height, "a fraction needs a taller row")
        XCTAssertEqual(layout().layout(line: 6).replacements, [], "prices aren't math")
        XCTAssertEqual(layout().layout(line: 8).replacements, [], "what can't be typeset stays as source")
        if let directory = ProcessInfo.processInfo.environment["SIDE_PREVIEW_SNAPSHOT"], let image = make.tabPreviewContent(0) {
            try? NSBitmapImageRep(data: image.tiffRepresentation!)?.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("live-step4.png"))
        }
        make.editor.selectedRange = NSRange(location: (text as NSString).range(of: "roots").location, length: 0)
        XCTAssertEqual(layout().layout(line: 2).replacements, [], "the caret's line shows the TeX")
    }

    func testAReadOnlyEditorTakesNoTyping() throws {
        try open("ro.swift", "fixed\n")
        make.editor.isEditable = false
        type("nope")
        XCTAssertEqual(make.editor.document?.string, "fixed\n")
        make.editor.isEditable = true
    }
}
