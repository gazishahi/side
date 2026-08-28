import Foundation

/// Owns at most one `AgentRunner` per track key for a single project, spawned lazily on first
/// visit — the `AgentRunner` analog of `LSPManager` (lazy per-key creation, explicit discard,
/// teardown-all on project close). Lives on `ProjectContext`, so it's shared across every window
/// that has the project open, the same as `TrackStore`/`AgentSessionStore`.
@MainActor
final class AgentRunnerManager {
    private let sessionStore: AgentSessionStore
    /// The project these runners belong to, used to file their token usage — the *project* root,
    /// not a track's worktree, so usage rolls up per project no matter which worktree ran it.
    private let projectPath: String
    private let bridgeProvider: (String) -> WorkspaceBridge
    /// Resolves the directory a track's tools should actually operate in — its linked worktree
    /// if it has one, else the shared project root. Resolved fresh per tool call (see
    /// `AgentRunner`), not cached, so a track lazily materializing its worktree mid-session is
    /// picked up without any explicit invalidation.
    private let rootProvider: (String) -> URL
    /// Whether a track has opted into skipping approval for `run_shell_command` — resolved
    /// fresh per tool call, same as `rootProvider`, so toggling it mid-conversation takes effect
    /// on the very next command rather than requiring a fresh runner.
    /// The track's mode (tool scope × autonomy), resolved fresh per request.
    private let modeProvider: (String) -> AgentMode
    /// Per-track provider/model/effort, resolved fresh per request — same reasoning as
    /// `rootProvider`.
    private let modelSelectionProvider: (String) -> (providerId: String?, modelId: String?, effort: AgentEffort?)
    private var runners: [String: AgentRunner] = [:]

    /// Fires whenever any owned runner's phase or unseen-completion state changes, debounced so
    /// a Tracks ledger or stage badge driven by many runners doesn't relayout on every single
    /// streamed token — only Think, watching one specific runner, needs per-event granularity.
    /// A multicast (same shape as `TrackStore.addChangeObserver`), not a single closure: this
    /// manager is shared across every window that has the project open, and a plain
    /// single-assignment callback would let the last window's registration silently clobber
    /// every other window's.
    private var changeObservers: [UUID: () -> Void] = [:]
    private var debounceWorkItem: DispatchWorkItem?
    private static let debounceInterval: TimeInterval = 0.2

    init(sessionStore: AgentSessionStore, projectPath: String, bridgeProvider: @escaping (String) -> WorkspaceBridge, rootProvider: @escaping (String) -> URL, modeProvider: @escaping (String) -> AgentMode, modelSelectionProvider: @escaping (String) -> (providerId: String?, modelId: String?, effort: AgentEffort?)) {
        self.sessionStore = sessionStore
        self.projectPath = projectPath
        self.bridgeProvider = bridgeProvider
        self.rootProvider = rootProvider
        self.modeProvider = modeProvider
        self.modelSelectionProvider = modelSelectionProvider
    }

    @discardableResult
    func addChangeObserver(_ observer: @escaping () -> Void) -> UUID {
        let token = UUID()
        changeObservers[token] = observer
        return token
    }

    func removeChangeObserver(_ token: UUID) {
        changeObservers.removeValue(forKey: token)
    }

    private func scheduleChangeNotification() {
        debounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            for observer in self.changeObservers.values { observer() }
        }
        debounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceInterval, execute: workItem)
    }

    /// Branch-name key, `""` for "no active track" — same convention every other per-track store
    /// in this codebase already uses. Creating one wires it into the debounced multicast above
    /// for the rest of its life — no separate teardown needed, since that observer closure is
    /// only ever referenced by this manager, not by any external caller.
    func runner(forTrackKey trackKey: String) -> AgentRunner {
        if let existing = runners[trackKey] { return existing }
        let runner = AgentRunner(
            trackKey: trackKey,
            sessionStore: sessionStore,
            projectPath: projectPath,
            bridgeProvider: { [bridgeProvider] in bridgeProvider(trackKey) },
            rootProvider: { [rootProvider] in rootProvider(trackKey) },
            modeProvider: { [modeProvider] in modeProvider(trackKey) },
            modelSelectionProvider: { [modelSelectionProvider] in modelSelectionProvider(trackKey) }
        )
        runner.addObserver { [weak self] event in
            guard case .phaseChanged = event else { return }
            self?.scheduleChangeNotification()
        }
        runners[trackKey] = runner
        return runner
    }

    /// Non-creating peek — a track that's never had an agent run shouldn't spin one up just to
    /// ask "what's its activity," which would always answer `.none` anyway.
    func existingRunner(forTrackKey trackKey: String) -> AgentRunner? {
        runners[trackKey]
    }

    /// Called when a track is deleted — its conversation has nowhere to belong anymore, same
    /// cleanup contract as Make's file memory and Run's terminal sessions.
    func discardRunner(forTrackKey trackKey: String) {
        guard let runner = runners.removeValue(forKey: trackKey) else { return }
        runner.teardown()
    }

    /// Called once, when the last window watching this project releases it (see
    /// `ProjectContextRegistry.release`) — never on an ordinary stage or track switch, which is
    /// exactly the bug this whole extraction fixes.
    func teardownAll() {
        for runner in runners.values { runner.teardown() }
        runners.removeAll()
    }
}
