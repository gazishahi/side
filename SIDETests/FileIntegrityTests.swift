import XCTest
@testable import Side
@testable import Heron

/// Audit H7 (encoding-safe saves) and H8 (external changes reach the editor and the indexes).
final class FileIntegrityTests: XCTestCase {
    func testDecodeRefusesBinaryAndRecordsTheFilesShape() {
        let cp1252Cafe = Data([0x63, 0x61, 0x66, 0xE9])  // "café" in Windows-1252
        let cases: [(name: String, bytes: Data, text: String?, format: TextFileCodec.Format?)] = [
            ("NUL byte", Data([0x41, 0x00, 0x42]), nil, nil),
            ("dense control bytes", Data([0x01, 0x02, 0x03, 0x04, 0x41]), nil, nil),
            ("UTF-16 without a BOM", "hi".data(using: .utf16LittleEndian)!, nil, nil),
            ("plain UTF-8", Data("a\nb".utf8), "a\nb", .utf8),
            ("UTF-8 with BOM", Data([0xEF, 0xBB, 0xBF]) + Data("x".utf8), "x", .init(encoding: .utf8, byteOrderMark: true, lineEnding: .lf)),
            ("Windows-1252", cp1252Cafe, "café", .init(encoding: .windowsCP1252, byteOrderMark: false, lineEnding: .lf)),
            ("CRLF is normalised in the buffer", Data("a\r\nb\r\nc".utf8), "a\nb\nc", .init(encoding: .utf8, byteOrderMark: false, lineEnding: .crlf)),
            ("UTF-16 LE with BOM", Data([0xFF, 0xFE]) + "hi".data(using: .utf16LittleEndian)!, "hi", .init(encoding: .utf16LittleEndian, byteOrderMark: true, lineEnding: .lf)),
        ]
        for c in cases {
            let decoded = TextFileCodec.decode(c.bytes)
            XCTAssertEqual(decoded?.text, c.text, c.name)
            XCTAssertEqual(decoded?.format, c.format, c.name)
        }
    }

    func testSavingWritesBackTheSameBytesForEverythingTheUserDidNotTouch() throws {
        // A CP1252 file with CRLF endings: edit line 1, and line 2's bytes — including the
        // non-ASCII one — must be identical, with CRLF preserved on the new line too.
        let line2 = Data([0x63, 0x61, 0x66, 0xE9])
        let original = Data("first\r\n".utf8) + line2
        let decoded = try XCTUnwrap(TextFileCodec.decode(original))
        let edited = decoded.text.replacingOccurrences(of: "first", with: "FIRST\nsecond")
        let saved = try XCTUnwrap(TextFileCodec.encode(edited, as: decoded.format))
        XCTAssertEqual(saved, Data("FIRST\r\nsecond\r\n".utf8) + line2)
        // A character the encoding can't hold is refused, never transcoded.
        XCTAssertNil(TextFileCodec.encode("→", as: decoded.format))
        // BOMs come back.
        let bom = TextFileCodec.Format(encoding: .utf8, byteOrderMark: true, lineEnding: .lf)
        XCTAssertEqual(TextFileCodec.encode("x", as: bom), Data([0xEF, 0xBB, 0xBF, 0x78]))
        // Writing through the URL helper picks the file's own format up from disk.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("codec-\(UUID().uuidString).txt")
        try original.write(to: url)
        try TextFileCodec.write("new\ncafé", to: url)
        XCTAssertEqual(try Data(contentsOf: url), Data("new\r\n".utf8) + line2)
    }

    @MainActor
    func testAWatchedRootReportsChangesAndMakesTheMentionIndexStale() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "a".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let index = ProjectFileIndex()
        let indexed = expectation(description: "indexed")
        index.refresh(root: root) { indexed.fulfill() }
        wait(for: [indexed], timeout: 5)
        XCTAssertEqual(index.relativePaths, ["a.txt"])

        let changed = expectation(description: "watcher fired")
        changed.assertForOverFulfill = false
        var seen: [URL] = []
        // Setup writes may still be in flight when the stream starts, so wait for b.txt itself.
        let watcher = ProjectWatcher(root: root, latency: 0.1) { urls in
            seen += urls
            if urls.contains(where: { $0.lastPathComponent == "b.txt" }) { changed.fulfill() }
        }
        // Give the stream a beat to start, then write.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        try "b".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        wait(for: [changed], timeout: 10)
        XCTAssertTrue(seen.contains { $0.lastPathComponent == "b.txt" }, "\(seen)")
        _ = watcher

        // Same root, no stale mark: refresh is a no-op (the original early-return).
        let unchanged = expectation(description: "no-op refresh")
        index.refresh(root: root) { unchanged.fulfill() }
        wait(for: [unchanged], timeout: 5)
        XCTAssertEqual(index.relativePaths, ["a.txt"])
        // Marked stale: the new file appears.
        index.markStale()
        let rescanned = expectation(description: "rescanned")
        index.refresh(root: root) { rescanned.fulfill() }
        wait(for: [rescanned], timeout: 5)
        XCTAssertEqual(Set(index.relativePaths), ["a.txt", "b.txt"])
    }
}

/// 2026-09-30 audit, H14: unsaved buffers are kept outside the project while unsaved, so a
/// crash doesn't lose them, and are offered back when the project next opens.
@MainActor
final class BufferRecoveryTests: XCTestCase {
    func testAnUnsavedBufferSurvivesAndIsGoneOnceClosed() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("side-recovery-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: MakeWorkspaceViewController.recoveryDirectory(for: folder))
        }
        let file = folder.appendingPathComponent("notes.txt")
        try "on disk\n".write(to: file, atomically: true, encoding: .utf8)
        let make = MakeWorkspaceViewController()
        make.loadViewIfNeeded()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = container
        for child in [make.view, make.topRowContent!] { container.addSubview(child) }
        make.view.frame = container.bounds
        defer { window.contentView = nil; window.close() }
        make.loadProject(at: folder)
        var opened = false
        make.openForTesting(file) { opened = true }
        let deadline = Date().addingTimeInterval(10)
        while !opened, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }

        make.editActiveTabForTesting("on disk\nand typed, never saved\n")
        make.syncRecovery()
        MakeWorkspaceViewController.flushRecoveryForTesting()
        let copies = MakeWorkspaceViewController.recoverableCopies(for: folder)
        XCTAssertEqual(copies.map(\.text), ["on disk\nand typed, never saved\n"])
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "on disk\n", "the file is untouched")

        // As after a relaunch: the tab gone, the copy restored, unsaved.
        make.closeAllTabsForTesting()
        make.restoreRecoveredForTesting()
        let reopened = Date().addingTimeInterval(10)
        while make.activeTabForTesting?.dirty != true, Date() < reopened { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertEqual(make.activeTabForTesting?.text, "on disk\nand typed, never saved\n")
        XCTAssertEqual(make.activeTabForTesting?.dirty, true)

        // A copy that matches the file on disk isn't offered.
        try "on disk\nand typed, never saved\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(MakeWorkspaceViewController.recoverableCopies(for: folder).isEmpty)

        // Closed: no copy left.
        make.closeAllTabsForTesting()
        make.syncRecovery()
        MakeWorkspaceViewController.flushRecoveryForTesting()
        let left = (try? FileManager.default.contentsOfDirectory(atPath: MakeWorkspaceViewController.recoveryDirectory(for: folder).path)) ?? []
        XCTAssertTrue(left.isEmpty, "\(left)")
    }
}

/// 2026-09-30 audit, EDT-8: a file replaced by one with an older modification date (`mv`,
/// `cp -p`, `rsync -a`, `unzip`) read as unchanged, and the next save overwrote it.
@MainActor
final class ExternalReplacementTests: XCTestCase {
    func testAReplacementWithAnOlderDateIsAChange() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("side-replace-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: MakeWorkspaceViewController.recoveryDirectory(for: folder))
        }
        let file = folder.appendingPathComponent("notes.txt")
        try "mine\n".write(to: file, atomically: true, encoding: .utf8)
        // Moved into place, as `mv` or an unzip does, keeping a date from two days ago.
        func replace(with text: String) throws {
            let incoming = folder.appendingPathComponent("incoming-\(UUID().uuidString)")
            try text.write(to: incoming, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 86_400)], ofItemAtPath: incoming.path)
            XCTAssertEqual(rename(incoming.path, file.path), 0)
        }
        let make = MakeWorkspaceViewController()
        make.loadViewIfNeeded()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = container
        for child in [make.view, make.topRowContent!] { container.addSubview(child) }
        make.view.frame = container.bounds
        defer { window.contentView = nil; window.close() }
        make.loadProject(at: folder)
        var opened = false
        make.openForTesting(file) { opened = true }
        let deadline = Date().addingTimeInterval(10)
        while !opened, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }

        // A clean tab takes the replacement.
        try replace(with: "from the archive\n")
        make.reconcileWithDiskForTesting()
        XCTAssertEqual(make.activeTabForTesting?.text, "from the archive\n")

        // A tab with unsaved edits is told, not overwritten, and its save will ask.
        make.editActiveTabForTesting("typed\n")
        try replace(with: "replaced again\n")
        make.reconcileWithDiskForTesting()
        XCTAssertTrue(make.activeTabHasExternalChangeForTesting)
        XCTAssertEqual(make.activeTabForTesting?.text, "typed\n")
        make.closeAllTabsForTesting()
    }
}

/// 2026-09-30 audit, H14: Save As kept the old encoding, so a Windows-1252 file holding a
/// character it can't represent was refused again, though the refusal says to Save As as UTF-8.
@MainActor
final class SaveAsTests: XCTestCase {
    func testSaveAsKeepsWhatTheOldEncodingCantAsUTF8() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("side-saveas-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: MakeWorkspaceViewController.recoveryDirectory(for: folder))
        }
        let original = folder.appendingPathComponent("legacy.txt")
        let legacyBytes = Data([0x63, 0x61, 0x66, 0xE9, 0x0D, 0x0A])  // "café\r\n" in Windows-1252
        try legacyBytes.write(to: original)
        let make = MakeWorkspaceViewController()
        make.loadViewIfNeeded()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = container
        for child in [make.view, make.topRowContent!] { container.addSubview(child) }
        make.view.frame = container.bounds
        defer { window.contentView = nil; window.close() }
        make.loadProject(at: folder)
        var opened = false
        make.openForTesting(original) { opened = true }
        let deadline = Date().addingTimeInterval(10)
        while !opened, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertEqual(make.activeTabForTesting?.text, "café\n")

        make.editActiveTabForTesting("café ✓\n")  // ✓ isn't in Windows-1252
        // Checked first: a refused write puts up a sheet that holds a test host, not fails it.
        let legacy = TextFileCodec.Format(encoding: .windowsCP1252, byteOrderMark: false, lineEnding: .crlf)
        guard TextFileCodec.encode("café ✓\n", as: MakeWorkspaceViewController.saveAsFormat(for: "café ✓\n", current: legacy)) != nil else {
            return XCTFail("Save As would refuse text Windows-1252 can't hold")
        }
        let copy = folder.appendingPathComponent("legacy-utf8.txt")
        var saved: Bool?
        make.saveActiveTabAsForTesting(copy) { saved = $0 }
        let wrote = Date().addingTimeInterval(10)
        while saved == nil, Date() < wrote { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertEqual(saved, true)
        XCTAssertEqual(try Data(contentsOf: copy), Data("café ✓\r\n".utf8), "UTF-8, the file's own line ending kept")
        XCTAssertEqual(try Data(contentsOf: original), legacyBytes, "the original is untouched")
        XCTAssertEqual(make.activeTabURLForTesting, copy)
        XCTAssertEqual(make.activeTabForTesting?.dirty, false)
        make.closeAllTabsForTesting()
    }
}

/// EDT-7 (2026-09-30 audit): a file saved under a new name, or an untitled one saved, is the
/// language server's under that name, and its edits reach it.
@MainActor
final class SaveAsLanguageServerTests: XCTestCase {
    func testASavedUntitledFileIsOpenOnItsServerAndFollowsEdits() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("side-saveas-lsp-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: MakeWorkspaceViewController.recoveryDirectory(for: folder))
        }
        let make = MakeWorkspaceViewController()
        make.loadViewIfNeeded()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = container
        for child in [make.view, make.topRowContent!] { container.addSubview(child) }
        make.view.frame = container.bounds
        defer { make.closeAllTabsForTesting(); window.contentView = nil; window.close() }
        make.loadProject(at: folder)

        make.newUntitledForTesting()
        make.editActiveTabForTesting("let a = 1\n")
        let first = folder.appendingPathComponent("a.ts")
        var saved: Bool?
        make.saveActiveTabAsForTesting(first) { saved = $0 }
        var deadline = Date().addingTimeInterval(10)
        while saved == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertEqual(saved, true)
        XCTAssertEqual(make.languageServerVersionForTesting(first), 1, "open under its new name")

        make.editActiveTabForTesting("let a = 2\n")
        XCTAssertEqual(make.languageServerVersionForTesting(first), 2, "and its edits reach the server")

        let second = folder.appendingPathComponent("b.ts")
        saved = nil
        make.saveActiveTabAsForTesting(second) { saved = $0 }
        deadline = Date().addingTimeInterval(10)
        while saved == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertNil(make.languageServerVersionForTesting(first), "the old name closed")
        XCTAssertEqual(make.languageServerVersionForTesting(second), 1)
    }
}

/// 2026-10-23, the owner: two tabs with the same file name looked the same. Each gets the
/// shortest folder suffix that tells it apart.
final class TabNameTests: XCTestCase {
    func testSameNamedTabsAreToldApartByTheirFolders() {
        let urls = ["/p/api/index.ts", "/p/web/index.ts", "/p/README.md", "/p/src/api/util.ts", "/p/lib/api/util.ts", "/p/main.swift"]
            .map(URL.init(fileURLWithPath:))
        XCTAssertEqual(MakeWorkspaceViewController.disambiguatingFolders(for: urls), ["api", "web", "", "src/api", "lib/api", ""])
        XCTAssertEqual(MakeWorkspaceViewController.disambiguatingFolders(for: [URL(fileURLWithPath: "/p/a.txt")]), [""], "a name that's alone has none")
    }
}

/// 2026-10-23, the owner: a blog post's front matter rendered as a rule and run-on text. It's
/// read as properties and shown as a card, with list values (tags) as chips.
@MainActor
final class FrontMatterTests: XCTestCase {
    static let post = """
    ---
    title: The Case for Bottom Navigation Bars
    description: "Utilizing familiar design patterns for agentic interfaces"
    date: 2026-09-27
    published: true
    tags: [design, ux, ui, navigation, agentic, artificial intelligence]
    authors:
      - Gazi
      - Claude
    ---

    # Hello

    Body text.
    """

    func testFrontMatterIsReadAsProperties() throws {
        let front = try XCTUnwrap(MarkdownPreview.frontMatter(Self.post))
        XCTAssertEqual(front.properties.map(\.key), ["title", "description", "date", "published", "tags", "authors"])
        XCTAssertEqual(front.properties[1].values, ["Utilizing familiar design patterns for agentic interfaces"], "quotes come off")
        XCTAssertEqual(front.properties[4].values, ["design", "ux", "ui", "navigation", "agentic", "artificial intelligence"])
        XCTAssertEqual(front.properties[5].values, ["Gazi", "Claude"], "a block list")
        XCTAssertTrue(front.body.hasPrefix("\n# Hello"))
        XCTAssertNil(MarkdownPreview.frontMatter("# No front matter\n\n---\n"), "a rule later on isn't front matter")
    }

    func testThePreviewShowsACardNotARule() {
        let rendered = MarkdownPreview.render(Self.post, style: .current(dark: false))
        let text = rendered.string
        XCTAssertTrue(text.hasPrefix("\ntitle\tThe Case for Bottom Navigation Bars"), String(text.prefix(80)))
        XCTAssertNil(rendered.attribute(MarkdownPreview.codeBlockKey, at: 0, effectiveRange: nil), "room above the card, outside it, so its top corners show")
        XCTAssertFalse(text.contains("title: The Case"), "not the raw YAML")
        XCTAssertTrue(text.contains("Hello"))
        let tags = (text as NSString).range(of: "artificial\u{00A0}intelligence")  // the tag, kept on one line
        XCTAssertNotEqual(tags.location, NSNotFound)
        XCTAssertNotNil(rendered.attribute(MarkdownPreview.inlineCodeKey, at: tags.location, effectiveRange: nil), "tags are chips")
        if let directory = ProcessInfo.processInfo.environment["SIDE_PREVIEW_SNAPSHOT"] {
            for dark in [false, true] {
                let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
                let view = MarkdownPreviewTextView.make()
                view.appearance = appearance
                view.drawsBackground = true
                view.backgroundColor = DS.Color.canvas
                let style = MarkdownPreview.Style(bodySize: 16, textColor: .labelColor, dark: dark)
                view.columnWidth = style.columnWidth
                view.frame = NSRect(x: 0, y: 0, width: 900, height: 360)
                view.textStorage?.setAttributedString(MarkdownPreview.render(Self.post, style: style))
                view.layoutManager?.ensureLayout(for: view.textContainer!)
                let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                appearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: rep) }
                try? rep.representation(using: NSBitmapImageRep.FileType.png, properties: [:])?
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent(dark ? "front-matter-dark.png" : "front-matter-light.png"))
            }
        }
    }
}

/// 2026-10-23, the owner: "get specific icons based on file type." Side's own set, by whole
/// name first and then extension.
@MainActor
final class FileIconTests: XCTestCase {
    func testFilesGetTheirLanguagesIcon() {
        XCTAssertEqual(FileIcon.style(forName: "App.tsx", isDirectory: false).glyph, .letters("TSX"))
        XCTAssertEqual(FileIcon.style(forName: "main.PY", isDirectory: false).glyph, .letters("PY"), "case doesn't matter")
        XCTAssertEqual(FileIcon.style(forName: "+page.svelte", isDirectory: false).glyph, .letters("S"))
        XCTAssertEqual(FileIcon.style(forName: "package.json", isDirectory: false).glyph, .symbol("shippingbox"), "the name wins over .json")
        XCTAssertEqual(FileIcon.style(forName: ".env.local", isDirectory: false).glyph, .symbol("key"))
        XCTAssertEqual(FileIcon.style(forName: "yarn.lock", isDirectory: false).glyph, .symbol("lock"))
        XCTAssertEqual(FileIcon.style(forName: "README.md", isDirectory: false).glyph, .symbol("book"))
        XCTAssertEqual(FileIcon.style(forName: "src", isDirectory: true).glyph, .symbol("folder.fill"))
        XCTAssertFalse(FileIcon.style(forName: "notes", isDirectory: false).tiled, "an unknown file is a quiet page")
        XCTAssertFalse(FileIcon.style(forName: ".bashrc", isDirectory: false).tiled, "a dotfile isn't read as an extension")
        let image = FileIcon.image(for: URL(fileURLWithPath: "/x/a.ts"), isDirectory: false)
        XCTAssertTrue(image === FileIcon.image(for: URL(fileURLWithPath: "/y/b.ts"), isDirectory: false), "one image per style")
        XCTAssertEqual(image.size, NSSize(width: 16, height: 16))
    }

    func testSnapshot() throws {
        guard let directory = ProcessInfo.processInfo.environment["SIDE_PREVIEW_SNAPSHOT"] else { return }
        let names = ["src", "App.swift", "index.ts", "App.tsx", "main.js", "app.py", "lib.rs", "main.go", "page.svelte", "App.vue",
                     "index.html", "styles.css", "theme.scss", "data.json", "config.yaml", "Cargo.toml", "README.md", "notes.md",
                     "paper.tex", "build.sh", "sales.csv", "logo.png", "spec.pdf", "package.json", "Dockerfile", ".gitignore",
                     ".env", "yarn.lock", "main.c", "engine.cpp", "Main.kt", "Program.cs", "schema.sql", "notes.txt", "LICENSE", "Makefile"]
        let columns = 3, rowHeight: CGFloat = 26, width: CGFloat = 180
        let rows = (names.count + columns - 1) / columns
        for dark in [false, true] {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            let canvas = NSView(frame: NSRect(x: 0, y: 0, width: width * CGFloat(columns), height: rowHeight * CGFloat(rows) + 16))
            canvas.appearance = appearance
            canvas.wantsLayer = true
            for (index, name) in names.enumerated() {
                let x = CGFloat(index % columns) * width + 12, y = canvas.bounds.height - 8 - rowHeight * CGFloat(index / columns + 1)
                let icon = NSImageView(frame: NSRect(x: x, y: y + 5, width: 16, height: 16))
                icon.image = FileIcon.image(for: URL(fileURLWithPath: "/p/" + name), isDirectory: name == "src")
                let label = NSTextField(labelWithString: name)
                label.font = DS.Text.body()
                label.frame = NSRect(x: x + 22, y: y + 3, width: width - 40, height: 18)
                canvas.addSubview(icon); canvas.addSubview(label)
            }
            let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds)!
            appearance.performAsCurrentDrawingAppearance {
                canvas.layer?.backgroundColor = DS.Color.canvas.cgColor
                canvas.cacheDisplay(in: canvas.bounds, to: rep)
            }
            try rep.representation(using: NSBitmapImageRep.FileType.png, properties: [:])?
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent(dark ? "icons-dark.png" : "icons-light.png"))
        }
    }
}

/// 2026-10-23, the owner: spreadsheets shown as a spreadsheet: CSV, TSV and Excel workbooks.
@MainActor
final class SheetTests: XCTestCase {
    func testDelimitersAreFoundAndQuotedFieldsKept() {
        XCTAssertEqual(CSVParser.delimiter(forExtension: "tsv", text: "a,b"), "\t")
        XCTAssertEqual(CSVParser.delimiter(forExtension: "csv", text: "a\tb\n1\t2"), "\t", "a tab file named .csv")
        XCTAssertEqual(CSVParser.delimiter(forExtension: "csv", text: "a;b\n1;2"), ";")
        XCTAssertEqual(CSVParser.delimiter(forExtension: "csv", text: "a,b"), ",")
        XCTAssertEqual(CSVParser.parse("name\tnote\nAda\t\"says \"\"hi\"\"\"", delimiter: "\t"), [["name", "note"], ["Ada", "says \"hi\""]])
    }

    /// A workbook built here the way Excel writes one: two sheets, shared strings, an inline
    /// string, a boolean, and a date-formatted number.
    func testAWorkbooksSheetsAreRead() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("xlsx-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let files: [String: String] = [
            "[Content_Types].xml": "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"/>",
            "xl/workbook.xml": #"<workbook xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Orders" sheetId="1" r:id="rId1"/><sheet name="Notes" sheetId="2" r:id="rId2"/><sheet name="Report" sheetId="3" r:id="rId3"/></sheets></workbook>"#,
            "xl/_rels/workbook.xml.rels": #"<Relationships><Relationship Id="rId1" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Target="worksheets/sheet2.xml"/><Relationship Id="rId3" Target="worksheets/sheet3.xml"/></Relationships>"#,
            "xl/sharedStrings.xml": #"<sst><si><t>Item</t></si><si><t>Qty</t></si><si><t>Shipped</t></si><si><r><t>Wid</t></r><r><t>get</t></r></si></sst>"#,
            "xl/theme/theme1.xml": #"<a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><a:themeElements><a:clrScheme name="Office"><a:dk1><a:sysClr val="windowText" lastClr="000000"/></a:dk1><a:lt1><a:sysClr val="window" lastClr="FFFFFF"/></a:lt1><a:dk2><a:srgbClr val="44546A"/></a:dk2><a:lt2><a:srgbClr val="E7E6E6"/></a:lt2><a:accent1><a:srgbClr val="4472C4"/></a:accent1></a:clrScheme></a:themeElements></a:theme>"#,
            "xl/styles.xml": #"<styleSheet><numFmts count="1"><numFmt numFmtId="164" formatCode="0.0%"/></numFmts><fonts count="2"><font><sz val="11"/></font><font><b/><color theme="4"/></font></fonts><fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor theme="4" tint="0.79998168889431442"/></patternFill></fill></fills><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0"/></cellStyleXfs><cellXfs count="5"><xf numFmtId="0"/><xf numFmtId="14"/><xf numFmtId="164"/><xf numFmtId="0" fontId="1" fillId="2"><alignment horizontal="center"/></xf><xf numFmtId="4"/></cellXfs><dxfs count="1"><dxf><font><i/></font></dxf></dxfs></styleSheet>"#,
            "xl/worksheets/sheet1.xml": #"<worksheet><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c><c r="C1" t="s"><v>2</v></c><c r="D1" t="inlineStr"><is><t>Paid</t></is></c></row><row r="2"><c r="A2" t="s"><v>3</v></c><c r="B2"><v>12</v></c><c r="C2" s="1"><v>45200</v></c><c r="D2" t="b"><v>1</v></c></row></sheetData></worksheet>"#,
            "xl/worksheets/sheet2.xml": #"<worksheet><sheetData><row r="1"><c r="B1" t="inlineStr"><is><t>later</t></is></c></row></sheetData></worksheet>"#,
            "xl/worksheets/sheet3.xml": #"<worksheet><cols><col min="1" max="2" width="20" customWidth="1"/></cols><sheetData><row r="1"><c r="A1" s="3" t="inlineStr"><is><t>Q3 Report</t></is></c></row><row r="3"><c r="A3" s="2"><v>0.153</v></c><c r="B3" s="4"><v>1234.5</v></c><c r="C3" s="3"/></row></sheetData></worksheet>"#,
        ]
        for (path, text) in files {
            let url = folder.appendingPathComponent("book/\(path)")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = folder.appendingPathComponent("book")
        zip.arguments = ["-q", "-r", "-X", folder.appendingPathComponent("orders.xlsx").path, "."]
        try zip.run(); zip.waitUntilExit()
        let sheets = try XLSXReader.read(folder.appendingPathComponent("orders.xlsx"))
        XCTAssertEqual(sheets.map(\.name), ["Orders", "Notes", "Report"])
        XCTAssertEqual(sheets[0].rows, [["Item", "Qty", "Shipped", "Paid"], ["Widget", "12", "2023-10-01", "TRUE"]], "rich text joined, the date as a date")
        XCTAssertEqual(sheets[1].rows, [["", "later"]], "an empty first column kept")
        XCTAssertTrue(sheets[0].headerRow, "a row of labels over data")
        XCTAssertNil(sheets[0].numbers[1][0])
        XCTAssertEqual(sheets[0].numbers[1][1], 12)

        let report = sheets[2]
        XCTAssertFalse(report.headerRow, "a title over a blank row isn't a header")
        XCTAssertEqual(report.rows, [["Q3 Report", "", ""], ["", "", ""], ["15.3%", "1,234.50", ""]], "number formats applied")
        XCTAssertEqual(report.numbers[2][0], 0.153, "the number behind 15.3%")
        XCTAssertEqual(report.columnWidths[0], 145)
        XCTAssertEqual(report.columnWidths[1], 145)
        let title = report.styles[report.styleIndex[0][0]]
        XCTAssertTrue(title.bold)
        XCTAssertEqual(title.color, 0x4472C4, "theme colour accent 1")
        XCTAssertEqual(title.fill, 0xDAE3F3, "tinted 80% lighter")
        XCTAssertEqual(title.alignment, .center)
        XCTAssertFalse(title.italic, "a conditional format's font isn't a cell's")
        XCTAssertEqual(report.styles[report.styleIndex[2][2]], title, "an empty styled cell keeps its fill")
    }

    /// 2026-10-23, the owner: the letters show without hovering; a cell highlights as a cell,
    /// and lights its row number and column letter.
    func testCellsSelectAndLightTheirRowAndColumn() throws {
        let view = SheetView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        view.show([Sheet(name: "s", rows: [["item", "qty", "price"], ["a", "2", "1.50"], ["b", "3", "2.25"], ["c", "x", "4"]])])
        let headers = view.table.tableColumns.dropFirst().compactMap { $0.headerCell as? SheetHeaderCell }
        XCTAssertEqual(headers.map(\.letter), ["A", "B", "C"], "every column carries its letter")
        XCTAssertEqual(headers.map(\.heading), ["item", "qty", "price"])

        view.hover(at: view.table.frameOfCell(atColumn: 2, row: 1).center)
        XCTAssertEqual(view.hovered, CellRef(row: 1, column: 1))
        XCTAssertEqual(view.markForTesting(row: 1, column: 1), .hover)
        XCTAssertEqual(view.markForTesting(row: 1, column: -1), .lit, "its row number lights")
        XCTAssertEqual(view.markForTesting(row: 0, column: -1), .gutter)
        XCTAssertTrue(view.headerLitForTesting(1), "and its column letter")
        XCTAssertFalse(view.headerLitForTesting(0))
        XCTAssertEqual(view.markForTesting(row: 1, column: 0), .none, "not the whole row")
        view.hover(at: nil)

        view.mouseDown(at: view.table.frameOfCell(atColumn: 3, row: 0).center, extend: false)
        XCTAssertEqual(view.anchor, CellRef(row: 0, column: 2))
        XCTAssertEqual(view.markForTesting(row: 0, column: 2), .active)
        XCTAssertEqual(view.summaryForTesting, "C2")
        view.mouseDown(at: view.table.frameOfCell(atColumn: 2, row: 2).center, extend: true)
        XCTAssertEqual(view.markForTesting(row: 1, column: 1), .range)
        XCTAssertEqual(view.summaryForTesting, "B2:C4 \u{00B7} 6 cells \u{00B7} Sum 12.75 \u{00B7} Average 2.55", "x isn't a number")

        let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                    characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 125)!
        XCTAssertTrue(view.handleKey(down))
        XCTAssertEqual(view.anchor, CellRef(row: 1, column: 2), "the arrow moves the active cell")
        XCTAssertEqual(view.focus, view.anchor)
        view.mouseDown(at: view.table.frameOfCell(atColumn: 0, row: 2).center, extend: false)
        XCTAssertEqual(view.selection?.columns, 0...2, "a row number selects its row")
        XCTAssertEqual(view.selection?.rows, 2...2)
    }

    /// The header view copies a header cell for the space past the last column; the copy must
    /// own its strings (the app crashed when the copy and the column's cell both freed them).
    func testAHeaderCellCopiesSafely() {
        var copies: [SheetHeaderCell] = []
        for index in 0..<200 {
            autoreleasepool {
                let cell = SheetHeaderCell(letter: SheetView.letter(index), title: "Column \(index) with a longer title", corner: false)
                cell.lit = true
                copies.append(cell.copy() as! SheetHeaderCell)
            }
        }
        XCTAssertEqual(copies[42].heading, "Column 42 with a longer title")
        XCTAssertEqual(copies[42].letter, "AQ")
        XCTAssertTrue(copies[42].lit)
    }

    /// Number format codes as Excel shows them.
    func testNumberFormats() {
        let formats = NumberFormatCode(locale: Locale(identifier: "en_US"))
        XCTAssertEqual(formats.display(0.153, code: "0.0%"), "15.3%")
        XCTAssertEqual(formats.display(1234567.891, code: "#,##0.00"), "1,234,567.89")
        XCTAssertEqual(formats.display(-42, code: #"$#,##0_);($#,##0)"#), "($42)")
        XCTAssertEqual(formats.display(42, code: #"$#,##0_);($#,##0)"#), "$42")
        XCTAssertEqual(formats.display(0, code: NumberFormatCode.builtIn(44)), "$-", "accounting shows zero as a dash")
        XCTAssertEqual(formats.display(1500, code: "[$€-407]#,##0"), "€1,500")
        XCTAssertEqual(formats.display(-3.5, code: "0.00"), "-3.50")
        XCTAssertEqual(formats.display(12345, code: "0.00E+00"), "1.23E+04")
        XCTAssertEqual(formats.display(7, code: "000"), "007")
        XCTAssertEqual(formats.display(2.5, code: "General"), "2.5")
        XCTAssertEqual(formats.display(1.0 / 3.0, code: "General"), "0.3333333333")
        XCTAssertEqual(formats.display(45200, code: NumberFormatCode.builtIn(14)), "2023-10-01")
        XCTAssertEqual(formats.display(45200.75, code: "mmm d, yyyy h:mm AM/PM"), "Oct 1, 2023 6:00 PM")
        XCTAssertEqual(formats.display(45200, code: "dddd"), "Sunday")
        XCTAssertEqual(formats.display(0.5, code: "hh:mm"), "12:00", "m after h is minutes")
        XCTAssertEqual(formats.display(1.25, code: "[h]:mm"), "30:00", "elapsed hours")
        XCTAssertEqual(formats.display(5, code: #"0 "units""#), "5 units")
        XCTAssertEqual(formats.display(5, code: ";;;"), "", "a hidden value")
    }

    /// A workbook's colours, fitted so they read on Side's background.
    func testWorkbookColoursAreFittedToTheBackground() {
        let darkCanvas = SheetColor.RGB(0x1C1F23), white = SheetColor.RGB(0xFFFFFF)
        XCTAssertNil(SheetColor.fit(CellStyle(fill: 0xFFFFFF), over: darkCanvas, dark: true).fill, "a white fill is the sheet's own background")
        XCTAssertNil(SheetColor.fit(CellStyle(color: 0x000000), over: darkCanvas, dark: true).text, "black text is the label colour")
        let navy = SheetColor.fit(CellStyle(color: 0x1F3864), over: darkCanvas, dark: true).text!
        let fitted = SheetColor.RGB(r: navy.redComponent, g: navy.greenComponent, b: navy.blueComponent)
        XCTAssertGreaterThanOrEqual(SheetColor.contrast(fitted, darkCanvas), 3, "dark blue text turns light on dark")
        XCTAssertGreaterThan(fitted.b, fitted.r, "and stays blue")
        let header = SheetColor.fit(CellStyle(fill: 0x1F3864), over: white, dark: false)
        XCTAssertNotNil(header.fill)
        XCTAssertEqual(header.text?.usingColorSpace(.sRGB)?.redComponent, 1, "white text on a dark fill")
        XCTAssertEqual(SheetColor.tinted(0x4472C4, by: 0.8), 0xDAE3F3, "Excel's 80% lighter accent 1")
    }

    func testTheViewAlignsSortsAndCopies() throws {
        let view = SheetView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        view.show([Sheet(name: "s", rows: [["name", "score"], ["b", "10"], ["a", "9"], ["c", ""]])])
        XCTAssertEqual(view.table.numberOfRows, 3)
        XCTAssertEqual(view.rows.map(\.number), [2, 3, 4], "rows numbered as in the file, the header being 1")
        XCTAssertTrue(SheetView.isNumeric(["10", "9", "", "1,200", "$3", "(4)", "€5"]))
        XCTAssertFalse(SheetView.isNumeric(["a", "9"]))
        XCTAssertEqual(SheetView.number("(1,200)"), -1200)
        view.sort(by: 1, ascending: true)
        XCTAssertEqual(view.rows.map(\.cells[0]), ["a", "b", "c"], "numbers as numbers (9 before 10), blanks last")
        XCTAssertEqual(view.rows.map(\.number), [3, 2, 4], "row numbers stay with their rows")
        view.sort(by: 1, ascending: false)
        XCTAssertEqual(view.rows.map(\.cells[0]), ["b", "a", "c"], "blanks last either way")
        view.sort(by: 1, ascending: true)
        view.select(CellRef(row: 0, column: 0), to: CellRef(row: 0, column: 1))
        view.copySelection()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "a\t9")
        view.selectAllCells()
        view.copySelection()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "name\tscore\na\t9\nb\t10\nc\t", "everything, with the header")
        XCTAssertEqual(SheetView.letter(0), "A")
        XCTAssertEqual(SheetView.letter(27), "AB")
        if let directory = ProcessInfo.processInfo.environment["SIDE_PREVIEW_SNAPSHOT"] {
            let regions = ["North", "South", "East", "West"], products = ["Widget", "Gadget", "Sprocket"]
            var rows: [[String]] = [["Region", "Product", "Units", "Revenue", "Updated"]]
            for i in 1...24 {
                let day = String(format: "%02d", i)
                rows.append([regions[i % 4], products[i % 3], String(i * 37), "$" + String(i * 1250), "2026-10-" + day])
            }
            for dark in [false, true] {
                let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
                let sheet = SheetView(frame: NSRect(x: 0, y: 0, width: 760, height: 420))
                sheet.appearance = appearance
                sheet.show([Sheet(name: "Sales", rows: rows), Sheet(name: "Notes", rows: [["a"]])])
                sheet.layoutSubtreeIfNeeded()
                sheet.select(CellRef(row: 2, column: 2), to: CellRef(row: 4, column: 3))
                sheet.hover(at: sheet.table.frameOfCell(atColumn: 2, row: 7).center)
                snapshot(sheet, appearance, URL(fileURLWithPath: directory).appendingPathComponent(dark ? "sheet-dark.png" : "sheet-light.png"))

                // A styled report: a title row, a banded header, number formats, a red negative.
                var report = Sheet(name: "Report", rows: [["Q3 Revenue", "", "", ""], ["Region", "Revenue", "Change", "Margin"],
                                                          ["North", "$1,250,000", "12.5%", "0.34"], ["South", "$980,400", "-3.2%", "0.29"], ["Total", "$2,230,400", "5.1%", "0.32"]])
                report.headerRow = false
                report.styles = [CellStyle(), CellStyle(bold: true, color: 0x1F3864), CellStyle(bold: true, color: 0xFFFFFF, fill: 0x4472C4, alignment: .center),
                                 CellStyle(color: 0xC00000), CellStyle(bold: true, fill: 0xDAE3F3)]
                report.styleIndex = [[1, 0, 0, 0], [2, 2, 2, 2], [0, 0, 0, 0], [0, 0, 3, 0], [4, 4, 4, 4]]
                report.columnWidths = [0: 140, 1: 120, 2: 90, 3: 90]
                let styled = SheetView(frame: NSRect(x: 0, y: 0, width: 600, height: 260))
                styled.appearance = appearance
                styled.show([report])
                styled.layoutSubtreeIfNeeded()
                snapshot(styled, appearance, URL(fileURLWithPath: directory).appendingPathComponent(dark ? "report-dark.png" : "report-light.png"))
            }
        }
    }
}

/// 2026-10-01, the owner: scrolling the tab strip under a still pointer left the tabs it passed
/// over highlighted, since AppKit sends no exit when the view moves rather than the pointer.
@MainActor
final class TabHoverTests: XCTestCase {
    func testAScrolledAwayTabStopsLookingHovered() {
        let tab = TabChipView(frame: NSRect(x: 0, y: 0, width: 120, height: 28))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView?.addSubview(tab)
        tab.syncHover(pointerInWindow: tab.convert(NSPoint(x: 60, y: 14), to: nil))
        XCTAssertTrue(tab.isHovered)
        // The strip scrolled: the pointer is now well past the tab.
        // The strip scrolled: the pointer is now past the tab, over where the next one is.
        tab.syncHover(pointerInWindow: tab.convert(NSPoint(x: 300, y: 14), to: nil))
        XCTAssertFalse(tab.isHovered)
        XCTAssertTrue(window.isMovable, "the window drags again once no tab is hovered")
    }
}

/// 2026-09-30 audit, SEC-11: opening or saving a file in a cloned repository ran its code: its
/// node_modules TypeScript, its Prettier (or a Prettier config that's a program), its Rust
/// build scripts and macros. Until the project is trusted, they don't run.
@MainActor
final class ProjectTrustTests: XCTestCase {
    private func project() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("trust-\(UUID().uuidString)").resolvingSymlinksInPath()
        let bin = root.appendingPathComponent("node_modules/.bin"), ts = root.appendingPathComponent("node_modules/typescript/lib")
        for folder in [bin, ts] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try "".write(to: ts.appendingPathComponent("tsserver.js"), atomically: true, encoding: .utf8)
        try "#!/bin/sh\necho pwned\n".write(to: bin.appendingPathComponent("prettier"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("prettier").path)
        return root
    }

    func testAProjectsOwnCodeWaitsForTrust() throws {
        let root = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = LanguageServerRegistry.Entry(languageId: "typescript", binaryName: "typescript-language-server", arguments: ["--stdio"], install: nil, languageKey: "typescript", asksToInstall: false)
        XCTAssertNotEqual(LanguageServerRegistry.tsserverPathOverride(for: entry, projectRoot: root, trusted: false), .projectDefault, "untrusted: not the project's TypeScript")
        XCTAssertEqual(LanguageServerRegistry.tsserverPathOverride(for: entry, projectRoot: root, trusted: true), .projectDefault)

        let file = root.appendingPathComponent("a.ts")
        XCTAssertNotEqual(MakeWorkspaceViewController.stdinFormatterCommand(for: file, projectRoot: root)?.executable, root.appendingPathComponent("node_modules/.bin/prettier").path)
        try "module.exports = {}".write(to: root.appendingPathComponent("prettier.config.js"), atomically: true, encoding: .utf8)
        XCTAssertNil(MakeWorkspaceViewController.stdinFormatterCommand(for: file, projectRoot: root), "a config that's code: no formatting until trusted")
        XCTAssertEqual(ProjectTrust.projectCode(in: root), ["its TypeScript", "its formatter"])

        XCTAssertFalse(ProjectTrust.isTrusted(root))
        ProjectTrust.trust(root)
        XCTAssertTrue(ProjectTrust.isTrusted(root))
        XCTAssertEqual(MakeWorkspaceViewController.stdinFormatterCommand(for: file, projectRoot: root)?.executable, root.appendingPathComponent("node_modules/.bin/prettier").path)
    }

    /// A track's worktree is trusted with its repository.
    func testAWorktreeIsItsRepositorysProject() throws {
        let root = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        let worktree = FileManager.default.temporaryDirectory.appendingPathComponent("trust-wt-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: worktree) }
        try "gitdir: \(root.path)/.git/worktrees/feature\n".write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        XCTAssertEqual(ProjectTrust.projectKey(worktree), ProjectTrust.projectKey(root))
    }

    func testMakeAsksForAnUntrustedProject() throws {
        let root = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        let make = MakeWorkspaceViewController()
        make.loadViewIfNeeded()
        make.loadProject(at: root)
        XCTAssertTrue(make.trustBannerTextForTesting?.contains("its TypeScript") == true, make.trustBannerTextForTesting ?? "no banner")
        ProjectTrust.trust(root)
        XCTAssertNil(make.trustBannerTextForTesting, "trusted: the banner goes")
    }

    /// Svelte: a project with its own Svelte setup counts as project code (its server runs the
    /// config), and .svelte files have a language server to offer.
    func testSvelteProjectsWaitForTrust() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("svelte-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertFalse(ProjectTrust.hasSvelteProjectCode(root))
        try "export default {}".write(to: root.appendingPathComponent("svelte.config.js"), atomically: true, encoding: .utf8)
        XCTAssertTrue(ProjectTrust.hasSvelteProjectCode(root))
        XCTAssertTrue(ProjectTrust.projectCode(in: root).contains("its Svelte setup"))
        XCTAssertEqual(LanguageSettings.preset(forExtension: "svelte")?.servers.first?.binary, "svelteserver")
    }

    /// LaTeX: texlab, and a project's latexmkrc (Perl, run by latexmk) waits for trust.
    func testLaTeXProjectsWithALatexmkrcWaitForTrust() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("latex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertFalse(ProjectTrust.hasLaTeXProjectCode(root))
        try "$pdf_mode = 1;".write(to: root.appendingPathComponent(".latexmkrc"), atomically: true, encoding: .utf8)
        XCTAssertTrue(ProjectTrust.hasLaTeXProjectCode(root))
        XCTAssertTrue(ProjectTrust.projectCode(in: root).contains("its latexmkrc"))
        XCTAssertEqual(LanguageSettings.preset(forExtension: "tex")?.servers.first?.binary, "texlab")
        XCTAssertEqual(LanguageSettings.shared.entry(forExtension: "bib")?.languageId, "bibtex")
        XCTAssertEqual(FileIcon.style(forName: "paper.tex", isDirectory: false).glyph, .letters("TEX"))
    }

    /// 2026-10-23, the owner: the banner fell to the bottom, behind the floating bar. Its tab bar
    /// is moved into the window's top row, which dropped the constraint it hung from; it now
    /// hangs from the top row's height, and the text starts below it.
    func testTheTrustBannerStaysUnderTheTopRowWhenTheTabsMoveOut() throws {
        let root = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        let make = MakeWorkspaceViewController()
        make.loadViewIfNeeded()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let container = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = container
        container.addSubview(make.view)
        make.view.frame = container.bounds
        container.addSubview(make.topRowContent!)  // as the shell does: the tabs leave Make's view
        make.viewDidAppear()  // where the banners are built, as the window showing would
        make.setTopObstruction(52)
        make.loadProject(at: root)
        XCTAssertNotNil(make.trustBannerTextForTesting)
        let layout = make.trustBannerLayoutForTesting
        XCTAssertEqual(layout.top, 52, accuracy: 0.5, "right under the top row, not at the bottom: \(layout.detail)")
        XCTAssertEqual(layout.editorInset, 52 + 28, accuracy: 0.5, "the text starts below the banner")
        ProjectTrust.trust(root)
        XCTAssertEqual(make.trustBannerLayoutForTesting.editorInset, 52, accuracy: 0.5, "and moves back up once it's gone")
    }
}

/// SEC-14 (2026-09-30 audit): a key in Side's environment doesn't reach the processes it starts.
final class SpawnEnvironmentTests: XCTestCase {
    private let names = ["ANTHROPIC_API_KEY", "GH_TOKEN"]

    override func setUp() {
        super.setUp()
        for name in names { setenv(name, "side-test-\(name)", 1) }
    }

    override func tearDown() {
        for name in names { unsetenv(name) }
        super.tearDown()
    }

    func testLanguageServersAndAdaptersGetNoKeys() {
        XCTAssertNil(LanguageServerRegistry.environmentForSpawning()["ANTHROPIC_API_KEY"])
        XCTAssertNil(DebugSession.adapterEnvironment()["GH_TOKEN"])
        XCTAssertNotNil(LanguageServerRegistry.environmentForSpawning()["PATH"])
        XCTAssertEqual(LanguageServerRegistry.environmentForSpawning(keeping: ["GH_TOKEN"])["GH_TOKEN"], "side-test-GH_TOKEN", "gh keeps its own")
    }

    /// A build is a shell Side starts: the key isn't in it.
    func testABuildGetsNoKeys() async {
        let (status, output) = await DebugSession.run("printenv ANTHROPIC_API_KEY; echo done", in: NSTemporaryDirectory())
        XCTAssertEqual(status, 0)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "done")
    }

    /// An outside agent in API-key mode still finds a key exported to Side; in Subscription
    /// mode it gets none.
    func testAnAgentGetsOnlyItsOwnKeyInAPIKeyMode() {
        let agent = ACPAgent.builtIn.first { $0.id == "claude-code" }!
        let saved = agent.signIn
        defer { agent.signIn = saved }
        let base = LanguageServerRegistry.environmentForSpawning()
        agent.signIn = .subscription
        XCTAssertNil(agent.launchEnvironment(from: base)["ANTHROPIC_API_KEY"])
        agent.signIn = .apiKey
        if agent.storedAPIKey == nil {
            XCTAssertEqual(agent.launchEnvironment(from: base)["ANTHROPIC_API_KEY"], "side-test-ANTHROPIC_API_KEY")
        }
        XCTAssertNil(agent.launchEnvironment(from: base)["GH_TOKEN"])
    }
}

/// The open-source components' notices ship inside Side (their licenses require it) and name
/// each component the generator found.
@MainActor
final class ThirdPartyNoticesTests: XCTestCase {
    func testTheNoticesShipInTheApp() throws {
        let notices = try XCTUnwrap(AppDelegate.thirdPartyNotices, "ThirdPartyNotices.txt is in the app's resources")
        for component in ["Sparkle", "SwiftTerm", "SwiftTreeSitter", "tree-sitter-swift", "tree-sitter-yaml"] {
            XCTAssertTrue(notices.contains(component), component)
        }
        XCTAssertTrue(notices.contains("Permission is hereby granted, free of charge"), "the license texts, not just names")
    }
}

@MainActor private func snapshot(_ view: NSView, _ appearance: NSAppearance, _ url: URL) {
    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    appearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: rep) }
    try? rep.representation(using: NSBitmapImageRep.FileType.png, properties: [:])?.write(to: url)
}

private extension NSRect {
    var center: NSPoint { NSPoint(x: midX, y: midY) }
}
