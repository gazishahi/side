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
setNonBlocking(master)

// MARK: - The terminal

var made: GhosttyTerminal?
guard ghostty_terminal_new(nil, &made, UInt16(spec.cols), UInt16(spec.rows)) == GHOSTTY_SUCCESS, let made else { fail("ghostty_terminal_new") }
terminal = made
var scrollbackLines = spec.scrollbackLines
ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &scrollbackLines)
// The C API's 10,000-byte default overrides the line limit (about 390 rows at 200 columns).
ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, nil)
var clustering = GhosttyTerminalModeConfig()
clustering.mode = ghostty_mode_new(2027, false)
clustering.value = true
ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_MODE, &clustering)

record = SessionRecord(id: spec.id, keeperPID: getpid(), childPID: childPID, executable: spec.executable, arguments: spec.arguments,
                           directory: spec.directory, client: spec.client, createdAt: Date(), lastOutputAt: Date())
writeRecord()

// MARK: - The loop

queue = kqueue()
registerTerminalCallbacks()


watch(master, EVFILT_READ, EV_ADD)
watch(listener, EVFILT_READ, EV_ADD)
watch(childPID, EVFILT_PROC, EV_ADD | EV_ONESHOT, fflags: UInt32(NOTE_EXIT))
watch(SIGTERM, EVFILT_SIGNAL, EV_ADD)
// The record's last-output time, written at most every two seconds.
watch(2, EVFILT_TIMER, EV_ADD, fflags: UInt32(NOTE_SECONDS), data: 2)
log("session \(spec.id): \(spec.executable) as \(childPID)")

let readBuffer = UnsafeMutableRawPointer.allocate(byteCount: 64 * 1024, alignment: 16)
var events = Array(repeating: kevent(), count: 16)
while true {
    let count = kevent(queue, nil, 0, &events, Int32(events.count), nil)
    if count < 0 { if errno == EINTR { continue }; fail("kevent: \(errno)") }
    for event in events.prefix(Int(count)) {
        let ident = Int32(event.ident)
        switch Int32(event.filter) {
        case EVFILT_READ where ident == master:
            let n = read(master, readBuffer, 64 * 1024)
            if n > 0 { consume(UnsafeRawBufferPointer(start: readBuffer, count: n)) }
            // EOF or EIO once the child and everything holding the PTY are gone: the exit event
            // follows (or already came), so stop watching an empty descriptor.
            else if n == 0 || (errno != EAGAIN && errno != EINTR) { watch(master, EVFILT_READ, EV_DELETE) }
        case EVFILT_READ where ident == listener:
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { continue }
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { close(fd); continue }
            if client >= 0 { sendToClient(Frame(.replaced)); flushClient(); dropClient() }
            var noSigPipe: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            setNonBlocking(fd)
            client = fd
            watch(fd, EVFILT_READ, EV_ADD)
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
        case EVFILT_WRITE where ident == master:
            flushPTY()
        case EVFILT_PROC:
            childExited()
        case EVFILT_SIGNAL:
            // Shutdown or logout: the child gets its own SIGTERM; save nothing yet (phase 2
            // writes the snapshot here) and go.
            log("SIGTERM")
            if recordDirty { writeRecord() }
            exit(0)
        case EVFILT_TIMER where event.ident == 1:
            finish()
        case EVFILT_TIMER:
            if recordDirty { writeRecord() }
        default:
            break
        }
    }
}
