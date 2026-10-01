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
}
