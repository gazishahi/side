import XCTest
@testable import Side
import SideAgents

/// Sessions, phase 4 (SIDE_RFC_SESSIONS.md): Changes as a review queue.
final class ReviewQueueTests: XCTestCase {
    private let diff = """
    diff --git a/Login.swift b/Login.swift
    index 1111111..2222222 100644
    --- a/Login.swift
    +++ b/Login.swift
    @@ -1,3 +1,4 @@
     func login() {
    +  retry(2)
       send()
     }
    @@ -10,2 +11,3 @@
     // tail
    +// typed by hand
     end
    diff --git a/README.md b/README.md
    index 3333333..4444444 100644
    --- a/README.md
    +++ b/README.md
    @@ -1 +1,2 @@
     hi
    +Retry the login twice
    diff --git a/Old.swift b/Old.swift
    deleted file mode 100644
    index 5555555..0000000
    --- a/Old.swift
    +++ /dev/null
    @@ -1 +0,0 @@
    -gone
    """

    private let claude = Author(kind: .session, sessionID: "s1", agent: "claude", request: "Fix the flaky login test")

    func testHunksAreSplitAndGroupedByWhoWroteThem() {
        let hunks = ReviewQueue.hunks(in: diff)
        XCTAssertEqual(hunks.map(\.path), ["Login.swift", "Login.swift", "README.md", "Old.swift"])
        XCTAssertEqual(hunks[0].addedLines, [2])
        XCTAssertEqual(hunks[1].addedLines, [12])
        XCTAssertEqual(hunks[3].removed, 1)

        let owners: [String: [Author?]] = [
            "Login.swift": [nil, claude, nil, nil, nil, nil, nil, nil, nil, nil, nil, .you, nil],
            "README.md": [nil, claude],
        ]
        let queue = ReviewQueue.build(diff: diff) { owners[$0] ?? [] }
        XCTAssertEqual(queue.groups.map(\.title), ["Fix the flaky login test", "Your edits", "Not attributed"])
        XCTAssertEqual(queue.groups[0].paths, ["Login.swift", "README.md"])
        XCTAssertEqual(queue.groups[0].added, 2)
        XCTAssertEqual(queue.groups[1].paths, ["Login.swift"])
        XCTAssertEqual(queue.groups[2].paths, ["Old.swift"], "a hunk that only removes lines isn't attributed")
    }

    /// A group's own diff renders as any diff does: each file's header once, then its hunks.
    func testAGroupIsADiffOfItsOwn() {
        let owners: [String: [Author?]] = ["Login.swift": [nil, claude], "README.md": [nil, claude]]
        let group = ReviewQueue.build(diff: diff) { owners[$0] ?? [] }.groups[0]
        let parsed = UnifiedDiff.parse(group.diffText)
        XCTAssertEqual(parsed.files.map(\.path), ["Login.swift", "README.md"])
        XCTAssertEqual(parsed.files[0].hunks.count, 1, "only the session's hunk of Login.swift")
        XCTAssertEqual(parsed.files[0].addedCount, 1)
        XCTAssertEqual(parsed.files[1].addedCount, 1)
    }

    /// An approval is for a hunk's lines: it holds when other changes move the hunk, and goes
    /// when the hunk itself changes.
    func testAnApprovalFollowsTheHunkNotItsLineNumbers() {
        let moved = diff.replacingOccurrences(of: "@@ -10,2 +11,3 @@", with: "@@ -20,2 +21,3 @@")
        XCTAssertEqual(ReviewQueue.hunks(in: diff)[1].key, ReviewQueue.hunks(in: moved)[1].key)
        let changed = diff.replacingOccurrences(of: "+// typed by hand", with: "+// typed again")
        XCTAssertNotEqual(ReviewQueue.hunks(in: diff)[1].key, ReviewQueue.hunks(in: changed)[1].key)
        XCTAssertNotEqual(ReviewQueue.hunks(in: diff)[0].key, ReviewQueue.hunks(in: diff)[1].key)
    }

    func testApprovalsAreKeptInTheCheckoutsGitDirAndLetGoOfWhenTheHunkIsGone() throws {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("approvals-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        XCTAssertTrue(GitPaths.runGitRaw(["init", "-q"], cwd: repo.path).success)
        let keys = ReviewQueue.hunks(in: diff).map(\.key)
        ReviewApprovals.shared.set([keys[0], keys[2]], approved: true, in: repo)
        XCTAssertEqual(ReviewApprovals.shared.approved(in: repo), [keys[0], keys[2]])
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.appendingPathComponent(".git/side/review.json").path))
        ReviewApprovals.shared.set([keys[0]], approved: false, in: repo)
        XCTAssertEqual(ReviewApprovals.shared.approved(in: repo), [keys[2]])
        ReviewApprovals.shared.keep(only: [keys[0], keys[1]], in: repo)
        XCTAssertEqual(ReviewApprovals.shared.approved(in: repo), [], "the approved hunk is gone, so is its approval")
    }

    // MARK: Slice 3: commit what was approved, discard what wasn't wanted

    private func makeRepo() throws -> URL {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("review-git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        for arguments in [["init", "-q", "-b", "main"], ["add", "-A"], ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init"]] {
            XCTAssertTrue(GitPaths.runGitRaw(arguments, cwd: repo.path).success)
        }
        _ = GitPaths.runGitRaw(["config", "user.email", "t@t"], cwd: repo.path)
        _ = GitPaths.runGitRaw(["config", "user.name", "t"], cwd: repo.path)
        return repo
    }

    func testCommitApprovedTakesOnlyTheApprovedHunks() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "ONE\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nTEN\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "new\n".write(to: repo.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let hunks = ReviewQueue.hunks(in: ReviewWorkspaceViewController.uncommittedDiff(cwd: repo.path) ?? "")
        XCTAssertEqual(hunks.map(\.path), ["a.txt", "a.txt", "b.txt"])
        // The first line's change and the new file, not the last line's.
        let result = ReviewGit.commit([hunks[0], hunks[2]], message: "Fix the counting", cwd: repo.path)
        guard case .success = result else { return XCTFail("\(result)") }
        XCTAssertEqual(GitPaths.runGit(["log", "-1", "--format=%s"], cwd: repo.path).output, "Fix the counting")
        XCTAssertEqual(GitPaths.runGit(["show", "HEAD:a.txt"], cwd: repo.path).output.split(separator: "\n").first, "ONE")
        XCTAssertEqual(GitPaths.runGit(["show", "HEAD:a.txt"], cwd: repo.path).output.split(separator: "\n").last, "ten", "the unapproved hunk isn't in it")
        XCTAssertEqual(GitPaths.runGit(["show", "HEAD:b.txt"], cwd: repo.path).output, "new")
        // Left as it was: the unapproved change, still in the working tree, nothing staged.
        XCTAssertEqual(GitPaths.runGit(["status", "--porcelain"], cwd: repo.path).output, "M a.txt")
        XCTAssertEqual(try String(contentsOf: repo.appendingPathComponent("a.txt"), encoding: .utf8).split(separator: "\n").last, "TEN")
    }

    func testCommitIsRefusedWhenSomethingElseIsStaged() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "ONE\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "staged\n".write(to: repo.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)
        _ = GitPaths.runGitRaw(["add", "c.txt"], cwd: repo.path)
        let hunk = ReviewQueue.hunks(in: GitPaths.runGitRaw(["diff", "--no-color"], cwd: repo.path).output)[0]
        XCTAssertEqual(ReviewGit.commit([hunk], message: "x", cwd: repo.path), .failure(.otherChangesStaged(["c.txt"])))
        XCTAssertEqual(GitPaths.runGit(["rev-list", "--count", "HEAD"], cwd: repo.path).output, "1", "nothing committed")
    }

    func testDiscardTakesASessionsChangesOutUnlessOthersBuiltOnThem() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let claude = Author(kind: .session, sessionID: "s1", agent: "claude", request: "x")
        try "ONE\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let hunk = ReviewQueue.hunks(in: GitPaths.runGitRaw(["diff", "--no-color"], cwd: repo.path).output)[0]
        // Someone else's line inside it: refused, and nothing changes.
        guard case .failure(let failure) = ReviewGit.discard([hunk], author: claude, owners: { _ in [.you] }, cwd: repo.path) else { return XCTFail("discarded someone else's line") }
        XCTAssertEqual(failure, .othersBuildOnIt(["You"]))
        XCTAssertTrue(try String(contentsOf: repo.appendingPathComponent("a.txt"), encoding: .utf8).hasPrefix("ONE"))
        // All the session's own: gone, as if never written.
        guard case .success = ReviewGit.discard([hunk], author: claude, owners: { _ in [claude] }, cwd: repo.path) else { return XCTFail() }
        XCTAssertEqual(GitPaths.runGit(["status", "--porcelain"], cwd: repo.path).output, "")
    }

    func testTheCommitMessageIsDraftedFromTheRequest() {
        let group = ReviewQueue.Group(author: Author(kind: .session, sessionID: "s", agent: "claude", request: "fix the flaky login test"), hunks: [])
        XCTAssertEqual(ReviewGit.draftMessage(for: group), "Fix the flaky login test")
        XCTAssertEqual(ReviewGit.draftMessage(for: ReviewQueue.Group(author: .you, hunks: [])), "", "your own edits: yours to describe")
    }
}
