import AppKit
import Darwin

/// Agent hooks (SIDE_RFC_SESSIONS.md, phase 2): what Claude Code says about its sessions, in any
/// terminal, through `side-hook`. Opt-in: nothing is installed until the person says so
/// (Settings › Agents), and it comes out as cleanly.
///
/// The hook writes each event as a file in `hooks/`; `HookInbox` reads them, in order, and
/// `HookSessions` keeps each session's state from them. Side reads nothing else of the agent's:
/// never its credentials, never its transcripts.
enum HookPaths {
    /// Tests and UI tests: a Side under test never reads the real hooks' events (they're the
    /// running Side's to read) or writes the person's Claude Code settings.
    static var isUnderTest: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil || UserDefaults.standard.bool(forKey: "SideUITesting")
    }

    /// A folder of its own for a run under test: a UI test's, beside its sessions (uitest.sh's
    /// root), else a temporary one.
    static let testRoot: URL = {
        if UserDefaults.standard.bool(forKey: "SideUITesting"), let run = ProcessInfo.processInfo.environment["SIDE_SESSIONS_DIR"], !run.isEmpty {
            return URL(fileURLWithPath: run, isDirectory: true).deletingLastPathComponent().appendingPathComponent("hooks-home", isDirectory: true)
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("SideHooks-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    }()

    /// `~/Library/Application Support/Side`, or `SIDE_HOOKS_HOME` (tests, UI tests).
    nonisolated(unsafe) static var home: URL = {
        if let override = ProcessInfo.processInfo.environment["SIDE_HOOKS_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        if isUnderTest { return testRoot.appendingPathComponent("side", isDirectory: true) }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return support.appendingPathComponent("Side", isDirectory: true)
    }()

    /// Where the hook writes its events.
    static var inbox: URL { home.appendingPathComponent("hooks", isDirectory: true) }

    /// The hook's own copy, outside the app: an installed hook names a path that must stay put
    /// when Side moves or updates.
    static var executable: URL { home.appendingPathComponent("bin/side-hook") }

    /// The copy inside the app.
    static var bundled: URL? { Bundle.main.url(forResource: "side-hook", withExtension: nil) }

    /// Puts the app's hook in place (and keeps it current after an update): written only when
    /// it differs, executable, readable only by the person.
    @discardableResult
    static func installExecutable() -> Bool {
        guard let bundled, let data = try? Data(contentsOf: bundled) else { return false }
        let target = executable
        if (try? Data(contentsOf: target)) == data { return true }
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
            chmod(target.path, 0o755)
            return true
        } catch {
            return false
        }
    }
}

/// One event from a hook, as `side-hook` wrote it.
struct HookEvent: Equatable {
    let agent: String
    /// The process that ran the hook: the agent itself, or a shell it ran the hook through.
    let parentPID: pid_t
    let at: Date
    let name: String
    let sessionID: String
    let cwd: String?
    /// The event's own fields, as the agent sent them (strings only: what Side reads).
    let fields: [String: String]

    /// A file's contents: nil when it isn't an event (cut short, or not JSON at all).
    static func parse(_ data: Data) -> HookEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let side = object["side"] as? [String: Any], let event = object["event"] as? [String: Any],
              let name = event["hook_event_name"] as? String, let session = event["session_id"] as? String, !session.isEmpty
        else { return nil }
        var fields: [String: String] = [:]
        for (key, value) in event {
            if let text = value as? String { fields[key] = text }
            else if let number = value as? NSNumber { fields[key] = number.stringValue }
        }
        // The tool's input, flattened one level: a Bash command, an edited file's path.
        if let input = event["tool_input"] as? [String: Any] {
            for (key, value) in input { if let text = value as? String { fields["tool_input." + key] = text } }
            // MultiEdit's edits: what each wrote, together.
            if let edits = input["edits"] as? [[String: Any]] {
                fields["tool_input.new_string"] = edits.compactMap { $0["new_string"] as? String }.joined(separator: "\n")
            }
        }
        // The files a shell command changed, as Claude Code reports them (`bashEditDiff`).
        if let diff = (event["tool_response"] as? [String: Any])?["bashEditDiff"] as? [String: Any] {
            let paths = Self.paths(in: diff["changedFiles"]) + Self.paths(in: diff["files"])
            if !paths.isEmpty { fields["bash.changed"] = Array(NSOrderedSet(array: paths)).compactMap { $0 as? String }.joined(separator: "\n") }
        }
        return HookEvent(agent: side["agent"] as? String ?? "claude",
                         parentPID: (side["ppid"] as? NSNumber)?.int32Value ?? 0,
                         at: Date(timeIntervalSince1970: (side["at"] as? NSNumber)?.doubleValue ?? 0),
                         name: name, sessionID: session, cwd: event["cwd"] as? String, fields: fields)
    }
}

extension HookEvent {
    /// File paths in a value however it's shaped: a path, a list of them, or entries naming one
    /// (`path`, `file`, `filePath`). Anything else is skipped.
    static func paths(in value: Any?) -> [String] {
        switch value {
        case let path as String: return [path]
        case let list as [Any]: return list.flatMap { paths(in: $0) }
        case let entry as [String: Any]:
            return ["path", "file", "filePath", "file_path"].compactMap { entry[$0] as? String }.prefix(1).map { $0 }
        default: return []
        }
    }

    /// An edit's file and the text it wrote, for attribution.
    var edit: (file: URL, written: [String]?)? {
        guard name == "PostToolUse", let tool = fields["tool_name"], let path = fields["tool_input.file_path"] else { return nil }
        let file = Self.absolute(path, cwd: cwd)
        switch tool {
        case "Edit", "MultiEdit": return fields["tool_input.new_string"].map { (file, Attribution.lines($0)) }
        case "Write": return (file, nil)
        default: return nil
        }
    }

    /// The files a shell command changed.
    var shellChanges: [URL] {
        guard name == "PostToolUse", fields["tool_name"] == "Bash", let changed = fields["bash.changed"] else { return [] }
        return changed.split(separator: "\n").map { Self.absolute(String($0), cwd: cwd) }
    }

    static func absolute(_ path: String, cwd: String?) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        return URL(fileURLWithPath: cwd ?? "/").appendingPathComponent(path).standardizedFileURL
    }
}

/// Each agent session the hooks have told Side about, and what it's doing.
struct HookSession: Equatable {
    let id: String
    var agent: String
    /// The agent's process, once known: how a session is matched to the terminal tab it runs in.
    var pid: pid_t
    var cwd: String?
    var state: SessionRegistry.State = .idle
    /// What it's waiting for or what went wrong, in its own words.
    var message = ""
    /// The last thing it was asked, its first line.
    var request = ""
    var subagents = 0
    var updatedAt: Date
    var ended = false
}

/// The state machine: events in, sessions out. Pure, so it's tested without a hook.
struct HookSessions: Equatable {
    private(set) var sessions: [String: HookSession] = [:]

    /// Applies one event. `agentPID` is the agent's process when Side found it.
    mutating func apply(_ event: HookEvent, agentPID: pid_t) {
        var session = sessions[event.sessionID] ?? HookSession(id: event.sessionID, agent: event.agent, pid: agentPID, updatedAt: event.at)
        if agentPID > 0 { session.pid = agentPID }
        if let cwd = event.cwd, !cwd.isEmpty { session.cwd = cwd }
        session.updatedAt = max(session.updatedAt, event.at)
        let fields = event.fields
        switch event.name {
        case "SessionStart":
            session.ended = false
            session.state = .idle
            session.message = ""
        case "UserPromptSubmit":
            session.state = .working(progress: nil)
            session.message = ""
            if let prompt = fields["prompt"] { session.request = Self.firstLine(prompt) }
        case "PostToolUse", "PostToolUseFailure":
            // At work again after a permission or a question was answered. Tool events are sent
            // in the background and can land after the turn's Stop: a finished turn stays so.
            if case .needsYou = session.state { session.message = "" }
            if session.state != .done, session.state != .failed { session.state = .working(progress: nil) }
        case "PermissionRequest":
            session.state = .needsYou(.permission)
            session.message = Self.permissionMessage(fields)
        case "Notification":
            switch fields["notification_type"] ?? "" {
            case "permission_prompt":
                session.state = .needsYou(.permission)
                session.message = fields["message"] ?? session.message
            case "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input":
                session.state = .needsYou(.question)
                session.message = fields["message"] ?? ""
            case "idle_prompt", "agent_completed":
                // "Waiting for your input": the turn is over, if no Stop said so.
                if case .working = session.state { session.state = .done }
            default:
                break
            }
        case "Stop":
            session.state = .done
            session.message = ""
        case "StopFailure":
            session.state = .failed
            session.message = Self.failureMessage(fields["error"])
        case "SubagentStart":
            session.subagents += 1
        case "SubagentStop":
            session.subagents = max(0, session.subagents - 1)
        case "CwdChanged":
            if let cwd = fields["new_cwd"], !cwd.isEmpty { session.cwd = cwd }
        case "SessionEnd":
            session.ended = true
        default:
            break
        }
        sessions[event.sessionID] = session
    }

    /// Ended sessions, and any not heard from in a day whose process is gone, are let go.
    mutating func prune(now: Date = Date(), isAlive: (pid_t) -> Bool = HookSessions.isAlive) {
        sessions = sessions.filter { _, session in
            !session.ended && (isAlive(session.pid) || now.timeIntervalSince(session.updatedAt) < 24 * 3600 && session.pid <= 0)
        }
    }

    static func isAlive(_ pid: pid_t) -> Bool { pid > 0 && (kill(pid, 0) == 0 || errno == EPERM) }

    /// "Wants to run swift test", "Wants to edit Sources/App.swift", "Wants to use WebFetch".
    static func permissionMessage(_ fields: [String: String]) -> String {
        guard let tool = fields["tool_name"] else { return "" }
        if let command = fields["tool_input.command"] { return "Wants to run " + firstLine(command) }
        if let path = fields["tool_input.file_path"] {
            let verb = tool == "Write" ? "write" : tool == "Read" ? "read" : "edit"
            return "Wants to \(verb) " + (path as NSString).lastPathComponent
        }
        return "Wants to use " + tool
    }

    /// StopFailure's `error`, in words.
    static func failureMessage(_ error: String?) -> String {
        switch error {
        case "rate_limit"?: return "Hit a rate limit"
        case "overloaded"?: return "The service is overloaded"
        case "authentication_failed"?, "oauth_org_not_allowed"?: return "Couldn\u{2019}t sign in"
        case "billing_error"?, "account_on_hold"?: return "A billing problem stopped it"
        case "max_output_tokens"?: return "Ran out of room for its answer"
        case nil: return ""
        default: return "Stopped with an error"
        }
    }

    static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.trimmingCharacters(in: .whitespaces)
    }
}

/// Reads the hook's event files as they arrive, and on launch the ones written while Side wasn't
/// running, into `sessions`.
@MainActor
final class HookInbox {
    static let shared = HookInbox()
    static let didChangeNotification = Notification.Name("SideHookSessionsDidChange")

    private(set) var sessions = HookSessions()
    private var source: DispatchSourceFileSystemObject?
    private var timer: Timer?
    private var readScheduled = false

    /// Watches the folder, if there's anything to watch: hooks installed, or events waiting.
    func start() {
        guard source == nil, timer == nil else { return }
        let inbox = HookPaths.inbox
        let waiting = (try? FileManager.default.contentsOfDirectory(atPath: inbox.path))?.isEmpty == false
        let installed = ClaudeHooks.isInstalledAnywhere
        guard installed || waiting else { return }
        // The hook as this Side has it, after an update.
        if installed { HookPaths.installExecutable() }
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let fd = open(inbox.path, O_EVTONLY)
        if fd >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
            source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.scheduleRead() } }
            source.setCancelHandler { close(fd) }
            source.resume()
            self.source = source
        }
        // A missed write, and sessions whose process ended without saying so.
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.read() }
        }
        read()
    }

    func stop() {
        source?.cancel()
        source = nil
        timer?.invalidate()
        timer = nil
    }

    private func scheduleRead() {
        guard !readScheduled else { return }
        readScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.readScheduled = false
            self?.read()
        }
    }

    /// Every waiting event, oldest first, then the files go.
    func read() {
        let before = sessions
        let manager = FileManager.default
        let files = (try? manager.contentsOfDirectory(at: HookPaths.inbox, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles)) ?? []
        let events = files.filter { $0.pathExtension == "json" }.map { url in
            (url, (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast)
        }.sorted { ($0.1, $0.0.lastPathComponent) < ($1.1, $1.0.lastPathComponent) }
        for (url, _) in events {
            if let data = try? Data(contentsOf: url), let event = HookEvent.parse(data) {
                // Only a process still there: one gone by now (an event read late, or a helper
                // that ran the hook) would make the session look ended.
                let pid = Self.agentPID(fromHookParent: event.parentPID)
                sessions.apply(event, agentPID: HookSessions.isAlive(pid) ? pid : 0)
                attribute(event)
            }
            try? manager.removeItem(at: url)
        }
        sessions.prune()
        guard sessions != before else { return }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    /// An agent's edit, or a shell command's changes, into the files' records (phase 3).
    private func attribute(_ event: HookEvent) {
        let session = sessions.sessions[event.sessionID]
        let author = Author(kind: .session, sessionID: event.sessionID, agent: event.agent, request: session?.request.isEmpty == false ? session?.request : nil)
        if let edit = event.edit {
            Attribution.shared.record(edit.file, author: author, written: edit.written)
        }
        let changed = event.shellChanges
        guard !changed.isEmpty else { return }
        // A command's changes are its session's only when no other session was at work in the
        // same checkout then; otherwise they're shared.
        let checkout = event.cwd.flatMap { Attribution.checkout(of: URL(fileURLWithPath: $0).appendingPathComponent("x")) }
        let othersWorking = sessions.sessions.values.contains { other in
            guard other.id != event.sessionID, case .working = other.state, let cwd = other.cwd else { return false }
            return Attribution.checkout(of: URL(fileURLWithPath: cwd).appendingPathComponent("x")) == checkout
        }
        for file in changed { Attribution.shared.record(file, author: othersWorking ? Author(kind: .shared) : author, written: nil) }
    }

    /// For tests: the events as if the hook had written them.
    func applyForTesting(_ event: HookEvent, agentPID: pid_t) {
        sessions.apply(event, agentPID: agentPID)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    /// The agent's process: the hook's parent, or past the shell the agent ran it through.
    nonisolated static func agentPID(fromHookParent pid: pid_t) -> pid_t {
        var current = pid
        for _ in 0..<3 {
            guard current > 1, let info = bsdInfo(current) else { return pid }
            let name = withUnsafeBytes(of: info.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            guard ["sh", "bash", "zsh", "dash", "fish"].contains(name) else { return current }
            current = pid_t(info.pbi_ppid)
        }
        return current
    }

    nonisolated private static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }
}

/// Side's hooks in Claude Code's settings: put in, checked, taken out. Only Side's own entries
/// are touched; everything else in the file stays as it was, and the file as it was before is
/// kept beside it (`settings.json.side-backup`).
enum ClaudeHooks {
    /// What Side listens for. Never WorktreeCreate or WorktreeRemove: a hook there replaces
    /// Claude Code's own worktree handling. The few that mark a turn's state run in step with
    /// Claude Code (they're quick, and their order matters); the rest in the background.
    static let events: [(name: String, inStep: Bool)] = [
        ("SessionStart", true), ("UserPromptSubmit", true), ("PermissionRequest", true), ("Notification", true),
        ("Stop", true), ("StopFailure", true), ("SessionEnd", false), ("PostToolUse", false),
        ("PostToolUseFailure", false), ("SubagentStart", false), ("SubagentStop", false), ("CwdChanged", false),
    ]

    enum Status: Equatable {
        case notInstalled
        case installed
        /// Some of Side's hooks are gone (the file was rewritten): Settings offers to put them back.
        case incomplete
    }

    enum Failure: LocalizedError {
        case unreadable(URL)
        var errorDescription: String? {
            switch self {
            case .unreadable(let url): return "\((url.path as NSString).abbreviatingWithTildeInPath) isn\u{2019}t a settings file Side can read, so it was left alone."
            }
        }
    }

    /// `~/.claude`, or `CLAUDE_CONFIG_DIR` as Claude Code reads it; tests set their own.
    nonisolated(unsafe) static var configDirectory: URL = {
        // Under test, never the person's: a UI test's own (uitest.sh sets one), else a temporary one.
        if HookPaths.isUnderTest { return HookPaths.testRoot.appendingPathComponent("claude", isDirectory: true) }
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty { return URL(fileURLWithPath: dir, isDirectory: true) }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent(".claude", isDirectory: true)
    }()

    /// Every project's sessions (user-wide).
    static var userSettings: URL { configDirectory.appendingPathComponent("settings.json") }

    /// One project's, kept out of its repository (`.claude/settings.local.json`).
    static func projectSettings(_ project: URL) -> URL { project.appendingPathComponent(".claude/settings.local.json") }

    static var command: String { "\"\(HookPaths.executable.path)\" claude" }

    static func isSides(_ hook: Any) -> Bool {
        ((hook as? [String: Any])?["command"] as? String)?.contains("/bin/side-hook") == true
    }

    /// Projects installed for one at a time, remembered so Settings can list them.
    private static let projectsKey = "side.claude-hooks.projects"
    nonisolated(unsafe) static var defaults: UserDefaults = HookPaths.isUnderTest ? (UserDefaults(suiteName: "side.hooks.testing") ?? .standard) : .standard
    static var projects: [URL] {
        (defaults.stringArray(forKey: projectsKey) ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
            .filter { status(at: projectSettings($0)) != .notInstalled }
    }

    static var isInstalledAnywhere: Bool { status(at: userSettings) != .notInstalled || !projects.isEmpty }

    static func status(at url: URL) -> Status {
        guard let settings = try? read(url), let hooks = settings["hooks"] as? [String: Any] else { return .notInstalled }
        let present = events.filter { event in
            ((hooks[event.name] as? [[String: Any]]) ?? []).contains { (($0["hooks"] as? [Any]) ?? []).contains(where: isSides) }
        }
        if present.isEmpty { return .notInstalled }
        return present.count == events.count ? .installed : .incomplete
    }

    static func install(at url: URL, project: URL? = nil) throws {
        HookPaths.installExecutable()
        var settings = try read(url) ?? [:]
        var hooks = withoutSides(settings["hooks"] as? [String: Any] ?? [:])
        for event in events {
            var entry: [String: Any] = ["type": "command", "command": command, "timeout": 10]
            if !event.inStep { entry["async"] = true }
            hooks[event.name] = ((hooks[event.name] as? [[String: Any]]) ?? []) + [["hooks": [entry]]]
        }
        settings["hooks"] = hooks
        try write(settings, to: url)
        if let project {
            var list = defaults.stringArray(forKey: projectsKey) ?? []
            if !list.contains(project.path) { list.append(project.path) }
            defaults.set(list, forKey: projectsKey)
        }
    }

    static func remove(at url: URL) throws {
        guard var settings = try read(url) else { return }
        let hooks = withoutSides(settings["hooks"] as? [String: Any] ?? [:])
        if hooks.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = hooks }
        try write(settings, to: url)
    }

    /// The hooks with Side's entries taken out, and any event left with none.
    private static func withoutSides(_ hooks: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { result[event] = value; continue }
            let kept = groups.compactMap { group -> [String: Any]? in
                guard let list = group["hooks"] as? [Any] else { return group }
                let others = list.filter { !isSides($0) }
                if others.isEmpty { return nil }
                var group = group
                group["hooks"] = others
                return group
            }
            if !kept.isEmpty { result[event] = kept }
        }
        return result
    }

    /// Nil when there's no file; an error when there is one that isn't a JSON object.
    private static func read(_ url: URL) throws -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.unreadable(url) }
        return object
    }

    /// Through a symlink to the file itself (settings kept in a dotfiles repository stay linked),
    /// with its permissions kept.
    private static func write(_ settings: [String: Any], to url: URL) throws {
        let manager = FileManager.default
        let target = url.resolvingSymlinksInPath()
        try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let permissions = (try? manager.attributesOfItem(atPath: target.path))?[.posixPermissions] as? NSNumber
        if let original = try? Data(contentsOf: target) {
            try original.write(to: url.appendingPathExtension("side-backup"), options: .atomic)
        }
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try (data + Data("\n".utf8)).write(to: target, options: .atomic)
        if let permissions { chmod(target.path, mode_t(permissions.uint16Value)) }
    }
}
