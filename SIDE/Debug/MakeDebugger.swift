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
    /// Makes room for the inspector beside the editor and the bar over it (0s when they're gone).
    func debugSetInsets(inspector width: CGFloat, leading: Bool, bar height: CGFloat)
}

/// Debugging in Make (SIDE_RFC_DEBUGGER.md): the project's breakpoints in the gutter, a session,
/// the debug bar over the editor and the inspector in the explorer's place.
@MainActor
final class MakeDebugger {
    private weak var host: MakeDebuggerHost?
    private(set) var breakpoints: BreakpointStore?
    private(set) var session: DebugSession?
    private var configuration: DebugConfiguration?
    private var adapter: (url: URL, arguments: [String])?
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

    init(host: MakeDebuggerHost) {
        self.host = host
        NotificationCenter.default.addObserver(self, selector: #selector(breakpointsChanged(_:)), name: BreakpointStore.didChangeNotification, object: nil)
    }

    /// The project changed: its own breakpoints (a session in the old one ends).
    func projectChanged(_ root: URL?) {
        session?.stop()
        breakpoints = root.map { BreakpointStore(project: $0) }
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

    var isActive: Bool { session?.isActive == true }
    var isStopped: Bool { session?.isStopped == true }

    /// ⌘R: continues a paused session, or starts one with the project's executable.
    func start() {
        if let session, session.isActive {
            if session.isStopped { session.resume() }
            return
        }
        guard let host, let root = host.debugProjectRoot, let window = host.debugHostView.window else { return }
        Task {
            do {
                guard let adapter = await Task.detached(operation: { DebugLaunch.lldbDAP() }).value else { throw DebugLaunch.Failure.noAdapter }
                let products = try await DebugLaunch.swiftExecutables(in: root)
                guard !products.isEmpty else { throw DebugLaunch.Failure.noExecutable }
                guard let product = self.choose(products, root: root, window: window) else { return }
                self.launch(DebugLaunch.swiftConfiguration(product: product, root: root), adapter: adapter)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Can't start debugging"
                alert.informativeText = error.localizedDescription
                alert.beginSheetModal(for: window, completionHandler: nil)
            }
        }
    }

    /// Which executable, when there's more than one: the last one chosen in this project, or
    /// asked.
    private func choose(_ products: [String], root: URL, window: NSWindow) -> String? {
        let key = "SideDebugProduct." + root.standardizedFileURL.path
        let defaults = MakeWorkspaceViewController.preferences
        if products.count == 1 { return products[0] }
        if let remembered = defaults.string(forKey: key), products.contains(remembered) { return remembered }
        let alert = NSAlert()
        alert.messageText = "Debug which executable?"
        alert.informativeText = "Side remembers the choice for this project."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 26), pullsDown: false)
        popup.addItems(withTitles: products)
        alert.accessoryView = popup
        alert.addButton(withTitle: "Debug")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn, let chosen = popup.titleOfSelectedItem else { return nil }
        defaults.set(chosen, forKey: key)
        return chosen
    }

    /// Runs a configuration under an adapter (tests start sessions this way too).
    func launch(_ configuration: DebugConfiguration, adapter: URL, adapterArguments: [String] = []) {
        guard let breakpoints else { return }
        self.configuration = configuration
        self.adapter = (adapter, adapterArguments)
        let session = DebugSession(configuration: configuration, adapter: adapter, adapterArguments: adapterArguments, breakpoints: breakpoints)
        self.session = session
        session.onChange = { [weak self, weak session] in
            guard let self, let session, session === self.session else { return }
            self.sessionChanged(session)
        }
        session.onStopEvent = { [weak self] in self?.stopStarted = CFAbsoluteTimeGetCurrent() }
        session.onOutput = { [weak self, weak session] in
            guard let self, let session, session === self.session else { return }
            self.inspector.show(output: session.output)
        }
        showUI()
        inspector.show(frames: [], selected: 0)
        inspector.clearVariables(placeholder: "Not paused")
        inspector.show(breakpoints: breakpoints.all)
        inspector.show(output: "")
        sessionChanged(session)
        Task { await session.start() }
    }

    func pauseOrContinue() {
        guard let session else { return }
        session.isStopped ? session.resume() : session.pause()
    }

    func stepOver() { session?.stepOver() }
    func stepIn() { session?.stepIn() }
    func stepOut() { session?.stepOut() }

    func stop() {
        guard let session, session.isActive else { return hideUI() }
        session.stop()
    }

    /// Stops the session and starts the same configuration again (built again first).
    func restart() {
        guard let configuration, let session, let adapter else { return }
        session.onChange = nil
        session.onOutput = nil
        session.onStopEvent = nil
        session.stop()
        self.session = nil
        launch(configuration, adapter: adapter.url, adapterArguments: adapter.arguments)
    }

    private func sessionChanged(_ session: DebugSession) {
        bar.show(session.state, name: session.configuration.name)
        hideAfterEnd?.cancel()
        switch session.state {
        case .stopped:
            inspector.show(frames: session.frames, selected: session.selectedFrame)
            showFrame(session)
        case .running, .starting, .building:
            inspector.show(frames: [], selected: 0)
            inspector.clearVariables(placeholder: "Running")
            refreshEditor()
        case .ended(let message):
            inspector.show(frames: [], selected: 0)
            inspector.clearVariables(placeholder: "Ended")
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
