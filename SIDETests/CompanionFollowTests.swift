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

/// Rich blocks (SIDE_DESIGN_SESSIONS_2026-11-06.md, session 2): which parts of a message are
/// blocks, and what's read out of them.
final class RichBlocksTests: XCTestCase {
    func testAMessageIsCutIntoProseAndBlocks() {
        let text = "Before\n\n```mermaid\ngraph TD\n  A --> B\n```\n\nMiddle\n\n| a | b |\n|---|--:|\n| 1 | x\\|y |\n\n```swift\nlet a = 1\n```\nAfter"
        let segments = RichBlocks.segments(text)
        guard segments.count == 5 else { return XCTFail("\(segments)") }
        XCTAssertEqual(segments[0], .text("Before"))
        guard case .block(let diagram) = segments[1], case .block(let table) = segments[3] else { return XCTFail("\(segments)") }
        XCTAssertEqual(diagram.kind, .mermaid)
        XCTAssertEqual(RichBlockView.fenceBody(diagram.source), "graph TD\n  A --> B")
        XCTAssertEqual(table.rows, [["a", "b"], ["1", "x|y"]], "an escaped pipe stays in its cell")
        guard case .text(let tail) = segments[4] else { return XCTFail("\(segments)") }
        XCTAssertTrue(tail.contains("```swift"), "a fence in another language stays text")
    }

    func testPlainTextIsOneSegment() {
        XCTAssertEqual(RichBlocks.segments("No blocks | here, really."), [.text("No blocks | here, really.")])
        XCTAssertEqual(RichBlocks.segments("```mermaid\nunclosed"), [.text("```mermaid\nunclosed")])
    }

    func testCSVKeepsQuotedCommasAndQuotes() {
        XCTAssertEqual(RichBlocks.csvRows("a,b\n\"x, y\",\"say \"\"hi\"\"\"\n"), [["a", "b"], ["x, y", "say \"hi\""]])
    }

    func testAnImageIsOnlyAFileTheProjectHas() {
        let url = URL(fileURLWithPath: "/tmp/chart.png")
        let segments = RichBlocks.segments("![chart](chart.png)\n![gone](gone.png)\n![web](https://x/y.png)", image: { $0 == "chart.png" ? url : nil })
        guard case .block(let block) = segments.first else { return XCTFail("\(segments)") }
        XCTAssertEqual(block.kind, .image)
        XCTAssertEqual(block.url, url)
        XCTAssertEqual(segments.count, 2, "the others stay text")
    }

    func testNumbersSortAsNumbers() {
        let rows = [["b", "10"], ["a", "9"], ["c", "1,200"]]
        XCTAssertEqual(TableBlockView.sorted(rows, column: 1, ascending: true).map { $0[0] }, ["a", "b", "c"])
        XCTAssertEqual(TableBlockView.sorted(rows, column: 0, ascending: false).map { $0[0] }, ["c", "b", "a"])
    }
}
