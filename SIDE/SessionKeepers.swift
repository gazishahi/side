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

    /// A live session's record: its keeper answers on its socket.
    static func liveRecord(_ id: String) -> SessionRecord? {
        guard let record = SessionRecord.read(from: SessionPaths.record(id)), kill(record.keeperPID, 0) == 0 else { return nil }
        return record
    }

    /// Every live session for a project's track, oldest first.
    static func liveRecords(project: String, track: String) -> [SessionRecord] {
        SessionPaths.records().filter { $0.client[Fact.project] == project && $0.client[Fact.track] == track && kill($0.keeperPID, 0) == 0 }
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
