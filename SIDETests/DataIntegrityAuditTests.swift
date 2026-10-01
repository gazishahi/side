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
            if case .failure(let error as TrackStore.TrackError) = result, case .worktreeHasUncommittedChanges(let risk) = error {
                XCTAssertEqual(risk, TrackStore.WorkAtRisk(uncommitted: 1))
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

    // MARK: - 2026-09-30 audit, R5: ignored files go with a worktree, so they're asked about

    /// A parked track whose worktree holds only a gitignored `.env`: Delete and Remove Working
    /// Copy both deleted it unasked (git removes ignored files with or without `--force`, and
    /// re-creating the worktree doesn't bring them back).
    @MainActor
    func testAnIgnoredFileInAWorktreeIsAskedAboutBeforeItsDeleted() throws {
        makeRepo()
        try ".env\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        git(["add", ".gitignore"])
        git(["commit", "-q", "-m", "ignore .env"])
        let store = TrackStore(projectRoot: root, stateDirectory: root.appendingPathComponent(".git/side"))
        let created = expectation(description: "create")
        let captured = Captured<Track>()
        store.createTrack(intent: "has secrets") { result in
            if case .success(let made) = result { captured.value = made.0 }
            created.fulfill()
        }
        wait(for: [created], timeout: 20)
        guard let track = captured.value, let worktree = track.workingDirectoryPath else { return XCTFail("no worktree") }
        let secret = (worktree as NSString).appendingPathComponent(".env")
        try "API_KEY=1".write(toFile: secret, atomically: true, encoding: .utf8)
        store.setStatus(.parked, for: track)
        guard let parked = store.tracks.first(where: { $0.id == track.id }) else { return XCTFail("track vanished") }

        for remove in [false, true] {
            let refused = expectation(description: remove ? "remove refused" : "delete refused")
            let handler: @Sendable (Result<Void, Error>) -> Void = { result in
                if case .failure(let error as TrackStore.TrackError) = result, case .worktreeHasUncommittedChanges(let risk) = error {
                    XCTAssertEqual(risk, TrackStore.WorkAtRisk(ignored: [".env"]))
                } else {
                    XCTFail("expected a question, got \(result)")
                }
                refused.fulfill()
            }
            if remove { store.removeWorkingCopy(for: parked, completion: handler) } else { store.deleteTrack(parked, alsoDeleteBranch: false, completion: handler) }
            wait(for: [refused], timeout: 20)
            XCTAssertTrue(FileManager.default.fileExists(atPath: secret), "the .env was deleted unasked")
        }

        let removed = expectation(description: "removed")
        store.removeWorkingCopy(for: parked, discardIgnoredFiles: true) { result in
            if case .failure(let error) = result { XCTFail("\(error)") }
            removed.fulfill()
        }
        wait(for: [removed], timeout: 20)
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree))
    }

    // MARK: - 2026-09-30 audit, H14: a stacked track whose parent was deleted

    /// With its parent gone, a stacked track's base fell back to main and Promote merged the
    /// deleted parent's commits into main without a word. Now Promote says how many aren't
    /// this track's own (and defaults to Cancel).
    @MainActor
    func testPromotingATrackWhoseParentWasDeletedSaysWhatElseItCarries() throws {
        makeRepo()
        let store = TrackStore(projectRoot: root, stateDirectory: root.appendingPathComponent(".git/side"))
        func create(_ intent: String, on base: Track?) -> Track? {
            let done = expectation(description: intent)
            let made = Captured<Track>()
            store.createTrack(intent: intent, baseTrack: base) { result in
                if case .success(let pair) = result { made.value = pair.0 }
                done.fulfill()
            }
            wait(for: [done], timeout: 20)
            return made.value
        }
        func commit(_ file: String, in track: Track) -> String {
            let path = track.workingDirectoryPath ?? root.path
            try? file.write(toFile: (path as NSString).appendingPathComponent(file), atomically: true, encoding: .utf8)
            XCTAssertTrue(GitPaths.runGit(["add", file], cwd: path).success)
            XCTAssertTrue(GitPaths.runGit(["-c", "user.email=t@t", "-c", "user.name=T", "commit", "-q", "-m", file], cwd: path).success)
            return GitPaths.runGit(["rev-parse", "HEAD"], cwd: path).output
        }
        guard let parent = create("parent work", on: nil) else { return XCTFail("no parent") }
        _ = commit("parent.txt", in: parent)
        store.setStatus(.parked, for: parent)
        guard let parked = store.tracks.first(where: { $0.id == parent.id }),
              let child = create("child work", on: parked) else { return XCTFail("no child") }
        let own = commit("child.txt", in: child)
        let checkpoint = Checkpoint(trackKey: child.branchName, agentSessionId: UUID(), declaredIntent: "child", changedFilePaths: ["child.txt"], commandsRun: [],
                                    provenance: AgentProvenance(providerId: "p", modelId: "m", instructionSourceSummary: ""), gitCommitSHA: own)
        XCTAssertNil(ReviewWorkspaceViewController.orphanedStackNote(for: child, trackStore: store, checkpoints: [checkpoint]), "the parent is still there")

        // The child archived so the parent can go, as the Tracks menu requires, then back.
        store.setStatus(.parked, for: child)
        store.setStatus(.archived, for: child)
        let deleted = expectation(description: "parent deleted")
        guard let parentNow = store.tracks.first(where: { $0.id == parent.id }) else { return XCTFail("parent vanished") }
        store.deleteTrack(parentNow, alsoDeleteBranch: false, discardUncommittedChanges: true) { result in
            if case .failure(let error) = result { XCTFail("\(error)") }
            deleted.fulfill()
        }
        wait(for: [deleted], timeout: 20)
        store.setStatus(.parked, for: child)
        guard let orphan = store.tracks.first(where: { $0.id == child.id }) else { return XCTFail("child vanished") }
        XCTAssertEqual(ReviewWorkspaceViewController.baseRef(for: orphan, trackStore: store), "main")
        let note = ReviewWorkspaceViewController.orphanedStackNote(for: orphan, trackStore: store, checkpoints: [checkpoint])
        XCTAssertTrue(note?.contains("1 of its 2 commits ahead of main") == true, note ?? "no note")
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

/// 2026-09-30 audit, CON-5: every agent phase change refreshed Tracks, running git and `du`
/// for every track, even with Tracks off screen.
@MainActor
final class TracksOffScreenTests: XCTestCase {
    func testAnOffScreenLedgerOnlyMarksItselfStale() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("side-tracks-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for args in [["init", "-q", "-b", "main"], ["commit", "--allow-empty", "-q", "-m", "base"]] { XCTAssertTrue(GitPaths.runGit(args, cwd: root.path).success) }
        let store = TrackStore(projectRoot: root, stateDirectory: root.appendingPathComponent(".git/side"))
        let tracks = TracksWorkspaceViewController()
        tracks.loadViewIfNeeded()
        let sessions = AgentSessionStore(stateDirectory: root.appendingPathComponent(".git/side"))
        let manager = AgentRunnerManager(
            sessionStore: sessions, projectPath: root.path,
            bridgeProvider: { _ in WorkspaceBridge(liveBufferProvider: { _ in nil }, applyEditIntoOpenTab: { _, _ in false }, onRevealFileRequested: { _ in },
                                                   runShellCommand: { _, _, completion in completion("") }, interruptShellCommand: {}) },
            rootProvider: { _ in root }, modeProvider: { _ in AgentMode(scope: .ask, autonomy: .manual) },
            modelSelectionProvider: { _ in (nil, nil, nil) }
        )
        tracks.configure(with: store, runnerManager: manager, sessionStore: sessions)
        for _ in 0..<50 { tracks.refresh() }
        XCTAssertTrue(tracks.ledgerIsStaleForTesting)
        XCTAssertFalse(tracks.isRefreshingGitSummariesForTesting, "no git work for a ledger nobody can see")
    }
}
