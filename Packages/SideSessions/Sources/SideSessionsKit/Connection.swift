import Darwin
import Foundation

public enum SessionError: Error, Equatable, CustomStringConvertible {
    case pathTooLong(String)
    case socket(String, Int32)
    case keeperDidNotStart(String)
    case closed

    public var description: String {
        switch self {
        case .pathTooLong(let path): "Socket path is longer than a Unix socket allows: \(path)"
        case .socket(let call, let code): "\(call) failed: \(String(cString: strerror(code)))"
        case .keeperDidNotStart(let log): "The session keeper didn't start. \(log)"
        case .closed: "The connection is closed."
        }
    }
}

/// A Unix socket's buffers are 8 KB each way by default (`net.local.stream.sendspace`), which
/// made a flood of output a context switch every few kilobytes: a quarter of a bare PTY's
/// throughput lost on the hop alone (2026-11-03). A megabyte each way.
public func enlargeSocketBuffers(_ fd: Int32) {
    var size: Int32 = 1 << 20
    setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
}

/// Fills a `sockaddr_un` for `path`, which must fit in its 104 bytes with the terminator.
func withUnixAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) throws -> T {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard bytes.count < capacity else { throw SessionError.pathTooLong(path) }
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        raw.copyBytes(from: bytes)
        raw[bytes.count] = 0
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    return withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
}

/// One client connection to a keeper. Frames arrive on `queue`; `send` may be called from any
/// thread and writes in order.
public final class SessionConnection: @unchecked Sendable {
    public let fd: Int32
    private let writeQueue = DispatchQueue(label: "side.sessions.write")
    private var source: DispatchSourceRead?
    private let lock = NSLock()
    private var isClosed = false

    private init(fd: Int32) { self.fd = fd }

    public static func connect(to socket: URL) throws -> SessionConnection {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SessionError.socket("socket", errno) }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        enlargeSocketBuffers(fd)
        let result = try withUnixAddress(socket.path) { Darwin.connect(fd, $0, $1) }
        guard result == 0 else {
            let code = errno
            Darwin.close(fd)
            throw SessionError.socket("connect", code)
        }
        return SessionConnection(fd: fd)
    }

    /// Starts reading. `onClose` runs once, after the last frame, when the keeper hangs up.
    public func start(queue: DispatchQueue, onFrame: @escaping @Sendable (Frame) -> Void, onClose: @escaping @Sendable () -> Void) {
        var decoder = FrameDecoder()
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let size = 1 << 20
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let n = read(self.fd, buffer, size)
            if n > 0 {
                decoder.append(UnsafeRawBufferPointer(start: buffer, count: n))
                while let frame = decoder.next() { onFrame(frame) }
                if decoder.isCorrupt { self.close() }
            } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
                self.close()
            }
        }
        source.setCancelHandler {
            buffer.deallocate()
            onClose()
        }
        lock.lock(); self.source = source; lock.unlock()
        source.resume()
    }

    /// Frames sent before `close()` still go out: closed is checked when a frame is queued,
    /// not when it's written.
    public func send(_ frame: Frame) {
        guard !closed else { return }
        let bytes = frame.encoded
        writeQueue.async { [fd] in
            bytes.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if n > 0 { offset += n; continue }
                    if n < 0, errno == EINTR { continue }
                    return
                }
            }
        }
    }

    private var closed: Bool { lock.lock(); defer { lock.unlock() }; return isClosed }

    public func close() {
        lock.lock()
        guard !isClosed else { lock.unlock(); return }
        isClosed = true
        let source = self.source
        lock.unlock()
        // Writes already queued go first; then the descriptor closes and the reader ends.
        writeQueue.async { [fd] in
            if let source { source.cancel() }
            shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
    }
}

/// Starts keepers.
public enum KeeperLauncher {
    /// Starts a keeper for `spec` and returns once its socket accepts connections. The keeper is
    /// in a session of its own (`setsid`), so it outlives whoever started it.
    public static func launch(_ spec: LaunchSpec, keeper: URL, timeout: TimeInterval = 3) throws {
        try SessionPaths.ensureRunDirectory()
        let launchURL = SessionPaths.launch(spec.id)
        try JSONEncoder().encode(spec).write(to: launchURL, options: [.atomic])
        chmod(launchURL.path, 0o600)
        let logURL = SessionPaths.runDirectory.appendingPathComponent("\(spec.id).log")

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, logURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // A session of its own, and nothing of ours inherited but the three it was given.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        disclaimResponsibility(&attributes)

        var environment = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin"]
        if let dir = ProcessInfo.processInfo.environment["SIDE_SESSIONS_DIR"] { environment.append("SIDE_SESSIONS_DIR=\(dir)") }
        let argv = [keeper.lastPathComponent, "--launch", launchURL.path]
        var cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        var cEnv: [UnsafeMutablePointer<CChar>?] = environment.map { strdup($0) } + [nil]
        defer { (cArgs + cEnv).forEach { free($0) } }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, keeper.path, &actions, &attributes, &cArgs, &cEnv)
        guard spawned == 0 else { throw SessionError.socket("posix_spawn", spawned) }
        // Reaped whenever it ends, so it never lingers as a zombie of ours.
        Thread.detachNewThread { var status: Int32 = 0; waitpid(pid, &status, 0) }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let probe = try? SessionConnection.connect(to: SessionPaths.socket(spec.id)) {
                probe.close()
                return
            }
            if kill(pid, 0) != 0 { break }
            usleep(5_000)
        }
        let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        throw SessionError.keeperDidNotStart(log.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The keeper answers for itself to macOS's privacy settings (camera, screen recording,
    /// files…), not Side. It outlives the Side that started it, and a process whose responsible
    /// app has quit was left answering for itself anyway, under a grant Side's never reached:
    /// the same terminal had Side's permissions before a restart and none after (2026-11-07).
    /// Disclaimed from the start, a terminal's permissions are the keeper app's, always.
    ///
    /// `responsibility_spawnattrs_setdisclaim` is in libSystem but not in its headers (Chromium
    /// and Terminal-like apps call it the same way); looked up at run time, and without it the
    /// keeper starts as before.
    static func disclaimResponsibility(_ attributes: inout posix_spawnattr_t?) {
        typealias SetDisclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") else { return }
        _ = unsafeBitCast(symbol, to: SetDisclaim.self)(&attributes, 1)
    }

    /// The process macOS holds responsible for `pid`'s requests (tests).
    public static func responsiblePID(for pid: pid_t) -> pid_t? {
        typealias Responsible = @convention(c) (pid_t) -> pid_t
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: Responsible.self)(pid)
    }
}
