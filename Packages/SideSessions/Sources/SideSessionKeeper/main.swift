import CKeeperSpawn
import Darwin
import Foundation
import GhosttyVt
import SideSessionsKit

// A session keeper (docs/SIDE_RFC_SESSION_RESTORE.md): owns one terminal's PTY and child, and a
// headless libghostty-vt terminal fed every byte the child writes, so a client can detach and
// reattach to the same screen. One thread and one kqueue: the PTY, the listening socket, the
// attached client, the child's exit, and SIGTERM.
//
// Usage: SideSessionKeeper --launch <path to LaunchSpec JSON>   (the file is read and deleted)

setvbuf(stdout, nil, _IOLBF, 0)

let arguments = CommandLine.arguments
guard let flag = arguments.firstIndex(of: "--launch"), arguments.indices.contains(flag + 1) else { fail("usage: SideSessionKeeper --launch <spec.json>") }
let launchURL = URL(fileURLWithPath: arguments[flag + 1])
guard let launched = (try? Data(contentsOf: launchURL)).flatMap({ try? JSONDecoder().decode(LaunchSpec.self, from: $0) }) else { fail("unreadable launch spec at \(launchURL.path)") }
spec = launched
try? FileManager.default.removeItem(at: launchURL)

signal(SIGPIPE, SIG_IGN)
signal(SIGHUP, SIG_IGN)
signal(SIGTERM, SIG_IGN) // delivered through the kqueue instead

socketURL = SessionPaths.socket(spec.id)
recordURL = SessionPaths.record(spec.id)


// MARK: - Listening socket

unlink(socketURL.path)
let listener = socket(AF_UNIX, SOCK_STREAM, 0)
guard listener >= 0 else { fail("socket: \(errno)") }
var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)
let pathBytes = Array(socketURL.path.utf8)
guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else { fail("socket path too long: \(socketURL.path)") }
withUnsafeMutableBytes(of: &address.sun_path) { raw in raw.copyBytes(from: pathBytes); raw[pathBytes.count] = 0 }
address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
guard bound == 0 else { fail("bind \(socketURL.path): \(String(cString: strerror(errno)))") }
chmod(socketURL.path, 0o600)
guard listen(listener, 4) == 0 else { fail("listen: \(errno)") }
setNonBlocking(listener)
_ = fcntl(listener, F_SETFD, FD_CLOEXEC)

// MARK: - The child, on its PTY

childPID = {
    let argv = [spec.executable] + spec.arguments
    var cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
    var cEnv: [UnsafeMutablePointer<CChar>?] = spec.environment.map { strdup($0) } + [nil]
    defer { (cArgs + cEnv).forEach { free($0) } }
    return keeper_spawn(spec.executable, &cArgs, &cEnv, spec.directory, UInt16(spec.cols), UInt16(spec.rows), &master)
}()
guard childPID > 0 else { unlink(socketURL.path); fail("spawn \(spec.executable): \(String(cString: strerror(errno)))") }
// Blocking: the reader thread reads it, and the writer queue writes it.

// MARK: - The terminal

// After a restart: the session's last saved screen and scrollback first, then a line saying so,
// then the new program's output. A snapshot that won't read is a fresh terminal instead.
var made: GhosttyTerminal? = spec.restoreFrom.flatMap(restoredTerminal(from:))
if made != nil {
    ghostty_terminal_resize(made, UInt16(spec.cols), UInt16(spec.rows), 8, 16)
} else {
    guard ghostty_terminal_new(nil, &made, UInt16(spec.cols), UInt16(spec.rows)) == GHOSTTY_SUCCESS, made != nil else { fail("ghostty_terminal_new") }
}
terminal = made!
var scrollbackLines = spec.scrollbackLines
ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &scrollbackLines)
// The C API's 10,000-byte default overrides the line limit (about 390 rows at 200 columns).
ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, nil)
var clustering = GhosttyTerminalModeConfig()
clustering.mode = ghostty_mode_new(2027, false)
clustering.value = true
ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_MODE, &clustering)
if spec.restoreFrom != nil, let banner = spec.banner {
    // Out of a full-screen program's alternate screen, below what was there, dimmed.
    let line = Array("\u{1b}[?1049l\u{1b}[0m\r\n\u{1b}[2m\(banner)\u{1b}[0m\r\n".utf8)
    line.withUnsafeBufferPointer { ghostty_terminal_vt_write(terminal, $0.baseAddress, $0.count) }
}

record = SessionRecord(id: spec.id, keeperPID: getpid(), childPID: childPID, tty: ptsname(master).map { String(cString: $0) } ?? "", executable: spec.executable, arguments: spec.arguments,
                           directory: spec.directory, client: spec.client, createdAt: Date(), lastOutputAt: Date())
writeRecord()

// MARK: - The loop

queue = kqueue()
registerTerminalCallbacks()
watch(Int32(eventIdent), EVFILT_USER, EV_ADD | EV_CLEAR)
watch(Int32(readIdent), EVFILT_USER, EV_ADD | EV_CLEAR)
startParser()


watch(listener, EVFILT_READ, EV_ADD)
watch(childPID, EVFILT_PROC, EV_ADD | EV_ONESHOT, fflags: UInt32(NOTE_EXIT))
watch(SIGTERM, EVFILT_SIGNAL, EV_ADD)
watch(SIGHUP, EVFILT_SIGNAL, EV_ADD)
// Timers 2 (the record's last-output time) and 3 (compression) are armed by output.
startReader()
log("session \(spec.id): \(spec.executable) as \(childPID)")

let readSize = 256 * 1024
let readBuffer = UnsafeMutableRawPointer.allocate(byteCount: readSize, alignment: 16)
var events = Array(repeating: kevent(), count: 16)
while true {
    let count = kevent(queue, nil, 0, &events, Int32(events.count), nil)
    if count < 0 { if errno == EINTR { continue }; fail("kevent: \(errno)") }
    for event in events.prefix(Int(count)) {
        let ident = Int32(event.ident)
        switch Int32(event.filter) {
        case EVFILT_READ where ident == listener:
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { continue }
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { close(fd); continue }
            var noSigPipe: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            enlargeSocketBuffers(fd)
            setNonBlocking(fd)
            // With a client already here, a newcomer waits as a candidate: it's answered, and it
            // takes over only if it attaches. Connecting alone never disturbs the session.
            if client >= 0 {
                if candidate >= 0 { close(candidate) }
                candidate = fd
                candidateDecoder = FrameDecoder()
            } else {
                client = fd
            }
            watch(fd, EVFILT_READ, EV_ADD)
        case EVFILT_READ where ident == candidate:
            let n = read(candidate, readBuffer, 64 * 1024)
            guard n > 0 else {
                if n == 0 || (errno != EAGAIN && errno != EINTR) { close(candidate); candidate = -1 }
                continue
            }
            candidateDecoder.append(UnsafeRawBufferPointer(start: readBuffer, count: n))
            while candidate >= 0, let frame = candidateDecoder.next() {
                switch frame.kind {
                case .hello:
                    let welcome = Frame(.welcome, json: Welcome(protocolVersion: SessionProtocol.version, build: build, record: record)).encoded
                    _ = welcome.withUnsafeBytes { write(candidate, $0.baseAddress!, $0.count) }
                case .attach:
                    // The takeover: the attached client is told, then the candidate becomes it.
                    sendToClient(Frame(.replaced)); flushClient(); dropClient()
                    client = candidate
                    clientDecoder = candidateDecoder
                    candidate = -1
                    handle(frame)
                    while client >= 0, let next = clientDecoder.next() { handle(next) }
                default:
                    break // nothing else counts before an attach
                }
            }
            if candidate >= 0, candidateDecoder.isCorrupt { close(candidate); candidate = -1 }
        case EVFILT_READ where ident == client:
            let n = read(client, readBuffer, 64 * 1024)
            if n > 0 {
                clientDecoder.append(UnsafeRawBufferPointer(start: readBuffer, count: n))
                while client >= 0, let frame = clientDecoder.next() { handle(frame) }
                if clientDecoder.isCorrupt { dropClient() }
            } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
                dropClient()
            }
        case EVFILT_WRITE where ident == client:
            flushClient()
        case EVFILT_PROC:
            childExited()
        case EVFILT_SIGNAL where ident == SIGHUP:
            saveSnapshot(wait: true)
        case EVFILT_SIGNAL:
            // Shutdown or logout: the screen saved for the restart, then go. The child gets its
            // own SIGTERM.
            log("SIGTERM")
            takeReads()
            saveSnapshot(wait: true)
            writeRecord()
            exit(0)
        case EVFILT_USER where event.ident == readIdent:
            takeReads()
        case EVFILT_USER:
            handleEvents()
        case EVFILT_TIMER where event.ident == 1:
            finish()
        case EVFILT_TIMER where event.ident == 3:
            compressIfQuiet()
        case EVFILT_TIMER where event.ident == 4:
            snapshotTimerArmed = false
            saveSnapshot(wait: false)
        case EVFILT_TIMER:
            recordTimerArmed = false
            if recordDirty { writeRecord() }
        default:
            break
        }
    }
}
