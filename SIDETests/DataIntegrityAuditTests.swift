import XCTest
@testable import Side
@testable import Heron

/// The git/persistence data-integrity cluster from the 2026-09-01 audit (H3–H6). Each of these
/// was a path where Side lost work or reported success for something that had not happened.
final class DataIntegrityAuditTests: XCTestCase {
    private var root: URL!

    /// A completion handler is `@Sendable`; a captured `var` isn't. The box is the usual answer.
    private final class Captured<Value>: @unchecked Sendable { var value: Value? }

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("integrity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        // Worktrees live outside the repo, under Application Support — prune them too.
        _ = GitPaths.runGit(["worktree", "prune"], cwd: root.path)
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    @discardableResult
    private func git(_ args: [String], cwd: URL? = nil) -> String {
        let result = GitPaths.runGit(args, cwd: (cwd ?? root).path)
        XCTAssertTrue(result.success, "git \(args.joined(separator: " ")): \(result.output)")
        return result.output
    }

    private func makeRepo() {
        git(["init", "-b", "main"])
        git(["config", "user.email", "t@t"])
        git(["config", "user.name", "T"])
        try? "hi".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        git(["add", "."])
        git(["commit", "-q", "-m", "first"])
    }

    // MARK: - H4: promote refuses a detached merge root

    func testPromoteRefusesWhenTheMergeRootIsDetached() {
        makeRepo()
        git(["checkout", "-q", "-b", "feature"])
        try? "feature".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        git(["add", "."])
        git(["commit", "-q", "-m", "feature work"])
        let mainBefore = git(["rev-parse", "main"])
        // Detach the merge root: the user is inspecting an old commit.
        git(["checkout", "-q", "--detach", "main"])

        let outcome = ReviewWorkspaceViewController.performMerge(branchName: "feature", baseRef: "main", intent: "", cwd: root.path)
        XCTAssertFalse(outcome.succeeded, outcome.message)
        XCTAssertTrue(outcome.message.contains("detached"), outcome.message)
        // The one thing that must be true: main did not move, and nothing claimed it did.
        XCTAssertEqual(git(["rev-parse", "main"]), mainBefore)
    }

    func testPromoteStillWorksFromABranch() {
        makeRepo()
        git(["checkout", "-q", "-b", "feature"])
        try? "feature".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        git(["add", "."])
        git(["commit", "-q", "-m", "feature work"])
        git(["checkout", "-q", "main"])
        let outcome = ReviewWorkspaceViewController.performMerge(branchName: "feature", baseRef: "main", intent: "did it", cwd: root.path)
        XCTAssertTrue(outcome.succeeded, outcome.message)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("b.txt").path))
    }

    // MARK: - 2026-09-30 audit, H10: a first track in a repository with no commits

    @MainActor
    func testAFirstTrackInAnUnbornRepositoryIsExplainedThenWorksAfterTheInitialCommit() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertTrue(GitPaths.runGit(["init", "-q"], cwd: root.path).success)
        let store = TrackStore(projectRoot: root, stateDirectory: root.appendingPathComponent(".git/side"))
        let refused = expectation(description: "refused")
        store.createTrack(intent: "first work") { result in
            if case .failure(TrackStore.TrackError.repositoryHasNoCommits) = result {} else { XCTFail("expected repositoryHasNoCommits, got \(result)") }
            refused.fulfill()
        }
        wait(for: [refused], timeout: 20)

        let committed = expectation(description: "initial commit")
        store.makeInitialCommit { result in
            if case .failure(let error) = result { XCTFail("\(error)") }
            committed.fulfill()
        }
        wait(for: [committed], timeout: 20)
        XCTAssertEqual(GitPaths.runGit(["ls-tree", "-r", "--name-only", "HEAD"], cwd: root.path).output, "", "empty: none of the folder's files")

        let created = expectation(description: "created")
        store.createTrack(intent: "first work") { result in
            if case .failure(let error) = result { XCTFail("\(error)") }
            created.fulfill()
        }
        wait(for: [created], timeout: 20)
        XCTAssertEqual(store.tracks.count, 1)
    }

    @MainActor
    func testInitializeGitLeavesARepositoryATrackCanBranchFrom() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = TrackStore(projectRoot: root, stateDirectory: root.appendingPathComponent(".side-state"))
        let done = expectation(description: "init")
        store.initializeGitRepo { result in
            if case .failure(let error) = result { XCTFail("\(error)") }
            done.fulfill()
        }
        wait(for: [done], timeout: 20)
        XCTAssertTrue(GitPaths.runGit(["rev-parse", "--verify", "-q", "HEAD"], cwd: root.path).success)
    }

    // MARK: - H5: deleting a track with uncommitted work needs consent

    @MainActor
    func testDeletingATrackWithUncommittedWorkIsRefusedUntilConsented() throws {
        makeRepo()
        let store = TrackStore(projectRoot: root, stateDirectory: root.appendingPathComponent(".git/side"))
        let created = expectation(description: "create")
        let captured = Captured<Track>()
        let failure = Captured<String>()
        store.createTrack(intent: "risky work") { result in
            switch result {
            case .success(let made): captured.value = made.0
            case .failure(let error): failure.value = "\(error)"
            }
            created.fulfill()
        }
        wait(for: [created], timeout: 20)
        guard let track = captured.value, let worktree = track.workingDirectoryPath else { return XCTFail("no worktree: \(failure.value ?? "no error")") }

        // The agent's un-checkpointed edit.
        try "unsaved".write(to: URL(fileURLWithPath: worktree).appendingPathComponent("wip.txt"), atomically: true, encoding: .utf8)
        store.setStatus(.parked, for: track)
        // The store's copy, not the one captured at creation — `Track` is a value type and the
        // status change lives in the store, which is what the Tracks menu hands to delete.
        guard let parked = store.tracks.first(where: { $0.id == track.id }) else { return XCTFail("track vanished") }

        let refused = expectation(description: "refused")
        store.deleteTrack(parked, alsoDeleteBranch: false) { result in
            if case .failure(let error as TrackStore.TrackError) = result, case .worktreeHasUncommittedChanges(let count) = error {
                XCTAssertEqual(count, 1)
            } else {
                XCTFail("expected refusal, got \(result)")
            }
            refused.fulfill()
        }
        wait(for: [refused], timeout: 20)
        // Refused means untouched: the file and the track are both still there.
        XCTAssertTrue(FileManager.default.fileExists(atPath: (worktree as NSString).appendingPathComponent("wip.txt")))
        XCTAssertTrue(store.tracks.contains { $0.id == track.id })

        let deleted = expectation(description: "deleted")
        store.deleteTrack(parked, alsoDeleteBranch: false, discardUncommittedChanges: true) { result in
            if case .failure(let error) = result { XCTFail("\(error)") }
            deleted.fulfill()
        }
        wait(for: [deleted], timeout: 20)
        XCTAssertFalse(store.tracks.contains { $0.id == track.id })
    }

    @MainActor
    func testDeletingACleanTrackNeedsNoConsent() throws {
        makeRepo()
        let store = TrackStore(projectRoot: root, stateDirectory: root.appendingPathComponent(".git/side"))
        let created = expectation(description: "create")
        let captured = Captured<Track>()
        let failure = Captured<String>()
        store.createTrack(intent: "clean work") { result in
            switch result {
            case .success(let made): captured.value = made.0
            case .failure(let error): failure.value = "\(error)"
            }
            created.fulfill()
        }
        wait(for: [created], timeout: 20)
        guard let track = captured.value else { return XCTFail("no track: \(failure.value ?? "no error")") }
        store.setStatus(.parked, for: track)
        guard let parked = store.tracks.first(where: { $0.id == track.id }) else { return XCTFail("track vanished") }
        let deleted = expectation(description: "deleted")
        store.deleteTrack(parked, alsoDeleteBranch: true) { result in
            if case .failure(let error) = result { XCTFail("\(error)") }
            deleted.fulfill()
        }
        wait(for: [deleted], timeout: 20)
        XCTAssertFalse(store.tracks.contains { $0.id == track.id })
    }

    // MARK: - H6: an adopted worktree does not follow the banner to a different branch

    @MainActor
    func testTurningADifferentBranchIntoATrackDoesNotInheritAnotherBranchesWorktree() throws {
        makeRepo()
        git(["branch", "alpha"])
        git(["branch", "beta"])
        let store = TrackStore(projectRoot: root, stateDirectory: root.appendingPathComponent(".git/side"))

        // Adopt alpha: this materializes alpha's worktree and remembers its path.
        let adopted = expectation(description: "adopt")
        store.switchToExistingBranch("alpha") { _ in adopted.fulfill() }
        wait(for: [adopted], timeout: 20)
        XCTAssertEqual(store.untrackedBranch, "alpha")

        // The user moves the main tree to beta behind Side's back, and Side notices.
        git(["checkout", "-q", "beta"])
        store.reconcile()
        let settled = expectation(description: "reconciled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { settled.fulfill() }
        wait(for: [settled], timeout: 5)
        XCTAssertEqual(store.untrackedBranch, "beta")

        let promoted = expectation(description: "promote")
        let captured = Captured<Track>()
        store.promoteCurrentBranch(intent: "beta work") { result in
            if case .success(let made) = result { captured.value = made }
            promoted.fulfill()
        }
        wait(for: [promoted], timeout: 5)
        guard let track = captured.value else { return XCTFail("no track") }
        XCTAssertEqual(track.branchName, "beta")
        // Either no worktree (it will be materialized on demand) or one that is actually on
        // beta — never alpha's.
        if let path = track.workingDirectoryPath {
            let onBranch = GitPaths.runGit(["symbolic-ref", "--short", "HEAD"], cwd: path).output
            XCTAssertEqual(onBranch, "beta", "track beta is bound to a worktree on \(onBranch)")
        }
    }
}
