import Foundation
import Darwin

/// What runs while Side is closed, for the menu bar (Helpers/SideNotifier, `--menu`): kept
/// terminals with something going on in them, and the Claude Code sessions in them.
///
/// Compiled into Side and into the notifier, so Foundation only. Side writes `AgentSnapshot`s as
/// it quits (it has read, and removed, every hook event until then); the helper reads the keepers'
/// records and the hook events written after, without removing them: Side reads those when it
/// opens again.
enum BackgroundSessions {
    // MARK: - What's read

    /// A keeper's record (`SessionRecord` in SideSessionsKit), as much of it as the menu needs.
    struct Keeper: Decodable, Equatable {
        struct Exit: Decodable, Equatable { var status: Int32? }
        struct Status: Decodable, Equatable {
            var id: String
            var state: String
            var title: String?
            var message: String?
            var app: String?
            var updatedAt: Date?
        }
        var id: String
        var keeperPID: Int32
        var childPID: Int32
        var executable: String
        var directory: String
        var client: [String: String]?
        var exit: Exit?
        var foreground: [String]?
        var programStatus: [Status]?

        static func read(_ url: URL) -> Keeper? {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return (try? Data(contentsOf: url)).flatMap { try? decoder.decode(Keeper.self, from: $0) }
        }

        /// Every record in the run directory, oldest file first.
        static func all(in run: URL) -> [Keeper] {
            let files = (try? FileManager.default.contentsOfDirectory(at: run, includingPropertiesForKeys: nil)) ?? []
            return files.filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasSuffix(".launch.json") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .compactMap(read)
        }

        /// The keeper is still running: by its own arguments, which name the session, not by its
        /// PID alone (`SessionKeepers.isRunning`).
        var isRunning: Bool {
            guard keeperPID > 0, kill(keeperPID, 0) == 0 else { return false }
            var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, keeperPID]
            var size = 0
            guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return false }
            var buffer = [UInt8](repeating: 0, count: size)
            guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return false }
            let arguments = String(decoding: buffer.prefix(size).map { $0 == 0 ? 10 : $0 }, as: UTF8.self)
            return arguments.contains("SideSessionKeeper") && arguments.contains("/\(id).launch.json")
        }

        var project: String {
            let path = client?["project"].flatMap { $0.isEmpty ? nil : $0 } ?? directory
            return (path as NSString).lastPathComponent
        }
    }

    // MARK: - Agents

    enum State: String, Codable, CaseIterable, Comparable {
        case needsYou, working, finished, failed
        /// The menu's order: what wants you first.
        static func < (a: State, b: State) -> Bool { allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)! }
        var word: String {
            switch self {
            case .needsYou: return "Needs You"
            case .working: return "Working"
            case .finished: return "Finished"
            case .failed: return "Failed"
            }
        }
    }

    /// A Claude Code session, as Side last knew it, then as the hook's events since have it.
    struct Agent: Codable, Equatable {
        var id: String
        /// The agent's process: how it's matched to the keeper whose shell runs it.
        var pid: Int32
        var state: State?
        var request: String
        var message: String
        var updatedAt: Date
        var ended = false
    }

    /// One hook event, applied as `HookSessions.apply` does in Side, for what the menu shows.
    static func apply(_ data: Data, to agents: inout [String: Agent], agentPID: (Int32) -> Int32) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let side = object["side"] as? [String: Any], let event = object["event"] as? [String: Any],
              let name = event["hook_event_name"] as? String, let id = event["session_id"] as? String, !id.isEmpty else { return }
        let at = Date(timeIntervalSince1970: (side["at"] as? NSNumber)?.doubleValue ?? 0)
        let pid = agentPID((side["ppid"] as? NSNumber)?.int32Value ?? 0)
        var agent = agents[id] ?? Agent(id: id, pid: pid, state: nil, request: "", message: "", updatedAt: at)
        if pid > 0 { agent.pid = pid }
        agent.updatedAt = max(agent.updatedAt, at)
        let input = event["tool_input"] as? [String: Any] ?? [:]
        switch name {
        case "SessionStart":
            agent.ended = false
            agent.state = nil
            agent.message = ""
        case "UserPromptSubmit":
            agent.state = .working
            agent.message = ""
            if let prompt = event["prompt"] as? String { agent.request = firstLine(prompt) }
        case "PostToolUse", "PostToolUseFailure":
            if agent.state == .needsYou { agent.message = "" }
            if agent.state != .finished, agent.state != .failed { agent.state = .working }
        case "PermissionRequest":
            agent.state = .needsYou
            if let command = input["command"] as? String { agent.message = "Wants to run " + firstLine(command) }
            else if let path = input["file_path"] as? String { agent.message = "Wants to edit " + (path as NSString).lastPathComponent }
            else if let tool = event["tool_name"] as? String { agent.message = "Wants to use " + tool }
        case "Notification":
            switch event["notification_type"] as? String ?? "" {
            case "permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input":
                agent.state = .needsYou
                if let message = event["message"] as? String { agent.message = message }
            case "idle_prompt", "agent_completed":
                if agent.state == .working { agent.state = .finished }
            default: break
            }
        case "Stop":
            agent.state = .finished
            agent.message = ""
        case "StopFailure":
            agent.state = .failed
            agent.message = "Stopped with an error"
        case "SessionEnd":
            agent.ended = true
        default: break
        }
        agents[id] = agent
    }

    static func firstLine(_ text: String) -> String {
        (text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "").trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Rows

    struct Row: Equatable {
        /// The keeper's session: `side://run/<id>` opens its tab.
        var id: String
        var project: String
        /// What it was asked, or the program running.
        var label: String
        /// Why it needs you, or what went wrong.
        var detail: String
        var state: State
        /// Since when it's needed you, or when it finished; nil while working.
        var since: Date?
    }

    /// Each keeper with something going on: its agent's state when one runs in it, else what its
    /// program says (OSC 7501), else the program in front. An idle shell isn't shown.
    /// `parent` gives a process's parent, for matching an agent to the shell it runs under.
    static func rows(keepers: [Keeper], agents: [Agent], parent: (Int32) -> Int32) -> [Row] {
        var rows: [Row] = []
        for keeper in keepers {
            // A shell that has ended: nothing runs there any more (its keeper waits for a tab to
            // show how it ended).
            guard keeper.exit == nil else { continue }
            let project = keeper.project
            let agent = agents.filter { !$0.ended && $0.state != nil && isDescendant($0.pid, of: keeper.childPID, parent: parent) }
                .max { $0.updatedAt < $1.updatedAt }
            if let agent, let state = agent.state {
                rows.append(Row(id: keeper.id, project: project, label: agent.request.isEmpty ? "Claude Code" : agent.request,
                                detail: state == .needsYou || state == .failed ? agent.message : "",
                                state: state, since: state == .working ? nil : agent.updatedAt))
                continue
            }
            if let status = keeper.programStatus?.first(where: { $0.id.isEmpty }), let state = Self.state(ofProgram: status.state) {
                let label = [status.title, status.app].compactMap { $0 }.first { !$0.isEmpty } ?? program(keeper.foreground ?? [], else: keeper.executable)
                rows.append(Row(id: keeper.id, project: project, label: label,
                                detail: state == .working ? "" : status.message ?? "", state: state,
                                since: state == .working ? nil : status.updatedAt))
                continue
            }
            if let foreground = keeper.foreground, !foreground.isEmpty {
                rows.append(Row(id: keeper.id, project: project, label: program(foreground, else: keeper.executable), detail: "", state: .working, since: nil))
            }
        }
        return rows.enumerated().sorted { ($0.element.state, $0.offset) < ($1.element.state, $1.offset) }.map(\.element)
    }

    static func state(ofProgram state: String) -> State? {
        switch state {
        case "working": return .working
        case "blocked": return .needsYou
        case "done": return .finished
        case "error": return .failed
        default: return nil
        }
    }

    /// "npm run dev": the program's name and its first few arguments.
    static func program(_ arguments: [String], else executable: String) -> String {
        guard let first = arguments.first else { return (executable as NSString).lastPathComponent }
        let words = [(first as NSString).lastPathComponent] + arguments.dropFirst().prefix(3)
        return words.joined(separator: " ")
    }

    static func isDescendant(_ pid: Int32, of ancestor: Int32, parent: (Int32) -> Int32) -> Bool {
        guard pid > 1, ancestor > 1 else { return false }
        var current = pid
        for _ in 0..<6 {
            current = parent(current)
            if current == ancestor { return true }
            if current <= 1 { return false }
        }
        return false
    }

    static func parent(of pid: Int32) -> Int32 {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? Int32(info.pbi_ppid) : 0
    }

    // MARK: - The icon

    /// What the icon shows: the most urgent state, and how many need you.
    static func summary(_ rows: [Row]) -> (state: State?, needsYou: Int) {
        (rows.map(\.state).min(), rows.filter { $0.state == .needsYou }.count)
    }

    /// "4m", "1h 12m", "2d".
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds) / 60)
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 24 * 60 { return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes / (24 * 60))d"
    }

    // MARK: - Side's part

    /// Side → Settings → General → Terminal: the menu bar's list while Side is closed (on by default).
    static let showKey = "side.menuBar.showRunning"

    /// Beside the run directory: `Application Support/Side/menu-bar.json`.
    static func snapshotURL(run: URL) -> URL { run.deletingLastPathComponent().appendingPathComponent("menu-bar.json") }

    static func writeSnapshot(_ agents: [Agent], to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(agents) else { return }
        try? data.write(to: url, options: .atomic)
        chmod(url.path, 0o600)
    }

    static func readSnapshot(_ url: URL) -> [Agent] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: url)).flatMap { try? decoder.decode([Agent].self, from: $0) } ?? []
    }
}

#if canImport(SideSessionsKit)
extension BackgroundSessions.State {
    /// A hook session's state in Side, as the menu has it; idle isn't shown.
    init?(_ state: SessionRegistry.State) {
        switch state {
        case .working: self = .working
        case .needsYou: self = .needsYou
        case .done: self = .finished
        case .failed: self = .failed
        case .idle: return nil
        }
    }
}
#endif
