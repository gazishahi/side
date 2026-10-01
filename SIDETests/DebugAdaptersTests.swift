import XCTest
@testable import Side

/// SIDE_RFC_DEBUGGER.md, step 3: the adapters beyond lldb-dap, what Side proposes to debug, a
/// server adapter over TCP with its child sessions, and the adapter's `runInTerminal`.
final class DebugProposalTests: XCTestCase {
    private func project() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("side-proposals-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("cmd/tool"), withIntermediateDirectories: true)
        try #"{"scripts": {"dev": "node app.js", "build": "tsc"}}"#.write(to: root.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try "module example.com/p\n".write(to: root.appendingPathComponent("go.mod"), atomically: true, encoding: .utf8)
        for name in ["app.ts", "main.py", "cmd/tool/main.go"] {
            try "".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return root
    }

    func testTheOpenFilesLanguageComesFirst() async throws {
        let root = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        let python = await DebugLaunch.proposals(root: root, currentFile: root.appendingPathComponent("main.py"))
        XCTAssertEqual(python.map(\.name), ["main.py", "npm run build", "npm run dev", "go run ."])
        XCTAssertEqual(python.map(\.adapter), ["debugpy", "js-debug", "js-debug", "delve"])
        XCTAssertEqual(python[0].launchArguments?["console"], "integratedTerminal")
        XCTAssertEqual(python[0].launchArguments?["python"], "python3", "no .venv: the person's python3")

        let go = await DebugLaunch.proposals(root: root, currentFile: root.appendingPathComponent("cmd/tool/main.go"))
        XCTAssertEqual(go.first?.name, "go run ./cmd/tool")
        XCTAssertEqual(go.first?.launchArguments?["mode"], "debug")

        let ts = await DebugLaunch.proposals(root: root, currentFile: root.appendingPathComponent("app.ts"))
        XCTAssertEqual(ts.prefix(3).map(\.name), ["app.ts", "npm run build", "npm run dev"])
        XCTAssertEqual(ts[1].launchArguments?["runtimeArgs"], ["run", "build"])
    }

    func testAProjectVenvIsThePythonUsed() throws {
        let root = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        let python = root.appendingPathComponent(".venv/bin/python")
        try FileManager.default.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: python, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
        XCTAssertEqual(DebugLaunch.pythonFile(root.appendingPathComponent("main.py"), root: root).launchArguments?["python"], .string(python.path))
    }

    func testEveryAdapterHasItsLanguagesAndAWayIn() {
        XCTAssertEqual(DebugAdapters.presets.map(\.id), ["lldb-dap", "js-debug", "debugpy", "delve"])
        for preset in DebugAdapters.presets {
            for language in preset.languages { XCTAssertNotNil(LanguageSettings.presets.first { $0.id == language }, "\(preset.id): \(language)") }
            if preset.id != "lldb-dap" { XCTAssertNotNil(preset.install, preset.id) }
        }
        // Side's own installs go into Side's folder, quoted (it has a space).
        XCTAssertTrue(DebugAdapters.debugpy.install!.command.contains("python3 -m venv"))
        XCTAssertTrue(DebugAdapters.jsDebug.install!.command.contains("js-debug-dap-v"))
    }

    func testAFreePortIsOne() throws {
        let port = try XCTUnwrap(DAPSocketTransport.freePort())
        XCTAssertGreaterThan(port, 1024)
    }
}

/// A server adapter over TCP (js-debug's shape): the launcher session asks for a terminal, then
/// for a child session, which connects to the same port and is where the program stops.
@MainActor
final class DebugServerSessionTests: XCTestCase {
    private static let server = #"""
import socket, json, sys, threading, os
port = int(sys.argv[1]); out = os.environ["SIDE_FAKE_DAP_OUT"]
record = {"child": []}
def dump():
    with open(out, "w") as f: json.dump(record, f)
srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", port)); srv.listen(4)
def serve(conn, index):
    f = conn.makefile("rb"); seq = [0]; pending = [None]
    def send(o):
        seq[0] += 1; o["seq"] = seq[0]; b = json.dumps(o).encode(); conn.sendall(b"Content-Length: %d\r\n\r\n" % len(b) + b)
    def reply(m, body=None): send({"type": "response", "request_seq": m["seq"], "command": m["command"], "success": True, "body": body or {}})
    while True:
        headers = {}
        while True:
            l = f.readline()
            if not l: return
            l = l.strip()
            if not l: break
            k, v = l.split(b":", 1); headers[k.lower()] = int(v)
        m = json.loads(f.read(headers[b"content-length"]))
        if m["type"] == "response":
            if m["command"] == "runInTerminal":
                record["runInTerminal"] = m.get("body"); dump()
                send({"type": "request", "command": "startDebugging", "arguments": {"request": "launch", "configuration": {"type": "pwa-node", "__pendingTargetId": "t1"}}})
            elif m["command"] == "startDebugging":
                record["startDebugging"] = m["success"]; dump()
            continue
        c = m["command"]
        if index == 0:
            if c == "initialize":
                record["parentInitialize"] = m["arguments"]; dump()
                reply(m, {"supportsConfigurationDoneRequest": True})
            elif c == "launch": pending[0] = m; send({"type": "event", "event": "initialized"})
            elif c == "configurationDone":
                reply(m); reply(pending[0])
                send({"type": "request", "command": "runInTerminal", "arguments": {"kind": "integrated", "title": "app", "cwd": "/tmp", "args": ["node", "app.js"], "env": {"A": "1", "B": None}}})
            elif c == "disconnect": reply(m); return
            else: reply(m)
        else:
            record["child"].append(c); dump()
            if c == "initialize": reply(m, {"supportsConfigurationDoneRequest": True})
            elif c == "launch": record["childLaunch"] = m["arguments"]; dump(); pending[0] = m; send({"type": "event", "event": "initialized"})
            elif c == "setBreakpoints": reply(m, {"breakpoints": [{"verified": True, "line": b["line"]} for b in m["arguments"]["breakpoints"]]})
            elif c == "configurationDone": reply(m); reply(pending[0]); send({"type": "event", "event": "stopped", "body": {"reason": "breakpoint", "threadId": 1}})
            elif c == "threads": reply(m, {"threads": [{"id": 1, "name": "main"}]})
            elif c == "stackTrace": reply(m, {"stackFrames": [{"id": 1, "name": "square", "line": 3, "column": 1, "source": {"path": "/p/app.js"}}]})
            elif c == "continue": reply(m); send({"type": "event", "event": "terminated"})
            elif c == "disconnect": reply(m); return
            else: reply(m)
index = 0
while True:
    conn, _ = srv.accept()
    threading.Thread(target=serve, args=(conn, index), daemon=True).start()
    index += 1
"""#

    func testALauncherSessionItsTerminalAndItsChild() async throws {
        let shim = URL(fileURLWithPath: "/usr/bin/python3")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: shim.path), "no python3")
        // The interpreter itself: /usr/bin/python3 is a shim that runs it as a child, which
        // stopping the shim leaves running.
        let probe = Process()
        probe.executableURL = shim
        probe.arguments = ["-c", "import sys; print(sys.executable)"]
        let pipe = Pipe()
        probe.standardOutput = pipe
        try probe.run()
        probe.waitUntilExit()
        let python = URL(fileURLWithPath: String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("side-fake-dap-server-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("server.py"), out = dir.appendingPathComponent("seen.json")
        try Self.server.write(to: script, atomically: true, encoding: .utf8)
        setenv("SIDE_FAKE_DAP_OUT", out.path, 1)

        let store = BreakpointStore(project: dir, defaults: throwawayDefaults())
        store.toggle(path: "/p/app.js", line: 2)
        let configuration = DebugConfiguration(name: "app.js", adapter: DebugAdapters.jsDebug.id,
                                               launchArguments: ["type": "pwa-node", "request": "launch", "program": "/p/app.js"], directory: dir.path)
        let parent = DebugSession(configuration: configuration, connection: .server(executable: python, arguments: [script.path, "{port}"]),
                                  adapterID: "pwa-node", breakpoints: store)
        var terminal: ([String], String, [String: String], String)?
        parent.runInTerminal = { arguments, directory, environment, title in
            terminal = (arguments, directory, environment, title)
            return 4242
        }
        let stopped = expectation(description: "child stopped")
        let ended = expectation(description: "child ended")
        var child: DebugSession?
        parent.onStartChild = { request, arguments in
            var childConfiguration = configuration
            childConfiguration.request = request
            childConfiguration.launchArguments = arguments
            let session = DebugSession(configuration: childConfiguration, connection: .socket(port: parent.port!), adapterID: "pwa-node", breakpoints: store)
            session.onChange = {
                if case .stopped = session.state { stopped.fulfill() }
                if case .ended = session.state { ended.fulfill() }
            }
            child = session
            Task { await session.start() }
        }
        await parent.start()
        XCTAssertNotNil(parent.port)
        await fulfillment(of: [stopped], timeout: 15)

        // The terminal it asked for: the program's command, the directory, the environment
        // without its unset (null) entries, the title.
        XCTAssertEqual(terminal?.0, ["node", "app.js"])
        XCTAssertEqual(terminal?.1, "/tmp")
        XCTAssertEqual(terminal?.2, ["A": "1"])
        XCTAssertEqual(terminal?.3, "app")
        let seen = try JSONSerialization.jsonObject(with: Data(contentsOf: out)) as? [String: Any]
        XCTAssertEqual((seen?["runInTerminal"] as? [String: Any])?["processId"] as? Int, 4242)
        XCTAssertEqual(seen?["startDebugging"] as? Bool, true)
        XCTAssertEqual((seen?["parentInitialize"] as? [String: Any])?["supportsRunInTerminalRequest"] as? Bool, true)
        XCTAssertEqual((seen?["parentInitialize"] as? [String: Any])?["supportsStartDebuggingRequest"] as? Bool, true)
        // The child launches with what `startDebugging` said, and gets the breakpoints.
        XCTAssertEqual((seen?["childLaunch"] as? [String: Any])?["__pendingTargetId"] as? String, "t1")
        XCTAssertEqual(Array(((seen?["child"] as? [String]) ?? []).prefix(4)), ["initialize", "launch", "setBreakpoints", "setExceptionBreakpoints"])
        XCTAssertEqual(child?.currentFrame?.name, "square")

        child?.resume()
        await fulfillment(of: [ended], timeout: 10)
        parent.stop()
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertFalse(parent.isActive)
    }
}

/// The real adapters, on a small program each: stopped at a breakpoint, a local read and an
/// expression evaluated, and run to the end. Opt-in (`SIDE_DEBUGGER_TESTS=1`), and each skips
/// unless its adapter is installed (`SIDE_DEBUGGERS_FOLDER` and `SIDE_DLV` point at others).
@MainActor
final class RealAdapterTests: XCTestCase {
    private func skipUnlessAsked() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SIDE_DEBUGGER_TESTS"] == "1", "set SIDE_DEBUGGER_TESTS=1 (TEST_RUNNER_SIDE_DEBUGGER_TESTS=1)")
    }

    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("side-adapter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return URL(fileURLWithPath: realPath(root.path))
    }

    /// Runs one to a stop at `line` (zero-based) in `file`, checks `local` is `value` and
    /// `expression` is `result`, then to the end; returns what the program printed.
    private func debug(_ configuration: DebugConfiguration, preset: DebugAdapterPreset, file: URL, line: Int,
                       local: String, value: String, expression: String, result: String) async throws -> String {
        let connection = try XCTUnwrap(DebugAdapters.connection(for: preset), "\(preset.name) isn't installed")
        let store = BreakpointStore(project: URL(fileURLWithPath: configuration.directory), defaults: throwawayDefaults())
        store.toggle(path: file.path, line: line)
        let printed = LockedBox("")
        var sessions: [DebugSession] = []
        let stopped = expectation(description: "stopped")
        let ended = expectation(description: "ended")
        var stoppedSession: DebugSession?
        func watch(_ session: DebugSession) {
            session.onChange = {
                switch session.state {
                case .stopped: if stoppedSession == nil { stoppedSession = session; stopped.fulfill() }
                case .ended: if session === stoppedSession { ended.fulfill() }
                default: break
                }
            }
            session.onOutput = { text, fromProgram in if fromProgram { printed.value += text } }
            session.runInTerminal = { arguments, directory, environment, _ in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = arguments
                process.currentDirectoryURL = URL(fileURLWithPath: directory)
                // A terminal's environment, as a Run tab gives it: not the test host's (its
                // injected XCTest libraries hang an interpreter that loads them).
                let spawning = LanguageServerRegistry.environmentForSpawning()
                process.environment = ["PATH": spawning["PATH"] ?? "/usr/bin:/bin", "HOME": NSHomeDirectory(), "TERM": "xterm-256color"].merging(environment) { $1 }
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if !data.isEmpty { printed.value += String(decoding: data, as: UTF8.self) }
                }
                guard (try? process.run()) != nil else { return nil }
                return process.processIdentifier
            }
            session.onStartChild = { request, arguments in
                var child = session.configuration
                child.request = request
                child.launchArguments = arguments
                let next = DebugSession(configuration: child, connection: .socket(port: session.port!), adapterID: preset.adapterID, breakpoints: store)
                watch(next)
                sessions.append(next)
                Task { await next.start() }
            }
        }
        let session = DebugSession(configuration: configuration, connection: connection, adapterID: preset.adapterID, breakpoints: store)
        watch(session)
        sessions.append(session)
        await session.start()
        await fulfillment(of: [stopped], timeout: 40)
        let paused = try XCTUnwrap(stoppedSession, "the program printed: " + printed.value)
        let frame = try XCTUnwrap(paused.currentFrame)
        XCTAssertEqual(frame.line, line + 1, frame.name)
        let scopes = await paused.scopes(frameID: frame.id)
        var locals: [DAPVariable] = []
        for scope in scopes where !scope.expensive { locals += await paused.variables(scope.variablesReference) }
        XCTAssertEqual(locals.first { $0.name == local }?.value, value, locals.map { "\($0.name)=\($0.value)" }.joined(separator: ", "))
        let evaluated = await paused.evaluate(expression, context: "watch")
        XCTAssertEqual(try evaluated.get().result, result)
        store.removeAll()
        await paused.sendBreakpoints(path: file.path)
        paused.resume()
        await fulfillment(of: [ended], timeout: 60)
        for session in sessions where session.isActive { session.stop() }
        // Stopping gives an adapter a second to answer `disconnect`.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertTrue(sessions.allSatisfy { !$0.isActive })
        return printed.value
    }

    /// A real project debugged the ways Side offers, recorded as it happens (SIDE_DEMO_REPO, a
    /// copy is used; SIDE_DEMO_OUT): each session's states, children, what the program printed,
    /// and what's still running after. For looking at, not asserting.
    func testARealProjectsTimeline() async throws {
        try skipUnlessAsked()
        guard let demo = ProcessInfo.processInfo.environment["SIDE_DEMO_REPO"] else { throw XCTSkip("set SIDE_DEMO_REPO") }
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = Budgets.run("/bin/cp", ["-R", demo + "/.", root.path])
        let breakpointFile = root.appendingPathComponent(ProcessInfo.processInfo.environment["SIDE_DEMO_BREAKPOINT_FILE"] ?? "src/greeter.ts")
        let breakpointLine = Int(ProcessInfo.processInfo.environment["SIDE_DEMO_BREAKPOINT_LINE"] ?? "6") ?? 6
        var report: [String] = []
        for configuration in [DebugLaunch.npmScript("start", root: root), DebugLaunch.nodeFile(root.appendingPathComponent("src/index.js"), root: root)] {
            let preset = DebugAdapters.jsDebug
            let connection = try XCTUnwrap(DebugAdapters.connection(for: preset))
            let store = BreakpointStore(project: root, defaults: throwawayDefaults())
            store.toggle(path: breakpointFile.path, line: breakpointLine)
            let start = CACurrentMediaTime()
            let log = LockedBox<[String]>([])
            let note: @Sendable (String) -> Void = { text in log.value.append(String(format: "%7.0f ms  ", (CACurrentMediaTime() - start) * 1000) + text) }
            var sessions: [DebugSession] = []
            var children: [Process] = []
            func watch(_ session: DebugSession, _ name: String) {
                session.onChange = { note("\(name): \(session.state)\(session.currentFrame.map { " at \($0.name):\($0.line)" } ?? "")") }
                session.onOutput = { text, fromProgram in note("\(name) \(fromProgram ? "program" : "adapter"): " + text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160)) }
                session.runInTerminal = { arguments, directory, environment, _ in
                    note("\(name) runInTerminal: " + arguments.joined(separator: " ").prefix(160))
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                    process.arguments = arguments
                    process.currentDirectoryURL = URL(fileURLWithPath: directory)
                    let spawning = LanguageServerRegistry.environmentForSpawning()
                    process.environment = ["PATH": spawning["PATH"] ?? "/usr/bin:/bin", "HOME": NSHomeDirectory(), "TERM": "xterm-256color"].merging(environment) { $1 }
                    let pipe = Pipe()
                    process.standardOutput = pipe
                    process.standardError = pipe
                    pipe.fileHandleForReading.readabilityHandler = { handle in
                        let data = handle.availableData
                        if data.isEmpty { handle.readabilityHandler = nil } else { note("\(name) terminal: " + String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)) }
                    }
                    guard (try? process.run()) != nil else { return nil }
                    children.append(process)
                    return process.processIdentifier
                }
                session.onStartChild = { request, arguments in
                    note("\(name) starts a child: \(request)")
                    var child = session.configuration
                    child.request = request
                    child.launchArguments = arguments
                    let next = DebugSession(configuration: child, connection: .socket(port: session.port!), adapterID: preset.adapterID, breakpoints: store)
                    watch(next, name + ".child\(sessions.count)")
                    sessions.append(next)
                    Task { await next.start() }
                }
            }
            let session = DebugSession(configuration: configuration, connection: connection, adapterID: preset.adapterID, breakpoints: store)
            watch(session, "root")
            sessions.append(session)
            await session.start()
            let deadline = Date().addingTimeInterval(15)
            func stopped(_ session: DebugSession) -> Bool { if case .stopped = session.state { return true } else { return false } }
            while Date() < deadline, sessions.contains(where: \.isActive), !sessions.contains(where: stopped) { try await Task.sleep(nanoseconds: 50_000_000) }
            note("verified: \(store.breakpoints(in: breakpointFile.path).map { "\($0.line + 1)=\($0.verified.map(String.init) ?? "nil")" })")
            for session in sessions where session.isActive { session.stop() }
            try await Task.sleep(nanoseconds: 2_000_000_000)
            note("still active: \(sessions.filter(\.isActive).count) of \(sessions.count); terminal processes still running: \(children.filter(\.isRunning).count) of \(children.count)")
            note("processes on the copy: " + Budgets.run("/bin/sh", ["-c", "pgrep -fl \(root.lastPathComponent) || true"]).trimmingCharacters(in: .whitespacesAndNewlines))
            children.filter(\.isRunning).forEach { $0.terminate() }
            report.append("== \(configuration.name)\n" + log.value.joined(separator: "\n"))
        }
        try report.joined(separator: "\n\n").write(toFile: ProcessInfo.processInfo.environment["SIDE_DEMO_OUT"] ?? "/tmp/side-demo.txt", atomically: true, encoding: .utf8)
    }

    private static let squares = "total 14"

    func testJsDebugOnTypeScript() async throws {
        try skipUnlessAsked()
        try XCTSkipUnless(DebugAdapters.isInstalled(DebugAdapters.jsDebug), "js-debug isn't installed")
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("app.ts")
        try """
        function square(n: number): number {
          const result = n * n;
          return result;
        }
        let total = 0;
        for (let i = 1; i <= 3; i++) total += square(i);
        console.log("total", total);
        """.write(to: file, atomically: true, encoding: .utf8)
        let printed = try await debug(DebugLaunch.nodeFile(file, root: root), preset: DebugAdapters.jsDebug, file: file, line: 2,
                                      local: "result", value: "1", expression: "result * 10", result: "10")
        XCTAssertTrue(printed.contains(Self.squares), printed)
    }

    func testDebugpyOnPython() async throws {
        try skipUnlessAsked()
        try XCTSkipUnless(DebugAdapters.isInstalled(DebugAdapters.debugpy), "debugpy isn't installed")
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("app.py")
        try """
        def square(n):
            result = n * n
            return result

        total = 0
        for i in range(1, 4):
            total += square(i)
        print("total", total)
        """.write(to: file, atomically: true, encoding: .utf8)
        // debugpy's own environment runs the program: a global Python's .pth files can point
        // into folders (~/Documents) this test process may not read, and wait on the prompt.
        var configuration = DebugLaunch.pythonFile(file, root: root)
        configuration.launchArguments?["python"] = .string(DebugAdapters.debugpyPython.path)
        let printed = try await debug(configuration, preset: DebugAdapters.debugpy, file: file, line: 2,
                                      local: "result", value: "1", expression: "result * 10", result: "10")
        XCTAssertTrue(printed.contains(Self.squares), printed)
    }

    func testDelveOnGo() async throws {
        try skipUnlessAsked()
        try XCTSkipUnless(DebugAdapters.isInstalled(DebugAdapters.delve), "Delve isn't installed")
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try "module example.com/demo\n\ngo 1.22\n".write(to: root.appendingPathComponent("go.mod"), atomically: true, encoding: .utf8)
        let file = root.appendingPathComponent("main.go")
        try """
        package main

        import "fmt"

        func square(n int) int {
        \tresult := n * n
        \treturn result
        }

        func main() {
        \ttotal := 0
        \tfor i := 1; i <= 3; i++ {
        \t\ttotal += square(i)
        \t}
        \tfmt.Println("total", total)
        }
        """.write(to: file, atomically: true, encoding: .utf8)
        let printed = try await debug(DebugLaunch.goPackage(root, root: root), preset: DebugAdapters.delve, file: file, line: 6,
                                      local: "result", value: "1", expression: "result * 10", result: "10")
        XCTAssertTrue(printed.contains(Self.squares), printed)
    }
}

/// Side's own installs (js-debug from its GitHub release, debugpy in an environment of its own)
/// into a folder of the test's (`SIDE_DEBUGGERS_FOLDER`), then found. Opt-in: it downloads
/// (`SIDE_NETWORK_TESTS=1`).
final class DebugAdapterInstallTests: XCTestCase {
    func testSidesOwnInstallsWork() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SIDE_NETWORK_TESTS"] == "1", "set SIDE_NETWORK_TESTS=1 (TEST_RUNNER_SIDE_NETWORK_TESTS=1) to download the debuggers")
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SIDE_DEBUGGERS_FOLDER"] != nil, "set SIDE_DEBUGGERS_FOLDER (TEST_RUNNER_SIDE_DEBUGGERS_FOLDER) to a folder the installs may fill")
        for preset in [DebugAdapters.jsDebug, DebugAdapters.debugpy] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", preset.install!.command]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let log = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, "\(preset.name): \(log)")
            XCTAssertTrue(DebugAdapters.isInstalled(preset), preset.name)
        }
    }
}

/// Opt-in, as the language servers' start test: every installed adapter starts and answers
/// `initialize` (SIDE_SERVER_TESTS=1).
@MainActor
final class DebugAdapterStartTests: XCTestCase {
    func testEachInstalledAdapterStartsAndAnswers() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SIDE_SERVER_TESTS"] == "1", "set SIDE_SERVER_TESTS=1 (TEST_RUNNER_SIDE_SERVER_TESTS=1) to start the installed adapters")
        var tried: [String] = []
        for preset in DebugAdapters.presets {
            guard let connection = DebugAdapters.connection(for: preset) else { continue }
            tried.append(preset.id)
            let client = try DAPClient(connection: connection, environment: LanguageServerRegistry.environmentForSpawning(), currentDirectory: FileManager.default.temporaryDirectory)
            await client.setHandlers(onEvent: { _, _ in }, onTerminate: {})
            do {
                try await client.start()
                let reply = try await client.request("initialize", ["clientID": "side", "adapterID": .string(preset.adapterID), "linesStartAt1": true, "columnsStartAt1": true, "pathFormat": "path"])
                XCTAssertNotNil(reply.object, preset.id)
            } catch {
                XCTFail("\(preset.name) didn't answer initialize: \(error.localizedDescription)")
            }
            await client.stop()
        }
        print("Adapters started: \(tried)")
    }
}
