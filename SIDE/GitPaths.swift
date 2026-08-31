import Foundation
import CryptoKit

/// Resolves the handful of filesystem facts Phase C's worktrees depend on. The load-bearing
/// detail behind all of it: inside a linked worktree, `.git` is a *file* containing `gitdir: …`,
/// not a directory, so a naive `projectRoot.appendingPathComponent(".git/side")` would fragment
/// per-track state depending on which worktree happened to open the project — a track's own
/// worktree would see an *empty* ledger the first time anything read `tracks.json` from inside
/// it. Every path here is resolved through git itself rather than assumed from string shape.
enum GitPaths {
    /// The one directory every worktree of a repository agrees on — resolved via
    /// `--git-common-dir`, not `--git-dir` (which returns the *calling* worktree's own private
    /// git dir, a subdirectory of the common one). `nil` for a plain folder that isn't a git
    /// repo at all, or before the first commit in some edge cases `rev-parse` can't resolve.
    static func commonGitDir(for projectRoot: URL) -> URL? {
        let result = runGit(["rev-parse", "--path-format=absolute", "--git-common-dir"], cwd: projectRoot.path)
        guard result.success, !result.output.isEmpty else { return nil }
        return URL(fileURLWithPath: result.output).standardizedFileURL
    }

    /// Where `TrackStore`/`AgentSessionStore` persist — `<common-git-dir>/side`. Opening the
    /// main checkout or any of its linked worktrees resolves to the exact same directory, which
    /// is what lets two windows on the same repo (one via the root, one via a worktree) share
    /// one ledger instead of each seeing a different, fragmented one.
    static func stateDirectory(for projectRoot: URL) -> URL? {
        commonGitDir(for: projectRoot)?.appendingPathComponent("side")
    }

    /// A stable identity for this repository, independent of which worktree (if any) was used
    /// to open it — the common git dir's own resolved path. Two separate clones of the same
    /// repo still get different identities (genuinely different `.git` directories on disk),
    /// which is correct: they really are two independent working copies, not "the same project."
    static func projectIdentity(for projectRoot: URL) -> String? {
        commonGitDir(for: projectRoot)?.resolvingSymlinksInPath().path
    }

    /// Where a track's linked worktree lives on disk — deliberately outside the repo entirely.
    /// `ProjectFileAccess.scan` only excludes a fixed list (`.git`, `node_modules`, `.build`,
    /// etc.), not arbitrary in-repo directories, so an in-repo location would silently multiply
    /// quick-open, search, and the file explorer by however many tracks exist. Keyed by a hash
    /// of the *common git dir* (not the project's display name), so a track's worktree location
    /// survives the user renaming or moving the repo folder.
    static func worktreesRootDirectory(for projectRoot: URL) -> URL? {
        guard let identity = projectIdentity(for: projectRoot) else { return nil }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Side/Worktrees/\(projectRoot.lastPathComponent)-\(stableHash(identity))")
    }

    static func worktreePath(forBranchSlug slug: String, projectRoot: URL) -> URL? {
        worktreesRootDirectory(for: projectRoot)?.appendingPathComponent(slug)
    }

    /// Short, filesystem-safe, and — critically — stable across process launches. `Hasher` is
    /// deliberately *not* used here: Swift randomizes its seed per process for hash-flooding
    /// protection, which would relocate every track's worktree to a new path on every relaunch.
    private static func stableHash(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// `extraEnvironment` exists for `GIT_INDEX_FILE` — the only safe way to stage a commit
    /// without touching whatever the user already has staged in the repository's real index
    /// (see `AgentRunner.createCheckpointIfNeeded`).
    @discardableResult
    static func runGit(_ args: [String], cwd: String, extraEnvironment: [String: String] = [:]) -> (success: Bool, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        if !extraEnvironment.isEmpty {
            var environment = ProcessInfo.processInfo.environment
            for (key, value) in extraEnvironment { environment[key] = value }
            process.environment = environment
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (false, error.localizedDescription) }
        // Read *before* waiting. `waitUntilExit()` first is a deadlock: once git fills the
        // ~64KB pipe buffer it blocks writing, while we block waiting for it to exit, and
        // neither side ever moves. Reproduced against a 175KB blob — `git show` of any large
        // file, or a diff over ~64KB, hung the app until Force Quit.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (process.terminationStatus == 0, output)
    }

    /// Like `runGit`, but returns git's output **verbatim**.
    ///
    /// `runGit` trims whitespace, which is right for `rev-parse` and wrong — silently and
    /// destructively — for `status --porcelain`, whose first two columns *are* the status and
    /// whose first column is a space for a worktree-modified file. Trimming ate that space, so
    /// ` M src/mathUtils.ts` became `M src/mathUtils.ts` and the 3-character prefix drop then
    /// produced `rc/mathUtils.ts`: a path git had never heard of.
    ///
    /// Only the *first* entry was affected, which is why this hid for so long — checkpointing
    /// worked whenever the first dirty file happened to be staged or untracked, and failed
    /// whenever it was merely modified. Before checkpoint failures were reported honestly, that
    /// failure printed as "✓ Checkpoint (no file changes)".
    static func runGitRaw(_ args: [String], cwd: String) -> (success: Bool, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let pipe = Pipe()
        process.standardOutput = pipe
        // stderr goes nowhere: merging it would corrupt a format parsed by position.
        process.standardError = Pipe()
        do { try process.run() } catch { return (false, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus == 0, String(data: data, encoding: .utf8) ?? "")
    }

    /// Every path git considers dirty (staged, unstaged, or untracked) relative to `cwd`'s repo
    /// root — used to snapshot a worktree's state before/after a batch of agent actions, so a
    /// checkpoint can stage only what actually changed *during* the batch instead of everything
    /// sitting in the tree (which would misattribute a concurrent manual edit to the agent).
    static func dirtyPaths(cwd: String) -> Set<String> {
        // `-z` for two independent reasons, both of which silently broke checkpoints: git
        // *quotes* any path with non-ASCII or unusual bytes by default (`"caf\303\251.txt"`),
        // and those quotes were passed straight into `git add`, which then matched nothing —
        // so a single accented filename anywhere in the tree made every checkpoint commit
        // fail. `-z` also uses NUL separators, so a filename containing a newline can't split
        // one entry into two.
        // `runGitRaw`, not `runGit`: this format's leading column is significant. See above.
        let result = runGitRaw(["status", "--porcelain", "-z"], cwd: cwd)
        guard result.success, !result.output.isEmpty else { return [] }
        // With -z a rename is two NUL-separated fields (`R  new\0old`) rather than
        // `old -> new`, so the arrow form no longer appears at all.
        var paths: Set<String> = []
        var entries = result.output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        while !entries.isEmpty {
            let entry = entries.removeFirst()
            guard entry.count > 3 else { continue }
            let status = entry.prefix(2)
            paths.insert(String(entry.dropFirst(3)))
            // A rename/copy consumes the following field (the source path); it isn't dirty in
            // its own right, and leaving it in the stream would stage a path that no longer
            // exists.
            if status.hasPrefix("R") || status.hasPrefix("C") { _ = entries.isEmpty ? nil : entries.removeFirst() }
        }
        return paths
    }
}
