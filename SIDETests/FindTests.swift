import XCTest
@testable import Side

/// Find in this file (SIDE_RFC_FIND_REVIEW_TRACKS.md, F1): the model, and Make's palette mode.
@MainActor
final class FindTests: XCTestCase {
    func testMatchesAndOptions() {
        let text = "let Value = value + values\nvalue.value()" as NSString
        var find = InFileFind(query: "value", options: .init())
        XCTAssertEqual(find.matches(in: text).ranges.count, 5, "case-insensitive by default")
        find.options.caseSensitive = true
        XCTAssertEqual(find.matches(in: text).ranges.count, 4)
        find.options.wholeWord = true
        XCTAssertEqual(find.matches(in: text).ranges.map(\.location), [12, 27, 33], "not inside values")
        find = InFileFind(query: "val(ue)s?", options: .init(regularExpression: true))
        XCTAssertEqual(find.matches(in: text).ranges.count, 5)
        find.query = "val("
        XCTAssertNotNil(find.expressionError())
        XCTAssertTrue(find.matches(in: text).ranges.isEmpty)
        XCTAssertEqual(InFileFind(query: "a.b", options: .init()).matches(in: "axb a.b" as NSString).ranges.map(\.location), [4], "literal unless asked")
    }

    /// Plain queries take a direct search, not the expression engine: the same matches, across
    /// its 64K chunk edges too, with every option.
    func testTheDirectSearchAgreesWithTheExpressionEngine() {
        var generator = SystemRandomNumberGenerator()
        let alphabet = Array("abAB _-\nÀé1".utf16)
        let text = String(utf16CodeUnits: (0..<200_000).map { _ in alphabet.randomElement(using: &generator)! }, count: 200_000) as NSString
        for query in ["ab", "aB a", "b_", "a", "Ab1", "À", "-a"] {
            for options in [InFileFind.Options(), .init(caseSensitive: true), .init(wholeWord: true), .init(caseSensitive: true, wholeWord: true)] {
                let direct = InFileFind(query: query, options: options).matches(in: text)
                var expressionOptions = options
                expressionOptions.regularExpression = true
                let engine = InFileFind(query: NSRegularExpression.escapedPattern(for: query), options: expressionOptions).matches(in: text)
                XCTAssertEqual(direct, engine, "“\(query)” \(options)")
            }
        }
    }

    func testReplacementsAndStepping() {
        let text = "f(a) f(b)" as NSString
        let find = InFileFind(query: #"f\((\w)\)"#, options: .init(regularExpression: true))
        XCTAssertEqual(find.replaceAllEdits(in: text, template: "g($1)").map(\.text), ["g(a)", "g(b)"])
        let ranges = [NSRange(location: 2, length: 1), NSRange(location: 8, length: 1)]
        XCTAssertEqual(InFileFind.index(of: ranges, from: 3, forward: true), 1)
        XCTAssertEqual(InFileFind.index(of: ranges, from: 9, forward: true), 0, "wraps")
        XCTAssertEqual(InFileFind.index(of: ranges, from: 2, forward: false), 1, "wraps back")
        XCTAssertNil(InFileFind.query(fromSelection: "two\nlines"))
        XCTAssertEqual(MakeWorkspaceViewController.lineNumbers(of: [NSRange(location: 0, length: 1), NSRange(location: 6, length: 1)][...], in: "ab\ncd\nef" as NSString), [1, 3])
    }

    // MARK: In Make

    private var root: URL!
    private var make: MakeWorkspaceViewController!
    private var window: NSWindow!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("find-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        make = MakeWorkspaceViewController()
        make.loadViewIfNeeded()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = container
        let tabs = try XCTUnwrap(make.topRowContent)
        for child in [make.view, tabs, make.paletteSurface!] {
            child.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(child)
        }
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: container.topAnchor), tabs.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tabs.trailingAnchor.constraint(equalTo: container.trailingAnchor), tabs.heightAnchor.constraint(equalToConstant: 30),
            make.view.topAnchor.constraint(equalTo: container.topAnchor), make.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            make.view.leadingAnchor.constraint(equalTo: container.leadingAnchor), make.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            make.paletteSurface.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -60),
            make.paletteSurface.centerXAnchor.constraint(equalTo: container.centerXAnchor), make.paletteSurface.widthAnchor.constraint(equalToConstant: 640),
            make.paletteSurface.heightAnchor.constraint(equalToConstant: 300),
        ])
        window.makeKeyAndOrderFront(nil)
    }

    override func tearDownWithError() throws {
        window?.close(); window = nil; make = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func open(_ text: String) throws {
        let url = root.appendingPathComponent("find.swift")
        try text.write(to: url, atomically: true, encoding: .utf8)
        make.revealFile(url, line: nil)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, make.editor.document?.string != text { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }

    private func type(_ query: String) {
        make.searchField.stringValue = query
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: make.searchField)
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
    }

    private var alloy: AlloyEditorEngine { make.editor as! AlloyEditorEngine }

    func testFindMarksStepsAndReplaces() throws {
        try open("let count = 1\nprint(count)\nlet other = count + 1\n")
        make.editor.selectedRange = NSRange(location: 0, length: 0)
        make.presentFind(replace: false)
        XCTAssertTrue(make.isPaletteOpen)
        type("count")
        let marks = (make.editor.document as? AlloyEditorDocument)?.decorations[.findMatch]?.count
        XCTAssertEqual(marks, 3, "every match marked in the editor")
        XCTAssertEqual(make.editor.selectedRange, NSRange(location: 4, length: 5), "the first match is selected")
        make.findNext(forward: true)
        XCTAssertEqual(make.editor.selectedRange, NSRange(location: 20, length: 5))
        make.findNext(forward: false)
        XCTAssertEqual(make.editor.selectedRange, NSRange(location: 4, length: 5))
        XCTAssertGreaterThan(make.editor.scrollView.contentInsets.bottom, 150, "the editor scrolls above the palette")

        make.replaceField.stringValue = "total"
        make.perform(Selector(("replaceAll")))
        XCTAssertEqual(make.editor.document?.string, "let total = 1\nprint(total)\nlet other = total + 1\n")
        alloy.view.textView.undo(nil)
        XCTAssertEqual(make.editor.document?.string, "let count = 1\nprint(count)\nlet other = count + 1\n", "Replace All is one undo step")
    }

    /// Find in the terminal (⌘F in the Terminal stage): the same palette, without the editor's
    /// options or replace; Return steps up through older output; the keys stay in the palette;
    /// Escape gives the terminal its focus back and clears the highlights. The editor's Find
    /// afterwards has its options again.
    func testFindInTheTerminalUsesThePalette() throws {
        let surface = AlloyTerminalSurface(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        surface.applyTheme(TerminalSurfaceTheme(foreground: .white, background: .black,
                                                palette: TerminalViewController.ansiPaletteColors(dark: true), backgroundOpacity: 1))
        window.contentView?.addSubview(surface, positioned: .below, relativeTo: make.paletteSurface)
        surface.display(text: "first needle\r\n" + String(repeating: "hay\r\n", count: 40) + "last needle here")
        XCTAssertTrue(waitUntil { surface.visibleText().contains("last needle") })
        window.makeFirstResponder(surface)
        XCTAssertTrue((window.firstResponder as? NSView)?.isDescendant(of: surface) == true)

        make.presentTerminalFind(surface)
        XCTAssertTrue(make.isPaletteOpen)
        XCTAssertTrue(make.findOptionsShownForTesting == (false, false), "no case, word, expression or replace")
        type("needle")
        XCTAssertTrue(waitUntil { self.make.terminalFindCountForTesting == "1 of 2" }, make.terminalFindCountForTesting)
        XCTAssertEqual(surface.searchHighlightsForTesting.selected.first?[1...2], [5, 10], "the newest match, selected")

        let fieldEditor = try XCTUnwrap(make.searchField.currentEditor() as? NSTextView)
        XCTAssertTrue(make.control(make.searchField, textView: fieldEditor, doCommandBy: #selector(NSResponder.insertNewline(_:))), "Return stays in the palette")
        XCTAssertTrue(waitUntil { self.make.terminalFindCountForTesting == "2 of 2" }, make.terminalFindCountForTesting)
        XCTAssertTrue(surface.scrollbarForTesting.isScrolledBack, "the older match, scrolled to")

        XCTAssertTrue(make.control(make.searchField, textView: fieldEditor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertFalse(make.isPaletteOpen)
        XCTAssertTrue((window.firstResponder as? NSView)?.isDescendant(of: surface) == true, "typing goes back to the terminal: \(String(describing: window.firstResponder))")
        XCTAssertTrue(waitUntil { surface.searchHighlightsForTesting.matches.isEmpty && surface.findStatus.total == 0 })

        try open("let count = 1\n")
        make.presentFind(replace: false)
        XCTAssertTrue(make.findOptionsShownForTesting == (true, true), "the editor's Find keeps its options")
        XCTAssertEqual(make.searchField.placeholderString, "Find in find.swift")
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline { if condition() { return true }; RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return condition()
    }

    /// 2026-10-23, the owner: "Does Find work in a table?" It does: each cell is searched, the
    /// matches are marked, and stepping moves the active cell; a sheet isn't edited, so no replace.
    func testFindWorksInASheetWithoutReplace() throws {
        let url = root.appendingPathComponent("people.csv")
        try "name,city\nAda,London\nGrace,New York\nAlan,London\n".write(to: url, atomically: true, encoding: .utf8)
        make.revealFile(url, line: nil)
        let sheet = make.sheetViewForTesting
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, sheet.rows.count != 3 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        make.presentFind(replace: true)
        XCTAssertTrue(make.isPaletteOpen)
        XCTAssertFalse(make.findReplaceShownForTesting, "nothing to replace in")
        type("london")
        XCTAssertEqual(sheet.anchor, CellRef(row: 0, column: 1), "the first match is the active cell")
        XCTAssertEqual(sheet.name(of: sheet.anchor!), "B2")
        make.findNext(forward: true)
        XCTAssertEqual(sheet.anchor, CellRef(row: 2, column: 1))
        make.findNext(forward: true)
        XCTAssertEqual(sheet.anchor, CellRef(row: 0, column: 1), "wraps")
        type("new york")
        XCTAssertEqual(sheet.anchor, CellRef(row: 1, column: 1), "a match across a space in one cell")
        type("ada\nlondon")
        XCTAssertEqual(sheet.anchor, CellRef(row: 1, column: 1), "no match across two cells: the active cell stays")
    }

    func testFindWorksInAMarkdownPreviewWithoutReplace() throws {
        let url = root.appendingPathComponent("notes.md")
        try "# Launch plan\n\nBefore **launch**, check the list.\n".write(to: url, atomically: true, encoding: .utf8)
        make.revealFile(url, line: nil)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, make.editor.document?.string.isEmpty ?? true { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        make.toggleMarkdownPreviewForTesting()
        let preview = make.markdownPreviewForTesting
        while Date() < deadline, preview.string.isEmpty { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        preview.setSelectedRange(NSRange(location: 0, length: 0))
        make.presentFind(replace: true)
        XCTAssertFalse(make.findReplaceShownForTesting, "a preview is the rendering: nothing to replace in it")
        type("launch")
        let text = preview.string as NSString
        let first = text.range(of: "Launch")
        XCTAssertEqual(preview.selectedRange(), first, "the rendered text's first match, case-insensitive")
        var effective = NSRange()
        let mark = preview.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: text.range(of: "launch").location, effectiveRange: &effective)
        XCTAssertNotNil(mark, "every match is marked in the preview")
        make.findNext(forward: true)
        XCTAssertEqual(preview.selectedRange(), text.range(of: "launch"))
        make.perform(Selector(("dismissQuickOpen")))
        XCTAssertNil(preview.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: first.location, effectiveRange: &effective))
    }

    /// `SIDE_FIND_SNAPSHOT=<png>`: a picture of the window with Find and Replace open.
    func testSnapshot() throws {
        guard let path = ProcessInfo.processInfo.environment["SIDE_FIND_SNAPSHOT"] else { throw XCTSkip("snapshot not asked for") }
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("SIDE/InFileFind.swift"), encoding: .utf8)
        try open(source)
        make.setBottomObstruction(44)
        make.presentFind(replace: true)
        type("matches")
        make.findNext(forward: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        // Captured from outside (a test can't capture its own window): the window number goes
        // to a file, and the window stays up while it's taken.
        try "\(window.windowNumber)".write(toFile: path + ".window", atomically: true, encoding: .utf8)
        RunLoop.main.run(until: Date().addingTimeInterval(6))
    }

    func testClosingClearsTheMarksAndKeepsTheMatchSelected() throws {
        try open("alpha beta alpha\n")
        make.presentFind(replace: true)
        type("alpha")
        make.findNext(forward: true)
        let selected = make.editor.selectedRange
        make.perform(Selector(("dismissQuickOpen")))
        XCTAssertFalse(make.isPaletteOpen)
        XCTAssertTrue((make.editor.document as? AlloyEditorDocument)?.decorations[.findMatch]?.isEmpty ?? true)
        XCTAssertLessThan(make.editor.scrollView.contentInsets.bottom, 60, "and its inset goes back")
        XCTAssertEqual(make.editor.selectedRange, selected)
        // ⌘G still steps with the palette closed.
        make.findNext(forward: true)
        XCTAssertNotEqual(make.editor.selectedRange, selected)
    }
}
