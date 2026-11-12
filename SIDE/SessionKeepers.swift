import AppKit
import SideSessionsKit

/// Run's shells live in session keepers (SIDE_RFC_SESSION_RESTORE.md): a process per terminal,
/// outside Side, that owns the PTY and a copy of the screen. Closing a window or quitting detaches
/// from them; reopening the project attaches again, to the same running shells.
enum SessionKeepers {
    /// The keeper app in Side's bundle (`Contents/Helpers`, from the "Embed session keeper" build
    /// phase). An app, not a bare binary: a keeper outlives the Side that started it, so macOS's
    /// privacy settings see it, not Side, behind every command in its terminal, and an app's
    /// bundle identifier keeps a grant across updates (2026-11-07).
    static let bundledKeeperAppURL: URL? = {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(keeperAppName)")
        return FileManager.default.isExecutableFile(atPath: url.appendingPathComponent(keeperExecutablePath).path) ? url : nil
    }()
    static let keeperAppName = "Side Session Keeper.app"
    private static let keeperExecutablePath = "Contents/MacOS/SideSessionKeeper"

    /// The notifier app keepers run to post notifications (`Contents/Helpers/Side Notifier.app`).
    static let notifierURL: URL? = {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/Side Notifier.app/Contents/MacOS/Side Notifier")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }()

    /// What keepers run: a copy of the bundled app under the run directory, one per build.
    /// Never the bundle's own: a rebuild or an update that changes it in place makes the kernel
    /// kill every process running it (an invalid code page), which took every session with it
    /// (2026-11-03). A copy per build means a running keeper's files never change.
    static var keeperURL: URL? {
        guard let bundledApp = bundledKeeperAppURL else { return nil }
        // Checked each time: the run directory can be cleared while Side runs.
        if let installed = installedKeeper, FileManager.default.isExecutableFile(atPath: installed.path) { return installed }
        let bundled = bundledApp.appendingPathComponent(keeperExecutablePath)
        let attributes = try? FileManager.default.attributesOfItem(atPath: bundled.path)
        let size = (attributes?[.size] as? Int) ?? 0
        let modified = Int((attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        let dir = SessionPaths.runDirectory.appendingPathComponent("bin/\(size)-\(modified)", isDirectory: true)
        let copy = dir.appendingPathComponent(keeperAppName).appendingPathComponent(keeperExecutablePath)
        if !FileManager.default.isExecutableFile(atPath: copy.path) {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                // Copied beside it, then renamed into place: a reader never sees half an app.
                let temporary = dir.appendingPathComponent(".SideSessionKeeper.\(getpid()).app")
                try? FileManager.default.removeItem(at: temporary)
                try FileManager.default.copyItem(at: bundledApp, to: temporary)
                guard rename(temporary.path, dir.appendingPathComponent(keeperAppName).path) == 0 else { return bundled }
            } catch {
                return bundled
            }
        }
        installedKeeper = copy
        // Other builds' copies go once no keeper runs from them. A running program keeps the
        // file it opened, but macOS reads an app's signature and Info.plist from disk when it
        // checks a permission, so a running keeper's app stays where it is.
        let bin = dir.deletingLastPathComponent()
        let running = runningKeeperPaths()
        let realBin = realpath(bin.path, nil).map { defer { free($0) }; return String(cString: $0) } ?? bin.path
        for other in (try? FileManager.default.contentsOfDirectory(at: bin, includingPropertiesForKeys: nil)) ?? []
        where other.lastPathComponent != dir.lastPathComponent && !running.contains(where: { $0.hasPrefix(realBin + "/" + other.lastPathComponent + "/") }) {
            try? FileManager.default.removeItem(at: other)
        }
        return copy
    }

    /// The executables of this user's running processes under the run directory's `bin`.
    static func runningKeeperPaths() -> [String] {
        // The real path, as the kernel reports executables (`/tmp` is `/private/tmp`; Foundation's
        // own resolving drops the `/private`).
        let given = SessionPaths.runDirectory.appendingPathComponent("bin").path
        let bin = realpath(given, nil).map { defer { free($0) }; return String(cString: $0) } ?? given
        var pids = [pid_t](repeating: 0, count: 4096)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var paths: [String] = []
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(max(0, count)) where pid > 0 {
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
            let path = String(cString: buffer)
            if path.hasPrefix(bin + "/") { paths.append(path) }
        }
        return paths
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
        guard bundledKeeperAppURL != nil else { return false }
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

    /// Every live session for a project, any track, oldest first.
    static func liveRecords(project: String) -> [SessionRecord] {
        SessionPaths.records().filter { $0.client[Fact.project] == project && isRunning($0) }
    }

    /// Every ended, unfinished session for a project, any track, oldest first.
    static func endedRecords(project: String) -> [SessionRecord] {
        SessionPaths.records().filter { $0.client[Fact.project] == project && $0.exit == nil && !isRunning($0) }
    }

    /// How many sessions are live for a project, any track (the switcher's cards). A record can
    /// name the folder through a symlink, so both spellings count.
    static func liveCount(project: URL) -> Int {
        let wanted = Set([project.standardizedFileURL.path, project.resolvingSymlinksInPath().standardizedFileURL.path])
        return SessionPaths.records().filter { record in
            guard let path = record.client[Fact.project] else { return false }
            let url = URL(fileURLWithPath: path)
            return (wanted.contains(url.standardizedFileURL.path) || wanted.contains(url.resolvingSymlinksInPath().standardizedFileURL.path)) && isRunning(record)
        }.count
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
        guard let program = ForegroundProgram.name(arguments: foreground) else { return .nothing }
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

    /// Ends a session no tab shows: attached just long enough to end its whole process tree,
    /// as closing its tab would.
    @MainActor
    static func endSession(_ id: String) {
        guard let link = try? KeeperLink.connect(id) else { return }
        ending.append(link)
        link.attach(cols: 0, rows: 0, history: 0)
        link.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            link.detach()
            ending.removeAll { $0 === link }
        }
    }
    @MainActor private static var ending: [KeeperLink] = []

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

/// Which Claude Code conversation a running `claude` holds, from the file Claude Code keeps for
/// each of its processes (`<config>/sessions/<pid>.json`, its `sessionId`). Read, never
/// written; a Claude Code that no longer keeps the file just finds no duplicates.
///
/// Two tabs can end up on one conversation: a tab resumed while the conversation was still
/// running in another, or in a terminal no tab showed any more. Both then answered, and wrote
/// into the same transcript (the owner, 2026-11-05).
enum ClaudeConversations {
    static var sessionsDirectory: URL {
        let config = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        return config.appendingPathComponent("sessions")
    }

    /// The conversation the `claude` process `pid` holds.
    static func conversation(ofProcess pid: pid_t, in directory: URL = sessionsDirectory) -> String? {
        guard let data = FileManager.default.contents(atPath: directory.appendingPathComponent("\(pid).json").path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["pid"] as? NSNumber)?.int32Value == pid,
              let id = object["sessionId"] as? String, !id.isEmpty else { return nil }
        return id
    }

    /// The conversation of the Claude Code in the foreground of the terminal whose shell is
    /// `shell`, if that's what's running there.
    static func conversation(inShell shell: pid_t, in directory: URL = sessionsDirectory) -> String? {
        guard let group = ForegroundProgram.group(ofShell: shell),
              ForegroundProgram.name(arguments: ForegroundProgram.arguments(of: group)) == "claude" else { return nil }
        return conversation(ofProcess: group, in: directory)
    }

    /// Another of Side's terminals holding the conversation the terminal `keeperID` holds.
    struct Duplicate: Equatable {
        let conversation: String
        let otherKeeperID: String
    }

    static func duplicate(ofKeeper keeperID: String, records: [SessionRecord] = SessionPaths.records().filter(SessionKeepers.isRunning),
                          conversationInShell: (pid_t) -> String? = { conversation(inShell: $0) }) -> Duplicate? {
        guard let mine = records.first(where: { $0.id == keeperID }), mine.childPID > 0,
              let conversation = conversationInShell(mine.childPID) else { return nil }
        guard let other = records.first(where: { $0.id != keeperID && $0.childPID > 0 && conversationInShell($0.childPID) == conversation }) else { return nil }
        return Duplicate(conversation: conversation, otherKeeperID: other.id)
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
    /// What the program says it's doing (OSC 7501), every record, after any change.
    var onProgramStatus: (([ProgramStatusRecord]) -> Void)?
    /// The working directory the shell reported (OSC 7).
    var onPwd: ((String) -> Void)?
    var onExit: ((Exit) -> Void)?
    /// The connection ended without the keeper saying how the session ended: the keeper went
    /// away, dropped this client, or (`replaced`) another Side attached to the session.
    var onLost: ((_ replaced: Bool) -> Void)?

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
        // `events`: this Side reads program status and pwd frames (SIDE_RFC_SESSIONS.md).
        connection.send(Frame(.hello, json: Hello(build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "", events: true)))
        return link
    }

    /// `history`: the lines of scrollback this terminal keeps, so the keeper sends no more.
    ///
    /// A size of 0×0 is "keep yours" (a keeper ignores a size it can't use): a terminal not laid
    /// out yet attaches so, and attaches again with its real size once it has one, for a fresh
    /// snapshot at that size. Attached at SwiftTerm's 80×25 placeholder, the session was resized
    /// twice, and a prompt drawn to the right edge, and the cursor's row, came back wrong.
    func attach(cols: Int, rows: Int, history: Int) {
        attachHistory = history
        attachedUnsized = cols <= 0 || rows <= 0
        lastSize = attachedUnsized ? nil : Size(cols: cols, rows: rows)
        connection?.send(Frame(.attach, json: Attach(cols: max(cols, 0), rows: max(rows, 0), history: history)))
    }
    private var attachedUnsized = false
    private var attachHistory = 0

    func input<C: Collection>(_ bytes: C) where C.Element == UInt8 { connection?.send(Frame(.input, Array(bytes))) }

    func resize(cols: Int, rows: Int) {
        let size = Size(cols: cols, rows: rows)
        guard size != lastSize, cols > 0, rows > 0 else { return }
        // The first real size after attaching without one: attached again, so the screen comes
        // fresh at this size rather than reflowed into it.
        if attachedUnsized { return attach(cols: cols, rows: rows, history: attachHistory) }
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
    private var replaced = false

    private func received(_ frame: Frame) {
        switch frame.kind {
        case .welcome: record = frame.decode(Welcome.self)?.record ?? record
        case .snapshot: onSnapshot?(frame.payload)
        case .output: onOutput?(frame.payload[...])
        case .title: onTitle?(String(decoding: frame.payload, as: UTF8.self))
        case .attention: onAttention?()
        case .programStatus: onProgramStatus?(frame.decode([ProgramStatusRecord].self) ?? [])
        case .pwd: onPwd?(String(decoding: frame.payload, as: UTF8.self))
        case .exited:
            ended = true
            onExit?(frame.decode(Exit.self) ?? Exit(status: nil, signal: nil))
        case .replaced: replaced = true; closed()
        default: break
        }
    }

    private func closed() {
        connection = nil
        guard !ended else { return }
        let lost = onLost
        onLost = nil
        lost?(replaced)
    }
}
