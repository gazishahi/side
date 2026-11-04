import Foundation

/// A checkpoint's commit: exactly the paths a turn touched, in a private index, so nothing the
/// person staged rides along (SIDE_RFC_HERON_RETIREMENT.md, step 2: out of `AgentRunner`, which
/// outside agents' checkpoints were calling into). Off the main thread, and free of any state.
public enum CheckpointCommit {
    /// Pure text arithmetic — `nonisolated` so it can be counted off-main and tested directly.
    public nonisolated static func lineDelta(in diffText: String) -> (added: Int, removed: Int) {
        var added = 0, removed = 0
        for line in diffText.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("+"), !line.hasPrefix("+++") { added += 1 }
            else if line.hasPrefix("-"), !line.hasPrefix("---") { removed += 1 }
        }
        return (added, removed)
    }

    /// The git half — safe to run off the main thread, and deliberately free of any `self`
    /// reference so it cannot touch main-actor state from a background queue.
    // Internal so the staging rule — only what the batch touched — can be tested against a repo.
    public nonisolated static func stageAndCommit(
        root: String, baseline: Set<String>?, knownChanged: Set<String>, userSaved: Set<String> = [], message: String
    ) -> CheckpointCommitOutcome? {
        stageAndCommitReporting(root: root, baseline: baseline, knownChanged: knownChanged, userSaved: userSaved, message: message).outcome
    }

    /// `stageAndCommit`, and the batch's submodules whose changes are inside them, uncommitted:
    /// a checkpoint can't hold those, and the person is told (2026-09-30 audit, GIT-6: they got
    /// "✓ Checkpoint … (no file changes)").
    public nonisolated static func stageAndCommitReporting(
        root: String, baseline: Set<String>?, knownChanged: Set<String>, userSaved: Set<String> = [], message: String
    ) -> (outcome: CheckpointCommitOutcome?, uncommittedSubmodules: [String]) {

        // Stage only what this batch actually touched: paths a command left newly dirty (not
        // already dirty before the batch started — that's a concurrent manual edit sitting in
        // the same worktree, not the agent's work) plus every path an approved edit is known for
        // certain to have touched, even if that path happened to already be dirty. Deliberately
        // not `git add -A` — that would sweep any unrelated in-progress change in this worktree
        // into the agent's commit and misattribute it.
        //
        // `userSaved` closes the same hole from the other side: a file that only became dirty
        // because the user saved it in Make while the batch waited (audit F4) is theirs.
        //
        // The real index is read before and after the status, so a copy of it is known to be the
        // index that status described (see `commitPathsInIsolatedIndex`).
        let indexFile = GitPaths.indexFile(worktree: root)
        // Its modification time too, read first: the copy has to carry it (see below).
        let indexModified = indexFile.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date }
        let indexBefore = indexFile.flatMap { try? Data(contentsOf: $0) }
        guard let status = GitPaths.status(cwd: root) else {
            return (.failed(step: "status", message: "git status failed in \(root)"), [])
        }
        let indexAfter = indexFile.flatMap { try? Data(contentsOf: $0) }
        // Without a baseline (git status failed before the batch) nothing newly dirty can be
        // told apart from the person's own work, so only the known edits are committed and a
        // command's changes stay in the working copy.
        let newlyDirty = baseline.map { status.dirty.subtracting($0).subtracting(userSaved) } ?? []
        let pathsToStage = newlyDirty.union(knownChanged)
        // Everything the batch did left the tree exactly as it already was (e.g. a command that
        // ran but touched nothing) — nothing to checkpoint at all.
        guard !pathsToStage.isEmpty else { return (nil, []) }
        let submodules = status.submodulesWithUncommittedWork.intersection(pathsToStage).sorted()
        let realIndex: (url: URL, contents: Data, modified: Date)? = {
            guard let indexFile, let indexBefore, let indexModified, indexBefore == indexAfter, !status.hasStaged else { return nil }
            return (indexFile, indexBefore, indexModified)
        }()
        return (commitPathsInIsolatedIndex(pathsToStage.sorted(), message: message, cwd: root, head: status.head, realIndex: realIndex), submodules)
    }

    /// What to say about a batch's submodule changes that a checkpoint couldn't hold.
    public nonisolated static func uncommittedSubmoduleNote(_ paths: [String]) -> String? {
        guard !paths.isEmpty else { return nil }
        let names = paths.map { "\u{201C}\($0)\u{201D}" }.joined(separator: ", ")
        let one = paths.count == 1
        return "Not in the checkpoint: the changes inside the submodule\(one ? "" : "s") \(names). A checkpoint records a submodule's commit, not files changed inside it, so undoing it won't touch them. Commit them in the submodule to have them checkpointed."
    }

    /// The description a checkpoint is filed under. "no description" is the one thing a durable
    /// record of a change must not be: in Review months later it is the only handle on which
    /// checkpoint this was.
    public nonisolated static func describedIntent(_ declared: String, changedPaths: Set<String>) -> String {
        let trimmed = declared.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty else { return trimmed }
        let names = changedPaths.map { ($0 as NSString).lastPathComponent }.sorted()
        guard let first = names.first else { return "" }
        return names.count == 1
            ? "Edited \(first)"
            : "Edited \(first) and \(names.count - 1) other file\(names.count == 2 ? "" : "s")"
    }

    /// "✓ Checkpoint (sha7): intent", or "(no file changes)" when nothing was committed.
    public static func checkpointMarker(_ checkpoint: Checkpoint) -> String {
        let intent = checkpoint.declaredIntent.isEmpty ? "no description" : checkpoint.declaredIntent
        return checkpoint.gitCommitSHA.map { "✓ Checkpoint (\(String($0.prefix(7)))): \(intent)" } ?? "✓ Checkpoint: \(intent) (no file changes)"
    }

    /// Other git activity in this app (window-subtitle status polling, Tracks' uncommitted-file
    /// counts) can legitimately land at the same instant as a checkpoint's own `git add` — both
    /// sides just want a quick read or a stage, but git's index lock makes even that transient
    /// overlap fail outright with no automatic retry of its own. A short bounded retry absorbs
    /// that instead of surfacing a spurious "checkpoint failed" for what was actually just bad
    /// timing. Caught live, twice: a mixed edit+command batch (the edit's file-reveal triggers a
    /// git-status refresh) reliably reproduced the failure — and a fixed attempt-count retry (3,
    /// then 8, both tried live) still wasn't reliably enough margin, meaning the real contention
    /// window can run longer than a couple seconds (plausible cause: a git-aware shell prompt —
    /// oh-my-zsh's git plugin, starship, powerlevel10k, all common — runs several of its own git
    /// subcommands on every prompt redraw in the very same repo `run_shell_command` just used).
    /// A time-based deadline rather than a fixed attempt count is the more principled fix: keep
    /// retrying for up to `maxWait`, however many attempts that takes, instead of guessing a
    /// count and being wrong about it a second time.
    /// Returns git's own output on failure, not just `false`. Discarding it produced
    /// "couldn't stage 2 paths" — a message that says something went wrong and refuses to say
    /// what, which is precisely the shape this codebase calls out elsewhere as unacceptable.
    @discardableResult
    nonisolated static func runGitWithRetry(_ args: [String], cwd: String, maxWait: TimeInterval = 5, extraEnvironment: [String: String] = [:]) -> (success: Bool, output: String) {
        let deadline = Date().addingTimeInterval(maxWait)
        while true {
            let result = GitPaths.runGit(args, cwd: cwd, extraEnvironment: extraEnvironment)
            if result.success { return (true, result.output) }
            guard Date() < deadline else { return (false, result.output) }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    /// Five git processes in the usual case (D7; it was nine, and 875 ms in a 20,000-file
    /// repository): the status above, `add -v`, `write-tree`, `commit-tree` and `update-ref`.
    /// - `realIndex` is the user's index when nothing is staged in it, and so holds exactly HEAD:
    ///   the private index starts as a copy of it, with its stat information, instead of
    ///   `read-tree HEAD` rebuilding one from the tree. With something staged, `read-tree` it is,
    ///   so their staged work can't ride along.
    /// - `add -v` names what it changed, which is what the commit holds; `diff --cached` is asked
    ///   only when its output isn't that.
    /// - Afterwards the private index goes back in place as the real one, under git's own lock
    ///   and only if nothing wrote the index meanwhile; otherwise `git add` refreshes the paths.
    nonisolated static func commitPathsInIsolatedIndex(
        _ paths: [String], message: String, cwd: String, head: String?, realIndex: (url: URL, contents: Data, modified: Date)?
    ) -> CheckpointCommitOutcome {
        let indexURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("side-checkpoint-index-\(UUID().uuidString)")
        let indexPath = indexURL.path
        let environment = ["GIT_INDEX_FILE": indexPath]
        defer { try? FileManager.default.removeItem(atPath: indexPath) }

        let hasParent = head != nil
        // Seed from HEAD so the commit's baseline is the last commit, never the user's staged
        // state. A repo with no commits yet starts from an empty index instead.
        if let realIndex, hasParent, (try? realIndex.contents.write(to: indexURL)) != nil,
           (try? FileManager.default.setAttributes([.modificationDate: realIndex.modified.addingTimeInterval(-1)], ofItemAtPath: indexPath)) != nil {
            // The user's index, which holds HEAD: nothing is staged in it.
            //
            // With the index's own modification time, or earlier. git trusts an entry whose
            // stat data matches the file unless the entry is no older than the index file
            // ("racily clean"), and a copy written now made every entry older: a file changed
            // in place, to the same size, in the second its index was written, read as
            // unchanged, and the checkpoint missed it or said "nothing to commit" (2026-09-30,
            // CheckpointCostTests; 5 of 5 in a reproduction). Earlier only makes git re-read
            // more files; later would hide changes.
        } else if hasParent {
            let readTree = runGitWithRetry(["read-tree", "HEAD"], cwd: cwd, extraEnvironment: environment)
            guard readTree.success else {
                return .failed(step: "read-tree", message: readTree.output)
            }
        }
        let add = runGitWithRetry(["add", "-v", "--"] + paths, cwd: cwd, extraEnvironment: environment)
        guard add.success else {
            // Naming the paths matters: the failure is almost always about *which* path was
            // asked for, so a count tells the user nothing they can act on.
            return .failed(step: "add", message: "\(add.output) (paths: \(paths.joined(separator: ", ")))")
        }

        var committedPaths: [String]
        if let reported = Self.addedPaths(add.output, asked: Set(paths)) {
            committedPaths = reported
        } else {
            let staged = GitPaths.runGit(["diff", "--cached", "--name-only"] + (hasParent ? ["HEAD"] : []), cwd: cwd, extraEnvironment: environment)
            guard staged.success else {
                return .failed(step: "diff --cached", message: staged.output)
            }
            committedPaths = staged.output.isEmpty ? [] : staged.output.split(separator: "\n").map(String.init)
        }
        guard !committedPaths.isEmpty else { return .nothingToCommit }

        let tree = GitPaths.runGit(["write-tree"], cwd: cwd, extraEnvironment: environment)
        guard tree.success, !tree.output.isEmpty else {
            return .failed(step: "write-tree", message: tree.output)
        }
        var commitArgs = ["commit-tree", tree.output, "-m", message]
        if let head { commitArgs += ["-p", head] }
        let commit = GitPaths.runGit(commitArgs, cwd: cwd, extraEnvironment: environment)
        guard commit.success, !commit.output.isEmpty else {
            return .failed(step: "commit-tree", message: commit.output)
        }
        // `update-ref` with the expected old value: HEAD was read with the status and is the
        // new commit's parent, so if anything committed in between — the user typing
        // `git commit` in the Run terminal, which shares this worktree — moving HEAD
        // unconditionally would orphan their commit. Git refuses the swap instead.
        var updateArgs = ["update-ref", "HEAD", commit.output]
        if let head { updateArgs.append(head) }
        let update = GitPaths.runGit(updateArgs, cwd: cwd)
        guard update.success else {
            return .failed(step: "update-ref", message: update.output.isEmpty
                ? "the branch moved while the checkpoint was being written"
                : update.output)
        }

        // The real index should read these paths as committed rather than as modified. The
        // private index is exactly that when it began as the real one; otherwise, or if the real
        // one changed meanwhile, `git add` refreshes just these paths (unrelated staged entries
        // stay staged).
        if let realIndex, let updated = try? Data(contentsOf: indexURL),
           GitPaths.replaceIndex(realIndex.url, expected: realIndex.contents, with: updated) {
            return .committed(sha: commit.output, paths: committedPaths)
        }
        // `reset HEAD -- paths`, not `add`: it sets exactly these entries to the new commit, and
        // an edit the person made to one of them since stays theirs, unstaged. `add` would have
        // staged it under the agent's commit.
        let refresh = runGitWithRetry(["reset", "-q", "HEAD", "--"] + committedPaths, cwd: cwd, maxWait: 10)
        return refresh.success
            ? .committed(sha: commit.output, paths: committedPaths)
            : .committedIndexStale(sha: commit.output, paths: committedPaths)
    }

    /// The paths `git add -v` says it changed (`add 'path'`, `remove 'path'`), or nil when its
    /// output is anything else (a warning, a path it wasn't asked for): then git is asked.
    public nonisolated static func addedPaths(_ output: String, asked: Set<String>) -> [String]? {
        var paths: [String] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let path: Substring
            if line.hasPrefix("add '"), line.hasSuffix("'") { path = line.dropFirst(5).dropLast() }
            else if line.hasPrefix("remove '"), line.hasSuffix("'") { path = line.dropFirst(8).dropLast() }
            else { return nil }
            guard asked.contains(String(path)) else { return nil }
            paths.append(String(path))
        }
        return paths
    }
}

/// Commits exactly `paths` without ever consuming the repository's real index.
///
/// The old implementation staged with `git add` and committed with `git commit`, both of
/// which operate on the shared index — so anything the *user* had already staged rode along
/// in the agent's commit and got attributed to the agent (reproduced by the audit: a staged
/// `manual.txt` landing in a checkpoint for `agent.txt`). This builds the commit in a
/// private index instead: seed it from HEAD, add only the agent's paths, write a tree,
/// commit that tree with HEAD as parent, then move the branch. The user's index is touched
/// only at the very end, and only to refresh those same paths so they don't linger as
/// phantom modifications.
/// Why this returns a three-valued result instead of an Optional: `nil` used to mean both
/// "nothing to commit" and "six different git failures", so a checkpoint whose commit
/// actually failed was reported to the user as a green "✓ Checkpoint … (no file changes)"
/// and recorded with no SHA — a checkpoint that claimed success, changed nothing, and
/// couldn't be undone, with the agent's work left uncommitted underneath it. Found by an
/// audit. Failure now has to be stated.
public enum CheckpointCommitOutcome {
    case committed(sha: String, paths: [String])
    /// Committed, but the real index still holds these paths as they were before: another
    /// git process held its lock throughout. Left alone, the person's next `git commit`
    /// would commit the old contents back, silently reverting the checkpoint (2026-09-30
    /// audit, H4), so it's said, with the command that fixes it.
    case committedIndexStale(sha: String, paths: [String])

    /// The commit, whichever way the index came out.
    public var commit: (sha: String, paths: [String])? {
        switch self {
        case .committed(let sha, let paths), .committedIndexStale(let sha, let paths): return (sha, paths)
        default: return nil
        }
    }

    /// What to tell the person about a stale index, with the command that fixes it.
    public var staleIndexWarning: String? {
        guard case .committedIndexStale(_, let paths) = self else { return nil }
        let quoted = paths.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        return "The checkpoint is committed, but git's index couldn't be updated: another git command held its lock. Until it is, your next commit would undo the checkpoint. Run this in Run to fix it:\ngit reset -q HEAD -- \(quoted)"
    }
    /// The staged tree matched HEAD — the batch genuinely changed nothing on disk.
    case nothingToCommit
    case failed(step: String, message: String)
}
