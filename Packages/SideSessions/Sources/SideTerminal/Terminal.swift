import Foundation
import GhosttyVt
import SideSessionsKit

/// One terminal emulator: libghostty-vt's, wrapped for Side (docs/SIDE_RFC_TERMINAL_ENGINE.md).
/// The program's output goes in through `feed`, on the reader's thread; a `ScreenReader` copies
/// what changed out, on the render thread. Both take the terminal's lock, the reader for each
/// write and the screen only to update its render state, so drawing never waits on parsing for
/// longer than that update.
///
/// What the program asks of the terminal comes back through `Events`, called on the thread that
/// fed the bytes, inside the write: keep them short (hand the work to another queue).
public final class Terminal: @unchecked Sendable {
    // @unchecked: every use of `handle` and of the hold state is under `lock`.

    public struct Events: Sendable {
        /// Bytes for the program: replies to its queries (cursor position, device attributes,
        /// colors). Write them to the PTY.
        public var reply: (@Sendable ([UInt8]) -> Void)?
        public var title: (@Sendable (String) -> Void)?
        public var bell: (@Sendable () -> Void)?
        /// OSC 7: the program's working directory, as the URL it sent.
        public var workingDirectory: (@Sendable (String) -> Void)?
        /// OSC 9 and OSC 777: the program's own desktop notification.
        public var notification: (@Sendable (_ title: String, _ body: String) -> Void)?
        /// OSC 7501 (the Program Status Protocol): what the program says it's doing; nil clears
        /// the record with that id.
        public var programStatus: (@Sendable (_ id: String, _ record: ProgramStatusRecord?) -> Void)?

        public init() {}
    }

    public enum TerminalError: Error { case couldNotCreate }

    let lock = HandoffLock()
    /// Output is parsed in slices of this many bytes, so a waiting frame gets in between them.
    static let slice = 16 * 1024
    let handle: GhosttyTerminal
    private let events: Events
    public private(set) var columns: Int
    public private(set) var rows: Int

    /// Output arrived since the screen was last read.
    var changedSinceRead = true

    /// Synchronized output (mode 2026), which Claude Code wraps nearly every update in: while a
    /// hold lasts (a second at most), readers don't update, so what's drawn is the last frame
    /// read before it, as Ghostty's renderer does. Not a snapshot taken in a render state of
    /// its own when the hold begins: a render-state update takes the terminal's record of which
    /// rows changed, so a second state left the reader's missing rows (2026-11-20, on screen:
    /// btop's rows under lazygit).
    var holding = false
    var holdStarted: UInt64 = 0

    /// `cursorBlinks`: whether the cursor blinks until a program says otherwise (DECSCUSR, DEC
    /// mode 12), as Ghostty's `cursor-style-blink` does. Blinking, as there and in SwiftTerm.
    public init(columns: Int, rows: Int, scrollbackLines: Int = 10_000, cursorBlinks: Bool = true, events: Events = Events()) throws {
        var made: GhosttyTerminal?
        guard ghostty_terminal_new(nil, &made, UInt16(clamping: max(1, columns)), UInt16(clamping: max(1, rows))) == GHOSTTY_SUCCESS,
              let made else { throw TerminalError.couldNotCreate }
        handle = made
        self.columns = max(1, columns)
        self.rows = max(1, rows)
        self.events = events
        var lines = scrollbackLines
        ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &lines)
        // The C API's default byte limit (10,000 bytes) silently overrides the line limit.
        ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, nil)
        // Kitty graphics: off until given a storage limit; PNGs decoded by ImageIO.
        KittyGraphics.installDecoder
        var imageLimit = KittyGraphics.storageLimit
        ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT, &imageLimit)
        // Grapheme clustering (mode 2027), on as in Ghostty.app and the keeper.
        var clustering = GhosttyTerminalModeConfig()
        clustering.mode = ghostty_mode_new(2027, false)
        clustering.value = true
        ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_MODE, &clustering)
        var blink = GhosttyTerminalModeConfig()
        blink.mode = ghostty_mode_new(12, false)
        blink.value = cursorBlinks
        ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_MODE_DEFAULT, &blink)
        ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_MODE, &blink)
        var blinks = cursorBlinks
        ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_BLINK, &blinks)
        registerCallbacks()
    }

    deinit {
        ghostty_terminal_free(handle)
    }

    /// The program's output.
    public func feed(_ bytes: UnsafeRawBufferPointer) {
        guard let base = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self), !bytes.isEmpty else { return }
        var offset = 0
        while offset < bytes.count {
            let length = min(bytes.count - offset, Self.slice)
            lock.write {
                ghostty_terminal_vt_write(handle, base + offset, length)
                changedSinceRead = true
            }
            offset += length
        }
    }

    public func feed(_ bytes: [UInt8]) {
        bytes.withUnsafeBytes { feed($0) }
    }

    /// A new size, in cells, and the cell's size in pixels (for programs that ask).
    /// The cell size given at the last resize: the unit images are placed and sized in.
    public private(set) var cellWidth = 8
    public private(set) var cellHeight = 16

    public func resize(columns: Int, rows: Int, cellWidth: Int = 8, cellHeight: Int = 16) {
        lock.read {
            self.columns = max(1, columns)
            self.rows = max(1, rows)
            self.cellWidth = max(1, cellWidth)
            self.cellHeight = max(1, cellHeight)
            ghostty_terminal_resize(handle, UInt16(clamping: self.columns), UInt16(clamping: self.rows), UInt32(clamping: cellWidth), UInt32(clamping: cellHeight))
            changedSinceRead = true
        }
    }

    /// The default colors, 0xRRGGBB: what a cell with no color of its own is drawn in, and what
    /// programs are told when they ask (OSC 10, 11, 12).
    public func setDefaultColors(foreground: UInt32, background: UInt32, cursor: UInt32? = nil) {
        lock.read {
            var fg = Self.rgb(foreground), bg = Self.rgb(background)
            ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &fg)
            ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &bg)
            if let cursor {
                var c = Self.rgb(cursor)
                ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &c)
            } else {
                ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, nil)
            }
            changedSinceRead = true
        }
    }

    /// The first sixteen colors, 0xRRGGBB (the rest of the 256 stay xterm's).
    public func setPalette(_ colors: [UInt32]) {
        lock.read {
            var palette = [GhosttyColorRgb](repeating: GhosttyColorRgb(), count: 256)
            palette.withUnsafeMutableBufferPointer { _ = ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_COLOR_PALETTE_DEFAULT, $0.baseAddress) }
            for (i, color) in colors.prefix(256).enumerated() { palette[i] = Self.rgb(color) }
            palette.withUnsafeMutableBufferPointer { _ = ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, $0.baseAddress) }
            changedSinceRead = true
        }
    }

    /// Whether a mode is set: a DEC private mode (`?2004`, bracketed paste) unless `ansi`.
    public func isModeSet(_ mode: UInt16, ansi: Bool = false) -> Bool {
        lock.read {
            var config = GhosttyTerminalModeConfig()
            config.mode = ghostty_mode_new(mode, ansi)
            return ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_MODE, &config) == GHOSTTY_SUCCESS && config.value
        }
    }

    /// The text on screen, or with `scrollback` everything the terminal holds, as plain text.
    public func text(scrollback: Bool = false) -> String {
        lock.read {
            var options = GhosttyFormatterTerminalOptions()
            options.size = MemoryLayout<GhosttyFormatterTerminalOptions>.size
            options.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
            options.unwrap = true
            options.trim = true
            var selection = GhosttySelection()
            if !scrollback, let screen = screenRows() {
                selection = screen
                return withUnsafePointer(to: &selection) { pointer in
                    options.selection = pointer
                    return format(options)
                }
            }
            return format(options)
        }
    }

    /// The rows on screen, as a selection, when there's scrollback above them. Under `lock`.
    private func screenRows() -> GhosttySelection? {
        var total = 0, rows: UInt16 = 0, cols: UInt16 = 0
        ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_TOTAL_ROWS, &total)
        ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_ROWS, &rows)
        ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_COLS, &cols)
        let first = total - Int(rows)
        guard first > 0 else { return nil }
        var start = GhosttyGridRef(), end = GhosttyGridRef()
        start.size = MemoryLayout<GhosttyGridRef>.size
        end.size = MemoryLayout<GhosttyGridRef>.size
        var from = GhosttyPoint(), to = GhosttyPoint()
        from.tag = GHOSTTY_POINT_TAG_SCREEN
        from.value.coordinate = GhosttyPointCoordinate(x: 0, y: UInt32(first))
        to.tag = GHOSTTY_POINT_TAG_SCREEN
        to.value.coordinate = GhosttyPointCoordinate(x: cols > 0 ? cols - 1 : 0, y: UInt32(total - 1))
        guard ghostty_terminal_grid_ref(handle, from, &start) == GHOSTTY_SUCCESS, ghostty_terminal_grid_ref(handle, to, &end) == GHOSTTY_SUCCESS else { return nil }
        var selection = GhosttySelection()
        selection.size = MemoryLayout<GhosttySelection>.size
        selection.start = start
        selection.end = end
        return selection
    }

    /// Under `lock`.
    private func format(_ options: GhosttyFormatterTerminalOptions) -> String {
        var formatter: GhosttyFormatter?
        guard ghostty_formatter_terminal_new(nil, &formatter, handle, options) == GHOSTTY_SUCCESS, let formatter else { return "" }
        defer { ghostty_formatter_free(formatter) }
        var pointer: UnsafeMutablePointer<UInt8>?
        var length = 0
        guard ghostty_formatter_format_alloc(formatter, nil, &pointer, &length) == GHOSTTY_SUCCESS, let pointer else { return "" }
        defer { ghostty_free(nil, pointer, length) }
        return String(decoding: UnsafeBufferPointer(start: pointer, count: length), as: UTF8.self)
    }

    public var title: String { lock.read { string(GHOSTTY_TERMINAL_DATA_TITLE) } }

    public var workingDirectory: String { lock.read { string(GHOSTTY_TERMINAL_DATA_PWD) } }

    // MARK: - Internals

    static func rgb(_ value: UInt32) -> GhosttyColorRgb {
        GhosttyColorRgb(r: UInt8((value >> 16) & 0xFF), g: UInt8((value >> 8) & 0xFF), b: UInt8(value & 0xFF))
    }

    /// A string the terminal holds. Under `lock`, or inside a callback (already under it).
    func string(_ key: GhosttyTerminalData) -> String {
        var value = GhosttyString()
        guard ghostty_terminal_get(handle, key, &value) == GHOSTTY_SUCCESS else { return "" }
        return Self.text(value)
    }

    static func text(_ value: GhosttyString) -> String {
        guard let ptr = value.ptr, value.len > 0 else { return "" }
        return String(decoding: UnsafeBufferPointer(start: ptr, count: value.len), as: UTF8.self)
    }

    private static func owner(_ userdata: UnsafeMutableRawPointer?) -> Terminal {
        Unmanaged<Terminal>.fromOpaque(userdata!).takeUnretainedValue()
    }

    /// The callbacks run inside `vt_write`, on the feeding thread, with `lock` held.
    private func registerCallbacks() {
        let me = Unmanaged.passUnretained(self).toOpaque()
        ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_USERDATA, me)

        let writePTY: GhosttyTerminalWritePtyFn = { _, userdata, data, len in
            guard let data, len > 0 else { return }
            Terminal.owner(userdata).events.reply?(Array(UnsafeBufferPointer(start: data, count: len)))
        }
        let titleChanged: GhosttyTerminalTitleChangedFn = { _, userdata in
            let terminal = Terminal.owner(userdata)
            terminal.events.title?(terminal.string(GHOSTTY_TERMINAL_DATA_TITLE))
        }
        let bell: GhosttyTerminalBellFn = { _, userdata in Terminal.owner(userdata).events.bell?() }
        let pwdChanged: GhosttyTerminalPwdChangedFn = { _, userdata in
            let terminal = Terminal.owner(userdata)
            terminal.events.workingDirectory?(terminal.string(GHOSTTY_TERMINAL_DATA_PWD))
        }
        let notification: GhosttyTerminalDesktopNotificationFn = { _, userdata, request in
            guard let request else { return }
            Terminal.owner(userdata).events.notification?(Terminal.text(request.pointee.title), Terminal.text(request.pointee.body))
        }
        let programStatus: GhosttyTerminalProgramStatusFn = { _, userdata, report in
            guard let report else { return }
            let r = report.pointee
            let id = Terminal.text(r.id)
            let state: ProgramStatusRecord.State
            switch r.state {
            case GHOSTTY_PROGRAM_STATUS_STATE_CLEAR: Terminal.owner(userdata).events.programStatus?(id, nil); return
            case GHOSTTY_PROGRAM_STATUS_STATE_IDLE: state = .idle
            case GHOSTTY_PROGRAM_STATUS_STATE_WORKING: state = .working
            case GHOSTTY_PROGRAM_STATUS_STATE_DONE: state = .done
            case GHOSTTY_PROGRAM_STATUS_STATE_BLOCKED: state = .blocked
            case GHOSTTY_PROGRAM_STATUS_STATE_ERROR: state = .error
            default: return
            }
            let kind: ProgramStatusRecord.Kind? = switch r.kind {
            case GHOSTTY_PROGRAM_STATUS_KIND_PERMISSION: .permission
            case GHOSTTY_PROGRAM_STATUS_KIND_QUESTION: .question
            case GHOSTTY_PROGRAM_STATUS_KIND_AUTH: .auth
            default: nil
            }
            let record = ProgramStatusRecord(id: id, state: state, kind: kind, progress: r.progress >= 0 ? Int(r.progress) : nil,
                                             app: Terminal.text(r.app), title: Terminal.text(r.title), message: Terminal.text(r.message))
            Terminal.owner(userdata).events.programStatus?(id, record)
        }
        let renderHold: GhosttyTerminalRenderHoldFn = { terminal, userdata, held in
            let me = Terminal.owner(userdata)
            if held {
                // The screen as it is now is what readers see until the hold ends.
                me.holding = true
                me.holdStarted = DispatchTime.now().uptimeNanoseconds
            } else {
                me.holding = false
            }
            me.changedSinceRead = true
        }
        func set<F>(_ option: GhosttyTerminalOption, _ callback: F) {
            ghostty_terminal_set(handle, option, unsafeBitCast(callback, to: UnsafeRawPointer.self))
        }
        set(GHOSTTY_TERMINAL_OPT_WRITE_PTY, writePTY)
        set(GHOSTTY_TERMINAL_OPT_TITLE_CHANGED, titleChanged)
        set(GHOSTTY_TERMINAL_OPT_BELL, bell)
        set(GHOSTTY_TERMINAL_OPT_PWD_CHANGED, pwdChanged)
        set(GHOSTTY_TERMINAL_OPT_DESKTOP_NOTIFICATION, notification)
        set(GHOSTTY_TERMINAL_OPT_PROGRAM_STATUS, programStatus)
        set(GHOSTTY_TERMINAL_OPT_RENDER_HOLD, renderHold)
    }
}
