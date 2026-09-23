import XCTest
@testable import Side

/// The explorer's two pure pieces: what a folder lists, and what `git status` marks.
final class FileExplorerTests: XCTestCase {
    func testGitStatusMarksFilesAndEveryFolderAboveThem() {
        let root = URL(fileURLWithPath: "/tmp/proj")
        // porcelain v1 -z: modified, untracked, renamed (source follows), conflicted, deleted.
        let raw = " M src/app.swift\u{0}?? docs/new.md\u{0}R  lib/b.swift\u{0}lib/a.swift\u{0}UU core/merge.swift\u{0} D gone.txt\u{0}"
        let marks = FileExplorer.parseStatus(Data(raw.utf8), root: root)
        let cases: [(String, FileExplorer.GitMark?)] = [
            ("src/app.swift", .modified), ("src", .modified),
            ("docs/new.md", .added), ("docs", .added),  // only new inside → green
            ("lib/b.swift", .modified), ("lib/a.swift", nil),
            ("core/merge.swift", .conflicted), ("core", .conflicted),
            ("gone.txt", nil),
        ]
        // A folder with new and modified files inside reads as modified.
        let mixed = FileExplorer.parseStatus(Data(" M a/x.swift\u{0}?? a/y.swift\u{0}".utf8), root: root)
        XCTAssertEqual(mixed[root.appendingPathComponent("a").path], .modified)
        for (path, expected) in cases {
            XCTAssertEqual(marks[root.appendingPathComponent(path).path], expected, path)
        }
    }

    func testAFolderListsFoldersFirstAndSkipsHiddenAndGeneratedEntries() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("explorer-\(UUID().uuidString)", isDirectory: true)
        for folder in ["b-folder", "node_modules", ".git"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for file in ["Makefile", "a.swift", "B.md", ".env"] {
            try Data().write(to: root.appendingPathComponent(file))
        }
        let names = FileExplorer.listDirectory(root).map(\.url.lastPathComponent)
        // Extension-less files (Makefile) are listed — the old tree came from an index that
        // dropped them.
        XCTAssertEqual(names, ["b-folder", "a.swift", "B.md", "Makefile"])
    }
}
