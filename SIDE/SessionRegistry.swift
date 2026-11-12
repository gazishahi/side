import AppKit
import SideAgents
import SideSessionsKit

/// Sessions (SIDE_RFC_SESSIONS.md, phase 1): every program running in Side's terminals, in
/// every open project and the home folder, and Claude Code's background sessions. Observed,
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
            /// A Claude Code background session (`claude agents`), by its session id.
            case background(String)
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
    private var background: [BackgroundSession] = []
    private var looking = false

    private init() {}

    /// Starts watching: terminal changes and status reports at once, checkouts and Claude's
    /// background sessions every ten seconds.
    func start() {
        guard timer == nil else { return }
        for name in [TerminalSessionManager.didChangeNotification, TerminalViewController.programStatusDidChangeNotification] {
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
        for pool in pools {
            let projectCheckouts = pool.project.flatMap { checkouts[$0.standardizedFileURL.path] } ?? []
            for terminal in pool.terminals.everySession() {
                let vc = terminal.viewController
                guard vc.isAliveOrUnstarted else { continue }
                let program = vc.runningProgramName
                let reading = Self.state(records: vc.programStatus, working: vc.isProgramWorking, news: vc.news, program: program)
                if let id = vc.recoveredAgentSession, program == "claude" { claudeIDsInTerminals.insert(id) }
                // Where the program really is (the kernel's word), else the shell's last report.
                let shell = vc.keeperID.flatMap { SessionKeepers.liveRecord($0)?.childPID }
                let cwd = shell.flatMap(ForegroundProgram.group(ofShell:)).flatMap(ForegroundProgram.directory(of:))
                    ?? vc.currentDirectory ?? vc.workingDirectory
                next.append(Session(id: "terminal:\(terminal.id.uuidString)", source: .terminal(terminal.id), program: program, title: terminal.title,
                                    state: reading.state, message: reading.message, cwd: cwd, project: pool.project,
                                    checkout: cwd.flatMap { Self.checkout(for: $0, in: projectCheckouts) }, reportsItself: reading.reported))
            }
        }
        // Claude's background sessions not already showing in a tab.
        for session in background where !claudeIDsInTerminals.contains(session.sessionId) {
            guard let state = session.state else { continue }
            let project = contexts.first { session.cwd.hasPrefix($0.projectRoot.standardizedFileURL.path) }?.projectRoot
            let projectCheckouts = project.flatMap { checkouts[$0.standardizedFileURL.path] } ?? []
            next.append(Session(id: "background:\(session.sessionId)", source: .background(session.sessionId), program: "claude",
                                title: session.name ?? "Claude Code", state: state, message: session.waitingFor ?? "", cwd: session.cwd,
                                project: project, checkout: Self.checkout(for: session.cwd, in: projectCheckouts), reportsItself: true))
        }
        next.sort { ($0.state.rank, $0.title) < ($1.state.rank, $1.title) }
        guard next != sessions else { return }
        sessions = next
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
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
            let background = asksClaude ? Self.claudeBackgroundSessions() : []
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.looking = false
                    self.checkouts = found
                    self.background = background
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

    // MARK: Claude's background sessions

    struct BackgroundSession: Equatable, Sendable {
        let sessionId: String
        let name: String?
        let cwd: String
        /// Nil for a stopped session: not shown.
        let state: State?
        let waitingFor: String?
    }

    /// Not in tests or UI tests: a test never runs the developer's real Claude Code.
    nonisolated static var mayAskClaude: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] == nil && environment["XCTestBundlePath"] == nil
            && !UserDefaults.standard.bool(forKey: "SideUITesting")
    }

    /// `claude agents --json` (Claude Code's agent view, a research preview): its background
    /// sessions. Read only, five seconds at most; nothing when Claude Code isn't installed, is too
    /// old, or answers anything but a list.
    nonisolated static func claudeBackgroundSessions() -> [BackgroundSession] {
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

    /// Its documented fields: `sessionId`, `name`, `cwd`, `state` (working, blocked, done,
    /// failed, stopped; blocked always means it needs you) and `waitingFor`. Anything unexpected
    /// is skipped, not guessed at.
    nonisolated static func parseClaudeAgents(_ data: Data) -> [BackgroundSession] {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let list = (object as? [[String: Any]]) ?? ((object as? [String: Any])?["agents"] as? [[String: Any]]) ?? []
        return list.compactMap { entry in
            guard let id = entry["sessionId"] as? String, !id.isEmpty, let cwd = entry["cwd"] as? String else { return nil }
            let state: State?
            switch entry["state"] as? String {
            case "working": state = .working(progress: nil)
            case "blocked": state = .needsYou(nil)
            case "done": state = .done
            case "failed": state = .failed
            default: state = nil
            }
            return BackgroundSession(sessionId: id, name: (entry["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }, cwd: cwd,
                                     state: state, waitingFor: entry["waitingFor"] as? String)
        }
    }

    var stateForTesting: String {
        sessions.map { "\($0.title) | \($0.program ?? "-") | \($0.state.word) | \($0.reportsItself ? "reported" : "read") | \($0.checkout?.branch ?? "-") | \($0.message)" }
            .joined(separator: "\n")
    }
}
