import GhosttyVt

/// A mouse event for a program that asked for the mouse (htop, tmux, vim with mouse=a), as plain
/// data, in the surface's pixels from the top-left.
public struct MouseInput: Sendable, Equatable {
    public enum Action: Sendable { case press, release, motion }
    public enum Button: Sendable { case none, left, right, middle, wheelUp, wheelDown }

    public var action: Action
    public var button: Button
    public var modifiers: KeyInput.Modifiers
    public var x: Double
    public var y: Double

    public init(action: Action, button: Button, modifiers: KeyInput.Modifiers = [], x: Double, y: Double) {
        self.action = action
        self.button = button
        self.modifiers = modifiers
        self.x = x
        self.y = y
    }
}

/// Mouse events as the program asked for them (X10, normal, button or any-event tracking, in the
/// SGR, URxvt or SGR-pixel format): libghostty-vt's mouse encoder, with its options read from
/// the terminal before every event. Use it from one thread.
public final class MouseEncoder {
    public let terminal: Terminal

    /// The surface's geometry in pixels, for turning positions into cells.
    public struct Geometry: Sendable, Equatable {
        public var width: Int
        public var height: Int
        public var cellWidth: Int
        public var cellHeight: Int
        public init(width: Int, height: Int, cellWidth: Int, cellHeight: Int) {
            self.width = width
            self.height = height
            self.cellWidth = cellWidth
            self.cellHeight = cellHeight
        }
    }

    private var encoder: GhosttyMouseEncoder?
    private var event: GhosttyMouseEvent?
    private var pressed: Set<MouseInput.Button> = []
    private var lastGeometry: Geometry?
    private var dedupeSet = false
    private var configured = false
    private var buffer = [UInt8](repeating: 0, count: 64)

    public init(terminal: Terminal) {
        self.terminal = terminal
        ghostty_mouse_encoder_new(nil, &encoder)
        ghostty_mouse_event_new(nil, &event)
    }

    deinit {
        ghostty_mouse_event_free(event)
        ghostty_mouse_encoder_free(encoder)
    }

    /// Whether the program asked for the mouse at all.
    public var isTracking: Bool {
        terminal.lock.read {
            var tracking = false
            ghostty_terminal_get(terminal.handle, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &tracking)
            return tracking
        }
    }

    /// The bytes for `input`; empty when the program's mode doesn't report it (motion with no
    /// button in normal tracking, the same cell twice).
    public func encode(_ input: MouseInput, geometry: Geometry) -> [UInt8] {
        // The program's mode and format, read on presses and releases only: reading them forgets
        // the last cell, which is what reports motion within one cell once (mouse_encode.zig).
        if input.action != .motion || !configured {
            configured = true
            terminal.lock.read { ghostty_mouse_encoder_setopt_from_terminal(encoder, terminal.handle) }
        }
        if !dedupeSet {
            dedupeSet = true
            var dedupe = true
            ghostty_mouse_encoder_setopt(encoder, GHOSTTY_MOUSE_ENCODER_OPT_TRACK_LAST_CELL, &dedupe)
        }
        if geometry != lastGeometry {
            lastGeometry = geometry
            var size = GhosttyMouseEncoderSize()
            size.size = MemoryLayout<GhosttyMouseEncoderSize>.size
            size.screen_width = UInt32(max(1, geometry.width))
            size.screen_height = UInt32(max(1, geometry.height))
            size.cell_width = UInt32(max(1, geometry.cellWidth))
            size.cell_height = UInt32(max(1, geometry.cellHeight))
            ghostty_mouse_encoder_setopt(encoder, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &size)
        }

        let isWheel = input.button == .wheelUp || input.button == .wheelDown
        if !isWheel {
            switch input.action {
            case .press: pressed.insert(input.button)
            case .release: pressed.remove(input.button)
            case .motion: break
            }
        }
        var anyPressed = !pressed.isEmpty
        ghostty_mouse_encoder_setopt(encoder, GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED, &anyPressed)

        let action: GhosttyMouseAction = switch input.action {
        case .press: GHOSTTY_MOUSE_ACTION_PRESS
        case .release: GHOSTTY_MOUSE_ACTION_RELEASE
        case .motion: GHOSTTY_MOUSE_ACTION_MOTION
        }
        ghostty_mouse_event_set_action(event, action)
        switch input.button {
        case .none: ghostty_mouse_event_clear_button(event)
        case .left: ghostty_mouse_event_set_button(event, GHOSTTY_MOUSE_BUTTON_LEFT)
        case .right: ghostty_mouse_event_set_button(event, GHOSTTY_MOUSE_BUTTON_RIGHT)
        case .middle: ghostty_mouse_event_set_button(event, GHOSTTY_MOUSE_BUTTON_MIDDLE)
        case .wheelUp: ghostty_mouse_event_set_button(event, GHOSTTY_MOUSE_BUTTON_FOUR)
        case .wheelDown: ghostty_mouse_event_set_button(event, GHOSTTY_MOUSE_BUTTON_FIVE)
        }
        ghostty_mouse_event_set_mods(event, input.modifiers.rawValue)
        ghostty_mouse_event_set_position(event, GhosttyMousePosition(x: Float(input.x), y: Float(input.y)))

        var written = 0
        var result = buffer.withUnsafeMutableBufferPointer { out in
            out.baseAddress!.withMemoryRebound(to: CChar.self, capacity: out.count) {
                ghostty_mouse_encoder_encode(encoder, event, $0, out.count, &written)
            }
        }
        if result == GHOSTTY_OUT_OF_SPACE {
            buffer = [UInt8](repeating: 0, count: written)
            result = buffer.withUnsafeMutableBufferPointer { out in
                out.baseAddress!.withMemoryRebound(to: CChar.self, capacity: out.count) {
                    ghostty_mouse_encoder_encode(encoder, event, $0, out.count, &written)
                }
            }
        }
        guard result == GHOSTTY_SUCCESS else { return [] }
        return Array(buffer[0..<written])
    }
}
