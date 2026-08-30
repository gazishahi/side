import Foundation

/// Undoing agent work, without ever destroying anything.
///
/// The obvious implementation — `git reset --hard <sha>` — is the wrong one for Side, for three
/// independent reasons, each of which alone would rule it out:
///
/// 1. **It throws away uncommitted work.** A track's worktree routinely holds edits the user made
///    by hand between agent runs. Those aren't in any checkpoint (checkpoints only ever contain
///    what the agent changed), so a hard reset silently deletes work the user never agreed to
///    lose. "Undo the agent's last change" must never mean "and also your own."
/// 2. **It contradicts what a checkpoint *is*.** The constitution calls checkpoints a durable
///    record of what an agent did. A reset erases that record from history — the audit trail is
///    gone precisely when someone is most likely to want it (after something went wrong).
/// 3. **It breaks promotion.** A track's checkpoints can already have been merged into a parent
///    track or main. Rewriting this branch's history after that produces divergence the user
///    can't see and didn't ask for.
///
/// So undoing is *forward* motion: a new commit that reverses the old one, exactly like `git
/// revert`. History grows, nothing is lost, the audit trail records both the change and its
/// undo — and an undo can itself be undone. The one thing a revert can't claim is that the tree
/// is byte-identical to some past moment; that's the honest trade, and it's the right one.
enum CheckpointRestore {
    /// What to reverse.
    enum Scope: Equatable {
        /// Just this checkpoint — later ones stay. Surgical, and the common case: "that one
        /// change was wrong, the rest were fine."
        case single
        /// This checkpoint and everything after it, reversed newest-first so each revert applies
        /// against the tree the next one expects.
        case throughLatest
    }

    enum Outcome: Equatable {
        case reverted(commitSHA: String, checkpointCount: Int)
        /// The reverse doesn't apply cleanly — the files moved on since. Nothing was changed;
        /// git's conflict state is rolled back before returning, so the worktree is untouched.
        case conflicted(paths: [String])
        case nothingToDo
        case failed(String)
    }

    /// Commits to reverse, newest-first — the order `git revert` needs, since each reversal is
    /// computed against the tree the *later* commits produced.
    ///
    /// Pure so the ordering rule is testable without a repository: get this wrong and a
    /// multi-checkpoint undo conflicts with itself for reasons that look like git being flaky.
    static func commitsToRevert(
        checkpoints: [Checkpoint], target: Checkpoint, scope: Scope
    ) -> [String] {
        let ordered = checkpoints
            .filter { $0.gitCommitSHA != nil }
            .sorted { $0.createdAt < $1.createdAt }
        switch scope {
        case .single:
            return target.gitCommitSHA.map { [$0] } ?? []
        case .throughLatest:
            guard let index = ordered.firstIndex(where: { $0.id == target.id }) else { return [] }
            return ordered[index...].compactMap(\.gitCommitSHA).reversed()
        }
    }

    /// The message on the undo commit. Names what was undone, because six months later the
    /// commit log is the only thing left that remembers.
    static func revertMessage(target: Checkpoint, scope: Scope, count: Int) -> String {
        let intent = target.declaredIntent.isEmpty ? "an agent checkpoint" : "\u{201C}\(target.declaredIntent)\u{201D}"
        switch scope {
        case .single:
            return "Undo agent checkpoint: \(intent)"
        case .throughLatest:
            return count <= 1
                ? "Undo agent checkpoint: \(intent)"
                : "Undo \(count) agent checkpoints back to \(intent)"
        }
    }

    /// Applies the reversal in `worktreePath` as a single new commit.
    ///
    /// `--no-commit` for every revert, then one commit at the end: reversing four checkpoints
    /// should read as one deliberate undo in the log, not four mechanical entries. On any
    /// failure the whole thing is abandoned (`git revert --quit` plus a checkout of the paths
    /// git touched), so a conflict leaves the worktree exactly as it was rather than half-undone
    /// with conflict markers in it.
    @discardableResult
    static func perform(
        commits: [String], message: String, worktreePath: String,
        runGit: (([String], String) -> (success: Bool, output: String)) = { args, cwd in GitPaths.runGit(args, cwd: cwd) }
    ) -> Outcome {
        guard !commits.isEmpty else { return .nothingToDo }

        for sha in commits {
            let result = runGit(["revert", "--no-commit", "--no-edit", sha], worktreePath)
            guard !result.success else { continue }
            // Conflicted (or otherwise refused): unwind and report which files disagreed.
            let conflicted = runGit(["diff", "--name-only", "--diff-filter=U"], worktreePath)
                .output.split(separator: "\n").map(String.init)
            abandon(worktreePath: worktreePath, runGit: runGit)
            return conflicted.isEmpty ? .failed(result.output) : .conflicted(paths: conflicted)
        }

        let commit = runGit(["commit", "-m", message], worktreePath)
        guard commit.success else {
            abandon(worktreePath: worktreePath, runGit: runGit)
            return .failed(commit.output)
        }
        let sha = runGit(["rev-parse", "HEAD"], worktreePath).output
        return .reverted(commitSHA: sha, checkpointCount: commits.count)
    }

    /// Puts the worktree back the way it was after a failed revert: clear git's revert state,
    /// then reset the index and tree to HEAD. Deliberately does *not* touch untracked files —
    /// a failed undo has no business deleting anything the user created.
    private static func abandon(
        worktreePath: String, runGit: (([String], String) -> (success: Bool, output: String))
    ) {
        _ = runGit(["revert", "--quit"], worktreePath)
        _ = runGit(["reset", "--hard", "HEAD"], worktreePath)
    }
}
