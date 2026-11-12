import AppKit
import SideAgents
import SideSessionsKit
import SwiftTerm

/// What Terminal needs from the view that emulates and draws a terminal: SwiftTerm's
/// (`SideTerminalView`) today, libghostty-vt drawn by Alloy next, behind a setting
/// (docs/SIDE_RFC_TERMINAL_ENGINE.md). `TerminalViewController` and everything else reach the
/// terminal only through this, so the engine can change underneath them.
@MainActor
protocol TerminalSurface: NSView {
    var surfaceDelegate: TerminalSurfaceDelegate? { get set }

    // MARK: Session

    /// Set when the shell lives in a session keeper: input and size go to it, output comes from it.
    var keeper: KeeperLink? { get set }
    /// Tells the keeper the grid's size, after layout settles on a different one.
    func syncKeeperSize()
    var columns: Int { get }
    var rows: Int { get }
    var scrollbackLines: Int { get }

    // MARK: Output and input

    /// The program's output, through everything Side watches it for (marks, reports, unseen output).
    func receive(_ bytes: ArraySlice<UInt8>)
    /// Bytes straight to the screen, watched by nothing: a keeper's snapshot, Side's own notices.
    func display(_ bytes: ArraySlice<UInt8>)
    /// Input for the program, as if typed.
    func send(text: String)
    func send(bytes: ArraySlice<UInt8>)
    /// As a paste: bracketed when the program asked for it.
    func paste(text: String)
    /// Text as the input system hands it over (NSTextInputClient): the path typed keys take.
    func insertText(_ string: Any, replacementRange: NSRange)

    // MARK: A process of its own (command tabs; terminals without a keeper)

    func startProcess(executable: String, arguments: [String], environment: [String], currentDirectory: String?)
    /// The shell's or command's process id, when it runs in Side's process (not a keeper's).
    var processID: pid_t { get }
    /// The PTY's controlling side, for the debugger's TTY handoff.
    var processTerminalDescriptor: Int32 { get }
    func terminateProcess()

    // MARK: Appearance

    var font: NSFont { get set }
    func applyTheme(_ theme: TerminalSurfaceTheme)
    /// The background as drawn, in sRGB.
    var backgroundColor: NSColor { get }
    /// Light/dark notices (DEC mode 2031): whether the background reads dark, and whether the
    /// running program listens even if it didn't ask this terminal.
    var isDarkBackground: () -> Bool { get set }
    var programListensForColorScheme: () -> Bool { get set }
    /// Side's appearance changed: a program that listens hears which it is now.
    func colorSchemeChanged()

    // MARK: Watching

    var onBell: (() -> Void)? { get set }
    var onFileLinkRequested: ((String) -> Bool)? { get set }
    var onLineSubmitted: ((String) -> Void)? { get set }
    /// That output arrived (the unseen-output indicator).
    var onDataReceived: (() -> Void)? { get set }
    /// The output itself (command marks, agent sentinels).
    var onRawDataReceived: ((ArraySlice<UInt8>) -> Void)? { get set }
    /// Input with no keeper attached: true if handled (a session taken by another Side, rejoined).
    var onInputWithoutKeeper: (() -> Bool)? { get set }
    /// Side's own OSC 6973 report (`agent;claude;<session>;<nonce>`), its fields.
    var onAgentReport: (([String]) -> Void)? { get set }

    // MARK: Reading

    /// The visible screen as text, trailing blank rows dropped.
    func visibleText() -> String
    /// Everything the terminal holds, scrollback included, as text: for tests.
    func bufferText() -> String
    /// The view as an image (a dragged tab's preview).
    func snapshotImage() -> NSImage?
    var reportsColorSchemeForTesting: Bool { get }
}

/// What a terminal surface reports about its program.
@MainActor
protocol TerminalSurfaceDelegate: AnyObject {
    func terminalSurface(_ surface: any TerminalSurface, titleChanged title: String)
    /// OSC 7, as the program sent it (`file://host/path`).
    func terminalSurface(_ surface: any TerminalSurface, directoryChanged directory: String?)
    /// Its own process ended (not a keeper's).
    func terminalSurface(_ surface: any TerminalSurface, processTerminated exitCode: Int32?)
}

/// The colors and font a surface draws with, already resolved for the current appearance.
struct TerminalSurfaceTheme {
    var foreground: NSColor
    var background: NSColor
    /// The sixteen ANSI colors.
    var palette: [NSColor]
    /// The default background's opacity: below 1, the window's backdrop shows through.
    var backgroundOpacity: CGFloat
}

enum TerminalEnvironment {
    /// The variables every terminal's program starts with: what SwiftTerm's
    /// `Terminal.getEnvironmentVariables` set, kept as it was when Side owns it.
    static func base(termName: String = "xterm-256color") -> [String] {
        var variables = ["TERM=\(termName)", "COLORTERM=truecolor", "LANG=en_US.UTF-8"]
        let environment = ProcessInfo.processInfo.environment
        for name in ["LOGNAME", "USER", "DISPLAY", "LC_TYPE", "USER", "HOME"] {
            if let value = environment[name] { variables.append("\(name)=\(value)") }
        }
        return variables
    }
}

extension TerminalSurface {
    /// Text straight to the screen: Side's own notices.
    func display(text: String) { display(Array(text.utf8)[...]) }
}

/// Subclasses LocalProcessTerminalView purely to hook three things it exposes specifically for
/// subclass override/interception rather than via its processDelegate: link clicks (so
/// file-path-shaped links can open in Make instead of falling through to NSWorkspace), raw
/// input bytes (to approximate "last submitted command" for rerun, since there's no real shell
/// integration to ask), and raw output bytes (to signal "this session has unseen output" for
/// the background-activity indicator).
final class SideTerminalView: LocalProcessTerminalView, TerminalSurface {
    weak var surfaceDelegate: TerminalSurfaceDelegate?
    var onAgentReport: (([String]) -> Void)?
    /// SwiftTerm's process callbacks arrive here (its delegate is weak, so it's held).
    private let processBridge = ProcessBridge()

    /// Set when this terminal's shell lives in a session keeper (SIDE_RFC_SESSION_RESTORE.md):
    /// input and size go to it, and output comes from it, instead of SwiftTerm's own process.
    var keeper: KeeperLink? {
        didSet { syncKeeperSize() }
    }
    var onFileLinkRequested: ((String) -> Bool)?
    /// Input with no keeper attached: true if it was handled (a session taken by another Side,
    /// rejoined), and the bytes go nowhere.
    var onInputWithoutKeeper: (() -> Bool)?
    /// A bell from the program (BEL): the activity pill says so when the tab is out of sight.
    var onBell: (() -> Void)?

    // MARK: Light and dark (DEC mode 2031)

    /// What the program asked for of light/dark notices. Claude Code picks its theme from the
    /// terminal and listens for these; without them it kept the theme it started with, light in a
    /// window gone dark (the owner, 2026-11-04).
    private var colorScheme = ColorSchemeReports()
    /// Whether the terminal's background reads as dark: the program's notion of "dark".
    var isDarkBackground: () -> Bool = { true }
    /// A restored terminal doesn't know what its program asked before Side reattached; a program
    /// known to listen still hears of a change.
    var programListensForColorScheme: () -> Bool = { false }
    static func colorSchemeReport(dark: Bool) -> String { "\u{1B}[?997;\(dark ? 1 : 2)n" }

    /// Side's light/dark or theme changed: a program that listens hears which it is now. Told on
    /// every change, not only when it differs from the last told: a terminal's first colors can be
    /// resolved before the app has finished switching, and a repeated notice only redraws. Read
    /// a turn later, once every window has the new appearance.
    func colorSchemeChanged() {
        guard colorScheme.enabled || programListensForColorScheme() else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.send(txt: Self.colorSchemeReport(dark: self.isDarkBackground()))
        }
    }

    var reportsColorSchemeForTesting: Bool { colorScheme.enabled }

    // MARK: TerminalSurface

    var columns: Int { terminal.cols }
    var rows: Int { terminal.rows }
    var scrollbackLines: Int { terminal.options.scrollback }
    func receive(_ bytes: ArraySlice<UInt8>) { dataReceived(slice: bytes) }
    func display(_ bytes: ArraySlice<UInt8>) { feed(byteArray: bytes) }
    func send(text: String) { send(txt: text) }
    func send(bytes: ArraySlice<UInt8>) { send(source: self, data: bytes) }
    func startProcess(executable: String, arguments: [String], environment: [String], currentDirectory: String?) {
        startProcess(executable: executable, args: arguments, environment: environment, currentDirectory: currentDirectory)
    }
    var processID: pid_t { process.shellPid }
    var processTerminalDescriptor: Int32 { process.childfd }
    func terminateProcess() { process.terminate() }
    var backgroundColor: NSColor { nativeBackgroundColor.usingColorSpace(.sRGB) ?? nativeBackgroundColor }

    func applyTheme(_ theme: TerminalSurfaceTheme) {
        terminal.foregroundColor = TerminalViewController.terminalColor(theme.foreground)
        terminal.backgroundColor = TerminalViewController.terminalColor(theme.background)
        terminal.installPalette(colors: theme.palette.map(TerminalViewController.terminalColor))
        nativeForegroundColor = theme.foreground
        nativeBackgroundColor = theme.background
        backgroundOpacity = theme.backgroundOpacity
        needsDisplay = true
    }

    func bufferText() -> String { String(decoding: getTerminal().getBufferAsData(), as: UTF8.self) }

    func snapshotImage() -> NSImage? {
        guard bounds.width > 0, bounds.height > 0, let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }

    override func bell(source: Terminal) {
        super.bell(source: source)
        onBell?()
    }
    var onLineSubmitted: ((String) -> Void)?
    var onDataReceived: (() -> Void)?
    /// Raw output bytes, separate from `onDataReceived` (which only signals *that* output
    /// arrived, for the unseen-output indicator) — `runAgentCommand`'s sentinel scan needs the
    /// actual bytes.
    var onRawDataReceived: ((ArraySlice<UInt8>) -> Void)?
    private var currentLineBuffer = ""
    private var inputEscape = EscapeSkipper()
    private var accessibilityUpdateWorkItem: DispatchWorkItem?

    /// Whether VoiceOver is on, kept by observing it: asking NSWorkspace on every read of output
    /// was 5% of Run's CPU under a flood.
    @MainActor private final class VoiceOverState {
        private(set) var isOn = NSWorkspace.shared.isVoiceOverEnabled
        private var observation: NSKeyValueObservation?
        init() {
            observation = NSWorkspace.shared.observe(\.isVoiceOverEnabled, options: [.new]) { [weak self] _, change in
                guard let on = change.newValue else { return }
                DispatchQueue.main.async { self?.isOn = on }
            }
        }
    }
    private static let voiceOver = VoiceOverState()

    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .png, .tiff])
        processBridge.surface = self
        processDelegate = processBridge
        // Side genuinely handles OSC 133 (the semantic-prompt marks it asks the shell to emit),
        // but detection scans the raw PTY stream in handleAgentCommandData — SwiftTerm's parser
        // has no handler of its own and logged "Unknown OSC code: 133" for every mark.
        // Registering a no-op tells the parser the code is spoken for.
        terminal.registerOscHandler(code: 133) { _ in }
        // Side's own: `agent;<name>;<session id>;<nonce>` from the shell's `claude` wrapper.
        terminal.registerOscHandler(code: 6973) { [weak self] data in
            self?.onAgentReport?(String(decoding: data, as: UTF8.self).split(separator: ";", omittingEmptySubsequences: false).map(String.init))
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Drops

    /// Files dropped on the terminal type their paths, escaped for the shell, as other terminals
    /// do: it's how Claude Code takes a dragged image (the owner, 2026-10-29). A picture with no
    /// file behind it (a browser's, a screenshot's thumbnail) is saved to a temporary file first.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.canDrop(sender.draggingPasteboard) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let paths = Self.droppedPaths(sender.draggingPasteboard)
        guard !paths.isEmpty else { return false }
        window?.makeFirstResponder(self)
        paste(text: paths.map(Self.shellEscaped).joined(separator: " ") + " ")
        return true
    }

    /// As a paste: bracketed when the program asked for it, so it arrives as one paste.
    func paste(text: String) {
        if terminal.bracketedPasteMode {
            send(txt: "\u{1B}[200~" + text + "\u{1B}[201~")
        } else {
            send(txt: text)
        }
    }

    static func canDrop(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            || pasteboard.availableType(from: [.png, .tiff]) != nil
    }

    static func droppedPaths(_ pasteboard: NSPasteboard) -> [String] {
        let files = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !files.isEmpty { return files.map(\.path) }
        guard let type = pasteboard.availableType(from: [.png, .tiff]), let data = pasteboard.data(forType: type) else { return [] }
        let png = type == .png ? data : NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
        guard let png else { return [] }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Side Drops", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("Image \(Self.dropStamp.string(from: Date())).png")
        guard (try? png.write(to: file)) != nil else { return [] }
        return [file.path]
    }

    private static let dropStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter
    }()

    /// A backslash before each character the shell would read as syntax, as Terminal and iTerm
    /// escape a dropped path.
    static func shellEscaped(_ path: String) -> String {
        let special = Set(" \t\n\\'\"`$&*()[]{}<>|;!?#~=%^")
        return String(path.flatMap { special.contains($0) ? ["\\", $0] : [$0] })
    }

    override func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if onFileLinkRequested?(link) == true { return }
        super.requestOpenLink(source: source, link: link, params: params)
    }

    /// Best-effort line capture, not a real line editor: control sequences like arrow-key
    /// history recall aren't parsed, so a command recalled via shell history and re-run won't
    /// be captured here. Plain typed/pasted-then-Return input is.
    ///
    /// Escape sequences are skipped whole: arrow keys, and the terminal's own replies to a
    /// program's queries, which go to the program the same way (Claude Code asks at startup,
    /// and its "command" read `[?65;4;1;2;6;21;22;17;28cP>|SwiftTerm`).
    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        for byte in data {
            if inputEscape.consume(byte) { continue }
            switch byte {
            case 13, 10:
                let line = currentLineBuffer.trimmingCharacters(in: .whitespaces)
                if !line.isEmpty { onLineSubmitted?(line) }
                currentLineBuffer = ""
            case 127, 8:
                if !currentLineBuffer.isEmpty { currentLineBuffer.removeLast() }
            case 32..<127:
                currentLineBuffer.append(Character(UnicodeScalar(byte)))
            default:
                break
            }
        }
        if let keeper { keeper.input(data) } else if onInputWithoutKeeper?() != true { super.send(source: source, data: data) }
    }

    /// SwiftTerm tells only its own process about a new size, so a keeper's terminal is told
    /// here, whenever layout settles on a different grid.
    func syncKeeperSize() {
        guard let keeper else { return }
        keeper.resize(cols: terminal.cols, rows: terminal.rows)
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        onDataReceived?()
        onRawDataReceived?(slice)
        for event in colorScheme.consume(slice) where event == .query { send(txt: Self.colorSchemeReport(dark: isDarkBackground())) }
        receiving = true
        super.dataReceived(slice: slice)
        receiving = false
        scheduleAccessibilityValueUpdate()
        followOutput()
    }

    /// Once a turn of the run loop, however many reads it delivered: output arrives in small
    /// reads, and following each one was still a third of Run's main thread under a flood.
    private func followOutput() {
        guard !followScheduled else { return }
        followScheduled = true
        DispatchQueue.main.async { [weak self] in self?.followNow() }
    }

    private func followNow() {
        followScheduled = false
        if scrolledWhileReceiving {
            scrolledWhileReceiving = false
            super.scrolled(source: terminal, yDisp: terminal.buffer.yDisp)
            updateThumb()
        }
        syncScrollerVisibility()
    }

    /// SwiftTerm's scroller is a bare `NSScroller`, not one inside an `NSScrollView`, so nothing
    /// drives its overlay behaviour: it sat on the right edge as an empty track whose thumb never
    /// showed and which never faded (owner, 2026-09-23). It stays hidden — which also gives its
    /// reserved column back to the grid — and `thumb` does the job the way Make's scroller does:
    /// appears while scrolling, fades once scrolling stops, draggable while shown.
    func syncScrollerVisibility() {
        for case let scroller as NSScroller in subviews where !scroller.isHidden { scroller.isHidden = true }
    }

    override func layout() {
        super.layout()
        syncKeeperSize()
        syncScrollerVisibility()
        thumb.frame = NSRect(x: bounds.maxX - OverlayScrollThumb.trackWidth, y: bounds.minY, width: OverlayScrollThumb.trackWidth, height: bounds.height)
        updateThumb()
    }

    // MARK: - Overlay scroll thumb

    private lazy var thumb: OverlayScrollThumb = {
        let thumb = OverlayScrollThumb()
        thumb.onDrag = { [weak self] position in
            guard let self else { return }
            self.scrollTo(row: Int((position * Double(self.maxScrollback)).rounded()))
            self.updateThumb()
        }
        addSubview(thumb)
        return thumb
    }()
    private var scrollMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor); self.scrollMonitor = nil }
        guard window != nil else { return }
        // SwiftTerm's scrollWheel isn't overridable from outside the package (and its wheel path
        // doesn't report through `scrolled`); a local monitor scoped to this view sees the same
        // gesture, and reads the position once SwiftTerm has applied it.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            if let self, event.window === self.window,
               self.bounds.contains(self.convert(event.locationInWindow, from: nil)), self.canScroll {
                DispatchQueue.main.async { self.updateThumb(); self.thumb.flash() }
            }
            return event
        }
    }

    /// Output scrolls the terminal once a line: the scroller and thumb follow it afterwards, in
    /// `followOutput` (a fifth of Run's CPU under a flood of output went to following every line).
    private var receiving = false, scrolledWhileReceiving = false, followScheduled = false

    override func scrolled(source terminal: Terminal, yDisp: Int) {
        if receiving { scrolledWhileReceiving = true; return }
        super.scrolled(source: terminal, yDisp: yDisp)
        updateThumb()
    }

    /// How far the viewport can scroll, in rows. SwiftTerm keeps the line count internal; the
    /// public position is yDisp / maxScrollback, so the pair recovers it (at the top, where the
    /// ratio says nothing, the last known value holds).
    private var maxScrollback = 0

    private func updateThumb() {
        let yDisp = terminal.buffer.yDisp
        if scrollPosition >= 1 { maxScrollback = yDisp } else if scrollPosition > 0 { maxScrollback = Int((Double(yDisp) / scrollPosition).rounded()) }
        thumb.update(enabled: canScroll, proportion: scrollThumbsize, position: scrollPosition)
    }

    // MARK: - Accessibility

    /// SwiftTerm ships an `AccessibilityService` for UIKit but nothing for AppKit, so the whole
    /// Run stage was a hole in the AX tree: an inspector saw the window and a scrollbar, and
    /// none of the terminal's text or prompt. Typing worked; reading the result didn't — which
    /// makes Run unusable with VoiceOver no matter how well the keyboard path behaves.
    ///
    /// Exposed as one text area whose value is the visible screen (plus a bounded slice of
    /// scrollback), rather than an element per row: rows are transient — a redraw replaces them
    /// wholesale — and an element per row would churn the tree on every frame of output.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    override func accessibilityLabel() -> String? { "Terminal" }
    override func accessibilityHelp() -> String? {
        "Terminal output. Type to send input to the shell."
    }
    override func accessibilityValue() -> Any? { accessibleText() }
    override func accessibilityNumberOfCharacters() -> Int { accessibleText().count }
    override func isAccessibilityEnabled() -> Bool { true }

    /// The screen as text: every visible row, trailing blanks trimmed, empty trailing rows
    /// dropped so a mostly-empty screen doesn't read as a wall of silence.
    /// The visible screen as text, trailing blank rows dropped.
    func visibleText() -> String { accessibleText() }

    private func accessibleText() -> String {
        guard let terminal = terminal else { return "" }
        var lines: [String] = []
        for row in 0..<terminal.rows {
            guard let line = terminal.getLine(row: row) else { continue }
            lines.append(line.translateToString(trimRight: true))
        }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    /// Output arrives byte-by-byte; posting a value-changed notification per chunk would make
    /// VoiceOver stutter over its own announcements. Coalesced to one notification per quiet
    /// moment, which is also when the text is worth reading.
    private func scheduleAccessibilityValueUpdate() {
        guard Self.voiceOver.isOn else { return }
        accessibilityUpdateWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
        accessibilityUpdateWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
    }
}

/// SwiftTerm's process callbacks, passed on as the surface's. A separate object: SwiftTerm's view
/// already has methods by these names, which can't be overridden from outside its module.
private final class ProcessBridge: @preconcurrency LocalProcessTerminalViewDelegate {
    weak var surface: SideTerminalView?
    @MainActor func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    @MainActor func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        guard let surface else { return }
        surface.surfaceDelegate?.terminalSurface(surface, titleChanged: title)
    }
    @MainActor func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let surface else { return }
        surface.surfaceDelegate?.terminalSurface(surface, directoryChanged: directory)
    }
    @MainActor func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard let surface else { return }
        surface.surfaceDelegate?.terminalSurface(surface, processTerminated: exitCode)
    }
}

final class TerminalViewController: NSViewController, TerminalSurfaceDelegate {
    let terminalView: any TerminalSurface = SideTerminalView(frame: .zero)
    /// When the program last rang the bell out of sight: it wants you, until the tab is shown.
    private(set) var lastBellAt: Date?
    /// When an agent's turn last ended out of sight, until the tab is shown.
    private(set) var turnFinishedAt: Date?
    /// What happened here out of sight that you'd want to know, until the tab is shown: an
    /// agent's turn that ended, or a bell on its own, which wants you. A bell with the end of a
    /// turn is the turn ending (Claude Code rings one then, set to notify by the terminal bell).
    enum News { case finished, needsYou }
    var news: News? {
        let bellEndedTurn = lastBellAt.flatMap { bell in turnFinishedAt.map { abs(bell.timeIntervalSince($0)) < 2 } } ?? false
        if lastBellAt != nil, !bellEndedTurn { return .needsYou }
        if turnFinishedAt != nil { return .finished }
        return nil
    }
    var onNewsChanged: (() -> Void)?

    /// On screen in Side's front window.
    var isOnScreen: Bool {
        NSApp.isActive && view.window != nil && view.window === ShellViewController.frontmost?.view.window && !view.isHiddenOrHasHiddenAncestor
    }
    private var didStart = false
    var workingDirectory: String?
    /// The session keeper this terminal's shell lives in (SIDE_RFC_SESSION_RESTORE.md), set
    /// before it starts: a remembered tab keeps its id, so it reattaches to the shell it had.
    /// Nil runs the shell in Side's own process, as command tabs always do.
    var keeperID: String?
    /// Side's facts for the keeper's record: project and track, so a reopened project finds it.
    var keeperFacts: [String: String] = [:]
    /// Set before it starts when this tab's keeper ended without the session ending (a restart,
    /// a crash): the new shell starts below the old screen, and what was running is resumed,
    /// run again or offered (`SessionKeepers.recovery`).
    var recovering: SessionRecord?
    /// The agent session the tab's Claude reported, for resuming it after a restart.
    var recoveredAgentSession: String?
    /// A command that was running before a restart and isn't safe to start unasked: Run shows it
    /// with Run Again.
    private(set) var rerunOffer: String?
    var onRerunOfferChanged: (() -> Void)?
    /// An agent CLI reported its session id (the `claude` wrapper, `SessionKeepers`).
    var onAgentSessionReported: ((_ agent: String, _ session: String) -> Void)?

    /// A program to run in place of the login shell — an outside agent's `terminal/create`
    /// (`SIDE_RFC_BYO_HARNESS.md` step 3a). The command runs directly, never typed into a shell
    /// someone is using, and the tab ends when it does.
    struct CommandLaunch {
        let command: String
        let arguments: [String]
        /// Added to the terminal's own minimal environment (and the login shell's PATH).
        let environment: [String: String]
    }
    var commandLaunch: CommandLaunch?
    /// A command tab, not a shell: never chosen for the agent's typed commands, never restored.
    var isCommandSession: Bool { commandLaunch != nil }
    /// Every byte the program writes, for `terminal/output`.
    var onCommandOutput: ((ArraySlice<UInt8>) -> Void)?
    /// The process ended — its exit code, or nil when it didn't exit normally.
    var onProcessExit: ((Int32?) -> Void)?

    private(set) var isAlive = false
    /// Usable for a command: running, or not started yet (it starts on first use). A shell that
    /// exited is neither, and gets replaced rather than typed into.
    var isAliveOrUnstarted: Bool { !didStart || isAlive }
    private(set) var currentDirectory: String?
    private(set) var lastSubmittedCommand: String?
    /// Non-nil while an agent-submitted command is waiting for its sentinel to show up in the
    /// output stream. Exactly one runs at a time per terminal — they share one visible shell, so
    /// two commands typed simultaneously would interleave into nonsense — but "one at a time" is
    /// enforced by `queuedAgentCommands` rather than assumed: a single batch can contain several
    /// auto-runnable commands, and `AgentRunner` fires them in a loop without waiting. Before the
    /// queue, the second call overwrote this slot and the first command's completion was never
    /// called at all — a dropped `tool_result`, i.e. precisely the dangling-`tool_use` shape that
    /// wedges a conversation.
    private var pendingAgentCommand: (sentinel: String, buffer: String, scannedCharacters: Int, command: String, usesMarks: Bool, outputStarted: Bool, completion: (String) -> Void)?
    /// Commands waiting for the terminal to free up, in the order they were requested.
    private var queuedAgentCommands: [(command: String, timeout: TimeInterval, completion: (String) -> Void)] = []
    /// Whether the shell confirmed it emits OSC 133 marks. Commands that arrive while this is
    /// still `.probing` wait rather than committing to the wrong capture strategy.
    private enum ShellIntegration { case probing, confirmed, unavailable }
    private var shellIntegration: ShellIntegration = .probing
    /// One-shot guard for `tidyAfterSetup()`.
    private var didTidyAfterSetup = false
    /// Ceiling on the in-flight command buffer. Without one, 30 seconds of a verbose build (the
    /// timeout, not a size limit) accumulated hundreds of megabytes on the main thread. The
    /// number matches ToolExecutor's own output cap, since anything past it is truncated before
    /// the model ever sees it; the *tail* is kept because that's where the sentinel and the
    /// error the user cares about live.
    private static let maxCommandBufferCharacters = 60_000

    ///
    /// Trimmed only past twice the cap, and by UTF-8 bytes: counting characters on every chunk
    /// walked the whole buffer, grapheme by grapheme, for each kilobyte a command printed, and
    /// a command with a lot of output ran at a core's worth of Side's CPU, slower than it could
    /// print (2026-09-30, the Run budget). What's kept is at least the last cap's worth.
    /// In place: a buffer the caller still shares is copied whole on every append.
    private static func boundedAppend(_ buffer: inout String, _ addition: String) {
        buffer += addition
        guard buffer.utf8.count > maxCommandBufferCharacters * 2 else { return }
        let utf8 = buffer.utf8
        var start = utf8.index(utf8.endIndex, offsetBy: -maxCommandBufferCharacters)
        // On a scalar's first byte, so the cut never splits one.
        while start < utf8.endIndex, start.samePosition(in: buffer.unicodeScalars) == nil { start = utf8.index(after: start) }
        buffer = String(buffer[start...])
    }

    /// Where `needle` first occurs in `bytes` at or after `from`. The marks are found in the raw
    /// output bytes, with memchr: Foundation's `range(of:)` compares Characters, and under a
    /// flood of output it was a quarter of Run's CPU even over only the new text (2026-09-30).
    /// The marks are ASCII, so a byte match is a mark.
    static func firstOffset(of needle: [UInt8], in bytes: [UInt8], from: Int) -> Int? {
        guard let first = needle.first, from >= 0, bytes.count - from >= needle.count else { return nil }
        return bytes.withUnsafeBufferPointer { hay in
            guard let base = hay.baseAddress else { return nil }
            var at = from
            while hay.count - at >= needle.count {
                guard let hit = memchr(base + at, Int32(first), hay.count - at) else { return nil }
                at = base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
                guard hay.count - at >= needle.count else { return nil }
                if needle.withUnsafeBufferPointer({ memcmp(base + at, $0.baseAddress!, needle.count) }) == 0 { return at }
                at += 1
            }
            return nil
        }
    }

    private static let startMarkBytes = Array((markPrefix + "C" + markTerminator).utf8)
    private static let doneMarkBytes = Array((markPrefix + "D;").utf8)
    private static let markPrefixBytes = Array(markPrefix.utf8)
    private static let markTerminatorBytes = Array(markTerminator.utf8)
    private static let separator = UInt8(ascii: ";")

    /// True when integration was installed via the ZDOTDIR wrapper (zsh) — nothing was typed
    /// into the session, so there's nothing to tidy and no visible setup at all.
    private var integrationInstalledViaRc = false
    /// True once the shell is past its integration setup (tidied, or integration gave up) —
    /// output before this is startup plumbing, not something to badge as unseen.
    var startupSettled: Bool { didTidyAfterSetup || shellIntegration == .unavailable }
    /// Guards against a stale timeout resolving a *later* command that happens to occupy the slot.
    private var pendingAgentCommandGeneration = 0
    /// Per-terminal secret the shell's own OSC 133 hooks include in every `D` mark.
    ///
    /// Without it, the mark was twelve bytes any process could print: a repository's test
    /// script could emit `\e]133;D;0\a` and read as "exit 0" — a forged passing verification,
    /// which is the one record Promote trusts. The nonce reaches the shell in its environment,
    /// the rc file copies it into an unexported shell variable and removes it from the
    /// environment, so child processes never see it; a mark without the right nonce is treated as
    /// ordinary output. This does not stop a process that reads the rc file or the shell's
    /// environment — same-user code can — but it moves the attack from "print a line" to
    /// "deliberately go looking", which is a different threat. (2026-09-01 audit, terminal Med.)
    /// A reattached shell keeps the nonce it started with, from its keeper's record.
    private var markNonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    static let agentCommandTimeout = CommandTimeout.command
    static let agentTaskTimeout = CommandTimeout.task

    /// (isAlive, exitCode) — exitCode is nil if the process never actually started or died
    /// from an I/O error rather than a normal exit.
    var onExitStatusChanged: ((Bool, Int32?) -> Void)?
    var onDirectoryChanged: ((String?) -> Void)?

    /// The last command the shell ran, from its own OSC 133 marks — every command, not just the
    /// agent's — for Run's status line (§4.3).
    struct CommandStatus: Equatable {
        var lastExitCode: Int?
        var lastDuration: TimeInterval?
        var runningSince: Date?
        /// The last command was the agent's (or a task's) — those record their own results.
        var lastCommandWasAgent = false
        /// Counts finished commands, so a watcher can tell a new result from a redraw.
        var finishedCount = 0
    }
    private(set) var commandStatus = CommandStatus()
    var onCommandStatusChanged: (() -> Void)?
    /// The title the running program gave the terminal (OSC 0/2): Claude Code's task, Codex's,
    /// vim's file. Only while a command runs: a shell setting one at every prompt isn't naming
    /// anything, and the folder says more. Cleared when the command finishes.
    private(set) var programTitle: String?
    var onProgramTitleChanged: (() -> Void)?
    /// A program at work, by the glyph in front of its title: Claude Code shows ✳ while it waits
    /// and a turning half-circle (◐ ◓ ◑ ◒) while it works, changing it only every few seconds,
    /// so the glyph itself is read, not how often it changes (recorded 2026-11-04). Braille
    /// spinners count too. The Terminal's tab shows it.
    private(set) var isProgramWorking = false
    var onWorkingChanged: (() -> Void)?
    private var markScanCarry: [UInt8] = []
    /// The marked command's output so far, raw (`advanceMarkedCapture`); the sentinel path
    /// keeps its text in `pendingAgentCommand.buffer`.
    private var markedOutput: [UInt8] = []
    var onOutputReceived: (() -> Void)?
    /// Return true if handled (opened in Make); returning false falls through to the default
    /// NSWorkspace.open behavior, which is what makes plain URLs already clickable for free.
    var onFileLinkRequested: ((String) -> Bool)?

    override func loadView() { view = NSView() }

    /// The terminal font and size settings (Appearance). By default the Nerd Font (themed
    /// prompts draw their segments with its glyphs), with the system monospace as the fallback.
    @objc private func applyTextSize() {
        terminalView.font = DS.Text.Fonts.font(.terminal, size: DS.Text.CodeSize.terminal)
        terminalView.syncKeeperSize()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        terminalView.onInputWithoutKeeper = { [weak self] in self?.rejoinIfTaken() ?? false }
        terminalView.onBell = { [weak self] in
            guard let self else { return }
            // Rung where you can see it: nothing to tell you later.
            if !self.isOnScreen {
                self.lastBellAt = Date()
                self.onNewsChanged?()
            }
        }
        applyTextSize()
        NotificationCenter.default.addObserver(self, selector: #selector(applyTextSize), name: DS.Text.CodeSize.didChangeNotification, object: nil)
        // SwiftTerm's own defaults are a ~54%-gray foreground on a pure black background —
        // legible but noticeably dim next to the editor. Terminal background is deliberately
        // darker than the editor's own (near-black rather than matching exactly) — a common
        // convention (Terminal.app, iTerm2 defaults) that also helps a glance tell Make and
        // Run apart.
        applyTerminalTheme()
        NotificationCenter.default.addObserver(self, selector: #selector(appearanceChanged), name: DS.Appearance.didChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appearanceChanged), name: EditorThemes.didChangeNotification, object: nil)
        terminalView.surfaceDelegate = self
        // Side's own: `agent;<name>;<session id>;<nonce>` from the shell's `claude` wrapper, so a
        // restart can resume the exact conversation. Without the nonce, it's anyone's output.
        terminalView.onAgentReport = { [weak self] parts in
            guard let self, parts.count == 4, parts[0] == "agent", parts[3] == self.markNonce, !parts[2].isEmpty else { return }
            self.onAgentSessionReported?(parts[1], parts[2])
        }
        terminalView.isDarkBackground = { [weak self] in
            guard let color = self?.terminalView.backgroundColor else { return true }
            return 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent < 0.5
        }
        terminalView.programListensForColorScheme = { [weak self] in self?.runningProgramName == "claude" }
        terminalView.onFileLinkRequested = { [weak self] link in self?.onFileLinkRequested?(link) ?? false }
        terminalView.onLineSubmitted = { [weak self] line in self?.lastSubmittedCommand = line }
        terminalView.onDataReceived = { [weak self] in self?.onOutputReceived?() }
        terminalView.onRawDataReceived = { [weak self] slice in
            self?.onCommandOutput?(slice)
            self?.handleAgentCommandData(slice)
        }
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(terminalView)
        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: view.topAnchor),
            terminalView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    func activate() {
        ensureStarted()
        view.window?.makeFirstResponder(terminalView)
        // Seen: a bell or a finished turn from before no longer wants you.
        if news != nil {
            lastBellAt = nil
            turnFinishedAt = nil
            onNewsChanged?()
        }
    }

    /// Starts the shell without claiming first responder — split out of `activate()` so an
    /// agent's `run_shell_command` can lazily spin up a track's session in the background
    /// (e.g. its first command ever) without stealing focus from whatever the user is actually
    /// looking at in this window.
    /// Starts the process without taking focus — for a command tab created in the background.
    func start() { ensureStarted() }

    private func ensureStarted() {
        guard !didStart else { return }
        didStart = true
        isAlive = true
        // Laid out first when it's on screen, so the shell starts (or a keeper's session is
        // rejoined) at the terminal's real size, not SwiftTerm's 80×25 before layout: the prompt
        // drawn at 80 columns and then resized came back broken (a right-aligned segment
        // stranded mid-screen).
        if terminalView.bounds.isEmpty, view.window != nil { view.superview?.layoutSubtreeIfNeeded() }
        if let launch = commandLaunch {
            // `env` resolves the command on PATH, which comes from the login shell — a GUI
            // app's own PATH has no Homebrew, nvm or the like.
            var environment = TerminalEnvironment.base(termName: "xterm-256color")
            if let path = LanguageServerRegistry.environmentForSpawning()["PATH"] { environment.append("PATH=\(path)") }
            environment += launch.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            environment += Self.portEnvironment(for: workingDirectory)
            shellIntegration = .unavailable
            terminalView.startProcess(executable: "/usr/bin/env", arguments: [launch.command] + launch.arguments, environment: environment, currentDirectory: workingDirectory)
            return
        }
        if let keeperID, SessionKeepers.isEnabled, let record = SessionKeepers.liveRecord(keeperID), reattach(record) { return }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        // zsh gets its integration through a ZDOTDIR wrapper (the VS Code technique): the shell
        // sources our rc — which sources the user's own — so the hooks install before the first
        // prompt and *nothing is ever typed into the session*. The old typed-setup path stays
        // for bash, where no equivalent exists without clobbering the user's rc files.
        var environment = TerminalEnvironment.base(termName: "xterm-256color")
        if shell.contains("zsh"), let wrapper = Self.zshIntegrationDirectory() {
            if let original = ProcessInfo.processInfo.environment["ZDOTDIR"] {
                environment.append("SIDE_ORIG_ZDOTDIR=\(original)")
            }
            environment.append("ZDOTDIR=\(wrapper.path)")
            environment.append("SIDE_MARK_NONCE=\(markNonce)")
            integrationInstalledViaRc = true
        }
        environment += Self.portEnvironment(for: workingDirectory)
        if let keeperID, SessionKeepers.isEnabled, startInKeeper(id: keeperID, executable: shell, environment: environment) {
            installShellIntegration(shell: shell)
            if let recovering { resumeAfterRestart(recovering) }
            return
        }
        // A recovery that couldn't get a keeper starts plainly; what it left behind goes.
        if let keeperID, recovering != nil { SessionPaths.remove(keeperID) }
        terminalView.startProcess(executable: shell, arguments: ["-l"], environment: environment, currentDirectory: workingDirectory)
        installShellIntegration(shell: shell)
    }

    // MARK: - Session keeper

    /// A new shell in its own keeper. False if the keeper couldn't start; the shell then runs
    /// in Side's process as before, so a broken keeper never costs a terminal.
    private func startInKeeper(id: String, executable: String, environment: [String]) -> Bool {
        var facts = keeperFacts
        facts[SessionKeepers.Fact.nonce] = markNonce
        facts[SessionKeepers.Fact.integration] = integrationInstalledViaRc ? "rc" : "typed"
        // A recovered tab starts from its saved screen, below a line saying so.
        let snapshot = recovering.map { SessionPaths.snapshot($0.id).path }.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
        let spec = LaunchSpec(id: id, executable: executable, arguments: ["-l"], environment: environment,
                              directory: workingDirectory ?? NSHomeDirectory(), cols: max(terminalView.columns, 2), rows: max(terminalView.rows, 2), client: facts,
                              restoreFrom: snapshot, banner: snapshot == nil ? nil : SessionKeepers.restartBanner,
                              notifier: SessionKeepers.notifierURL?.path,
                              place: keeperFacts[SessionKeepers.Fact.project].map { ($0 as NSString).lastPathComponent })
        guard let link = try? KeeperLink.launch(spec) else { return false }
        wire(link)
        // At its real size when it has one (`ensureStarted` lays it out first); else unsized,
        // and the keeper keeps its own until this one has one (`KeeperLink.attach`).
        let sized = !terminalView.bounds.isEmpty
        link.attach(cols: sized ? terminalView.columns : 0, rows: sized ? terminalView.rows : 0, history: terminalView.scrollbackLines)
        return true
    }

    /// The shell this tab had, still running in its keeper: its screen comes back from the
    /// keeper's snapshot, and its shell integration is the one it was started with.
    private func reattach(_ record: SessionRecord) -> Bool {
        guard let link = try? KeeperLink.connect(record.id) else { return false }
        if let nonce = record.client[SessionKeepers.Fact.nonce] { markNonce = nonce }
        switch record.client[SessionKeepers.Fact.integration] {
        case "rc": integrationInstalledViaRc = true; shellIntegration = .confirmed
        case "typed": shellIntegration = .confirmed
        default: shellIntegration = .unavailable
        }
        didTidyAfterSetup = true
        reattachedTitlePending = true
        replayEndsAt = Date().addingTimeInterval(Self.replayDuration)
        wire(link)
        // At its real size when it has one (`ensureStarted` lays it out first); else unsized,
        // and the keeper keeps its own until this one has one (`KeeperLink.attach`).
        let sized = !terminalView.bounds.isEmpty
        link.attach(cols: sized ? terminalView.columns : 0, rows: sized ? terminalView.rows : 0, history: terminalView.scrollbackLines)
        return true
    }

    /// The first title after a reattach names what was already running before it.
    private var reattachedTitlePending = false
    /// Until then, a reattached tab is catching up on its screen: a spinner that stops in what
    /// it replays is a turn that ended before Side came back, not one to report.
    private var replayEndsAt: Date?
    private static let replayDuration: TimeInterval = 2

    private func wire(_ link: KeeperLink) {
        terminalView.keeper = link
        link.onSnapshot = { [weak self] bytes in self?.terminalView.display(bytes[...]) }
        link.onOutput = { [weak self] bytes in self?.terminalView.receive(bytes) }
        link.onTitle = { [weak self] title in
            guard let self, self.reattachedTitlePending else { return }
            self.reattachedTitlePending = false
            self.setProgramTitle(Self.cleanProgramTitle(title))
        }
        // What the program says it's doing (OSC 7501), kept by the keeper: the session registry
        // reads it (SIDE_RFC_SESSIONS.md). A reattach starts from the record's copy.
        programStatus = ProgramStatusRecords(link.record?.programStatus ?? [])
        link.onProgramStatus = { [weak self] records in
            guard let self else { return }
            self.programStatus = ProgramStatusRecords(records)
            NotificationCenter.default.post(name: Self.programStatusDidChangeNotification, object: self)
        }
        link.onExit = { [weak self] exit in self?.keeperSessionEnded(exitCode: exit.status) }
        link.onLost = { [weak self] replaced in self?.keeperConnectionLost(replaced: replaced) }
    }

    /// Once the new shell is ready: Claude resumes its conversation, an editor or watcher starts
    /// again, anything else is offered.
    private func resumeAfterRestart(_ record: SessionRecord) {
        switch SessionKeepers.recovery(foreground: record.foreground, agentSession: recoveredAgentSession) {
        case .nothing:
            break
        case .offer(let command):
            rerunOffer = command
            onRerunOfferChanged?()
        case .run(let command):
            // Offered, never run, under UI testing: a test's recovered tab started the real
            // `claude --continue` on the developer's account (2026-11-04).
            guard !AppDelegate.isUITesting else {
                rerunOffer = command
                onRerunOfferChanged?()
                return
            }
            whenShellIsReady { [weak self] in self?.terminalView.send(text: command + "\r") }
        }
    }

    /// Runs `body` once the shell is past its startup (prompt drawn, integration settled), or
    /// after ten seconds regardless.
    private func whenShellIsReady(_ body: @escaping () -> Void, waited: Int = 0) {
        if startupSettled || waited >= 100 { return body() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.whenShellIsReady(body, waited: waited + 1) }
    }

    /// What's running in this terminal, named for a close warning, or nil when it's only the shell
    /// at its prompt. From the shell's own marks; a shell without them, from the keeper's record
    /// of its foreground program.
    var runningProgramName: String? {
        guard didStart, isAlive else { return nil }
        if let launch = commandLaunch { return (launch.command as NSString).lastPathComponent }
        // Asked of the kernel: what was typed is no guide (an autosuggestion accepted with →
        // typed "claOC", and a message to Claude Code is a line too).
        if let shell = shellPID { return ForegroundProgram.name(ofShell: shell) }
        guard let keeperID, let record = SessionKeepers.liveRecord(keeperID) else { return nil }
        return ForegroundProgram.name(arguments: record.foreground)
    }

    /// The program's status records (OSC 7501), as its keeper keeps them; empty for a terminal
    /// with no keeper, or a program that doesn't report.
    private(set) var programStatus = ProgramStatusRecords()
    static let programStatusDidChangeNotification = Notification.Name("SideTerminalProgramStatusDidChange")

    /// The shell's process: Side's own child, or the keeper's, read once from its record.
    private var shellPID: pid_t? {
        if terminalView.keeper == nil {
            let pid = terminalView.processID
            return pid > 0 ? pid : nil
        }
        if keeperShellPID == nil, let keeperID { keeperShellPID = SessionKeepers.liveRecord(keeperID).map(\.childPID).flatMap { $0 > 0 ? $0 : nil } }
        return keeperShellPID
    }
    private var keeperShellPID: pid_t?

    /// Run Again: types the offered command into the shell.
    /// Types `command` into the shell once it's ready: Agent's Continue in Terminal.
    func runWhenReady(_ command: String) {
        whenShellIsReady { [weak self] in self?.terminalView.send(text: command + "\r") }
    }

    func runOfferedCommand() {
        guard let command = rerunOffer else { return }
        dismissRerunOffer()
        whenShellIsReady { [weak self] in self?.terminalView.send(text: command + "\r") }
    }

    func dismissRerunOffer() {
        rerunOffer = nil
        onRerunOfferChanged?()
    }

    /// The connection to the keeper ended without an exit. Only a keeper that's gone ends the
    /// session: one still running is rejoined, its screen fresh from its snapshot. Two Claude
    /// Code sessions said they had ended while their keepers and Claude ran on, with no way back
    /// but a new tab (the owner, 2026-11-05). Taken by another Side, it's rejoined on the next
    /// key, not at once: two Sides would take it back and forth.
    private func keeperConnectionLost(replaced: Bool) {
        terminalView.keeper = nil
        guard isAlive else { return }
        guard let keeperID, let record = SessionKeepers.liveRecord(keeperID) else { return keeperSessionEnded(exitCode: nil, lost: true) }
        if replaced {
            terminalView.display(text: "\r\n\u{1B}[2m[This terminal is open in another Side. Press a key to bring it back here.]\u{1B}[0m\r\n")
            rejoinsOnInput = true
            return
        }
        // A keeper that keeps letting go isn't chased: three drops in a minute end it.
        let now = Date()
        rejoins = rejoins.filter { now.timeIntervalSince($0) < 60 } + [now]
        guard rejoins.count <= 3 else { return keeperSessionEnded(exitCode: nil, lost: true) }
        rejoin(record)
    }
    private var rejoins: [Date] = []
    private var rejoinsOnInput = false

    /// Back to a keeper still running: the screen is reset and drawn again from its snapshot.
    private func rejoin(_ record: SessionRecord) {
        rejoinsOnInput = false
        terminalView.display(text: "\u{1B}c")
        if !reattach(record) { keeperSessionEnded(exitCode: nil, lost: true) }
    }

    /// A key in a terminal another Side took: it comes back here (the key itself isn't sent).
    func rejoinIfTaken() -> Bool {
        guard rejoinsOnInput, isAlive else { return false }
        guard let keeperID, let record = SessionKeepers.liveRecord(keeperID) else {
            rejoinsOnInput = false
            keeperSessionEnded(exitCode: nil, lost: true)
            return true
        }
        rejoin(record)
        return true
    }

    /// `lost`: the keeper went away without saying how the session ended (it crashed, or was
    /// killed). The terminal says so, rather than sit there taking input that goes nowhere.
    private func keeperSessionEnded(exitCode: Int32?, lost: Bool = false) {
        terminalView.keeper = nil
        guard isAlive else { return }
        if lost {
            terminalView.display(text: "\r\n\u{1B}[2m[This terminal's session ended unexpectedly, and what ran in it has stopped. Open a new tab (\u{2318}T) to carry on.]\u{1B}[0m\r\n")
        }
        processEnded(exitCode)
    }

    /// Closing a window or quitting: a shell in a keeper is let go and keeps running (unless
    /// Settings says to end terminals on quit); one in Side's own process ends, as it always has.
    func detachOrClose() {
        if let keeper = terminalView.keeper, SessionKeepers.keepsRunningOnQuit {
            keeper.detach()
            terminalView.keeper = nil
        } else {
            prepareForClose()
        }
    }

    /// A track's terminal gets its ports (`TrackPorts`): what runs in it, the agent's commands
    /// included, starts servers on `PORT` without colliding with another track's.
    static func portEnvironment(for directory: String?) -> [String] {
        TrackPorts.environment(forDirectory: directory).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    }

    /// Writes (once) and returns the wrapper ZDOTDIR whose startup files source the user's own
    /// and then register the OSC 133 hooks. Each wrapper file mirrors zsh's real sourcing order
    /// (.zshenv → .zprofile → .zshrc → .zlogin) so a login shell behaves exactly as it would in
    /// Terminal.app, plus the hooks.
    private static func zshIntegrationDirectory() -> URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = support.appendingPathComponent("Side/zsh-integration", isDirectory: true)
        let hooks = #"""
        __SIDE_NONCE=$SIDE_MARK_NONCE; unset SIDE_MARK_NONCE
        __side_done(){ printf '\e]133;D;%s;%s\a' $? $__SIDE_NONCE; printf '\e]7;file://%s%s\a' "$HOST" "${PWD// /%20}"; }
        __side_start(){ printf '\e]133;C\a'; }
        typeset -ga precmd_functions preexec_functions
        precmd_functions=(__side_done ${precmd_functions:#__side_done})
        preexec_functions=(${preexec_functions:#__side_start} __side_start)
        printf '\e]133;D;0;%s\a' $__SIDE_NONCE
        printf '\e]7;file://%s%s\a' "$HOST" "${PWD// /%20}"
        # Claude Code with a known session id, reported to Side so a restart resumes it exactly
        # (SIDE_RFC_SESSION_RESTORE.md). An explicit --resume <id> is reported as is; --continue,
        # a bare --resume picker and --print are left alone. An alias of the user's wins.
        claude() {
          local i=1 a
          while (( i <= $# )); do
            a=${@[i]}
            case $a in
              --session-id|--session-id=*|-c|--continue|-p|--print) command claude "$@"; return ;;
              -r|--resume)
                (( i < $# )) && [[ ${@[i+1]} != -* ]] && printf '\e]6973;agent;claude;%s;%s\a' "${@[i+1]}" "$__SIDE_NONCE"
                command claude "$@"; return ;;
              --resume=*) printf '\e]6973;agent;claude;%s;%s\a' "${a#--resume=}" "$__SIDE_NONCE"; command claude "$@"; return ;;
            esac
            (( i++ ))
          done
          local id=${(L)$(uuidgen)}
          printf '\e]6973;agent;claude;%s;%s\a' "$id" "$__SIDE_NONCE"
          command claude --session-id "$id" "$@"
        }
        """#
        func wrapper(_ name: String, extra: String = "") -> String {
            """
            SIDE_USER_ZDOTDIR=${SIDE_ORIG_ZDOTDIR:-$HOME}
            if [[ -f "$SIDE_USER_ZDOTDIR/\(name)" ]]; then
                SIDE_WRAPPER_ZDOTDIR=$ZDOTDIR
                ZDOTDIR=$SIDE_USER_ZDOTDIR
                . "$SIDE_USER_ZDOTDIR/\(name)"
                SIDE_ORIG_ZDOTDIR=${ZDOTDIR:-$HOME}
                ZDOTDIR=$SIDE_WRAPPER_ZDOTDIR
            fi
            \(extra)
            """
        }
        // .zshrc is the last interactive-startup file we need control in: hooks register after
        // the user's config so a themed prompt can't displace them, then ZDOTDIR is restored so
        // nested `zsh` invocations start clean.
        let restore = "ZDOTDIR=${SIDE_ORIG_ZDOTDIR:-$HOME}; [[ \"$ZDOTDIR\" == \"$HOME\" ]] && unset ZDOTDIR\n"
        let files = [
            ".zshenv": wrapper(".zshenv"),
            ".zprofile": wrapper(".zprofile"),
            ".zshrc": wrapper(".zshrc", extra: hooks + "\n" + restore),
            ".zlogin": wrapper(".zlogin"),
        ]
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (name, contents) in files {
                let url = dir.appendingPathComponent(name)
                // Rewrite only when changed, so the files don't churn mtimes on every tab.
                if (try? String(contentsOf: url, encoding: .utf8)) != contents {
                    try contents.write(to: url, atomically: true, encoding: .utf8)
                }
            }
            return dir
        } catch {
            return nil
        }
    }

    /// Wipes the echoed setup line once the shell has confirmed it took effect.
    ///
    /// Sends Ctrl-L rather than a `clear` command or a locally-fed escape sequence: the shell's
    /// own clear-screen redraws the prompt (and preserves anything half-typed), where feeding an
    /// escape would leave the screen blank until the user pressed Return, and typing `clear`
    /// would just echo a second line of our own noise. Only fires once, and only for the
    /// startup install — a user's own Ctrl-L habit isn't something to duplicate.
    private func tidyAfterSetup() {
        guard !didTidyAfterSetup else { return }
        didTidyAfterSetup = true
        // Ctrl-L exists to clear the *typed* setup line; the ZDOTDIR path types nothing.
        guard !integrationInstalledViaRc else { return }
        terminalView.send(bytes: ArraySlice([0x0C]))
    }

    /// Asks the shell to emit OSC 133 semantic-prompt marks — the same protocol VS Code, iTerm2,
    /// and WezTerm use — so a command's output can be delimited exactly instead of guessed at.
    ///
    /// Without this, the only way to know what a command printed was "everything between the
    /// echoed command line and a sentinel," which unavoidably swept up the user's shell prompt
    /// (git segments, box-drawing, redraw artifacts) into every tool result: noise the model pays
    /// for in context on every single command. With the marks, the shell itself says where output
    /// begins (`C`, at preexec) and ends (`D;<exit code>`, at precmd), so prompts fall outside the
    /// captured region by construction.
    ///
    /// Registered through `add-zsh-hook` rather than by defining `precmd`/`preexec` directly —
    /// defining them would silently clobber the user's own hooks, which is how you break a
    /// powerlevel10k prompt. Unsupported shells simply never confirm and fall back to the
    /// sentinel path.
    private func installShellIntegration(shell: String) {
        // zsh installed through the ZDOTDIR wrapper: the .zshrc already registered the hooks
        // and emitted the first D mark — nothing to type, just wait for the probe to confirm.
        if integrationInstalledViaRc {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.shellIntegration == .probing else { return }
                self.shellIntegration = .unavailable
                self.drainQueuedAgentCommandsIfIdle()
            }
            return
        }
        let setup: String
        if shell.contains("zsh") {
            // `precmd_functions` is *prepended*, not appended: hooks run in array order, and a
            // themed prompt (powerlevel10k) prints in its own precmd. Registering after it put
            // that output inside the C..D window — a stray `%` showed up in every result — and
            // `$?` would read the previous hook's status rather than the command's.
            setup = "__side_done(){ printf '\\e]133;D;%s\\a' $?; }; __side_start(){ printf '\\e]133;C\\a'; }; typeset -ga precmd_functions preexec_functions; precmd_functions=(__side_done ${precmd_functions:#__side_done}); preexec_functions=(${preexec_functions:#__side_start} __side_start); printf '\\e]133;D;0\\a'"
        } else if shell.contains("bash") {
            setup = "__side_done(){ printf '\\e]133;D;%s\\a' \"$?\"; printf '\\e]7;file://%s%s\\a' \"$HOSTNAME\" \"${PWD// /%20}\"; }; PROMPT_COMMAND=\"__side_done;${PROMPT_COMMAND}\"; trap 'printf \"\\e]133;C\\a\"' DEBUG; printf '\\e]133;D;0\\a'"
        } else {
            shellIntegration = .unavailable
            return
        }
        // A space prefix keeps it out of history when HIST_IGNORE_SPACE is set. The line itself
        // is echoed by the shell — Side never runs anything hidden — and `tidyAfterSetup()`
        // then clears it away so the user's session doesn't open on two paragraphs of our
        // plumbing.
        terminalView.send(bytes: ArraySlice(Array((" " + setup + "\r").utf8)))
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.shellIntegration == .probing else { return }
            self.shellIntegration = .unavailable
            self.drainQueuedAgentCommandsIfIdle()
        }
    }

    /// Types `command` into this session the same way keystrokes go in — the human sees the
    /// exact same prompt/output they'd see typing it themselves, per "no accidental
    /// surveillance." Wraps it with a sentinel + exit-code echo and resolves `completion` once
    /// that sentinel shows up in the raw output stream, or after `agentCommandTimeout` with a
    /// "still running" hint — a long-running or interactive command keeps running in the real,
    /// visible terminal; this just stops blocking the conversation on it.
    func runAgentCommand(_ command: String, timeout: TimeInterval = TerminalViewController.agentCommandTimeout, completion: @escaping (String) -> Void) {
        ensureStarted()
        // Only the sentinel fallback needs these refusals: it appends a line the shell must be
        // ready to parse, so anything leaving the shell mid-parse eats it. With shell-integration
        // marks nothing is appended, so heredocs and multi-line commands are fine.
        if shellIntegration != .confirmed, let reason = Self.unwrappableReason(for: command) {
            completion(reason)
            return
        }
        // Also queued while the integration probe is outstanding — starting now would pick a
        // capture strategy before knowing which one actually works.
        guard pendingAgentCommand == nil, shellIntegration != .probing else {
            queuedAgentCommands.append((command, timeout, completion))
            return
        }
        startAgentCommand(command, timeout: timeout, completion: completion)
    }

    private func drainQueuedAgentCommandsIfIdle() {
        guard pendingAgentCommand == nil, shellIntegration != .probing,
              !queuedAgentCommands.isEmpty else { return }
        let next = queuedAgentCommands.removeFirst()
        startAgentCommand(next.command, timeout: next.timeout, completion: next.completion)
    }

    /// Answers every queued command with `reason` and empties the queue.
    ///
    /// Clearing the queue without calling its completions is how a tool_use ends up with no
    /// tool_result: the batch never empties, the runner sits in awaitingApproval until the window
    /// closes, and nothing is persisted. Both paths that empty the queue — Stop, and the shell
    /// exiting — used to do exactly that. (2026-09-01 audit, H13.)
    private func cancelQueuedAgentCommands(reason: String) -> Int {
        let cancelled = queuedAgentCommands
        queuedAgentCommands.removeAll()
        for queued in cancelled { queued.completion(reason) }
        return cancelled.count
    }

    private func startAgentCommand(_ command: String, timeout: TimeInterval, completion: @escaping (String) -> Void) {
        let sentinel = "__SIDE_AGENT_DONE_\(UUID().uuidString)__"
        pendingAgentCommandGeneration += 1
        let generation = pendingAgentCommandGeneration
        let usesMarks = shellIntegration == .confirmed
        markedOutput = []
        pendingAgentCommand = (sentinel, "", 0, command, usesMarks, false, completion)
        // With shell integration the command is sent exactly as-is: the shell's own marks report
        // completion, so nothing has to be appended to the user's command line at all.
        // Without it, fall back to a sentinel echo on its own line — on its own line because a
        // command ending in a `#` comment used to swallow an appended echo entirely, so the
        // command ran and nothing ever reported it finished.
        let wrapped = usesMarks ? "\(command)\r" : "\(command)\recho \"\(sentinel):$?\"\r"
        terminalView.send(bytes: ArraySlice(Array(wrapped.utf8)))
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, self.pendingAgentCommandGeneration == generation,
                  self.pendingAgentCommand?.sentinel == sentinel else { return }
            // Deliberately *not* interrupted: a slow build or test run is legitimate, and it
            // keeps running in the real terminal where the user can watch it. The message says
            // exactly that instead of the old "Still running — check Run for output," which
            // implied output was available and said nothing about the command's fate.
            self.finishPendingAgentCommand(
                "No result after \(Int(timeout))s. The command was NOT interrupted; it is still running in this track's terminal, where its output is visible. Do not assume it succeeded or failed; ask the user what it did, or run something that inspects the result."
            )
        }
    }

    /// Resolves whatever command currently holds the slot and starts the next queued one.
    private func finishPendingAgentCommand(_ output: String) {
        guard let pending = pendingAgentCommand else { return }
        pendingAgentCommand = nil
        pending.completion(output)
        guard !queuedAgentCommands.isEmpty else { return }
        let next = queuedAgentCommands.removeFirst()
        startAgentCommand(next.command, timeout: next.timeout, completion: next.completion)
    }

    /// Why this command can't be wrapped with a completion sentinel, or `nil` if it can.
    ///
    /// The wrapper submits the command, then a second line that echoes a sentinel and `$?`. That
    /// only works if the shell finishes parsing the command at end-of-line. Anything that leaves
    /// the shell waiting for continuation — an unbalanced quote, a trailing backslash, a heredoc,
    /// an embedded newline — consumes the sentinel line as part of the command instead, so no
    /// completion is ever reported.
    static func unwrappableReason(for command: String) -> String? {
        // Scalars, not Characters: Swift treats "\r\n" as a *single* grapheme cluster, so
        // `contains("\n")` is false for CRLF and a command with Windows line endings would sail
        // through this guard and hang the terminal waiting for continuation.
        if command.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" }) {
            return "Not run: multi-line shell commands can't be tracked to completion here. Send a single-line command (join steps with `&&`), or use write_file to create file contents."
        }
        if command.contains("<<") {
            return "Not run: heredocs can't be tracked to completion here. Use write_file to create file contents instead."
        }
        if command.hasSuffix("\\") {
            return "Not run: a trailing backslash continues onto another line, which can't be tracked to completion here. Send the whole command on one line."
        }
        if hasUnbalancedQuotes(command) {
            return "Not run: the command has an unterminated quote, so the shell would wait for more input instead of finishing. Check the quoting and send it again."
        }
        return nil
    }

    /// Tracks single/double quotes, honoring backslash escapes outside single quotes (inside
    /// single quotes a backslash is literal, per POSIX).
    private static func hasUnbalancedQuotes(_ command: String) -> Bool {
        var inSingle = false
        var inDouble = false
        var escaped = false
        for character in command {
            if escaped { escaped = false; continue }
            switch character {
            case "\\" where !inSingle: escaped = true
            case "'" where !inDouble: inSingle.toggle()
            case "\"" where !inSingle: inDouble.toggle()
            default: break
            }
        }
        return inSingle || inDouble
    }

    /// Interrupts a running agent command (Ctrl-C to the foreground process group) and reports it
    /// truthfully. This is the cancellation path the runner's Stop uses — without it, a runaway
    /// command had no way to be stopped except the user typing into the terminal themselves.
    func interruptAgentCommand() {
        guard pendingAgentCommand != nil else { return }
        let queuedCount = cancelQueuedAgentCommands(reason: "Cancelled before it ran: the user stopped the agent while an earlier command was still running. Nothing changed.")
        // 0x03 = ETX, what Ctrl-C sends; the pty turns it into SIGINT for the foreground group.
        terminalView.send(bytes: ArraySlice([0x03]))
        var message = "Interrupted by the user (Ctrl-C) before it reported a result. Whether it partially completed is unknown. Check before assuming."
        if queuedCount > 0 {
            message += " \(queuedCount) queued command\(queuedCount == 1 ? "" : "s") were also cancelled and did not run."
        }
        finishPendingAgentCommand(message)
    }

    /// Waits for the sentinel *and* the `:<exit code>` that follows it (`echo` prints both on
    /// the same line) — if only the sentinel token has arrived so far, the exit code hasn't
    /// finished printing yet, so this keeps buffering rather than resolving one byte early.
    ///
    /// The sentinel text appears in the raw stream *twice*: once as the terminal's live echo of
    /// what we just typed (literally, before the shell has even processed Return — `$?` shows up
    /// unexpanded), and once for real once the command actually finishes and the shell expands
    /// `$?` to a real number. Only the second occurrence is genuine completion, so this scans
    /// past any occurrence whose exit-code text isn't purely numeric rather than resolving on
    /// the first (false) match.
    private func handleAgentCommandData(_ slice: ArraySlice<UInt8>) {
        trackCommandStatus(slice)
        // The probe: any `D` mark proves the shell is emitting OSC 133, whoever caused it.
        if shellIntegration == .probing, String(decoding: slice, as: UTF8.self).contains(";" + markNonce + Self.markTerminator) {
            shellIntegration = .confirmed
            tidyAfterSetup()
            drainQueuedAgentCommandsIfIdle()
        }
        guard var pending = pendingAgentCommand else { return }
        if pending.usesMarks {
            let finished = Self.advanceMarkedCapture(bytes: &markedOutput, outputStarted: &pending.outputStarted, chunk: slice, nonce: markNonce)
            pendingAgentCommand = pending
            guard let finished else { return }
            finishPendingAgentCommand(finished)
            return
        }
        // Stripped per-chunk, before accumulating — a shell that re-colors the line live as it
        // "types" (zsh-syntax-highlighting and similar) interleaves ANSI codes into the raw byte
        // stream mid-token, which can split the sentinel across escape sequences and make a
        // whole-buffer substring search miss it even though the rendered terminal shows the
        // sentinel as one clean, contiguous line.
        Self.boundedAppend(&pending.buffer, Self.stripANSI(String(decoding: slice, as: UTF8.self)))

        // Scan for `<sentinel>:<digits>` rather than reasoning about line structure.
        //
        // The buffer legitimately contains the sentinel more than once: the terminal echoes the
        // line as it's "typed" (with `$?` still unexpanded), zsh may redraw it while
        // highlighting, and only the final occurrence carries a real exit code. The previous
        // approach — take everything up to the next newline and require it to be numeric — broke
        // because the echoed line and the real output are *not* newline-separated in the raw
        // stream: zsh emits OSC title sequences and other non-CSI escapes between them, which
        // `stripANSI` didn't remove, so the echo and the result ran together as one "line". The
        // scan then consumed the real `:0` as part of the echo's text and skipped past it, and
        // the command never resolved. Matching digits directly is immune to that: `:$?` has no
        // digits after the colon, `:0` does.
        // Resume near where the previous chunk stopped rather than rescanning the whole buffer
        // every time — that restart made a command emitting a few MB quadratic on the main
        // thread. The overlap covers a sentinel split across two chunks.
        let overlap = pending.sentinel.count + 24
        var searchStart = pending.buffer.count > pending.scannedCharacters + overlap
            ? pending.buffer.index(pending.buffer.startIndex, offsetBy: pending.scannedCharacters - min(pending.scannedCharacters, overlap))
            : pending.buffer.startIndex
        // Generation-aware: resolving this command inside the loop below starts the *next* queued
        // one, which takes the slot. Writing `pending` back unconditionally then overwrote that
        // fresh command with this finished one — its sentinel was never matched, its timeout
        // never fired, its completion never ran, and the conversation hung on a missing
        // tool_result. (2026-09-01 audit, H12.)
        let generationAtEntry = pendingAgentCommandGeneration
        defer {
            pending.scannedCharacters = pending.buffer.count
            if pendingAgentCommand != nil, pendingAgentCommandGeneration == generationAtEntry { pendingAgentCommand = pending }
        }
        while let sentinelRange = pending.buffer.range(of: pending.sentinel, range: searchStart..<pending.buffer.endIndex) {
            let afterSentinel = pending.buffer[sentinelRange.upperBound...]
            guard afterSentinel.first == ":" else {
                searchStart = sentinelRange.upperBound
                continue
            }
            let digitsStart = afterSentinel.index(after: afterSentinel.startIndex)
            var cursor = digitsStart
            while cursor < afterSentinel.endIndex, afterSentinel[cursor].isNumber {
                cursor = afterSentinel.index(after: cursor)
            }
            guard cursor > digitsStart else {
                // No digits — this is the input echo, where `$?` is still literal.
                searchStart = sentinelRange.upperBound
                continue
            }
            guard cursor < afterSentinel.endIndex else {
                // Digits are still arriving; resolving now could read 1 out of a 130.
                pendingAgentCommand = pending
                return
            }
            let exitCode = Int(afterSentinel[digitsStart..<cursor]) ?? 0
            var output = Self.commandOutput(from: pending.buffer[pending.buffer.startIndex..<sentinelRange.lowerBound], sentinel: pending.sentinel, command: pending.command)
            // Always, not only on failure: the agent needs to distinguish "succeeded" from
            // "we could not tell", and a verification record that guesses from output text
            // would produce false verdicts about whether the project works.
            output += "\n[exit code: \(exitCode)]"
            pendingAgentCommand = pending
            finishPendingAgentCommand(output)
            return
        }
        pendingAgentCommand = pending
    }

    /// One chunk's worth of progress on an OSC 133 capture — pure, so it can be tested against a
    /// stream longer than the buffer.
    ///
    /// The bug this shape fixes: the buffer keeps only its last 60 000 characters, and the old
    /// code searched that buffer for the `C` ("output starts") mark on every chunk. A command that
    /// printed more than 60 KB between `C` and `D` pushed `C` off the front, so completion was
    /// never detected and the command reported the timeout's "still running" message after it had
    /// finished — on `swift test`, `npm test`, `xcodebuild test`: the verbose case the cap exists
    /// for, and the exact commands verification depends on. (2026-09-01 audit, H11.) `C` is now
    /// latched the first time it is seen and the buffer is cut to the output after it, so from
    /// then on only `D` matters, and the tail-keeping buffer keeps exactly the part that has `D`.
    struct MarkedCaptureStep {
        var buffer: String
        var outputStarted: Bool
        /// Non-nil once the `D` mark and its exit code have both arrived.
        var finished: String?
    }

    /// The same, in text (what the tests feed it).
    static func advanceMarkedCapture(buffer: String, outputStarted: Bool, chunk: String, nonce: String) -> MarkedCaptureStep {
        var bytes = Array(buffer.utf8), outputStarted = outputStarted
        let finished = advanceMarkedCapture(bytes: &bytes, outputStarted: &outputStarted, chunk: ArraySlice(chunk.utf8), nonce: nonce)
        return MarkedCaptureStep(buffer: String(decoding: bytes, as: UTF8.self), outputStarted: outputStarted, finished: finished)
    }

    /// In place, on the output's raw bytes: they're decoded once, when the command finishes,
    /// rather than once a read (which also repaired a character split across two reads into
    /// two replacement characters). Non-nil once finished.
    static func advanceMarkedCapture(bytes: inout [UInt8], outputStarted: inout Bool, chunk: ArraySlice<UInt8>, nonce: String) -> String? {
        bytes.append(contentsOf: chunk)
        // Trimmed past twice the cap, to the last cap's worth, on a character's first byte.
        if bytes.count > maxCommandBufferCharacters * 2 {
            var cut = bytes.count - maxCommandBufferCharacters
            while cut < bytes.count, bytes[cut] & 0xC0 == 0x80 { cut += 1 }
            bytes.removeFirst(cut)
        }
        // Only the new bytes are searched, and enough before them for a mark split across reads
        // (a mark with its exit code and nonce is well under 160 bytes): searching the whole
        // buffer again for every read was most of Run's CPU under a flood of output.
        var searchFrom = max(0, bytes.count - chunk.count - 160)
        if !outputStarted {
            guard let start = firstOffset(of: startMarkBytes, in: bytes, from: searchFrom) else { return nil }
            outputStarted = true
            bytes.removeFirst(start + startMarkBytes.count)
            searchFrom = 0
        }
        // Output is exactly what falls between the shell's own "output starts here" and "command
        // finished" marks, so the prompt is excluded by construction rather than by filtering.
        // A `D` mark is only the shell's if it carries this terminal's nonce; anything else
        // shaped like one is output and the search moves past it.
        let nonceBytes = Array(nonce.utf8)
        while let candidate = firstOffset(of: doneMarkBytes, in: bytes, from: searchFrom) {
            let payloadStart = candidate + doneMarkBytes.count
            // Still arriving — could be ours; wait for the rest.
            guard let terminator = firstOffset(of: markTerminatorBytes, in: bytes, from: payloadStart) else { return nil }
            let payload = bytes[payloadStart..<terminator].split(separator: separator, omittingEmptySubsequences: false)
            if payload.count == 2, payload[1].elementsEqual(nonceBytes), let exitCode = Int(String(decoding: payload[0], as: UTF8.self)) {
                var output = strippingPromptEOLMark(
                    stripANSI(String(decoding: bytes[..<candidate], as: UTF8.self))
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                if output.isEmpty { output = "(no output)" }
                // Always, not only on failure: the agent needs to distinguish "succeeded" from "we
                // could not tell", and a verification record that guesses from output text would
                // produce false verdicts about whether the project works.
                output += "\n[exit code: \(exitCode)]"
                return output
            }
            searchFrom = terminator + 1
        }
        return nil
    }

    /// What the model should see: the command's own output, with the wrapper's echoed sentinel
    /// lines removed so it never reads its own bookkeeping back as program output.
    private static func commandOutput(from raw: Substring, sentinel: String, command: String) -> String {
        // Split on *any* newline, CR included: zsh redraws a line in place with a bare `\r`
        // rather than `\n`, so splitting on `\n` alone leaves the wrapper's echoed sentinel
        // line and the command's real output inside one segment — and dropping that segment
        // threw the output away, reporting "(no output)" for a command that had printed.
        raw.split(whereSeparator: { $0.isNewline })
            .filter { segment in
                let trimmed = segment.trimmingCharacters(in: .whitespaces)
                return !trimmed.isEmpty && !trimmed.contains(sentinel) && trimmed != command
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strips ANSI escape/control sequences from a raw PTY byte stream — best-effort, not a real
    /// terminal parser. The human's own ground truth is the actual, visible terminal; this is
    /// only what gets fed back to the model afterward as a tool result.
    /// zsh prints an inverse-video `%` (PROMPT_EOL_MARK) when the previous output didn't end in
    /// a newline, and it emits it *before* precmd hooks run — so it lands inside the captured
    /// region and would otherwise appear at the end of every tool result. Only a final line that
    /// is exactly that marker is dropped; a command whose real last line is a lone `%` is
    /// conceivable but not worth carrying the noise for.
    static func strippingPromptEOLMark(_ output: String) -> String {
        // Split on `isNewline`, never on the literal "\n": Swift treats "\r\n" as a *single*
        // Character, so `split(separator: "\n")` doesn't split CRLF at all — the whole capture
        // stayed one "line" and the marker was never found. (Same grapheme trap as the CRLF
        // check in `unwrappableReason`; it bites anywhere terminal output is split by hand.)
        // Trailing CR also has to be trimmed, since zsh emits `\r` and padding after the mark.
        var lines = output.split(whereSeparator: { $0.isNewline })
        while let last = lines.last {
            let trimmed = last.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed == "%" || trimmed.isEmpty else { break }
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    /// OSC 133 semantic-prompt marks: `ESC ] 133 ; <kind> BEL`.
    static let markPrefix = "\u{1B}]133;"
    private static let markTerminator = "\u{07}"

    static func stripANSI(_ raw: String) -> String {
        // Order matters. CSI first (colors, cursor moves, `\u{1B}[?2004l` bracketed paste), then
        // the string-payload sequences — OSC/DCS/APC/PM — which carry text up to a BEL or ST
        // terminator; zsh sets the window title with an OSC on every prompt, and leaving those
        // in was what glued a command's echoed line to its real output. Only then the generic
        // two-character escapes (`\u{1B}>`, `\u{1B}=` keypad modes), which is safe as a catch-all
        // precisely because the sequences with payloads are already gone.
        var result = raw.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "\u{1B}[\\]P^_][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "\u{1B}.", with: "", options: .regularExpression)
        return result.replacingOccurrences(of: "\u{07}", with: "")
    }

    /// Kills the process without tearing down the view — used by "Stop", distinct from
    /// prepareForClose. Restarting reuses a fresh TerminalViewController instance in the same
    /// tab slot rather than trying to restart this one's LocalProcess in place.
    func stopProcess() {
        guard didStart, isAlive else { return }
        terminateProcessTree()
    }

    /// SwiftTerm's LocalProcess intentionally doesn't kill the shell from its own deinit
    /// (its deinit only tears down its own I/O resources) — without an explicit terminate,
    /// closing a window whose Run stage was ever activated leaves an orphaned shell process
    /// and drops the process into deinit while its own delegate callbacks may still be
    /// in flight. Call this before the owning window closes.
    func prepareForClose() {
        guard didStart, isAlive else { return }
        terminateProcessTree()
    }

    /// `LocalProcess.terminate()` only signals the shell's own PID — verified empirically that
    /// this genuinely isn't enough: an interactive shell's job control puts *every* backgrounded
    /// `&` job into its own separate process group by design (that's what lets you suspend/
    /// foreground jobs independently), so even `kill(-shellPid, ...)` (the whole original group)
    /// never reaches them. `npm run dev &`, or any plain background job, survives the shell being
    /// killed and is reparented to launchd, left running indefinitely with no owner. The only
    /// reliable fix is walking the live descendant tree via `ps` and signaling each PID directly
    /// — process group membership doesn't matter once you're killing by PID.
    private func terminateProcessTree() {
        if let keeper = terminalView.keeper {
            keeper.terminate()
            return
        }
        // A keeper's terminal this tab isn't attached to (another Side took it): closing the tab
        // still ends it, or it would run on with no tab, as two Claude Code sessions did.
        if let keeperID, SessionKeepers.liveRecord(keeperID) != nil {
            SessionKeepers.endSession(keeperID)
            return
        }
        let pid = terminalView.processID
        guard pid != 0 else {
            terminalView.terminateProcess()
            return
        }
        // Everything here happens off the main thread. The old version ran `/bin/ps` with a
        // synchronous waitUntilExit on main while tearing down the pty — the same
        // Foundation-Process-on-main pattern that crashed window tear-out, except here it could
        // also wedge against the dying shell's tty in an uninterruptible kernel wait (observed
        // live: a Side process that survived kill -9). Descendants are enumerated *before* the
        // shell is signaled, since killing the shell reparents its children to launchd and makes
        // them unfindable by walking down from the shell's pid.
        DispatchQueue.global(qos: .userInitiated).async {
            let descendants = Self.descendantPIDs(of: pid)
            kill(pid, SIGTERM)
            for descendantPID in descendants {
                kill(descendantPID, SIGTERM)
            }
        }
    }

    // MARK: - Theme

    @objc private func appearanceChanged() {
        applyTerminalTheme()
        terminalView.colorSchemeChanged()
    }

    /// Foreground, background, and the sixteen ANSI colours, from the design tokens for the
    /// current appearance. SwiftTerm's own defaults are a dim gray on pure black and know nothing
    /// about light mode; this is what makes Run follow the rest of the app.
    private func applyTerminalTheme() {
        let dark = DS.Appearance.isDark
        // The editor theme's terminal colors when it has them (Settings → Appearance).
        let theme = EditorThemes.current(dark: dark)
        let foreground = theme?.terminalText?.nsColor ?? NSColor.labelColor
        let background = theme?.terminalBackground?.nsColor ?? DS.Color.raised
        terminalView.applyTheme(TerminalSurfaceTheme(
            foreground: Self.resolved(foreground), background: Self.resolved(background),
            palette: theme?.ansi.map { $0.map(\.nsColor) } ?? Self.ansiPaletteColors(dark: dark),
            // Translucent background: the default background lets the window's backdrop through;
            // text and cells with a color of their own stay opaque.
            backgroundOpacity: DS.Translucency.isOn ? DS.Translucency.terminalOpacity : 1))
    }

    private static func resolved(_ color: NSColor) -> NSColor {
        var out = color
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            out = color.usingColorSpace(.sRGB) ?? color
        }
        return out
    }

    /// NSColor → SwiftTerm's 16-bit-per-channel `Color`, resolved for the current appearance.
    static func terminalColor(_ color: NSColor) -> Color {
        let rgb = resolved(color)
        return Color(red: UInt16(max(0, min(1, rgb.redComponent)) * 65535),
                     green: UInt16(max(0, min(1, rgb.greenComponent)) * 65535),
                     blue: UInt16(max(0, min(1, rgb.blueComponent)) * 65535))
    }

    /// The standard sixteen, tuned per appearance: the dark set is the familiar bright-on-black
    /// palette; the light set darkens every hue so yellow and cyan stay legible on near-white.
    static func ansiPalette(dark: Bool) -> [Color] { ansiPaletteColors(dark: dark).map(terminalColor) }

    static func ansiPaletteColors(dark: Bool) -> [NSColor] {
        func c(_ r: Double, _ g: Double, _ b: Double) -> NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }
        if dark {
            return [
                c(0.20, 0.20, 0.22), c(0.92, 0.40, 0.40), c(0.45, 0.80, 0.50), c(0.92, 0.80, 0.40),
                c(0.45, 0.65, 0.98), c(0.80, 0.55, 0.95), c(0.40, 0.85, 0.85), c(0.85, 0.85, 0.85),
                c(0.45, 0.45, 0.48), c(1.00, 0.50, 0.50), c(0.60, 0.90, 0.60), c(1.00, 0.90, 0.55),
                c(0.60, 0.75, 1.00), c(0.90, 0.65, 1.00), c(0.55, 0.95, 0.95), c(1.00, 1.00, 1.00),
            ]
        }
        return [
            c(0.15, 0.15, 0.17), c(0.75, 0.15, 0.15), c(0.12, 0.50, 0.22), c(0.62, 0.45, 0.02),
            c(0.12, 0.35, 0.80), c(0.55, 0.20, 0.75), c(0.05, 0.50, 0.55), c(0.55, 0.55, 0.58),
            c(0.40, 0.40, 0.42), c(0.85, 0.20, 0.20), c(0.10, 0.60, 0.25), c(0.70, 0.50, 0.00),
            c(0.10, 0.40, 0.95), c(0.65, 0.25, 0.90), c(0.00, 0.58, 0.65), c(0.10, 0.10, 0.10),
        ]
    }

    private static func descendantPIDs(of rootPID: pid_t) -> [pid_t] {
        let process = Process()
        process.environment = SpawnEnvironment.current()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-eo", "pid,ppid"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return []
        }
        // Read *before* waiting: `ps -eo pid,ppid` on a busy Mac can exceed the 64 KB pipe
        // buffer, at which point ps blocks writing while this blocked waiting — the shell and its
        // descendants never got SIGTERM, which is the orphaned-process leak this enumeration
        // exists to prevent. Same class as the eleven sites fixed on 2026-08-30. (Audit H18.)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        var childrenByParent: [pid_t: [pid_t]] = [:]
        for line in output.split(separator: "\n").dropFirst() {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, let pid = pid_t(parts[0]), let ppid = pid_t(parts[1]) else { continue }
            childrenByParent[ppid, default: []].append(pid)
        }

        var result: [pid_t] = []
        var queue = childrenByParent[rootPID] ?? []
        while let next = queue.popLast() {
            result.append(next)
            queue.append(contentsOf: childrenByParent[next] ?? [])
        }
        return result
    }

    // MARK: - TerminalSurfaceDelegate

    func terminalSurface(_ surface: any TerminalSurface, titleChanged title: String) {
        // A program's title, not the shell's. A tab reattached to its keeper doesn't know a
        // command is running (the shell's mark for it came before), so the kernel is asked too.
        guard commandStatus.runningSince != nil || shellPID.flatMap(ForegroundProgram.group(ofShell:)) != nil else { return }
        noteTitleGlyph(title)
        setProgramTitle(Self.cleanProgramTitle(title))
    }

    func noteTitleGlyph(_ title: String) {
        let glyph = title.unicodeScalars.first { !CharacterSet.whitespaces.contains($0) }
        setProgramWorking(glyph.map(Self.isSpinnerGlyph) ?? false)
    }

    static func isSpinnerGlyph(_ scalar: Unicode.Scalar) -> Bool {
        (0x2800...0x28FF).contains(scalar.value) && scalar.value != 0x2800 || "◐◓◑◒◴◵◶◷".unicodeScalars.contains(scalar)
    }

    private func setProgramWorking(_ working: Bool) {
        guard working != isProgramWorking else { return }
        // A turn that ended out of sight: the activity pill says it finished until you look.
        if !working, !isOnScreen, replayEndsAt.map({ Date() >= $0 }) ?? true { turnFinishedAt = Date() }
        if working { turnFinishedAt = nil }
        isProgramWorking = working
        onWorkingChanged?()
    }

    private func setProgramTitle(_ title: String?) {
        guard title != programTitle else { return }
        programTitle = title
        onProgramTitleChanged?()
    }

    /// A program's title without the spinner or status glyph in front (Claude Code animates one
    /// there), so the tab doesn't redraw on every frame of it. Empty is no title.
    static func cleanProgramTitle(_ title: String) -> String? {
        let trimmed = title.drop { !$0.isLetter && !$0.isNumber }.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(60))
    }

    func terminalSurface(_ surface: any TerminalSurface, directoryChanged directory: String?) {
        let path = directory.map(Self.pathFromOSC7)
        guard path != currentDirectory else { return }
        currentDirectory = path
        onDirectoryChanged?(path)
    }

    /// OSC 7 carries `file://host/path` with spaces percent-encoded; the status line wants a path.
    static func pathFromOSC7(_ value: String) -> String {
        guard value.hasPrefix("file://") else { return value }
        let rest = value.dropFirst("file://".count)
        let path = rest.firstIndex(of: "/").map { String(rest[$0...]) } ?? String(rest)
        return path.removingPercentEncoding ?? path
    }

    private func trackCommandStatus(_ chunk: ArraySlice<UInt8>) {
        // Only the nonce-carrying marks count where the rc install provides one; the typed bash
        // setup has no nonce, and its marks drive nothing but this display.
        let marks = Self.scanCommandMarks(carry: &markScanCarry, chunk: chunk, nonce: integrationInstalledViaRc ? markNonce : nil)
        guard !marks.isEmpty else { return }
        var status = commandStatus
        for mark in marks {
            switch mark {
            case .started:
                status.runningSince = Date()
            case .finished(let code):
                // The startup mark has no command before it; nothing ran, nothing to report.
                guard let start = status.runningSince else { continue }
                status.lastExitCode = code
                status.lastDuration = Date().timeIntervalSince(start)
                status.runningSince = nil
                setProgramTitle(nil)
                setProgramWorking(false)
                status.lastCommandWasAgent = pendingAgentCommand != nil
                status.finishedCount += 1
            }
        }
        guard status != commandStatus else { return }
        commandStatus = status
        onCommandStatusChanged?()
    }

    enum CommandMark: Equatable { case started, finished(exitCode: Int) }

    /// Every OSC 133 C / D mark in `chunk`, in order, with `carry` joining a mark split across
    /// reads. `nonce` nil accepts marks without one (the typed bash setup emits none).
    static func scanCommandMarks(carry: String, chunk: String, nonce: String?) -> (carry: String, marks: [CommandMark]) {
        var bytes = Array(carry.utf8)
        let marks = scanCommandMarks(carry: &bytes, chunk: ArraySlice(chunk.utf8), nonce: nonce)
        return (String(decoding: bytes, as: UTF8.self), marks)
    }

    /// The same, on raw bytes, `carry` kept in place.
    static func scanCommandMarks(carry: inout [UInt8], chunk: ArraySlice<UInt8>, nonce: String?) -> [CommandMark] {
        // Most reads hold no escape at all: nothing to find, nothing to carry.
        if carry.isEmpty, !chunk.contains(markPrefixBytes[0]) { return [] }
        var text = carry
        text.append(contentsOf: chunk)
        var marks: [CommandMark] = []
        var searchFrom = 0
        while let prefix = firstOffset(of: markPrefixBytes, in: text, from: searchFrom) {
            let bodyStart = prefix + markPrefixBytes.count
            guard let terminator = firstOffset(of: markTerminatorBytes, in: text, from: bodyStart) else {
                // Still arriving: keep it (bounded) for the next read.
                carry = Array(text[prefix...].prefix(256))
                return marks
            }
            let body = text[bodyStart..<terminator]
            if body.elementsEqual([UInt8(ascii: "C")]) {
                marks.append(.started)
            } else if body.starts(with: [UInt8(ascii: "D"), separator]) {
                let payload = body.dropFirst(2).split(separator: separator, omittingEmptySubsequences: false)
                let nonceMatches = nonce.map { payload.count == 2 && payload[1].elementsEqual($0.utf8) } ?? (payload.count <= 2)
                if nonceMatches, let first = payload.first, let code = Int(String(decoding: first, as: UTF8.self)) { marks.append(.finished(exitCode: code)) }
            }
            searchFrom = terminator + 1
        }
        // A tail shorter than the prefix can't hold a whole mark, so nothing is seen twice.
        carry = Array(text[searchFrom...].suffix(markPrefixBytes.count - 1))
        return marks
    }

    func terminalSurface(_ surface: any TerminalSurface, processTerminated exitCode: Int32?) { processEnded(exitCode) }

    private func processEnded(_ exitCode: Int32?) {
        isAlive = false
        onProcessExit?(exitCode)
        // A command like `exit` kills the shell, so the sentinel can never print. Without this
        // the call sat until the timeout and then claimed it was "still running" — of a shell
        // that no longer existed.
        if pendingAgentCommand != nil {
            let queuedCount = cancelQueuedAgentCommands(reason: "Did not run: the shell exited before this command's turn. Nothing changed.")
            var message = "The shell exited before reporting a result, so this command's outcome is unknown (a command that ends the shell, like `exit` or `logout`, can't report back)."
            if queuedCount > 0 {
                message += " \(queuedCount) queued command\(queuedCount == 1 ? "" : "s") did not run."
            }
            finishPendingAgentCommand(message)
        }
        onExitStatusChanged?(false, exitCode)
    }
}

/// A thumb-only overlay scroller: invisible at rest, shown by `flash()` and faded out once
/// scrolling stops — what an overlay `NSScroller` does inside an `NSScrollView`, which Run's
/// terminal doesn't have. Hidden (not just transparent) at rest so clicks reach the terminal.
final class OverlayScrollThumb: NSView {
    static let trackWidth: CGFloat = 12
    var onDrag: ((Double) -> Void)?
    private let knob = NSView()
    private var enabled = false
    private var proportion: CGFloat = 1
    private var position: Double = 0
    private var hideWork: DispatchWorkItem?
    private var dragOffset: CGFloat?

    init() {
        super.init(frame: .zero)
        isHidden = true
        alphaValue = 0
        knob.wantsLayer = true
        knob.bindLayerBackground(DS.Color.scrollKnob)
        addSubview(knob)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var track: NSRect { bounds.insetBy(dx: 0, dy: 3) }
    private var knobHeight: CGFloat { max(24, track.height * min(1, proportion)) }

    func update(enabled: Bool, proportion: CGFloat, position: Double) {
        self.enabled = enabled
        self.proportion = proportion
        self.position = position
        if !enabled { hideNow() }
        layoutKnob()
    }

    private func layoutKnob() {
        let travel = track.height - knobHeight
        // Position 0 is the top of the scrollback; this view's own coordinates are unflipped.
        let y = track.maxY - travel * CGFloat(position) - knobHeight
        let width: CGFloat = 7
        knob.frame = NSRect(x: bounds.maxX - width - 3, y: y, width: width, height: knobHeight)
        knob.layer?.cornerRadius = width / 2
    }

    func flash() {
        guard enabled else { return }
        hideWork?.cancel()
        if isHidden || alphaValue < 1 {
            isHidden = false
            DS.Motion.fade { animator().alphaValue = 1 }
        }
        scheduleHide()
    }

    private func scheduleHide() {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.dragOffset == nil else { return }
            DS.Motion.fade({ self.animator().alphaValue = 0 }, completion: { [weak self] in
                guard let self, self.alphaValue == 0 else { return }
                self.isHidden = true
            })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }

    private func hideNow() {
        hideWork?.cancel()
        alphaValue = 0
        isHidden = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // Grabbing the knob keeps the grip point; clicking the track jumps the knob there.
        dragOffset = knob.frame.contains(point) ? point.y - knob.frame.minY : knobHeight / 2
        hideWork?.cancel()
        drag(to: point)
    }

    override func mouseDragged(with event: NSEvent) { drag(to: convert(event.locationInWindow, from: nil)) }

    override func mouseUp(with event: NSEvent) {
        dragOffset = nil
        scheduleHide()
    }

    private func drag(to point: NSPoint) {
        guard let dragOffset else { return }
        let travel = track.height - knobHeight
        guard travel > 0 else { return }
        let minY = point.y - dragOffset
        let fromTop = track.maxY - minY - knobHeight
        onDrag?(Double(max(0, min(1, fromTop / travel))))
    }
}


/// Follows the escape sequences in a byte stream, so what's between them can be read as text.
struct EscapeSkipper {
    private enum State { case text, escape, csi, string, stringEscape, single }
    private var state = State.text

    /// Whether `byte` belongs to an escape sequence (and so isn't text).
    mutating func consume(_ byte: UInt8) -> Bool {
        switch state {
        case .text:
            guard byte == 0x1B else { return false }
            state = .escape
        case .escape:
            switch byte {
            case UInt8(ascii: "["): state = .csi
            case UInt8(ascii: "P"), UInt8(ascii: "]"), UInt8(ascii: "_"), UInt8(ascii: "^"), UInt8(ascii: "X"): state = .string
            // SS3 (`ESC O C`, an arrow key in application mode) and charset picks take one more byte.
            case UInt8(ascii: "O"), UInt8(ascii: "("), UInt8(ascii: ")"): state = .single
            default: state = .text
            }
        case .csi:
            if (0x40...0x7E).contains(byte) { state = .text }
        case .string:
            if byte == 0x07 { state = .text } else if byte == 0x1B { state = .stringEscape }
        case .stringEscape:
            state = byte == UInt8(ascii: "\\") ? .text : .string
        case .single:
            state = .text
        }
        return true
    }
}

/// A program's light/dark requests in its output, as DEC mode 2031 has them: `CSI ? 2031 h`
/// asks to be told when the terminal goes light or dark, `l` stops, and `CSI ? 996 n` asks now;
/// the answer is `CSI ? 997 ; 1 n` (dark) or `; 2 n` (light). Fed every read; a sequence split
/// across reads is still read whole.
struct ColorSchemeReports {
    enum Event: Equatable { case query }
    private(set) var enabled = false
    private enum State { case ground, escape, csi }
    private var state = State.ground
    private var params: [UInt8] = []

    mutating func consume<Bytes: Sequence>(_ bytes: Bytes) -> [Event] where Bytes.Element == UInt8 {
        var events: [Event] = []
        for byte in bytes {
            switch state {
            case .ground:
                if byte == 0x1B { state = .escape }
            case .escape:
                if byte == 0x5B { state = .csi; params = [] } else if byte != 0x1B { state = .ground }
            case .csi:
                if (0x20...0x3F).contains(byte) {
                    if params.count < 32 { params.append(byte) }
                } else {
                    if (0x40...0x7E).contains(byte) { finish(byte, &events) }
                    state = byte == 0x1B ? .escape : .ground
                }
            }
        }
        return events
    }

    private mutating func finish(_ final: UInt8, _ events: inout [Event]) {
        guard params.first == UInt8(ascii: "?") else { return }
        let modes = String(decoding: params.dropFirst(), as: UTF8.self).split(separator: ";")
        switch final {
        case UInt8(ascii: "h") where modes.contains("2031"): enabled = true
        case UInt8(ascii: "l") where modes.contains("2031"): enabled = false
        case UInt8(ascii: "n") where modes == ["996"]: events.append(.query)
        default: break
        }
    }
}
