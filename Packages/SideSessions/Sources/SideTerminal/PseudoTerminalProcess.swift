import CKeeperSpawn
import Darwin
import Foundation

/// A program in a pseudo-terminal of its own, for terminals that run one in Side's process (a
/// command tab; a shell when session keepers are off): the keeper's own forkpty-and-exec, a
/// reader thread of its own (bridged as Ghostty's is), and a watch for the exit. Replaces SwiftTerm's LocalProcess.
public final class PseudoTerminalProcess: @unchecked Sendable {
    // @unchecked: `master` and `pid` are set once in `start`, before any handler runs; the
    // sources are touched only on `queue`.
    public private(set) var pid: pid_t = 0
    /// The PTY's controlling side, or -1 before start and after it ended.
    public private(set) var master: Int32 = -1

    private let queue = DispatchQueue(label: "side.terminal.pty", qos: .userInteractive)
    private var exitWatch: DispatchSourceProcess?
    /// Signaled by the reader thread once it has delivered everything and stopped.
    private let readerEnded = DispatchSemaphore(value: 0)

    /// The program's output, in batches, on the reader's thread.
    public var onOutput: (@Sendable (ArraySlice<UInt8>) -> Void)?
    /// It exited: the raw status from waitpid, as SwiftTerm's LocalProcess reported it. After the
    /// last of its output.
    public var onExit: (@Sendable (Int32) -> Void)?
    /// Whether output handed over before is still being processed: then the reader may wait a
    /// moment to gather more into one batch (see `Bridge`). Nil: never wait.
    public var isConsumerBusy: (@Sendable () -> Bool)?

    public init() {}

    deinit {
        exitWatch?.cancel()
        // The reader thread ends on its own once the fd is closed (its poll reports it).
        if master >= 0 { close(master) }
    }

    /// False when the program couldn't be started.
    @discardableResult
    public func start(executable: String, arguments: [String], environment: [String], directory: String?, columns: Int, rows: Int) -> Bool {
        let argv = [executable] + arguments
        var fd: Int32 = -1
        let started: pid_t = withCStrings(argv) { argvPointer in
            withCStrings(environment) { envPointer in
                keeper_spawn(executable, argvPointer, envPointer, directory, UInt16(clamping: columns), UInt16(clamping: rows), &fd)
            }
        }
        guard started > 0, fd >= 0 else { return false }
        pid = started
        master = fd
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        startReader(fd)

        let exitWatch = DispatchSource.makeProcessSource(identifier: started, eventMask: .exit, queue: queue)
        exitWatch.setEventHandler { [weak self] in
            guard let self else { return }
            // What it wrote last: the reader sees the PTY close moments after the exit (later, if
            // a background job still holds it open; not waited for past a fifth of a second).
            let drained = self.readerEnded.wait(timeout: .now() + 0.2) == .success
            // Blocking, not WNOHANG: the exit event can arrive a moment before the child is
            // waitable, and WNOHANG then returns nothing, its status lost (an exit 4 read as 0).
            // It has exited, so this returns at once.
            var status: Int32 = 0
            while waitpid(started, &status, 0) == -1, errno == EINTR {}
            self.exitWatch?.cancel()
            self.master = -1
            // A reader still held open by a background job stops at the close.
            close(fd)
            if !drained { _ = self.readerEnded.wait(timeout: .now() + 0.2) }
            self.onExit?(status)
        }
        self.exitWatch = exitWatch
        exitWatch.resume()
        return true
    }

    /// How a flood's refill gaps are bridged, as Ghostty's own reader does (src/termio/Exec.zig,
    /// gatherMainPosix): macOS hands a PTY's output over about a kilobyte at a time, and a reader
    /// that sleeps whenever the queue is momentarily dry wakes once per kilobyte, in lockstep with
    /// the writer. Once a batch holds a full kilobyte, a dry queue is retried at once a few
    /// times, then (while the consumer is still busy) waited on for a millisecond, within a few
    /// milliseconds per batch. Anything smaller (an echo, a prompt) goes at once.
    /// Benchmarks/Terminal/Reader/: 184 MB/s against a blocking reader's 144.
    enum Bridge {
        static let threshold = 1024
        static let spins = 16
        static let pollMilliseconds: Int32 = 1
        static let budgetNanoseconds: UInt64 = 3_000_000
        static let batch = 64 * 1024
    }

    private func startReader(_ fd: Int32) {
        let thread = Thread { [weak self] in
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Bridge.batch)
            defer { buffer.deallocate(); self?.readerEnded.signal() }
            var ended = false
            while !ended {
                var ready = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                if poll(&ready, 1, -1) < 0 { if errno == EINTR { continue }; return }
                // Closed under us (deinit, or the exit with a background job holding the PTY).
                if ready.revents & Int16(POLLNVAL) != 0 { return }
                var filled = 0, spins = 0
                var bridgeStart: UInt64 = 0
                gather: while filled < Bridge.batch {
                    let n = read(fd, buffer + filled, Bridge.batch - filled)
                    if n > 0 { filled += n; spins = 0; continue }
                    // EOF (macOS, once the child is gone), or EIO once nothing holds the PTY.
                    if n == 0 { ended = true; break }
                    switch errno {
                    case EINTR:
                        continue
                    case EAGAIN:
                        guard filled >= Bridge.threshold else { break gather }
                        if spins < Bridge.spins { spins += 1; continue }
                        let now = DispatchTime.now().uptimeNanoseconds
                        if bridgeStart == 0 { bridgeStart = now } else if now - bridgeStart >= Bridge.budgetNanoseconds { break gather }
                        guard self?.isConsumerBusy?() == true else { break gather }
                        var more = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                        guard poll(&more, 1, Bridge.pollMilliseconds) == 1, more.revents & Int16(POLLIN) != 0 else { break gather }
                    default:
                        ended = true
                        break gather
                    }
                }
                if filled > 0, let onOutput = self?.onOutput {
                    onOutput(ArraySlice(UnsafeBufferPointer(start: buffer, count: filled)))
                }
            }
        }
        thread.name = "side.terminal.pty.reader"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Input for the program.
    public func write(_ bytes: ArraySlice<UInt8>) {
        let fd = master
        guard fd >= 0, !bytes.isEmpty else { return }
        let data = Array(bytes)
        queue.async {
            var offset = 0
            while offset < data.count {
                let n = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + offset, data.count - offset) }
                if n > 0 { offset += n } else if errno == EAGAIN || errno == EINTR { usleep(1000) } else { return }
            }
        }
    }

    public func resize(columns: Int, rows: Int) {
        guard master >= 0 else { return }
        var size = winsize(ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: columns), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &size)
    }

    /// SIGTERM to the program, as LocalProcess.terminate did. (Side ends the whole process tree
    /// itself first; see TerminalViewController.terminateProcessTree.)
    public func terminate() {
        if pid > 0 { kill(pid, SIGTERM) }
    }
}

/// NUL-terminated C strings, and a NULL-terminated array of them, for the duration of `body`.
private func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
    var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    pointers.append(nil)
    defer { pointers.forEach { free($0) } }
    return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
}
