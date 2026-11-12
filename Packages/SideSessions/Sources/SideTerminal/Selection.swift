import Foundation
import GhosttyVt

// MARK: - Scrolling back

extension Terminal {
    /// Where the viewport sits in everything the terminal holds, in rows.
    public struct Scrollbar: Equatable, Sendable {
        public var total: Int
        public var offset: Int
        public var length: Int
        /// The viewport isn't at the bottom: output arriving doesn't move it.
        public var isScrolledBack: Bool { offset + length < total }
    }

    public var scrollbar: Scrollbar {
        lock.read {
            var bar = GhosttyTerminalScrollbar()
            ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &bar)
            return Scrollbar(total: Int(bar.total), offset: Int(bar.offset), length: Int(bar.len))
        }
    }

    /// Up is negative.
    public func scroll(byRows delta: Int) {
        guard delta != 0 else { return }
        viewport(GhosttyTerminalScrollViewport(tag: GHOSTTY_SCROLL_VIEWPORT_DELTA, value: GhosttyTerminalScrollViewportValue(delta: delta)))
    }

    /// Row 0 is the top of the scrollback (the scrollbar's offset space).
    public func scroll(toRow row: Int) {
        viewport(GhosttyTerminalScrollViewport(tag: GHOSTTY_SCROLL_VIEWPORT_ROW, value: GhosttyTerminalScrollViewportValue(row: max(0, row))))
    }

    /// A full-screen program's own screen (vim, less): no scrollback of its own.
    public var isAlternateScreen: Bool {
        lock.read {
            var screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY
            ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen)
            return screen == GHOSTTY_TERMINAL_SCREEN_ALTERNATE
        }
    }

    public func scrollToBottom() {
        viewport(GhosttyTerminalScrollViewport(tag: GHOSTTY_SCROLL_VIEWPORT_BOTTOM, value: GhosttyTerminalScrollViewportValue()))
    }

    private func viewport(_ behavior: GhosttyTerminalScrollViewport) {
        lock.read {
            ghostty_terminal_scroll_viewport(handle, behavior)
            changedSinceRead = true
        }
    }
}

// MARK: - Selection

/// Text selection by pointer, with libghostty-vt's own gesture state machine (Ghostty's): a
/// click and drag selects cells, a double click words, a triple click lines, option-drag a
/// rectangle, and dragging past an edge asks for autoscroll. The selection is installed on the
/// terminal, so the screen reader marks its cells. Use it from one thread (the main thread).
public final class TerminalSelection {
    public let terminal: Terminal
    private var gesture: GhosttySelectionGesture?
    private var pressEvent: GhosttySelectionGestureEvent?
    private var dragEvent: GhosttySelectionGestureEvent?
    private var releaseEvent: GhosttySelectionGestureEvent?
    private var tickEvent: GhosttySelectionGestureEvent?

    /// The grid's geometry, in the surface's pixels: drags past an edge depend on it.
    public struct Geometry: Sendable {
        public var columns: Int
        public var cellWidth: Int
        public var screenHeight: Int
        public init(columns: Int, cellWidth: Int, screenHeight: Int) {
            self.columns = columns
            self.cellWidth = cellWidth
            self.screenHeight = screenHeight
        }
    }

    public enum Autoscroll: Sendable { case none, up, down }

    public init(terminal: Terminal) {
        self.terminal = terminal
        ghostty_selection_gesture_new(nil, &gesture)
        ghostty_selection_gesture_event_new(nil, &pressEvent, GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_PRESS)
        ghostty_selection_gesture_event_new(nil, &dragEvent, GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_DRAG)
        ghostty_selection_gesture_event_new(nil, &releaseEvent, GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_RELEASE)
        ghostty_selection_gesture_event_new(nil, &tickEvent, GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_AUTOSCROLL_TICK)
    }

    deinit {
        ghostty_selection_gesture_event_free(tickEvent)
        ghostty_selection_gesture_event_free(releaseEvent)
        ghostty_selection_gesture_event_free(dragEvent)
        ghostty_selection_gesture_event_free(pressEvent)
        // The gesture holds tracked references into the terminal: freed under its lock.
        terminal.lock.read { ghostty_selection_gesture_free(gesture, terminal.handle) }
    }

    /// The mouse went down on a cell of the viewport. `x`, `y`: surface pixels.
    public func press(column: Int, row: Int, x: Double, y: Double, repeatInterval: TimeInterval, repeatDistance: Double) {
        terminal.lock.read {
            guard var ref = gridRef(column: column, row: row) else { return }
            var position = GhosttySurfacePosition(x: x, y: y)
            var time = DispatchTime.now().uptimeNanoseconds
            var interval = UInt64(repeatInterval * 1_000_000_000)
            var distance = repeatDistance
            ghostty_selection_gesture_event_set(pressEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &ref)
            ghostty_selection_gesture_event_set(pressEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION, &position)
            ghostty_selection_gesture_event_set(pressEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_TIME_NS, &time)
            ghostty_selection_gesture_event_set(pressEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REPEAT_INTERVAL_NS, &interval)
            ghostty_selection_gesture_event_set(pressEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REPEAT_DISTANCE, &distance)
            // A single click clears; a double or triple click selects its word or line at once.
            install(apply(pressEvent))
        }
    }

    /// The mouse moved with the button down. Returns which way the viewport should scroll, if
    /// the pointer is past the top or bottom edge.
    @discardableResult
    public func drag(column: Int, row: Int, x: Double, y: Double, rectangle: Bool, geometry: Geometry) -> Autoscroll {
        terminal.lock.read {
            guard var ref = gridRef(column: column, row: row) else { return .none }
            var position = GhosttySurfacePosition(x: x, y: y)
            var rect = rectangle
            var geo = Self.geometry(geometry)
            ghostty_selection_gesture_event_set(dragEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &ref)
            ghostty_selection_gesture_event_set(dragEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION, &position)
            ghostty_selection_gesture_event_set(dragEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_RECTANGLE, &rect)
            ghostty_selection_gesture_event_set(dragEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_GEOMETRY, &geo)
            if let selection = apply(dragEvent) { install(selection) }
            return autoscroll()
        }
    }

    /// While dragging past an edge: the viewport scrolled a row; extend the selection with it.
    public func autoscrollTick(column: Int, row: Int, rectangle: Bool, geometry: Geometry) {
        terminal.lock.read {
            var point = GhosttyPointCoordinate(x: UInt16(clamping: column), y: UInt32(clamping: max(0, row)))
            var rect = rectangle
            var geo = Self.geometry(geometry)
            ghostty_selection_gesture_event_set(tickEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_VIEWPORT, &point)
            ghostty_selection_gesture_event_set(tickEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_RECTANGLE, &rect)
            ghostty_selection_gesture_event_set(tickEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_GEOMETRY, &geo)
            if let selection = apply(tickEvent) { install(selection) }
        }
    }

    public func release(column: Int, row: Int) {
        terminal.lock.read {
            if var ref = gridRef(column: column, row: row) {
                ghostty_selection_gesture_event_set(releaseEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &ref)
            } else {
                ghostty_selection_gesture_event_set(releaseEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, nil)
            }
            _ = apply(releaseEvent)
        }
    }

    public func selectAll() {
        terminal.lock.read {
            var selection = GhosttySelection()
            selection.size = MemoryLayout<GhosttySelection>.size
            if ghostty_terminal_select_all(terminal.handle, &selection) == GHOSTTY_SUCCESS { install(selection) }
        }
    }

    public func clear() {
        terminal.lock.read { install(nil) }
    }

    public var hasSelection: Bool { terminal.lock.read { formatted() != nil } }

    /// The selection as plain text, soft-wrapped lines joined, or nil when there's none.
    public var text: String? { terminal.lock.read { formatted() } }

    // MARK: Under the terminal's lock

    private func formatted() -> String? {
        var options = GhosttyTerminalSelectionFormatOptions()
        options.size = MemoryLayout<GhosttyTerminalSelectionFormatOptions>.size
        options.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
        options.unwrap = true
        options.trim = true
        var pointer: UnsafeMutablePointer<UInt8>?
        var length = 0
        guard ghostty_terminal_selection_format_alloc(terminal.handle, nil, options, &pointer, &length) == GHOSTTY_SUCCESS, let pointer else { return nil }
        defer { ghostty_free(nil, pointer, length) }
        return String(decoding: UnsafeBufferPointer(start: pointer, count: length), as: UTF8.self)
    }

    private func gridRef(column: Int, row: Int) -> GhosttyGridRef? {
        var point = GhosttyPoint()
        point.tag = GHOSTTY_POINT_TAG_VIEWPORT
        point.value.coordinate = GhosttyPointCoordinate(x: UInt16(clamping: max(0, column)), y: UInt32(clamping: max(0, row)))
        var ref = GhosttyGridRef()
        ref.size = MemoryLayout<GhosttyGridRef>.size
        return ghostty_terminal_grid_ref(terminal.handle, point, &ref) == GHOSTTY_SUCCESS ? ref : nil
    }

    private func apply(_ event: GhosttySelectionGestureEvent?) -> GhosttySelection?? {
        var selection = GhosttySelection()
        selection.size = MemoryLayout<GhosttySelection>.size
        switch ghostty_selection_gesture_event(gesture, terminal.handle, event, &selection) {
        case GHOSTTY_SUCCESS: return .some(selection)
        case GHOSTTY_NO_VALUE: return .some(nil)
        default: return nil
        }
    }

    /// Installs a gesture's result: a selection, or none (nil). `nil` outer: leave it be.
    private func install(_ result: GhosttySelection??) {
        guard let result else { return }
        install(result)
    }

    private func install(_ selection: GhosttySelection?) {
        if var selection {
            ghostty_terminal_set(terminal.handle, GHOSTTY_TERMINAL_OPT_SELECTION, &selection)
        } else {
            ghostty_terminal_set(terminal.handle, GHOSTTY_TERMINAL_OPT_SELECTION, nil)
        }
        terminal.changedSinceRead = true
    }

    private func autoscroll() -> Autoscroll {
        var value = GHOSTTY_SELECTION_GESTURE_AUTOSCROLL_NONE
        ghostty_selection_gesture_get(gesture, terminal.handle, GHOSTTY_SELECTION_GESTURE_DATA_AUTOSCROLL, &value)
        return switch value {
        case GHOSTTY_SELECTION_GESTURE_AUTOSCROLL_UP: .up
        case GHOSTTY_SELECTION_GESTURE_AUTOSCROLL_DOWN: .down
        default: .none
        }
    }

    private static func geometry(_ g: Geometry) -> GhosttySelectionGestureGeometry {
        GhosttySelectionGestureGeometry(columns: UInt32(max(1, g.columns)), cell_width: UInt32(max(1, g.cellWidth)), padding_left: 0,
                                        screen_height: UInt32(max(1, g.screenHeight)))
    }
}
