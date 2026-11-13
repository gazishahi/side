import CKeeperSpawn
import Darwin
import Foundation

/// A program in a pseudo-terminal of its own, for terminals that run one in Side's process (a
/// command tab; a shell when session keepers are off): the keeper's own forkpty-and-exec, a
/// read loop on a queue of its own, and a watch for the exit. Replaces SwiftTerm's LocalProcess.
public final class PseudoTerminalProcess: @unchecked Sendable {
    // @unchecked: `master` and `pid` are set once in `start`, before any handler runs; the
    // sources are touched only on `queue`.
    public private(set) var pid: pid_t = 0
    /// The PTY's controlling side, or -1 before start and after it ended.
    public private(set) var master: Int32 = -1

    private let queue = DispatchQueue(label: "side.terminal.pty", qos: .userInteractive)
    private var reader: DispatchSourceRead?
    private var exitWatch: DispatchSourceProcess?
    private var buffer = [UInt8](repeating: 0, count: 128 * 1024)

    /// The program's output, on the PTY's queue.
    public var onOutput: (@Sendable (ArraySlice<UInt8>) -> Void)?
    /// It exited: the raw status from waitpid, as SwiftTerm's LocalProcess reported it.
    public var onExit: (@Sendable (Int32) -> Void)?

    public init() {}

    deinit {
        reader?.cancel()
        exitWatch?.cancel()
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

        let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        reader.setEventHandler { [weak self] in self?.drain() }
        reader.setCancelHandler { close(fd) }
        self.reader = reader
        reader.resume()

        let exitWatch = DispatchSource.makeProcessSource(identifier: started, eventMask: .exit, queue: queue)
        exitWatch.setEventHandler { [weak self] in
            guard let self else { return }
            self.drain() // what it wrote last
            // Blocking, not WNOHANG: the exit event can arrive a moment before the child is
            // waitable, and WNOHANG then returns nothing, its status lost (an exit 4 read as 0).
            // It has exited, so this returns at once.
            var status: Int32 = 0
            while waitpid(started, &status, 0) == -1, errno == EINTR {}
            self.exitWatch?.cancel()
            self.reader?.cancel()
            self.master = -1
            self.onExit?(status)
        }
        self.exitWatch = exitWatch
        exitWatch.resume()
        return true
    }

    private func drain() {
        guard master >= 0 else { return }
        while true {
            let n = buffer.withUnsafeMutableBytes { read(master, $0.baseAddress, $0.count) }
            guard n > 0 else { return }
            onOutput?(buffer[0..<n])
        }
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
