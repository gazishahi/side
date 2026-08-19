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
    /// output stream. One at a time per terminal — `run_shell_command` always pauses for
    /// approval or executes synchronously-from-the-caller's-perspective before the next tool
    /// call, so there's never a second command racing the first for this slot.
    private var pendingAgentCommand: (sentinel: String, buffer: String, completion: (String) -> Void)?
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
        let sentinel = "__SIDE_AGENT_DONE_\(UUID().uuidString)__"
        pendingAgentCommand = (sentinel, "", completion)
        let wrapped = "\(command); echo \"\(sentinel):$?\"\r"
        terminalView.send(source: terminalView, data: ArraySlice(Array(wrapped.utf8)))
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.agentCommandTimeout) { [weak self] in
            guard let self, self.pendingAgentCommand?.sentinel == sentinel else { return }
            self.pendingAgentCommand = nil
            completion("Still running — check Run for output.")
        }
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

        var searchStart = pending.buffer.startIndex
        while let sentinelRange = pending.buffer.range(of: pending.sentinel, range: searchStart..<pending.buffer.endIndex) {
            let afterSentinel = pending.buffer[sentinelRange.upperBound...]
            guard afterSentinel.hasPrefix(":") else {
                searchStart = sentinelRange.upperBound
                continue
            }
            guard let newlineIndex = afterSentinel.firstIndex(where: \.isNewline) else {
                // This occurrence's line hasn't finished printing yet — it may still turn out to
                // be the real completion line once more bytes arrive, so wait rather than skip.
                pendingAgentCommand = pending
                return
            }
            let exitCodeText = pending.buffer[afterSentinel.index(after: afterSentinel.startIndex)..<newlineIndex].trimmingCharacters(in: .whitespaces)
            guard let exitCode = Int(exitCodeText) else {
                // Unexpanded "$?" — this is the input echo, not real completion. Keep looking.
                searchStart = newlineIndex
                continue
            }
            var output = String(pending.buffer[pending.buffer.startIndex..<sentinelRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if exitCode != 0 { output += "\n[exit code: \(exitCode)]" }
            pendingAgentCommand = nil
            pending.completion(output)
            return
        }
        pendingAgentCommand = pending
    }

    /// Strips ANSI escape/control sequences from a raw PTY byte stream — best-effort, not a real
    /// terminal parser. The human's own ground truth is the actual, visible terminal; this is
    /// only what gets fed back to the model afterward as a tool result.
    private static func stripANSI(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[a-zA-Z]", with: "", options: .regularExpression)
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
        let descendants = pid != 0 ? Self.descendantPIDs(of: pid) : []
        terminalView.process.terminate()
        for descendantPID in descendants {
            kill(descendantPID, SIGTERM)
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
        onExitStatusChanged?(false, exitCode)
    }
}
