import Heron
import AlloyCore
import XCTest
@testable import Side

/// Breakpoints: kept per project, toggled, and following edits (SIDE_RFC_DEBUGGER.md, D3).
@MainActor
final class BreakpointStoreTests: XCTestCase {
    private func store() -> BreakpointStore {
        let defaults = throwawayDefaults()
        return BreakpointStore(project: URL(fileURLWithPath: "/tmp/project"), defaults: defaults)
    }

    /// Applies edits to a buffer and has the store follow them.
    private func edit(_ store: BreakpointStore, _ buffer: TextBuffer, _ edits: [TextEdit]) {
        var applied: [AppliedEdit] = []
        buffer.onChange = { applied += $0.edits }
        buffer.apply(edits)
        store.follow(path: "/a.swift", edits: applied, text: buffer.text)
    }

    func testTogglesAndKeepsPerProject() {
        let defaults = throwawayDefaults()
        let project = URL(fileURLWithPath: "/tmp/project")
        let store = BreakpointStore(project: project, defaults: defaults)
        store.toggle(path: "/a.swift", line: 3)
        store.toggle(path: "/a.swift", line: 7)
        store.toggle(path: "/a.swift", line: 3)
        store.toggle(path: "/b.swift", line: 1)
        store.setEnabled(false, path: "/b.swift", line: 1)
        store.persist()
        XCTAssertEqual(store.breakpoints(in: "/a.swift").map(\.line), [7])

        let again = BreakpointStore(project: project, defaults: defaults)
        XCTAssertEqual(again.all.map { "\($0.path):\($0.breakpoint.line):\($0.breakpoint.enabled)" }, ["/a.swift:7:true", "/b.swift:1:false"])
        XCTAssertTrue(BreakpointStore(project: URL(fileURLWithPath: "/tmp/other"), defaults: defaults).all.isEmpty)
    }

    func testFollowsEdits() {
        let store = store()
        let buffer = TextBuffer("zero\none\ntwo\nthree\nfour\n")
        store.toggle(path: "/a.swift", line: 1)
        store.toggle(path: "/a.swift", line: 3)

        // A line typed above both moves both.
        edit(store, buffer, [TextEdit(range: 0..<0, text: "new\n")])
        XCTAssertEqual(store.breakpoints(in: "/a.swift").map(\.line).sorted(), [2, 4])

        // Typing within a line moves nothing; a newline in the middle of a line above does.
        edit(store, buffer, [TextEdit(range: 1..<1, text: "x")])
        XCTAssertEqual(store.breakpoints(in: "/a.swift").map(\.line).sorted(), [2, 4])
        edit(store, buffer, [TextEdit(range: 2..<2, text: "\n")])
        XCTAssertEqual(store.breakpoints(in: "/a.swift").map(\.line).sorted(), [3, 5])

        // A newline at the end of a breakpoint's own line leaves it where it is.
        let lineThreeEnd = buffer.text.offset(ofLine: 4) - 1
        edit(store, buffer, [TextEdit(range: lineThreeEnd..<lineThreeEnd, text: "\n")])
        XCTAssertEqual(store.breakpoints(in: "/a.swift").map(\.line).sorted(), [3, 6])

        // Deleting the lines that hold one puts it on the line the deletion started on, and two
        // that meet are one.
        let start = buffer.text.offset(ofLine: 2), end = buffer.text.offset(ofLine: 7)
        edit(store, buffer, [TextEdit(range: start..<end, text: "")])
        XCTAssertEqual(store.breakpoints(in: "/a.swift").map(\.line), [2])
    }

    func testOptionsAreKeptAndDescribed() {
        let defaults = throwawayDefaults()
        let project = URL(fileURLWithPath: "/tmp/project")
        let store = BreakpointStore(project: project, defaults: defaults)
        store.toggle(path: "/a.swift", line: 2)
        store.setOptions(path: "/a.swift", line: 2, condition: "n == 2", hitCondition: ">= 3", logMessage: "  ")
        store.watches = ["total", "points.count"]
        store.exceptionFilters = ["swift_throw"]
        store.persist()
        let again = BreakpointStore(project: project, defaults: defaults)
        let breakpoint = try! XCTUnwrap(again.breakpoints(in: "/a.swift").first)
        XCTAssertEqual(breakpoint.condition, "n == 2")
        XCTAssertEqual(breakpoint.hitCondition, ">= 3")
        XCTAssertNil(breakpoint.logMessage, "an empty log message isn't a logpoint")
        XCTAssertEqual(DebugInspector.describe(breakpoint), "if n == 2, hits >= 3")
        XCTAssertEqual(again.watches, ["total", "points.count"])
        XCTAssertEqual(again.exceptionFilters, ["swift_throw"])
        // Breakpoints kept before options existed still load.
        let old = try! JSONSerialization.data(withJSONObject: ["/b.swift": [["line": 4, "enabled": false]]])
        defaults.set(["/tmp/old": old], forKey: "SideBreakpoints")
        XCTAssertEqual(BreakpointStore(project: URL(fileURLWithPath: "/tmp/old"), defaults: defaults).breakpoints(in: "/b.swift").map(\.enabled), [false])
    }

    func testAdapterAnswersVerifyAndMove() {
        let store = store()
        store.toggle(path: "/a.swift", line: 4)
        store.toggle(path: "/a.swift", line: 9)
        store.verified(path: "/a.swift", lines: [(requested: 4, actual: 5, verified: true), (requested: 9, actual: nil, verified: false)])
        XCTAssertEqual(store.breakpoints(in: "/a.swift").map { "\($0.line):\($0.verified!)" }.sorted(), ["5:true", "9:false"])
        store.clearVerification()
        XCTAssertTrue(store.breakpoints(in: "/a.swift").allSatisfy { $0.verified == nil })
    }

    /// D6: 1,000 breakpoints in a file follow a keystroke that adds a line in ≤ 1 ms.
    func testFollowingAnEditIsCheap() {
        let store = store()
        let text = String(repeating: "let x = 1\n", count: 5_000)
        let buffer = TextBuffer(text)
        for line in stride(from: 0, to: 5_000, by: 5) { store.toggle(path: "/a.swift", line: line) }
        XCTAssertEqual(store.breakpoints(in: "/a.swift").count, 1_000)
        var samples: [Double] = []
        for round in 0..<30 {
            var applied: [AppliedEdit] = []
            buffer.onChange = { applied += $0.edits }
            let offset = buffer.text.offset(ofLine: 100 + round)
            buffer.apply([TextEdit(range: offset..<offset, text: "\n")])
            let start = CFAbsoluteTimeGetCurrent()
            store.follow(path: "/a.swift", edits: applied, text: buffer.text)
            samples.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }
        let median = samples.sorted()[samples.count / 2]
        print("BUDGET breakpoints follow an edit (1,000): median \(String(format: "%.3f", median)) ms")
        XCTAssertLessThanOrEqual(median, 1.0)
        XCTAssertEqual(store.breakpoints(in: "/a.swift").first?.line, 0)
        XCTAssertEqual(store.breakpoints(in: "/a.swift").last?.line, 4_995 + 30)
    }
}

@MainActor
final class DebugMessageTests: XCTestCase {
    func testAdapterErrorsReadAsOneLine() {
        XCTAssertEqual(MakeDebugger.message(.failed(command: "evaluate", message: "error: <EXPR>:3:1: cannot find 'a' in scope\na.x * 100\n^")),
                       "cannot find 'a' in scope")
        XCTAssertEqual(MakeDebugger.message(.failed(command: "evaluate", message: "error: No value")), "No value")
        XCTAssertEqual(MakeDebugger.message(.failed(command: "evaluate", message: "not paused")), "not paused")
    }
}

final class DebugLaunchTests: XCTestCase {
    func testExecutablesFromThePackageDescription() {
        let description: [String: Any] = ["products": [
            ["name": "tool", "type": ["executable": NSNull()]],
            ["name": "Lib", "type": ["library": ["automatic"]]],
            ["name": "server", "type": ["executable": NSNull()]],
        ]]
        XCTAssertEqual(DebugLaunch.executables(inDescription: description), ["tool", "server"])
        let configuration = DebugLaunch.swiftConfiguration(product: "it's", root: URL(fileURLWithPath: "/p"))
        XCTAssertEqual(configuration.program, "/p/.build/debug/it's")
        XCTAssertEqual(configuration.build, #"swift build --product 'it'\''s'"#)
    }
}

/// A session against a fake adapter over stdio: the order of the handshake, breakpoints sent and
/// answered, a stop's stack and variables, stepping and the end.
@MainActor
final class DebugSessionTests: XCTestCase {
    private static let adapter = #"""
import sys, json, os
out = os.environ["SIDE_FAKE_DAP_OUT"]
seq = [0]
seen = []
record = {}
def send(o):
    seq[0] += 1; o["seq"] = seq[0]
    b = json.dumps(o).encode()
    sys.stdout.buffer.write(b"Content-Length: %d\r\n\r\n" % len(b) + b); sys.stdout.buffer.flush()
def reply(m, body=None, success=True, message=None):
    r = {"type": "response", "request_seq": m["seq"], "command": m["command"], "success": success}
    if body is not None: r["body"] = body
    if message: r["message"] = message
    send(r)
def event(name, body=None): send({"type": "event", "event": name, "body": body or {}})
while True:
    headers = {}
    while True:
        l = sys.stdin.buffer.readline()
        if not l: sys.exit(0)
        l = l.strip()
        if not l: break
        k, v = l.split(b":", 1); headers[k.lower()] = int(v)
    m = json.loads(sys.stdin.buffer.read(headers[b"content-length"]))
    c = m["command"]; seen.append(c)
    record[c] = m.get("arguments")
    with open(out, "w") as f: json.dump({"seen": seen, "last": m.get("arguments"), "record": record}, f)
    if c == "initialize": reply(m, {"supportsConfigurationDoneRequest": True, "exceptionBreakpointFilters": [
        {"filter": "swift_throw", "label": "Swift Throw", "default": True}, {"filter": "cpp_throw", "label": "C++ Throw", "default": False}]})
    elif c == "evaluate":
        e = m["arguments"]["expression"]
        if e == "nope": reply(m, success=False, message="error: no such thing")
        else: reply(m, {"result": "%s@%s" % (e, m["arguments"].get("frameId")), "variablesReference": 0})
    elif c == "launch":
        event("initialized")
        event("output", {"category": "stdout", "output": "hello\n"})
        pending_launch = m
    elif c == "setBreakpoints":
        bps = m["arguments"]["breakpoints"]
        reply(m, {"breakpoints": [{"verified": b["line"] != 99, "line": b["line"] + (1 if b["line"] == 3 else 0)} for b in bps]})
    elif c == "setExceptionBreakpoints": reply(m, {})
    elif c == "configurationDone":
        reply(m, {}); reply(pending_launch, {})
        event("stopped", {"reason": "breakpoint", "threadId": 7})
    elif c == "threads": reply(m, {"threads": [{"id": 7, "name": "main"}]})
    elif c == "stackTrace":
        reply(m, {"stackFrames": [
            {"id": 1, "name": "libsystem", "line": 0, "column": 0},
            {"id": 2, "name": "distance(_:_:)", "line": 4, "column": 5, "source": {"path": "/p/main.swift"}},
            {"id": 3, "name": "main", "line": 12, "column": 1, "source": {"path": "/p/main.swift"}}]})
    elif c == "scopes": reply(m, {"scopes": [{"name": "Locals", "variablesReference": 10, "expensive": False}]})
    elif c == "variables":
        ref = m["arguments"]["variablesReference"]
        if ref == 10:
            reply(m, {"variables": [{"name": "dx", "value": "3", "type": "Int", "variablesReference": 0},
                                    {"name": "points", "value": "1000 values", "variablesReference": 11, "indexedVariables": 1000}]})
        else:
            s = m["arguments"].get("start", 0); n = m["arguments"].get("count", 1000)
            reply(m, {"variables": [{"name": "[%d]" % i, "value": str(i), "variablesReference": 0} for i in range(s, s + n)]})
    elif c == "next":
        reply(m, {}); event("continued", {"threadId": 7}); event("stopped", {"reason": "step", "threadId": 7})
    elif c == "continue":
        reply(m, {}); event("exited", {"exitCode": 0}); event("terminated")
    elif c == "disconnect": reply(m, {}); sys.exit(0)
    else: reply(m, success=False, message="unknown")
"""#

    private func wait(for session: DebugSession, timeout: TimeInterval = 10, until condition: @escaping (DebugSession.State) -> Bool) async {
        if condition(session.state) { return }
        let reached = expectation(description: "state")
        var fulfilled = false
        let previous = session.onChange
        session.onChange = {
            previous?()
            if !fulfilled, condition(session.state) { fulfilled = true; reached.fulfill() }
        }
        await fulfillment(of: [reached], timeout: timeout)
        session.onChange = previous
    }

    func testAFakeAdapterSessionFromLaunchToEnd() async throws {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: python.path), "no python3")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("side-fake-dap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("adapter.py"), out = dir.appendingPathComponent("seen.json")
        try Self.adapter.write(to: script, atomically: true, encoding: .utf8)
        setenv("SIDE_FAKE_DAP_OUT", out.path, 1)

        let store = BreakpointStore(project: dir, defaults: throwawayDefaults())
        store.toggle(path: "/p/main.swift", line: 2)    // line 3 to the adapter: moved to 4
        store.toggle(path: "/p/main.swift", line: 98)   // line 99: not placed
        store.setOptions(path: "/p/main.swift", line: 98, condition: " x > 1 ", hitCondition: "", logMessage: "x is {x}")
        let configuration = DebugConfiguration(name: "demo", program: "/p/demo", directory: dir.path)
        let session = DebugSession(configuration: configuration, adapter: python, adapterArguments: [script.path], breakpoints: store)
        await session.start()
        await wait(for: session) { if case .stopped = $0 { return true } else { return false } }

        // The handshake in its order, the breakpoints answered.
        let seen = try JSONSerialization.jsonObject(with: Data(contentsOf: out)) as? [String: Any]
        let commands = (seen?["seen"] as? [String]) ?? []
        XCTAssertEqual(Array(commands.prefix(5)), ["initialize", "launch", "setBreakpoints", "setExceptionBreakpoints", "configurationDone"])
        XCTAssertEqual(store.breakpoints(in: "/p/main.swift").map { "\($0.line):\($0.verified!)" }.sorted(), ["3:true", "98:false"])
        // Options go with a breakpoint (trimmed, empty ones left out); the adapter's default
        // exception breakpoint is on until the person picks.
        let record = seen?["record"] as? [String: Any]
        let sent = ((record?["setBreakpoints"] as? [String: Any])?["breakpoints"] as? [[String: Any]]) ?? []
        XCTAssertEqual(sent.last?["condition"] as? String, "x > 1")
        XCTAssertEqual(sent.last?["logMessage"] as? String, "x is {x}")
        XCTAssertNil(sent.last?["hitCondition"])
        XCTAssertNil(sent.first?["condition"])
        XCTAssertEqual((record?["setExceptionBreakpoints"] as? [String: Any])?["filters"] as? [String], ["swift_throw"])
        XCTAssertEqual(session.exceptionFilters.map(\.label), ["Swift Throw", "C++ Throw"])

        // The stop: the first frame with source is the one shown.
        XCTAssertEqual(session.frames.count, 3)
        XCTAssertEqual(session.currentFrame?.name, "distance(_:_:)")
        XCTAssertEqual(session.currentFrame?.line, 4)
        XCTAssertTrue(session.output.contains("hello"))
        let scopes = await session.scopes(frameID: 2)
        XCTAssertEqual(scopes.map(\.name), ["Locals"])
        let locals = await session.variables(10)
        XCTAssertEqual(locals.map(\.name), ["dx", "points"])
        XCTAssertEqual(locals.last?.indexedCount, 1000)
        let page = await session.variables(11, start: 200, count: 200)
        XCTAssertEqual(page.count, 200)
        XCTAssertEqual(page.first?.name, "[200]")

        // Evaluating goes to the selected frame; a failure carries the adapter's message.
        let value = await session.evaluate("dx * 2", context: "watch")
        XCTAssertEqual(try value.get().result, "dx * 2@2")
        if case .failure(.failed(_, let message)) = await session.evaluate("nope", context: "repl") {
            XCTAssertEqual(message, "error: no such thing")
        } else {
            XCTFail("expected a failure")
        }
        // Choosing exception breakpoints is kept and sent.
        store.exceptionFilters = ["cpp_throw"]
        await session.sendExceptionBreakpoints()
        let again = try JSONSerialization.jsonObject(with: Data(contentsOf: out)) as? [String: Any]
        XCTAssertEqual(((again?["record"] as? [String: Any])?["setExceptionBreakpoints"] as? [String: Any])?["filters"] as? [String], ["cpp_throw"])

        // A step stops again; continue runs to the end.
        session.stepOver()
        await wait(for: session) { if case .stopped(let reason, _, _) = $0 { return reason == "step" } else { return false } }
        session.resume()
        await wait(for: session) { if case .ended = $0 { return true } else { return false } }
        XCTAssertTrue(session.output.contains("exited with code 0"))
        XCTAssertTrue(store.breakpoints(in: "/p/main.swift").allSatisfy { $0.verified == nil })
    }

    /// The inspector's variables: the scope opens, a big array opens a page at a time. D6: its
    /// first page in ≤ 30 ms of Side's own work (the adapter's time excluded).
    func testTheInspectorPagesABigArray() async throws {
        let inspector = DebugInspector(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
        let calls = LockedBox<[String]>([])
        inspector.fetchVariables = { reference, start, count in
            calls.value.append("\(reference):\(start.map(String.init) ?? "-"):\(count.map(String.init) ?? "-")")
            if reference == 10 { return [DAPVariable(["name": "big", "value": "100000 values", "variablesReference": 11, "indexedVariables": 100_000])!] }
            return (start! ..< start! + count!).map { DAPVariable(["name": "[\($0)]", "value": "\($0)"])! }
        }
        inspector.show(frames: [DAPStackFrame(["id": 1, "name": "main", "line": 1])!], selected: 0)
        inspector.show(scopes: [DAPScope(["name": "Locals", "variablesReference": 10])!])
        let outline = inspector.variablesOutline
        try await waitUntil { outline.numberOfRows == 2 }
        let started = CFAbsoluteTimeGetCurrent()
        outline.expandItem(outline.item(atRow: 1))
        try await waitUntil { outline.numberOfRows == 2 + DebugInspector.pageSize + 1 }
        let elapsed = (CFAbsoluteTimeGetCurrent() - started) * 1000
        print("BUDGET variables: first page of 100,000: \(String(format: "%.2f", elapsed)) ms")
        XCTAssertLessThanOrEqual(elapsed, 30)
        XCTAssertEqual(calls.value, ["10:-:-", "11:0:200"])
        let more = outline.item(atRow: outline.numberOfRows - 1) as? DebugVariableNode
        if case .more(_, let start, let remaining)? = more?.kind {
            XCTAssertEqual(start, 200)
            XCTAssertEqual(remaining, 99_800)
        } else {
            XCTFail("no more row")
        }
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out") }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}

/// lldb-dap on a real Swift package: built, stopped at a breakpoint, its locals read, stepped
/// and ended. Opt-in (it builds a package and runs a debugger): SIDE_DEBUGGER_TESTS=1.
@MainActor
final class LLDBDAPTests: XCTestCase {
    /// Attach (SIDE_RFC_DEBUGGER.md, step 4): a running program, waiting on its input, paused
    /// and shown where it waits.
    func testAttachesToARunningProgramAndPausesIt() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SIDE_DEBUGGER_TESTS"] == "1", "set SIDE_DEBUGGER_TESTS=1 (TEST_RUNNER_SIDE_DEBUGGER_TESTS=1)")
        let adapter = try XCTUnwrap(DebugLaunch.lldbDAP(), "no lldb-dap")
        // A program of the test's own that waits on its input (a system one, like cat, is
        // protected: macOS lets no debugger attach to it).
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("side-attach-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // It sleeps in a loop: attaching interrupts a system call, and a read would take that for its end.
        try "#include <unistd.h>\nint main(void) { for (;;) sleep(1); }\n"
            .write(to: folder.appendingPathComponent("wait.c"), atomically: true, encoding: .utf8)
        let (status, log) = await DebugSession.run("cc -g -o wait wait.c", in: folder.path)
        XCTAssertEqual(status, 0, log)
        let program = Process()
        program.executableURL = folder.appendingPathComponent("wait")
        let input = Pipe()
        program.standardInput = input
        program.standardOutput = FileHandle.nullDevice
        try program.run()
        defer { program.terminate() }
        let store = BreakpointStore(project: FileManager.default.temporaryDirectory, defaults: throwawayDefaults())
        let configuration = DebugConfiguration(name: "cat", request: "attach", launchArguments: ["pid": .int(Int(program.processIdentifier))],
                                               directory: FileManager.default.temporaryDirectory.path)
        let session = DebugSession(configuration: configuration, adapter: adapter, breakpoints: store)
        let running = expectation(description: "running")
        let stopped = expectation(description: "stopped")
        var sawRunning = false, sawStopped = false
        session.onChange = {
            if case .running = session.state, !sawRunning { sawRunning = true; running.fulfill() }
            if case .stopped = session.state, !sawStopped { sawStopped = true; stopped.fulfill() }
        }
        await session.start()
        await fulfillment(of: [running], timeout: 60)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        session.pause()
        await fulfillment(of: [stopped], timeout: 30)
        XCTAssertFalse(session.frames.isEmpty)
        XCTAssertTrue(session.frames.contains { $0.name.contains("sleep") || $0.name.contains("main") }, session.frames.map(\.name).joined(separator: ", "))
        session.stop()
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertFalse(session.isActive)
        XCTAssertTrue(program.isRunning, "stopping an attached session lets the program go on")
        try input.fileHandleForWriting.close()   // held open until here: the program waits on it
    }

    func testDebugsASwiftPackage() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SIDE_DEBUGGER_TESTS"] == "1", "set SIDE_DEBUGGER_TESTS=1 (TEST_RUNNER_SIDE_DEBUGGER_TESTS=1) to debug a real package")
        let adapter = try XCTUnwrap(DebugLaunch.lldbDAP(), "no lldb-dap")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("side-lldb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources/Demo"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "Demo", targets: [.executableTarget(name: "Demo")])
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let source = root.appendingPathComponent("Sources/Demo/main.swift")
        try """
        func square(_ n: Int) -> Int {
            let result = n * n
            return result
        }
        var total = 0
        for i in 1...3 { total += square(i) }
        print("total", total)
        """.write(to: source, atomically: true, encoding: .utf8)

        let products = try await DebugLaunch.swiftExecutables(in: root)
        XCTAssertEqual(products, ["Demo"])
        let store = BreakpointStore(project: root, defaults: throwawayDefaults())
        let path = source.resolvingSymlinksInPath().path
        store.toggle(path: path, line: 2)   // `return result`, only when n is 2
        store.setOptions(path: path, line: 2, condition: "n == 2", hitCondition: nil, logMessage: nil)
        store.toggle(path: path, line: 1)   // a logpoint: prints, doesn't stop
        store.setOptions(path: path, line: 1, condition: nil, hitCondition: nil, logMessage: "squaring {n}")
        // The program on a terminal of its own, as a Run tab gives it.
        var master: Int32 = -1, slave: Int32 = -1
        XCTAssertEqual(openpty(&master, &slave, nil, nil, nil), 0)
        defer { close(master); close(slave) }
        var configuration = DebugLaunch.swiftConfiguration(product: "Demo", root: root.resolvingSymlinksInPath())
        configuration.terminal = String(cString: ttyname(slave))
        let session = DebugSession(configuration: configuration, adapter: adapter, breakpoints: store)
        let stopped = expectation(description: "stopped")
        let ended = expectation(description: "ended")
        var stops = 0
        session.onChange = {
            switch session.state {
            case .stopped: stops += 1; if stops == 1 { stopped.fulfill() }
            case .ended: ended.fulfill()
            default: break
            }
        }
        await session.start()
        await fulfillment(of: [stopped], timeout: 120)
        XCTAssertEqual(store.breakpoints(in: path).first?.verified, true)
        let frame = try XCTUnwrap(session.currentFrame)
        XCTAssertTrue(frame.name.contains("square"), frame.name)
        XCTAssertEqual(frame.line, 3)
        let scopes = await session.scopes(frameID: frame.id)
        let locals = try XCTUnwrap(scopes.first)
        let variables = await session.variables(locals.variablesReference)
        XCTAssertEqual(variables.first { $0.name == "result" }?.value, "4", variables.map { "\($0.name)=\($0.value)" }.joined(separator: ", "))
        let tenfold = await session.evaluate("result * 10", context: "watch")
        XCTAssertEqual(try tenfold.get().result, "40")
        XCTAssertTrue(session.output.contains("squaring 1"), session.output)
        store.removeAll()
        await session.sendBreakpoints(path: path)
        session.resume()
        await fulfillment(of: [ended], timeout: 60)
        // The program's output went to its terminal, not the adapter's events.
        var buffer = [UInt8](repeating: 0, count: 4096)
        let flags = fcntl(master, F_GETFL)
        _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)
        let count = read(master, &buffer, buffer.count)
        let written = count > 0 ? String(decoding: buffer[..<count], as: UTF8.self) : ""
        XCTAssertTrue(written.contains("total 14"), written)
        XCTAssertFalse(session.output.contains("total 14"))
    }
}


/// What the agent's read-only tool reads (SIDE_RFC_DEBUGGER.md, Q5): Make publishes the paused
/// program as the inspector has it, members once it stays paused, and nothing once it ends.
@MainActor
final class DebugSnapshotPublishingTests: XCTestCase {
    func testMakePublishesThePausedProgramForTheAgent() throws {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: python.path), "no python3")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("side-snapshot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Sources/work.swift")
        try (0..<200).map { "let line\($0) = \($0)" }.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        let script = folder.appendingPathComponent("adapter.py")
        try DebugBudgetTests.adapter.write(to: script, atomically: true, encoding: .utf8)
        setenv("SIDE_BUDGET_FILE", realPath(file.path), 1)

        let make = MakeWorkspaceViewController()
        make.loadViewIfNeeded()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = container
        for child in [make.view, make.topRowContent!] { container.addSubview(child) }
        make.view.frame = container.bounds
        defer { make.debugger.stop(); window.contentView = nil; window.close() }
        make.loadProject(at: folder)
        func waitUntil(_ timeout: TimeInterval = 10, _ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        }
        make.debugger.launch(DebugConfiguration(name: "work", program: "/bin/true", directory: folder.path), adapter: python, adapterArguments: [script.path])
        waitUntil { DebugSnapshot.shared.state(projectRoot: folder)?.locals.isEmpty == false }
        let paused = try XCTUnwrap(DebugSnapshot.shared.state(projectRoot: folder))
        XCTAssertEqual(paused.status, .paused)
        XCTAssertEqual(paused.reason, "breakpoint")
        XCTAssertEqual(paused.frames.first?.path, "Sources/work.swift", "relative to the project")
        XCTAssertEqual(paused.frames.count, 41)
        XCTAssertEqual(paused.locals.first?.name, "point")
        XCTAssertTrue(paused.locals.first?.children.isEmpty ?? false, "members only once it stays paused")

        // Half a second later, still paused: the small structured local's members.
        waitUntil { DebugSnapshot.shared.state(projectRoot: folder)?.locals.first?.children.isEmpty == false }
        XCTAssertEqual(DebugSnapshot.shared.state(projectRoot: folder)?.locals.first?.children.map(\.name), ["x", "y"])
        let report = DebugSnapshot.shared.report(projectRoot: folder)
        XCTAssertTrue(report.contains("#0 work  Sources/work.swift:1  \u{2190} selected"), report)
        XCTAssertTrue(report.contains("    x: Int = 3"), report)

        // Running: no stack; ended: no session.
        make.debugger.stepOver()
        make.debugger.stop()
        waitUntil { DebugSnapshot.shared.state(projectRoot: folder) == nil }
        XCTAssertNil(DebugSnapshot.shared.state(projectRoot: folder))
    }
}

/// 2026-09-30 audit, H8: Stop during the pre-launch build left the build running, and when it
/// finished the ended session came back to life and launched the program.
@MainActor
final class DebugBuildStopTests: XCTestCase {
    func testStopDuringTheBuildEndsItAndLaunchesNothing() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("side-debug-build-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = "31.\(Int.random(in: 100_000...999_999))"
        let configuration = DebugConfiguration(name: "t", program: "/usr/bin/true", directory: dir.path, build: "sleep \(marker)")
        let store = BreakpointStore(project: dir, defaults: throwawayDefaults())
        let session = DebugSession(configuration: configuration, adapter: URL(fileURLWithPath: "/usr/bin/false"), breakpoints: store)
        var states: [DebugSession.State] = []
        session.onChange = { states.append(session.state) }
        let started = Task { await session.start() }
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(session.state, .building)
        session.stop()
        _ = await started.value  // returns once the build is gone, not after 31.5 s
        XCTAssertFalse(session.isActive)
        XCTAssertFalse(states.contains(.starting), "nothing launched after Stop: \(states)")
        let left = Process()
        left.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        left.arguments = ["-f", "sleep \(marker)"]
        try left.run()
        left.waitUntilExit()
        XCTAssertNotEqual(left.terminationStatus, 0, "the build is gone")
    }
}
