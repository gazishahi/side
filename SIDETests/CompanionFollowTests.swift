import XCTest
@testable import Side

/// The companion's Follow (SIDE_DESIGN_SESSIONS_2026-11-06.md, session 1): which changed files
/// it shows, and where in them.
final class CompanionFollowTests: XCTestCase {
    func testTheFirstChangedLineIsWhereTheEditLanded() {
        XCTAssertEqual(ShellViewController.firstChangedLine("a\nb\nc", "a\nB\nc"), 2)
        XCTAssertEqual(ShellViewController.firstChangedLine("a\nb", "a\nb\nc"), 3, "a line added at the end")
        XCTAssertEqual(ShellViewController.firstChangedLine("a\nb\nc", "a\nb"), 2, "a deleted last line lands on the new last line")
        XCTAssertNil(ShellViewController.firstChangedLine("same", "same"))
    }

    /// Source files under the track's folder, never git's own files, dependencies or build output.
    func testOnlySourceUnderTheRootIsFollowed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("follow-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let files = ["src/main.swift", ".git/index", "node_modules/x/index.js", ".build/out.o", "src/.hidden"]
        for file in files {
            let url = root.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        let elsewhere = FileManager.default.temporaryDirectory.appendingPathComponent("elsewhere-\(UUID().uuidString).swift")
        try Data("x".utf8).write(to: elsewhere)
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        let paths = (files.map { root.appendingPathComponent($0).path } + [elsewhere.path, root.appendingPathComponent("src").path])
        let followed = ShellViewController.followCandidates(paths, root: root).map(\.lastPathComponent)
        XCTAssertEqual(followed, ["main.swift"], "a folder, files outside the root and ignored places are skipped")
    }
}
