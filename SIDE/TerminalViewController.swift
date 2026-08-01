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
        if didStart {
            view.window?.makeFirstResponder(terminalView)
            return
        }
        didStart = true
        isAlive = true
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        terminalView.startProcess(executable: shell, args: ["-l"], currentDirectory: workingDirectory)
        view.window?.makeFirstResponder(terminalView)
    }

    /// Kills the process without tearing down the view — used by "Stop", distinct from
    /// prepareForClose. Restarting reuses a fresh TerminalViewController instance in the same
    /// tab slot rather than trying to restart this one's LocalProcess in place.
    func stopProcess() {
        guard didStart, isAlive else { return }
        terminalView.process.terminate()
    }

    /// SwiftTerm's LocalProcess intentionally doesn't kill the shell from its own deinit
    /// (its deinit only tears down its own I/O resources) — without an explicit terminate,
    /// closing a window whose Run stage was ever activated leaves an orphaned shell process
    /// and drops the process into deinit while its own delegate callbacks may still be
    /// in flight. Call this before the owning window closes.
    func prepareForClose() {
        guard didStart, isAlive else { return }
        terminalView.process.terminate()
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
