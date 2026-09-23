import AppKit

/// One terminal: a live PTY and the view that renders it. A class so every window's Run stage
/// and the agent's command path hold the same object rather than copies that drift.
@MainActor
final class TerminalSession {
    let id = UUID()
    var label: String
    let viewController: TerminalViewController
    var hasUnseenOutput = false

    init(label: String, viewController: TerminalViewController) {
        self.label = label
        self.viewController = viewController
    }
}

/// Every terminal in a project, keyed by track — owned by `ProjectContext`, not by a window
/// (RFC R2, the Heron/Think split applied to terminals).
///
/// PTYs used to live inside `RunWorkspaceViewController`, so a terminal's lifetime was a window's
/// lifetime: closing the window killed a running dev server even while another window had the
/// project open, and an agent on a track no window was showing had nowhere to run a command at
/// all ("No window is open for this project"). Now Run is a view that attaches to these
/// sessions; they live until the project is released or the user closes them. Keys follow the
/// rest of the app: a track's branch name, `""` for "no active track".
@MainActor
final class TerminalSessionManager {
    /// Posted with the manager as `object`. `userInfo[originKey]` is the `ObjectIdentifier` of
    /// the Run view that caused the change, when one did — so that view can skip redrawing what
    /// it just drew.
    static let didChangeNotification = Notification.Name("SideTerminalSessionsDidChange")
    static let originKey = "origin"

    let projectRoot: URL
    private let directoryProvider: (String) -> URL
    /// A track's own list (`holder == nil`, what every window shows), or the terminals torn out
    /// into one window (`holder` is that window's id) — out of the track's list, so no other
    /// window shows them, until that window closes and `release` hands them back.
    private struct Pool: Hashable {
        let trackKey: String
        let holder: UUID?
    }
    private var sessionsByPool: [Pool: [TerminalSession]] = [:]
    private var activeIndexByPool: [Pool: Int] = [:]
    /// The session an agent's commands go to, per track. Pinned the first time the agent needs
    /// one, so interrupting targets the session actually running the command — not whichever
    /// tab happens to be selected now (audit D-4).
    private var agentSessionIDByTrackKey: [String: UUID] = [:]
    /// Which session each attached Run view is showing. Output into a shown session isn't
    /// "unseen"; output anywhere else lights the stage badge.
    private var displayedByHost: [ObjectIdentifier: UUID] = [:]

    init(projectRoot: URL, directoryProvider: @escaping (String) -> URL) {
        self.projectRoot = projectRoot
        self.directoryProvider = directoryProvider
    }

    func workingDirectory(forTrackKey key: String) -> URL { directoryProvider(key) }

    func sessions(forTrackKey key: String, holder: UUID? = nil) -> [TerminalSession] { sessionsByPool[Pool(trackKey: key, holder: holder)] ?? [] }

    /// Every terminal on a track, wherever it's showing.
    private func allSessions(forTrackKey key: String) -> [TerminalSession] {
        sessionsByPool.filter { $0.key.trackKey == key }.sorted { $0.key.holder == nil && $1.key.holder != nil }.flatMap(\.value)
    }

    /// Replaces a track's session list — the Run view's open, close, restart and reorder all
    /// land here. Records the new shape so a relaunch can reopen it.
    func setSessions(_ sessions: [TerminalSession], forTrackKey key: String, holder: UUID? = nil, origin: AnyObject? = nil) {
        let pool = Pool(trackKey: key, holder: holder)
        sessionsByPool[pool] = sessions.isEmpty && holder != nil ? nil : sessions
        if let active = activeIndexByPool[pool], !sessions.indices.contains(active) {
            activeIndexByPool[pool] = sessions.isEmpty ? nil : sessions.count - 1
        }
        remember(forTrackKey: key)
        post(origin: origin)
    }

    func activeIndex(forTrackKey key: String, holder: UUID? = nil) -> Int? { activeIndexByPool[Pool(trackKey: key, holder: holder)] }
    func setActiveIndex(_ index: Int?, forTrackKey key: String, holder: UUID? = nil) { activeIndexByPool[Pool(trackKey: key, holder: holder)] = index }

    var hasUnseenOutput: Bool { sessionsByPool.values.contains { $0.contains { $0.hasUnseenOutput } } }

    /// A terminal torn out into its own window: it leaves the track's list (and any other
    /// window's) for the window `holder`, still running — nothing restarts.
    func hold(_ session: TerminalSession, forTrackKey key: String, holder: UUID, origin: AnyObject? = nil) {
        for pool in sessionsByPool.keys where pool.trackKey == key {
            guard let index = sessionsByPool[pool]?.firstIndex(where: { $0 === session }) else { continue }
            let countBefore = sessionsByPool[pool]!.count
            sessionsByPool[pool]!.remove(at: index)
            activeIndexByPool[pool] = TabSelection.indexAfterClosing(index, active: activeIndexByPool[pool], countBefore: countBefore)
        }
        let target = Pool(trackKey: key, holder: holder)
        sessionsByPool[target, default: []].append(session)
        activeIndexByPool[target] = sessionsByPool[target]!.count - 1
        post(origin: origin)
    }

    /// The torn-out window closed: its terminals go back to the end of their tracks' lists,
    /// still running, rather than dying with a window that was only ever a view onto them.
    func release(holder: UUID) {
        let held = sessionsByPool.keys.filter { $0.holder == holder }
        guard !held.isEmpty else { return }
        for pool in held {
            let main = Pool(trackKey: pool.trackKey, holder: nil)
            sessionsByPool[main, default: []].append(contentsOf: sessionsByPool.removeValue(forKey: pool) ?? [])
            activeIndexByPool.removeValue(forKey: pool)
            if activeIndexByPool[main] == nil { activeIndexByPool[main] = 0 }
        }
        post(origin: nil)
    }

    /// A new, not-yet-started terminal in `directory` (or the track's own worktree).
    func makeSession(forTrackKey key: String, inDirectory directory: String? = nil) -> TerminalSession {
        let vc = TerminalViewController()
        let path = directory ?? directoryProvider(key).path
        vc.workingDirectory = path
        let session = TerminalSession(label: (path as NSString).lastPathComponent, viewController: vc)
        vc.onExitStatusChanged = { [weak self] _, _ in self?.post(origin: nil) }
        vc.onOutputReceived = { [weak self, weak session] in
            guard let self, let session else { return }
            // A shell still settling (integration line echoing, first prompt painting) is
            // plumbing, not output anyone needs to come back for.
            guard session.viewController.startupSettled, !session.hasUnseenOutput,
                  !self.displayedByHost.values.contains(session.id) else { return }
            session.hasUnseenOutput = true
            self.post(origin: nil)
        }
        return session
    }

    func markDisplayed(_ session: TerminalSession?, by host: AnyObject) {
        let key = ObjectIdentifier(host)
        guard displayedByHost[key] != session?.id else { return }
        displayedByHost[key] = session?.id
        post(origin: host)
    }

    func clearUnseenOutput(_ session: TerminalSession) {
        guard session.hasUnseenOutput else { return }
        session.hasUnseenOutput = false
        post(origin: nil)
    }

    /// A deleted track's terminals have nowhere to belong — terminate them rather than leak.
    func discardSessions(forTrackKey key: String) {
        for session in allSessions(forTrackKey: key) { session.viewController.prepareForClose() }
        for pool in sessionsByPool.keys where pool.trackKey == key {
            sessionsByPool.removeValue(forKey: pool)
            activeIndexByPool.removeValue(forKey: pool)
        }
        agentSessionIDByTrackKey.removeValue(forKey: key)
        post(origin: nil)
    }

    /// The project is being released: the one moment every shell in it ends.
    func teardownAll() {
        for list in sessionsByPool.values { for session in list { session.viewController.prepareForClose() } }
        sessionsByPool.removeAll()
        activeIndexByPool.removeAll()
        agentSessionIDByTrackKey.removeAll()
    }

    // MARK: - Agent commands

    /// Types `command` into the track's agent session — the real, visible terminal, never a
    /// hidden `Process` — creating one if the track has none. Needs no window: the session's
    /// view is loaded (which wires its output scan) without ever being shown.
    func runAgentCommand(_ command: String, trackKey: String, timeout: TimeInterval, completion: @escaping (String) -> Void) {
        agentSession(forTrackKey: trackKey).viewController.runAgentCommand(command, timeout: timeout, completion: completion)
    }

    func interruptAgentCommand(trackKey: String) {
        guard let id = agentSessionIDByTrackKey[trackKey],
              let session = allSessions(forTrackKey: trackKey).first(where: { $0.id == id }) else { return }
        session.viewController.interruptAgentCommand()
    }

    func agentSession(forTrackKey key: String) -> TerminalSession {
        var list = sessions(forTrackKey: key)
        // Pinned wherever it is — a torn-out agent terminal is still the one running its command.
        if let id = agentSessionIDByTrackKey[key], let pinned = allSessions(forTrackKey: key).first(where: { $0.id == id }), pinned.viewController.isAliveOrUnstarted {
            return pinned
        }
        let chosen: TerminalSession
        if let active = activeIndex(forTrackKey: key), list.indices.contains(active), list[active].viewController.isAliveOrUnstarted {
            chosen = list[active]
        } else if let first = list.first(where: { $0.viewController.isAliveOrUnstarted }) {
            chosen = first
        } else {
            chosen = makeSession(forTrackKey: key)
            chosen.viewController.loadViewIfNeeded()
            list.append(chosen)
            if activeIndex(forTrackKey: key) == nil { setActiveIndex(list.count - 1, forTrackKey: key) }
            setSessions(list, forTrackKey: key)
        }
        agentSessionIDByTrackKey[key] = chosen.id
        return chosen
    }

    // MARK: - Remembered shape

    /// Only directories are stored — no scrollback, no history: a terminal's contents are not
    /// ours to persist. Keyed by project *and* track; the old per-window key was the track alone,
    /// so every project's "no track" bucket shared one entry.
    private static let rememberedSessionsKey = "side.run-sessions-by-track"

    private func rememberedKey(_ trackKey: String) -> String { "\(projectRoot.path)#\(trackKey)" }

    func rememberedDirectories(forTrackKey key: String) -> [String] {
        let map = UserDefaults.standard.dictionary(forKey: Self.rememberedSessionsKey) as? [String: [String]] ?? [:]
        return map[rememberedKey(key)] ?? map[key] ?? []
    }

    private func remember(forTrackKey key: String) {
        guard !AppDelegate.isUITesting else { return }
        var map = UserDefaults.standard.dictionary(forKey: Self.rememberedSessionsKey) as? [String: [String]] ?? [:]
        let directories = allSessions(forTrackKey: key).compactMap { $0.viewController.workingDirectory }
        map.removeValue(forKey: key)
        if directories.isEmpty { map.removeValue(forKey: rememberedKey(key)) } else { map[rememberedKey(key)] = directories }
        UserDefaults.standard.set(map, forKey: Self.rememberedSessionsKey)
    }

    private func post(origin: AnyObject?) {
        var info: [String: Any] = [:]
        if let origin { info[Self.originKey] = ObjectIdentifier(origin) }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self, userInfo: info)
    }
}
