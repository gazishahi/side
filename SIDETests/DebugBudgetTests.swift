import AlloyCore
import XCTest
@testable import Side

/// SIDE_RFC_DEBUGGER.md, D6: what the debugger costs Side itself, apart from the adapter. Limits
/// in `Budgets.table`; opt-in with the other budgets (`scripts/budgets.sh Debug`).
@MainActor
final class DebugBudgetTests: XCTestCase {
    private var make: MakeWorkspaceViewController!
    private var window: NSWindow!
    private var folder: URL!

    /// An adapter that stops again on every step, one line further down a real file.
    static let adapter = #"""
import sys, json, os
path = os.environ["SIDE_BUDGET_FILE"]
seq = [0]; line = [1]; pending = [None]
def send(o):
    seq[0] += 1; o["seq"] = seq[0]; b = json.dumps(o).encode()
    sys.stdout.buffer.write(b"Content-Length: %d\r\n\r\n" % len(b) + b); sys.stdout.buffer.flush()
def reply(m, body=None): send({"type": "response", "request_seq": m["seq"], "command": m["command"], "success": True, "body": body or {}})
def stop(reason): send({"type": "event", "event": "stopped", "body": {"reason": reason, "threadId": 1}})
while True:
    headers = {}
    while True:
        l = sys.stdin.buffer.readline()
        if not l: sys.exit(0)
        l = l.strip()
        if not l: break
        k, v = l.split(b":", 1); headers[k.lower()] = int(v)
    m = json.loads(sys.stdin.buffer.read(headers[b"content-length"])); c = m["command"]
    if c == "launch": pending[0] = m; send({"type": "event", "event": "initialized"})
    elif c == "configurationDone": reply(m); reply(pending[0]); stop("breakpoint")
    elif c == "threads": reply(m, {"threads": [{"id": 1, "name": "main"}]})
    elif c == "stackTrace":
        frames = [{"id": 1, "name": "work", "line": line[0], "column": 1, "source": {"path": path}}]
        frames += [{"id": 2 + i, "name": "caller%d" % i, "line": 1, "column": 1} for i in range(40)]
        reply(m, {"stackFrames": frames})
    elif c == "scopes": reply(m, {"scopes": [{"name": "Locals", "variablesReference": 10}]})
    elif c == "variables":
        if m["arguments"]["variablesReference"] == 11:
            reply(m, {"variables": [{"name": "x", "value": "3", "type": "Int", "variablesReference": 0}, {"name": "y", "value": "6", "type": "Int", "variablesReference": 0}]})
        else:
            reply(m, {"variables": [{"name": "point", "value": "Point", "type": "Point", "variablesReference": 11, "namedVariables": 2}]
                      + [{"name": "v%d" % i, "value": str(i), "variablesReference": 0} for i in range(11)]})
    elif c == "next":
        reply(m); line[0] += 7; send({"type": "event", "event": "continued", "body": {"threadId": 1}}); stop("step")
    elif c == "disconnect": reply(m); sys.exit(0)
    else: reply(m)
"""#

    override func setUpWithError() throws {
        try Budgets.skipUnlessEnabled()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("side-debug-budget-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        make = MakeWorkspaceViewController()
        make.loadViewIfNeeded()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // Make's top row (the tab strip) lives beside its view, in the window's chrome.
        let container = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = container
        let tabs = try XCTUnwrap(make.topRowContent)
        for child in [make.view, tabs, make.paletteSurface!] {
            child.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(child)
        }
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: container.topAnchor), tabs.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tabs.trailingAnchor.constraint(equalTo: container.trailingAnchor), tabs.heightAnchor.constraint(equalToConstant: 30),
            make.view.topAnchor.constraint(equalTo: container.topAnchor), make.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            make.view.leadingAnchor.constraint(equalTo: container.leadingAnchor), make.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            make.paletteSurface.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -60),
            make.paletteSurface.centerXAnchor.constraint(equalTo: container.centerXAnchor), make.paletteSurface.widthAnchor.constraint(equalToConstant: 640),
            make.paletteSurface.heightAnchor.constraint(equalToConstant: 300),
        ])
        window.makeKeyAndOrderFront(nil)
    }

    override func tearDownWithError() throws {
        make?.debugger.stop()
        window?.contentView = nil
        window?.close()
        window = nil
        make = nil
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    /// For the agent's snapshot test, which isn't a budget.
    var skipsBudgetCheck = false

    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.002)) }
    }

    private func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

    /// A step, the adapter's `stopped` to the line shown in the editor and the stack in the
    /// inspector. It includes the fake adapter's answers to `threads` and `stackTrace` (a
    /// millisecond or so), so it's an upper bound on Side's own work.
    func testAStepIsShownQuickly() throws {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: python.path), "no python3")
        let file = folder.appendingPathComponent("work.swift")
        try (0..<2_000).map { "let line\($0) = \($0)" }.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        let script = folder.appendingPathComponent("adapter.py")
        try Self.adapter.write(to: script, atomically: true, encoding: .utf8)
        setenv("SIDE_BUDGET_FILE", realPath(file.path), 1)
        make.revealFile(file, line: 1)
        waitUntil { self.make.debugCurrentFile != nil }
        make.debugger.projectChanged(folder)

        let debugger = make.debugger
        debugger.launch(DebugConfiguration(name: "work", program: "/bin/true", directory: folder.path), adapter: python, adapterArguments: [script.path])
        waitUntil { debugger.isStopped && debugger.inspectorForTesting.frames.count == 41 }
        var samples: [Double] = []
        for _ in 0..<25 {
            let before = debugger.lastStopShownIn
            debugger.stepOver()
            waitUntil { debugger.isStopped && debugger.lastStopShownIn != before && debugger.inspectorForTesting.frames.count == 41 }
            samples.append((debugger.lastStopShownIn ?? .infinity) * 1000)
        }
        XCTAssertEqual(make.editor.stoppedLine, 1 + 25 * 7 - 1, "the stopped line is the last step's")
        Budgets.check("debug.step", median(samples), detail: "p90 \(String(format: "%.1f", samples.sorted()[Int(Double(samples.count) * 0.9)])) ms, 41 frames")

        // Paused: nothing runs. The run loop turns for three seconds; Side's CPU in that time.
        // (One long turn: a polling wait would be the CPU measured.)
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        let start = Self.cpuSeconds(), wall = Date()
        RunLoop.main.run(until: Date().addingTimeInterval(3))
        let cpu = (Self.cpuSeconds() - start) / Date().timeIntervalSince(wall) * 100
        Budgets.check("debug.idle.cpu", cpu, detail: "3 s paused")
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }

    /// The first page of a 100,000-element array, opened in the inspector (the adapter's time
    /// excluded: the fetch answers at once).
    func testABigArraysFirstPage() throws {
        let inspector = DebugInspector(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
        inspector.fetchVariables = { reference, start, count in
            if reference == 10 { return [DAPVariable(["name": "big", "value": "100000 values", "variablesReference": 11, "indexedVariables": 100_000])!] }
            return (start! ..< start! + count!).map { DAPVariable(["name": "[\($0)]", "value": "\($0)", "type": "Int"])! }
        }
        var samples: [Double] = []
        for _ in 0..<10 {
            inspector.show(frames: [DAPStackFrame(["id": 1, "name": "main", "line": 1])!], selected: 0)
            inspector.show(scopes: [DAPScope(["name": "Locals", "variablesReference": 10])!])
            let outline = inspector.variablesOutline
            waitUntil { outline.numberOfRows == 2 }
            let start = CFAbsoluteTimeGetCurrent()
            outline.expandItem(outline.item(atRow: 1))
            waitUntil { outline.numberOfRows == 2 + DebugInspector.pageSize + 1 }
            outline.layoutSubtreeIfNeeded()
            samples.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }
        Budgets.check("debug.variables", median(samples), detail: "\(DebugInspector.pageSize) rows")
    }

    func testBreakpointsFollowAnEdit() {
        let store = BreakpointStore(project: folder, defaults: UserDefaults(suiteName: "side.tests.debug-budget.\(UUID().uuidString)")!)
        let buffer = TextBuffer(String(repeating: "let x = 1\n", count: 5_000))
        for line in stride(from: 0, to: 5_000, by: 5) { store.toggle(path: "/a.swift", line: line) }
        var samples: [Double] = []
        for round in 0..<60 {
            var applied: [AppliedEdit] = []
            buffer.onChange = { applied += $0.edits }
            let offset = buffer.text.offset(ofLine: 100 + round)
            buffer.apply([TextEdit(range: offset..<offset, text: "\n")])
            let start = CFAbsoluteTimeGetCurrent()
            store.follow(path: "/a.swift", edits: applied, text: buffer.text)
            samples.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }
        Budgets.check("debug.breakpoints", median(samples), detail: "1,000 breakpoints, 5,000 lines")
    }
}
