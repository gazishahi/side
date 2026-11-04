import AppKit
import SideSessionsKit

/// Run's shells live in session keepers (SIDE_RFC_SESSION_RESTORE.md): a process per terminal,
/// outside Side, that owns the PTY and a copy of the screen. Closing a window or quitting detaches
/// from them; reopening the project attaches again, to the same running shells.
enum SessionKeepers {
    /// The keeper in the app bundle (`Contents/Helpers`, from the "Embed session keeper" build
    /// phase).
    static let bundledKeeperURL: URL? = {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/SideSessionKeeper")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }()

    /// What keepers run: a copy of the bundled one under the run directory, one per build.
    /// Never the bundle's own file: a rebuild or an update that changes it in place makes the
    /// kernel kill every process running it (an invalid code page), which took every session
    /// with it (2026-11-03). A copy per build means a running keeper's file never changes.
    static var keeperURL: URL? {
        guard let bundled = bundledKeeperURL else { return nil }
        // Checked each time: the run directory can be cleared while Side runs.
        if let installed = installedKeeper, FileManager.default.isExecutableFile(atPath: installed.path) { return installed }
        let attributes = try? FileManager.default.attributesOfItem(atPath: bundled.path)
        let size = (attributes?[.size] as? Int) ?? 0
        let modified = Int((attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        let dir = SessionPaths.runDirectory.appendingPathComponent("bin/\(size)-\(modified)", isDirectory: true)
        let copy = dir.appendingPathComponent("SideSessionKeeper")
        if !FileManager.default.isExecutableFile(atPath: copy.path) {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                // Copied beside it, then renamed into place: a reader never sees half a file.
                let temporary = dir.appendingPathComponent(".SideSessionKeeper.\(getpid())")
                try? FileManager.default.removeItem(at: temporary)
                try FileManager.default.copyItem(at: bundled, to: temporary)
                guard rename(temporary.path, copy.path) == 0 else { return bundled }
            } catch {
                return bundled
            }
        }
        installedKeeper = copy
        // Other builds' copies go: deleting a running program's file is safe (it keeps the file
        // it opened); only changing one in place isn't.
        let bin = dir.deletingLastPathComponent()
        for other in (try? FileManager.default.contentsOfDirectory(at: bin, includingPropertiesForKeys: nil)) ?? [] where other.lastPathComponent != dir.lastPathComponent {
            try? FileManager.default.removeItem(at: other)
        }
        return copy
    }
    nonisolated(unsafe) private static var installedKeeper: URL?

    /// Settings → General → Run: "Keep terminals running when Side quits" (on unless turned
    /// off). Off, quitting or closing a project ends its shells, as before keepers; shells still
    /// live in keepers either way, so a session left running always reattaches and can be ended.
    static let keepRunningKey = "side.run.keepSessions"

    /// Settings → General → Run: ask before closing a tab with something running in it.
    static let confirmCloseKey = "side.run.confirmCloseRunning"

    static var confirmsClosingRunning: Bool {
        get { UserDefaults.standard.object(forKey: confirmCloseKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: confirmCloseKey) }
    }

    static var keepsRunningOnQuit: Bool {
        get { UserDefaults.standard.object(forKey: keepRunningKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: keepRunningKey) }
    }

    /// Unit tests get the old in-process terminals unless a test turns keepers on: a test's
    /// shells must end with it, not outlive the run.
    nonisolated(unsafe) static var enabledForTesting = false

    static var isEnabled: Bool {
        guard bundledKeeperURL != nil else { return false }
        if NSClassFromString("XCTestCase") != nil { return enabledForTesting }
        return true
    }

    /// A live session's record: its keeper is running. Checked by the process's own arguments
    /// (which carry the session's id), not by its PID alone, which after a restart can belong to
    /// anything, and not by connecting, which a keeper takes as a client taking over.
    static func liveRecord(_ id: String) -> SessionRecord? {
        guard let record = SessionRecord.read(from: SessionPaths.record(id)), isRunning(record) else { return nil }
        return record
    }

    /// A session whose keeper is gone (a restart, or a crash) but whose record is still there:
    /// one to recover.
    static func endedRecord(_ id: String) -> SessionRecord? {
        guard let record = SessionRecord.read(from: SessionPaths.record(id)), record.exit == nil, !isRunning(record) else { return nil }
        return record
    }

    static func isRunning(_ record: SessionRecord) -> Bool {
        guard record.keeperPID > 0, kill(record.keeperPID, 0) == 0 else { return false }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, record.keeperPID]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return false }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return false }
        let arguments = String(decoding: buffer.prefix(size).map { $0 == 0 ? 10 : $0 }, as: UTF8.self)
        return arguments.contains("SideSessionKeeper") && arguments.contains("/\(record.id).launch.json")
    }

    /// Every live session for a project's track, oldest first.
    static func liveRecords(project: String, track: String) -> [SessionRecord] {
        SessionPaths.records().filter { $0.client[Fact.project] == project && $0.client[Fact.track] == track && isRunning($0) }
    }

    /// Every ended, unfinished session for a project's track, oldest first.
    static func endedRecords(project: String, track: String) -> [SessionRecord] {
        SessionPaths.records().filter { $0.client[Fact.project] == project && $0.client[Fact.track] == track && $0.exit == nil && !isRunning($0) }
    }

    /// Ends a session with no tab open on it, as closing its tab would: SIGTERM to the whole tree,
    /// SIGHUP to the shell (which ignores SIGTERM when interactive). The keeper sees its child
    /// end and goes.
    static func end(_ record: SessionRecord) {
        var targets = [record.childPID]
        var frontier = [record.childPID]
        while let pid = frontier.popLast() {
            var children = [pid_t](repeating: 0, count: 512)
            let bytes = proc_listchildpids(pid, &children, Int32(children.count * MemoryLayout<pid_t>.size))
            for child in children.prefix(max(0, Int(bytes))) where child > 0 { targets.append(child); frontier.append(child) }
        }
        for pid in targets where pid > 0 { kill(pid, SIGTERM) }
        if record.childPID > 0 { kill(record.childPID, SIGHUP) }
        // No tab will come to hear how it ended (a keeper waits a day for one): once the shell
        // is gone, the keeper and the session's files go too.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if isRunning(record) { kill(record.keeperPID, SIGKILL) }
            SessionPaths.remove(record.id)
        }
    }

    // MARK: - After a restart

    /// The line between a recovered screen and the new shell.
    static let restartBanner = "\u{2500}\u{2500} Restored after a restart \u{2500}\u{2500}"

    /// Programs that are safe to start again by themselves in a recovered tab: editors, pagers,
    /// watchers (the RFC's list). Anything else is offered, never run unasked: re-running an
    /// arbitrary command could deploy something or delete files twice.
    static let rerunnable: Set<String> = ["vim", "nvim", "vi", "less", "more", "man", "top", "htop", "btop", "tail", "watch", "lazygit", "tig"]

    /// Agent CLIs without an exact session id from Side: each resumes the latest session in the
    /// directory, which is the tab's own unless two tabs ran the same agent in one folder. Claude
    /// is resumed exactly (the `claude` wrapper reports its id) and isn't here.
    static let resumeLatest: [String: String] = [
        "opencode": "opencode --continue",
        "codex": "codex resume --last",
    ]

    /// What a recovered tab does once its new shell is ready.
    enum Recovery: Equatable {
        case nothing
        /// Typed into the new shell.
        case run(String)
        /// Shown with a Run Again button.
        case offer(String)
    }

    /// `foreground`: the program that was running (the record's), `agentSession`: its agent's own
    /// session id, when the `claude` wrapper reported one.
    static func recovery(foreground: [String], agentSession: String?, hasTranscript: (String) -> Bool = claudeTranscriptExists) -> Recovery {
        guard let program = foreground.first.map({ ($0 as NSString).lastPathComponent }) else { return .nothing }
        if ["zsh", "-zsh", "bash", "-bash", "sh", "fish", "login"].contains(program) { return .nothing }
        if program == "claude" {
            guard let session = agentSession else { return .run("claude --continue") } // the directory's latest
            // A session nothing was typed into never wrote a transcript, and has nothing to
            // resume: it starts fresh under the same id, so a later restart still finds it.
            return .run(hasTranscript(session) ? "claude --resume \(session)" : "claude --session-id \(session)")
        }
        if let resume = resumeLatest[program] { return .run(resume) }
        let line = foreground.map(shellQuoted).joined(separator: " ")
        return rerunnable.contains(program) ? .run(line) : .offer(line)
    }

    /// Whether Claude Code has a transcript for `session`: `<config>/projects/*/<session>.jsonl`,
    /// with the config directory `CLAUDE_CONFIG_DIR` or `~/.claude`. Only looked at, never read.
    static func claudeTranscriptExists(_ session: String) -> Bool {
        let config = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        let projects = config.appendingPathComponent("projects")
        let folders = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        return folders.contains { FileManager.default.fileExists(atPath: $0.appendingPathComponent("\(session).jsonl").path) }
    }

    static func shellQuoted(_ word: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./=:,+@%"))
        if !word.isEmpty, word.unicodeScalars.allSatisfy(safe.contains) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Side's own facts in a session's record.
    enum Fact {
        static let project = "project"
        static let track = "track"
        static let nonce = "nonce"
        /// "rc" (zsh's ZDOTDIR wrapper), "typed" (bash), or "none".
        static let integration = "integration"
    }
}

/// One terminal's connection to its keeper. Everything is delivered on the main actor, in order.
@MainActor
final class KeeperLink {
    let id: String
    private(set) var record: SessionRecord?
    private var connection: SessionConnection?
    private var lastSize: Size?

    var onSnapshot: (([UInt8]) -> Void)?
    var onOutput: ((ArraySlice<UInt8>) -> Void)?
    var onTitle: ((String) -> Void)?
    var onAttention: (() -> Void)?
    var onExit: ((Exit) -> Void)?
    /// The keeper went away without saying how the session ended, or another Side took it.
    var onLost: (() -> Void)?

    private init(id: String) { self.id = id }

    /// A new session: starts its keeper, then connects.
    static func launch(_ spec: LaunchSpec) throws -> KeeperLink {
        guard let keeper = SessionKeepers.keeperURL else { throw SessionError.keeperDidNotStart("No keeper in the app bundle.") }
        try KeeperLauncher.launch(spec, keeper: keeper)
        return try connect(spec.id)
    }

    /// An existing session.
    static func connect(_ id: String) throws -> KeeperLink {
        let link = KeeperLink(id: id)
        let connection = try SessionConnection.connect(to: SessionPaths.socket(id))
        link.connection = connection
        link.record = SessionRecord.read(from: SessionPaths.record(id))
        connection.start(queue: DispatchQueue(label: "side.keeper.\(id)"), onFrame: { [weak link] frame in
            DispatchQueue.main.async { MainActor.assumeIsolated { link?.received(frame) } }
        }, onClose: { [weak link] in
            DispatchQueue.main.async { MainActor.assumeIsolated { link?.closed() } }
        })
        connection.send(Frame(.hello, json: Hello(build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")))
        return link
    }

    /// `history`: the lines of scrollback this terminal keeps, so the keeper sends no more.
    func attach(cols: Int, rows: Int, history: Int) {
        lastSize = Size(cols: cols, rows: rows)
        connection?.send(Frame(.attach, json: Attach(cols: cols, rows: rows, history: history)))
    }

    func input<C: Collection>(_ bytes: C) where C.Element == UInt8 { connection?.send(Frame(.input, Array(bytes))) }

    func resize(cols: Int, rows: Int) {
        let size = Size(cols: cols, rows: rows)
        guard size != lastSize, cols > 0, rows > 0 else { return }
        lastSize = size
        connection?.send(Frame(.resize, json: size))
    }

    /// The session's whole process tree, background jobs included: SIGTERM to every process,
    /// and SIGHUP to the shell, which is what closing a terminal sends it. An interactive shell
    /// ignores SIGTERM, and a keeper's PTY doesn't close when the tab does.
    func terminate() {
        connection?.send(Frame(.signal, json: SignalRequest(signal: SIGTERM, wholeTree: true)))
        connection?.send(Frame(.signal, json: SignalRequest(signal: SIGHUP, wholeTree: false)))
    }

    /// Let go; the session keeps running.
    func detach() {
        onLost = nil
        connection?.send(Frame(.detach))
        connection?.close()
        connection = nil
    }

    private var ended = false

    private func received(_ frame: Frame) {
        switch frame.kind {
        case .welcome: record = frame.decode(Welcome.self)?.record ?? record
        case .snapshot: onSnapshot?(frame.payload)
        case .output: onOutput?(frame.payload[...])
        case .title: onTitle?(String(decoding: frame.payload, as: UTF8.self))
        case .attention: onAttention?()
        case .exited:
            ended = true
            onExit?(frame.decode(Exit.self) ?? Exit(status: nil, signal: nil))
        case .replaced: closed()
        default: break
        }
    }

    private func closed() {
        connection = nil
        guard !ended else { return }
        let lost = onLost
        onLost = nil
        lost?()
    }
}
