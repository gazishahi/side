import AlloyCore
import Foundation

// MARK: What a stopped program looks like

struct DAPThread: Equatable, Sendable {
    let id: Int
    let name: String
}

struct DAPStackFrame: Equatable, Sendable {
    let id: Int
    let name: String
    /// The source file, if the frame has one (a system library's doesn't).
    let path: String?
    /// One-based, as the protocol counts (Side asks for that).
    let line: Int
    let column: Int
    /// "subtle" frames (the adapter's hint for library code).
    let isSubtle: Bool

    init?(_ value: Any) {
        guard let object = value as? [String: Any], let id = object["id"] as? Int, let name = object["name"] as? String else { return nil }
        self.id = id
        self.name = name
        let source = object["source"] as? [String: Any]
        path = source?["path"] as? String
        line = object["line"] as? Int ?? 0
        column = object["column"] as? Int ?? 0
        isSubtle = (object["presentationHint"] as? String) == "subtle" || (source?["presentationHint"] as? String) == "deemphasize"
    }
}

struct DAPScope: Equatable, Sendable {
    let name: String
    let variablesReference: Int
    let expensive: Bool

    init?(_ value: Any) {
        guard let object = value as? [String: Any], let name = object["name"] as? String, let reference = object["variablesReference"] as? Int else { return nil }
        self.name = name
        variablesReference = reference
        expensive = object["expensive"] as? Bool ?? false
    }
}

struct DAPVariable: Equatable, Sendable {
    let name: String
    let value: String
    let type: String?
    /// Non-zero when it has children, fetched when it's opened.
    let variablesReference: Int
    /// How many children, if the adapter says (arrays: indexed, objects: named).
    let indexedCount: Int?
    let namedCount: Int?

    init?(_ value: Any) {
        guard let object = value as? [String: Any], let name = object["name"] as? String else { return nil }
        self.name = name
        self.value = object["value"] as? String ?? ""
        type = object["type"] as? String
        variablesReference = object["variablesReference"] as? Int ?? 0
        indexedCount = object["indexedVariables"] as? Int
        namedCount = object["namedVariables"] as? Int
    }
}

// MARK: Breakpoints

/// A breakpoint on a line (zero-based, as Alloy counts). `verified` is the adapter's say while a
/// session runs: nil before one has.
struct Breakpoint: Codable, Equatable, Sendable {
    var line: Int
    var enabled = true
    /// Stops only when this expression is true.
    var condition: String?
    /// Stops only on the hits this says ("5", ">= 10", "% 2", as the adapter reads it).
    var hitCondition: String?
    /// A logpoint: prints this ({expressions} in braces filled in) and doesn't stop.
    var logMessage: String?
    var verified: Bool? = nil
    /// Why the adapter couldn't place it, when it says.
    var message: String? = nil

    init(line: Int, enabled: Bool = true) {
        self.line = line
        self.enabled = enabled
    }

    var isLogpoint: Bool { !(logMessage ?? "").isEmpty }
    var hasOptions: Bool { !(condition ?? "").isEmpty || !(hitCondition ?? "").isEmpty || isLogpoint }

    enum CodingKeys: String, CodingKey { case line, enabled, condition, hitCondition, logMessage }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        line = try container.decode(Int.self, forKey: .line)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        condition = try container.decodeIfPresent(String.self, forKey: .condition)
        hitCondition = try container.decodeIfPresent(String.self, forKey: .hitCondition)
        logMessage = try container.decodeIfPresent(String.self, forKey: .logMessage)
    }
}

/// The project's breakpoints, by file path, kept across launches (SIDE_RFC_DEBUGGER.md, D3). They
/// follow edits: a line typed above one moves it down.
@MainActor
final class BreakpointStore {
    static let didChangeNotification = Notification.Name("SideBreakpointsDidChange")
    private static let key = "SideBreakpoints"

    private let project: String
    private let defaults: UserDefaults
    private(set) var byPath: [String: [Breakpoint]] = [:]

    init(project: URL, defaults: UserDefaults = MakeWorkspaceViewController.preferences) {
        self.project = project.standardizedFileURL.path
        self.defaults = defaults
        let all = defaults.dictionary(forKey: Self.key) as? [String: Data] ?? [:]
        if let data = all[self.project], let decoded = try? JSONDecoder().decode([String: [Breakpoint]].self, from: data) { byPath = decoded }
    }

    /// Tells the gutter at once; writes to preferences once per turn of the run loop (a
    /// keystroke's edits, a burst of typing), not per change.
    private func save() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        guard !savePending else { return }
        savePending = true
        DispatchQueue.main.async { [weak self] in self?.persist() }
    }
    private var savePending = false

    /// Writes now (and what a pending save would have).
    func persist() {
        savePending = false
        var all = defaults.dictionary(forKey: Self.key) as? [String: Data] ?? [:]
        let kept = byPath.filter { !$0.value.isEmpty }
        all[project] = kept.isEmpty ? nil : try? JSONEncoder().encode(kept)
        defaults.set(all, forKey: Self.key)
    }

    func breakpoints(in path: String) -> [Breakpoint] { byPath[path] ?? [] }

    var all: [(path: String, breakpoint: Breakpoint)] {
        byPath.sorted { $0.key < $1.key }.flatMap { path, list in list.sorted { $0.line < $1.line }.map { (path, $0) } }
    }

    /// Adds a breakpoint on the line, or removes the one there.
    func toggle(path: String, line: Int) {
        var list = byPath[path] ?? []
        if let index = list.firstIndex(where: { $0.line == line }) { list.remove(at: index) } else { list.append(Breakpoint(line: line)) }
        byPath[path] = list
        save()
    }

    func contains(path: String, line: Int) -> Bool { byPath[path]?.contains { $0.line == line } ?? false }

    /// A breakpoint's condition, hit count and log message (empty clears one).
    func setOptions(path: String, line: Int, condition: String?, hitCondition: String?, logMessage: String?) {
        guard let index = byPath[path]?.firstIndex(where: { $0.line == line }) else { return }
        func clean(_ text: String?) -> String? {
            let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        byPath[path]?[index].condition = clean(condition)
        byPath[path]?[index].hitCondition = clean(hitCondition)
        byPath[path]?[index].logMessage = clean(logMessage)
        save()
    }

    /// The exception breakpoints turned on, by the adapter's filter ids (nil: the adapter's
    /// defaults, until the person picks).
    var exceptionFilters: Set<String>? {
        get { (defaults.dictionary(forKey: Self.exceptionsKey)?[project] as? [String]).map(Set.init) }
        set {
            var all = defaults.dictionary(forKey: Self.exceptionsKey) ?? [:]
            all[project] = newValue.map { Array($0).sorted() }
            defaults.set(all, forKey: Self.exceptionsKey)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }
    private static let exceptionsKey = "SideExceptionBreakpoints"

    /// Watch expressions, in order, kept per project.
    var watches: [String] {
        get { defaults.dictionary(forKey: Self.watchesKey)?[project] as? [String] ?? [] }
        set {
            var all = defaults.dictionary(forKey: Self.watchesKey) ?? [:]
            all[project] = newValue.isEmpty ? nil : newValue
            defaults.set(all, forKey: Self.watchesKey)
        }
    }
    private static let watchesKey = "SideWatchExpressions"

    func setEnabled(_ enabled: Bool, path: String, line: Int) {
        guard let index = byPath[path]?.firstIndex(where: { $0.line == line }) else { return }
        byPath[path]?[index].enabled = enabled
        save()
    }

    func remove(path: String, line: Int) {
        byPath[path]?.removeAll { $0.line == line }
        save()
    }

    func removeAll() {
        byPath = [:]
        save()
    }

    /// What a session said about a file's breakpoints: which it could place, and on which line
    /// (an adapter moves one on a blank line to the next line with code).
    func verified(path: String, lines: [(requested: Int, actual: Int?, verified: Bool)], messages: [Int: String] = [:]) {
        guard var list = byPath[path] else { return }
        for answer in lines {
            guard let index = list.firstIndex(where: { $0.line == answer.requested }) else { continue }
            list[index].verified = answer.verified
            list[index].message = messages[answer.requested]
            if let actual = answer.actual, actual != answer.requested, !list.contains(where: { $0.line == actual }) { list[index].line = actual }
        }
        byPath[path] = list
        save()
    }

    func clearVerification() {
        for key in byPath.keys { byPath[key] = byPath[key]?.map { var b = $0; b.verified = nil; b.message = nil; return b } }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    /// Edits to a file, in order, and its text after them: breakpoints below an edit move by the
    /// lines it added or removed; one inside removed lines goes to the edit's line.
    func follow(path: String, edits: [AppliedEdit], text: Rope) {
        guard var list = byPath[path], !list.isEmpty else { return }
        // The text before the edits: each undone, last first.
        var snapshot = text
        for edit in edits.reversed() {
            let inverse = edit.inverse
            guard inverse.range.upperBound <= snapshot.utf16Count else { return }
            snapshot.replace(inverse.range, with: inverse.newText)
        }
        var changed = false
        for edit in edits {
            let removed = edit.oldText.reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
            let added = edit.newText.reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
            if removed != added {
                let line = snapshot.line(containing: edit.range.lowerBound)
                // Text typed at a line's very start (a line inserted above) pushes that line down.
                let pushesLine = removed == 0 && edit.range.lowerBound == snapshot.offset(ofLine: line)
                list = list.map { breakpoint in
                    var moved = breakpoint
                    if breakpoint.line > line + removed || (pushesLine && breakpoint.line == line) {
                        moved.line = breakpoint.line + added - removed
                    } else if breakpoint.line > line {
                        moved.line = line   // its line was removed
                    }
                    return moved
                }
                changed = true
            }
            snapshot.replace(edit.range, with: edit.newText)
        }
        guard changed else { return }
        // Two that met on one line are one.
        var seen = Set<Int>()
        byPath[path] = list.filter { seen.insert($0.line).inserted }
        save()
    }
}

// MARK: A session

/// What's being debugged (SIDE_RFC_DEBUGGER.md, D3): the program, and a build to run first.
struct DebugConfiguration: Equatable, Sendable {
    var name: String
    /// The adapter (`DebugAdapterPreset.id`).
    var adapter: String = DebugAdapters.lldb.id
    /// "launch" or "attach".
    var request = "launch"
    /// The adapter's own launch arguments (js-debug's, debugpy's, Delve's), sent as they are;
    /// nil builds lldb-dap's from `program`, `arguments` and `environment`.
    var launchArguments: [String: LSPValue]?
    var program: String = ""
    var arguments: [String] = []
    var directory: String
    var environment: [String: String] = [:]
    /// A command run first in `directory` (`swift build --product X`); the session starts when
    /// it succeeds.
    var build: String?
    /// The terminal the program reads and writes (a Run tab's pty), or nil for the adapter's
    /// output events.
    var terminal: String?
}

/// An exception breakpoint the adapter offers (`exceptionBreakpointFilters`).
struct DAPExceptionFilter: Equatable, Sendable {
    let id: String
    let label: String
    let isDefault: Bool
}

/// What an expression came to in a frame.
struct DAPEvaluation: Equatable, Sendable {
    let result: String
    let type: String?
    let variablesReference: Int
}

/// One debugging session with one adapter (SIDE_RFC_DEBUGGER.md): launch, breakpoints, stops,
/// stepping, and what a stopped program looks like. Main-actor; the adapter's messages arrive
/// through `DAPClient`.
@MainActor
final class DebugSession {
    enum State: Equatable {
        case building
        case starting
        case running
        case stopped(reason: String, threadID: Int, text: String?)
        case ended(String?)
    }

    let configuration: DebugConfiguration
    let breakpoints: BreakpointStore
    private(set) var state: State = .starting { didSet { if state != oldValue { onChange?() } } }
    private(set) var threads: [DAPThread] = []
    private(set) var frames: [DAPStackFrame] = []
    private(set) var selectedFrame = 0
    /// The program's and the adapter's output, most recent last (a few hundred KB kept).
    private(set) var output = ""
    var onChange: (() -> Void)?
    /// Text added to the output, and whether the program wrote it (not the adapter or a build).
    var onOutput: ((String, Bool) -> Void)?
    /// The adapter's `stopped` event, before the stack is asked for (the step budget's start).
    var onStopEvent: (() -> Void)?

    /// The adapter asked to run the program in a terminal (`runInTerminal`): its arguments,
    /// directory, environment and title. The answer is the process id, or nil if it couldn't.
    var runInTerminal: (([String], String, [String: String], String) async -> Int32?)?
    /// The adapter asked for a child session (`startDebugging`, js-debug's program sessions):
    /// the request and its configuration, to start over this session's connection.
    var onStartChild: ((String, [String: LSPValue]) -> Void)?

    private let connection: DAPConnection
    private let adapterID: String
    private var client: DAPClient?
    private var capabilities: [String: Any] = [:]
    private var configured = false
    /// The adapter's ids for the breakpoints it answered, to follow its `breakpoint` events.
    private var placedBreakpoints: [Int: (path: String, line: Int)] = [:]
    /// The port a server adapter listens on, for a child session.
    private(set) var port: UInt16?

    init(configuration: DebugConfiguration, connection: DAPConnection, adapterID: String, breakpoints: BreakpointStore) {
        self.configuration = configuration
        self.connection = connection
        self.adapterID = adapterID
        self.breakpoints = breakpoints
    }

    convenience init(configuration: DebugConfiguration, adapter: URL, adapterArguments: [String] = [], breakpoints: BreakpointStore) {
        self.init(configuration: configuration, connection: .stdio(executable: adapter, arguments: adapterArguments), adapterID: DebugAdapters.lldb.adapterID, breakpoints: breakpoints)
    }

    var isActive: Bool { if case .ended = state { return false } else { return true } }
    var isStopped: Bool { if case .stopped = state { return true } else { return false } }
    var currentFrame: DAPStackFrame? { frames.indices.contains(selectedFrame) ? frames[selectedFrame] : nil }

    /// Builds (if asked), then launches under the adapter.
    func start() async {
        if let build = configuration.build {
            state = .building
            appendOutput("$ \(build)\n")
            let (status, log) = await Self.run(build, in: configuration.directory)
            appendOutput(log)
            guard status == 0 else { return state = .ended("The build failed (exit \(status)).") }
        }
        state = .starting
        do {
            // A server adapter builds and runs from the project (Delve's `go build`), and finds
            // the person's tools on their PATH.
            let client = try DAPClient(connection: connection, environment: Self.adapterEnvironment(),
                                       currentDirectory: URL(fileURLWithPath: realPath(configuration.directory)))
            self.client = client
            port = client.port
            await client.setHandlers(
                onEvent: { [weak self] event, body in Task { @MainActor in self?.handle(event: event, body: body) } },
                onTerminate: { [weak self] in Task { @MainActor in self?.adapterExited() } },
                onReverseRequest: { [weak self] command, arguments in
                    guard let self else { return .failure(.notRunning) }
                    return await self.answer(command, arguments)
                }
            )
            try await client.start()
            let initialize = try await client.request("initialize", [
                "clientID": "side", "clientName": "Side", "adapterID": .string(adapterID), "locale": "en",
                "linesStartAt1": true, "columnsStartAt1": true, "pathFormat": "path",
                "supportsVariableType": true, "supportsVariablePaging": true,
                "supportsRunInTerminalRequest": .bool(runInTerminal != nil), "supportsStartDebuggingRequest": .bool(onStartChild != nil),
            ])
            capabilities = initialize.object ?? [:]
            // The launch's response may come only after configurationDone, so it isn't awaited
            // before configuring (the adapter's `initialized` event starts that).
            var arguments: [String: LSPValue] = configuration.launchArguments.map(Self.realPaths) ?? [
                "program": .string(realPath(configuration.program)), "args": .array(configuration.arguments.map { .string($0) }),
                "cwd": .string(realPath(configuration.directory)), "stopOnEntry": false,
            ]
            // The program on a Run tab's terminal, so its input works. lldb's own target
            // settings: lldb-1703's `runInTerminal` launcher times out on macOS, and it ignores
            // the newer `stdio` argument.
            if let terminal = configuration.terminal, configuration.launchArguments == nil {
                arguments["preRunCommands"] = .array(["input", "output", "error"].map { .string("settings set target.\($0)-path \(terminal)") })
            }
            if !configuration.environment.isEmpty, configuration.launchArguments == nil {
                arguments["env"] = .array(configuration.environment.map { .string("\($0.key)=\($0.value)") })
            }
            await client.send(configuration.request, .object(arguments)) { [weak self] result in
                Task { @MainActor in
                    if case .failure(let error) = result { self?.appendOutput("Launch failed: \(error.localizedDescription)\n"); self?.end(error.localizedDescription) }
                }
            }
        } catch {
            end("Couldn't start the debugger: \(error.localizedDescription)")
        }
    }

    /// The adapter's requests of Side.
    private func answer(_ command: String, _ arguments: LSPResult) async -> Result<LSPValue, DAPClient.DAPError> {
        let object = arguments.object ?? [:]
        switch command {
        case "runInTerminal":
            guard let runInTerminal, let args = object["args"] as? [String], !args.isEmpty else { break }
            let cwd = object["cwd"] as? String ?? configuration.directory
            // A null value means "unset"; the terminal's environment is the person's anyway.
            let environment = (object["env"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
            let title = (object["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? configuration.name
            guard let pid = await runInTerminal(args, cwd, environment, title) else {
                return .failure(.failed(command: command, message: "Couldn't open a terminal for the program."))
            }
            return .success(["processId": .int(Int(pid))])
        case "startDebugging":
            guard let onStartChild, let configuration = object["configuration"] as? [String: Any] else { break }
            let request = object["request"] as? String ?? "launch"
            onStartChild(request, configuration.mapValues { LSPValue(any: $0) })
            return .success([:])
        default:
            break
        }
        return .failure(.failed(command: command, message: "\(command) isn't supported"))
    }

    private func handle(event: String, body: LSPResult) {
        let object = body.object ?? [:]
        switch event {
        case "initialized":
            Task { await configure() }
        case "stopped":
            let threadID = object["threadId"] as? Int ?? threads.first?.id ?? 1
            let reason = object["reason"] as? String ?? "pause"
            var text = object["text"] as? String ?? object["description"] as? String
            // Pausing an attached process stops it with SIGSTOP, which lldb reports as a signal.
            if text?.contains("SIGSTOP") == true { text = nil }
            // A breakpoint that was hit is placed, whatever an earlier event said (lldb-dap
            // reports one unverified while the program's modules load, then stops at it).
            for id in object["hitBreakpointIds"] as? [Int] ?? [] {
                guard let placed = placedBreakpoints[id] else { continue }
                breakpoints.verified(path: placed.path, lines: [(requested: placed.line, actual: placed.line, verified: true)])
            }
            onStopEvent?()
            Task { await stopped(threadID: threadID, reason: reason, text: text) }
        case "continued":
            frames = []
            state = .running
        case "output":
            let category = object["category"] as? String ?? "console"
            guard let text = object["output"] as? String, category != "telemetry" else { return }
            // lldb-dap echoes the commands Side gave it (the program's terminal); they're Side's
            // plumbing, not the program's or the person's.
            if category == "console", text == "Running preRunCommands:\n" || text.hasPrefix("(lldb) settings set target.") { return }
            appendOutput(text, fromProgram: category == "stdout" || category == "stderr")
        case "breakpoint":
            // A breakpoint the adapter placed (or moved) after answering: js-debug's
            // "provisional" ones bind once the script loads.
            guard let breakpoint = object["breakpoint"] as? [String: Any], let id = breakpoint["id"] as? Int,
                  let placed = placedBreakpoints[id] else { return }
            let line = (breakpoint["line"] as? Int).map { $0 - 1 }
            breakpoints.verified(path: placed.path, lines: [(requested: placed.line, actual: line, verified: breakpoint["verified"] as? Bool ?? false)])
            if let line { placedBreakpoints[id] = (placed.path, line) }
        case "exited":
            if let code = object["exitCode"] as? Int { appendOutput("\nThe program exited with code \(code).\n") }
        case "terminated":
            end(nil)
        default:
            break
        }
    }

    /// After `initialized`: every file's breakpoints, no exception breakpoints (step 2), then go.
    private func configure() async {
        guard let client, !configured else { return }
        configured = true
        for (path, _) in breakpoints.byPath { await sendBreakpoints(path: path) }
        await sendExceptionBreakpoints()
        if case .starting = state { state = .running }
        _ = try? await client.request("configurationDone")
    }

    /// The adapter's exception breakpoints, from `initialize`.
    var exceptionFilters: [DAPExceptionFilter] {
        (capabilities["exceptionBreakpointFilters"] as? [[String: Any]] ?? []).compactMap { filter in
            guard let id = filter["filter"] as? String else { return nil }
            return DAPExceptionFilter(id: id, label: filter["label"] as? String ?? id, isDefault: filter["default"] as? Bool ?? false)
        }
    }

    /// The exception breakpoints turned on: the person's, else the adapter's defaults.
    var enabledExceptionFilters: Set<String> {
        breakpoints.exceptionFilters ?? Set(exceptionFilters.filter(\.isDefault).map(\.id))
    }

    func sendExceptionBreakpoints() async {
        guard let client else { return }
        let offered = Set(exceptionFilters.map(\.id))
        let filters = enabledExceptionFilters.intersection(offered).sorted()
        _ = try? await client.request("setExceptionBreakpoints", ["filters": .array(filters.map { .string($0) })])
    }

    /// An expression in the selected frame: the console's ("repl"), a watch's ("watch") or the
    /// pointer's ("hover").
    func evaluate(_ expression: String, context: String) async -> Result<DAPEvaluation, DAPClient.DAPError> {
        guard let client else { return .failure(.notRunning) }
        var arguments: [String: LSPValue] = ["expression": .string(expression), "context": .string(context)]
        if let frame = currentFrame { arguments["frameId"] = .int(frame.id) }
        do {
            let reply = try await client.request("evaluate", .object(arguments))
            let object = reply.object ?? [:]
            return .success(DAPEvaluation(result: object["result"] as? String ?? "", type: object["type"] as? String,
                                          variablesReference: object["variablesReference"] as? Int ?? 0))
        } catch let error as DAPClient.DAPError {
            return .failure(error)
        } catch {
            return .failure(.failed(command: "evaluate", message: error.localizedDescription))
        }
    }

    /// A file's breakpoints, as they are now (called on each change while a session runs).
    func sendBreakpoints(path: String) async {
        guard let client else { return }
        let enabled = breakpoints.breakpoints(in: path).filter(\.enabled).sorted { $0.line < $1.line }
        let arguments: LSPValue = [
            "source": ["path": .string(realPath(path)), "name": .string((path as NSString).lastPathComponent)],
            "breakpoints": .array(enabled.map { breakpoint in
                var entry: [String: LSPValue] = ["line": .int(breakpoint.line + 1)]
                if let condition = breakpoint.condition { entry["condition"] = .string(condition) }
                if let hitCondition = breakpoint.hitCondition { entry["hitCondition"] = .string(hitCondition) }
                if let logMessage = breakpoint.logMessage { entry["logMessage"] = .string(logMessage) }
                return .object(entry)
            }),
            "sourceModified": false,
        ]
        guard let reply = try? await client.request("setBreakpoints", arguments),
              let placed = reply.object?["breakpoints"] as? [[String: Any]] else { return }
        let answers = zip(enabled, placed).map { requested, answer -> (Int, Int?, Bool) in
            (requested.line, (answer["line"] as? Int).map { $0 - 1 }, answer["verified"] as? Bool ?? false)
        }
        var messages: [Int: String] = [:]
        for (requested, answer) in zip(enabled, placed) {
            if let message = answer["message"] as? String { messages[requested.line] = message }
            if let id = answer["id"] as? Int { placedBreakpoints[id] = (path, (answer["line"] as? Int).map { $0 - 1 } ?? requested.line) }
        }
        breakpoints.verified(path: path, lines: answers.map { (requested: $0.0, actual: $0.1, verified: $0.2) }, messages: messages)
    }

    private func stopped(threadID: Int, reason: String, text: String?) async {
        guard let client else { return }
        if let reply = try? await client.request("threads"), let list = reply.object?["threads"] as? [Any] {
            threads = list.compactMap { value in
                (value as? [String: Any]).flatMap { t in (t["id"] as? Int).map { DAPThread(id: $0, name: t["name"] as? String ?? "Thread \($0)") } }
            }
        }
        let trace = try? await client.request("stackTrace", ["threadId": .int(threadID), "startFrame": 0, "levels": 60])
        frames = (trace?.object?["stackFrames"] as? [Any] ?? []).compactMap(DAPStackFrame.init)
        // The first frame with source code the person can read; a stop inside a library still
        // shows where the program called it.
        selectedFrame = frames.firstIndex { $0.path != nil && !$0.isSubtle } ?? 0
        state = .stopped(reason: reason, threadID: threadID, text: text)
    }

    func selectFrame(_ index: Int) {
        guard frames.indices.contains(index) else { return }
        selectedFrame = index
        onChange?()
    }

    func scopes(frameID: Int) async -> [DAPScope] {
        guard let client, let reply = try? await client.request("scopes", ["frameId": .int(frameID)]) else { return [] }
        return (reply.object?["scopes"] as? [Any] ?? []).compactMap(DAPScope.init)
    }

    /// A variable's children, a page at a time for big arrays.
    func variables(_ reference: Int, start: Int? = nil, count: Int? = nil) async -> [DAPVariable] {
        guard let client, reference > 0 else { return [] }
        var arguments: [String: LSPValue] = ["variablesReference": .int(reference)]
        if let start, let count { arguments["filter"] = "indexed"; arguments["start"] = .int(start); arguments["count"] = .int(count) }
        guard let reply = try? await client.request("variables", .object(arguments)) else { return [] }
        return (reply.object?["variables"] as? [Any] ?? []).compactMap(DAPVariable.init)
    }

    // MARK: Controls

    private var threadID: Int? { if case .stopped(_, let id, _) = state { return id } else { return threads.first?.id } }

    func resume() { command("continue") }
    func stepOver() { command("next") }
    func stepIn() { command("stepIn") }
    func stepOut() { command("stepOut") }

    func pause() {
        guard let client, case .running = state else { return }
        Task {
            // A session that hasn't stopped yet (an attached process) has no threads known.
            if threads.isEmpty, let reply = try? await client.request("threads"), let list = reply.object?["threads"] as? [[String: Any]] {
                threads = list.compactMap { t in (t["id"] as? Int).map { DAPThread(id: $0, name: t["name"] as? String ?? "Thread \($0)") } }
            }
            guard let thread = threads.first?.id else { return }
            _ = try? await client.request("pause", ["threadId": .int(thread)])
        }
    }

    private func command(_ name: String) {
        guard let client, let thread = threadID, isStopped else { return }
        frames = []
        state = .running
        Task { _ = try? await client.request(name, ["threadId": .int(thread)]) }
    }

    /// Ends the session: the program is stopped (terminated if the adapter can), the adapter too.
    func stop() {
        guard let client, isActive else { return end(nil) }
        Task {
            // An adapter needn't answer (js-debug's launcher session doesn't always): a second,
            // then the adapter (and a server's process) is stopped regardless.
            // Stopping the client fails what's pending, so the wait ends either way.
            let deadline = Task {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await client.stop()
            }
            // A launched program ends with the session; an attached one is let go, still running.
            _ = try? await client.request("disconnect", ["terminateDebuggee": .bool(configuration.request != "attach")])
            deadline.cancel()
            await client.stop()
            self.end(nil)
        }
    }

    private func adapterExited() {
        guard isActive else { return }
        end(nil)
    }

    private func end(_ message: String?) {
        guard isActive else { return }
        if let message { appendOutput("\(message)\n") }
        frames = []
        breakpoints.clearVerification()
        state = .ended(message)
        if let client { Task { await client.stop() } }
    }

    func appendOutput(_ text: String, fromProgram: Bool = false) {
        output += text
        if output.utf16.count > 400_000 { output = String(output.suffix(300_000)) }
        onOutput?(text, fromProgram)
    }

    /// An adapter's launch arguments with their paths as the file system has them: `go build`
    /// finds a module by the real path of its directory, and a breakpoint binds by the real path
    /// the compiler recorded.
    nonisolated static func realPaths(_ arguments: [String: LSPValue]) -> [String: LSPValue] {
        var arguments = arguments
        for key in ["program", "cwd"] {
            if case .string(let path)? = arguments[key], path.hasPrefix("/") { arguments[key] = .string(realPath(path)) }
        }
        return arguments
    }

    /// The person's environment (their login PATH) without what was injected into Side's own
    /// process: `DYLD_*` libraries from Xcode or XCTest, which an adapter's interpreter (and the
    /// program it starts) would load too.
    nonisolated static func adapterEnvironment() -> [String: String] {
        LanguageServerRegistry.environmentForSpawning().filter { key, _ in
            !key.hasPrefix("DYLD_") && !key.hasPrefix("__XPC_DYLD_") && !key.hasPrefix("XCTest") && key != "OS_ACTIVITY_DT_MODE"
        }
    }

    /// A shell command's status and output, off the main thread (the build).
    nonisolated static func run(_ command: String, in directory: String) async -> (Int32, String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-lc", command]
                process.currentDirectoryURL = URL(fileURLWithPath: directory)
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do { try process.run() } catch { return continuation.resume(returning: (-1, "\(error.localizedDescription)\n")) }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: (process.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
        }
    }
}
