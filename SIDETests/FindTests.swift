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
