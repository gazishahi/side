import AlloyCore
import AppKit
import Heron

/// What Make gives its debugger: the project, the editor, and a way to show a file.
@MainActor
protocol MakeDebuggerHost: AnyObject {
    var debugProjectRoot: URL? { get }
    var debugHostView: NSView { get }
    var editor: EditorEngine { get }
    /// The file shown in the editor (nil for none, or not text).
    var debugCurrentFile: URL? { get }
    /// Opens a file at a line (zero-based) and puts the caret there.
    func debugReveal(_ url: URL, line: Int)
    /// The palette as a picker (the launch configurations, the processes to attach to).
    func debugChoose(_ prompt: String, from choices: [PaletteChoice], completion: @escaping (Int) -> Void)
    /// Makes room for the inspector beside the editor and the bar over it (0s when they're gone).
    func debugSetInsets(inspector width: CGFloat, leading: Bool, bar height: CGFloat)
}

/// A Run tab the program reads and writes: its terminal's device, and a way to end the tab's
/// holder process when the session does.
struct DebugProgramTerminal {
    let tty: String
    /// The session ended: the tab stays, with what the program wrote.
    let end: () -> Void
    /// A new session replaces it: the tab goes.
    let close: () -> Void
}

/// Debugging in Make (SIDE_RFC_DEBUGGER.md): the project's breakpoints in the gutter, a session,
/// the debug bar over the editor and the inspector in the explorer's place.
@MainActor
final class MakeDebugger {
    private weak var host: MakeDebuggerHost?
    private(set) var breakpoints: BreakpointStore?
    private(set) var session: DebugSession?
    private var configuration: DebugConfiguration?
    private lazy var bar = DebugBar()
    private lazy var inspector = DebugInspector()
    private var barShown = false
    private var hideAfterEnd: DispatchWorkItem?
    /// Where the stopped line was drawn, to clear it.
    private var stoppedPath: String?
    /// The stop whose variables are shown (a newer stop drops an older answer).
    private var stopGeneration = 0
    /// How long the last stop took to show (the adapter's event to the line and stack), for the
    /// budget test.
    private(set) var lastStopShownIn: TimeInterval?
    private var stopStarted: CFAbsoluteTime?
    /// Opens a Run tab for the program (the shell provides it: Run's terminals are its own).
    /// Arguments: the tab's title and directory.
    var openProgramTerminal: ((String, String) -> DebugProgramTerminal?)?
    private var programTerminal: DebugProgramTerminal?
    private var watches: [DebugWatch] = []

    init(host: MakeDebuggerHost) {
        self.host = host
        NotificationCenter.default.addObserver(self, selector: #selector(breakpointsChanged(_:)), name: BreakpointStore.didChangeNotification, object: nil)
    }

    /// The project changed: its own breakpoints (a session in the old one ends).
    func projectChanged(_ root: URL?) {
        session?.stop()
        breakpoints = root.map { BreakpointStore(project: $0) }
        watches = (breakpoints?.watches ?? []).map { DebugWatch(expression: $0) }
        refreshEditor()
    }

    // MARK: Breakpoints

    /// A click on a line number: toggles its breakpoint. A right-click offers the rest.
    func lineNumberClicked(_ line: Int, event: NSEvent) {
        guard let path = host?.debugCurrentFile?.standardizedFileURL.path, let breakpoints else { return }
        let zeroBased = line - 1
        if event.type == .rightMouseDown || event.modifierFlags.contains(.control) {
            return showMenu(path: path, line: zeroBased, event: event)
        }
        toggle(path: path, line: zeroBased, in: breakpoints)
    }

    /// ⌘\: the caret's line.
    func toggleBreakpointAtCaret() {
        guard let host, let path = host.debugCurrentFile?.standardizedFileURL.path, let breakpoints, let document = host.editor.document else { return }
        let line = document.rope.line(containing: min(host.editor.selectedRange.location, document.length))
        toggle(path: path, line: line, in: breakpoints)
    }

    private func toggle(path: String, line: Int, in breakpoints: BreakpointStore) {
        breakpoints.toggle(path: path, line: line)
        resend(path)
    }

    private func resend(_ path: String) {
        guard let session, session.isActive else { return }
        Task { await session.sendBreakpoints(path: path) }
    }

    private func showMenu(path: String, line: Int, event: NSEvent) {
        guard let breakpoints, let view = host?.editor.gutterView else { return }
        let menu = NSMenu()
        if let breakpoint = breakpoints.breakpoints(in: path).first(where: { $0.line == line }) {
            menu.addItem(ClosureItem("Edit Breakpoint\u{2026}") { [weak self] in self?.editBreakpoint(path: path, line: line, near: nil) })
            menu.addItem(ClosureItem(breakpoint.enabled ? "Disable Breakpoint" : "Enable Breakpoint") { [weak self] in
                breakpoints.setEnabled(!breakpoint.enabled, path: path, line: line)
                self?.resend(path)
            })
            menu.addItem(ClosureItem("Delete Breakpoint") { [weak self] in
                breakpoints.remove(path: path, line: line)
                self?.resend(path)
            })
        } else {
            menu.addItem(ClosureItem("Add Breakpoint") { [weak self] in self?.toggle(path: path, line: line, in: breakpoints) })
        }
        if !breakpoints.byPath.values.allSatisfy(\.isEmpty) {
            menu.addItem(.separator())
            menu.addItem(ClosureItem("Delete All Breakpoints") { [weak self] in
                let paths = Array(breakpoints.byPath.keys)
                breakpoints.removeAll()
                paths.forEach { self?.resend($0) }
            })
        }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    /// The condition, hit count and log message, in a popover by the line (or by a row of the
    /// inspector's list).
    func editBreakpoint(path: String, line: Int, near anchor: NSView?) {
        guard let breakpoints, let breakpoint = breakpoints.breakpoints(in: path).first(where: { $0.line == line }), let host else { return }
        let editor = BreakpointEditor(breakpoint)
        editor.onDone = { [weak self] condition, hits, log in
            breakpoints.setOptions(path: path, line: line, condition: condition, hitCondition: hits, logMessage: log)
            self?.resend(path)
        }
        let popover = NSPopover()
        popover.contentViewController = editor
        popover.behavior = .transient
        editor.popover = popover
        if let anchor {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxX)
        } else if host.debugCurrentFile?.standardizedFileURL.path == path, let document = host.editor.document, line < document.rope.lineCount {
            let offset = document.rope.offset(ofLine: line)
            let text = host.editor.rect(forCharacterRange: NSRange(location: offset, length: 0))
            let gutter = host.editor.gutterView
            let inGutter = gutter.convert(text, from: host.editor.textView)
            let rect = NSRect(x: gutter.bounds.midX - 8, y: inGutter.minY, width: 16, height: max(inGutter.height, 14))
            popover.show(relativeTo: rect, of: gutter, preferredEdge: .maxX)
        }
        editor.view.window?.makeFirstResponder(editor.condition)
    }

    /// Edits to an open file: its breakpoints follow them.
    func edited(url: URL, edits: [AppliedEdit], text: Rope) {
        breakpoints?.follow(path: url.standardizedFileURL.path, edits: edits, text: text)
    }

    @objc private func breakpointsChanged(_ notification: Notification) {
        guard notification.object as AnyObject? === breakpoints else { return }
        refreshEditor()
        if let breakpoints { inspector.show(breakpoints: breakpoints.all) }
    }

    /// The shown file's breakpoints, and the stopped line if it's in this file. Called on each
    /// tab switch.
    func refreshEditor() {
        guard let host else { return }
        let path = host.debugCurrentFile?.standardizedFileURL.path
        var marks: [Int: (enabled: Bool, verified: Bool)] = [:]
        if let path, let breakpoints {
            let active = session?.isActive == true
            for breakpoint in breakpoints.breakpoints(in: path) {
                marks[breakpoint.line + 1] = (breakpoint.enabled, active ? breakpoint.verified ?? false : true)
            }
        }
        host.editor.lineBreakpoints = marks
        let frame = session?.isStopped == true ? session?.currentFrame : nil
        host.editor.stoppedLine = frame.flatMap { frame in
            guard let framePath = frame.path, let path else { return nil }
            return realPath(framePath) == realPath(path) ? frame.line - 1 : nil
        }
    }

    // MARK: A session

    var isActive: Bool { session?.isActive == true || parents.contains { $0.isActive } }
    var isStopped: Bool { session?.isStopped == true }

    /// What can be debugged here: the project's `.vscode/launch.json` (once accepted), then what
    /// Side proposes (SIDE_RFC_DEBUGGER.md, Q3).
    enum Option {
        case configuration(DebugConfiguration, fromFile: Bool)
        case unsupported(name: String, reason: String)

        var name: String {
            switch self {
            case .configuration(let configuration, _): return configuration.name
            case .unsupported(let name, _): return name
            }
        }
    }

    nonisolated static func options(root: URL, currentFile: URL?) async -> [Option] {
        let fromFile: [Option] = DebugLaunchFile.entries(root: root, currentFile: currentFile).map { entry in
            switch entry.result {
            case .success(let configuration): return .configuration(configuration, fromFile: true)
            case .failure(let unsupported): return .unsupported(name: entry.name, reason: unsupported.reason)
            }
        }
        let proposed = await DebugLaunch.proposals(root: root, currentFile: currentFile).map { Option.configuration($0, fromFile: false) }
        return fromFile + proposed
    }

    private func rememberedKey(_ root: URL) -> String { "SideDebugProduct." + root.standardizedFileURL.path }

    /// ⌘R: continues a paused session, or starts the one chosen last in this project (asking
    /// when there's no choice yet and more than one option).
    func start() {
        if let session, session.isActive {
            if session.isStopped { session.resume() }
            return
        }
        begin(forcingChoice: false)
    }

    /// Debug → Choose What to Debug…: always the picker; what's picked is remembered.
    func chooseAndStart() {
        guard !isActive else { return }
        begin(forcingChoice: true)
    }

    private func begin(forcingChoice: Bool) {
        guard let host, let root = host.debugProjectRoot, let window = host.debugHostView.window else { return }
        let file = host.debugCurrentFile
        askToAcceptLaunchFile(root: root, window: window) { [weak self] in
            guard let self else { return }
            Task {
                let options = await Self.options(root: root, currentFile: file)
                guard !options.isEmpty else {
                    return self.alert("Nothing here to debug yet", "Side debugs a Swift package's or a Cargo project's executables, the open JavaScript, TypeScript or Python file, npm scripts, Go main packages, and what .vscode/launch.json describes.", in: window)
                }
                let defaults = MakeWorkspaceViewController.preferences
                let remembered = defaults.string(forKey: self.rememberedKey(root)).flatMap { name in options.first { $0.name == name } }
                if !forcingChoice, let remembered { return self.run(remembered, in: window) }
                if !forcingChoice, options.count == 1 { return self.run(options[0], in: window) }
                let choices = options.map { option -> PaletteChoice in
                    switch option {
                    case .configuration(let configuration, let fromFile):
                        let adapter = DebugAdapters.preset(configuration.adapter)?.name ?? configuration.adapter
                        return PaletteChoice(symbol: fromFile ? "doc.text" : "play.circle", title: configuration.name,
                                             detail: adapter + (configuration.request == "attach" ? " \u{00B7} attach" : ""),
                                             trailing: fromFile ? "launch.json" : "proposed")
                    case .unsupported(let name, let reason):
                        return PaletteChoice(symbol: "exclamationmark.circle", title: name, detail: nil, trailing: "launch.json", unavailable: reason)
                    }
                }
                host.debugChoose("Debug what?", from: choices) { [weak self] index in
                    guard let self else { return }
                    let option = options[index]
                    if case .configuration = option { defaults.set(option.name, forKey: self.rememberedKey(root)) }
                    self.run(option, in: window)
                }
            }
        }
    }

    private func run(_ option: Option, in window: NSWindow) {
        switch option {
        case .unsupported(let name, let reason):
            alert("Can\u{2019}t debug \u{201C}\(name)\u{201D}", reason, in: window)
        case .configuration(let configuration, _):
            guard let preset = DebugAdapters.preset(configuration.adapter) else { return }
            Task {
                guard let connection = await Task.detached(operation: { DebugAdapters.connection(for: preset) }).value else {
                    return self.missingAdapter(preset, in: window)
                }
                self.launch(configuration, connection: connection, adapterID: preset.adapterID)
            }
        }
    }

    /// `.vscode/launch.json` (and the tasks file it names) arrived with the project, and runs
    /// commands: asked about once per content, as `.side/tasks.json` is. "Not Now" goes on
    /// without it, and asks again after the file changes or Side restarts.
    private func askToAcceptLaunchFile(root: URL, window: NSWindow, then proceed: @escaping () -> Void) {
        let pending = DebugLaunchFile.pending(root: root).filter { !declined.contains(Self.fingerprint($0)) }
        guard !pending.isEmpty else { return proceed() }
        let names = pending.map { $0.url.path.dropFirst(root.path.count + 1) }.joined(separator: " and ")
        let alert = NSAlert()
        alert.messageText = "Use this project\u{2019}s launch configurations?"
        alert.informativeText = "This project contains \(names), which say what to debug and which commands to run first (preLaunchTask).\n\n"
            + "They arrive with a cloned repository, so read them first if the project isn\u{2019}t yours: a configuration can run any program. "
            + "Until you accept them, Side offers only what it finds in the project itself."
        alert.addButton(withTitle: "Use Them")
        alert.addButton(withTitle: "Show Me the File")
        alert.addButton(withTitle: "Not Now")
        alert.beginSheetModal(for: window) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn:
                DebugLaunchFile.accept(pending)
                proceed()
            case .alertSecondButtonReturn:
                if let first = pending.first { self?.host?.debugReveal(first.url, line: 0) }
            default:
                pending.forEach { self?.declined.insert(Self.fingerprint($0)) }
                proceed()
            }
        }
    }
    /// "Not Now", for this run of Side.
    private var declined: Set<String> = []
    private static func fingerprint(_ file: (url: URL, contents: String)) -> String { file.url.path + "#" + String(file.contents.hashValue) }

    private func alert(_ title: String, _ message: String, in window: NSWindow) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    /// The adapter isn't installed: say which, and offer Settings, where Install is.
    private func missingAdapter(_ preset: DebugAdapterPreset, in window: NSWindow) {
        let alert = NSAlert()
        alert.messageText = "\(preset.name) isn't installed"
        alert.informativeText = preset.install.map { "Settings \u{2192} Languages \u{2192} Debuggers installs it (\($0.tool))." } ?? preset.note
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            (NSApp.delegate as? AppDelegate)?.openSettings(at: .languages)
        }
    }

    // MARK: Attaching

    /// Debug → Attach to Process…: one of the person's running processes, under LLDB (or
    /// js-debug for Node).
    func attachToProcess() {
        guard !isActive, let host, let window = host.debugHostView.window else { return }
        Task {
            let root = host.debugProjectRoot
            let processes = await Task.detached(operation: { DebugProcesses.list(projectRoot: root) }).value
            guard !processes.isEmpty else { return self.alert("No processes to attach to", "Side lists your own processes, not the system's.", in: window) }
            let choices = processes.map { process in
                PaletteChoice(symbol: process.isNode ? "curlybraces" : "cpu", title: process.name, detail: process.path, trailing: "\(process.pid)")
            }
            host.debugChoose("Attach to which process?", from: choices) { [weak self] index in
                guard let self else { return }
                let process = processes[index]
                let root = host.debugProjectRoot?.path ?? NSHomeDirectory()
                let configuration: DebugConfiguration
                if process.isNode {
                    configuration = DebugConfiguration(name: "\(process.name) (\(process.pid))", adapter: DebugAdapters.jsDebug.id, request: "attach", launchArguments: [
                        "type": "pwa-node", "request": "attach", "name": .string(process.name), "processId": .string(String(process.pid)), "cwd": .string(root),
                    ], directory: root)
                } else {
                    configuration = DebugConfiguration(name: "\(process.name) (\(process.pid))", adapter: DebugAdapters.lldb.id, request: "attach", launchArguments: [
                        "pid": .int(Int(process.pid)), "program": .string(process.path),
                    ], directory: root)
                }
                self.run(.configuration(configuration, fromFile: false), in: window)
            }
        }
    }

    /// Runs a configuration under lldb-dap at a path (tests start sessions this way).
    func launch(_ configuration: DebugConfiguration, adapter: URL, adapterArguments: [String] = []) {
        launch(configuration, connection: .stdio(executable: adapter, arguments: adapterArguments), adapterID: DebugAdapters.lldb.adapterID)
    }

    /// Runs a configuration under an adapter.
    func launch(_ configuration: DebugConfiguration, connection: DAPConnection, adapterID: String) {
        guard let breakpoints else { return }
        var configuration = configuration
        // The program's own terminal, a Run tab (the last session's is ended and replaced).
        // lldb-dap is given one up front; the others ask for one (`runInTerminal`).
        programTerminal?.close()
        programTerminal = nil
        if configuration.launchArguments == nil, configuration.terminal == nil, let terminal = openProgramTerminal?(configuration.name, configuration.directory) {
            programTerminal = terminal
            configuration.terminal = terminal.tty
        }
        self.configuration = configuration
        lastLaunch = (connection, adapterID)
        parents = []
        let session = DebugSession(configuration: configuration, connection: connection, adapterID: adapterID, breakpoints: breakpoints)
        adopt(session)
        showUI()
        inspector.show(frames: [], selected: 0)
        inspector.clearVariables(placeholder: "Not paused")
        inspector.show(breakpoints: breakpoints.all)
        inspector.show(output: "")
        inspector.show(exceptionFilters: [])
        watches = watches.map { DebugWatch(expression: $0.expression) }
        inspector.show(watches: watches)
        sessionChanged(session)
        Task { await session.start() }
    }
    private var lastLaunch: (connection: DAPConnection, adapterID: String)?
    /// Sessions this one was started from (js-debug's launcher session): kept, not shown.
    private var parents: [DebugSession] = []

    /// A session the bar and inspector follow, with the adapter's requests answered.
    private func adopt(_ session: DebugSession) {
        self.session = session
        session.onChange = { [weak self, weak session] in
            guard let self, let session else { return }
            if session === self.session { self.sessionChanged(session) } else { self.parentChanged(session) }
        }
        session.onStopEvent = { [weak self] in self?.stopStarted = CFAbsoluteTimeGetCurrent() }
        session.onOutput = { [weak self] text, fromProgram in
            guard let self else { return }
            // What the program printed is in its terminal already (js-debug reports it too).
            if fromProgram, self.programTerminal != nil { return }
            self.inspector.append(output: text, style: fromProgram ? .program : .adapter)
        }
        session.runInTerminal = { [weak self] arguments, directory, environment, title in
            self?.runInTerminal(arguments, directory: directory, environment: environment, title: title)
        }
        session.onStartChild = { [weak self, weak session] request, configuration in
            guard let self, let session else { return }
            self.startChild(of: session, request: request, configuration: configuration)
        }
    }

    /// The program in a Run tab of its own, for an adapter that asks (`runInTerminal`).
    var openCommandTerminal: (([String], String, [String: String], String) -> (pid: Int32, terminal: DebugProgramTerminal)?)?

    private func runInTerminal(_ arguments: [String], directory: String, environment: [String: String], title: String) -> Int32? {
        programTerminal?.close()
        guard let opened = openCommandTerminal?(arguments, directory, environment, title) else { return nil }
        programTerminal = opened.terminal
        return opened.pid
    }

    /// js-debug's `startDebugging`: the program's own session, over another connection to the
    /// same server. The bar and inspector follow it; the launcher session stays behind it.
    private func startChild(of parent: DebugSession, request: String, configuration arguments: [String: LSPValue]) {
        guard let port = parent.port, let breakpoints, let adapterID = lastLaunch?.adapterID else { return }
        var configuration = parent.configuration
        configuration.request = request
        configuration.launchArguments = arguments
        configuration.build = nil
        configuration.terminal = nil
        let child = DebugSession(configuration: configuration, connection: .socket(port: port), adapterID: adapterID, breakpoints: breakpoints)
        parents.append(parent)
        adopt(child)
        sessionChanged(child)
        Task { await child.start() }
    }

    /// The launcher session ended (or the program's did): everything does.
    private func parentChanged(_ parent: DebugSession) {
        guard case .ended = parent.state, let session, session.isActive else { return }
        session.stop()
    }

    func pauseOrContinue() {
        guard let session else { return }
        session.isStopped ? session.resume() : session.pause()
    }

    func stepOver() { session?.stepOver() }
    func stepIn() { session?.stepIn() }
    func stepOut() { session?.stepOut() }

    func stop() {
        guard isActive else { return hideUI() }
        session?.stop()
        parents.forEach { $0.stop() }
    }

    /// Stops the session and starts the same configuration again (built again first).
    func restart() {
        guard let configuration, let session, let lastLaunch else { return }
        for old in [session] + parents {
            old.onChange = nil
            old.onOutput = nil
            old.onStopEvent = nil
            old.stop()
        }
        self.session = nil
        var again = configuration
        again.terminal = nil
        launch(again, connection: lastLaunch.connection, adapterID: lastLaunch.adapterID)
    }

    private func sessionChanged(_ session: DebugSession) {
        bar.show(session.state, name: session.configuration.name)
        hideAfterEnd?.cancel()
        showExceptionFilters(session)
        switch session.state {
        case .stopped:
            inspector.show(frames: session.frames, selected: session.selectedFrame)
            showFrame(session)
        case .running, .starting, .building:
            inspector.show(frames: [], selected: 0)
            inspector.clearVariables(placeholder: "Running")
            watches = watches.map { DebugWatch(expression: $0.expression) }
            inspector.show(watches: watches)
            refreshEditor()
        case .ended(let message):
            parents.filter(\.isActive).forEach { $0.stop() }
            inspector.show(frames: [], selected: 0)
            inspector.clearVariables(placeholder: "Ended")
            // Ended, not closed: the tab keeps what the program wrote until the next session.
            programTerminal?.end()
            refreshEditor()
            // A session that ended quietly clears away; one with something to say stays until
            // closed (the bar's stop).
            if message == nil {
                let work = DispatchWorkItem { [weak self] in self?.hideUI() }
                hideAfterEnd = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
            }
        }
    }

    /// The selected frame: its file at its line, tinted (D4), and its variables.
    private func showFrame(_ session: DebugSession) {
        stopGeneration += 1
        let generation = stopGeneration
        if let frame = session.currentFrame, let path = frame.path, FileManager.default.fileExists(atPath: path) {
            host?.debugReveal(URL(fileURLWithPath: path), line: max(0, frame.line - 1))
        }
        refreshEditor()
        if let started = stopStarted {
            lastStopShownIn = CFAbsoluteTimeGetCurrent() - started
            stopStarted = nil
        }
        guard let frame = session.currentFrame else { return inspector.clearVariables(placeholder: "No frame") }
        Task {
            let scopes = await session.scopes(frameID: frame.id)
            guard generation == self.stopGeneration, session.isStopped else { return }
            self.inspector.show(scopes: scopes)
        }
        evaluateWatches(session, generation: generation)
    }

    // MARK: Watches, the console, hovering, exceptions

    /// Every watch again, in the selected frame (D5: on each stop).
    private func evaluateWatches(_ session: DebugSession, generation: Int) {
        guard !watches.isEmpty else { return }
        let expressions = watches.map(\.expression)
        Task {
            var results: [DebugWatch] = []
            for expression in expressions {
                switch await session.evaluate(expression, context: "watch") {
                case .success(let value): results.append(DebugWatch(expression: expression, value: value.result))
                case .failure(let error): results.append(DebugWatch(expression: expression, value: Self.message(error), failed: true))
                }
            }
            guard generation == self.stopGeneration, session.isStopped, results.map(\.expression) == self.watches.map(\.expression) else { return }
            self.watches = results
            self.inspector.show(watches: results)
        }
    }

    func addWatch(_ expression: String) {
        watches.append(DebugWatch(expression: expression))
        breakpoints?.watches = watches.map(\.expression)
        inspector.show(watches: watches)
        if let session, session.isStopped { evaluateWatches(session, generation: stopGeneration) }
    }

    func removeWatch(at index: Int) {
        guard watches.indices.contains(index) else { return }
        watches.remove(at: index)
        breakpoints?.watches = watches.map(\.expression)
        inspector.show(watches: watches)
    }

    /// The console: an expression in the paused frame (lldb commands too, as lldb-dap takes them).
    func evaluateInConsole(_ expression: String) {
        inspector.append(output: "\u{203A} \(expression)\n", style: .input)
        guard let session, session.isActive else { return inspector.append(output: "Not debugging.\n", style: .error) }
        Task {
            switch await session.evaluate(expression, context: "repl") {
            case .success(let value): self.inspector.append(output: value.result + (value.result.hasSuffix("\n") ? "" : "\n"))
            case .failure(let error): self.inspector.append(output: Self.message(error) + "\n", style: .error)
            }
        }
    }

    /// Hovering an expression while paused: its value, or nil (the hover falls back to the
    /// language server's).
    func hoverValue(_ expression: String) async -> String? {
        guard let session, session.isStopped else { return nil }
        guard case .success(let value) = await session.evaluate(expression, context: "hover"), !value.result.isEmpty else { return nil }
        return value.result
    }

    /// One line of an adapter's error: lldb's come with the expression echoed and a caret under
    /// it ("error: <EXPR>:1:1: cannot find 'a' in scope\na.x\n^").
    static func message(_ error: DAPClient.DAPError) -> String {
        guard case .failed(_, let message) = error else { return error.localizedDescription }
        let lines = message.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard var line = lines.first(where: { $0.contains("error:") }) ?? lines.first(where: { !$0.isEmpty && $0 != "^" }) else { return message }
        if let range = line.range(of: "error:", options: .backwards) { line = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces) }
        // "<EXPR>:1:1: cannot find…" → "cannot find…"
        if line.hasPrefix("<"), let colon = line.range(of: ": ") { line = String(line[colon.upperBound...]) }
        return line.isEmpty ? message : line
    }

    /// The adapter's exception breakpoints, as the session knows them.
    private func showExceptionFilters(_ session: DebugSession) {
        let enabled = session.enabledExceptionFilters
        // The file's own language's first (Swift's in a Swift package), then the rest.
        let language = host?.debugCurrentFile?.pathExtension.lowercased() == "swift" ? "swift" : ""
        let filters = session.exceptionFilters.enumerated().sorted { a, b in
            let aFirst = !language.isEmpty && a.element.id.hasPrefix(language), bFirst = !language.isEmpty && b.element.id.hasPrefix(language)
            return aFirst != bFirst ? aFirst : a.offset < b.offset
        }.map(\.element)
        inspector.show(exceptionFilters: filters.map { ($0, enabled.contains($0.id)) })
    }

    func setExceptionFilter(_ id: String, enabled: Bool) {
        guard let session, let breakpoints else { return }
        var set = session.enabledExceptionFilters
        if enabled { set.insert(id) } else { set.remove(id) }
        breakpoints.exceptionFilters = set
        showExceptionFilters(session)
        if session.isActive { Task { await session.sendExceptionBreakpoints() } }
    }

    // MARK: The bar and the inspector

    private func showUI() {
        guard let host else { return }
        let view = host.debugHostView
        if bar.superview == nil {
            bar.onAction = { [weak self] action in
                guard let self else { return }
                switch action {
                case .pauseContinue: self.pauseOrContinue()
                case .stepOver: self.stepOver()
                case .stepIn: self.stepIn()
                case .stepOut: self.stepOut()
                case .restart: self.restart()
                case .stop: self.stop()
                }
            }
            inspector.onSelectFrame = { [weak self] index in
                guard let self, let session = self.session else { return }
                session.selectFrame(index)
                self.showFrame(session)
            }
            inspector.fetchVariables = { [weak self] reference, start, count in
                await self?.session?.variables(reference, start: start, count: count) ?? []
            }
            inspector.onRevealBreakpoint = { [weak self] path, line in self?.host?.debugReveal(URL(fileURLWithPath: path), line: line) }
            inspector.onRemoveBreakpoint = { [weak self] path, line in
                self?.breakpoints?.remove(path: path, line: line)
                self?.resend(path)
            }
            inspector.onToggleBreakpoint = { [weak self] path, line, enabled in
                self?.breakpoints?.setEnabled(enabled, path: path, line: line)
                self?.resend(path)
            }
            inspector.onEditBreakpoint = { [weak self] path, line, anchor in self?.editBreakpoint(path: path, line: line, near: anchor) }
            inspector.onExceptionFilter = { [weak self] id, enabled in self?.setExceptionFilter(id, enabled: enabled) }
            inspector.onAddWatch = { [weak self] expression in self?.addWatch(expression) }
            inspector.onRemoveWatch = { [weak self] index in self?.removeWatch(at: index) }
            inspector.onEvaluate = { [weak self] expression in self?.evaluateInConsole(expression) }
        }
        if bar.superview !== view {
            view.addSubview(bar)
            NSLayoutConstraint.activate([
                bar.topAnchor.constraint(equalTo: view.topAnchor, constant: ChromeHost.rowHeight + 8),
                bar.centerXAnchor.constraint(equalTo: host.editor.containerView.centerXAnchor),
            ])
        }
        let leading = FileExplorer.Side.preferred == .left
        if inspector.superview !== view {
            view.addSubview(inspector)
            NSLayoutConstraint.activate([
                inspector.topAnchor.constraint(equalTo: view.topAnchor, constant: ChromeHost.rowHeight + 8),
                inspector.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -(ChromeHost.barGap + ChromeHost.barHeight + 12)),
                inspector.widthAnchor.constraint(equalToConstant: DebugInspector.width),
                leading ? inspector.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10)
                    : inspector.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            ])
        }
        bar.isHidden = false
        inspector.isHidden = false
        barShown = true
        host.debugSetInsets(inspector: DebugInspector.width + 20, leading: leading, bar: DebugBar.height + 12)
    }

    private func hideUI() {
        hideAfterEnd?.cancel()
        guard barShown else { return }
        barShown = false
        bar.isHidden = true
        inspector.isHidden = true
        host?.debugSetInsets(inspector: 0, leading: FileExplorer.Side.preferred == .left, bar: 0)
        refreshEditor()
    }

    var inspectorForTesting: DebugInspector { inspector }
    var barForTesting: DebugBar { bar }
}

/// A menu item that runs a closure.
private final class ClosureItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func run() { handler() }
}
