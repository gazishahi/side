import XCTest
@testable import Side

/// The launch probe. Its bugs are invisible (a stale branch name) until they aren't (opening the
/// wrong state directory), so the cases below pin the correctness rules the speed depends on.
final class GitLaunchProbeTests: XCTestCase {
    private var root: URL!

    private var savedDefaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        savedDefaults = GitLaunchProbe.defaults
        GitLaunchProbe.defaults = UserDefaults(suiteName: "side-tests-\(UUID().uuidString)")!
        root = FileManager.default.temporaryDirectory.appendingPathComponent("probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        GitLaunchProbe.defaults = savedDefaults
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func git(_ args: [String]) {
        XCTAssertTrue(GitPaths.runGit(args, cwd: root.path).success, args.joined(separator: " "))
    }

    private func makeRepo(branch: String = "main") {
        git(["init", "-b", branch])
        git(["config", "user.email", "t@t"])
        git(["config", "user.name", "T"])
        try? "hi".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        git(["add", "."])
        git(["commit", "-m", "first"])
    }

    func testAPlainFolderIsNotARepository() {
        let probe = GitLaunchProbe.probe(projectRoot: root)
        XCTAssertFalse(probe.isRepository)
        XCTAssertNil(probe.commonGitDir)
    }

    func testResolvesGitDirBranchAndDefaultInOnePass() {
        makeRepo()
        let probe = GitLaunchProbe.probe(projectRoot: root)
        XCTAssertTrue(probe.isRepository)
        XCTAssertEqual(probe.currentBranch, "main")
        XCTAssertEqual(probe.defaultBranch, "main")
        // The state directory derives from this; getting it wrong opens the wrong ledger.
        XCTAssertTrue(probe.commonGitDir?.hasSuffix(".git") == true, probe.commonGitDir ?? "nil")
    }

    func testMasterIsRecognizedAsTheDefault() {
        makeRepo(branch: "master")
        XCTAssertEqual(GitLaunchProbe.probe(projectRoot: root).defaultBranch, "master")
    }

    func testTheCheckedOutBranchDoesNotBecomeTheDefault() {
        // The precedence that matters: sitting on a feature branch must not make that branch
        // look like the trunk, or every promote would target the wrong base.
        makeRepo()
        git(["checkout", "-b", "feature-x"])
        let probe = GitLaunchProbe.probe(projectRoot: root)
        XCTAssertEqual(probe.currentBranch, "feature-x")
        XCTAssertEqual(probe.defaultBranch, "main")
    }

    func testDetachedHeadHasNoCurrentBranch() {
        makeRepo()
        let sha = GitPaths.runGit(["rev-parse", "HEAD"], cwd: root.path).output
        git(["checkout", "--detach", sha])
        let probe = GitLaunchProbe.probe(projectRoot: root)
        XCTAssertTrue(probe.isRepository)
        // `--abbrev-ref HEAD` prints the literal string "HEAD" when detached, which is not a
        // branch and must not be treated as one.
        XCTAssertNil(probe.currentBranch)
    }

    func testARepoWithNoCommitsStillResolves() {
        git(["init", "-b", "main"])
        let probe = GitLaunchProbe.probe(projectRoot: root)
        XCTAssertTrue(probe.isRepository)
        // show-ref can't see refs/heads/main before the first commit; HEAD still says where it
        // points, which is why that fallback exists.
        XCTAssertEqual(probe.defaultBranch, "main")
    }

    // TrackStore is @MainActor — it is the view-model half of the split, so a test that
    // constructs one says where it runs.
    @MainActor
    func testTheProbeAgreesWithTheHelpersItReplaced() {
        // The whole optimization rests on this: one spawn must produce what six did.
        makeRepo()
        let probe = GitLaunchProbe.probe(projectRoot: root)
        XCTAssertEqual(probe.commonGitDir, GitPaths.commonGitDir(for: root)?.path)
        let store = TrackStore(projectRoot: root, stateDirectory: root.appendingPathComponent(".git/side"))
        XCTAssertEqual(probe.defaultBranch, store.defaultBranchName())
    }

    // MARK: - Cache

    func testCacheRoundTrips() {
        makeRepo()
        let probe = GitLaunchProbe.probe(projectRoot: root)
        GitLaunchProbe.cache(probe, projectRoot: root)
        XCTAssertEqual(GitLaunchProbe.cached(projectRoot: root), probe)
    }

    func testAnUncachedProjectReportsNothingRatherThanGuessing() {
        XCTAssertNil(GitLaunchProbe.cached(projectRoot: root))
    }

    func testAFullCacheNeverEvictsTheEntryBeingWritten() {
        makeRepo()
        let probe = GitLaunchProbe.probe(projectRoot: root)
        // Fill well past the cap with paths that sort *after* this test's own, which is what made
        // alphabetical eviction drop the fresh entry instead of the stale ones.
        for index in 0..<40 {
            GitLaunchProbe.cache(probe, projectRoot: URL(fileURLWithPath: "/tmp/zzz-filler-\(index)"))
        }
        GitLaunchProbe.cache(probe, projectRoot: root)
        XCTAssertEqual(GitLaunchProbe.cached(projectRoot: root), probe)
    }

    func testTheCacheStaysBounded() {
        makeRepo()
        let probe = GitLaunchProbe.probe(projectRoot: root)
        var survivors = 0
        let paths = (0..<40).map { URL(fileURLWithPath: "/tmp/bounded-\(UUID().uuidString)-\($0)") }
        for path in paths { GitLaunchProbe.cache(probe, projectRoot: path) }
        for path in paths where GitLaunchProbe.cached(projectRoot: path) != nil { survivors += 1 }
        // Unbounded growth in UserDefaults is the failure the cap exists to prevent; the newest
        // writes are the ones that must survive it.
        XCTAssertLessThanOrEqual(survivors, 24)
        XCTAssertNotNil(GitLaunchProbe.cached(projectRoot: paths[paths.count - 1]))
    }
}
