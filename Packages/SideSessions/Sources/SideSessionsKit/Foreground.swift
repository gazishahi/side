import Darwin

/// The program in a terminal's foreground: its process group's leader, as the kernel has it.
/// The keeper asks with its PTY; Side asks with the shell's PID, so a Terminal tab is named by
/// what's actually running there rather than by what was typed (the owner, 2026-11-04: a tab
/// running Claude Code was named "claOC", and once a message was sent, after the message).
public enum ForegroundProgram {
    /// The foreground group of the terminal `shell` is attached to, or nil when that's the shell
    /// itself (at its prompt) or the shell is gone.
    public static func group(ofShell shell: pid_t) -> pid_t? {
        guard shell > 0, let info = processInfo(shell) else { return nil }
        let group = info.kp_eproc.e_tpgid
        guard group > 0, group != info.kp_eproc.e_pgid else { return nil }
        return group
    }

    /// A process's arguments, the executable's name first, or empty when it can't be read.
    public static func arguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        // argc, then the executable path, padding, then argc NUL-terminated arguments.
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = 4
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < Int(argc), index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }

    /// The name people know a program by: `claude` for `/opt/homebrew/bin/claude`, and for
    /// one run by an interpreter (an npm-installed Claude Code is `node …/bin/claude`) its
    /// script's.
    public static func name(arguments: [String]) -> String? {
        guard let first = arguments.first.map(lastComponent), !first.isEmpty else { return nil }
        let interpreters: Set<String> = ["node", "bun", "deno", "python", "python3", "ruby"]
        if interpreters.contains(first), let script = arguments.dropFirst().first(where: { !$0.hasPrefix("-") }) {
            return lastComponent(script)
        }
        return first
    }

    /// The foreground program's name for the terminal `shell` is attached to.
    public static func name(ofShell shell: pid_t) -> String? {
        group(ofShell: shell).flatMap { name(arguments: arguments(of: $0)) }
    }

    private static func lastComponent(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    private static func processInfo(_ pid: pid_t) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }
}
