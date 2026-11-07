import XCTest
@testable import Side
import SideAgents

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

/// The Agent panel's changed files (SIDE_RFC_AGENT_PANEL.md): the branch against where it left
/// its base, committed and not, untracked included, and nothing the base did since.
final class AgentBranchPanelTests: XCTestCase {
    func testChangedFilesAreTheBranchsAgainstItsBase() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("panel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func git(_ args: [String]) { XCTAssertTrue(GitPaths.runGit(args, cwd: root.path).success, "\(args)") }
        func write(_ name: String, _ text: String) throws { try text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        git(["init", "-q", "-b", "main"]); git(["config", "user.email", "t@t"]); git(["config", "user.name", "T"])
        try write("a.txt", "one\ntwo\n")
        git(["add", "."]); git(["commit", "-q", "-m", "base"])
        git(["checkout", "-q", "-b", "feature"])
        try write("a.txt", "one\nTWO\nthree\n")
        git(["commit", "-qam", "branch work"])
        // The base moves on: not the branch's change.
        git(["checkout", "-q", "main"]); try write("c.txt", "base only\n"); git(["add", "."]); git(["commit", "-q", "-m", "base moves"])
        git(["checkout", "-q", "feature"])
        try write("b.txt", "new\nfile\n")
        let files = AgentBranchPanel.changedFiles(cwd: root.path, base: "main")
        XCTAssertEqual(files, [.init(path: "a.txt", added: 2, removed: 1), .init(path: "b.txt", added: 2, removed: 0)])
    }

    func testACheckpointReadsAsOneWord() {
        let checkpoint = Checkpoint(trackKey: "t", agentSessionId: UUID(), declaredIntent: "Fix", changedFilePaths: [], commandsRun: [],
                                    provenance: AgentProvenance(providerId: "", modelId: "", instructionSourceSummary: ""), gitCommitSHA: nil)
        XCTAssertEqual(AgentBranchPanel.checkpointLine(checkpoint).word, "Unverified")
    }
}
