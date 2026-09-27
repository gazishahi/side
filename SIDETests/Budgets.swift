import AppKit
import MachO
import XCTest

/// Every performance budget Side holds itself to, in one table (SIDE_RFC_FIND_REVIEW_TRACKS.md,
/// step 6). The budget tests measure and call `Budgets.check`, which prints a row and fails
/// the test past the limit; `scripts/budgets.sh` runs them all, optimized, and prints the table.
///
/// Opt-in: they're slow and depend on the machine. `SIDE_BUDGETS=1` in the test's environment
/// (`TEST_RUNNER_SIDE_BUDGETS=1` through xcodebuild).
enum Budgets {
    struct Row {
        let id: String
        let area: String
        let measure: String
        let limit: Double
        let unit: String
    }

    static let table: [Row] = [
        // Make's editor (SIDE_RFC_ALLOY.md).
        Row(id: "editor.open.swift", area: "Make", measure: "Open a 100k-line Swift file to first paint", limit: 50, unit: "ms"),
        Row(id: "editor.open.log", area: "Make", measure: "Open a 20 MB log to first paint", limit: 150, unit: "ms"),
        Row(id: "editor.keystroke", area: "Make", measure: "Keystroke to frame, main thread, p99", limit: 8, unit: "ms"),
        Row(id: "editor.recolor", area: "Make", measure: "Recolor the edited line, p99", limit: 2, unit: "ms"),
        Row(id: "editor.scroll.cpu", area: "Make", measure: "Scrolling: a frame's CPU, p99, as a share of the frame", limit: 50, unit: "%"),
        Row(id: "editor.scroll.missed", area: "Make", measure: "Scrolling: frames missed beyond drawing nothing", limit: 0.5, unit: "%"),
        Row(id: "editor.memory.log", area: "Make", measure: "Memory for a 20 MB log (3x the file, plus the atlas)", limit: 92, unit: "MB"),
        Row(id: "editor.agentEdits", area: "Make", measure: "An agent's whole-file edit, applied and drawn, p99", limit: 16.7, unit: "ms"),
        Row(id: "editor.foldRegions", area: "Make", measure: "A 100k-line file's foldable regions (off the main thread)", limit: 500, unit: "ms"),
        Row(id: "editor.foldAll", area: "Make", measure: "Fold All in a 100k-line file", limit: 50, unit: "ms"),
        Row(id: "editor.minimap", area: "Make", measure: "Drawing the minimap while scrolling, p99", limit: 4, unit: "ms"),
        Row(id: "completion.filter", area: "Make", measure: "Completion: re-ranking 6,000 items for a keystroke, p99", limit: 8, unit: "ms"),
        Row(id: "completion.sync", area: "Make", measure: "A keystroke's edit to the language server, 100k-line file, p99", limit: 1, unit: "ms"),
        Row(id: "hover.show", area: "Make", measure: "Hover: a large doc and two problems, shown, p99 (card made)", limit: 5, unit: "ms"),
        Row(id: "signature.show", area: "Make", measure: "Signature help: two signatures, shown, p99", limit: 5, unit: "ms"),
        Row(id: "problems.open", area: "Make", measure: "Show Problems with 5,000 problems in 250 files", limit: 50, unit: "ms"),
        Row(id: "find.matches", area: "Make", measure: "Find: every match in a 100k-line file", limit: 50, unit: "ms"),
        Row(id: "find.next", area: "Make", measure: "Find: to the next match, p99", limit: 8, unit: "ms"),
        // Make's debugger (SIDE_RFC_DEBUGGER.md, D6).
        Row(id: "debug.step", area: "Make", measure: "Debugger: a step, the stopped event to the line shown and the stack filled, median", limit: 50, unit: "ms"),
        Row(id: "debug.variables", area: "Make", measure: "Debugger: the first page of a 100,000-element array", limit: 30, unit: "ms"),
        Row(id: "debug.idle.cpu", area: "Make", measure: "Debugger: paused, CPU", limit: 0.5, unit: "%"),
        Row(id: "debug.breakpoints", area: "Make", measure: "Debugger: 1,000 breakpoints following a keystroke's edit, median", limit: 1, unit: "ms"),
        // Review.
        Row(id: "review.open", area: "Review", measure: "Show a 500-file change set", limit: 300, unit: "ms"),
        Row(id: "review.memory", area: "Review", measure: "Memory for a 500-file change set, drawing buffers apart", limit: 60, unit: "MB"),
        Row(id: "review.scroll", area: "Review", measure: "Scrolling a 500-file change set, a frame, p99", limit: 8.3, unit: "ms"),
        // Think.
        Row(id: "think.memory", area: "Think", measure: "A 200-turn conversation on screen, the view's memory", limit: 60, unit: "MB"),
        Row(id: "think.cpu", area: "Think", measure: "Streaming with the transcript on screen, a core", limit: 25, unit: "%"),
        // The app as a whole, launched and driven as a person would.
        Row(id: "app.idle.memory", area: "App", measure: "Idle in the background with files open", limit: 80, unit: "MB"),
        Row(id: "app.idle.cpu", area: "App", measure: "Idle in the background, CPU", limit: 0.5, unit: "%"),
        Row(id: "app.idle.wakeups", area: "App", measure: "Idle in the background, wakeups (the median second)", limit: 2, unit: "/s"),
        Row(id: "app.stages.peak", area: "App", measure: "Through every stage and a Markdown preview, peak", limit: 300, unit: "MB"),
        Row(id: "app.stages.settled", area: "App", measure: "Through every stage, then 40 s in the background", limit: 120, unit: "MB"),
    ]

    static var enabled: Bool { ProcessInfo.processInfo.environment["SIDE_BUDGETS"] == "1" }

    static func skipUnlessEnabled() throws {
        try XCTSkipUnless(enabled, "set SIDE_BUDGETS=1 to measure")
        // Measured without Xcode's diagnostic layers, or it isn't the app being measured.
        let loaded = (0..<_dyld_image_count()).contains { String(cString: _dyld_get_image_name($0)).contains("libMainThreadChecker") }
        if loaded { print("BUDGETNOTE the Main Thread Checker is loaded: UI costs read high") }
    }

    /// Prints the row with its measurement and fails the test past the limit. `detail` is the
    /// numbers behind it (each run, the percentiles). `limit` overrides the table's for a
    /// budget that depends on the machine (a frame's length).
    static func check(_ id: String, _ value: Double, detail: String = "", limit override: Double? = nil, file: StaticString = #filePath, line: UInt = #line) {
        guard let row = table.first(where: { $0.id == id }) else {
            XCTFail("no budget \(id) in Budgets.table", file: file, line: line)
            return
        }
        let limit = override ?? row.limit
        let passed = value <= limit
        let shown = String(format: value < 10 ? "%.2f" : "%.0f", value)
        let bound = String(format: limit < 10 ? "%.2f" : "%.0f", limit)
        print("BUDGET\t\(passed ? "ok  " : "OVER")\t\(row.area)\t\(row.measure)\t\(shown) \(row.unit)\t≤ \(bound) \(row.unit)\t\(detail)")
        fflush(stdout)
        XCTAssertLessThanOrEqual(value, limit, "\(row.measure): \(shown) \(row.unit), budget \(bound) \(row.unit). \(detail)", file: file, line: line)
    }

    // MARK: Measuring

    static func footprintMB(pid: pid_t? = nil) -> Double {
        if let pid, pid != getpid() { return footprintFromTool(pid: pid) }
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    /// Another process's footprint, from `footprint` (what Activity Monitor calls Memory).
    private static func footprintFromTool(pid: pid_t) -> Double {
        let output = run("/usr/bin/footprint", ["\(pid)"])
        guard let line = output.split(separator: "\n").first(where: { $0.contains("Footprint:") }),
              let range = line.range(of: #"Footprint: ([0-9.]+) ([KMG]B)"#, options: .regularExpression) else { return 0 }
        let parts = line[range].split(separator: " ")
        let value = Double(parts[1]) ?? 0
        switch parts[2] {
        case "KB": return value / 1024
        case "GB": return value * 1024
        default: return value
        }
    }

    /// CPU time and idle wakeups for a process over `seconds`, from `top`.
    /// CPU and idle wakeups for a process over `seconds`, from `top`, a sample a second:
    /// CPU averaged; wakeups as the median second (a one-off burst, a git status, shouldn't
    /// read as a steady rate) and the average beside it.
    static func activity(pid: pid_t, seconds: Int) -> (cpuPercent: Double, wakeupsPerSecond: Double, meanWakeups: Double) {
        let output = run("/usr/bin/top", ["-pid", "\(pid)", "-stats", "cpu,idlew", "-l", "\(seconds + 1)", "-s", "1"])
        // The first sample has no interval behind it.
        let samples = output.split(separator: "\n").compactMap { line -> (Double, Double)? in
            let fields = line.split(separator: " ")
            guard fields.count == 2, let cpu = Double(fields[0]), let wakeups = Double(fields[1]) else { return nil }
            return (cpu, wakeups)
        }.dropFirst()
        guard !samples.isEmpty else { return (0, 0, 0) }
        let wakeups = samples.map(\.1)
        return (samples.map(\.0).reduce(0, +) / Double(samples.count), percentile(wakeups, 0.5), wakeups.reduce(0, +) / Double(wakeups.count))
    }

    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    /// Runs the main run loop for a while, each turn in its own autorelease pool as the app's
    /// event loop does (without one, freed views look leaked).
    static func settle(_ seconds: TimeInterval, until condition: () -> Bool = { false }) {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            autoreleasepool { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
        }
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
