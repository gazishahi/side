import GhosttyVt

/// Focus reports (DEC mode 1004): what a program that asked for them is sent when the terminal
/// gains or loses the keyboard, `CSI I` or `CSI O`, encoded by libghostty-vt (focus.h).
public enum FocusReport {
    public static func encode(gained: Bool) -> [UInt8] {
        var buffer = [CChar](repeating: 0, count: 8)
        var written = 0
        let result = buffer.withUnsafeMutableBufferPointer {
            ghostty_focus_encode(gained ? GHOSTTY_FOCUS_GAINED : GHOSTTY_FOCUS_LOST, $0.baseAddress, $0.count, &written)
        }
        guard result == GHOSTTY_SUCCESS else { return [] }
        return buffer.prefix(written).map { UInt8(bitPattern: $0) }
    }
}
