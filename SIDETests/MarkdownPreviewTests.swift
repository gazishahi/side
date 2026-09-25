import AlloySyntax
import XCTest
@testable import Side

/// The Markdown preview (`MarkdownPreview`): structure comes out right, and (opt-in) a picture of it.
@MainActor
final class MarkdownPreviewTests: XCTestCase {
    private func render(_ markdown: String) -> NSAttributedString {
        MarkdownPreview.render(markdown, style: .init(bodySize: 16, textColor: .labelColor, dark: false))
    }

    func testBlocksAndInlines() {
        let out = render("# Title\n\nSome **bold** and `code`.\n\n- one\n- two\n\n```swift\nlet a = 1\n```\n\n> quoted\n\n---\n")
        let text = out.string
        XCTAssertTrue(text.hasPrefix("Title\nSome bold and code.\n"), text)
        XCTAssertTrue(text.contains("•\tone\n•\ttwo"), "bullets hang on a tab stop")
        XCTAssertTrue(text.contains("let a = 1"))
        let codeAt = (text as NSString).range(of: "let a = 1").location
        XCTAssertNotNil(out.attribute(MarkdownPreview.codeBlockKey, at: codeAt, effectiveRange: nil), "a code card")
        let inlineAt = (text as NSString).range(of: "code.").location
        XCTAssertNotNil(out.attribute(MarkdownPreview.inlineCodeKey, at: inlineAt, effectiveRange: nil), "an inline chip")
        let quoteAt = (text as NSString).range(of: "quoted").location
        XCTAssertNotNil(out.attribute(MarkdownPreview.quoteKey, at: quoteAt, effectiveRange: nil))
        XCTAssertEqual(out.attribute(MarkdownRenderer.anchorSlugKey, at: 0, effectiveRange: nil) as? String, "title")
        let bold = out.attribute(.font, at: (text as NSString).range(of: "bold").location, effectiveRange: nil) as? NSFont
        XCTAssertTrue(bold?.fontDescriptor.symbolicTraits.contains(.bold) ?? false)
    }

    func testOrderedAndNestedLists() {
        let text = render("1. first\n2. second\n   - inner\n").string
        XCTAssertTrue(text.contains("1.\tfirst"), text)
        XCTAssertTrue(text.contains("2.\tsecond"), text)
        XCTAssertTrue(text.contains("◦\tinner"), "a nested list gets its own bullet: \(text)")
    }

    func testTablesLineUp() {
        let text = render("| A | B |\n|---|---|\n| one | two |\n").string
        XCTAssertTrue(text.contains("A\tB\none\ttwo"), text)
    }

    func testAnchorLinksStayInTheDocument() {
        let out = render("See [setup](#set-up).\n\n## Set up\n")
        let at = (out.string as NSString).range(of: "setup").location
        XCTAssertEqual((out.attribute(.link, at: at, effectiveRange: nil) as? URL)?.scheme, MarkdownRenderer.anchorScheme)
    }

    func testFontChoicesApplyAndFallBack() {
        defer { for role in DS.Text.Fonts.Role.allCases { DS.Text.Fonts.setFamily(nil, for: role) } }
        XCTAssertEqual(DS.Text.Fonts.font(.reading, size: 16).fontName, DS.Text.Fonts.serif(16).fontName, "reading defaults to the serif")
        XCTAssertNotEqual(DS.Text.Fonts.serif(16).fontName, NSFont.systemFont(ofSize: 16).fontName)
        XCTAssertTrue(DS.Text.Fonts.font(.editor, size: 14).isFixedPitch)
        DS.Text.Fonts.setFamily("Menlo", for: .editor)
        XCTAssertEqual(DS.Text.Fonts.font(.editor, size: 14).familyName, "Menlo")
        XCTAssertEqual(DS.Text.editor().familyName, "Menlo", "the editor font follows")
        DS.Text.Fonts.setFamily("SF Pro", for: .reading)
        XCTAssertEqual(DS.Text.Fonts.font(.reading, size: 16).familyName, NSFont.systemFont(ofSize: 16).familyName)
        DS.Text.Fonts.setFamily("No Such Family", for: .reading)
        XCTAssertEqual(DS.Text.Fonts.font(.reading, size: 16).pointSize, 16, "an uninstalled family falls back")
        XCTAssertTrue(DS.Text.Fonts.monospacedFamilies().contains("Menlo"))
    }

    /// `SIDE_PREVIEW_SNAPSHOT=<dir>` writes light and dark pictures of `SIDE_PREVIEW_SAMPLE`.
    func testSnapshot() throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["SIDE_PREVIEW_SNAPSHOT"], let sample = env["SIDE_PREVIEW_SAMPLE"] else { throw XCTSkip("snapshot not asked for") }
        let markdown = try String(contentsOfFile: sample, encoding: .utf8)
        // As the preview does once they're built: code blocks colored.
        for ext in ["ts", "swift", "py"] { _ = SyntaxLanguage.forExtension(ext) }
        for dark in [false, true] {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            let view = MarkdownPreviewTextView.make()
            view.appearance = appearance
            view.drawsBackground = true
            view.backgroundColor = DS.Color.canvas
            let style = MarkdownPreview.Style(bodySize: 16, textColor: .labelColor, dark: dark)
            view.columnWidth = style.columnWidth
            view.frame = NSRect(x: 0, y: 0, width: 1200, height: 100)
            view.textStorage?.setAttributedString(MarkdownPreview.render(markdown, style: style))
            view.layoutManager?.ensureLayout(for: view.textContainer!)
            let used = view.layoutManager!.usedRect(for: view.textContainer!).height
            view.frame.size.height = min(used + view.textContainerInset.height * 2, 2400)
            let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            appearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: rep) }
            try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: dir).appendingPathComponent(dark ? "preview-dark.png" : "preview-light.png"))
        }
    }
}
