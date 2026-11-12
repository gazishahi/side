import Foundation

/// What to run and how: written by Side for a new keeper, read once and deleted by it.
public struct LaunchSpec: Codable, Sendable, Equatable {
    public var id: String
    public var executable: String
    public var arguments: [String]
    /// `KEY=value`, in order: the whole environment, not added to the keeper's own.
    public var environment: [String]
    public var directory: String
    public var cols: Int
    public var rows: Int
    public var scrollbackLines: Int
    /// Side's own facts about the session (project, track, tab, shell-integration nonce),
    /// carried in the record and given back on every attach. The keeper never reads them.
    public var client: [String: String]
    /// Start from this snapshot: the screen and scrollback a session had before a restart, with
    /// the new program's output following it.
    public var restoreFrom: String?
    /// Written between the restored screen and the new program's output.
    public var banner: String?
    /// The notifier app's executable, run (detached) to post a notification for this session
    /// while no client is attached. Nil: no notifications.
    public var notifier: String?
    /// How notifications name the session ("sill"): the project, by default its folder.
    public var place: String?

    public init(id: String, executable: String, arguments: [String], environment: [String], directory: String,
                cols: Int, rows: Int, scrollbackLines: Int = 10_000, client: [String: String] = [:],
                restoreFrom: String? = nil, banner: String? = nil, notifier: String? = nil, place: String? = nil) {
        self.id = id
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.directory = directory
        self.cols = cols
        self.rows = rows
        self.scrollbackLines = scrollbackLines
        self.client = client
        self.restoreFrom = restoreFrom
        self.banner = banner
        self.notifier = notifier
        self.place = place
    }
}

/// A session as its keeper last described it, in `<id>.json` beside its socket.
public struct SessionRecord: Codable, Sendable, Equatable {
    public var id: String
    public var keeperPID: Int32
    public var childPID: Int32
    /// The PTY's device (`/dev/ttys012`): a debugger points a program at it.
    public var tty: String
    public var executable: String
    public var arguments: [String]
    public var directory: String
    public var client: [String: String]
    /// The program's latest title (OSC 0/2); empty when none.
    public var title: String
    public var createdAt: Date
    public var lastOutputAt: Date
    public var exit: Exit?
    public var protocolVersion: Int
    /// The foreground program's arguments when the record was written (empty when the shell
    /// itself is): what to resume or re-run after a restart.
    public var foreground: [String] = []
    /// The working directory the shell last reported (OSC 7); empty when none.
    public var pwd: String = ""
    /// What the program says it's doing (OSC 7501), for a client that wasn't attached.
    public var programStatus: [ProgramStatusRecord] = []

    public init(id: String, keeperPID: Int32, childPID: Int32, tty: String = "", executable: String, arguments: [String], directory: String,
                client: [String: String], title: String = "", createdAt: Date, lastOutputAt: Date, exit: Exit? = nil,
                protocolVersion: Int = SessionProtocol.version) {
        self.id = id
        self.keeperPID = keeperPID
        self.childPID = childPID
        self.tty = tty
        self.executable = executable
        self.arguments = arguments
        self.directory = directory
        self.client = client
        self.title = title
        self.createdAt = createdAt
        self.lastOutputAt = lastOutputAt
        self.exit = exit
        self.protocolVersion = protocolVersion
    }

    private enum CodingKeys: String, CodingKey {
        case id, keeperPID, childPID, tty, executable, arguments, directory, client, title, createdAt, lastOutputAt, exit, protocolVersion, foreground, pwd, programStatus
    }

    /// Fields added after phase 1 are optional on disk, so an older keeper's record still reads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        keeperPID = try c.decode(Int32.self, forKey: .keeperPID)
        childPID = try c.decode(Int32.self, forKey: .childPID)
        tty = try c.decodeIfPresent(String.self, forKey: .tty) ?? ""
        executable = try c.decode(String.self, forKey: .executable)
        arguments = try c.decode([String].self, forKey: .arguments)
        directory = try c.decode(String.self, forKey: .directory)
        client = try c.decodeIfPresent([String: String].self, forKey: .client) ?? [:]
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        lastOutputAt = try c.decode(Date.self, forKey: .lastOutputAt)
        exit = try c.decodeIfPresent(Exit.self, forKey: .exit)
        protocolVersion = try c.decodeIfPresent(Int.self, forKey: .protocolVersion) ?? 1
        foreground = try c.decodeIfPresent([String].self, forKey: .foreground) ?? []
        pwd = try c.decodeIfPresent(String.self, forKey: .pwd) ?? ""
        programStatus = try c.decodeIfPresent([ProgramStatusRecord].self, forKey: .programStatus) ?? []
    }

    /// Written to a temporary file and renamed into place, so a reader never sees half a record.
    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: url, options: [.atomic])
        chmod(url.path, 0o600)
    }

    public static func read(from url: URL) -> SessionRecord? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: url)).flatMap { try? decoder.decode(SessionRecord.self, from: $0) }
    }
}

/// Where sessions live: `~/Library/Application Support/Side/run/`, readable only by the user.
public enum SessionPaths {
    /// `SIDE_SESSIONS_DIR` overrides it, for tests.
    public static var runDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["SIDE_SESSIONS_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return support.appendingPathComponent("Side/run", isDirectory: true)
    }

    @discardableResult
    public static func ensureRunDirectory() throws -> URL {
        let dir = runDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(dir.path, 0o700)
        // Terminal contents stay off backups: they're saved for a restart, nothing more.
        var excluded = dir
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)
        return dir
    }

    /// Sixteen hex characters: unique enough, and short, since a socket path is limited to 103
    /// bytes and the run directory sits under the user's home.
    public static func newID() -> String {
        (0..<8).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    public static func socket(_ id: String) -> URL { runDirectory.appendingPathComponent("\(id).sock") }
    public static func record(_ id: String) -> URL { runDirectory.appendingPathComponent("\(id).json") }
    public static func launch(_ id: String) -> URL { runDirectory.appendingPathComponent("\(id).launch.json") }
    /// The session's screen and scrollback, saved for a restart (on by default; see the RFC's
    /// "Snapshots on disk" for the protections).
    public static func snapshot(_ id: String) -> URL { runDirectory.appendingPathComponent("\(id).snap") }

    /// Every session's record in the run directory, live or not.
    public static func records() -> [SessionRecord] {
        let files = (try? FileManager.default.contentsOfDirectory(at: runDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasSuffix(".launch.json") }
            .compactMap(SessionRecord.read(from:))
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Removes what a session left behind.
    public static func remove(_ id: String) {
        for url in [socket(id), record(id), launch(id), snapshot(id), runDirectory.appendingPathComponent("\(id).log")] {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
