import XCTest
@testable import Side
@testable import SideAgents

/// The launch probe. Its bugs are invisible (a stale branch name) until they aren't (opening the
/// wrong state directory), so the cases below pin the correctness rules the speed depends on.
final class GitLaunchProbeTests: XCTestCase {
    private var root: URL!

    private var savedDefaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        savedDefaults = GitLaunchProbe.defaults
        GitLaunchProbe.defaults = throwawayDefaults()
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

    func testDefaultBranchResolution() {
        // Three rules, one repo. Before the first commit show-ref can't see refs/heads/master;
        // HEAD still says where it points, which is why that fallback exists. `master` is
        // recognized as a default alongside `main`. And the precedence that matters: sitting on a
        // feature branch must not make that branch look like the trunk, or every promote would
        // target the wrong base.
        git(["init", "-b", "master"])
        var probe = GitLaunchProbe.probe(projectRoot: root)
        XCTAssertTrue(probe.isRepository)
        XCTAssertEqual(probe.defaultBranch, "master", "a repo with no commits should still resolve")

        git(["config", "user.email", "t@t"])
        git(["config", "user.name", "T"])
        try? "hi".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        git(["add", "."])
        git(["commit", "-m", "first"])
        probe = GitLaunchProbe.probe(projectRoot: root)
        XCTAssertEqual(probe.currentBranch, "master")
        XCTAssertEqual(probe.defaultBranch, "master")

        git(["checkout", "-b", "feature-x"])
        probe = GitLaunchProbe.probe(projectRoot: root)
        XCTAssertEqual(probe.currentBranch, "feature-x")
        XCTAssertEqual(probe.defaultBranch, "master", "the checked-out branch must not become the default")
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

    func testProbeCache() {
        // An uncached project reports nothing rather than guessing; a cached probe round-trips;
        // a full cache never evicts the entry being written (filling with paths that sort *after*
        // this test's own is what made alphabetical eviction drop the fresh entry instead of the
        // stale ones); and the cache stays bounded — unbounded growth in UserDefaults is the
        // failure the cap exists to prevent, and the newest writes are the ones that must survive.
        XCTAssertNil(GitLaunchProbe.cached(projectRoot: root))

        makeRepo()
        let probe = GitLaunchProbe.probe(projectRoot: root)
        GitLaunchProbe.cache(probe, projectRoot: root)
        XCTAssertEqual(GitLaunchProbe.cached(projectRoot: root), probe)

        for index in 0..<40 {
            GitLaunchProbe.cache(probe, projectRoot: URL(fileURLWithPath: "/tmp/zzz-filler-\(index)"))
        }
        GitLaunchProbe.cache(probe, projectRoot: root)
        XCTAssertEqual(GitLaunchProbe.cached(projectRoot: root), probe, "a full cache evicted the entry being written")

        let paths = (0..<40).map { URL(fileURLWithPath: "/tmp/bounded-\(UUID().uuidString)-\($0)") }
        for path in paths { GitLaunchProbe.cache(probe, projectRoot: path) }
        let survivors = paths.filter { GitLaunchProbe.cached(projectRoot: $0) != nil }.count
        XCTAssertLessThanOrEqual(survivors, 24)
        XCTAssertNotNil(GitLaunchProbe.cached(projectRoot: paths[paths.count - 1]))
    }
}
