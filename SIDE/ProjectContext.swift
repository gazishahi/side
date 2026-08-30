import Foundation

/// Everything scoped to one open project, shared by every window that has that project open:
/// `TrackStore`, `AgentSessionStore`, and `AgentRunnerManager` (so an agent conversation now
/// survives the window that started it closing, as long as another window keeps the project
/// open). Never constructed directly: always obtained from
/// `ProjectContextRegistry.acquire(projectRoot:)`, which is what guarantees at most one instance
/// per project no matter how many windows have it open.
@MainActor
final class ProjectContext {
    let projectRoot: URL
    let trackStore: TrackStore
    let sessionStore: AgentSessionStore
    lazy var runnerManager: AgentRunnerManager = {
        // Captured by value, not through `self` — the fallback root for when `self` has already
        // deallocated, which the closure below can't express as `self?.projectRoot` (Swift
        // requires an explicit, non-optional-chained `self` for stored-property access even
        // when the fallback only runs after confirming `self` is nil).
        let fallbackRoot = projectRoot
        return AgentRunnerManager(
            sessionStore: sessionStore,
            projectPath: fallbackRoot.path,
            bridgeProvider: { [weak self] trackKey in self?.bridge(forTrackKey: trackKey) ?? .none },
            rootProvider: { [weak self] trackKey in self?.workingDirectory(forTrackKey: trackKey) ?? fallbackRoot },
            modeProvider: { [weak self] trackKey in self?.trackStore.mode(forTrackKey: trackKey) ?? .default },
            modelSelectionProvider: { [weak self] trackKey in self?.trackStore.modelSelection(forTrackKey: trackKey) ?? (nil, nil, nil) }
        )
    }()

    /// Owned by `ProjectContextRegistry` — the number of windows currently holding this context.
    fileprivate var refCount = 0

    /// One entry per window showing this project — weakly held, since a window's lifetime is
    /// never this context's to manage. Backs `bridge(forTrackKey:)`.
    private var bridgeHosts: [ObjectIdentifier: WeakBridgeHost] = [:]

    fileprivate init(projectRoot: URL) {
        self.projectRoot = projectRoot
        // Resolved once, through git itself, rather than a bare `.git/side` string-append — the
        // common git dir is the same directory whether `projectRoot` is the main checkout or one
        // of its linked worktrees, which is what lets opening either resolve to the same ledger.
        // Falls back to the old scheme for a plain folder that isn't a git repo yet at all.
        //
        // Resolved through `GitLaunchProbe`, which answers this *and* the repo/branch questions
        // TrackStore used to ask for itself — six subprocesses collapsed into one, or zero when
        // a cached answer from a previous launch is available. A bare process spawn costs ~72ms
        // on a machine running endpoint security, so this was the bulk of Side's blocked first
        // frame; see GitLaunchProbe for the measurements.
        let cached = GitLaunchProbe.cached(projectRoot: projectRoot)
        let probe = cached ?? GitLaunchProbe.probe(projectRoot: projectRoot)
        if cached == nil { GitLaunchProbe.cache(probe, projectRoot: projectRoot) }
        let stateDirectory = probe.commonGitDir.map { URL(fileURLWithPath: $0).appendingPathComponent("side") }
            ?? projectRoot.appendingPathComponent(".git/side")
        self.trackStore = TrackStore(projectRoot: projectRoot, stateDirectory: stateDirectory, probe: probe)
        self.sessionStore = AgentSessionStore(stateDirectory: stateDirectory)
        // A cache is a guess about a moving target: the user can switch branches, `git init` a
        // plain folder, or move a worktree between launches. So it is used to render *now* and
        // verified immediately after, off the main thread, with any disagreement corrected.
        // Being wrong costs one frame of a stale branch name, never a wrong decision — every
        // operation that acts on git state re-reads it at the time it acts.
        if cached != nil { verifyProbeInBackground(projectRoot: projectRoot, assumed: probe) }
    }

    private func verifyProbeInBackground(projectRoot: URL, assumed: GitLaunchProbe) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let actual = GitLaunchProbe.probe(projectRoot: projectRoot)
            guard actual != assumed else { return }
            GitLaunchProbe.cache(actual, projectRoot: projectRoot)
            DispatchQueue.main.async { self?.trackStore.applyProbe(actual) }
        }
    }

    /// Where a track's own agent tools/Run session should actually operate — its linked
    /// worktree if it has one, else this project's shared root (a track created before Phase C,
    /// or one that's never been materialized). Resolved fresh on every call rather than cached,
    /// so a track lazily materializing its worktree mid-session is picked up on the next tool
    /// call without any explicit invalidation.
    func workingDirectory(forTrackKey trackKey: String) -> URL {
        guard let path = trackStore.tracks.first(where: { $0.branchName == trackKey })?.workingDirectoryPath else { return projectRoot }
        return URL(fileURLWithPath: path)
    }

    func registerBridgeHost(_ host: WorkspaceBridgeHost) {
        bridgeHosts[ObjectIdentifier(host)] = WeakBridgeHost(host)
    }

    func unregisterBridgeHost(_ host: WorkspaceBridgeHost) {
        bridgeHosts.removeValue(forKey: ObjectIdentifier(host))
    }

    /// The real bridge for editor access if some window is both key (frontmost/active) and
    /// currently showing this track, else the safe no-op fallbacks in `.none`. Only the key
    /// window is eligible for the editor-related fields — without that check, an agent running
    /// against a track shown in a background window could land its edit into a Make tab the user
    /// is actively looking at in a *different*, focused window. `runShellCommand` is resolved
    /// separately with looser criteria (see below) since a track's Run session isn't gated on
    /// "is this exact track currently displayed" the way an open Make tab is.
    func bridge(forTrackKey trackKey: String) -> WorkspaceBridge {
        let editHost = bridgeHosts.values.compactMap(\.host).first { $0.isKeyWindow && ($0.bridgeTrackKey ?? "") == trackKey }
        // Prefer the key window (most likely to be the one actively driving this conversation),
        // but fall back to any registered window at all — a track's terminal persists
        // independent of what's currently on screen, the same way a background dev-server
        // process already does.
        let allHosts = bridgeHosts.values.compactMap(\.host)
        let shellHost = allHosts.first { $0.isKeyWindow } ?? allHosts.first
        return WorkspaceBridge(
            liveBufferProvider: { [weak editHost] url in editHost?.liveBufferContent(for: url) },
            applyEditIntoOpenTab: { [weak editHost] url, content in editHost?.applyApprovedEdit(url: url, newContent: content) ?? false },
            onRevealFileRequested: { [weak editHost] url in editHost?.revealAfterApply(url) },
            runShellCommand: { [weak shellHost] command, completion in
                guard let shellHost else { completion("No window is open for this project — nowhere to run this command."); return }
                shellHost.runShellCommand(command, trackKey: trackKey, completion: completion)
            },
            interruptShellCommand: { [weak shellHost] in
                shellHost?.interruptShellCommand(trackKey: trackKey)
            }
        )
    }

    fileprivate func teardownAllRunners() {
        runnerManager.teardownAll()
    }
}

private struct WeakBridgeHost {
    weak var host: WorkspaceBridgeHost?
    init(_ host: WorkspaceBridgeHost) { self.host = host }
}

/// App-level table of `ProjectContext`s, keyed by resolved project identity, refcounted by the
/// windows holding them. Before this existed, `ShellViewController.projectOpened` built its own
/// `TrackStore`/`AgentSessionStore` per window — opening the same project in two windows silently
/// produced two stores both reading and writing the same `tracks.json`/`think.json`, so a track
/// created in one window wouldn't show up in the other's ledger until the next full reconcile (or
/// could stomp it outright on the next save). Routing every window through this registry instead
/// means there is exactly one `TrackStore`/`AgentSessionStore` per project, however many windows
/// are looking at it.
@MainActor
final class ProjectContextRegistry {
    static let shared = ProjectContextRegistry()
    private init() {}

    private var contexts: [String: ProjectContext] = [:]

    /// The common git dir's own path when this resolves to a real repo — so opening the main
    /// checkout in one window and one of its linked worktrees in another still collapses to the
    /// same `ProjectContext`, same `TrackStore`, same ledger, per the plan's own verification
    /// bullet ("point Side at a worktree directory directly and confirm the same ledger
    /// appears"). Falls back to a plain resolved path for a folder that isn't a git repo yet.
    private func key(for projectRoot: URL) -> String {
        GitPaths.projectIdentity(for: projectRoot) ?? projectRoot.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Hands back the existing context for this project if another window already has it open
    /// (bumping its refcount), or creates a fresh one. Every call must be paired with
    /// `release(projectRoot:)` once the caller is done with this project — closing the window, or
    /// opening a different project in the same window.
    /// Every project some window currently has open. Used by Preferences, which isn't scoped to
    /// a project but still has to act on them (deleting conversation history).
    static func openContexts() -> [ProjectContext] {
        Array(shared.contexts.values)
    }

    func acquire(projectRoot: URL) -> ProjectContext {
        let key = key(for: projectRoot)
        if let existing = contexts[key] {
            existing.refCount += 1
            return existing
        }
        let context = ProjectContext(projectRoot: projectRoot)
        context.refCount = 1
        contexts[key] = context
        return context
    }

    /// Drops one window's claim on this project's context. Once no window holds it, the context
    /// is discarded — safe to reconstruct from disk the next time anything reopens this project,
    /// same as today's per-window stores already were.
    func release(projectRoot: URL) {
        let key = key(for: projectRoot)
        guard let existing = contexts[key] else { return }
        existing.refCount -= 1
        if existing.refCount <= 0 {
            existing.teardownAllRunners()
            contexts.removeValue(forKey: key)
        }
    }
}
