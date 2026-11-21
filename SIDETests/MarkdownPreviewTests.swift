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

    /// 2026-10-29, the owner: the preview showed no pictures. A local one (relative to the file)
    /// shows, fitted to the column; a remote one waits for a click; a missing one says so.
    func testPicturesShowAndRemoteOnesWaitForAClick() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("img"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let wide = NSImage(size: NSSize(width: 4000, height: 1000), flipped: false) { rect in NSColor.red.setFill(); rect.fill(); return true }
        let png = NSBitmapImageRep(data: wide.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        try png.write(to: folder.appendingPathComponent("img/wide.png"))
        let style = MarkdownPreview.Style(bodySize: 16, textColor: .labelColor, dark: false)
        let out = MarkdownPreview.render("![A chart](img/wide.png)\n\n![Logo](https://example.com/logo.png)\n\n![Gone](nope.png)\n", style: style, folder: folder)
        var attachment: NSTextAttachment?
        out.enumerateAttribute(.attachment, in: NSRange(location: 0, length: out.length)) { value, _, _ in attachment = attachment ?? value as? NSTextAttachment }
        let picture = try XCTUnwrap(attachment, "the local picture is drawn")
        XCTAssertEqual(picture.bounds.width, style.columnWidth, "no wider than the column")
        XCTAssertEqual(picture.bounds.height, (style.columnWidth / 4).rounded())
        XCTAssertTrue(out.string.contains("Logo \u{00B7} Load from example.com"), out.string)
        let linkAt = (out.string as NSString).range(of: "Load from").location
        XCTAssertEqual((out.attribute(.link, at: linkAt, effectiveRange: nil) as? URL)?.scheme, MarkdownPreview.loadImageScheme)
        XCTAssertTrue(out.string.contains("Gone (not found)"))
    }

    /// 2026-11-06, the owner: pictures still didn't show. READMEs draw theirs with `<img>` in raw
    /// HTML and badges as `[![alt](picture)](link)`, which the parser handed over as tags and as
    /// bare words; and a picture's paragraph kept text's pinned line height, cut down to a line.
    func testReadmePicturesInHTMLAndBadgesAtTheirOwnHeight() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let logo = NSImage(size: NSSize(width: 200, height: 100), flipped: false) { rect in NSColor.blue.setFill(); rect.fill(); return true }
        try NSBitmapImageRep(data: logo.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("logo.png"))
        let style = MarkdownPreview.Style(bodySize: 16, textColor: .labelColor, dark: false)
        let markdown = "<p align=\"center\">\n  <img src=\"logo.png\" width=\"100\" alt=\"Logo\">\n</p>\n\n<h1 align=\"center\">Side</h1>\n\n"
            + "[![Build](https://example.com/b.svg)](https://example.com/ci) and ![Again](logo.png)\n\n```\n[![Kept](x.png)](y)\n```\n"
        let out = MarkdownPreview.render(markdown, style: style, folder: folder)
        var pictures: [(NSTextAttachment, Int)] = []
        out.enumerateAttribute(.attachment, in: NSRange(location: 0, length: out.length)) { value, range, _ in
            if let attachment = value as? NSTextAttachment { pictures.append((attachment, range.location)) }
        }
        XCTAssertEqual(pictures.count, 2, "the <img> and the Markdown picture: \(out.string)")
        let (html, at) = try XCTUnwrap(pictures.first)
        XCTAssertEqual(html.bounds.size, NSSize(width: 100, height: 50), "at the width it asks for")
        let paragraph = try XCTUnwrap(out.attribute(.paragraphStyle, at: at, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(paragraph.alignment, .center)
        XCTAssertEqual(paragraph.maximumLineHeight, 0, "its line as tall as it is")
        XCTAssertTrue(out.string.contains("Side"), "a block's words stay, its tags go: \(out.string)")
        let titleFont = out.attribute(.font, at: (out.string as NSString).range(of: "Side").location, effectiveRange: nil) as? NSFont
        XCTAssertEqual(titleFont?.pointSize, style.heading(1).pointSize, "an <h1> is a heading")
        XCTAssertFalse(out.string.contains("<"), out.string.debugDescription)
        XCTAssertTrue(out.string.contains("Build \u{00B7} Load from example.com"), "the badge waits for a click: \(out.string)")
        XCTAssertTrue(out.string.contains("[![Kept](x.png)](y)"), "code is left alone")

        // Laid out, the picture's line is as tall as the picture.
        let storage = NSTextStorage(attributedString: out)
        let layout = MarkdownPreviewLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: style.columnWidth, height: .greatestFiniteMagnitude))
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        let line = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: at), effectiveRange: nil)
        XCTAssertGreaterThanOrEqual(line.height, 50, "not cut down to a line of text")
    }

    func testBadgesBecomeLinkedImageTags() {
        let converted = MarkdownPreview.linkedImagesAsHTML("See [![CI](https://x.io/b.svg)](https://x.io/ci) now")
        XCTAssertEqual(converted, "See <img src=\"https://x.io/b.svg\" alt=\"CI\" data-side-link=\"https://x.io/ci\"> now")
        XCTAssertEqual(MarkdownPreview.htmlPictures(in: converted), [.init(source: "https://x.io/b.svg", alt: "CI", width: nil, link: "https://x.io/ci")])
    }

    func testOrderedAndNestedLists() {
        let text = render("1. first\n2. second\n   - inner\n").string
        XCTAssertTrue(text.contains("1.\tfirst"), text)
        XCTAssertTrue(text.contains("2.\tsecond"), text)
        XCTAssertTrue(text.contains("◦\tinner"), "a nested list gets its own bullet: \(text)")
    }

    /// Lays `markdown` out in a preview column `width` wide: each cell's text and its frame.
    private func layOut(_ markdown: String, width: CGFloat) -> (text: NSAttributedString, frame: (String) -> NSRect) {
        let out = render(markdown)
        let storage = NSTextStorage(attributedString: out)
        let layout = MarkdownPreviewLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        return (out, { word in
            // The layout manager holds its storage weakly: the closure keeps it.
            _ = storage
            let range = (out.string as NSString).range(of: word)
            return layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
        })
    }

    func testTablesLineUp() {
        let (text, frame) = layOut("| A | B |\n|---|---|\n| one | two |\n", width: 720)
        XCTAssertTrue(text.string.contains("A\nB\none\ntwo"), text.string)
        XCTAssertEqual(frame("B").minX, frame("two").minX, accuracy: 0.5, "a column starts in one place")
        XCTAssertLessThan(frame("B").minX, 200, "a short table keeps to its cells, not the column's width")
    }

    /// 2026-10-31, the owner: a long cell ran out of its column. It wraps inside it now.
    func testALongCellWrapsInsideItsColumn() {
        let long = "Opening " + Array(repeating: "words that go on", count: 20).joined(separator: " ") + " closing"
        let (text, frame) = layOut("| Name | Notes | End |\n|---|---|---|\n| one | \(long) | last |\n", width: 600)
        let first = frame("Opening"), lastLine = frame("closing")
        XCTAssertGreaterThan(lastLine.minY - first.minY, 60, "the cell wraps onto several lines: \(text.string)")
        XCTAssertLessThanOrEqual(frame("last").maxX, 600.5, "the table fits the column")
        XCTAssertGreaterThan(frame("last").minX, first.minX + 200, "the next column starts after the wrapped one")
        XCTAssertEqual(frame("Notes").minX, first.minX, accuracy: 0.5)
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

    /// Font variations (Settings › Appearance › Fonts › Weight): a variable font's weight axis,
    /// or a family's faces; none for a family with only a regular and a bold; a new family
    /// starts at its own regular again.
    func testACodeFontsWeight() throws {
        defer { for role in DS.Text.Fonts.Role.allCases { DS.Text.Fonts.setFamily(nil, for: role) } }
        let wght = NSNumber(value: 0x7767_6874)
        func weight(_ font: NSFont) -> Double? { (CTFontCopyVariation(font as CTFont) as? [NSNumber: NSNumber])?[wght]?.doubleValue }

        // The default editor font, SF Mono, is variable.
        guard case .axis(let range)? = DS.Text.Fonts.weights(.editor) else { return XCTFail("SF Mono's weight axis") }
        XCTAssertTrue(range.contains(450))
        DS.Text.Fonts.setWeight(.axis(450), for: .editor)
        XCTAssertEqual(weight(DS.Text.editor()), 450)
        XCTAssertEqual(DS.Text.Fonts.currentWeight(.editor), .axis(450))
        XCTAssertTrue(DS.Text.editor().isFixedPitch)
        XCTAssertNotEqual(weight(DS.Text.editor(.bold)), 450, "bold isn't the chosen weight")
        XCTAssertNil(weight(DS.Text.Fonts.font(.reading, size: 16)).map { $0 == 450 ? $0 : nil } ?? nil, "reading isn't a code font")

        // Menlo: Regular and Bold only, so no choice; a family change drops the old weight.
        DS.Text.Fonts.setFamily("Menlo", for: .editor)
        XCTAssertNil(DS.Text.Fonts.weights(.editor))
        XCTAssertNil(DS.Text.Fonts.weight(.editor))
        XCTAssertEqual(DS.Text.editor().fontName, "Menlo-Regular")

        // A face of another family never applies.
        DS.Text.Fonts.setWeight(.face("Menlo-Bold"), for: .terminal)
        DS.Text.Fonts.setFamily("Menlo", for: .terminal)
        DS.Text.Fonts.setWeight(.face("Menlo-Bold"), for: .terminal)
        XCTAssertEqual(DS.Text.Fonts.font(.terminal, size: 12).fontName, "Menlo-Bold", "a face of the family applies")
        DS.Text.Fonts.setWeight(.face("Courier-Bold"), for: .terminal)
        XCTAssertEqual(DS.Text.Fonts.font(.terminal, size: 12).fontName, "Menlo-Regular", "one of another family doesn't")
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
