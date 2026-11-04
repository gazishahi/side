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

    public init(id: String, executable: String, arguments: [String], environment: [String], directory: String,
                cols: Int, rows: Int, scrollbackLines: Int = 10_000, client: [String: String] = [:]) {
        self.id = id
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.directory = directory
        self.cols = cols
        self.rows = rows
        self.scrollbackLines = scrollbackLines
        self.client = client
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

    /// Every session's record in the run directory, live or not.
    public static func records() -> [SessionRecord] {
        let files = (try? FileManager.default.contentsOfDirectory(at: runDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasSuffix(".launch.json") }
            .compactMap(SessionRecord.read(from:))
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Removes what a session left behind.
    public static func remove(_ id: String) {
        for url in [socket(id), record(id), launch(id)] { try? FileManager.default.removeItem(at: url) }
    }
}
