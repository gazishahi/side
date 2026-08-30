import XCTest
@testable import Side

/// Undo is the one feature whose bugs are unrecoverable by definition — if it destroys work, the
/// work is gone. These cover both halves: the ordering/selection logic (pure), and the git
/// sequence itself against a real repository.
final class CheckpointRestoreTests: XCTestCase {

    private func checkpoint(_ intent: String, sha: String?, at offset: TimeInterval) -> Checkpoint {
        var checkpoint = Checkpoint(
            trackKey: "main", agentSessionId: UUID(), declaredIntent: intent,
            changedFilePaths: [], commandsRun: [],
            provenance: AgentProvenance(providerId: "p", modelId: "m", instructionSourceSummary: ""),
            gitCommitSHA: sha
        )
        // createdAt is set at init; re-encode with the offset so ordering is deterministic.
        let json = try! JSONEncoder().encode(checkpoint)
        var object = try! JSONSerialization.jsonObject(with: json) as! [String: Any]
        object["createdAt"] = Date(timeIntervalSinceReferenceDate: offset).timeIntervalSinceReferenceDate
        let patched = try! JSONSerialization.data(withJSONObject: object)
        checkpoint = try! JSONDecoder().decode(Checkpoint.self, from: patched)
        return checkpoint
    }

    // MARK: - What gets reverted, and in what order

    func testSingleScopeRevertsOnlyThatCheckpoint() {
        let first = checkpoint("first", sha: "aaa", at: 100)
        let second = checkpoint("second", sha: "bbb", at: 200)
        let third = checkpoint("third", sha: "ccc", at: 300)
        XCTAssertEqual(
            CheckpointRestore.commitsToRevert(checkpoints: [first, second, third], target: second, scope: .single),
            ["bbb"]
        )
    }

    func testRestoringThroughLatestRevertsNewestFirst() {
        // Order is the whole correctness question: reversing the oldest first would try to undo
        // a change against a tree that later commits have already moved on from, and conflict
        // for reasons that look like git misbehaving.
        let first = checkpoint("first", sha: "aaa", at: 100)
        let second = checkpoint("second", sha: "bbb", at: 200)
        let third = checkpoint("third", sha: "ccc", at: 300)
        XCTAssertEqual(
            CheckpointRestore.commitsToRevert(checkpoints: [first, second, third], target: second, scope: .throughLatest),
            ["ccc", "bbb"]
        )
    }

    func testCheckpointsWithNoCommitAreSkipped() {
        // A command-only checkpoint has no commit — there's nothing to revert, and including a
        // nil would either crash or revert the wrong thing.
        let first = checkpoint("edit", sha: "aaa", at: 100)
        let second = checkpoint("ran tests", sha: nil, at: 200)
        let third = checkpoint("edit again", sha: "ccc", at: 300)
        XCTAssertEqual(
            CheckpointRestore.commitsToRevert(checkpoints: [first, second, third], target: first, scope: .throughLatest),
            ["ccc", "aaa"]
        )
    }

    func testOutOfOrderInputIsSortedByTime() {
        let first = checkpoint("first", sha: "aaa", at: 100)
        let second = checkpoint("second", sha: "bbb", at: 200)
        XCTAssertEqual(
            CheckpointRestore.commitsToRevert(checkpoints: [second, first], target: first, scope: .throughLatest),
            ["bbb", "aaa"]
        )
    }

    func testAnUnknownTargetRevertsNothing() {
        let known = checkpoint("known", sha: "aaa", at: 100)
        let stranger = checkpoint("stranger", sha: "zzz", at: 150)
        XCTAssertTrue(CheckpointRestore.commitsToRevert(checkpoints: [known], target: stranger, scope: .throughLatest).isEmpty)
    }

    func testMessageNamesWhatIsBeingUndone() {
        let target = checkpoint("add the parser", sha: "aaa", at: 100)
        XCTAssertTrue(CheckpointRestore.revertMessage(target: target, scope: .single, count: 1).contains("add the parser"))
        let many = CheckpointRestore.revertMessage(target: target, scope: .throughLatest, count: 3)
        XCTAssertTrue(many.contains("3"), many)
    }

    // MARK: - Against a real repository

    private func makeRepo() throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("restore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.path
        for args in [["init"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] {
            XCTAssertTrue(GitPaths.runGit(args, cwd: path).success, "git \(args.joined(separator: " "))")
        }
        return path
    }

    private func commit(_ contents: String, to file: String, in path: String, message: String) -> String {
        try? contents.write(toFile: path + "/" + file, atomically: true, encoding: .utf8)
        XCTAssertTrue(GitPaths.runGit(["add", "."], cwd: path).success)
        XCTAssertTrue(GitPaths.runGit(["commit", "-m", message], cwd: path).success)
        return GitPaths.runGit(["rev-parse", "HEAD"], cwd: path).output
    }

    func testRevertingRestoresTheContentAndKeepsHistory() throws {
        let path = try makeRepo()
        _ = commit("original\n", to: "a.txt", in: path, message: "base")
        let agentSHA = commit("agent wrote this\n", to: "a.txt", in: path, message: "agent edit")

        let outcome = CheckpointRestore.perform(commits: [agentSHA], message: "Undo agent checkpoint", worktreePath: path)
        guard case .reverted(_, let count) = outcome else { return XCTFail("expected revert, got \(outcome)") }
        XCTAssertEqual(count, 1)

        let contents = try String(contentsOfFile: path + "/a.txt", encoding: .utf8)
        XCTAssertEqual(contents, "original\n")
        // Forward motion, not erasure: the agent's commit is still in the log, plus the undo.
        let log = GitPaths.runGit(["log", "--oneline"], cwd: path).output
        XCTAssertTrue(log.contains("agent edit"), log)
        XCTAssertEqual(log.split(separator: "\n").count, 3, log)
    }

    func testUncommittedWorkInOtherFilesSurvives() throws {
        // The reason this is a revert and not `reset --hard`. A user's unsaved-to-git work sits
        // in the tree constantly; an undo that eats it is worse than no undo at all.
        let path = try makeRepo()
        _ = commit("original\n", to: "a.txt", in: path, message: "base")
        let agentSHA = commit("agent wrote this\n", to: "a.txt", in: path, message: "agent edit")
        try "my own work in progress\n".write(toFile: path + "/mine.txt", atomically: true, encoding: .utf8)

        _ = CheckpointRestore.perform(commits: [agentSHA], message: "Undo", worktreePath: path)

        XCTAssertEqual(try String(contentsOfFile: path + "/mine.txt", encoding: .utf8), "my own work in progress\n")
    }

    func testRevertingSeveralCheckpointsProducesOneCommit() throws {
        let path = try makeRepo()
        _ = commit("v0\n", to: "a.txt", in: path, message: "base")
        let first = commit("v1\n", to: "a.txt", in: path, message: "agent 1")
        let second = commit("v2\n", to: "a.txt", in: path, message: "agent 2")

        let outcome = CheckpointRestore.perform(commits: [second, first], message: "Undo 2 checkpoints", worktreePath: path)
        guard case .reverted(_, let count) = outcome else { return XCTFail("expected revert, got \(outcome)") }
        XCTAssertEqual(count, 2)
        XCTAssertEqual(try String(contentsOfFile: path + "/a.txt", encoding: .utf8), "v0\n")
        // One undo entry, not one per checkpoint — the log should read like the decision, not
        // like the mechanism.
        XCTAssertEqual(GitPaths.runGit(["log", "--oneline"], cwd: path).output.split(separator: "\n").count, 4)
    }

    func testAConflictLeavesTheWorktreeUntouched() throws {
        let path = try makeRepo()
        _ = commit("line\n", to: "a.txt", in: path, message: "base")
        let agentSHA = commit("agent line\n", to: "a.txt", in: path, message: "agent edit")
        // Someone edited the same line afterwards, so the reversal can't apply cleanly.
        _ = commit("human line\n", to: "a.txt", in: path, message: "human edit")

        let outcome = CheckpointRestore.perform(commits: [agentSHA], message: "Undo", worktreePath: path)
        guard case .conflicted(let paths) = outcome else { return XCTFail("expected conflict, got \(outcome)") }
        XCTAssertEqual(paths, ["a.txt"])
        // Half-undone with conflict markers in it would be the worst possible outcome — the
        // file must read exactly as it did before the attempt.
        XCTAssertEqual(try String(contentsOfFile: path + "/a.txt", encoding: .utf8), "human line\n")
        XCTAssertTrue(GitPaths.runGit(["status", "--porcelain"], cwd: path).output.isEmpty)
    }

    func testUndoingAnUndoIsJustAnotherRevert() throws {
        // Falls out of the design, and is worth pinning: reverts are ordinary commits, so the
        // undo of an undo needs no special case anywhere.
        let path = try makeRepo()
        _ = commit("original\n", to: "a.txt", in: path, message: "base")
        let agentSHA = commit("agent wrote this\n", to: "a.txt", in: path, message: "agent edit")

        guard case .reverted(let undoSHA, _) = CheckpointRestore.perform(commits: [agentSHA], message: "Undo", worktreePath: path) else {
            return XCTFail("first revert failed")
        }
        guard case .reverted = CheckpointRestore.perform(commits: [undoSHA], message: "Redo", worktreePath: path) else {
            return XCTFail("second revert failed")
        }
        XCTAssertEqual(try String(contentsOfFile: path + "/a.txt", encoding: .utf8), "agent wrote this\n")
    }

    func testNothingToRevertIsNotAFailure() {
        XCTAssertEqual(CheckpointRestore.perform(commits: [], message: "x", worktreePath: "/tmp"), .nothingToDo)
    }
}
