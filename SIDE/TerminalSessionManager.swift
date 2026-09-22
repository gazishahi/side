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
    private var sessionsByTrackKey: [String: [TerminalSession]] = [:]
    private var activeIndexByTrackKey: [String: Int] = [:]
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

    func sessions(forTrackKey key: String) -> [TerminalSession] { sessionsByTrackKey[key] ?? [] }

    /// Replaces a track's session list — the Run view's open, close, restart and reorder all
    /// land here. Records the new shape so a relaunch can reopen it.
    func setSessions(_ sessions: [TerminalSession], forTrackKey key: String, origin: AnyObject? = nil) {
        sessionsByTrackKey[key] = sessions
        if let active = activeIndexByTrackKey[key], !sessions.indices.contains(active) {
            activeIndexByTrackKey[key] = sessions.isEmpty ? nil : sessions.count - 1
        }
        remember(forTrackKey: key)
        post(origin: origin)
    }

    func activeIndex(forTrackKey key: String) -> Int? { activeIndexByTrackKey[key] }
    func setActiveIndex(_ index: Int?, forTrackKey key: String) { activeIndexByTrackKey[key] = index }

    var hasUnseenOutput: Bool { sessionsByTrackKey.values.contains { $0.contains { $0.hasUnseenOutput } } }

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
        for session in sessionsByTrackKey[key] ?? [] { session.viewController.prepareForClose() }
        sessionsByTrackKey.removeValue(forKey: key)
        activeIndexByTrackKey.removeValue(forKey: key)
        agentSessionIDByTrackKey.removeValue(forKey: key)
        post(origin: nil)
    }

    /// The project is being released: the one moment every shell in it ends.
    func teardownAll() {
        for list in sessionsByTrackKey.values { for session in list { session.viewController.prepareForClose() } }
        sessionsByTrackKey.removeAll()
        activeIndexByTrackKey.removeAll()
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
              let session = sessions(forTrackKey: trackKey).first(where: { $0.id == id }) else { return }
        session.viewController.interruptAgentCommand()
    }

    func agentSession(forTrackKey key: String) -> TerminalSession {
        var list = sessions(forTrackKey: key)
        if let id = agentSessionIDByTrackKey[key], let pinned = list.first(where: { $0.id == id }), pinned.viewController.isAliveOrUnstarted {
            return pinned
        }
        let chosen: TerminalSession
        if let active = activeIndexByTrackKey[key], list.indices.contains(active), list[active].viewController.isAliveOrUnstarted {
            chosen = list[active]
        } else if let first = list.first(where: { $0.viewController.isAliveOrUnstarted }) {
            chosen = first
        } else {
            chosen = makeSession(forTrackKey: key)
            chosen.viewController.loadViewIfNeeded()
            list.append(chosen)
            if activeIndexByTrackKey[key] == nil { activeIndexByTrackKey[key] = list.count - 1 }
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
        let directories = sessions(forTrackKey: key).compactMap { $0.viewController.workingDirectory }
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
