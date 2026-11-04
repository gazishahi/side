import XCTest
@testable import Side
@testable import SideAgents

/// The regression tests the 2026-09-01 audit listed in Part V item 15 that were not tied to a fix
/// already made — written now so "closed" means test-pinned, not commit-message-pinned.

// MARK: - JSON-RPC framing

final class JSONRPCFramingTests: XCTestCase {
    private func frame(_ body: String, length: Int? = nil) -> Data {
        let n = length ?? body.utf8.count
        return Data("Content-Length: \(n)\r\n\r\n".utf8) + Data(body.utf8)
    }

    func testBadContentLengthsAreReportedNotTrappedAndTheStreamRecovers() {
        // `Int("-5")` is a valid Int; indexing a buffer by it is a crash. Now it is a problem
        // report, and the stream keeps going; an absurd length is refused rather than buffered.
        var negative = JSONRPCFraming()
        // A negative length has no body worth the name; the next header follows directly.
        let clean = negative.feed(frame("", length: -5) + frame("{\"ok\":1}"))
        XCTAssertEqual(clean.problems, [.invalidContentLength(-5)])
        XCTAssertEqual(clean.messages.map { String(decoding: $0, as: UTF8.self) }, ["{\"ok\":1}"])

        // Bytes that were the bad frame's "body" corrupt the next header; both are reported, none
        // crash, and a clean frame after them is delivered.
        var junk = JSONRPCFraming()
        let recovered = junk.feed(frame("{}", length: -5) + frame("{\"a\":1}") + frame("{\"b\":2}"))
        XCTAssertEqual(recovered.problems.first, .invalidContentLength(-5))
        XCTAssertEqual(recovered.messages.map { String(decoding: $0, as: UTF8.self) }.last, "{\"b\":2}")

        var absurd = JSONRPCFraming()
        let refused = absurd.feed(frame("{}", length: 5_000_000_000))
        XCTAssertEqual(refused.problems, [.invalidContentLength(5_000_000_000)])
        XCTAssertTrue(refused.messages.isEmpty)
    }

    func testMessagesReassembleAcrossChunksAndArriveInOrder() {
        var framing = JSONRPCFraming()
        let whole = frame("{\"method\":\"x\"}")
        let first = framing.feed(whole.prefix(10))
        XCTAssertTrue(first.messages.isEmpty)
        let second = framing.feed(whole.suffix(from: 10))
        XCTAssertEqual(second.messages.map { String(decoding: $0, as: UTF8.self) }, ["{\"method\":\"x\"}"])
        // Two whole messages in one chunk come out of the same stream in order.
        let both = framing.feed(frame("{\"a\":1}") + frame("{\"b\":2}"))
        XCTAssertEqual(both.messages.map { String(decoding: $0, as: UTF8.self) }, ["{\"a\":1}", "{\"b\":2}"])
    }

    func testAHeaderWithoutContentLengthIsSkipped() {
        var framing = JSONRPCFraming()
        let result = framing.feed(Data("Content-Type: x\r\n\r\n".utf8) + frame("{}"))
        XCTAssertEqual(result.problems, [.missingContentLength])
        XCTAssertEqual(result.messages.count, 1)
    }
}

// MARK: - Checkpoint staging

final class CheckpointStagingTests: XCTestCase {
    func testAPreStagedManualEditIsNotSweptIntoTheAgentsCheckpoint() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ args: [String]) -> String {
            let r = GitPaths.runGit(args, cwd: root.path); XCTAssertTrue(r.success, "git \(args): \(r.output)"); return r.output
        }
        git(["init", "-q", "-b", "main"]); git(["config", "user.email", "t@t"]); git(["config", "user.name", "T"])
        try "a".write(to: root.appendingPathComponent("agent.txt"), atomically: true, encoding: .utf8)
        try "m".write(to: root.appendingPathComponent("manual.txt"), atomically: true, encoding: .utf8)
        git(["add", "."]); git(["commit", "-q", "-m", "base"])

        // The user has a manual edit *staged* before the agent's batch begins.
        try "manual v2".write(to: root.appendingPathComponent("manual.txt"), atomically: true, encoding: .utf8)
        git(["add", "manual.txt"])
        let baseline = GitPaths.dirtyPaths(cwd: root.path)
        XCTAssertEqual(baseline, ["manual.txt"])

        // The agent's batch edits its own file.
        try "agent v2".write(to: root.appendingPathComponent("agent.txt"), atomically: true, encoding: .utf8)
        let outcome = CheckpointCommit.stageAndCommit(root: root.path, baseline: baseline, knownChanged: ["agent.txt"], message: "agent work")
        guard case .committed(_, let paths)? = outcome else { return XCTFail("expected a commit, got \(String(describing: outcome))") }
        XCTAssertEqual(paths, ["agent.txt"])
        // The commit contains only the agent's file; the manual edit is still staged, uncommitted.
        XCTAssertEqual(git(["show", "--name-only", "--format=", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines), "agent.txt")
        XCTAssertEqual(git(["diff", "--cached", "--name-only"]).trimmingCharacters(in: .whitespacesAndNewlines), "manual.txt")
    }
    /// 2026-09-30 audit, GIT-3: status listed a new directory as one entry, so the person's
    /// `newdir/notes.md`, saved while the agent's command made `newdir/x.swift`, was committed
    /// with it (the user-save rule couldn't subtract a file it never saw named).
    func testTheAgentsNewFileInANewDirectoryIsCheckpointedAlone() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ args: [String]) -> String {
            let r = GitPaths.runGit(args, cwd: root.path); XCTAssertTrue(r.success, "git \(args): \(r.output)"); return r.output
        }
        git(["init", "-q", "-b", "main"]); git(["config", "user.email", "t@t"]); git(["config", "user.name", "T"])
        try "a".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        git(["add", "."]); git(["commit", "-q", "-m", "base"])
        let baseline = GitPaths.dirtyPaths(cwd: root.path)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("newdir"), withIntermediateDirectories: true)
        try "mine".write(to: root.appendingPathComponent("newdir/notes.md"), atomically: true, encoding: .utf8)
        try "agent".write(to: root.appendingPathComponent("newdir/x.swift"), atomically: true, encoding: .utf8)

        let outcome = CheckpointCommit.stageAndCommit(root: root.path, baseline: baseline, knownChanged: [], userSaved: ["newdir/notes.md"], message: "agent work")
        guard case .committed(_, let paths)? = outcome else { return XCTFail("expected a commit, got \(String(describing: outcome))") }
        XCTAssertEqual(paths, ["newdir/x.swift"])
        XCTAssertEqual(git(["show", "--name-only", "--format=", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines), "newdir/x.swift")
    }

    /// 2026-09-30 audit, GIT-11: with no baseline (git status failed before the batch), the
    /// checkpoint took every dirty file, the person's own included. Now only the known edits.
    func testWithNoBaselineOnlyTheKnownEditsAreCheckpointed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ args: [String]) -> String {
            let r = GitPaths.runGit(args, cwd: root.path); XCTAssertTrue(r.success, "git \(args): \(r.output)"); return r.output
        }
        git(["init", "-q", "-b", "main"]); git(["config", "user.email", "t@t"]); git(["config", "user.name", "T"])
        try "a".write(to: root.appendingPathComponent("agent.txt"), atomically: true, encoding: .utf8)
        try "m".write(to: root.appendingPathComponent("manual.txt"), atomically: true, encoding: .utf8)
        git(["add", "."]); git(["commit", "-q", "-m", "base"])
        try "manual v2".write(to: root.appendingPathComponent("manual.txt"), atomically: true, encoding: .utf8)
        try "agent v2".write(to: root.appendingPathComponent("agent.txt"), atomically: true, encoding: .utf8)

        let outcome = CheckpointCommit.stageAndCommit(root: root.path, baseline: nil, knownChanged: ["agent.txt"], message: "agent work")
        guard case .committed(_, let paths)? = outcome else { return XCTFail("expected a commit, got \(String(describing: outcome))") }
        XCTAssertEqual(paths, ["agent.txt"])
        XCTAssertEqual(git(["status", "--porcelain"]).trimmingCharacters(in: .whitespacesAndNewlines), "M manual.txt")
    }
}

// MARK: - Minimal tasks.json

final class ProjectTaskDecodeTests: XCTestCase {
    func testATaskWithOnlyNameAndCommandDecodes() throws {
        let tasks = try JSONDecoder().decode([ProjectTask].self, from: Data(#"[{"name":"test","command":"swift test"}]"#.utf8))
        XCTAssertEqual(tasks.first?.name, "test")
        XCTAssertEqual(tasks.first?.detail, "")
        XCTAssertEqual(tasks.first?.isVerification, false)
    }
}
