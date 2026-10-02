import Foundation

/// Ports for tracks that run at once. Every process Side starts for a track (its terminals, the
/// agent's commands, tasks, the debugger, an outside agent) gets `PORT` from the track's own
/// block of ten, so two tracks' dev servers don't both reach for 3000 (2026-10-02, the owner).
/// The main checkout keeps the usual ports. Keyed by folder: whatever starts inside a track's
/// folder is that track's.
public enum TrackPorts {
    public static let blockSize = 10
    public static let firstBase = 4100
    public static let lastBase = 8990

    public struct Block: Equatable, Sendable {
        public let base: Int
        public let trackName: String
        public var range: ClosedRange<Int> { base...(base + TrackPorts.blockSize - 1) }
        public init(base: Int, trackName: String) {
            self.base = base
            self.trackName = trackName
        }
    }

    private static let lock = NSLock()
    /// Project → (folder → block): each project's tracks, so two open projects don't replace
    /// each other's.
    nonisolated(unsafe) private static var blocksByProject: [String: [String: Block]] = [:]

    /// A project's tracks: folder → block. Replaces what that project had.
    public static func set(_ blocks: [String: Block], forProject project: String) {
        let normalized = Dictionary(blocks.map { (normalize($0.key), $0.value) }, uniquingKeysWith: { first, _ in first })
        lock.withLock { blocksByProject[project] = normalized }
    }

    /// Every base in use, by any open project's tracks.
    public static var takenBases: Set<Int> {
        lock.withLock { Set(blocksByProject.values.flatMap { $0.values.map(\.base) }) }
    }

    /// The block of the track whose folder holds `directory`, if any.
    public static func block(forDirectory directory: String) -> Block? {
        let path = normalize(directory)
        return lock.withLock {
            blocksByProject.values.lazy.compactMap { blocks in blocks.first { path == $0.key || path.hasPrefix($0.key + "/") }?.value }.first
        }
    }

    /// What a process started in `directory` adds to its environment: `PORT` (the block's
    /// first), `SIDE_PORT_BASE` and `SIDE_PORT_RANGE`. Empty outside a track's folder.
    public static func environment(forDirectory directory: String?) -> [String: String] {
        guard let directory, let block = block(forDirectory: directory) else { return [:] }
        return ["PORT": String(block.base), "SIDE_PORT_BASE": String(block.base),
                "SIDE_PORT_RANGE": "\(block.range.lowerBound)-\(block.range.upperBound)"]
    }

    /// A free block for a new track: not another track's, and none of its ports in use now.
    public static func freeBase(excluding taken: Set<Int>, isFree: (Int) -> Bool = TrackPorts.isFree) -> Int? {
        stride(from: firstBase, through: lastBase, by: blockSize).first { base in
            !taken.contains(base) && (base..<(base + blockSize)).allSatisfy(isFree)
        }
    }

    /// Nothing listening on `port` (a TCP bind to it succeeds).
    public static func isFree(_ port: Int) -> Bool {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { return false }
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr = in_addr(s_addr: INADDR_ANY)
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }

    /// For the agent's instructions: the ports a track's work should use.
    public static func promptSection(forDirectory directory: String) -> String? {
        guard let block = block(forDirectory: directory) else { return nil }
        return "This track runs alongside others, so it has its own ports: \(block.range.lowerBound)–\(block.range.upperBound). "
            + "Commands you run get PORT=\(block.base). Start servers on these ports (PORT, or a --port flag for tools that don't read it), not the usual defaults like 3000 or 8080, and use them in URLs you open or test."
    }

    private static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}

/// "Address already in use" in a command's output, explained: which port, and who holds it, so
/// the agent (and the person) can tell another track's server from a stale one.
public enum PortConflict {
    /// The port a "port in use" error names, from the usual wordings (Node, Vite, Python,
    /// Rails, Go, Docker).
    public static func port(in output: String) -> Int? {
        guard output.range(of: #"EADDRINUSE|[Aa]ddress already in use|[Pp]ort \d+ is (already )?in use|port is already allocated"#, options: .regularExpression) != nil else { return nil }
        let patterns = [
            #"EADDRINUSE[^\n]*?:(\d{2,5})\b"#,
            #"[Pp]ort (\d{2,5}) is (?:already )?in use"#,
            #"address already in use[^\n]*?[:\s](\d{2,5})\b"#,
            #"[Aa]ddress already in use[^\n]*?port (\d{2,5})"#,
            #":(\d{2,5})[^\n]*?(?:address already in use|port is already allocated)"#,
            #"bind[^\n]*?:(\d{2,5})[^\n]*?[Aa]ddress already in use"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
                  let range = Range(match.range(at: 1), in: output), let port = Int(output[range]), (1...65535).contains(port) else { continue }
            return port
        }
        return nil
    }

    /// What holds `port`: its process, and the track whose folder it runs in, if one.
    public static func holder(of port: Int) -> (pid: Int, command: String, track: String?)? {
        let listening = run("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpc"])
        var pid: Int?, command: String?
        for line in listening.split(separator: "\n") {
            if line.hasPrefix("p"), pid == nil { pid = Int(line.dropFirst()) }
            if line.hasPrefix("c"), command == nil { command = String(line.dropFirst()) }
        }
        guard let pid else { return nil }
        let cwd = run("/usr/sbin/lsof", ["-a", "-p", String(pid), "-d", "cwd", "-Fn"])
            .split(separator: "\n").first { $0.hasPrefix("n") }.map { String($0.dropFirst()) }
        return (pid, command ?? "a process", cwd.flatMap { TrackPorts.block(forDirectory: $0)?.trackName })
    }

    /// A tool's output (it's lsof, which answers at once), read before waiting.
    private static func run(_ executable: String, _ arguments: [String]) -> String {
        let process = Process()
        process.environment = SpawnEnvironment.current()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// A line to add to the command's output, or nil when it shows no port conflict.
    public static func explanation(for output: String, directory: String?) -> String? {
        guard let port = port(in: output) else { return nil }
        var text = "\n\n[Side: port \(port) is already in use"
        if let holder = holder(of: port) {
            text += " by \(holder.command) (pid \(holder.pid))"
            if let track = holder.track { text += ", running in the track \u{201C}\(track)\u{201D}" }
        }
        text += "."
        if let directory, let block = TrackPorts.block(forDirectory: directory) {
            text += " This track's ports are \(block.range.lowerBound)–\(block.range.upperBound); use PORT=\(block.base) or another in that range."
        }
        return text + "]"
    }
}
