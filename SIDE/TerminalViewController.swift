import AppKit
import Heron
import SwiftTerm

/// Subclasses LocalProcessTerminalView purely to hook three things it exposes specifically for
/// subclass override/interception rather than via its processDelegate: link clicks (so
/// file-path-shaped links can open in Make instead of falling through to NSWorkspace), raw
/// input bytes (to approximate "last submitted command" for rerun, since there's no real shell
/// integration to ask), and raw output bytes (to signal "this session has unseen output" for
/// the background-activity indicator).
final class SideTerminalView: LocalProcessTerminalView {
    var onFileLinkRequested: ((String) -> Bool)?
    var onLineSubmitted: ((String) -> Void)?
    var onDataReceived: (() -> Void)?
    /// Raw output bytes, separate from `onDataReceived` (which only signals *that* output
    /// arrived, for the unseen-output indicator) — `runAgentCommand`'s sentinel scan needs the
    /// actual bytes.
    var onRawDataReceived: ((ArraySlice<UInt8>) -> Void)?
    private var currentLineBuffer = ""
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

    override func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if onFileLinkRequested?(link) == true { return }
        super.requestOpenLink(source: source, link: link, params: params)
    }

    /// Best-effort line capture, not a real line editor: control sequences like arrow-key
    /// history recall aren't parsed, so a command recalled via shell history and re-run won't
    /// be captured here. Plain typed/pasted-then-Return input is.
    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        for byte in data {
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
        super.send(source: source, data: data)
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        onDataReceived?()
        onRawDataReceived?(slice)
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

final class TerminalViewController: NSViewController, @preconcurrency LocalProcessTerminalViewDelegate {
    let terminalView = SideTerminalView(frame: .zero)
    private var didStart = false
    var workingDirectory: String?

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

    /// The first `needle` in `text` at or after `from`, compared as UTF-8 bytes. Foundation's
    /// `range(of:)` compares Characters, and under a flood of output it was a quarter of Run's
    /// CPU even over only the new text. The marks are ASCII, so a byte match is a mark.
    static func utf8Range(of needle: String, in text: String, from: String.Index) -> Range<String.Index>? {
        let bytes = text.utf8, pattern = needle.utf8
        guard let first = pattern.first else { return nil }
        var from = from
        while let hit = bytes[from...].firstIndex(of: first) {
            guard let end = bytes.index(hit, offsetBy: pattern.count, limitedBy: bytes.endIndex) else { return nil }
            if bytes[hit..<end].elementsEqual(pattern) { return hit..<end }
            from = bytes.index(after: hit)
        }
        return nil
    }

    /// Where a search for a mark needs to start after `chunk` was appended: the new text, and
    /// enough before it for a mark split across chunks (a mark with its exit code and nonce is
    /// well under this).
    private static func searchStart(in buffer: String, afterAppending chunk: String) -> String.Index {
        let back = min(buffer.utf8.count, chunk.utf8.count + 160)
        var index = buffer.utf8.index(buffer.utf8.endIndex, offsetBy: -back)
        while index > buffer.startIndex, index.samePosition(in: buffer.unicodeScalars) == nil { index = buffer.utf8.index(before: index) }
        return index
    }
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
    private let markNonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
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
    private var markScanCarry = ""
    var onOutputReceived: (() -> Void)?
    /// Return true if handled (opened in Make); returning false falls through to the default
    /// NSWorkspace.open behavior, which is what makes plain URLs already clickable for free.
    var onFileLinkRequested: ((String) -> Bool)?

    override func loadView() { view = NSView() }

    /// The terminal font and size settings (Appearance). By default the Nerd Font (themed
    /// prompts draw their segments with its glyphs), with the system monospace as the fallback.
    @objc private func applyTextSize() {
        terminalView.font = DS.Text.Fonts.font(.terminal, size: DS.Text.CodeSize.terminal)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
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
        terminalView.processDelegate = self
        // Side genuinely handles OSC 133 (the semantic-prompt marks it asks the shell to emit),
        // but detection scans the raw PTY stream in handleAgentCommandData — SwiftTerm's parser
        // has no handler of its own and logged "Unknown OSC code: 133" for every mark.
        // Registering a no-op tells the parser the code is spoken for.
        terminalView.terminal.registerOscHandler(code: 133) { _ in }
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
        if let launch = commandLaunch {
            // `env` resolves the command on PATH, which comes from the login shell — a GUI
            // app's own PATH has no Homebrew, nvm or the like.
            var environment = Terminal.getEnvironmentVariables(termName: "xterm-256color")
            if let path = LanguageServerRegistry.environmentForSpawning()["PATH"] { environment.append("PATH=\(path)") }
            environment += launch.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            shellIntegration = .unavailable
            terminalView.startProcess(executable: "/usr/bin/env", args: [launch.command] + launch.arguments, environment: environment, currentDirectory: workingDirectory)
            return
        }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        // zsh gets its integration through a ZDOTDIR wrapper (the VS Code technique): the shell
        // sources our rc — which sources the user's own — so the hooks install before the first
        // prompt and *nothing is ever typed into the session*. The old typed-setup path stays
        // for bash, where no equivalent exists without clobbering the user's rc files.
        var environment = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        if shell.contains("zsh"), let wrapper = Self.zshIntegrationDirectory() {
            if let original = ProcessInfo.processInfo.environment["ZDOTDIR"] {
                environment.append("SIDE_ORIG_ZDOTDIR=\(original)")
            }
            environment.append("ZDOTDIR=\(wrapper.path)")
            environment.append("SIDE_MARK_NONCE=\(markNonce)")
            integrationInstalledViaRc = true
        }
        terminalView.startProcess(executable: shell, args: ["-l"], environment: environment, currentDirectory: workingDirectory)
        installShellIntegration(shell: shell)
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
        terminalView.send(source: terminalView, data: ArraySlice([0x0C]))
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
        terminalView.send(source: terminalView, data: ArraySlice(Array((" " + setup + "\r").utf8)))
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
        pendingAgentCommand = (sentinel, "", 0, command, usesMarks, false, completion)
        // With shell integration the command is sent exactly as-is: the shell's own marks report
        // completion, so nothing has to be appended to the user's command line at all.
        // Without it, fall back to a sentinel echo on its own line — on its own line because a
        // command ending in a `#` comment used to swallow an appended echo entirely, so the
        // command ran and nothing ever reported it finished.
        let wrapped = usesMarks ? "\(command)\r" : "\(command)\recho \"\(sentinel):$?\"\r"
        terminalView.send(source: terminalView, data: ArraySlice(Array(wrapped.utf8)))
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
        terminalView.send(source: terminalView, data: ArraySlice([0x03]))
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
        let chunk = String(decoding: slice, as: UTF8.self)
        trackCommandStatus(chunk)
        // The probe: any `D` mark proves the shell is emitting OSC 133, whoever caused it.
        if shellIntegration == .probing, chunk.contains(";" + markNonce + Self.markTerminator) {
            shellIntegration = .confirmed
            tidyAfterSetup()
            drainQueuedAgentCommandsIfIdle()
        }
        guard var pending = pendingAgentCommand else { return }
        if pending.usesMarks {
            // The buffer taken out of both copies of `pending`, so appending to it doesn't copy it.
            var buffer = pending.buffer
            pending.buffer = ""
            pendingAgentCommand?.buffer = ""
            let finished = Self.advanceMarkedCapture(buffer: &buffer, outputStarted: &pending.outputStarted, chunk: chunk, nonce: markNonce)
            pending.buffer = buffer
            guard let finished else {
                pendingAgentCommand = pending
                return
            }
            pendingAgentCommand = pending
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

    static func advanceMarkedCapture(buffer: String, outputStarted: Bool, chunk: String, nonce: String) -> MarkedCaptureStep {
        var buffer = buffer, outputStarted = outputStarted
        let finished = advanceMarkedCapture(buffer: &buffer, outputStarted: &outputStarted, chunk: chunk, nonce: nonce)
        return MarkedCaptureStep(buffer: buffer, outputStarted: outputStarted, finished: finished)
    }

    /// The same, in place; non-nil once finished.
    static func advanceMarkedCapture(buffer: inout String, outputStarted: inout Bool, chunk: String, nonce: String) -> String? {
        boundedAppend(&buffer, chunk)
        var startedNow = false
        // Only the new text is searched (see `searchStart`): searching the whole buffer again
        // for every chunk was most of Run's CPU under a flood of output.
        let fresh = searchStart(in: buffer, afterAppending: chunk)
        if !outputStarted {
            guard let start = utf8Range(of: markPrefix + "C" + markTerminator, in: buffer, from: fresh) else { return nil }
            outputStarted = true
            startedNow = true
            buffer = String(buffer[start.upperBound...])
        }
        // Output is exactly what falls between the shell's own "output starts here" and "command
        // finished" marks, so the prompt is excluded by construction rather than by filtering.
        // A `D` mark is only the shell's if it carries this terminal's nonce; anything else
        // shaped like one is output and the search moves past it.
        // A `C` found just now cut the buffer: search all of what's left; otherwise the new text.
        var searchFrom = startedNow ? buffer.startIndex : fresh
        var doneRange: Range<String.Index>?
        var exitCode = 0
        while let candidate = utf8Range(of: markPrefix + "D;", in: buffer, from: searchFrom) {
            // Still arriving — could be ours; wait for the rest.
            guard let terminator = utf8Range(of: markTerminator, in: buffer, from: candidate.upperBound) else { return nil }
            let payload = buffer[candidate.upperBound..<terminator.lowerBound].split(separator: ";", omittingEmptySubsequences: false)
            if payload.count == 2, payload[1] == nonce, let code = Int(payload[0]) {
                doneRange = candidate
                exitCode = code
                break
            }
            searchFrom = terminator.upperBound
        }
        guard let doneRange else { return nil }
        var output = strippingPromptEOLMark(
            stripANSI(String(buffer[buffer.startIndex..<doneRange.lowerBound]))
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        if output.isEmpty { output = "(no output)" }
        // Always, not only on failure: the agent needs to distinguish "succeeded" from "we could
        // not tell", and a verification record that guesses from output text would produce false
        // verdicts about whether the project works.
        output += "\n[exit code: \(exitCode)]"
        return output
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
        let pid = terminalView.process.shellPid
        guard pid != 0 else {
            terminalView.process.terminate()
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

    @objc private func appearanceChanged() { applyTerminalTheme() }

    /// Foreground, background, and the sixteen ANSI colours, from the design tokens for the
    /// current appearance. SwiftTerm's own defaults are a dim gray on pure black and know nothing
    /// about light mode; this is what makes Run follow the rest of the app.
    private func applyTerminalTheme() {
        let dark = DS.Appearance.isDark
        // The editor theme's terminal colors when it has them (Settings → Appearance).
        let theme = EditorThemes.current(dark: dark)
        let foreground = theme?.terminalText?.nsColor ?? NSColor.labelColor
        let background = theme?.terminalBackground?.nsColor ?? DS.Color.raised
        terminalView.terminal.foregroundColor = Self.terminalColor(foreground)
        terminalView.terminal.backgroundColor = Self.terminalColor(background)
        terminalView.terminal.installPalette(colors: theme?.ansi.map { $0.map { Self.terminalColor($0.nsColor) } } ?? Self.ansiPalette(dark: dark))
        terminalView.nativeForegroundColor = Self.resolved(foreground)
        terminalView.nativeBackgroundColor = Self.resolved(background)
        terminalView.needsDisplay = true
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
    static func ansiPalette(dark: Bool) -> [Color] {
        func c(_ r: Double, _ g: Double, _ b: Double) -> Color {
            Color(red: UInt16(r * 65535), green: UInt16(g * 65535), blue: UInt16(b * 65535))
        }
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

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
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

    private func trackCommandStatus(_ chunk: String) {
        // Only the nonce-carrying marks count where the rc install provides one; the typed bash
        // setup has no nonce, and its marks drive nothing but this display.
        let scan = Self.scanCommandMarks(carry: markScanCarry, chunk: chunk, nonce: integrationInstalledViaRc ? markNonce : nil)
        markScanCarry = scan.carry
        guard !scan.marks.isEmpty else { return }
        var status = commandStatus
        for mark in scan.marks {
            switch mark {
            case .started:
                status.runningSince = Date()
            case .finished(let code):
                // The startup mark has no command before it; nothing ran, nothing to report.
                guard let start = status.runningSince else { continue }
                status.lastExitCode = code
                status.lastDuration = Date().timeIntervalSince(start)
                status.runningSince = nil
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
        let text = carry + chunk
        var marks: [CommandMark] = []
        var searchFrom = text.startIndex
        while let prefix = utf8Range(of: markPrefix, in: text, from: searchFrom) {
            guard let terminator = utf8Range(of: markTerminator, in: text, from: prefix.upperBound) else {
                // Still arriving: keep it (bounded) for the next read.
                return (String(text[prefix.lowerBound...].suffix(256)), marks)
            }
            let body = text[prefix.upperBound..<terminator.lowerBound]
            if body == "C" {
                marks.append(.started)
            } else if body.hasPrefix("D;") {
                let payload = body.dropFirst(2).split(separator: ";", omittingEmptySubsequences: false)
                let nonceMatches = nonce.map { payload.count == 2 && payload[1] == $0 } ?? (payload.count <= 2)
                if nonceMatches, let first = payload.first, let code = Int(first) { marks.append(.finished(exitCode: code)) }
            }
            searchFrom = terminator.upperBound
        }
        // A tail shorter than the prefix can't hold a whole mark, so nothing is seen twice.
        return (String(text[searchFrom...].suffix(markPrefix.count - 1)), marks)
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
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
            NSAnimationContext.runAnimationGroup { context in
                context.duration = DS.Motion.duration(0.1)
                animator().alphaValue = 1
            }
        }
        scheduleHide()
    }

    private func scheduleHide() {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.dragOffset == nil else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = DS.Motion.duration(0.3)
                self.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                guard let self, self.alphaValue == 0 else { return }
                self.isHidden = true
            }
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

