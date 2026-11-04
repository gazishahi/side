import Foundation
import SideAgents

/// The person's running processes, to attach the debugger to (SIDE_RFC_DEBUGGER.md, Q3).
enum DebugProcesses {
    struct Entry: Equatable, Sendable {
        let pid: Int32
        let path: String
        var name: String { (path as NSString).lastPathComponent }
        /// Node attaches through js-debug (it opens Node's inspector); the rest through LLDB.
        var isNode: Bool { name == "node" || name == "nodejs" }
    }

    /// Their own, not the system's (a debugger can't take those, and they'd bury the list), and
    /// not Side itself. Sorted by name. Blocking: call off the main thread.
    nonisolated static func list(projectRoot: URL? = nil) -> [Entry] {
        let process = Process()
        process.environment = SpawnEnvironment.current()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-U", String(getuid()), "-o", "pid=,comm="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // `comm` is the path as the program was started (./tool); the system knows the real one.
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " "), let pid = Int32(trimmed[..<space]), let path = executablePath(pid) else { return trimmed }
            return "\(pid) \(path)"
        }
        return parse(lines.joined(separator: "\n"), excluding: getpid(), projectRoot: projectRoot.map { realPath($0.path) })
    }

    /// A process's executable, from the system (nil if it can't say).
    nonisolated static func executablePath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    /// `ps -o pid=,comm=` lines.
    /// The project's own programs first (what's built there), then the rest by name.
    nonisolated static func parse(_ output: String, excluding own: Int32, projectRoot: String? = nil) -> [Entry] {
        let systemPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/", "/usr/bin/", "/bin/"]
        // The iOS Simulator's own system, which runs as the person too.
        let systemParts = ["/RuntimeRoot/", "/CoreSimulator/"]
        return output.split(separator: "\n").compactMap { line -> Entry? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " "), let pid = Int32(trimmed[..<space]), pid != own else { return nil }
            let path = trimmed[space...].trimmingCharacters(in: .whitespaces)
            guard path.hasPrefix("/"), !systemPrefixes.contains(where: { path.hasPrefix($0) }),
                  !systemParts.contains(where: { path.contains($0) }) else { return nil }
            return Entry(pid: pid, path: path)
        }
        .sorted { a, b in
            let aOwn = projectRoot.map { realPath(a.path).hasPrefix($0 + "/") } ?? false
            let bOwn = projectRoot.map { realPath(b.path).hasPrefix($0 + "/") } ?? false
            if aOwn != bOwn { return aOwn }
            return (a.name.lowercased(), a.pid) < (b.name.lowercased(), b.pid)
        }
    }
}
