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
            let size = TabDragOverlay.cardSize(for: window.frame.size, outside: true)
            for (index, name) in [(2, "drag-window-text.png"), (0, "drag-window-sheet.png"), (1, "drag-window-background.png")] {
                let image = TabChipView.miniWindow(content: make.tabPreviewContent(index)!, size: size)
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

    private func mouse(_ type: NSEvent.EventType, _ point: NSPoint, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    /// Direction 03 §4.2: a tab lifts after 3 pt in any direction, follows the pointer along the
    /// strip as its neighbours make way, stretches across the strip's edge, tears into a big card
    /// past it, comes back a chip over the strip, and sets down where it's dropped.
    func testATabLiftsReordersTearsIntoACardAndSetsDown() throws {
        for name in ["a.swift", "b.swift", "c.swift"] { _ = try open(name, "let \(name.first!) = 1\n") }
        let strip = make.tabStripForTesting
        make.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(strip.chips.map(\.title), ["a.swift", "b.swift", "c.swift"])
        let chip = strip.chips[0]
        let start = chip.convert(NSPoint(x: chip.bounds.midX, y: chip.bounds.midY), to: nil)
        chip.mouseDown(with: mouse(.leftMouseDown, start))
        chip.mouseDragged(with: mouse(.leftMouseDragged, NSPoint(x: start.x, y: start.y - 2)))
        XCTAssertEqual(chip.phase, .pressed, "2 pt isn't a drag")
        // Straight down, inside the strip's band: lifted, and stretching, not torn.
        chip.mouseDragged(with: mouse(.leftMouseDragged, NSPoint(x: start.x, y: start.y - 10)))
        XCTAssertEqual(chip.phase, .lifted, "a pull straight down lifts it too")
        let overlay = try XCTUnwrap(chip.overlayForTesting)
        let held = overlay.cardFrameForTesting
        XCTAssertLessThan(held.midY, window.convertPoint(toScreen: start).y, "it stretches toward the pointer")
        XCTAssertGreaterThan(held.midY, window.convertPoint(toScreen: start).y - 12, "but never further than the stretch")

        // Along the strip past the third tab: it takes the last place.
        let third = strip.chips[2].convert(NSPoint(x: strip.chips[2].bounds.maxX - 2, y: 0), to: nil)
        chip.mouseDragged(with: mouse(.leftMouseDragged, NSPoint(x: third.x, y: start.y)))
        XCTAssertEqual(strip.chips.map(\.title), ["b.swift", "c.swift", "a.swift"])
        XCTAssertEqual(make.openTabURLsForTesting.map(\.lastPathComponent), ["b.swift", "c.swift", "a.swift"], "the model follows")

        // Down past the strip: a card, the window's proportions.
        chip.mouseDragged(with: mouse(.leftMouseDragged, NSPoint(x: third.x, y: start.y - 120)))
        XCTAssertEqual(chip.phase, .torn)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        let card = overlay.cardFrameForTesting
        XCTAssertEqual(card.size, TabDragOverlay.cardSize(for: window.frame.size, outside: false))
        XCTAssertGreaterThanOrEqual(card.width, 340, "big, as Rex's is")
        XCTAssertTrue(overlay.isShowingCardForTesting)

        // Back over the strip: a chip again, then set down there.
        chip.mouseDragged(with: mouse(.leftMouseDragged, NSPoint(x: start.x, y: start.y)))
        XCTAssertEqual(chip.phase, .lifted)
        chip.mouseUp(with: mouse(.leftMouseUp, NSPoint(x: start.x, y: start.y)))
        XCTAssertEqual(chip.phase, .idle)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertEqual(chip.alphaValue, 1, "the tab is back in its slot")
        XCTAssertEqual(strip.chips.first?.title, "a.swift", "dropped at the front")
        XCTAssertEqual(make.openTabURLsForTesting.map(\.lastPathComponent), ["a.swift", "b.swift", "c.swift"])
    }

    /// 2026-10-31, the owner's sequence that left new tabs blank: open, close, open in the same
    /// slot. The tint stays under every chip.
    func testOpeningAndClosingKeepsTheTintUnderTheTabs() throws {
        _ = try open("greeter.ts", "a\n")
        _ = try open("AGENTS.md", "b\n")
        let strip = make.tabStripForTesting
        var order: [String] = []
        for name in ["README.md", "mathUtils.ts", "README.md"] {
            _ = try open(name, name)
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            order.append("\(name) open: \(strip.tintIsUnderTheChipsForTesting)")
            make.closeTabForTesting(named: name)
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            order.append("\(name) closed: \(strip.tintIsUnderTheChipsForTesting)")
        }
        _ = try open("README.md", "README.md")
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertTrue(strip.tintIsUnderTheChipsForTesting, order.joined(separator: "; "))
        XCTAssertFalse(order.contains { $0.hasSuffix("false") }, order.joined(separator: "; "))
    }

    /// 2026-10-31, the owner: a new tab, or one dropped back from its card, sometimes showed
    /// blank until clicked. In every record it was laid out and drawn; on screen the strip's mask,
    /// shaped to the glass track from the tabs' old width, cut it off. Only the window server's
    /// pixels show that, so this reads them, in a window made as the app makes it.
    func testANewTabAndATabDroppedBackShowOnScreen() throws {
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage") else { throw XCTSkip("no window capture") }
        let capture = unsafeBitCast(symbol, to: Capture.self)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1300, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let shell = ShellViewController()
        window.contentViewController = shell
        shell.installChrome(in: window)
        window.makeKeyAndOrderFront(nil)
        let names = ["greeter.ts", "AGENTS.md", "README.md"]
        for name in names { try "// \(name)\n".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        shell.openProject(at: root, focusingTrackKey: nil)
        func settle(_ seconds: Double) { let end = Date().addingTimeInterval(seconds); while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.016)) } }
        settle(1.5)
        window.setFrame(NSRect(x: 100, y: 100, width: 1300, height: 800), display: true)
        settle(0.5)
        let make = shell.makeForTesting
        /// Dark pixels where a chip's title is, in what's actually on screen.
        func ink(_ chip: TabChipView) throws -> Int {
            guard let image = capture(.null, 8, UInt32(window.windowNumber), 1)?.takeRetainedValue() else { throw XCTSkip("window capture refused") }
            let rep = NSBitmapImageRep(cgImage: image)
            let scale = CGFloat(image.width) / window.frame.width
            let frame = chip.convert(chip.bounds, to: nil)
            var dark = 0
            for x in stride(from: Int((frame.minX + 14) * scale), to: Int((frame.maxX - 24) * scale), by: 2) {
                for y in stride(from: Int((window.frame.height - frame.maxY) * scale), to: Int((window.frame.height - frame.minY) * scale), by: 2) {
                    if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.brightnessComponent < 0.45 { dark += 1 }
                }
            }
            return dark
        }
        for name in names.dropLast() {
            make.revealFile(root.appendingPathComponent(name), line: nil)
            settle(0.8)
        }
        let strip = make.tabStripForTesting
        // Intermittent: opened and closed again and again, as the owner did.
        var blank: [Int] = []
        for round in 0..<6 {
            make.revealFile(root.appendingPathComponent("README.md"), line: nil)
            settle(0.8)
            let arrived = try XCTUnwrap(strip.chips.last)
            if try ink(arrived) <= 20 { blank.append(round) }
            if round < 5 {
                make.closeTabForTesting(named: "README.md")
                settle(0.8)
            }
        }
        XCTAssertEqual(blank, [], "every new tab's title on screen")
        let arrived = try XCTUnwrap(strip.chips.last)

        // Torn out into its card and dropped back in the strip.
        func mouse(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let start = arrived.convert(NSPoint(x: arrived.bounds.midX, y: arrived.bounds.midY), to: nil)
        arrived.mouseDown(with: mouse(.leftMouseDown, start))
        arrived.mouseDragged(with: mouse(.leftMouseDragged, NSPoint(x: start.x, y: start.y - 10)))
        arrived.mouseDragged(with: mouse(.leftMouseDragged, NSPoint(x: start.x, y: start.y - 200)))
        XCTAssertEqual(arrived.phase, .torn)
        settle(0.6)
        arrived.mouseDragged(with: mouse(.leftMouseDragged, start))
        arrived.mouseUp(with: mouse(.leftMouseUp, start))
        settle(1)
        let back = try XCTUnwrap(strip.chips.first { $0.title == "README.md" })
        XCTAssertGreaterThan(try ink(back), 20, "dropped back, its title is on screen")
    }

    /// 2026-10-31, the owner: the strip's reveal with a second tab played only sometimes. Every
    /// time, the track springs open from the first tab.
    func testTheStripOpensOutEveryTime() throws {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1300, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let shell = ShellViewController()
        window.contentViewController = shell
        shell.installChrome(in: window)
        window.makeKeyAndOrderFront(nil)
        for name in ["one.swift", "two.swift"] { try "// \(name)\n".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        shell.openProject(at: root, focusingTrackKey: nil)
        func settle(_ seconds: Double) { let end = Date().addingTimeInterval(seconds); while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.004)) } }
        settle(1.5)
        let make = shell.makeForTesting
        make.revealFile(root.appendingPathComponent("one.swift"), line: nil)
        settle(0.8)
        let strip = make.tabStripForTesting
        var notes: [String] = []
        for round in 0..<5 {
            let before = strip.appearCountForTesting
            make.revealFile(root.appendingPathComponent("two.swift"), line: nil)
            let deadline = Date().addingTimeInterval(3)
            while strip.chips.count < 2, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.002)) }
            let glass = strip.bar.subviews.first { String(describing: Swift.type(of: $0)).contains("Glass") }
            let springing = !(glass?.layer?.animationKeys()?.isEmpty ?? true)
            notes.append("round \(round): appear ran \(strip.appearCountForTesting > before), track springing \(springing), chips \(strip.chips.count)")
            settle(0.8)
            make.closeTabForTesting(named: "two.swift")
            settle(0.8)
        }
        XCTAssertEqual(notes.filter { $0.contains("appear ran true") }.count, 5, notes.joined(separator: "\n"))
        XCTAssertEqual(notes.filter { $0.contains("track springing true") }.count, 5, notes.joined(separator: "\n"))
    }

    /// 2026-10-31, the owner: the palette looked squeezed into the bar. It grows out of the nav's
    /// capsule evenly, keeping its proportions, and back into it.
    func testThePaletteMorphsOutOfTheNavAndBack() throws {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1300, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let shell = ShellViewController()
        window.contentViewController = shell
        shell.installChrome(in: window)
        window.makeKeyAndOrderFront(nil)
        try "x".write(to: root.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
        shell.openProject(at: root, focusingTrackKey: nil)
        func settle(_ seconds: Double) { let end = Date().addingTimeInterval(seconds); while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.004)) } }
        settle(1.5)
        window.setFrame(NSRect(x: 100, y: 100, width: 1300, height: 800), display: true)
        settle(0.5)
        var notes = ["nav capsule \(shell.paletteOriginForTesting())"]
        shell.makeForTesting.presentPalette(.files)
        let t0 = Date()
        for ms in [0, 30, 80, 150, 250, 400, 600] {
            while Date().timeIntervalSince(t0) * 1000 < Double(ms) { RunLoop.main.run(until: Date().addingTimeInterval(0.004)) }
            let layer = shell.paletteLayerForTesting
            let shown = layer?.presentation() ?? layer
            notes.append("open \(ms)ms frame \(String(describing: shown?.frame)) radius \(shown?.cornerRadius ?? -1) opacity \(shown?.opacity ?? -1) model \(String(describing: layer?.frame))")
        }
        shell.makeForTesting.dismissPaletteForTesting()
        let t1 = Date()
        for ms in [0, 60, 150, 300, 500] {
            while Date().timeIntervalSince(t1) * 1000 < Double(ms) { RunLoop.main.run(until: Date().addingTimeInterval(0.004)) }
            let layer = shell.paletteLayerForTesting
            let shown = layer?.presentation() ?? layer
            notes.append("close \(ms)ms frame \(String(describing: shown?.frame)) radius \(shown?.cornerRadius ?? -1) opacity \(shown?.opacity ?? -1)")
        }
        func frame(_ line: String) -> NSRect {
            let inside = line.components(separatedBy: "frame Optional(")[1].components(separatedBy: ")")[0].replacingOccurrences(of: "(", with: "")
            let n = inside.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            return NSRect(x: n[0], y: n[1], width: n[2], height: n[3])
        }
        let capsule = shell.paletteOriginForTesting()
        // Sample times stretch under load, so judge the curve's shape, not its clock: every
        // in-flight frame sits on the capsule's centre line at the settled proportions, and the
        // close ends at the capsule's width.
        let all = notes.filter { $0.contains("frame Optional(") }.map { ($0, frame($0)) }.filter { $0.1.width > 0 }
        let settled = frame(notes.first { $0.hasPrefix("open 600ms") }!)
        XCTAssertGreaterThan(settled.width, capsule.width * 1.5, "to its own size")
        let moving = all.filter { $0.1.width < settled.width - 1 }
        XCTAssertFalse(moving.isEmpty, "it grows rather than appearing: \(notes.joined(separator: "\n"))")
        for (line, f) in moving {
            XCTAssertGreaterThanOrEqual(f.width, capsule.width - 4, "never smaller than the capsule: \(line)")
            XCTAssertEqual(f.midX, capsule.midX, accuracy: 6, "out of the capsule, evenly: \(line)")
            XCTAssertEqual(f.width / f.height, settled.width / settled.height, accuracy: 0.05, "never squeezed: \(line)")
        }
        XCTAssertTrue(shell.paletteLayerForTesting.map { _ in true } ?? false)
    }

    /// 2026-10-31, the owner: after a tab was dropped outside its window, its card stayed over
    /// every app. The card goes once the landing is over, window or not.
    func testADroppedCardLeavesTheScreen() throws {
        for name in ["a.swift", "b.swift"] { _ = try open(name, "let \(name.first!) = 1\n") }
        let chip = make.tabStripForTesting.chips[1]
        let before = TabDragOverlay.panelsOnScreenForTesting
        let start = chip.convert(NSPoint(x: chip.bounds.midX, y: chip.bounds.midY), to: nil)
        chip.mouseDown(with: mouse(.leftMouseDown, start))
        chip.mouseDragged(with: mouse(.leftMouseDragged, NSPoint(x: start.x, y: start.y - 10)))
        chip.mouseDragged(with: mouse(.leftMouseDragged, NSPoint(x: start.x, y: start.y - 200)))
        // Released outside the window.
        let outside = NSPoint(x: window.frame.width + 300, y: start.y - 200)
        chip.mouseDragged(with: mouse(.leftMouseDragged, outside))
        chip.mouseUp(with: mouse(.leftMouseUp, outside))
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline, TabDragOverlay.panelsOnScreenForTesting > before { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertEqual(TabDragOverlay.panelsOnScreenForTesting, before, "the card is gone")
    }

    /// The drag's two looks, for the eye (SIDE_PREVIEW_SNAPSHOT): the lifted chip and the card.
    func testTheDragLayerSnapshots() throws {
        guard let directory = ProcessInfo.processInfo.environment["SIDE_PREVIEW_SNAPSHOT"] else { throw XCTSkip("snapshot not asked for") }
        _ = try open("one.swift", (1...30).map { "let value\($0) = \($0)" }.joined(separator: "\n"))
        _ = try open("two.swift", "let two = 2\n")
        let chip = make.tabStripForTesting.chips[1]
        let start = chip.convert(NSPoint(x: chip.bounds.midX, y: chip.bounds.midY), to: nil)
        chip.mouseDown(with: mouse(.leftMouseDown, start))
        chip.mouseDragged(with: mouse(.leftMouseDragged, NSPoint(x: start.x - 20, y: start.y - 6)))
        let overlay = try XCTUnwrap(chip.overlayForTesting)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        for (name, image) in [("drag-chip.png", overlay.renderedForTesting(backdrop: .white))] {
            try? NSBitmapImageRep(data: image!.tiffRepresentation!)?.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
        }
        chip.mouseDragged(with: mouse(.leftMouseDragged, NSPoint(x: start.x, y: start.y - 140)))
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        if let image = overlay.renderedForTesting(backdrop: .white) {
            try? NSBitmapImageRep(data: image.tiffRepresentation!)?.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("drag-card.png"))
        }
        chip.mouseUp(with: mouse(.leftMouseUp, start))
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
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

    /// Live Markdown, step 5: whole lines as blocks (a local picture, a remote one's placeholder,
    /// a rule, a centered formula), a table's columns lined up, front matter as a band.
    func testLiveMarkdownBlocks() throws {
        defer { MakeWorkspaceViewController.preferences.removeObject(forKey: MakeWorkspaceViewController.liveMarkdownKey) }
        let picture = NSImage(size: NSSize(width: 320, height: 160))
        picture.lockFocus()
        NSColor.systemTeal.setFill(); NSRect(x: 0, y: 0, width: 320, height: 160).fill()
        NSColor.white.setFill(); NSBezierPath(ovalIn: NSRect(x: 120, y: 40, width: 80, height: 80)).fill()
        picture.unlockFocus()
        try NSBitmapImageRep(data: picture.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("diagram.png"))
        let text = """
        ---
        title: Blocks
        tags: [a, b]
        ---

        # Blocks

        ![A diagram](diagram.png)

        ![Remote](https://example.com/cat.png)

        ---

        $$\\int_0^1 x\\,dx = \\frac{1}{2}$$

        | Name | Role |
        |---|---|
        | Ada | Engineer |
        | Grace Hopper | Admiral |

        End.
        """
        _ = try open("blocks.md", text)
        let engine = make.editor as! AlloyEditorEngine
        make.toggleLiveMarkdown(nil)
        make.editor.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        let layout = { engine.view.documentLayout }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, layout().layout(line: 14).replacements.isEmpty { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

        XCTAssertEqual(layout().layout(line: 7).replacements.count, 1, "the local picture")
        XCTAssertEqual(layout().layout(line: 7).replacements.first?.size.height, 160, "at its size (it fits the column)")
        XCTAssertLessThan(layout().layout(line: 7).height, 160 + layout().lineHeight, "its row holds it, and the line's space below")
        XCTAssertTrue(layout().layout(line: 9).replacements.first?.key.hasPrefix("placeholder|Image from example.com") ?? false, "the remote one waits")
        XCTAssertTrue(layout().layout(line: 11).replacements.first?.key.hasPrefix("rule|") ?? false, "a rule")
        let formula = try XCTUnwrap(layout().layout(line: 13).replacements.first)
        XCTAssertNotNil(formula.drawSize, "a displayed formula alone on its line is centered")
        XCTAssertEqual(layout().layout(line: 0).replacements.count, 1, "front matter's --- takes no room")
        XCTAssertNotNil(engine.view.lineBackground?(1), "its band")
        XCTAssertNil(engine.view.lineBackground?(6))

        // The table: the pipe after each cell at its column's edge, so every row's lines up.
        func pipeXs(_ line: Int) -> [CGFloat] {
            let laid = layout().layout(line: line)
            let units = Array(laid.text.utf16)
            return units.indices.filter { units[$0] == 0x7C }.dropFirst().map { laid.caretX(at: $0 + 1).x }
        }
        XCTAssertEqual(layout().layout(line: 16).replacements.count, 1, "the |---| row is a line")
        let header = pipeXs(15), ada = pipeXs(17), grace = pipeXs(18)
        XCTAssertEqual(header.count, 2)
        for (a, b) in zip(header, ada) { XCTAssertEqual(a, b, accuracy: 1, "columns line up") }
        for (a, b) in zip(header, grace) { XCTAssertEqual(a, b, accuracy: 1) }
        make.editor.selectedRange = NSRange(location: (text as NSString).range(of: "Ada").location, length: 0)
        for (a, b) in zip(header, pipeXs(17)) { XCTAssertEqual(a, b, accuracy: 1, "and stay lined up on the caret's line") }
        make.editor.selectedRange = NSRange(location: (text as NSString).length, length: 0)

        if let directory = ProcessInfo.processInfo.environment["SIDE_PREVIEW_SNAPSHOT"], let image = make.tabPreviewContent(0) {
            try? NSBitmapImageRep(data: image.tiffRepresentation!)?.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("live-step5.png"))
            engine.view.scrollY = layout().y(ofLine: 11)
            engine.view.render()
            if let lower = make.tabPreviewContent(0) {
                try? NSBitmapImageRep(data: lower.tiffRepresentation!)?.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent("live-step5-table.png"))
            }
        }
    }

    /// Markdown's formatting: ⌘B and ⌘I wrap or unwrap, ⌘K makes a link; their keys are live
    /// in Markdown files only.
    func testMarkdownFormattingCommands() throws {
        _ = try open("notes.md", "Make this bold and that a link.\nSee https://example.com now.\n")
        XCTAssertEqual(Shortcuts.activeContext, .markdown)
        func text() -> String { make.editor.document!.string }
        func select(_ word: String) { make.editor.selectedRange = (text() as NSString).range(of: word) }

        select("bold")
        make.formatBold(nil)
        XCTAssertTrue(text().hasPrefix("Make this **bold** and"))
        XCTAssertEqual((text() as NSString).substring(with: make.editor.selectedRange), "bold", "the word stays selected")
        make.formatBold(nil)
        XCTAssertTrue(text().hasPrefix("Make this bold and"), "again: unwrapped")

        make.editor.selectedRange = NSRange(location: (text() as NSString).range(of: "this").location + 2, length: 0)
        make.formatItalic(nil)
        XCTAssertTrue(text().hasPrefix("Make *this* bold"), "nothing selected: the word under the caret")
        select("*this*")
        make.formatItalic(nil)
        XCTAssertTrue(text().hasPrefix("Make this bold"), "the marks inside the selection come off too")

        select("bold")
        make.formatBold(nil)
        select("bold")
        make.formatItalic(nil)
        XCTAssertTrue(text().hasPrefix("Make this ***bold*** and"), "italic inside bold")
        select("bold")
        make.formatItalic(nil)
        XCTAssertTrue(text().hasPrefix("Make this **bold** and"), "and out again, the bold kept")

        select("that a link")
        make.formatLink(nil)
        XCTAssertTrue(text().contains("[that a link](url)."))
        XCTAssertEqual((text() as NSString).substring(with: make.editor.selectedRange), "url", "the address to type over")
        select("https://example.com")
        make.formatLink(nil)
        XCTAssertTrue(text().contains("See [](https://example.com) now."), "a selected address becomes the target")
        XCTAssertEqual(make.editor.selectedRange.length, 0)

        _ = try open("code.swift", "let x = 1\n")
        XCTAssertNil(Shortcuts.activeContext, "back to every file's shortcuts")
    }

    func testAReadOnlyEditorTakesNoTyping() throws {
        try open("ro.swift", "fixed\n")
        make.editor.isEditable = false
        type("nope")
        XCTAssertEqual(make.editor.document?.string, "fixed\n")
        make.editor.isEditable = true
    }

    /// Pictures of each editor theme in each appearance: Make with a file and with none, and
    /// Review's diff. Only with SIDE_THEME_GALLERY set (a folder), to look at by eye.
    func testThemeGallery() throws {
        guard let directory = ProcessInfo.processInfo.environment["SIDE_THEME_GALLERY"] else { throw XCTSkip("SIDE_THEME_GALLERY not set") }
        let code = """
        import Foundation

        /// A track's state, as the sidebar shows it.
        struct Track: Codable {
            let name: String
            var count = 42 // checkpoints
            func label(_ prefix: String) -> String { "\\(prefix): \\(name)" }
        }
        """
        let diffText = """
        diff --git a/a.swift b/a.swift
        --- a/a.swift
        +++ b/a.swift
        @@ -1,4 +1,4 @@
         import Foundation
        -let count = 1
        +let count = 2 // more
         func run() { print("hi") }
        """
        let diffWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        diffWindow.isReleasedWhenClosed = false
        let diff = DiffDocumentView(frame: diffWindow.contentRect(forFrameRect: diffWindow.frame))
        diff.autoresizingMask = [.width, .height]
        diffWindow.contentView = diff
        diffWindow.orderFront(nil)
        defer { diffWindow.close(); DS.Appearance.preference = .system; EditorThemes.lightThemeID = EditorThemes.sideID; EditorThemes.darkThemeID = EditorThemes.sideID }
        func settle() { let end = Date().addingTimeInterval(0.4); while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) } }
        func picture(_ root: NSView, _ name: String) {
            root.layoutSubtreeIfNeeded()
            root.displayIfNeeded()
            let image = NSImage(size: root.bounds.size)
            image.lockFocusFlipped(root.isFlipped)
            // The layer tree, not cacheDisplay: layer backgrounds (the gutter's, a header's) are
            // only in the layers.
            if let context = NSGraphicsContext.current?.cgContext, let layer = root.layer {
                func display(_ layer: CALayer) { layer.displayIfNeeded(); layer.sublayers?.forEach(display) }
                display(layer)
                layer.render(in: context)
            }
            // Metal draws the text, which a view snapshot leaves out: each editor drawn over its place.
            func editors(_ view: NSView) -> [AlloyEditorView] { (view as? AlloyEditorView).map { [$0] } ?? view.subviews.flatMap(editors) }
            for editor in editors(root) where !editor.isHiddenOrHasHiddenAncestor {
                guard let shot = editor.snapshot() else { continue }
                let clip = editor.scrollView.contentView
                var frame = clip.convert(clip.bounds, to: root)
                frame = frame.intersection(root.bounds)
                if !root.isFlipped { frame.origin.y = root.bounds.height - frame.maxY }
                shot.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            image.unlockFocus()
            let out = NSBitmapImageRep(data: image.tiffRepresentation!)!
            try? out.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
        }
        let url = root.appendingPathComponent("Track.swift")
        try code.write(to: url, atomically: true, encoding: .utf8)
        for dark in [false, true] {
            DS.Appearance.preference = dark ? .dark : .light
            NotificationCenter.default.post(name: DS.Appearance.didChangeNotification, object: nil)
            for theme in [EditorThemes.sideID] + EditorThemes.builtIn.map(\.id) {
                if dark { EditorThemes.darkThemeID = theme } else { EditorThemes.lightThemeID = theme }
                let name = "\(dark ? "dark" : "light")-\(theme)"
                make.closeAllTabsForTesting()
                settle()
                picture(window.contentView!, name + "-empty")
                _ = try open("Track.swift", code)
                make.editor.selectedRange = NSRange(location: 60, length: 12)
                settle()
                picture(window.contentView!, name + "-make")
                if let tabs = make.topRowContent { picture(tabs, name + "-tabs") }
                _ = try open("Notes.md", "# Notes\n\nSome *text*, `code` and a [link](https://example.com).\n\n```swift\nlet x = 1\n```\n")
                make.toggleMarkdownPreviewForTesting()
                settle()
                picture(window.contentView!, name + "-preview")
                make.toggleMarkdownPreviewForTesting()
                diff.render(diffText: diffText)
                settle()
                picture(diff, name + "-diff")
            }
        }
    }
}
