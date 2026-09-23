import Foundation
import Heron

/// What actually happened around a track becoming active, so the UI can tell the user their
/// uncommitted changes weren't silently touched. Only ever non-empty now for the one legacy
/// path this still applies to: a track created before per-track worktrees existed, still
/// checked out in the shared main tree, being moved into its own worktree for the first time
/// (see `materializeFromMainCheckout`). Every other path — a track that already has its own
/// worktree, or a brand-new one — never touches the main tree's working files at all, so there
/// is nothing to stash.
struct TrackSwitchOutcome {
    var stashedFileCount: Int?
    var restoredFileCount: Int?
    var restoreConflicted = false
}

/// Owns the list of tracks for one open project. Persisted at a resolved state directory
/// (`GitPaths.stateDirectory`, effectively `<common-git-dir>/side`) rather than a bare
/// `.git/side` string-append — inside a linked worktree, `.git` is a *file*, not a directory, so
/// the naive path would fragment per-track state depending on which worktree happened to open
/// the project.
@MainActor
final class TrackStore {
    private(set) var tracks: [Track] = []
    let projectRoot: URL
    private let storeURL: URL

    /// One `TrackStore` can now be shared by every window that has this project open (see
    /// `ProjectContext`), so change notification has to reach all of them — a plain
    /// single-assignment closure would let whichever window registered last silently clobber
    /// every other window's callback. Each caller gets a token back to unregister with.
    private var changeObservers: [UUID: () -> Void] = [:]

    @discardableResult
    func addChangeObserver(_ observer: @escaping () -> Void) -> UUID {
        let token = UUID()
        changeObservers[token] = observer
        return token
    }

    func removeChangeObserver(_ token: UUID) {
        changeObservers.removeValue(forKey: token)
    }

    private func notifyChange() {
        for observer in changeObservers.values { observer() }
    }

    var activeTrack: Track? { tracks.first { $0.status == .active } }

    /// Non-nil when `HEAD` is sitting on a branch that isn't the project's default branch and
    /// doesn't belong to any known track — work started outside Side (or before Tracks existed)
    /// that hasn't been folded in yet. Kept separate from `tracks` itself so nothing gets a
    /// fabricated intent without the user explicitly naming it.
    private(set) var untrackedBranch: String?
    /// The worktree `switchToExistingBranch` materialized for `untrackedBranch`, if any —
    /// transferred into the real `Track.workingDirectoryPath` the moment it's promoted.
    private var untrackedBranchWorkingDirectoryPath: String?

    enum RepoState: Equatable {
        case ready
        /// Opening (or creating) a plain folder with no `.git` — every git call would otherwise
        /// fail with "fatal: not a git repository," and without this check that raw stderr text
        /// was leaking into the UI as if it were a branch name.
        case notAGitRepo
    }
    private(set) var repoState: RepoState = .ready

    /// `git rev-parse --abbrev-ref HEAD` literally returns the string "HEAD" when detached — that
    /// isn't a real branch name, so treating it as `untrackedBranch` would let "Turn into a Track"
    /// try to promote a branch called "HEAD" that doesn't actually exist anywhere.
    private(set) var isDetachedHead = false

    /// Bumped synchronously at the start of every mutating operation (create/switch/promote).
    /// `reconcile()`'s own git call runs on a background queue and can land after one of those
    /// has already changed the truth on disk — without this, a reconcile that started just before
    /// a switch could apply its now-stale reading afterward and stomp the switch's own result.
    private var epoch = 0

    /// Synchronous on purpose: callers (namely `ShellViewController.projectOpened`) need
    /// `activeTrack`/`untrackedBranch` settled before this initializer returns, so they can hand
    /// the right per-track key to Make in the same call stack as opening the project — a project
    /// open already blocks briefly on file indexing, so one more quick local `git` call here
    /// doesn't introduce a new perceptible delay.
    /// `probe` carries the git facts this used to discover itself, through four separate
    /// subprocesses, on the main thread during launch. Resolving them once per project (see
    /// `GitLaunchProbe`) and handing them in turns those four spawns into zero — which matters
    /// far more than it sounds, because a bare process spawn costs ~72ms on a machine with
    /// endpoint security, so those four were most of half a second of frozen window.
    ///
    /// Passing nil preserves the old self-resolving behavior, for callers with no probe in hand.
    init(projectRoot: URL, stateDirectory: URL, probe: GitLaunchProbe? = nil) {
        self.projectRoot = projectRoot
        self.storeURL = stateDirectory.appendingPathComponent("tracks.json")
        load()
        let cwd = projectRoot.path
        if let probe {
            repoState = probe.isRepository ? .ready : .notAGitRepo
            cachedDefaultBranch = probe.defaultBranch
            if probe.isRepository {
                applyReconciliation(currentBranch: probe.currentBranch, defaultBranch: probe.defaultBranch)
            }
        } else if refreshRepoState(cwd: cwd) {
            applyReconciliation(currentBranch: currentBranchName(cwd: cwd), defaultBranch: defaultBranchName())
        }
    }

    /// Set from the launch probe. `defaultBranchName()` prefers it over re-spawning git, and it
    /// is refreshed whenever a real probe lands.
    private var cachedDefaultBranch: String?

    /// Replaces this store's git-derived state with a freshly probed one — the correction half
    /// of rendering optimistically from cache. Notifies observers only when something actually
    /// changed, so the common case (the cache was right) causes no relayout at all.
    func applyProbe(_ probe: GitLaunchProbe) {
        let newState: RepoState = probe.isRepository ? .ready : .notAGitRepo
        let changed = newState != repoState || cachedDefaultBranch != probe.defaultBranch
        repoState = newState
        cachedDefaultBranch = probe.defaultBranch
        if probe.isRepository {
            applyReconciliation(currentBranch: probe.currentBranch, defaultBranch: probe.defaultBranch)
        }
        if changed { notifyChange() }
    }

    enum TrackError: Error, LocalizedError, Equatable {
        case emptyIntent
        case gitCheckoutFailed(String)
        case nothingToPromote
        case cannotDeleteActive
        case gitBranchDeleteFailed(String)
        case gitInitFailed(String)
        case gitWorktreeFailed(String)
        /// A parent track can't be deleted out from under tracks still stacked on it — their
        /// base resolution (`ReviewWorkspaceViewController.baseRef`) depends on the parent's
        /// `Track` record existing, not just its branch, so deleting it would silently strand
        /// every child's base/promote-target logic.
        case cannotDeleteTrackWithLiveChildren
        /// `pullFromParent` on a root track — there's no parent branch to pull.
        case noParentTrack
        case nothingToPull
        /// The track's worktree holds uncommitted work and the caller hasn't consented to losing
        /// it. Carries the count so the consent prompt can name what is about to be destroyed.
        case worktreeHasUncommittedChanges(Int)

        var errorDescription: String? {
            switch self {
            case .emptyIntent: return "Give this track a short description first."
            case .gitCheckoutFailed(let detail): return "Git checkout failed: \(detail)"
            case .nothingToPromote: return "There's no untracked branch to turn into a track right now."
            case .cannotDeleteActive: return "Switch to a different track before deleting this one."
            case .gitBranchDeleteFailed(let detail): return "The track was removed, but its branch couldn't be deleted: \(detail)"
            case .gitInitFailed(let detail): return "Git init failed: \(detail)"
            case .gitWorktreeFailed(let detail): return "Git worktree operation failed: \(detail)"
            case .cannotDeleteTrackWithLiveChildren: return "This track still has stacked tracks forked from it — park, complete, or archive them first."
            case .noParentTrack: return "This track doesn't fork from another track — there's nothing to pull."
            case .nothingToPull: return "Already up to date with its parent branch."
            case .worktreeHasUncommittedChanges(let count):
                return "This track's working copy has \(count) uncommitted change\(count == 1 ? "" : "s") that would be lost."
            }
        }
    }

    /// Where `HEAD` actually is on disk can drift from what `tracks.json` says is active — e.g.
    /// checking out a branch from a terminal instead of through Side. Call this whenever the
    /// project is opened or the Tracks stage becomes visible so the ledger reflects reality
    /// instead of stale bookkeeping, rather than only ever trusting its own prior writes. This
    /// only ever inspects the *shared main tree*'s `HEAD` — a track with its own worktree has its
    /// branch permanently pinned to that worktree and can't drift the way a shared checkout can.
    func reconcile() {
        let cwd = projectRoot.path
        let startEpoch = epoch
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let isRepo = self.checkIsGitRepo(cwd: cwd)
            let current = isRepo ? self.currentBranchName(cwd: cwd) : nil
            // Deliberately the git-reading form: this block *is* the refresh, so consulting
            // the cached value would answer with the thing being refreshed.
            let base = isRepo ? self.resolveDefaultBranchFromGit() : ""
            DispatchQueue.main.async {
                // A create/switch/promote started (and possibly finished) while this was in
                // flight — its own reading is already stale, so applying it now would clobber
                // whatever that operation just established.
                guard self.epoch == startEpoch else { return }
                self.repoState = isRepo ? .ready : .notAGitRepo
                guard isRepo else { self.notifyChange(); return }
                self.applyReconciliation(currentBranch: current, defaultBranch: base)
            }
        }
    }

    /// Only ever inspects the *shared main tree*'s `HEAD` — which, once a track has its own
    /// worktree, is permanently independent of that track: the main tree normally never leaves
    /// the default branch again, while the track's branch lives on in its own worktree
    /// regardless. So a worktree-backed active track must never be demoted just because the main
    /// tree's `HEAD` (predictably) isn't sitting on its branch — only a *legacy* active track,
    /// one still relying on the shared checkout (`workingDirectoryPath == nil`), can genuinely
    /// drift this way, e.g. someone running `git checkout` by hand in the main tree.
    private func applyReconciliation(currentBranch: String?, defaultBranch: String) {
        let activeHasOwnWorktree = activeTrack?.workingDirectoryPath != nil
        guard let currentBranch else {
            // Detached — HEAD points directly at a commit, not a branch, so there's nothing to
            // mark active or offer as an untracked branch to promote, unless that's just the
            // main tree being detached independent of any worktree-backed track.
            isDetachedHead = true
            guard !activeHasOwnWorktree else { notifyChange(); return }
            let hadStaleActive = activeTrack != nil
            demoteActiveTrack()
            untrackedBranch = nil
            if hadStaleActive { save() }
            notifyChange()
            return
        }
        isDetachedHead = false
        if let index = tracks.firstIndex(where: { $0.branchName == currentBranch }) {
            untrackedBranch = nil
            guard tracks[index].status != .active else { return }
            demoteActiveTrack()
            tracks[index].status = .active
            tracks[index].lastActiveAt = Date()
            save()
            notifyChange()
        } else {
            guard !activeHasOwnWorktree else {
                // The main tree is just sitting on its own business (the default branch, or
                // whatever else) — doesn't affect a track that already has an independent
                // worktree, but the untracked-branch banner is still worth keeping accurate.
                setUntrackedBranchFromReconcile(currentBranch == defaultBranch ? nil : currentBranch)
                notifyChange()
                return
            }
            let hadStaleActive = activeTrack != nil
            demoteActiveTrack()
            setUntrackedBranchFromReconcile(currentBranch == defaultBranch ? nil : currentBranch)
            if hadStaleActive { save() }
            notifyChange()
        }
    }

    /// `git init`-s a plain folder that isn't a repo yet, then reconciles immediately so the
    /// ledger reflects it without requiring a second visit to this stage.
    func initializeGitRepo(completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        epoch += 1
        let cwd = projectRoot.path
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = self.runGit(["init"], cwd: cwd)
            DispatchQueue.main.async {
                guard result.success else { completion(.failure(TrackError.gitInitFailed(result.output))); return }
                self.repoState = .ready
                self.applyReconciliation(currentBranch: self.currentBranchName(cwd: cwd), defaultBranch: self.defaultBranchName())
                completion(.success(()))
            }
        }
    }

    /// Detached HEAD has no name to promote — this creates a brand-new branch at the current
    /// commit instead, which is the closest real equivalent to "turn this into a track." Gets
    /// its own worktree immediately, same as any other new track — the main tree is left exactly
    /// where it was (still detached), not carried along into the new branch.
    func createTrackFromDetachedHead(intent: String, completion: @escaping @Sendable (Result<(Track, TrackSwitchOutcome), Error>) -> Void) {
        let trimmed = intent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { completion(.failure(TrackError.emptyIntent)); return }
        let branchName = uniqueBranchName(from: trimmed)
        epoch += 1
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = self.addWorktree(branchName: branchName, baseRef: "HEAD", newBranch: true)
            DispatchQueue.main.async {
                switch result {
                case .failure(let error):
                    completion(.failure(error))
                case .success(let worktreePath):
                    self.demoteActiveTrack()
                    var track = Track(intent: trimmed, branchName: branchName)
                    track.workingDirectoryPath = worktreePath.path
                    self.tracks.append(track)
                    self.isDetachedHead = false
                    self.save()
                    self.notifyChange()
                    completion(.success((track, TrackSwitchOutcome())))
                }
            }
        }
    }

    /// Reconciliation's way of updating `untrackedBranch`: a *different* branch invalidates the
    /// adopted worktree path, because that worktree is checked out on the old one.
    ///
    /// Without this: "Switch to Existing Branch…" adopts A and stores A's worktree path; the user
    /// runs `git checkout B` in the main tree; reconcile sets the banner to B but keeps A's path;
    /// "Turn Into a Track" for B then creates a track whose working directory is A's worktree, and
    /// every edit, checkpoint, terminal, and promote for "track B" operates on branch A, forever.
    /// Found by the 2026-09-01 audit.
    private func setUntrackedBranchFromReconcile(_ branch: String?) {
        if branch != untrackedBranch { untrackedBranchWorkingDirectoryPath = nil }
        untrackedBranch = branch
    }

    /// Wraps whatever branch is *already* checked out into a new track — no checkout, since we're
    /// already there. This is how work started before Tracks existed (or outside Side entirely)
    /// gets folded in, with the user naming the intent rather than Side guessing one from the
    /// branch name. Transfers over whatever worktree `switchToExistingBranch` already set up for
    /// this branch, if any — promoting shouldn't require materializing a second time.
    func promoteCurrentBranch(intent: String, completion: @escaping @Sendable (Result<Track, Error>) -> Void) {
        let trimmed = intent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { completion(.failure(TrackError.emptyIntent)); return }
        guard let branchName = untrackedBranch else { completion(.failure(TrackError.nothingToPromote)); return }
        epoch += 1
        demoteActiveTrack()
        var track = Track(intent: trimmed, branchName: branchName)
        // Belt to the clearing above's braces: only hand over a worktree that is actually on this
        // branch. One `symbolic-ref` — a click-triggered action can afford a spawn.
        if let path = untrackedBranchWorkingDirectoryPath {
            let onBranch = runGit(["symbolic-ref", "--short", "HEAD"], cwd: path)
            track.workingDirectoryPath = (onBranch.success && onBranch.output == branchName) ? path : nil
        }
        tracks.append(track)
        untrackedBranch = nil
        untrackedBranchWorkingDirectoryPath = nil
        save()
        notifyChange()
        completion(.success(track))
    }

    /// New tracks branch off the project's default branch by default, never off whatever happens
    /// to be checked out — otherwise creating a track while another track's branch is active
    /// would silently stack them, which is surprising rather than useful. Deliberate stacking is
    /// opt-in via `baseTrack`: a track forking from another track's own branch instead — its own
    /// worktree, own agent, own checkpoint/review/promote cycle, nested rather than sitting side
    /// by side (see "Stacked tracks" in the constitution). Either way this gets its own linked
    /// worktree — the shared main tree is never touched, so there's nothing to guard against
    /// losing there.
    func createTrack(intent: String, baseTrack: Track? = nil, completion: @escaping @Sendable (Result<(Track, TrackSwitchOutcome), Error>) -> Void) {
        let trimmed = intent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { completion(.failure(TrackError.emptyIntent)); return }
        let branchName = uniqueBranchName(from: trimmed)
        epoch += 1
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let cwd = self.projectRoot.path
            let baseRef: String
            if let baseTrack {
                // The parent's branch always exists once the parent track does, regardless of
                // whether its own worktree happens to be materialized right now — branches and
                // worktrees are independent, so there's nothing to lazily create here first.
                baseRef = baseTrack.branchName
            } else {
                // A brand-new repo has no commits yet, so the default branch isn't a valid base
                // to fork from — there's only one branch anyway in that case, so just branch from
                // wherever HEAD is.
                let hasCommits = self.runGit(["rev-parse", "--verify", "-q", "HEAD"], cwd: cwd).success
                baseRef = hasCommits ? self.resolveDefaultBranchFromGit() : "HEAD"
            }
            let result = self.addWorktree(branchName: branchName, baseRef: baseRef, newBranch: true)
            DispatchQueue.main.async {
                switch result {
                case .failure(let error):
                    completion(.failure(error))
                case .success(let worktreePath):
                    self.demoteActiveTrack()
                    var track = Track(intent: trimmed, branchName: branchName, parentTrackId: baseTrack?.id)
                    track.workingDirectoryPath = worktreePath.path
                    self.tracks.append(track)
                    self.untrackedBranch = nil
                    self.save()
                    self.notifyChange()
                    completion(.success((track, TrackSwitchOutcome())))
                }
            }
        }
    }

    /// Local branches and remote-tracking branches (short name, `origin/` stripped) that aren't
    /// already owned by a track — candidates for "Switch to Existing Branch…". Fetched fresh each
    /// time rather than cached, since branches can appear (a teammate pushes, a `git fetch` runs
    /// in Run's terminal) without Side ever being told.
    func availableBranchesToAdopt(completion: @escaping @Sendable ([String]) -> Void) {
        // Snapshotted here, on the main actor, and captured by value. Reading `self.tracks`
        // inside the background block — as this used to — was a genuine unsynchronized read of
        // state the main actor mutates.
        let trackedNames = Set(tracks.map(\.branchName))
        let cwd = projectRoot.path
        let runGit = self.runGit
        DispatchQueue.global(qos: .userInitiated).async {
            let local = runGit(["branch", "--list", "--format=%(refname:short)"], cwd)
            let remote = runGit(["branch", "-r", "--list", "--format=%(refname:short)"], cwd)
            var names = Set<String>()
            if local.success {
                names.formUnion(local.output.split(separator: "\n").map(String.init))
            }
            if remote.success {
                for line in remote.output.split(separator: "\n") {
                    let name = String(line)
                    guard !name.hasSuffix("/HEAD"), let slash = name.firstIndex(of: "/") else { continue }
                    names.insert(String(name[name.index(after: slash)...]))
                }
            }
            let candidates = names.subtracting(trackedNames).sorted()
            DispatchQueue.main.async { completion(candidates) }
        }
    }

    /// Adopts a branch that already exists (locally, or as a remote-tracking branch not yet
    /// checked out anywhere locally) but isn't owned by any track — the in-app equivalent of
    /// `git checkout <branch>` done outside Side, except it lands in its own worktree rather than
    /// the shared main tree (which stays on the default branch, per "the main checkout is
    /// reserved for the base branch"). Lands as `untrackedBranch`, ready to either work on as-is
    /// or fold into a track via `promoteCurrentBranch`.
    func switchToExistingBranch(_ branchName: String, completion: @escaping @Sendable (Result<TrackSwitchOutcome, Error>) -> Void) {
        epoch += 1
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let cwd = self.projectRoot.path
            let localExists = self.runGit(["show-ref", "--verify", "--quiet", "refs/heads/\(branchName)"], cwd: cwd).success
            let result: Result<URL, TrackError>
            if localExists {
                result = self.addWorktree(branchName: branchName, baseRef: nil, newBranch: false)
            } else {
                result = self.addWorktree(branchName: branchName, baseRef: "origin/\(branchName)", newBranch: true)
            }
            DispatchQueue.main.async {
                switch result {
                case .failure(let error):
                    completion(.failure(error))
                case .success(let worktreePath):
                    self.untrackedBranchWorkingDirectoryPath = worktreePath.path
                    self.untrackedBranch = branchName
                    completion(.success(TrackSwitchOutcome()))
                }
            }
        }
    }

    /// Instant once a track has its own worktree — no checkout, so nothing to lose and nothing
    /// to wait on. Only falls back to an actual git operation for a track that predates
    /// per-track worktrees (`workingDirectoryPath == nil`) or whose worktree directory vanished
    /// out from under Side (deleted by hand, moved), in which case it's lazily (re)materialized.
    func switchTo(_ track: Track, completion: @escaping @Sendable (Result<TrackSwitchOutcome, Error>) -> Void) {
        epoch += 1
        if let path = track.workingDirectoryPath, FileManager.default.fileExists(atPath: path) {
            markActive(track)
            completion(.success(TrackSwitchOutcome()))
            return
        }
        // Snapshotted on the main actor before the hop, for the same reason as everywhere else
        // in this file: the background side must not reach back into main-actor state.
        let defaultBranch = defaultBranchName()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = self.materializeWorktree(for: track, defaultBranch: defaultBranch)
            DispatchQueue.main.async {
                switch result {
                case .failure(let error):
                    completion(.failure(error))
                case .success((let worktreePath, let outcome)):
                    if let index = self.tracks.firstIndex(where: { $0.id == track.id }) {
                        self.tracks[index].workingDirectoryPath = worktreePath.path
                    }
                    self.markActive(track)
                    completion(.success(outcome))
                }
            }
        }
    }

    private func markActive(_ track: Track) {
        demoteActiveTrack()
        if let index = tracks.firstIndex(where: { $0.id == track.id }) {
            tracks[index].status = .active
            tracks[index].lastActiveAt = Date()
        }
        save()
        notifyChange()
    }

    /// Pure status change (Park/Archive/Complete) — no git operation. Parking or archiving the
    /// currently-active track is allowed and just leaves no track active until the user switches
    /// to another one; it never touches the working tree on its own.
    func setStatus(_ status: TrackStatus, for track: Track) {
        guard let index = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        tracks[index].status = status
        save()
        notifyChange()
    }

    /// The per-track "auto-run commands" opt-in — off by default. Never touches anything else
    /// about the track; purely a policy toggle `AgentRunner` consults before pausing a
    /// `run_shell_command` proposal for approval.
    func setAutoRunCommands(_ autoRun: Bool, for track: Track) {
        guard let index = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        tracks[index].autoRunCommands = autoRun
        // Kept in step with the mode axes so the two can't disagree about the same track.
        tracks[index].autonomy = autoRun ? .guarded : .manual
        save()
        notifyChange()
    }

    /// The per-track model choice. `nil` provider/model means "follow the app default," which
    /// is what a track gets until someone picks — never a snapshot of whatever the default
    /// happened to be at creation time, so changing the default in Settings still moves every
    /// track that hasn't chosen.
    func setModelSelection(providerId: String?, modelId: String?, effort: AgentEffort?, for trackKey: String) {
        guard let index = tracks.firstIndex(where: { $0.branchName == trackKey }) else { return }
        tracks[index].providerId = providerId
        tracks[index].modelId = modelId
        tracks[index].effort = effort
        save()
        notifyChange()
    }

    /// The track's mode. Writing it also updates the legacy `autoRunCommands` bool so a
    /// downgrade (or any code still reading the bool) sees a consistent picture rather than a
    /// track that silently stopped auto-running.
    func setMode(_ mode: AgentMode, forTrackKey trackKey: String) {
        guard let index = tracks.firstIndex(where: { $0.branchName == trackKey }) else { return }
        tracks[index].toolScope = mode.scope
        tracks[index].autonomy = mode.autonomy
        tracks[index].autoRunCommands = mode.autonomy.autoRunsAllowlistedCommands
        save()
        notifyChange()
    }

    func mode(forTrackKey trackKey: String) -> AgentMode {
        tracks.first { $0.branchName == trackKey }?.mode ?? .default
    }

    func modelSelection(forTrackKey trackKey: String) -> (providerId: String?, modelId: String?, effort: AgentEffort?) {
        guard let track = tracks.first(where: { $0.branchName == trackKey }) else { return (nil, nil, nil) }
        return (track.providerId, track.modelId, track.effort)
    }

    struct GitSummary {
        var aheadCount = 0
        var behindCount = 0
        /// `nil` when there's no real working tree to inspect on this track's behalf — a track
        /// that's never been materialized into a worktree and isn't the one active in the shared
        /// main tree either.
        var uncommittedCount: Int?
        /// Disk space this track's own worktree takes up, in bytes — `nil` for a track with no
        /// worktree of its own (never materialized, a legacy track still living in the shared
        /// main tree, or one already reclaimed via "Remove Working Copy"). Measured for the
        /// active track too, same as any other — its worktree is real, reclaimable disk space
        /// just like any other track's.
        var diskUsageBytes: Int?
    }

    /// Cheap, synchronous git introspection for the ledger row — this is what lets Tracks show a
    /// real snapshot of a track's state (ahead/behind `main`, dirty-or-clean) instead of just the
    /// intent/branch/status/last-active fields it started with. Ahead/behind works against any
    /// ref regardless of what's checked out; uncommitted count needs a real working tree — the
    /// track's own worktree if it has one, else the shared main tree if it's the active track.
    /// Reads main-actor state, so it must be called from the main actor — it exists to *gather*
    /// the inputs for the nonisolated worker below.
    func gitSummaryInputs(for track: Track) -> GitSummaryInputs {
        GitSummaryInputs(track: track, projectRootPath: projectRoot.path, baseBranch: defaultBranchName())
    }

    /// The values `gitSummary` needs, snapshotted on the main actor so the git work that follows
    /// can run anywhere without reaching back into the store.
    ///
    /// This is the shape of the fix, in miniature: the old version read `defaultBranchName()`
    /// (and through it `tracks`) from a background queue while the main actor was free to mutate
    /// it — an unsynchronized read the compiler could not see, because the type declared no
    /// isolation at all.
    struct GitSummaryInputs: Sendable {
        let track: Track
        let projectRootPath: String
        let baseBranch: String
    }

    nonisolated func gitSummary(_ inputs: GitSummaryInputs) -> GitSummary {
        let track = inputs.track
        var summary = GitSummary()
        let cwd = inputs.projectRootPath
        let base = inputs.baseBranch
        if base != track.branchName {
            let counts = runGit(["rev-list", "--left-right", "--count", "\(base)...\(track.branchName)"], cwd: cwd)
            let parts = counts.output.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if counts.success, parts.count == 2, let behind = Int(parts[0]), let ahead = Int(parts[1]) {
                summary.behindCount = behind
                summary.aheadCount = ahead
            }
        }
        let workingTreeCwd = track.workingDirectoryPath ?? (track.status == .active ? inputs.projectRootPath : nil)
        if let workingTreeCwd {
            let status = runGit(["status", "--porcelain"], cwd: workingTreeCwd)
            if status.success {
                summary.uncommittedCount = status.output.isEmpty ? 0 : status.output.split(separator: "\n").count
            }
        }
        if let path = track.workingDirectoryPath {
            summary.diskUsageBytes = Self.directorySizeBytes(at: path)
        }
        return summary
    }

    /// `du -sk` rather than walking the tree in Swift — one process spawn reports a single
    /// number for the whole worktree instead of a `FileManager` enumeration touching every file
    /// individually. Runs on the same background thread the rest of `gitSummary` already does
    /// (see `TracksWorkspaceViewController.refreshGitSummariesIfNeeded`), so a worktree with a
    /// large `node_modules` doesn't block the main thread.
    nonisolated private static func directorySizeBytes(at path: String) -> Int? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        process.arguments = ["-sk", path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // Read before waiting — waiting first deadlocks once git fills the pipe buffer
        // (see GitPaths.runGit).
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8),
              let kilobytes = output.split(separator: "\t").first.flatMap({ Int($0) }) else { return nil }
        return kilobytes * 1024
    }

    /// Renaming only ever touches the human-readable intent — the branch name a track was created
    /// with doesn't change, so this never re-slugs or touches git. Typos and second thoughts are
    /// common; there's no reason renaming should require creating a new track.
    func renameTrack(_ track: Track, to newIntent: String, completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        let trimmed = newIntent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { completion(.failure(TrackError.emptyIntent)); return }
        guard let index = tracks.firstIndex(where: { $0.id == track.id }) else { completion(.success(())); return }
        tracks[index].intent = trimmed
        save()
        notifyChange()
        completion(.success(()))
    }

    /// Park/Archive/Complete all leave the track (and its branch) around indefinitely — this is
    /// the actual removal, for tracks created by mistake or cleaned up long after the work landed.
    /// Refuses to delete the active track (deleting out from under the branch you're standing on
    /// makes no sense) rather than silently switching you elsewhere first. Removes the track's
    /// worktree before deleting its branch — `branch -D` alone fails on a branch still checked
    /// out in a worktree.
    ///
    /// `--force` on the worktree removal destroys every uncommitted and untracked file in it, so
    /// it is only ever passed after a dirtiness probe: a dirty worktree is refused with
    /// `.worktreeHasUncommittedChanges(count)` unless the caller has `discardUncommittedChanges`
    /// consent from the user. Before this, "Delete" with "Also delete branch" *unchecked* — the
    /// option a user picks precisely because they believe the work survives — silently
    /// obliterated the agent's un-checkpointed edits. Found by both git passes of the 2026-09-01
    /// audit. `removeWorkingCopy` already had this rule; delete is the path that didn't.
    func deleteTrack(
        _ track: Track, alsoDeleteBranch: Bool, discardUncommittedChanges: Bool = false,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        guard track.status != .active else { completion(.failure(TrackError.cannotDeleteActive)); return }
        // Archived children don't count — they're already treated as gone from the working set,
        // so they can't be silently stranded by anything this does.
        let hasLiveChildren = tracks.contains { $0.parentTrackId == track.id && $0.status != .archived }
        guard !hasLiveChildren else { completion(.failure(TrackError.cannotDeleteTrackWithLiveChildren)); return }

        guard let path = track.workingDirectoryPath else {
            // No worktree: nothing on disk can be lost, so nothing to probe.
            if !alsoDeleteBranch {
                tracks.removeAll { $0.id == track.id }
                save()
                notifyChange()
                completion(.success(()))
                return
            }
            deleteBranchAndRecord(track, worktreePath: nil, completion: completion)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let dirtyCount = GitPaths.dirtyPaths(cwd: path).count
            if dirtyCount > 0, !discardUncommittedChanges {
                DispatchQueue.main.async { completion(.failure(TrackError.worktreeHasUncommittedChanges(dirtyCount))) }
                return
            }
            if !alsoDeleteBranch {
                _ = self.runGit(["worktree", "remove", "--force", path], cwd: self.projectRoot.path)
                DispatchQueue.main.async {
                    self.tracks.removeAll { $0.id == track.id }
                    self.save()
                    self.notifyChange()
                    completion(.success(()))
                }
                return
            }
            DispatchQueue.main.async { self.deleteBranchAndRecord(track, worktreePath: path, completion: completion) }
        }
    }

    /// The branch-deleting half of `deleteTrack`, reached only after any dirtiness check passed.
    private func deleteBranchAndRecord(_ track: Track, worktreePath: String?, completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let cwd = self.projectRoot.path
            if let path = worktreePath {
                _ = self.runGit(["worktree", "remove", "--force", path], cwd: cwd)
            }
            let result = self.runGit(["branch", "-D", track.branchName], cwd: cwd)
            DispatchQueue.main.async {
                self.tracks.removeAll { $0.id == track.id }
                self.save()
                self.notifyChange()
                if result.success {
                    completion(.success(()))
                } else {
                    completion(.failure(TrackError.gitBranchDeleteFailed(result.output)))
                }
            }
        }
    }

    /// Frees the disk space a materialized track's worktree takes up, without touching its
    /// branch or removing it from the ledger — unlike `deleteTrack`, this is meant to be
    /// reversible: the branch and all its history stay exactly as they are, and the row's
    /// existing "Watch"/"Resume" action already re-materializes a worktree-less track on demand,
    /// the same path a legacy pre-worktree track already went through. Refuses for the active
    /// track (same reasoning as `deleteTrack`) and never passes `--force` — a dirty worktree
    /// makes `git worktree remove` refuse on its own, which is exactly right here: silently
    /// discarding uncommitted work would contradict "just free disk space, keep everything else."
    func removeWorkingCopy(for track: Track, completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        guard track.status != .active else { completion(.failure(TrackError.cannotDeleteActive)); return }
        guard let path = track.workingDirectoryPath else { completion(.success(())); return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = self.runGit(["worktree", "remove", path], cwd: self.projectRoot.path)
            DispatchQueue.main.async {
                guard result.success else {
                    completion(.failure(TrackError.gitWorktreeFailed(result.output)))
                    return
                }
                if let index = self.tracks.firstIndex(where: { $0.id == track.id }) {
                    self.tracks[index].workingDirectoryPath = nil
                }
                self.save()
                self.notifyChange()
                completion(.success(()))
            }
        }
    }

    /// Merges the parent's branch into this stacked track's *own* worktree — the inverse of
    /// Promote (which moves the track's changes onto its base), this moves the base's changes
    /// onto the track, so a long-lived child doesn't drift further from its parent every time the
    /// parent moves forward. Always runs in the child's own worktree, never the parent's — unlike
    /// Promote, there's no "which working copy" ambiguity here since a pull only ever touches the
    /// track pulling. A root track (`parentTrackId == nil`) has no parent branch to pull from.
    func pullFromParent(_ track: Track, completion: @escaping @Sendable (Result<String, Error>) -> Void) {
        guard let parentId = track.parentTrackId, let parent = tracks.first(where: { $0.id == parentId }) else {
            completion(.failure(TrackError.noParentTrack))
            return
        }
        guard let cwd = track.workingDirectoryPath else {
            completion(.failure(TrackError.gitWorktreeFailed("This track has no working copy — resume it (Tracks) first.")))
            return
        }
        let parentBranch = parent.branchName
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let outcome = self.performPull(parentBranch: parentBranch, cwd: cwd)
            DispatchQueue.main.async { completion(outcome) }
        }
    }

    /// `nonisolated`: pure git I/O over immutable inputs. See `runGit` for why this
    /// distinction is now stated rather than assumed.
    nonisolated private func performPull(parentBranch: String, cwd: String) -> Result<String, Error> {
        let dirty = runGit(["status", "--porcelain"], cwd: cwd)
        guard dirty.output.isEmpty else {
            return .failure(TrackError.gitWorktreeFailed("This track's working copy has uncommitted changes — commit or stash them first."))
        }
        let behind = runGit(["rev-list", "--count", "HEAD..\(parentBranch)"], cwd: cwd)
        if behind.success, Int(behind.output) == 0 {
            return .failure(TrackError.nothingToPull)
        }
        let mergeAttempt = runGit(["merge", "--no-ff", parentBranch], cwd: cwd)
        guard mergeAttempt.success else {
            _ = runGit(["merge", "--abort"], cwd: cwd)
            return .failure(TrackError.gitWorktreeFailed("Merging \(parentBranch) would conflict — resolve manually (e.g. rebase) and try again."))
        }
        let sha = runGit(["rev-parse", "--short", "HEAD"], cwd: cwd)
        return .success("✓ Pulled \(parentBranch) (\(sha.success ? sha.output : "?")).")
    }

    private func demoteActiveTrack() {
        if let index = tracks.firstIndex(where: { $0.status == .active }) {
            tracks[index].status = .waiting
        }
    }

    /// Checked against real git branches, not just the ones Side already knows about as tracks —
    /// a branch created before Tracks existed (or from outside Side entirely) still occupies that
    /// name, and `git worktree add -b` would otherwise fail on it with a raw git error.
    private func uniqueBranchName(from intent: String) -> String {
        let lowered = intent.lowercased()
        let slugged = lowered.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        var slug = String(String(slugged).unicodeScalars.filter { !$0.properties.isWhitespace })
        while slug.contains("--") { slug = slug.replacingOccurrences(of: "--", with: "-") }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.count > 48 { slug = String(slug.prefix(48)) }
        if slug.isEmpty { slug = "track" }
        let existingNames = Set(tracks.map(\.branchName)).union(existingGitBranchNames())
        guard existingNames.contains(slug) else { return slug }
        var suffix = 2
        while existingNames.contains("\(slug)-\(suffix)") { suffix += 1 }
        return "\(slug)-\(suffix)"
    }

    /// `nonisolated`: pure git I/O over immutable inputs. See `runGit` for why this
    /// distinction is now stated rather than assumed.
    nonisolated private func checkIsGitRepo(cwd: String) -> Bool {
        let result = runGit(["rev-parse", "--is-inside-work-tree"], cwd: cwd)
        return result.success && result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    @discardableResult
    private func refreshRepoState(cwd: String) -> Bool {
        let ready = checkIsGitRepo(cwd: cwd)
        repoState = ready ? .ready : .notAGitRepo
        return ready
    }

    private func existingGitBranchNames() -> Set<String> {
        let result = runGit(["branch", "--list", "--format=%(refname:short)"], cwd: projectRoot.path)
        guard result.success else { return [] }
        return Set(result.output.split(separator: "\n").map(String.init))
    }

    // MARK: - Persistence

    private func load() {
        tracks = JSONStore.read([Track].self, from: storeURL)?.payload ?? []
    }

    private func save() {
        JSONStore.write(tracks, to: storeURL)
    }

    // MARK: - Git

    /// The project's "home base" branch — where new tracks fork from, regardless of whatever's
    /// currently checked out. Tries the remote's default branch first (what GitHub/GitLab call
    /// the repo's primary branch), then falls back to a local `main` or `master`, then finally to
    /// whatever's currently checked out for a repo with neither (e.g. a brand-new local-only repo).
    /// The cached answer where there is one — main-actor, because the cache is mutable state
    /// the launch probe writes.
    func defaultBranchName() -> String {
        // The probe already answered this; re-asking costs three subprocesses.
        if let cachedDefaultBranch, !cachedDefaultBranch.isEmpty { return cachedDefaultBranch }
        return resolveDefaultBranchFromGit()
    }

    /// The same question, asked of git directly. `nonisolated` because it consults no stored
    /// state — which is exactly what a background refresh wants: re-reading the cache it is
    /// trying to refresh would be circular, and reading it *across* the isolation boundary is
    /// the race this whole pass exists to remove.
    nonisolated func resolveDefaultBranchFromGit() -> String {
        let cwd = projectRoot.path
        let remoteHead = runGit(["symbolic-ref", "refs/remotes/origin/HEAD"], cwd: cwd)
        if remoteHead.success, let name = remoteHead.output.split(separator: "/").last {
            return String(name)
        }
        if runGit(["show-ref", "--verify", "--quiet", "refs/heads/main"], cwd: cwd).success { return "main" }
        if runGit(["show-ref", "--verify", "--quiet", "refs/heads/master"], cwd: cwd).success { return "master" }
        // A brand-new repo (zero commits) has neither ref yet — `show-ref` needs the ref to point
        // to a real object, which doesn't exist until the first commit. `symbolic-ref` still
        // works here since it just reads where HEAD points, without needing that target to exist.
        return currentBranchName(cwd: cwd) ?? ""
    }

    /// `nil` means detached — HEAD points directly at a commit rather than at a branch. Uses
    /// `symbolic-ref`, not `rev-parse --abbrev-ref HEAD`: the latter's behavior on a zero-commit
    /// repo is inconsistent (it can print a bare "HEAD" the same way real detached HEAD does),
    /// while `symbolic-ref` correctly succeeds for any real branch — commits or not — and only
    /// fails when HEAD is genuinely detached.
    /// `nonisolated`: pure git I/O over immutable inputs. See `runGit` for why this
    /// distinction is now stated rather than assumed.
    nonisolated private func currentBranchName(cwd: String) -> String? {
        let result = runGit(["symbolic-ref", "--quiet", "--short", "HEAD"], cwd: cwd)
        return result.success ? result.output : nil
    }

    // MARK: - Worktrees

    /// Every branch currently checked out in some worktree, keyed by branch name, mapped to that
    /// worktree's absolute path — parsed from `git worktree list --porcelain`'s stable line
    /// format (`worktree <path>` / `branch refs/heads/<name>` pairs, blank-line separated).
    /// Consulted before adding a worktree so an existing one is adopted rather than re-added
    /// (which git refuses: a branch can only be checked out in one place at a time).
    /// `nonisolated`: pure git I/O over immutable inputs.
    nonisolated private func existingWorktreesByBranch(cwd: String) -> [String: String] {
        let result = runGit(["worktree", "list", "--porcelain"], cwd: cwd)
        guard result.success else { return [:] }
        var map: [String: String] = [:]
        var currentPath: String?
        for line in result.output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") {
                currentPath = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("branch refs/heads/"), let path = currentPath {
                map[String(line.dropFirst("branch refs/heads/".count))] = path
            } else if line.isEmpty {
                currentPath = nil
            }
        }
        return map
    }

    /// Adds a linked worktree for `branchName` at its canonical location (`GitPaths.worktreePath`),
    /// adopting an already-existing worktree for that branch instead of re-adding if
    /// `git worktree list` shows one (git refuses to check out the same branch twice). Pruned
    /// once first, so a worktree whose directory was deleted out from under git doesn't block a
    /// fresh `add` at the same path with a stale "already exists" error.
    /// `baseRef` is the commit-ish to branch a *new* branch from (ignored when `newBranch` is
    /// false); it can be a plain ref like a default branch name, `"HEAD"`, or a remote-tracking
    /// ref like `"origin/foo"` — `git worktree add -b <branch> <path> origin/foo` auto-sets up
    /// tracking the same way plain `git checkout -b` does, so no separate `--track` flag is
    /// needed for that case.
    /// `nonisolated`: pure git I/O over immutable inputs. See `runGit` for why this
    /// distinction is now stated rather than assumed.
    nonisolated private func addWorktree(branchName: String, baseRef: String?, newBranch: Bool) -> Result<URL, TrackError> {
        let cwd = projectRoot.path
        guard let path = GitPaths.worktreePath(forBranchSlug: branchName.replacingOccurrences(of: "/", with: "-"), projectRoot: projectRoot) else {
            return .failure(.gitWorktreeFailed("Couldn't resolve a worktree location for this repository."))
        }
        if let existing = existingWorktreesByBranch(cwd: cwd)[branchName] {
            return .success(URL(fileURLWithPath: existing))
        }
        _ = runGit(["worktree", "prune"], cwd: cwd)
        try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        var args = ["worktree", "add"]
        if newBranch { args += ["-b", branchName] }
        args.append(path.path)
        if newBranch, let baseRef {
            args.append(baseRef)
        } else if !newBranch {
            args.append(branchName)
        }
        let result = runGit(args, cwd: cwd)
        guard result.success else { return .failure(.gitWorktreeFailed(result.output)) }
        return .success(path)
    }

    /// The one remaining path that still needs stash-style care: a track created before
    /// per-track worktrees existed, whose branch is still checked out in the shared main tree
    /// rather than its own worktree. Moves it over without discarding uncommitted work: stash
    /// (if dirty) → check the main tree out to the default branch → add the worktree → pop the
    /// stash back *inside the new worktree*, not the main tree. If the branch isn't in the main
    /// tree at all (already checked out elsewhere, or nowhere), this is just a plain `addWorktree`.
    /// `nonisolated`: pure git I/O over immutable inputs. See `runGit` for why this
    /// distinction is now stated rather than assumed.
    nonisolated private func materializeWorktree(for track: Track, defaultBranch: String) -> Result<(URL, TrackSwitchOutcome), TrackError> {
        let cwd = projectRoot.path
        guard currentBranchName(cwd: cwd) == track.branchName else {
            switch addWorktree(branchName: track.branchName, baseRef: nil, newBranch: false) {
            case .failure(let error): return .failure(error)
            case .success(let path): return .success((path, TrackSwitchOutcome()))
            }
        }
        guard let path = GitPaths.worktreePath(forBranchSlug: track.branchName.replacingOccurrences(of: "/", with: "-"), projectRoot: projectRoot) else {
            return .failure(.gitWorktreeFailed("Couldn't resolve a worktree location for this repository."))
        }
        let dirtyStatus = runGit(["status", "--porcelain"], cwd: cwd)
        let dirtyCount = dirtyStatus.output.isEmpty ? 0 : dirtyStatus.output.split(separator: "\n").count
        var outcome = TrackSwitchOutcome()
        if dirtyCount > 0 {
            let stashResult = runGit(["stash", "push", "-u", "-m", "side-track-materialize:\(track.branchName)"], cwd: cwd)
            guard stashResult.success else { return .failure(.gitWorktreeFailed(stashResult.output)) }
            outcome.stashedFileCount = dirtyCount
        }
        let checkoutResult = runGit(["checkout", defaultBranch], cwd: cwd)
        guard checkoutResult.success else {
            if dirtyCount > 0 { _ = runGit(["stash", "pop"], cwd: cwd) }
            return .failure(.gitWorktreeFailed(checkoutResult.output))
        }
        try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let addResult = runGit(["worktree", "add", path.path, track.branchName], cwd: cwd)
        guard addResult.success else { return .failure(.gitWorktreeFailed(addResult.output)) }
        if dirtyCount > 0 {
            let popResult = runGit(["stash", "pop"], cwd: path.path)
            outcome.restoredFileCount = dirtyCount
            outcome.restoreConflicted = !popResult.success
        }
        return .success((path, outcome))
    }

    /// `nonisolated` deliberately: this shells out and touches no instance state, so it is the
    /// *business* half of this type and has no business being pinned to the main actor.
    ///
    /// That distinction was invisible before `TrackStore` became `@MainActor`. With no isolation
    /// declared, the compiler had nothing to check, and git calls from background queues looked
    /// exactly like git calls from main. Annotating the type turned nine of them into named
    /// diagnostics — which is the whole argument for adopting strict concurrency rather than
    /// merely enabling it.
    nonisolated private func runGit(_ args: [String], cwd: String) -> (success: Bool, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (false, error.localizedDescription)
        }
        // Read before waiting — waiting first deadlocks once git fills the pipe buffer
        // (see GitPaths.runGit).
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (process.terminationStatus == 0, output)
    }
}
