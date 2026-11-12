import AppKit
import SideAgents
import SideSessionsKit

/// One terminal: a live PTY and the view that renders it. A class so every window's Run stage
/// and the agent's command path hold the same object rather than copies that drift.
@MainActor
final class TerminalSession {
    let id = UUID()
    var label: String
    /// The person's own name for the tab (Direction 03 §4.3); nil for the automatic one: what's
    /// running names it (an agent CLI's task), else `label`, the folder.
    var customName: String?
    var title: String { customName ?? viewController.programTitle ?? restoredTitle ?? label }
    /// After a restart, what the tab was last called (its program's title), until a program
    /// names it again.
    var restoredTitle: String?
    let viewController: TerminalViewController
    var hasUnseenOutput = false
    /// The track it was opened for: the checkout a new tab starts in, and whose agent may run
    /// commands in it. Not where it is now; a program can move itself (`SessionRegistry` asks
    /// the kernel for that).
    var trackKey: String

    init(label: String, viewController: TerminalViewController, trackKey: String = "") {
        self.label = label
        self.viewController = viewController
        self.trackKey = trackKey
    }
}

/// Every terminal in a project — owned by `ProjectContext`, not by a window (RFC R2, the
/// Heron/Think split applied to terminals).
///
/// PTYs used to live inside `RunWorkspaceViewController`, so a terminal's lifetime was a window's
/// lifetime: closing the window killed a running dev server even while another window had the
/// project open, and an agent on a track no window was showing had nowhere to run a command at
/// all ("No window is open for this project"). Now Run is a view that attaches to these
/// sessions; they live until the project is released or the user closes them.
///
/// One list of tabs for the whole project, not one per track (SIDE_RFC_SESSIONS.md: terminals
/// keyed by project): switching branches no longer swaps the tabs, and an agent that moved
/// itself into a worktree stays where you left it. Each tab still knows the track it was opened
/// for (`TerminalSession.trackKey`: a branch name, `""` for none).
@MainActor
final class TerminalSessionManager {
    /// Posted with the manager as `object`. `userInfo[originKey]` is the `ObjectIdentifier` of
    /// the Run view that caused the change, when one did — so that view can skip redrawing what
    /// it just drew.
    static let didChangeNotification = Notification.Name("SideTerminalSessionsDidChange")
    static let originKey = "origin"

    let projectRoot: URL
    private let directoryProvider: (String) -> URL
    /// The project's tabs (`holder == nil`, what every window shows), or the terminals torn out
    /// into one window (`holder` is that window's id) — out of the tabs, so no other window
    /// shows them, until that window closes and `release` hands them back.
    private typealias Pool = UUID?
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

    /// The project's tabs, or those held by window `holder`.
    func sessions(holder: UUID? = nil) -> [TerminalSession] { sessionsByPool[holder] ?? [] }

    /// The tabs opened for one track, in order.
    func sessions(forTrackKey key: String, holder: UUID? = nil) -> [TerminalSession] { sessions(holder: holder).filter { $0.trackKey == key } }

    /// Every tab's session in the project, every track and window.
    func everySession() -> [TerminalSession] { sessionsByPool.sorted { $0.key == nil && $1.key != nil }.flatMap(\.value) }

    /// Every terminal opened for a track, the tabs' and any held beside a stage or in a window of its own.
    func allSessions(forTrackKey key: String) -> [TerminalSession] { everySession().filter { $0.trackKey == key } }

    /// Replaces the tabs — the Run view's open, close, restart and reorder all land here.
    /// Records the new shape so a relaunch can reopen it.
    func setSessions(_ sessions: [TerminalSession], holder: UUID? = nil, origin: AnyObject? = nil) {
        sessionsByPool[holder] = sessions.isEmpty && holder != nil ? nil : sessions
        if let active = activeIndexByPool[holder], !sessions.indices.contains(active) {
            activeIndexByPool[holder] = sessions.isEmpty ? nil : sessions.count - 1
        }
        remember()
        post(origin: origin)
    }

    /// Replaces one track's tabs among the rest: kept ones stay where they are, new ones go at
    /// the end.
    func setSessions(_ sessions: [TerminalSession], forTrackKey key: String, holder: UUID? = nil, origin: AnyObject? = nil) {
        let current = self.sessions(holder: holder)
        var list = current.filter { session in session.trackKey != key || sessions.contains { $0 === session } }
        list += sessions.filter { session in !list.contains { $0 === session } }
        for session in sessions { session.trackKey = key }
        setSessions(list, holder: holder, origin: origin)
    }

    func activeIndex(holder: UUID? = nil) -> Int? { activeIndexByPool[holder] }
    func setActiveIndex(_ index: Int?, holder: UUID? = nil) { activeIndexByPool[holder] = index }

    /// Selects `session` in the tabs, if it's one of them.
    func select(_ session: TerminalSession) {
        if let index = sessions().firstIndex(where: { $0 === session }) { activeIndexByPool[nil] = index }
    }

    var hasUnseenOutput: Bool { sessionsByPool.values.contains { $0.contains { $0.hasUnseenOutput } } }

    /// A terminal torn out into its own window: it leaves the tabs (and any other window's) for
    /// the window `holder`, still running — nothing restarts.
    func hold(_ session: TerminalSession, holder: UUID, origin: AnyObject? = nil) {
        for pool in sessionsByPool.keys {
            guard let index = sessionsByPool[pool]?.firstIndex(where: { $0 === session }) else { continue }
            let countBefore = sessionsByPool[pool]!.count
            sessionsByPool[pool]!.remove(at: index)
            activeIndexByPool[pool] = TabSelection.indexAfterClosing(index, active: activeIndexByPool[pool], countBefore: countBefore)
        }
        let target: Pool = holder
        sessionsByPool[target, default: []].append(session)
        activeIndexByPool[target] = sessionsByPool[target]!.count - 1
        post(origin: origin)
    }

    /// The torn-out window closed: its terminals go back to the end of the tabs, still running,
    /// rather than dying with a window that was only ever a view onto them.
    func release(holder: UUID) {
        guard let held = sessionsByPool.removeValue(forKey: holder) else { return }
        activeIndexByPool.removeValue(forKey: holder)
        sessionsByPool[nil, default: []].append(contentsOf: held)
        if activeIndexByPool[nil] == nil { activeIndexByPool[nil] = 0 }
        post(origin: nil)
    }

    /// A new, not-yet-started terminal in `directory` (or the track's own worktree).
    /// `keeperID`: a remembered tab's session, to reattach to if its keeper still runs.
    func makeSession(forTrackKey key: String, inDirectory directory: String? = nil, keeperID: String? = nil) -> TerminalSession {
        let vc = TerminalViewController()
        let path = directory ?? directoryProvider(key).path
        vc.workingDirectory = path
        if SessionKeepers.isEnabled {
            let id = keeperID ?? SessionPaths.newID()
            vc.keeperID = id
            vc.keeperFacts = [SessionKeepers.Fact.project: projectRoot.path, SessionKeepers.Fact.track: key]
            vc.recoveredAgentSession = agentSession(forKeeper: id)
            vc.onAgentSessionReported = { [weak self] agent, session in self?.rememberAgentSession(agent: agent, session: session, forKeeper: id) }
        }
        let session = TerminalSession(label: (path as NSString).lastPathComponent, viewController: vc, trackKey: key)
        vc.onExitStatusChanged = { [weak self] _, _ in self?.post(origin: nil) }
        // Run's status line: live cwd and the last command's exit and duration.
        vc.onDirectoryChanged = { [weak self] _ in self?.post(origin: nil) }
        vc.onCommandStatusChanged = { [weak self] in self?.post(origin: nil) }
        vc.onProgramTitleChanged = { [weak self] in self?.post(origin: nil) }
        vc.onWorkingChanged = { [weak self] in self?.post(origin: nil) }
        vc.onNewsChanged = { [weak self] in self?.post(origin: nil) }
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

    /// A tab that runs one program instead of a shell — an outside agent's `terminal/create`.
    /// Appended to the tabs, not selected: it's visible and interruptible without taking the tab
    /// the user was looking at.
    func makeCommandSession(forTrackKey key: String, launch: TerminalViewController.CommandLaunch, directory: String, label: String? = nil) -> TerminalSession {
        let session = makeSession(forTrackKey: key, inDirectory: directory)
        session.viewController.commandLaunch = launch
        session.label = label ?? ([ (launch.command as NSString).lastPathComponent ] + launch.arguments.prefix(2)).joined(separator: " ")
        session.viewController.loadViewIfNeeded()
        append(session)
        return session
    }

    /// Takes one terminal out of whichever list holds it, ending its process if it still runs.
    func removeSession(_ session: TerminalSession) {
        session.viewController.prepareForClose()
        if let id = session.viewController.keeperID { forgetAgentSession(forKeeper: id) }
        for pool in sessionsByPool.keys {
            guard let index = sessionsByPool[pool]?.firstIndex(where: { $0 === session }) else { continue }
            let countBefore = sessionsByPool[pool]!.count
            sessionsByPool[pool]!.remove(at: index)
            activeIndexByPool[pool] = TabSelection.indexAfterClosing(index, active: activeIndexByPool[pool], countBefore: countBefore)
        }
        remember()
        post(origin: nil)
    }

    func markDisplayed(_ session: TerminalSession?, by host: AnyObject) {
        let key = ObjectIdentifier(host)
        guard displayedByHost[key] != session?.id else { return }
        displayedByHost[key] = session?.id
        post(origin: host)
    }

    /// Whether a view other than `host` is showing `session`.
    func isDisplayed(_ session: TerminalSession, elsewhereThan host: AnyObject) -> Bool {
        displayedByHost.contains { $0.key != ObjectIdentifier(host) && $0.value == session.id }
    }

    func clearUnseenOutput(_ session: TerminalSession) {
        guard session.hasUnseenOutput else { return }
        session.hasUnseenOutput = false
        post(origin: nil)
    }

    /// A track was deleted. Its terminals stay open, the project's now: what runs in them is
    /// the person's to end, and one whose folder went shows that in its status row. Only the
    /// track's agent loses its pinned terminal.
    func forgetTrack(_ key: String) {
        for session in allSessions(forTrackKey: key) { session.trackKey = "" }
        agentSessionIDByTrackKey.removeValue(forKey: key)
        remember()
        post(origin: nil)
    }

    /// The project is being released (its last window closed, or Side quitting). Shells in
    /// keepers are let go and keep running, to be reattached when the project opens again; the
    /// rest end.
    func teardownAll() {
        for list in sessionsByPool.values { for session in list { session.viewController.detachOrClose() } }
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

    /// Which tab the agent's commands run in, if it has one pinned — non-creating.
    func agentSessionIndex(forTrackKey key: String) -> Int? {
        guard let id = agentSessionIDByTrackKey[key] else { return nil }
        return sessions().firstIndex { $0.id == id }
    }

    /// True when the terminal the agent's commands would go to has been `cd`-ed outside the
    /// track's worktree (audit D-10) — then no command auto-runs, whatever the autonomy: an
    /// allowlisted `rm -rf build` means something else in another directory. Non-creating.
    func agentSessionIsOutsideWorktree(trackKey key: String) -> Bool {
        let list = sessions(forTrackKey: key).filter { !$0.viewController.isCommandSession }
        let pinned = agentSessionIDByTrackKey[key].flatMap { id in allSessions(forTrackKey: key).first { $0.id == id } }
        let active = activeSession(forTrackKey: key)
        guard let session = pinned ?? active ?? list.first, let cwd = session.viewController.currentDirectory else { return false }
        return !Self.isInside(cwd, root: directoryProvider(key).path)
    }

    /// Path containment with symlinks resolved (`/tmp` is `/private/tmp`), component-wise so
    /// `/work/app2` is not inside `/work/app`.
    static func isInside(_ path: String, root: String) -> Bool {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let base = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.pathComponents
        return resolved.count >= base.count && Array(resolved.prefix(base.count)) == base
    }

    /// The selected tab, when it was opened for track `key`.
    private func activeSession(forTrackKey key: String) -> TerminalSession? {
        let list = sessions()
        guard let index = activeIndex(), list.indices.contains(index), list[index].trackKey == key else { return nil }
        return list[index]
    }

    /// Adds a tab at the end, selected if none is.
    private func append(_ session: TerminalSession) {
        var list = sessions()
        list.append(session)
        if activeIndex() == nil { setActiveIndex(list.count - 1) }
        setSessions(list)
    }

    func agentSession(forTrackKey key: String) -> TerminalSession {
        // A command tab (an outside agent's `terminal/create`) runs one program; nothing is ever
        // typed into it.
        let shells = sessions(forTrackKey: key).filter { !$0.viewController.isCommandSession }
        // Pinned wherever it is — a torn-out agent terminal is still the one running its command.
        if let id = agentSessionIDByTrackKey[key], let pinned = allSessions(forTrackKey: key).first(where: { $0.id == id }), pinned.viewController.isAliveOrUnstarted {
            return pinned
        }
        let chosen: TerminalSession
        if let active = activeSession(forTrackKey: key), !active.viewController.isCommandSession, active.viewController.isAliveOrUnstarted {
            chosen = active
        } else if let first = shells.first(where: { $0.viewController.isAliveOrUnstarted }) {
            chosen = first
        } else {
            chosen = makeSession(forTrackKey: key)
            chosen.viewController.loadViewIfNeeded()
            append(chosen)
        }
        agentSessionIDByTrackKey[key] = chosen.id
        return chosen
    }

    // MARK: - Remembered shape

    /// Only directories, names and keepers are stored — no scrollback, no history: a terminal's
    /// contents are not ours to persist. Keyed by project.
    private static let rememberedTabsKey = "side.run-tabs-by-project"
    /// The per-track records the tabs were kept in before, read until a project's are rewritten.
    private static let rememberedSessionsKey = "side.run-sessions-by-track"
    /// Tabs' own names, in the same order as the directories; "" for an automatic name.
    private static let rememberedNamesKey = "side.run-session-names-by-track"
    /// Tabs' keeper sessions, in the same order; "" for a tab with none.
    private static let rememberedKeepersKey = "side.run-session-keepers-by-track"

    /// Agent sessions by keeper id (`claude:<session id>`), for resuming after a restart.
    private static let agentSessionsKey = "side.run-session-agents"

    func agentSession(forKeeper id: String) -> String? {
        let map = HeronDefaults.store.dictionary(forKey: Self.agentSessionsKey) as? [String: String] ?? [:]
        guard let value = map[id], value.hasPrefix("claude:") else { return nil }
        return String(value.dropFirst("claude:".count))
    }

    func rememberAgentSession(agent: String, session: String, forKeeper id: String) {
        for list in sessionsByPool.values { for s in list where s.viewController.keeperID == id { s.viewController.recoveredAgentSession = session } }
        guard !AppDelegate.isUITesting else { return }
        var map = HeronDefaults.store.dictionary(forKey: Self.agentSessionsKey) as? [String: String] ?? [:]
        map[id] = "\(agent):\(session)"
        HeronDefaults.store.set(map, forKey: Self.agentSessionsKey)
    }

    /// The tab running Claude Code session `id` right now, if any
    /// (SIDE_RFC_SHARED_CLAUDE_SESSIONS.md: Agent asks before both are live).
    func sessionRunningClaude(_ id: String) -> TerminalSession? {
        everySession().first { $0.viewController.recoveredAgentSession == id && $0.viewController.runningProgramName == "claude" }
    }

    func forgetAgentSession(forKeeper id: String) {
        var map = HeronDefaults.store.dictionary(forKey: Self.agentSessionsKey) as? [String: String] ?? [:]
        guard map.removeValue(forKey: id) != nil else { return }
        HeronDefaults.store.set(map, forKey: Self.agentSessionsKey)
    }

    /// A tab as it's remembered between launches.
    struct RememberedTab: Equatable {
        var directory: String
        var name: String?
        var keeperID: String?
        var trackKey: String
    }

    /// The project's tabs in order, as Side last left them.
    ///
    /// Once kept per track (`side.run-sessions-by-track` and its two companions); read from
    /// there, every track's in turn, until the project's tabs are first written the new way.
    func rememberedTabs() -> [RememberedTab] {
        let map = HeronDefaults.store.dictionary(forKey: Self.rememberedTabsKey) as? [String: [[String: String]]] ?? [:]
        if let tabs = map[projectRoot.path] {
            return tabs.compactMap { tab in
                guard let directory = tab["directory"] else { return nil }
                return RememberedTab(directory: directory, name: tab["name"].flatMap { $0.isEmpty ? nil : $0 },
                                     keeperID: tab["keeper"].flatMap { $0.isEmpty ? nil : $0 }, trackKey: tab["track"] ?? "")
            }
        }
        return rememberedTabsByTrack()
    }

    /// The old per-track records for this project: the no-track tabs first, then each track's.
    private func rememberedTabsByTrack() -> [RememberedTab] {
        let directories = HeronDefaults.store.dictionary(forKey: Self.rememberedSessionsKey) as? [String: [String]] ?? [:]
        let names = HeronDefaults.store.dictionary(forKey: Self.rememberedNamesKey) as? [String: [String]] ?? [:]
        let keepers = HeronDefaults.store.dictionary(forKey: Self.rememberedKeepersKey) as? [String: [String]] ?? [:]
        let prefix = projectRoot.path + "#"
        let tracks = directories.keys.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }.sorted()
        return tracks.flatMap { track -> [RememberedTab] in
            let key = prefix + track
            let named = names[key] ?? [], ids = keepers[key] ?? []
            return (directories[key] ?? []).enumerated().map { index, directory in
                RememberedTab(directory: directory, name: named.indices.contains(index) && !named[index].isEmpty ? named[index] : nil,
                              keeperID: ids.indices.contains(index) && !ids[index].isEmpty ? ids[index] : nil, trackKey: track)
            }
        }
    }

    /// The person named a tab, or gave it back its automatic name.
    func rename(_ session: TerminalSession, to name: String?) {
        session.customName = name
        remember()
        post(origin: nil)
    }

    /// Set once a Run view has brought the remembered tabs back (or found none). Until then
    /// nothing is written: a tab an agent opened first would otherwise replace them all.
    private(set) var hasRestored = false
    func markRestored() {
        hasRestored = true
        remember()
    }

    private func remember() {
        guard hasRestored, !AppDelegate.isUITesting else { return }
        // Command tabs are an agent's one-off programs, not terminals to reopen.
        let kept = everySession().filter { !$0.viewController.isCommandSession && $0.viewController.workingDirectory != nil }
        let tabs = kept.map { session -> [String: String] in
            ["directory": session.viewController.workingDirectory ?? "", "name": session.customName ?? "",
             "keeper": session.viewController.keeperID ?? "", "track": session.trackKey]
        }
        var map = HeronDefaults.store.dictionary(forKey: Self.rememberedTabsKey) as? [String: [[String: String]]] ?? [:]
        map[projectRoot.path] = tabs
        HeronDefaults.store.set(map, forKey: Self.rememberedTabsKey)
    }

    private func post(origin: AnyObject?) {
        var info: [String: Any] = [:]
        if let origin { info[Self.originKey] = ObjectIdentifier(origin) }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self, userInfo: info)
    }
}
