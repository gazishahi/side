import GhosttyVt

/// A typed key, as plain data: what the view turns an NSEvent into (SideTerminal stays free of
/// AppKit, since the keeper links it).
public struct KeyInput: Sendable, Equatable {
    public enum Action: Sendable { case press, `repeat`, release }

    public struct Modifiers: OptionSet, Sendable, Hashable {
        public let rawValue: UInt16
        public init(rawValue: UInt16) { self.rawValue = rawValue }
        public static let shift = Modifiers(rawValue: UInt16(GHOSTTY_MODS_SHIFT))
        public static let control = Modifiers(rawValue: UInt16(GHOSTTY_MODS_CTRL))
        public static let option = Modifiers(rawValue: UInt16(GHOSTTY_MODS_ALT))
        public static let command = Modifiers(rawValue: UInt16(GHOSTTY_MODS_SUPER))
        public static let capsLock = Modifiers(rawValue: UInt16(GHOSTTY_MODS_CAPS_LOCK))
        public static let numLock = Modifiers(rawValue: UInt16(GHOSTTY_MODS_NUM_LOCK))
        /// The right-hand key of the pair was the one held.
        public static let rightShift = Modifiers(rawValue: UInt16(GHOSTTY_MODS_SHIFT_SIDE))
        public static let rightControl = Modifiers(rawValue: UInt16(GHOSTTY_MODS_CTRL_SIDE))
        public static let rightOption = Modifiers(rawValue: UInt16(GHOSTTY_MODS_ALT_SIDE))
        public static let rightCommand = Modifiers(rawValue: UInt16(GHOSTTY_MODS_SUPER_SIDE))
    }

    public var action: Action
    /// The macOS virtual keycode (NSEvent.keyCode).
    public var keycode: UInt16
    public var modifiers: Modifiers
    /// Modifiers the keyboard layout used up producing `text` (shift for "A", option for "é").
    public var consumed: Modifiers
    /// What the key typed, after the layout and the input system; nil when it typed nothing
    /// printable.
    public var text: String?
    /// The key's character with no modifiers ("a" for shift-A), for the kitty protocol.
    public var unshifted: UInt32
    /// A dead key or an input method is still composing.
    public var composing: Bool

    public init(action: Action = .press, keycode: UInt16, modifiers: Modifiers = [], consumed: Modifiers = [], text: String? = nil,
                unshifted: UInt32 = 0, composing: Bool = false) {
        self.action = action
        self.keycode = keycode
        self.modifiers = modifiers
        self.consumed = consumed
        self.text = text
        self.unshifted = unshifted
        self.composing = composing
    }
}

/// Turns typed keys into the bytes the program expects, by the terminal's current modes (cursor
/// and keypad application mode, modifyOtherKeys, the kitty keyboard protocol): libghostty-vt's
/// key encoder, with its options read from the terminal before every key. Use it from one thread.
public final class KeyEncoder {
    public enum OptionAsAlt: Sendable { case never, always, left, right }

    public let terminal: Terminal
    /// Whether option sends escape-prefixed keys (Meta) instead of typing the layout's
    /// characters. Never by default, as in Terminal.app and Ghostty.
    public var optionAsAlt: OptionAsAlt = .never

    private var encoder: GhosttyKeyEncoder?
    private var event: GhosttyKeyEvent?
    private var buffer = [UInt8](repeating: 0, count: 128)

    public init(terminal: Terminal) {
        self.terminal = terminal
        ghostty_key_encoder_new(nil, &encoder)
        ghostty_key_event_new(nil, &event)
    }

    deinit {
        ghostty_key_event_free(event)
        ghostty_key_encoder_free(encoder)
    }

    /// The modifiers the view should let the keyboard layout translate the key with: all of
    /// them, except option when it acts as Meta (then "f", not "ƒ", with option unconsumed), as
    /// Ghostty's macOS app does (`ghostty_surface_key_translation_mods`).
    public func translationModifiers(for modifiers: KeyInput.Modifiers) -> KeyInput.Modifiers {
        guard modifiers.contains(.option) else { return modifiers }
        let right = modifiers.contains(.rightOption)
        let meta = switch optionAsAlt {
        case .never: false
        case .always: true
        case .left: !right
        case .right: right
        }
        return meta ? modifiers.subtracting([.option, .rightOption]) : modifiers
    }

    /// The bytes for `key`; empty when it sends nothing (a bare modifier, most releases).
    public func encode(_ key: KeyInput) -> [UInt8] {
        terminal.lock.read { ghostty_key_encoder_setopt_from_terminal(encoder, terminal.handle) }
        var option: GhosttyOptionAsAlt = switch optionAsAlt {
        case .never: GHOSTTY_OPTION_AS_ALT_FALSE
        case .always: GHOSTTY_OPTION_AS_ALT_TRUE
        case .left: GHOSTTY_OPTION_AS_ALT_LEFT
        case .right: GHOSTTY_OPTION_AS_ALT_RIGHT
        }
        ghostty_key_encoder_setopt(encoder, GHOSTTY_KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT, &option)

        let action: GhosttyKeyAction = switch key.action {
        case .press: GHOSTTY_KEY_ACTION_PRESS
        case .`repeat`: GHOSTTY_KEY_ACTION_REPEAT
        case .release: GHOSTTY_KEY_ACTION_RELEASE
        }
        ghostty_key_event_set_action(event, action)
        ghostty_key_event_set_key(event, macKeycodes[key.keycode] ?? GHOSTTY_KEY_UNIDENTIFIED)
        ghostty_key_event_set_mods(event, key.modifiers.rawValue)
        ghostty_key_event_set_consumed_mods(event, key.consumed.rawValue)
        ghostty_key_event_set_composing(event, key.composing)
        ghostty_key_event_set_unshifted_codepoint(event, key.unshifted)

        // The text must outlive the encode: it's read, not copied, by set_utf8.
        var text = Array((key.text ?? "").utf8)
        return text.withUnsafeMutableBufferPointer { utf8 in
            utf8.baseAddress.map { base in
                base.withMemoryRebound(to: CChar.self, capacity: utf8.count) { ghostty_key_event_set_utf8(event, $0, utf8.count) }
            } ?? ghostty_key_event_set_utf8(event, nil, 0)
            var written = 0
            var result = buffer.withUnsafeMutableBufferPointer { out in
                out.baseAddress!.withMemoryRebound(to: CChar.self, capacity: out.count) {
                    ghostty_key_encoder_encode(encoder, event, $0, out.count, &written)
                }
            }
            if result == GHOSTTY_OUT_OF_SPACE {
                buffer = [UInt8](repeating: 0, count: written)
                result = buffer.withUnsafeMutableBufferPointer { out in
                    out.baseAddress!.withMemoryRebound(to: CChar.self, capacity: out.count) {
                        ghostty_key_encoder_encode(encoder, event, $0, out.count, &written)
                    }
                }
            }
            guard result == GHOSTTY_SUCCESS else { return [] }
            return Array(buffer[0..<written])
        }
    }
}
