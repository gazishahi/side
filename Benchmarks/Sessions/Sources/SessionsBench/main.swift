import Darwin
import Foundation
import SideSessionsKit
import SwiftTerm

// Usage: SessionsBench <path to a release SideSessionKeeper>
// Each measure runs through a keeper and, where there is one, against a direct PTY with no keeper.

setvbuf(stdout, nil, _IOLBF, 0)
guard CommandLine.arguments.count > 1 else { print("usage: SessionsBench <SideSessionKeeper>"); exit(2) }
let keeper = URL(fileURLWithPath: CommandLine.arguments[1])
let run = URL(fileURLWithPath: "/tmp/ssb-\(getpid())", isDirectory: true)
setenv("SIDE_SESSIONS_DIR", run.path, 1)
try? FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
var launched: [SessionRecord] = []
defer { cleanUp() }
func cleanUp() {
    for r in SessionPaths.records() { kill(r.childPID, SIGKILL); kill(r.keeperPID, SIGKILL) }
    try? FileManager.default.removeItem(at: run)
}

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
func median(_ xs: [Double]) -> Double { let s = xs.sorted(); return s[s.count / 2] }
func p95(_ xs: [Double]) -> Double { let s = xs.sorted(); return s[min(s.count - 1, s.count * 95 / 100)] }

// MARK: - Workloads

/// Lines of styled text, 200 columns wide, as a build log or an agent's transcript prints them.
func workload(lines: Int) -> URL {
    let url = run.appendingPathComponent("workload-\(lines).txt")
    if FileManager.default.fileExists(atPath: url.path) { return url }
    var out = ""
    out.reserveCapacity(lines * 220)
    let words = ["let", "value", "return", "func", "self", "error:", "warning", "0x7f3a", "→", "done", "build", "test"]
    var seed: UInt64 = 7
    for i in 0..<lines {
        var line = "\u{1b}[2m\(String(format: "%6d", i))\u{1b}[0m "
        while line.count < 190 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let w = words[Int(seed >> 33) % words.count]
            line += (seed >> 40) % 5 == 0 ? "\u{1b}[3\(Int(seed >> 50) % 7 + 1)m\(w)\u{1b}[0m " : "\(w) "
        }
        out += line + "\r\n"
    }
    try! out.write(to: url, atomically: true, encoding: .utf8)
    return url
}

// MARK: - A direct PTY (no keeper)

final class DirectPTY {
    let master: Int32
    let pid: pid_t
    init(_ argv: [String]) {
        var m: Int32 = 0, s: Int32 = 0
        var size = winsize(ws_row: 60, ws_col: 200, ws_xpixel: 0, ws_ypixel: 0)
        openpty(&m, &s, nil, nil, &size)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, s, 0)
        posix_spawn_file_actions_adddup2(&actions, s, 1)
        posix_spawn_file_actions_adddup2(&actions, s, 2)
        posix_spawn_file_actions_addclose(&actions, m)
        var cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        var cEnv: [UnsafeMutablePointer<CChar>?] = (["TERM=xterm-256color", "PATH=/usr/bin:/bin"] as [String]).map { strdup($0) } + [nil]
        var child: pid_t = 0
        posix_spawn(&child, argv[0], &actions, nil, &cArgs, &cEnv)
        close(s)
        master = m
        pid = child
    }
    func end() { kill(pid, SIGKILL); var st: Int32 = 0; waitpid(pid, &st, 0); close(master) }
}

// MARK: - A client of a keeper

final class Client: @unchecked Sendable {
    let connection: SessionConnection
    let lock = NSLock()
    var outputBytes = 0
    var output = [UInt8]()
    var keepOutput = false
    var snapshot: [UInt8]?
    var exited = false
    var lastOutputAt = 0.0
    var exitedAt = 0.0
    let signal = DispatchSemaphore(value: 0)

    init(_ id: String) throws {
        connection = try SessionConnection.connect(to: SessionPaths.socket(id))
        connection.start(queue: DispatchQueue(label: "bench.\(id)"), onFrame: { [weak self] frame in
            guard let self else { return }
            self.lock.lock()
            switch frame.kind {
            case .snapshot: self.snapshot = frame.payload
            case .output:
                self.outputBytes += frame.payload.count
                self.lastOutputAt = now()
                if self.keepOutput { self.output += frame.payload }
            case .exited: self.exited = true; self.exitedAt = now()
            default: break
            }
            self.lock.unlock()
            self.signal.signal()
        }, onClose: { [weak self] in self?.signal.signal() })
        connection.send(Frame(.hello, json: Hello(build: "bench")))
    }

    func wait(_ timeout: Double = 60, until condition: () -> Bool) -> Bool {
        let deadline = now() + timeout
        while true {
            lock.lock(); let done = condition(); lock.unlock()
            if done { return true }
            if now() > deadline { return false }
            _ = signal.wait(timeout: .now() + 0.05)
        }
    }

    func attach(history: Int? = nil) -> Bool {
        connection.send(Frame(.attach, json: Attach(cols: 200, rows: 60, history: history)))
        return wait { snapshot != nil }
    }
}

func launch(_ script: String) throws -> String {
    let id = SessionPaths.newID()
    try KeeperLauncher.launch(LaunchSpec(id: id, executable: "/bin/sh", arguments: ["-c", script], environment: ["TERM=xterm-256color", "PATH=/usr/bin:/bin"],
                                         directory: "/tmp", cols: 200, rows: 60), keeper: keeper)
    return id
}

func footprintMB(_ pid: pid_t) -> Double {
    var info = rusage_info_v4()
    _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) } }
    return Double(info.ri_phys_footprint) / 1_048_576
}

func cpuSeconds(_ pid: pid_t) -> Double {
    var info = rusage_info_v4()
    _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) } }
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    return Double(info.ri_user_time + info.ri_system_time) * Double(timebase.numer) / Double(timebase.denom) / 1e9
}

var results: [(String, String, String)] = []
func report(_ measure: String, _ value: String, _ target: String) {
    results.append((measure, value, target))
    print("\(measure): \(value)   (target \(target))")
}

// MARK: - 1. Keypress latency added by the keeper

do {
    let keys = 1000
    // The kernel's own echo (canonical mode): a key comes straight back, so this times only the
    // path a keystroke and its echo travel.
    let direct = DirectPTY(["/bin/sleep", "600"])
    var directTimes: [Double] = []
    var buf = [UInt8](repeating: 0, count: 256)
    usleep(100_000)
    for i in 0..<keys {
        let key: UInt8 = i % 100 == 99 ? 13 : 120
        let t0 = now()
        var k = key
        write(direct.master, &k, 1)
        var p = pollfd(fd: direct.master, events: Int16(POLLIN), revents: 0)
        poll(&p, 1, 1000)
        _ = read(direct.master, &buf, buf.count)
        directTimes.append((now() - t0) * 1000)
    }
    direct.end()

    let id = try launch("exec sleep 600")
    let client = try Client(id)
    _ = client.attach()
    var keeperTimes: [Double] = []
    for i in 0..<keys {
        let key: UInt8 = i % 100 == 99 ? 13 : 120
        client.lock.lock(); let before = client.outputBytes; client.lock.unlock()
        let t0 = now()
        client.connection.send(Frame(.input, [key]))
        guard client.wait(1, until: { client.outputBytes > before }) else {
            let alive = SessionPaths.records().map { "\($0.id) keeper alive \(kill($0.keeperPID, 0) == 0)" }
            print("  key \(i) wasn't echoed within a second; records: \(alive); run dir: \((try? FileManager.default.contentsOfDirectory(atPath: run.path)) ?? [])")
            exit(1)
        }
        keeperTimes.append((now() - t0) * 1000)
    }
    client.connection.close()
    let added = median(keeperTimes) - median(directTimes)
    print(String(format: "  direct echo: median %.3f ms, p95 %.3f ms · through a keeper: median %.3f ms, p95 %.3f ms", median(directTimes), p95(directTimes), median(keeperTimes), p95(keeperTimes)))
    report("Keypress latency added by the keeper (median)", String(format: "%.3f ms", added), "≤ 0.5 ms")
}

// MARK: - 2. Throughput through a keeper

do {
    let file = workload(lines: 150_000) // about 30 MB
    let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
    var directRates: [Double] = [], keeperRates: [Double] = []
    for _ in 0..<3 {
        let direct = DirectPTY(["/bin/cat", file.path])
        var buf = [UInt8](repeating: 0, count: 65536)
        let t0 = now()
        var directBytes = 0
        while true { let n = read(direct.master, &buf, buf.count); if n <= 0 { break }; directBytes += n }
        directRates.append(Double(size) / (now() - t0) / 1_048_576)
        direct.end()

        let id = try launch("read _; exec cat '\(file.path)'")
        let client = try Client(id)
        _ = client.attach()
        let keeperPID = SessionPaths.records().first { $0.id == id }!.keeperPID
        let keeperCPU0 = cpuSeconds(keeperPID), ourCPU0 = cpuSeconds(getpid())
        let t1 = now()
        client.connection.send(Frame(.input, [13]))
        _ = client.wait(120) { client.exited }
        let wall = client.lastOutputAt - t1
        keeperRates.append(Double(size) / wall / 1_048_576)
        print("    bytes: direct read \(directBytes), keeper delivered \(client.outputBytes)")
        print(String(format: "    run: to the last byte %.3f s (exit reported %.3f s after it) · keeper CPU %.3f s · client CPU %.3f s", wall, client.exitedAt - client.lastOutputAt, cpuSeconds(keeperPID) - keeperCPU0, cpuSeconds(getpid()) - ourCPU0))
        client.connection.close()
    }
    print(String(format: "  %.0f MB of styled text: direct %.0f MB/s · through a keeper %.0f MB/s", Double(size) / 1_048_576, median(directRates), median(keeperRates)))
    report("Throughput through a keeper, share of direct", String(format: "%.0f%%", median(keeperRates) / median(directRates) * 100), "≥ 90%")
}

// MARK: - 3–5. Six sessions with full scrollback: reattach, memory, idle CPU

do {
    let file = workload(lines: 10_500)
    var ids: [String] = []
    for _ in 0..<6 { ids.append(try launch("cat '\(file.path)'; exec sleep 600")) }
    // Wait for every keeper to have read it all and gone quiet.
    let deadline = now() + 30
    while now() < deadline, !SessionPaths.records().filter({ ids.contains($0.id) }).allSatisfy({ Date().timeIntervalSince($0.lastOutputAt) > 1.5 }) { usleep(200_000) }
    let records = SessionPaths.records().filter { ids.contains($0.id) }
    let full = records.map { footprintMB($0.keeperPID) }
    // Quiet for over five seconds: compression has run.
    sleep(8)
    let compressed = records.map { footprintMB($0.keeperPID) }

    // Reattach: connect, hello, attach, snapshot in hand, all six one after another, as a project
    // reopening does, with the 500 lines of history Side's terminal keeps.
    var snapshots: [[UInt8]] = []
    let t0 = now()
    for id in ids {
        let client = try Client(id)
        _ = client.attach(history: 500)
        client.lock.lock(); snapshots.append(client.snapshot ?? []); client.lock.unlock()
        client.connection.close()
    }
    let reattachMs = (now() - t0) * 1000
    // Today's SwiftTerm view replaying them: Side's main-thread cost until the tabs show.
    final class Quiet: TerminalDelegate { func send(source: Terminal, data: ArraySlice<UInt8>) {} }
    let quiet = Quiet()
    let t1 = now()
    for snapshot in snapshots {
        let term = Terminal(delegate: quiet, options: TerminalOptions(cols: 200, rows: 60, scrollback: 500))
        term.feed(buffer: snapshot[...])
    }
    let replayMs = (now() - t1) * 1000
    let cpuBefore = records.map { cpuSeconds($0.keeperPID) }
    sleep(10)
    let idleCPU = zip(records.map { cpuSeconds($0.keeperPID) }, cpuBefore).map { $0 - $1 }

    print(String(format: "  snapshots: %.2f MB each (500 of 10,000 lines of scrollback, as Side asks)", Double(snapshots.map(\.count).reduce(0, +)) / 6 / 1_048_576))
    report("Reattach, 6 sessions with full scrollback (keeper side)", String(format: "%.0f ms", reattachMs), "≤ 150 ms")
    report("Replaying those 6 snapshots into SwiftTerm (Side's main thread)", String(format: "%.0f ms", replayMs), "≤ 100 ms (added)")
    report("Keeper memory, full scrollback, before compression", String(format: "%.1f MB median", median(full)), "—")
    report("Keeper memory, full styled scrollback, compressed", String(format: "%.1f MB median", median(compressed)), "— (worst case: every fifth word colored)")
    report("Keeper CPU over 10 s idle", String(format: "%.1f ms median", median(idleCPU) * 1000), "0 (blocks on reads)")
}

do {
    // Plain text, as the RFC's memory target was set for.
    let plain = run.appendingPathComponent("plain.txt")
    let source = (try? String(contentsOfFile: "/Users/gazishahi/Documents/side/SIDE/SIDE/TerminalViewController.swift", encoding: .utf8)) ?? "plain text\n"
    var text = ""
    while text.utf8.count < 3_000_000 { text += source.replacingOccurrences(of: "\n", with: "\r\n") }
    try text.write(to: plain, atomically: true, encoding: .utf8)
    let id = try launch("cat '\(plain.path)'; exec sleep 600")
    sleep(2)
    let r = SessionPaths.records().first { $0.id == id }!
    let before = footprintMB(r.keeperPID)
    sleep(8)
    report("Keeper memory, full plain-text scrollback, compressed", String(format: "%.1f MB (%.1f MB before)", footprintMB(r.keeperPID), before), "≤ 4 MB")
}

do {
    let id = try launch("exec sleep 600")
    sleep(1)
    let record = SessionPaths.records().first { $0.id == id }!
    report("Keeper memory, idle, empty scrollback", String(format: "%.1f MB", footprintMB(record.keeperPID)), "≤ 2 MB")
}

print("\n| Measure | Result | Target |\n| --- | --- | --- |")
for (m, v, t) in results { print("| \(m) | \(v) | \(t) |") }
