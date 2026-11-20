import CKeeperSpawn
import Darwin
import Foundation
import GhosttyVt
import SideSessionsKit
import Synchronization

// The keeper's state and handlers, as true globals: libghostty-vt's callbacks are C function
// pointers, which can't capture context, and top-level variables in main.swift count as captured.

var spec: LaunchSpec!
var socketURL: URL!
var recordURL: URL!
let build = "\(SessionProtocol.version)"
var master: Int32 = -1
var childPID: pid_t = 0
var terminal: GhosttyTerminal!
var record: SessionRecord!
var recordDirty = true
var queue: Int32 = -1

/// A line on stderr (the session's log file), dropped if it can't be written. `FileHandle.write`
/// raises an Objective-C exception on a failed write, and on a full disk the keeper logged that
/// its record couldn't be saved, and aborted on the log line: its terminal stopped taking input
/// (the owner, 2026-11-04, Claude Code sessions frozen while the Mac was out of storage).
func log(_ message: String) {
    let line = Array("[keeper \(getpid())] \(message)\n".utf8)
    _ = line.withUnsafeBytes { write(STDERR_FILENO, $0.baseAddress, $0.count) }
}
func fail(_ message: String) -> Never { log(message); exit(1) }
func setNonBlocking(_ fd: Int32) { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }

func writeRecord() {
    recordDirty = false
    record.foreground = foregroundArguments()
    do { try record.write(to: recordURL) } catch { log("record: \(error)") }
}

// MARK: - The client


/// Bytes for the client, written as it can take them.
var client: Int32 = -1
var attached = false
var clientDecoder = FrameDecoder()
/// A second connection while a client is attached (`main.swift`).
var candidate: Int32 = -1
var candidateDecoder = FrameDecoder()
var toClient: [UInt8] = []
var toClientOffset = 0
/// A client that stops reading is let go past this; the terminal keeps the state regardless,
/// and a reattach gets it whole from the snapshot.
let clientBacklogLimit = 32 << 20

func watch(_ ident: Int32, _ filter: Int32, _ flags: Int32, fflags: UInt32 = 0, data: Int = 0) {
    var event = kevent(ident: UInt(ident), filter: Int16(filter), flags: UInt16(flags), fflags: fflags, data: data, udata: nil)
    _ = kevent(queue, &event, 1, nil, 0, nil)
}

func sendToClient(_ frame: Frame) {
    guard client >= 0 else { return }
    frame.payload.withUnsafeBytes { sendToClient(frame.kind, $0) }
}

/// A frame straight into the client's buffer: header and payload, no intermediate copies.
func sendToClient(_ kind: FrameKind, _ payload: UnsafeRawBufferPointer) {
    guard client >= 0 else { return }
    let wasEmpty = toClientOffset == toClient.count
    toClient.append(kind.rawValue)
    withUnsafeBytes(of: UInt32(payload.count).littleEndian) { toClient.append(contentsOf: $0) }
    toClient.append(contentsOf: payload)
    if toClient.count - toClientOffset > clientBacklogLimit { dropClient(why: "it stopped reading"); return }
    if wasEmpty { flushClient() }
}

func flushClient() {
    guard client >= 0 else { return }
    while toClientOffset < toClient.count {
        let n = toClient.withUnsafeBytes { write(client, $0.baseAddress! + toClientOffset, toClient.count - toClientOffset) }
        if n > 0 { toClientOffset += n; continue }
        if n < 0, errno == EINTR { continue }
        if n < 0, errno == EAGAIN { watch(client, EVFILT_WRITE, EV_ADD | EV_ENABLE | EV_ONESHOT); return }
        dropClient(why: n < 0 ? "write: \(String(cString: strerror(errno)))" : "write: nothing written")
        return
    }
    // Capacity kept for steady output, not a flood's peak.
    toClient.removeAll(keepingCapacity: toClient.capacity <= 1 << 20)
    toClientOffset = 0
    // Gone only once the client has been told how the session ended.
    if exitReported { finish() }
}

/// `why`: logged, so a terminal that lost its connection leaves a reason in the session's log
/// (two did, 2026-11-05, and nothing said why).
func dropClient(why: String? = nil) {
    guard client >= 0 else { return }
    if let why { log("client let go: \(why)") }
    exitReported = false
    close(client) // closing removes its kqueue filters
    client = -1
    attached = false
    readerBridges.store(false, ordering: .relaxed)
    clientWantsEvents = false
    clientDecoder = FrameDecoder()
    toClient.removeAll()
    toClientOffset = 0
}

/// Input for the program, written on a queue of its own: a program that stops reading its input
/// blocks that queue, never the keeper's loop.
let ptyWriter = DispatchQueue(label: "keeper.pty-writer")
func writeToPTY(_ bytes: [UInt8]) {
    ptyWriter.async {
        bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(master, raw.baseAddress! + offset, raw.count - offset)
                if n > 0 { offset += n; continue }
                if n < 0, errno == EINTR { continue }
                // The master is non-blocking (for the reader): a full input queue (a big paste
                // into a program that isn't reading) waits for room, as a blocking write did.
                if n < 0, errno == EAGAIN {
                    var room = pollfd(fd: master, events: Int16(POLLOUT), revents: 0)
                    if poll(&room, 1, -1) >= 0 || errno == EINTR { continue }
                }
                return
            }
        }
    }
}

// MARK: - The reader thread

/// The PTY is read on a thread of its own, as a terminal reading its own PTY does (non-blocking
/// reads gathered into batches, bridged under a flood; see `Bridge`): waiting on the kqueue between reads, the keeper spent most of a flood idle, and reached
/// three quarters of a bare PTY's throughput (2026-11-03). The main loop takes what was read, in
/// order, and does the rest (forwarding, the parse queue), so a snapshot stays in step with what
/// a client was sent.
/// A batch of output in one of the pool's buffers: read into it, forwarded from it, parsed from
/// it, then handed back. One buffer, no copies on the way.
struct Chunk {
    let base: UnsafeMutableRawPointer
    let count: Int
    var bytes: UnsafeRawBufferPointer { UnsafeRawBufferPointer(start: base, count: count) }
}

/// Read buffers, reused: a fresh array per batch left megabytes of freed malloc memory dirty
/// after a flood (2026-11-03). Mapped directly, so `trim` gives spare ones back to the system.
enum ChunkPool {
    static let size = 256 * 1024
    /// Up to 16 MB in flight; past that the reader waits, so the PTY pushes back on the program
    /// rather than the keeper growing (the parser is far faster than any program writes).
    static let limit = 64
    private static let condition = NSCondition()
    private static var spare: [UnsafeMutableRawPointer] = []
    private static var count = 0

    static func take() -> UnsafeMutableRawPointer {
        condition.lock()
        defer { condition.unlock() }
        while spare.isEmpty && count >= limit { condition.wait() }
        if let buffer = spare.popLast() { return buffer }
        count += 1
        return mmap(nil, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0)
    }

    static func give(_ buffer: UnsafeMutableRawPointer) {
        condition.lock()
        spare.append(buffer)
        condition.signal()
        condition.unlock()
    }

    /// Spare buffers back to the system, for a session that's gone quiet.
    static func trim() {
        condition.lock()
        for buffer in spare { munmap(buffer, size) }
        count -= spare.count
        spare.removeAll()
        condition.unlock()
    }
}

let readLock = NSLock()
var readChunks: [Chunk] = []
var readEnded = false
let readIdent: UInt = 11

/// Set while a client is attached: only then does the reader bridge a flood's refill gaps (below).
/// Detached, nobody is watching the output stream by, so it isn't worth the extra CPU.
let readerBridges = Atomic<Bool>(false)

/// How the reader bridges a flood's refill gaps, as Ghostty's own reader does (src/termio/Exec.zig,
/// gatherMainPosix): macOS hands a PTY's output over about a kilobyte at a time, and a reader that
/// sleeps whenever the queue is momentarily dry wakes once per kilobyte, in lockstep with the
/// writer. Once a batch holds a full kilobyte (a writer filling the queue as fast as it can), a dry
/// queue is retried at once a few times, then waited on for a millisecond, within a few
/// milliseconds per batch. Anything smaller (an echo, a prompt) is handed over at once.
/// Benchmarks/Terminal/Reader/: a blocking reader topped out near 125 MB/s, this one near 160.
enum Bridge {
    static let threshold = 1024
    static let spins = 16
    static let pollMilliseconds: Int32 = 1
    static let budgetNanoseconds: UInt64 = 3_000_000
}

/// Whether what was read before is still waiting to be taken or parsed: then waiting a moment for
/// more costs nothing. Once everything is parsed, holding a batch only delays it; a program that
/// ends its output with a query (a cursor position report) would wait out every bridge.
func parserBusy() -> Bool {
    readLock.lock()
    let waiting = !readChunks.isEmpty
    readLock.unlock()
    if waiting { return true }
    parseCondition.lock()
    defer { parseCondition.unlock() }
    return !parseQueue.isEmpty || parsing
}

func startReader() {
    let thread = Thread {
        let size = ChunkPool.size
        var nonblocking = false
        while true {
            // Bridging needs non-blocking reads; without it (detached) the reader blocks in read(),
            // which wakes less often than a poll for readiness: the old loop cost 0.37 s of the
            // keeper's CPU for a 50 MB flood, a poll-and-drain one 0.63 s.
            let bridging = readerBridges.load(ordering: .relaxed)
            if bridging != nonblocking {
                let flags = fcntl(master, F_GETFL)
                _ = fcntl(master, F_SETFL, bridging ? flags | O_NONBLOCK : flags & ~O_NONBLOCK)
                nonblocking = bridging
            }
            if bridging {
                var ready = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
                if poll(&ready, 1, -1) < 0, errno == EINTR { continue }
            }
            let buffer = ChunkPool.take()
            // A PTY hands output over a few kilobytes at a time. Reads are gathered while more is
            // readable, and handed over once it isn't (bridged, under a flood): under a flood, a
            // handoff per read (a copy, a lock and a wakeup) held the keeper to 58% of a plain
            // reader's speed, while a single keystroke's echo still goes the moment it's read.
            // Not FIONREAD: on a PTY master it also counts input the program hasn't read, so after
            // Return in a program that doesn't read, the echo was held back indefinitely.
            var filled = 0
            var ended = false
            var spins = 0
            var bridgeStart: UInt64 = 0
            gather: while filled < size {
                let n = read(master, buffer + filled, size - filled)
                if n > 0 {
                    filled += n
                    spins = 0
                    if nonblocking { continue }
                    // Blocking: gather only while more is already readable.
                    var readable = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
                    guard poll(&readable, 1, 0) == 1, readable.revents & Int16(POLLIN) != 0 else { break gather }
                    continue
                }
                // EOF (macOS, once the child is gone), or EIO once everything holding the PTY is.
                if n == 0 { ended = true; break }
                switch errno {
                case EINTR:
                    continue
                case EAGAIN:
                    guard filled >= Bridge.threshold else { break gather }
                    if spins < Bridge.spins { spins += 1; continue }
                    let now = DispatchTime.now().uptimeNanoseconds
                    if bridgeStart == 0 { bridgeStart = now } else if now - bridgeStart >= Bridge.budgetNanoseconds { break gather }
                    guard parserBusy() else { break gather }
                    var more = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
                    guard poll(&more, 1, Bridge.pollMilliseconds) == 1, more.revents & Int16(POLLIN) != 0 else { break gather }
                default:
                    ended = true
                    break gather
                }
            }
            readLock.lock()
            let wasEmpty = readChunks.isEmpty
            if filled > 0 { readChunks.append(Chunk(base: buffer, count: filled)) } else { ChunkPool.give(buffer) }
            if ended { readEnded = true }
            readLock.unlock()
            // One wakeup per batch: while the loop is busy, batches pile up and go together.
            if wasEmpty || ended { trigger(readIdent) }
            if ended { return }
        }
    }
    thread.qualityOfService = .userInteractive
    thread.start()
}

func trigger(_ ident: UInt) {
    var event = kevent(ident: ident, filter: Int16(EVFILT_USER), flags: 0, fflags: UInt32(NOTE_TRIGGER), data: 0, udata: nil)
    _ = kevent(queue, &event, 1, nil, 0, nil)
}

/// What the reader has read since last time, forwarded and queued for parsing in order.
func takeReads() {
    readLock.lock()
    let chunks = readChunks
    readChunks.removeAll(keepingCapacity: true)
    readLock.unlock()
    for chunk in chunks { consume(chunk) }
}

// MARK: - Terminal callbacks

func currentTitle() -> String {
    var value = GhosttyString()
    guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_TITLE, &value) == GHOSTTY_SUCCESS, let ptr = value.ptr, value.len > 0 else { return "" }
    return String(decoding: UnsafeBufferPointer(start: ptr, count: value.len), as: UTF8.self)
}

// The callbacks run on the parse thread, inside a write: they read what they need from the
// terminal there and hand the rest to the main loop.
let titleChanged: GhosttyTerminalTitleChangedFn = { _, _ in post(.title(currentTitle())) }

let bell: GhosttyTerminalBellFn = { _, _ in post(.bell) }

// OSC 9 and OSC 777: a program's own desktop notification.
let desktopNotification: GhosttyTerminalDesktopNotificationFn = { _, _, request in
    guard let request else { return }
    func text(_ value: GhosttyString) -> String {
        guard let ptr = value.ptr, value.len > 0 else { return "" }
        return String(decoding: UnsafeBufferPointer(start: ptr, count: value.len), as: UTF8.self)
    }
    post(.notification(title: text(request.pointee.title), body: text(request.pointee.body)))
}

let pwdChanged: GhosttyTerminalPwdChangedFn = { _, _ in
    var value = GhosttyString()
    guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_PWD, &value) == GHOSTTY_SUCCESS, let ptr = value.ptr, value.len > 0 else { return }
    post(.pwd(String(decoding: UnsafeBufferPointer(start: ptr, count: value.len), as: UTF8.self)))
}

// OSC 7501: what the program says it's doing. libghostty-vt has parsed and checked the report;
// the keeper keeps the records (the terminal doesn't), by the spec's rules.
let programStatus: GhosttyTerminalProgramStatusFn = { _, _, report in
    guard let report else { return }
    func text(_ value: GhosttyString) -> String {
        guard let ptr = value.ptr, value.len > 0 else { return "" }
        return String(decoding: UnsafeBufferPointer(start: ptr, count: value.len), as: UTF8.self)
    }
    let id = text(report.pointee.id)
    let state: ProgramStatusRecord.State
    switch report.pointee.state {
    case GHOSTTY_PROGRAM_STATUS_STATE_CLEAR: post(.statusClear(id)); return
    case GHOSTTY_PROGRAM_STATUS_STATE_IDLE: state = .idle
    case GHOSTTY_PROGRAM_STATUS_STATE_WORKING: state = .working
    case GHOSTTY_PROGRAM_STATUS_STATE_DONE: state = .done
    case GHOSTTY_PROGRAM_STATUS_STATE_BLOCKED: state = .blocked
    case GHOSTTY_PROGRAM_STATUS_STATE_ERROR: state = .error
    default: return
    }
    let kind: ProgramStatusRecord.Kind?
    switch report.pointee.kind {
    case GHOSTTY_PROGRAM_STATUS_KIND_PERMISSION: kind = .permission
    case GHOSTTY_PROGRAM_STATUS_KIND_QUESTION: kind = .question
    case GHOSTTY_PROGRAM_STATUS_KIND_AUTH: kind = .auth
    default: kind = nil
    }
    let progress = report.pointee.progress
    post(.status(ProgramStatusRecord(id: id, state: state, kind: kind, progress: progress >= 0 ? Int(progress) : nil,
                                     app: text(report.pointee.app), title: text(report.pointee.title), message: text(report.pointee.message))))
}

// OSC 133: a new primary prompt means the program before it is over (the spec drops its working
// and blocked records then).
let semanticPrompt: GhosttyTerminalSemanticPromptFn = { _, _, event in
    guard let event, event.pointee.kind == GHOSTTY_SEMANTIC_PROMPT_PROMPT_START,
          event.pointee.prompt_kind == GHOSTTY_SEMANTIC_PROMPT_PROMPT_PRIMARY else { return }
    post(.promptStart)
}

// Replies to the program's queries (cursor position, device attributes); `handleEvents` decides.
let writePTY: GhosttyTerminalWritePtyFn = { _, _, data, len in
    guard let data, len > 0 else { return }
    post(.reply(Array(UnsafeBufferPointer(start: data, count: len))))
}

// MARK: - The parse thread

/// The keeper's copy of the screen is kept on a thread of its own, behind the client: output is
/// forwarded as soon as it's read, and parsed meanwhile. One thread did both, and parsing was a
/// third of the keeper's time under a flood (2026-11-03, 74% of a bare PTY's throughput).
/// Whatever reads or changes the terminal from the main loop goes through `withTerminal`, which
/// waits for the parser to catch up first, so a snapshot matches exactly what was forwarded.
let parseCondition = NSCondition()
var parseQueue: [Chunk] = []
var parsing = false
/// True while the parse thread waits for work: only then does queuing work need to wake it.
var parserWaiting = false
let terminalLock = NSLock()

func startParser() {
    let thread = Thread {
        while true {
            parseCondition.lock()
            while parseQueue.isEmpty && !snapshotRequested { parserWaiting = true; parseCondition.wait(); parserWaiting = false }
            let batch = parseQueue
            parseQueue.removeAll(keepingCapacity: true)
            parsing = true
            parseCondition.unlock()
            terminalLock.lock()
            for chunk in batch { ghostty_terminal_vt_write(terminal, chunk.base.assumingMemoryBound(to: UInt8.self), chunk.count) }
            terminalLock.unlock()
            for chunk in batch { ChunkPool.give(chunk.base) }
            parseCondition.lock()
            let wantsSnapshot = snapshotRequested && parseQueue.isEmpty
            parseCondition.unlock()
            // On this thread, so forwarding never waits on it: the main loop only asks.
            if wantsSnapshot {
                terminalLock.lock()
                writeSnapshotFile()
                terminalLock.unlock()
            }
            parseCondition.lock()
            if wantsSnapshot { snapshotRequested = false; snapshotsWritten += 1 }
            parsing = false
            parseCondition.broadcast()
            parseCondition.unlock()
        }
    }
    thread.qualityOfService = .userInitiated
    thread.start()
}

// MARK: - Notifications

/// While no client is attached (Side is closed, or this session's project is), the keeper
/// tells the person through Side's notifier app (RFC, Notifications): a program's own desktop
/// notification (OSC 9/777), a bell, or an agent going quiet after working, which is the end of its
/// turn or a question waiting. One notification a session every 30 seconds at most.
let agents: Set<String> = ["claude", "codex", "opencode", "gemini", "aider", "goose", "amp", "crush", "qwen", "cursor-agent"]
var busySince: Date?
var notifiedThisBusySpell = false
var lastNotifiedAt = Date.distantPast
var quietTimerArmedAt = Date.distantPast
/// Working for this long, then quiet for `quietBeforeNotifying`: a turn ended.
let busyBeforeNotifying: TimeInterval = 5
let quietBeforeNotifying: TimeInterval = 4

var sessionName: String {
    let program = ForegroundProgram.name(arguments: record.foreground)
    let place = spec.place ?? (spec.directory as NSString).lastPathComponent
    return program.map { "\(displayName($0)) in \(place)" } ?? place
}

func displayName(_ program: String) -> String {
    ["claude": "Claude", "codex": "Codex", "opencode": "OpenCode", "gemini": "Gemini", "aider": "Aider"][program] ?? program
}

func noteActivity() {
    let now = Date()
    // A new spell of work begins after two quiet seconds.
    if busySince == nil || now.timeIntervalSince(record.lastOutputAt) > 2 {
        busySince = now
        notifiedThisBusySpell = false
    }
    guard spec.notifier != nil, now.timeIntervalSince(quietTimerArmedAt) > 1 else { return }
    quietTimerArmedAt = now
    watch(5, EVFILT_TIMER, EV_ADD | EV_ONESHOT, fflags: 0 /* milliseconds */, data: Int((quietBeforeNotifying + 1.2) * 1000))
}

/// The quiet timer: an agent that worked and has now stopped.
func checkForTurnEnd() {
    let now = Date()
    let quiet = now.timeIntervalSince(record.lastOutputAt)
    guard quiet >= quietBeforeNotifying else {
        watch(5, EVFILT_TIMER, EV_ADD | EV_ONESHOT, fflags: 0 /* milliseconds */, data: Int((quietBeforeNotifying - quiet) * 1000) + 50)
        return
    }
    guard !attached, !notifiedThisBusySpell, let start = busySince, record.lastOutputAt.timeIntervalSince(start) >= busyBeforeNotifying else { return }
    let foreground = foregroundArguments()
    guard let program = ForegroundProgram.name(arguments: foreground), agents.contains(program) else { return }
    notifiedThisBusySpell = true
    record.foreground = foreground
    notify(body: "\(sessionName) stopped: done, or waiting on you")
}

func notify(title: String? = nil, body: String) {
    guard let notifier = spec.notifier, FileManager.default.isExecutableFile(atPath: notifier) else { return }
    let now = Date()
    guard now.timeIntervalSince(lastNotifiedAt) >= 30 else { return }
    lastNotifiedAt = now
    let arguments = [notifier, "--title", title ?? "Side", "--body", body, "--url", "side://run/\(spec.id)", "--group", spec.id]
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
    var cArgs: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
    var cEnv: [UnsafeMutablePointer<CChar>?] = (["PATH=/usr/bin:/bin"] as [String]).map { strdup($0) } + [nil]
    defer { (cArgs + cEnv).forEach { free($0) } }
    var pid: pid_t = 0
    if posix_spawn(&pid, notifier, &actions, &attributes, &cArgs, &cEnv) == 0 {
        // Reaped when it ends, so it never lingers as a zombie of ours.
        Thread.detachNewThread { var status: Int32 = 0; waitpid(pid, &status, 0) }
    }
}

// MARK: - Snapshots on disk

/// `<id>.snap`: the screen and scrollback, so a restart brings them back (RFC, Snapshots on disk).
/// Written every 30 seconds while there's new output, and at shutdown (SIGTERM) or hangup.
var snapshotRequested = false
var snapshotsWritten = 0
var snapshotTimerArmed = false

func armSnapshotTimer() {
    guard !snapshotTimerArmed else { return }
    snapshotTimerArmed = true
    watch(4, EVFILT_TIMER, EV_ADD | EV_ONESHOT, fflags: UInt32(NOTE_SECONDS), data: 30)
}

/// Asks the parse thread for a snapshot; `wait` blocks until it's on disk (at shutdown).
func saveSnapshot(wait: Bool) {
    parseCondition.lock()
    let target = snapshotsWritten + 1
    snapshotRequested = true
    parseCondition.broadcast()
    if wait { while snapshotsWritten < target { parseCondition.wait() } }
    parseCondition.unlock()
}

/// Streamed through a writer to a temporary file and renamed into place: never built whole in
/// memory, and a reader never sees half of one. Readable only by the user.
func writeSnapshotFile() {
    let url = SessionPaths.snapshot(spec.id)
    let temporary = url.path + ".tmp"
    let fd = open(temporary, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
    guard fd >= 0 else { log("snapshot: \(String(cString: strerror(errno)))"); return }
    var box = fd
    let ok = withUnsafeMutablePointer(to: &box) { pointer -> Bool in
        let writer = GhosttyWriter(write: { userdata, data, len in
            guard let userdata, let data else { return false }
            let fd = userdata.assumingMemoryBound(to: Int32.self).pointee
            var offset = 0
            while offset < len {
                let n = Darwin.write(fd, data + offset, len - offset)
                if n > 0 { offset += n } else if n < 0, errno == EINTR { continue } else { return false }
            }
            return true
        }, userdata: UnsafeMutableRawPointer(pointer))
        return ghostty_snapshot_encode(terminal, writer) == GHOSTTY_SUCCESS
    }
    close(fd)
    if ok { rename(temporary, url.path) } else { unlink(temporary); log("snapshot: encode failed") }
}

/// A terminal decoded from a saved snapshot, or nil if it won't read.
func restoredTerminal(from path: String) -> GhosttyTerminal? {
    guard let data = FileManager.default.contents(atPath: path), !data.isEmpty else { return nil }
    return data.withUnsafeBytes { raw -> GhosttyTerminal? in
        var decoder: GhosttySnapshotDecoder?
        guard ghostty_snapshot_decoder_new_buf(nil, &decoder, raw.bindMemory(to: UInt8.self).baseAddress, raw.count) == GHOSTTY_SUCCESS, let decoder else { return nil }
        defer { ghostty_snapshot_decoder_free(decoder) }
        var compress = true
        ghostty_snapshot_decoder_set(decoder, GHOSTTY_SNAPSHOT_DECODER_OPT_COMPRESS_HISTORY, &compress)
        var restored: GhosttyTerminal?
        guard ghostty_snapshot_decoder_decode(decoder, &restored) == GHOSTTY_SUCCESS else { return nil }
        return restored
    }
}

// MARK: - The foreground program

/// The arguments of the program in the foreground of the PTY (its process group's leader), or
/// empty when that's the shell itself: what a restart resumes or offers to run again.
func foregroundArguments() -> [String] {
    let group = tcgetpgrp(master)
    guard group > 0, group != childPID else { return [] }
    return ForegroundProgram.arguments(of: group)
}

func enqueueParse(_ chunk: Chunk) {
    parseCondition.lock()
    parseQueue.append(chunk)
    if parserWaiting { parseCondition.signal() }
    parseCondition.unlock()
}

/// The terminal, with everything read so far parsed into it.
func withTerminal<T>(_ body: () -> T) -> T {
    parseCondition.lock()
    while !parseQueue.isEmpty || parsing { parseCondition.wait() }
    parseCondition.unlock()
    terminalLock.lock()
    defer { terminalLock.unlock() }
    return body()
}

// MARK: - Events from the parse thread

enum Event {
    case notification(title: String, body: String)
    case pwd(String)
    case title(String)
    case bell
    case reply([UInt8])
    case status(ProgramStatusRecord)
    case statusClear(String)
    case promptStart
}

/// The program's status records (OSC 7501), kept here: the terminal doesn't.
var statusRecords = ProgramStatusRecords()
/// The attached client asked for `programStatus` and `pwd` frames (its Hello).
var clientWantsEvents = false
/// The same, for a connection waiting to take over (`main.swift`): it said hello as a candidate.
var candidateWantsEvents = false

/// After any change: the record on disk, and the client if it listens.
func statusChanged() {
    record.programStatus = statusRecords.records
    recordDirty = true
    if clientWantsEvents { sendToClient(Frame(.programStatus, json: statusRecords.records)) }
}
let eventLock = NSLock()
var pendingEvents: [Event] = []
/// The kqueue user event that wakes the main loop for them.
let eventIdent: UInt = 10

func post(_ event: Event) {
    eventLock.lock()
    pendingEvents.append(event)
    eventLock.unlock()
    var trigger = kevent(ident: eventIdent, filter: Int16(EVFILT_USER), flags: 0, fflags: UInt32(NOTE_TRIGGER), data: 0, udata: nil)
    _ = kevent(queue, &trigger, 1, nil, 0, nil)
}

func handleEvents() {
    eventLock.lock()
    let pending = pendingEvents
    pendingEvents.removeAll()
    eventLock.unlock()
    for event in pending {
        switch event {
        case .title(let title):
            guard title != record.title else { continue }
            record.title = title
            recordDirty = true
            sendToClient(Frame(.title, Array(title.utf8)))
        case .bell:
            sendToClient(Frame(.attention, Array("bell".utf8)))
            if !attached { notify(body: "\(sessionName) rang its bell") }
        case .notification(let title, let body):
            sendToClient(Frame(.attention, Array(body.utf8)))
            if !attached { notify(title: title.isEmpty ? nil : title, body: body.isEmpty ? "\(sessionName) sent a notification" : body) }
        case .pwd(let pwd):
            // OSC 7 carries a file URL; the record keeps the path.
            let path = URL(string: pwd)?.path ?? pwd
            guard path != record.pwd else { continue }
            record.pwd = path
            recordDirty = true
            if clientWantsEvents { sendToClient(Frame(.pwd, Array(path.utf8))) }
        case .reply(let bytes):
            // While a client is attached, its own terminal answers the program's queries, as it
            // always has; answering here too would send every reply twice. Detached, the keeper
            // answers, so a program that asks doesn't wait forever. The OSC 7501 support query
            // is the keeper's alone to answer: it's the keeper that keeps the records.
            guard !attached || bytes.starts(with: Array("\u{1b}]7501".utf8)) else { continue }
            writeToPTY(bytes)
        case .status(let report):
            statusRecords.put(report)
            statusChanged()
        case .statusClear(let id):
            statusRecords.clear(id)
            statusChanged()
        case .promptStart:
            let before = statusRecords
            statusRecords.programEnded()
            if statusRecords != before { statusChanged() }
        }
    }
}

// MARK: - Snapshot

/// The terminal as escape sequences: scrollback and screen, styles, cursor, scroll region, tab
/// stops, the working directory and every mode that isn't at its default. Not the palette:
/// the client has its own theme.
func formatted(_ term: GhosttyTerminal, history: Int? = nil) -> [UInt8] {
    var options = GhosttyFormatterTerminalOptions()
    options.size = MemoryLayout<GhosttyFormatterTerminalOptions>.size
    options.emit = GHOSTTY_FORMATTER_FORMAT_VT
    options.unwrap = false
    options.trim = false
    options.extra.size = MemoryLayout<GhosttyFormatterTerminalExtra>.size
    options.extra.palette = false
    options.extra.modes = true
    options.extra.scrolling_region = true
    options.extra.tabstops = true
    options.extra.pwd = true
    options.extra.keyboard = true
    options.extra.screen.size = MemoryLayout<GhosttyFormatterScreenExtra>.size
    options.extra.screen.cursor = true
    options.extra.screen.style = true
    options.extra.screen.hyperlink = true
    options.extra.screen.protection = true
    options.extra.screen.kitty_keyboard = true
    options.extra.screen.charsets = true
    // Only the last `history` lines of scrollback, then the screen.
    var selection = GhosttySelection()
    if let history, let range = recentRows(term, history: history) {
        selection = range
        return withUnsafePointer(to: &selection) { pointer in
            options.selection = pointer
            return format(term, options)
        }
    }
    return format(term, options)
}

/// The rows from `history` lines above the screen to the bottom of it.
func recentRows(_ term: GhosttyTerminal, history: Int) -> GhosttySelection? {
    var total = 0, rows: UInt16 = 0, cols: UInt16 = 0
    ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_TOTAL_ROWS, &total)
    ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_ROWS, &rows)
    ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_COLS, &cols)
    let first = max(0, total - Int(rows) - history)
    guard first > 0 else { return nil } // all of it fits: no selection needed
    var start = GhosttyGridRef(), end = GhosttyGridRef()
    start.size = MemoryLayout<GhosttyGridRef>.size
    end.size = MemoryLayout<GhosttyGridRef>.size
    var from = GhosttyPoint(), to = GhosttyPoint()
    from.tag = GHOSTTY_POINT_TAG_SCREEN
    from.value.coordinate = GhosttyPointCoordinate(x: 0, y: UInt32(first))
    to.tag = GHOSTTY_POINT_TAG_SCREEN
    to.value.coordinate = GhosttyPointCoordinate(x: cols > 0 ? cols - 1 : 0, y: UInt32(total - 1))
    guard ghostty_terminal_grid_ref(term, from, &start) == GHOSTTY_SUCCESS, ghostty_terminal_grid_ref(term, to, &end) == GHOSTTY_SUCCESS else { return nil }
    var selection = GhosttySelection()
    selection.size = MemoryLayout<GhosttySelection>.size
    selection.start = start
    selection.end = end
    selection.rectangle = false
    return selection
}

func format(_ term: GhosttyTerminal, _ options: GhosttyFormatterTerminalOptions) -> [UInt8] {
    var formatter: GhosttyFormatter?
    guard ghostty_formatter_terminal_new(nil, &formatter, term, options) == GHOSTTY_SUCCESS, let formatter else { return [] }
    defer { ghostty_formatter_free(formatter) }
    var ptr: UnsafeMutablePointer<UInt8>?
    var len = 0
    guard ghostty_formatter_format_alloc(formatter, nil, &ptr, &len) == GHOSTTY_SUCCESS, let ptr else { return [] }
    defer { ghostty_free(nil, ptr, len) }
    return Array(UnsafeBufferPointer(start: ptr, count: len))
}

/// Everything a fresh client terminal needs to show this one: a full reset, then the screen.
/// While a full-screen program has the alternate screen, the primary screen (the shell and its
/// scrollback) comes first, rebuilt in a scratch copy, so it's there when the program exits.
func snapshot(history: Int? = nil) -> [UInt8] { withTerminal { snapshotLocked(history: history) } }

func snapshotLocked(history: Int?) -> [UInt8] {
    var out = Array("\u{1b}c".utf8)
    var screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY
    ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen)
    if screen == GHOSTTY_TERMINAL_SCREEN_ALTERNATE, let primary = primaryCopy() {
        out += formatted(primary, history: history)
        ghostty_terminal_free(primary)
        out += Array("\u{1b}[?1049h".utf8)
    }
    out += formatted(terminal, history: history)
    return out
}

/// A copy of the terminal switched back to its primary screen.
func primaryCopy() -> GhosttyTerminal? {
    var ptr: UnsafeMutablePointer<UInt8>?
    var len = 0
    guard ghostty_snapshot_encode_alloc(terminal, nil, &ptr, &len) == GHOSTTY_SUCCESS, let ptr else { return nil }
    defer { ghostty_free(nil, ptr, len) }
    var decoder: GhosttySnapshotDecoder?
    guard ghostty_snapshot_decoder_new_buf(nil, &decoder, ptr, len) == GHOSTTY_SUCCESS, let decoder else { return nil }
    defer { ghostty_snapshot_decoder_free(decoder) }
    var copy: GhosttyTerminal?
    guard ghostty_snapshot_decoder_decode(decoder, &copy) == GHOSTTY_SUCCESS, let copy else { return nil }
    let leave = Array("\u{1b}[?1049l".utf8)
    leave.withUnsafeBufferPointer { ghostty_terminal_vt_write(copy, $0.baseAddress, $0.count) }
    return copy
}

// MARK: - Messages from the client

func handle(_ frame: Frame) {
    switch frame.kind {
    case .hello:
        clientWantsEvents = frame.decode(Hello.self)?.events == true
        // Too new a client is still answered; it decides whether it can talk to this keeper.
        sendToClient(Frame(.welcome, json: Welcome(protocolVersion: SessionProtocol.version, build: build, record: record)))
    case .attach:
        let request = frame.decode(Attach.self)
        if let request { resize(Size(cols: request.cols, rows: request.rows)) }
        attached = true
        readerBridges.store(true, ordering: .relaxed)
        sendToClient(Frame(.snapshot, snapshot(history: request?.history)))
        if !record.title.isEmpty { sendToClient(Frame(.title, Array(record.title.utf8))) }
        if clientWantsEvents {
            if !record.pwd.isEmpty { sendToClient(Frame(.pwd, Array(record.pwd.utf8))) }
            if !statusRecords.records.isEmpty { sendToClient(Frame(.programStatus, json: statusRecords.records)) }
        }
        reportExit()
    case .detach:
        dropClient()
    case .input:
        writeToPTY(frame.payload)
    case .resize:
        if let size = frame.decode(Size.self) { resize(size) }
    case .signal:
        if let request = frame.decode(SignalRequest.self) { signalChild(request) }
    default:
        break
    }
}

func resize(_ size: Size) {
    guard size.cols > 0, size.rows > 0 else { return }
    var ws = winsize(ws_row: UInt16(size.rows), ws_col: UInt16(size.cols), ws_xpixel: 0, ws_ypixel: 0)
    _ = ioctl(master, TIOCSWINSZ, &ws)
    withTerminal { _ = ghostty_terminal_resize(terminal, UInt16(size.cols), UInt16(size.rows), 8, 16) }
}

/// The child and, for a whole-tree signal, every descendant, found before any is signalled: a
/// killed shell's children are reparented to launchd and can't be found by walking down from it.
func signalChild(_ request: SignalRequest) {
    var targets: [pid_t] = [childPID]
    if request.wholeTree {
        var frontier: [pid_t] = [childPID]
        while let pid = frontier.popLast() {
            var children = [pid_t](repeating: 0, count: 512)
            let bytes = proc_listchildpids(pid, &children, Int32(children.count * MemoryLayout<pid_t>.size))
            for child in children.prefix(max(0, Int(bytes))) where child > 0 { targets.append(child); frontier.append(child) }
        }
    }
    for pid in targets { kill(pid, request.signal) }
}

// MARK: - The child's exit

var exitPending = false
/// The exit frame is queued for an attached client; the keeper ends when it has gone out.
var exitReported = false

func reportExit() {
    guard let exit = record.exit, attached, !exitReported else { return }
    exitReported = true
    sendToClient(Frame(.exited, json: exit))
    flushClient()
}

func childExited() {
    var status: Int32 = 0
    guard waitpid(childPID, &status, WNOHANG) == childPID else { return }
    // Whatever the child wrote before it ended: the reader sees the PTY close moments after the
    // exit (later, if a background job still holds it open; not waited for past a fifth of a
    // second).
    let deadline = Date().addingTimeInterval(0.2)
    while Date() < deadline {
        readLock.lock(); let ended = readEnded; readLock.unlock()
        if ended { break }
        usleep(2_000)
    }
    takeReads()
    let exitedNormally = (status & 0x7f) == 0
    record.exit = Exit(status: exitedNormally ? (status >> 8) & 0xff : nil, signal: exitedNormally ? nil : status & 0x7f)
    // The program is over: nothing is still working or waiting.
    let before = statusRecords
    statusRecords.programEnded()
    if statusRecords != before { statusChanged() }
    writeRecord()
    log("child \(childPID) exited (\(record.exit!))")
    exitPending = true
    reportExit()
    // Detached: kept until a client attaches and learns how it ended, or for a day.
    watch(1, EVFILT_TIMER, EV_ADD | EV_ONESHOT, fflags: UInt32(NOTE_SECONDS), data: 24 * 3600)
}


func consume(_ chunk: Chunk) {
    // To the client first: what it shows doesn't wait on the keeper's own parse.
    if attached { sendToClient(.output, chunk.bytes) }
    enqueueParse(chunk)
    record.lastOutputAt = Date()
    outputSinceTimers()
}

/// Timers are armed by output, never left ticking: an idle keeper doesn't wake at all. The
/// record's last-output time is written within two seconds; compression is considered once the
/// session has been quiet for five.
var recordTimerArmed = false
func outputSinceTimers() {
    recordDirty = true
    noteActivity()
    armSnapshotTimer()
    if !recordTimerArmed {
        recordTimerArmed = true
        watch(2, EVFILT_TIMER, EV_ADD | EV_ONESHOT, fflags: UInt32(NOTE_SECONDS), data: 2)
    }
    // Re-adding a timer restarts it, so this fires five seconds after the last output. Not
    // re-armed for every read: once a second at most.
    let now = Date()
    if now.timeIntervalSince(compressionTimerArmedAt) > 1 {
        compressionTimerArmedAt = now
        watch(3, EVFILT_TIMER, EV_ADD | EV_ONESHOT, fflags: 0 /* milliseconds */, data: Int(quietBeforeCompressing * 1000) + 100)
    }
}
var compressionTimerArmedAt = Date.distantPast

/// Exit for good: the client knows how the session ended, or a day passed.
func finish() {
    SessionPaths.remove(spec.id)
    exit(0)
}


func registerTerminalCallbacks() {
    ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_DESKTOP_NOTIFICATION, unsafeBitCast(desktopNotification, to: UnsafeRawPointer.self))
    ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_PWD_CHANGED, unsafeBitCast(pwdChanged, to: UnsafeRawPointer.self))
    ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_TITLE_CHANGED, unsafeBitCast(titleChanged, to: UnsafeRawPointer.self))
    ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_BELL, unsafeBitCast(bell, to: UnsafeRawPointer.self))
    ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY, unsafeBitCast(writePTY, to: UnsafeRawPointer.self))
    ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_PROGRAM_STATUS, unsafeBitCast(programStatus, to: UnsafeRawPointer.self))
    ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SEMANTIC_PROMPT, unsafeBitCast(semanticPrompt, to: UnsafeRawPointer.self))
}

// MARK: - Compression

/// Scrollback is compressed once the session has been quiet for a while
/// (SIDE_RFC_SESSION_RESTORE.md, Memory): libghostty-vt's incremental steps, a bounded amount
/// per tick, never while output flows. Scrolling back or a snapshot decompresses transparently.
let quietBeforeCompressing: TimeInterval = 5
var compressedAtActivity: UInt64?

func compressIfQuiet() { withTerminal { compressIfQuietLocked() } }

func compressIfQuietLocked() {
    // The timer is re-armed at most once a second while output flows, so it can fire before
    // five quiet seconds have passed: then it waits out the rest, rather than giving up.
    let quiet = Date().timeIntervalSince(record.lastOutputAt)
    guard quiet >= quietBeforeCompressing else {
        watch(3, EVFILT_TIMER, EV_ADD | EV_ONESHOT, fflags: 0 /* milliseconds */, data: Int((quietBeforeCompressing - quiet) * 1000) + 50)
        return
    }
    var activity: UInt64 = 0
    ghostty_terminal_compression_activity(terminal, &activity)
    guard activity != compressedAtActivity else { return }
    let start = Date()
    var result = GHOSTTY_TERMINAL_COMPRESSION_RESULT_PENDING
    // About 20 ms of steps a tick (a step is under a millisecond for text, a few for heavily
    // styled output); the rest waits for the next tick, so the loop never stalls on it.
    while result == GHOSTTY_TERMINAL_COMPRESSION_RESULT_PENDING, Date().timeIntervalSince(start) < 0.02 {
        ghostty_terminal_compress(terminal, GHOSTTY_TERMINAL_COMPRESSION_MODE_INCREMENTAL, &result)
    }
    if result == GHOSTTY_TERMINAL_COMPRESSION_RESULT_PENDING {
        // More to do: the next slice shortly, not a second from now.
        watch(3, EVFILT_TIMER, EV_ADD | EV_ONESHOT, fflags: 0 /* milliseconds */, data: 50)
        return
    }
    compressedAtActivity = activity
    // Freed pages back to the system now: macOS otherwise reclaims them only under pressure,
    // so the keeper looked as big as before compressing.
    ChunkPool.trim()
    malloc_zone_pressure_relief(nil, 0)
}
