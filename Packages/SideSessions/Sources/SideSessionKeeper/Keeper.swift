import CKeeperSpawn
import Darwin
import Foundation
import GhosttyVt
import SideSessionsKit

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

func log(_ message: String) { FileHandle.standardError.write(Data("[keeper \(getpid())] \(message)\n".utf8)) }
func fail(_ message: String) -> Never { log(message); exit(1) }
func setNonBlocking(_ fd: Int32) { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }

func writeRecord() {
    recordDirty = false
    do { try record.write(to: recordURL) } catch { log("record: \(error)") }
}

// MARK: - The client


/// Bytes for the PTY, and for the client: both written as they can take them.
var toPTY: [UInt8] = []
var client: Int32 = -1
var attached = false
var clientDecoder = FrameDecoder()
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
    let wasEmpty = toClientOffset == toClient.count
    toClient.append(contentsOf: frame.encoded)
    if toClient.count - toClientOffset > clientBacklogLimit { log("client stopped reading; letting it go"); dropClient(); return }
    if wasEmpty { flushClient() }
}

func flushClient() {
    guard client >= 0 else { return }
    while toClientOffset < toClient.count {
        let n = toClient.withUnsafeBytes { write(client, $0.baseAddress! + toClientOffset, toClient.count - toClientOffset) }
        if n > 0 { toClientOffset += n; continue }
        if n < 0, errno == EINTR { continue }
        if n < 0, errno == EAGAIN { watch(client, EVFILT_WRITE, EV_ADD | EV_ENABLE | EV_ONESHOT); return }
        dropClient()
        return
    }
    toClient.removeAll(keepingCapacity: true)
    toClientOffset = 0
    // Gone only once the client has been told how the session ended.
    if exitReported { finish() }
}

func dropClient() {
    guard client >= 0 else { return }
    exitReported = false
    close(client) // closing removes its kqueue filters
    client = -1
    attached = false
    clientDecoder = FrameDecoder()
    toClient.removeAll()
    toClientOffset = 0
}

func flushPTY() {
    while !toPTY.isEmpty {
        let n = toPTY.withUnsafeBytes { write(master, $0.baseAddress!, $0.count) }
        if n > 0 { toPTY.removeFirst(n); continue }
        if n < 0, errno == EINTR { continue }
        if n < 0, errno == EAGAIN { watch(master, EVFILT_WRITE, EV_ADD | EV_ENABLE | EV_ONESHOT); return }
        toPTY.removeAll()
        return
    }
}

// MARK: - Terminal callbacks

func currentTitle() -> String {
    var value = GhosttyString()
    guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_TITLE, &value) == GHOSTTY_SUCCESS, let ptr = value.ptr, value.len > 0 else { return "" }
    return String(decoding: UnsafeBufferPointer(start: ptr, count: value.len), as: UTF8.self)
}

let titleChanged: GhosttyTerminalTitleChangedFn = { _, _ in
    let title = currentTitle()
    guard title != record.title else { return }
    record.title = title
    recordDirty = true
    sendToClient(Frame(.title, Array(title.utf8)))
}

let bell: GhosttyTerminalBellFn = { _, _ in sendToClient(Frame(.attention, Array("bell".utf8))) }

// Replies to the program's queries (cursor position, device attributes). While a client is
// attached, its own terminal answers them, as it always has; answering here too would send every
// reply twice. Detached, the keeper answers, so a program that asks doesn't wait forever.
let writePTY: GhosttyTerminalWritePtyFn = { _, _, data, len in
    guard !attached, let data, len > 0 else { return }
    toPTY.append(contentsOf: UnsafeBufferPointer(start: data, count: len))
    flushPTY()
}

// MARK: - Snapshot

/// The terminal as escape sequences: scrollback and screen, styles, cursor, scroll region, tab
/// stops, the working directory and every mode that isn't at its default. Not the palette:
/// the client has its own theme.
func formatted(_ term: GhosttyTerminal) -> [UInt8] {
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
func snapshot() -> [UInt8] {
    var out = Array("\u{1b}c".utf8)
    var screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY
    ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen)
    if screen == GHOSTTY_TERMINAL_SCREEN_ALTERNATE, let primary = primaryCopy() {
        out += formatted(primary)
        ghostty_terminal_free(primary)
        out += Array("\u{1b}[?1049h".utf8)
    }
    out += formatted(terminal)
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
        // Too new a client is still answered; it decides whether it can talk to this keeper.
        sendToClient(Frame(.welcome, json: Welcome(protocolVersion: SessionProtocol.version, build: build, record: record)))
    case .attach:
        if let size = frame.decode(Size.self) { resize(size) }
        attached = true
        sendToClient(Frame(.snapshot, snapshot()))
        if !record.title.isEmpty { sendToClient(Frame(.title, Array(record.title.utf8))) }
        reportExit()
    case .detach:
        dropClient()
    case .input:
        toPTY.append(contentsOf: frame.payload)
        flushPTY()
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
    ghostty_terminal_resize(terminal, UInt16(size.cols), UInt16(size.rows), 8, 16)
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
    drainPTY()
    let exitedNormally = (status & 0x7f) == 0
    record.exit = Exit(status: exitedNormally ? (status >> 8) & 0xff : nil, signal: exitedNormally ? nil : status & 0x7f)
    writeRecord()
    log("child \(childPID) exited (\(record.exit!))")
    exitPending = true
    reportExit()
    // Detached: kept until a client attaches and learns how it ended, or for a day.
    watch(1, EVFILT_TIMER, EV_ADD | EV_ONESHOT, fflags: UInt32(NOTE_SECONDS), data: 24 * 3600)
}

/// Whatever the child wrote before it ended.
func drainPTY() {
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: 64 * 1024, alignment: 16)
    defer { buffer.deallocate() }
    while true {
        let n = read(master, buffer, 64 * 1024)
        guard n > 0 else { return }
        consume(UnsafeRawBufferPointer(start: buffer, count: n))
    }
}

func consume(_ bytes: UnsafeRawBufferPointer) {
    ghostty_terminal_vt_write(terminal, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count)
    if attached { sendToClient(Frame(.output, Array(bytes))) }
    record.lastOutputAt = Date()
    recordDirty = true
}

/// Exit for good: the client knows how the session ended, or a day passed.
func finish() {
    unlink(socketURL.path)
    try? FileManager.default.removeItem(at: recordURL)
    try? FileManager.default.removeItem(at: SessionPaths.runDirectory.appendingPathComponent("\(spec.id).log"))
    exit(0)
}


func registerTerminalCallbacks() {
    ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_TITLE_CHANGED, unsafeBitCast(titleChanged, to: UnsafeRawPointer.self))
    ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_BELL, unsafeBitCast(bell, to: UnsafeRawPointer.self))
    ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY, unsafeBitCast(writePTY, to: UnsafeRawPointer.self))
}
