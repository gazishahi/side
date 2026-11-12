import AppKit
import SideAgents
import SideSessionsKit

/// Sessions (SIDE_RFC_SESSIONS.md, phase 1): every program running in Side's terminals, in
/// every open project and the home folder, and every Claude Code session on the Mac, in any
/// terminal or in the background (`claude agents --json`). Observed,
/// never owned: Side reads what each says it's doing and where it is, and starts nothing.
///
/// What a session is doing comes, best first, from what the program reports itself (OSC 7501,
/// kept by its keeper), then from Side's own reading of the terminal (the working spinner, a
/// question or a bell while you were away). Where it is: its working directory, matched to the
/// project's checkouts (the main folder and every worktree, agents' own included).
@MainActor
final class SessionRegistry {
    static let shared = SessionRegistry()
    static let didChangeNotification = Notification.Name("SideSessionRegistryDidChange")

    /// A place code lives: the project's main folder or one of its worktrees.
    struct Checkout: Equatable, Sendable {
        let path: String
        /// Nil when detached.
        let branch: String?
        let isMain: Bool
    }

    enum State: Equatable {
        case working(progress: Int?)
        /// What it needs, when it said (OSC 7501's kind).
        case needsYou(ProgramStatusRecord.Kind?)
        case done
        case failed
        case idle

        /// Needs-you first, then failures, what finished, what's working, what's idle.
        var rank: Int {
            switch self {
            case .needsYou: return 0
            case .failed: return 1
            case .done: return 2
            case .working: return 3
            case .idle: return 4
            }
        }

        var word: String {
            switch self {
            case .working: return "Working"
            case .needsYou(.permission?): return "Needs permission"
            case .needsYou(.question?): return "Has a question"
            case .needsYou(.auth?): return "Needs you to sign in"
            case .needsYou(nil): return "Needs you"
            case .done: return "Finished"
            case .failed: return "Failed"
            case .idle: return "Idle"
            }
        }

        var status: DS.StatusState {
            switch self {
            case .working: return .working
            case .needsYou: return .needsYou
            case .done: return .verified
            case .failed: return .failed
            case .idle: return .idle
            }
        }
    }

    struct Session: Equatable, Identifiable {
        enum Source: Equatable {
            /// A tab in Side's Terminal (the `TerminalSession`'s id).
            case terminal(UUID)
            /// A Claude Code session Side isn't showing in a tab (`claude agents`): another
            /// terminal's, or a background one. By its session id.
            case claude(String)
        }

        let id: String
        let source: Source
        /// The program's command name ("claude", "codex", "npm"); nil for a shell at its prompt.
        let program: String?
        let title: String
        let state: State
        /// One line from the program on what it's doing or waiting for; empty when it said none.
        /// Untrusted text: shown as plain text, never as markup.
        let message: String
        let cwd: String?
        /// The open project it belongs to; nil for a terminal in the home folder.
        let project: URL?
        let checkout: Checkout?
        /// Its state is the program's own report (OSC 7501, or Claude's agent list), not Side's
        /// reading of its terminal.
        let reportsItself: Bool

        var isAgent: Bool { program.map(SessionRegistry.agentPrograms.contains) ?? false }
    }

    /// The agent CLIs Side knows by name (the keeper's list).
    nonisolated static let agentPrograms: Set<String> = ["claude", "codex", "opencode", "gemini", "agy", "aider", "goose", "amp", "crush", "qwen", "cursor-agent", "copilot"]

    private(set) var sessions: [Session] = []
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var refreshScheduled = false
    /// Checkouts by project path, read off the main thread.
    private var checkouts: [String: [Checkout]] = [:]
    private var claudeSessions: [ClaudeSession] = []
    private var looking = false

    private init() {}

    /// Starts watching: terminal changes and status reports at once, checkouts and Claude's
    /// background sessions every ten seconds.
    func start() {
        guard timer == nil else { return }
        HookInbox.shared.start()
        for name in [TerminalSessionManager.didChangeNotification, TerminalViewController.programStatusDidChangeNotification, HookInbox.didChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            })
        }
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.lookAround() }
        }
        lookAround()
    }

    /// One rebuild per burst of terminal events.
    func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.refreshScheduled = false
            self?.refresh()
        }
    }

    func refresh() {
        var next: [Session] = []
        let contexts = ProjectContextRegistry.openContexts()
        var pools: [(project: URL?, terminals: TerminalSessionManager)] = contexts.map { ($0.projectRoot, $0.terminals) }
        pools.append((nil, RunWorkspaceViewController.homeTerminals))
        var claudeIDsInTerminals: Set<String> = []
        var foregroundPIDs: Set<pid_t> = []
        // What the hooks say, by session and by the agent's process.
        let hooked = Array(HookInbox.shared.sessions.sessions.values)
        let hookedByPID = Dictionary(hooked.filter { $0.pid > 0 }.map { ($0.pid, $0) }, uniquingKeysWith: { $0.updatedAt > $1.updatedAt ? $0 : $1 })
        let hookedByID = Dictionary(hooked.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for pool in pools {
            let projectCheckouts = pool.project.flatMap { checkouts[$0.standardizedFileURL.path] } ?? []
            // Named as their tabs are: two in one folder are "app" and "app 2".
            let terminals = pool.terminals.everySession()
            let titles = RunWorkspaceViewController.distinctTitles(terminals.map(\.title))
            for (terminal, title) in zip(terminals, titles) {
                let vc = terminal.viewController
                guard vc.isAliveOrUnstarted else { continue }
                let program = vc.runningProgramName
                var reading = Self.state(records: vc.programStatus, working: vc.isProgramWorking, news: vc.news, program: program)
                if let id = vc.recoveredAgentSession, program == "claude" { claudeIDsInTerminals.insert(id) }
                // Where the program really is (the kernel's word), else the shell's last report.
                let shell = vc.keeperID.flatMap { SessionKeepers.liveRecord($0)?.childPID }
                let foreground = shell.flatMap(ForegroundProgram.group(ofShell:))
                if let foreground { foregroundPIDs.insert(foreground) }
                // The agent's own word through its hooks, when it didn't report in the terminal.
                if program != nil, !reading.reported,
                   let hook = foreground.flatMap({ hookedByPID[$0] }) ?? vc.recoveredAgentSession.flatMap({ hookedByID[$0] }) {
                    claudeIDsInTerminals.insert(hook.id)
                    reading = (hook.state, hook.message, true)
                }
                let cwd = foreground.flatMap(ForegroundProgram.directory(of:)) ?? vc.currentDirectory ?? vc.workingDirectory
                next.append(Session(id: "terminal:\(terminal.id.uuidString)", source: .terminal(terminal.id), program: program, title: title,
                                    state: reading.state, message: reading.message, cwd: cwd, project: pool.project,
                                    checkout: cwd.flatMap { Self.checkout(for: $0, in: projectCheckouts) }, reportsItself: reading.reported))
            }
        }
        // Claude Code's own list, less the sessions already showing in a tab (by conversation, or
        // by the process in a tab's foreground).
        var listed = claudeIDsInTerminals
        for session in claudeSessions where !claudeIDsInTerminals.contains(session.sessionId) && !foregroundPIDs.contains(session.pid) {
            guard let listedState = session.state else { continue }
            listed.insert(session.sessionId)
            let hook = hookedByID[session.sessionId]
            let cwd = hook?.cwd ?? session.cwd
            let project = Self.project(containing: cwd, in: contexts)
            let projectCheckouts = project.flatMap { checkouts[$0.standardizedFileURL.path] } ?? []
            next.append(Session(id: "claude:\(session.sessionId)", source: .claude(session.sessionId), program: "claude",
                                title: session.name ?? hook.map(\.request).flatMap { $0.isEmpty ? nil : $0 } ?? "Claude Code",
                                state: hook?.state ?? listedState, message: hook?.message ?? session.waitingFor ?? "", cwd: cwd,
                                project: project, checkout: Self.checkout(for: cwd, in: projectCheckouts), reportsItself: true))
        }
        // Sessions only the hooks know of (a Claude Code too old for `claude agents`): while
        // their process lives.
        for hook in hooked where !listed.contains(hook.id) && !foregroundPIDs.contains(hook.pid) && HookSessions.isAlive(hook.pid) {
            let project = hook.cwd.flatMap { Self.project(containing: $0, in: contexts) }
            let projectCheckouts = project.flatMap { checkouts[$0.standardizedFileURL.path] } ?? []
            next.append(Session(id: "claude:\(hook.id)", source: .claude(hook.id), program: hook.agent,
                                title: hook.request.isEmpty ? "Claude Code" : hook.request, state: hook.state, message: hook.message,
                                cwd: hook.cwd, project: project, checkout: hook.cwd.flatMap { Self.checkout(for: $0, in: projectCheckouts) },
                                reportsItself: true))
        }
        next.sort { ($0.state.rank, $0.title) < ($1.state.rank, $1.title) }
        guard next != sessions else { return }
        sessions = next
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    /// The open project a folder is in, at a component boundary (`/work/app2` isn't in `/work/app`).
    static func project(containing directory: String, in contexts: [ProjectContext]) -> URL? {
        let path = (directory as NSString).standardizingPath
        return contexts.map(\.projectRoot).filter { root in
            let base = root.standardizedFileURL.path
            return path == base || path.hasPrefix(base + "/")
        }.max { $0.path.count < $1.path.count }
    }

    /// Off the main thread: every open project's checkouts, and Claude's background sessions.
    private func lookAround() {
        guard !looking else { return }
        looking = true
        let roots = ProjectContextRegistry.openContexts().map(\.projectRoot)
        let asksClaude = Self.mayAskClaude
        DispatchQueue.global(qos: .utility).async {
            var found: [String: [Checkout]] = [:]
            for root in roots {
                let result = GitPaths.runGitRaw(["worktree", "list", "--porcelain"], cwd: root.path)
                if result.success { found[root.standardizedFileURL.path] = Self.parseWorktrees(result.output) }
            }
            let claude = asksClaude ? Self.claudeAgentList() : []
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.looking = false
                    self.checkouts = found
                    self.claudeSessions = claude
                    self.refresh()
                }
            }
        }
    }

    // MARK: Reading a terminal

    /// A terminal's state: the program's own report when it made one, else Side's reading.
    nonisolated static func state(records: ProgramStatusRecords, working: Bool, news: TerminalViewController.News?, program: String?)
        -> (state: State, message: String, reported: Bool) {
        // The program itself, else the record it touched last.
        if let record = records.root ?? records.records.max(by: { $0.updatedAt < $1.updatedAt }) {
            let state: State
            switch record.state {
            case .working: state = .working(progress: record.progress)
            case .blocked: state = .needsYou(record.kind)
            case .done: state = .done
            case .error: state = .failed
            case .idle: state = .idle
            }
            return (state, record.message, true)
        }
        if working { return (.working(progress: nil), "", false) }
        switch news {
        case .needsYou?: return (.needsYou(nil), "", false)
        case .finished?: return (.done, "", false)
        case nil: return (.idle, "", false)
        }
    }

    // MARK: Checkouts

    /// `git worktree list --porcelain`: the main folder first, then each worktree.
    nonisolated static func parseWorktrees(_ porcelain: String) -> [Checkout] {
        var result: [Checkout] = []
        for block in porcelain.components(separatedBy: "\n\n") {
            var path: String?
            var branch: String?
            var bare = false
            for line in block.split(separator: "\n").map(String.init) {
                if line.hasPrefix("worktree ") { path = String(line.dropFirst("worktree ".count)) }
                if line.hasPrefix("branch ") { branch = String(line.dropFirst("branch ".count)).replacingOccurrences(of: "refs/heads/", with: "") }
                if line == "bare" { bare = true }
            }
            guard let path, !bare else { continue }
            result.append(Checkout(path: (path as NSString).standardizingPath, branch: branch, isMain: result.isEmpty))
        }
        return result
    }

    /// The checkout a directory is in: the deepest one containing it (a worktree inside the
    /// main folder, as Claude Code's `.claude/worktrees/` are, wins over the main folder).
    nonisolated static func checkout(for directory: String, in checkouts: [Checkout]) -> Checkout? {
        let path = (directory as NSString).standardizingPath
        return checkouts.filter { path == $0.path || path.hasPrefix($0.path + "/") }.max { $0.path.count < $1.path.count }
    }

    // MARK: Claude Code's sessions

    struct ClaudeSession: Equatable, Sendable {
        let sessionId: String
        let pid: pid_t
        let name: String?
        let cwd: String
        /// "interactive" (in a terminal) or "background".
        let kind: String?
        /// Nil for a stopped or finished one: not shown.
        let state: State?
        let waitingFor: String?
    }

    /// Not in tests or UI tests: a test never runs the developer's real Claude Code.
    nonisolated static var mayAskClaude: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] == nil && environment["XCTestBundlePath"] == nil
            && !UserDefaults.standard.bool(forKey: "SideUITesting")
    }

    /// `claude agents --json`: every live Claude Code session on the Mac, interactive (in any
    /// terminal) and background. Read only, five seconds at most; nothing when Claude Code isn't
    /// installed, is too old, or answers anything but a list.
    nonisolated static func claudeAgentList() -> [ClaudeSession] {
        guard let claude = LanguageServerRegistry.resolveExecutable(named: "claude") else { return [] }
        let process = Process()
        process.executableURL = claude
        process.arguments = ["agents", "--json"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning { process.terminate(); return [] }
        guard process.terminationStatus == 0 else { return [] }
        return parseClaudeAgents(output.fileHandleForReading.readDataToEndOfFile())
    }

    /// As Claude Code 2.1.322 prints it (checked 2026-11-12): `pid`, `cwd`, `kind`
    /// (interactive, background), `startedAt`, `sessionId`, `name` and `status` (busy, idle).
    /// The agent view docs name the field `state` (working, blocked, done, failed, stopped) and
    /// add `waitingFor`: both spellings are read. Anything unexpected is skipped, not guessed at.
    nonisolated static func parseClaudeAgents(_ data: Data) -> [ClaudeSession] {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let list = (object as? [[String: Any]]) ?? ((object as? [String: Any])?["agents"] as? [[String: Any]]) ?? []
        return list.compactMap { entry in
            guard let id = entry["sessionId"] as? String, !id.isEmpty, let cwd = entry["cwd"] as? String else { return nil }
            let state: State?
            switch (entry["state"] as? String) ?? (entry["status"] as? String) {
            case "working", "busy": state = .working(progress: nil)
            case "blocked", "waiting": state = .needsYou(nil)
            case "idle": state = .idle
            case "done": state = .done
            case "failed", "error": state = .failed
            default: state = nil
            }
            return ClaudeSession(sessionId: id, pid: (entry["pid"] as? NSNumber)?.int32Value ?? 0,
                                 name: (entry["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }, cwd: cwd,
                                 kind: entry["kind"] as? String, state: state, waitingFor: entry["waitingFor"] as? String)
        }
    }

    var stateForTesting: String {
        sessions.map { "\($0.title) | \($0.program ?? "-") | \($0.state.word) | \($0.reportsItself ? "reported" : "read") | \($0.checkout?.branch ?? "-") | \($0.message)" }
            .joined(separator: "\n")
    }
}
