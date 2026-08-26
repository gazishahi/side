import AppKit
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
        super.dataReceived(slice: slice)
    }
}

final class TerminalViewController: NSViewController, @preconcurrency LocalProcessTerminalViewDelegate {
    let terminalView = SideTerminalView(frame: .zero)
    private var didStart = false
    var workingDirectory: String?

    private(set) var isAlive = false
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
    private var pendingAgentCommand: (sentinel: String, buffer: String, command: String, completion: (String) -> Void)?
    /// Commands waiting for the terminal to free up, in the order they were requested.
    private var queuedAgentCommands: [(command: String, completion: (String) -> Void)] = []
    /// Guards against a stale timeout resolving a *later* command that happens to occupy the slot.
    private var pendingAgentCommandGeneration = 0
    private static let agentCommandTimeout: TimeInterval = 30

    /// (isAlive, exitCode) — exitCode is nil if the process never actually started or died
    /// from an I/O error rather than a normal exit.
    var onExitStatusChanged: ((Bool, Int32?) -> Void)?
    var onDirectoryChanged: ((String?) -> Void)?
    var onOutputReceived: (() -> Void)?
    /// Return true if handled (opened in Make); returning false falls through to the default
    /// NSWorkspace.open behavior, which is what makes plain URLs already clickable for free.
    var onFileLinkRequested: ((String) -> Bool)?

    override func loadView() { view = NSView() }

    override func viewDidLoad() {
        super.viewDidLoad()
        if let nerdFont = NSFont(name: "MesloLGS-NF-Regular", size: 14) {
            terminalView.font = nerdFont
        }
        // SwiftTerm's own defaults are a ~54%-gray foreground on a pure black background —
        // legible but noticeably dim next to the editor. Terminal background is deliberately
        // darker than the editor's own (near-black rather than matching exactly) — a common
        // convention (Terminal.app, iTerm2 defaults) that also helps a glance tell Make and
        // Run apart.
        terminalView.terminal.foregroundColor = Color(red: 55704, green: 55704, blue: 55704)
        terminalView.terminal.backgroundColor = Color(red: 1310, green: 1310, blue: 1310)
        terminalView.processDelegate = self
        terminalView.onFileLinkRequested = { [weak self] link in self?.onFileLinkRequested?(link) ?? false }
        terminalView.onLineSubmitted = { [weak self] line in self?.lastSubmittedCommand = line }
        terminalView.onDataReceived = { [weak self] in self?.onOutputReceived?() }
        terminalView.onRawDataReceived = { [weak self] slice in self?.handleAgentCommandData(slice) }
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
    private func ensureStarted() {
        guard !didStart else { return }
        didStart = true
        isAlive = true
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        terminalView.startProcess(executable: shell, args: ["-l"], currentDirectory: workingDirectory)
    }

    /// Types `command` into this session the same way keystrokes go in — the human sees the
    /// exact same prompt/output they'd see typing it themselves, per "no accidental
    /// surveillance." Wraps it with a sentinel + exit-code echo and resolves `completion` once
    /// that sentinel shows up in the raw output stream, or after `agentCommandTimeout` with a
    /// "still running" hint — a long-running or interactive command keeps running in the real,
    /// visible terminal; this just stops blocking the conversation on it.
    func runAgentCommand(_ command: String, completion: @escaping (String) -> Void) {
        ensureStarted()
        // Some commands can't be wrapped in a way that reliably reports completion. Saying so is
        // far better than sending them and hanging until the timeout with a misleading answer.
        if let reason = Self.unwrappableReason(for: command) {
            completion(reason)
            return
        }
        guard pendingAgentCommand == nil else {
            queuedAgentCommands.append((command, completion))
            return
        }
        startAgentCommand(command, completion: completion)
    }

    private func startAgentCommand(_ command: String, completion: @escaping (String) -> Void) {
        let sentinel = "__SIDE_AGENT_DONE_\(UUID().uuidString)__"
        pendingAgentCommandGeneration += 1
        let generation = pendingAgentCommandGeneration
        pendingAgentCommand = (sentinel, "", command, completion)
        // The sentinel goes on its *own* line rather than being appended after `;` — a command
        // ending in a `#` comment used to swallow the appended echo entirely, so the command ran
        // and then nothing ever reported it finished.
        let wrapped = "\(command)\recho \"\(sentinel):$?\"\r"
        terminalView.send(source: terminalView, data: ArraySlice(Array(wrapped.utf8)))
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.agentCommandTimeout) { [weak self] in
            guard let self, self.pendingAgentCommandGeneration == generation,
                  self.pendingAgentCommand?.sentinel == sentinel else { return }
            // Deliberately *not* interrupted: a slow build or test run is legitimate, and it
            // keeps running in the real terminal where the user can watch it. The message says
            // exactly that instead of the old "Still running — check Run for output," which
            // implied output was available and said nothing about the command's fate.
            self.finishPendingAgentCommand(
                "No result after \(Int(Self.agentCommandTimeout))s. The command was NOT interrupted — it is still running in this track's terminal, where its output is visible. Do not assume it succeeded or failed; ask the user what it did, or run something that inspects the result."
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
        startAgentCommand(next.command, completion: next.completion)
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
        let queuedCount = queuedAgentCommands.count
        queuedAgentCommands.removeAll()
        // 0x03 = ETX, what Ctrl-C sends; the pty turns it into SIGINT for the foreground group.
        terminalView.send(source: terminalView, data: ArraySlice([0x03]))
        var message = "Interrupted by the user (Ctrl-C) before it reported a result. Whether it partially completed is unknown — check before assuming."
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
        guard var pending = pendingAgentCommand else { return }
        // Stripped per-chunk, before accumulating — a shell that re-colors the line live as it
        // "types" (zsh-syntax-highlighting and similar) interleaves ANSI codes into the raw byte
        // stream mid-token, which can split the sentinel across escape sequences and make a
        // whole-buffer substring search miss it even though the rendered terminal shows the
        // sentinel as one clean, contiguous line.
        pending.buffer += Self.stripANSI(String(decoding: slice, as: UTF8.self))

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
        var searchStart = pending.buffer.startIndex
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
            if exitCode != 0 { output += "\n[exit code: \(exitCode)]" }
            pendingAgentCommand = pending
            finishPendingAgentCommand(output)
            return
        }
        pendingAgentCommand = pending
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
    private static func stripANSI(_ raw: String) -> String {
        // CSI (colors, cursor moves, bracketed-paste toggles like `\u{1B}[?2004l`), then OSC
        // (`\u{1B}]0;title\u{07}` — zsh sets the window title on every prompt, which is what
        // used to glue the echoed command and its real output into one unbroken run), then
        // two-character escapes (`\u{1B}>`), then stray BELs.
        var result = raw.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "\u{1B}[@-Z\\\\-_]", with: "", options: .regularExpression)
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

    private static func descendantPIDs(of rootPID: pid_t) -> [pid_t] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-eo", "pid,ppid"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return []
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
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
        currentDirectory = directory
        onDirectoryChanged?(directory)
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        isAlive = false
        // A command like `exit` kills the shell, so the sentinel can never print. Without this
        // the call sat until the timeout and then claimed it was "still running" — of a shell
        // that no longer existed.
        if pendingAgentCommand != nil {
            let queuedCount = queuedAgentCommands.count
            queuedAgentCommands.removeAll()
            var message = "The shell exited before reporting a result, so this command's outcome is unknown (a command that ends the shell — `exit`, `logout` — can't report back)."
            if queuedCount > 0 {
                message += " \(queuedCount) queued command\(queuedCount == 1 ? "" : "s") did not run."
            }
            finishPendingAgentCommand(message)
        }
        onExitStatusChanged?(false, exitCode)
    }
}
