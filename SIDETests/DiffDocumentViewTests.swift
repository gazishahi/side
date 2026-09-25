import AlloyAppKit
import XCTest
@testable import Side

/// Review's diff on Alloy (SIDE_RFC_FIND_REVIEW_TRACKS.md, R2).
@MainActor
final class DiffDocumentViewTests: XCTestCase {
    private var window: NSWindow!
    private var view: DiffDocumentView!

    private let diff = """
    diff --git a/Sources/a.swift b/Sources/a.swift
    index 1..2 100644
    --- a/Sources/a.swift
    +++ b/Sources/a.swift
    @@ -1,3 +1,3 @@
     let a = 1
    -let b = 2
    +let b = 3
     let c = 4
    diff --git a/notes.md b/notes.md
    new file mode 100644
    --- /dev/null
    +++ b/notes.md
    @@ -0,0 +1,2 @@
    +# Notes
    +text
    """

    override func setUpWithError() throws {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = container
        view = DiffDocumentView()
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor), view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor), view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        window.orderFront(nil)
    }

    override func tearDownWithError() throws { window.close() }

    private func settle(_ seconds: TimeInterval = 0.1) {
        window.layoutIfNeeded()
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { autoreleasepool { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) } }
    }

    func testOneDocumentWithHeadersOverTheirRows() throws {
        view.diffLayout = .unified
        view.render(diffText: diff)
        settle()
        // a.swift: 2 header rows, a hunk, 4 lines; a gap; notes.md: 2 header rows, a hunk, 2 lines.
        XCTAssertEqual(view.rowCount, 2 + 1 + 4 + 1 + 2 + 1 + 2)
        XCTAssertEqual(view.visibleHeaderCount, 2, "a header view for each file in view")
        let editor = try XCTUnwrap(view.editors.first)
        XCTAssertEqual(editor.buffer.text.substring(editor.buffer.text.range(ofLine: 4)), "-let b = 2".dropFirst().description, "the lines are the code, without +/−")
        XCTAssertEqual(editor.gutter.label?(4), "    2      ", "old and new numbers: a removed line has only an old one")
        XCTAssertEqual(editor.gutter.label?(5), "          2", "an added line only a new one")
        XCTAssertNil(editor.gutter.label?(0), "nothing beside a header")
        XCTAssertNotNil(editor.lineBackground?(4), "a removed line is tinted")
        XCTAssertNil(editor.lineBackground?(3), "context isn't")
        let spoken = editor.textView.accessibilityValue() as? String ?? ""
        XCTAssertTrue(spoken.contains("removed, let b = 2"), spoken)
        XCTAssertTrue(spoken.contains("added, let b = 3"), spoken)
        XCTAssertTrue(spoken.contains("file, Sources/a.swift"), spoken)
    }

    func testFoldingAFileRemovesItsLines() {
        view.diffLayout = .unified
        view.render(diffText: diff)
        settle()
        let rows = view.rowCount
        view.toggleFoldForTesting(0)
        settle()
        XCTAssertEqual(view.rowCount, rows - 6, "the hunk, its four lines and the gap after them go; the header stays")
        view.toggleFoldForTesting(0)
        settle()
        XCTAssertEqual(view.rowCount, rows)
    }

    func testSplitColumnsLineUp() throws {
        view.diffLayout = .sideBySide
        view.render(diffText: diff)
        settle()
        XCTAssertEqual(view.editors.count, 2)
        let (left, right) = (view.editors[0], view.editors[1])
        XCTAssertEqual(left.buffer.text.lineCount, right.buffer.text.lineCount, "row for row")
        // The change is one row: old text left, new right.
        XCTAssertEqual(left.buffer.text.substring(left.buffer.text.range(ofLine: 4)), "let b = 2")
        XCTAssertEqual(right.buffer.text.substring(right.buffer.text.range(ofLine: 4)), "let b = 3")
        left.scrollY = 20
        settle()
        XCTAssertEqual(right.scrollY, left.scrollY, "they scroll together")
    }

    func testEmptyAndLoading() {
        view.renderLoading()
        XCTAssertEqual(view.rowCount, 0)
        view.render(diffText: "")
        XCTAssertEqual(view.rowCount, 0)
    }

    /// `SIDE_DIFF_SNAPSHOT=<png>` and `SIDE_REVIEW_DIFF=<diff>`: a picture, for looking at.
    func testSnapshot() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["SIDE_DIFF_SNAPSHOT"] else { throw XCTSkip("snapshot not asked for") }
        window.setFrame(NSRect(x: 80, y: 80, width: 1200, height: 800), display: true)
        window.makeKeyAndOrderFront(nil)
        view.diffLayout = env["SIDE_DIFF_SPLIT"] == "1" ? .sideBySide : .unified
        view.render(diffText: try env["SIDE_REVIEW_DIFF"].map { try String(contentsOfFile: $0, encoding: .utf8) } ?? diff)
        settle(1.5)
        try "\(window.windowNumber)".write(toFile: path + ".window", atomically: true, encoding: .utf8)
        settle(6)
    }
}
