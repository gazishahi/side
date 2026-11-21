import Foundation
import GhosttyVt

/// Find in a terminal, scrollback included, with libghostty's search: the matches in the
/// viewport for drawing, which one is selected, and stepping through them (the viewport scrolls to
/// the selected match). Matching is byte-exact but for ASCII letters, which ignore case, as in
/// Ghostty.
///
/// Every call takes the terminal's lock. Call `refresh()` after output, so new text is searched
/// and the viewport's matches follow it.
public final class TerminalSearch: @unchecked Sendable {
    // @unchecked: `handle` is touched only under the terminal's lock.
    public let terminal: Terminal
    private var handle: GhosttySearch?

    public init(terminal: Terminal) {
        self.terminal = terminal
        terminal.lock.write {
            var made: GhosttySearch?
            if ghostty_search_new(nil, &made, terminal.handle) == GHOSTTY_SUCCESS { handle = made }
        }
    }

    deinit {
        let handle = handle
        terminal.lock.write { if let handle { ghostty_search_free(handle) } }
    }

    /// What's being looked for; empty for nothing. Setting the same text again keeps the results.
    public var needle: String = "" {
        didSet {
            let needle = needle
            terminal.lock.write {
                guard let handle else { return }
                if needle.isEmpty {
                    ghostty_search_set(handle, GHOSTTY_SEARCH_OPT_NEEDLE, nil)
                } else {
                    var bytes = Array(needle.utf8)
                    bytes.withUnsafeMutableBufferPointer { buffer in
                        var string = GhosttyString(ptr: buffer.baseAddress, len: buffer.count)
                        _ = ghostty_search_set(handle, GHOSTTY_SEARCH_OPT_NEEDLE, &string)
                    }
                    ghostty_search_run(handle)
                }
            }
        }
    }

    /// Catches up with the terminal's new text.
    public func refresh() {
        terminal.lock.write {
            guard let handle, !needle.isEmpty else { return }
            ghostty_search_run(handle)
        }
    }

    /// Selects the next match toward older text (up, into the scrollback), wrapping around, and
    /// scrolls to it if it's out of view.
    public func next() { select(GHOSTTY_SEARCH_OPT_SELECT_NEXT) }
    /// The next toward newer text (down).
    public func previous() { select(GHOSTTY_SEARCH_OPT_SELECT_PREV) }

    private func select(_ option: GhosttySearchOption) {
        terminal.lock.write {
            guard let handle, !needle.isEmpty else { return }
            ghostty_search_set(handle, option, nil)
            // Selecting a match can scroll the viewport: the screen is read again.
            terminal.changedSinceRead = true
        }
    }

    /// All matches, scrollback included.
    public var total: Int {
        terminal.lock.read {
            guard let handle else { return 0 }
            var total = 0
            ghostty_search_get(handle, GHOSTTY_SEARCH_DATA_TOTAL_MATCHES, &total)
            return total
        }
    }

    /// The selected match's place, 1 for the newest (the lowest on screen), for "3 of 12"; nil
    /// when none is selected.
    public var selectedNumber: Int? {
        terminal.lock.read {
            guard let handle else { return nil }
            var index = 0
            return ghostty_search_get(handle, GHOSTTY_SEARCH_DATA_SELECTED_INDEX, &index) == GHOSTTY_SUCCESS ? index + 1 : nil
        }
    }

    /// The matches in the viewport, each as the cells it covers row by row, and the selected one
    /// if it's in view.
    public func viewportMatches() -> (matches: [[TerminalLink.Span]], selected: [TerminalLink.Span]) {
        terminal.lock.read {
            guard let handle else { return ([], []) }
            let terminal = terminal.handle
            var buffer = GhosttySelectionBuffer(ptr: nil, cap: 0, len: 0)
            var list: [GhosttySelection] = []
            if ghostty_search_get(handle, GHOSTTY_SEARCH_DATA_VIEWPORT_MATCHES, &buffer) == GHOSTTY_OUT_OF_SPACE, buffer.len > 0 {
                list = Array(repeating: Self.emptySelection, count: buffer.len)
                let ok = list.withUnsafeMutableBufferPointer { pointer -> Bool in
                    buffer = GhosttySelectionBuffer(ptr: pointer.baseAddress, cap: pointer.count, len: 0)
                    return ghostty_search_get(handle, GHOSTTY_SEARCH_DATA_VIEWPORT_MATCHES, &buffer) == GHOSTTY_SUCCESS
                }
                list = ok ? Array(list.prefix(buffer.len)) : []
            }
            // Screen coordinates throughout: every match has them, in view or not.
            guard let top = Self.screenPoint(terminal, Self.viewportOrigin(terminal)) else { return ([], []) }
            var rows: UInt16 = 0, columns: UInt16 = 0
            ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_ROWS, &rows)
            ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_COLS, &columns)
            func spans(_ selection: GhosttySelection) -> [TerminalLink.Span] {
                guard var a = Self.screenPoint(terminal, selection.start), var b = Self.screenPoint(terminal, selection.end) else { return [] }
                if (b.y, b.x) < (a.y, a.x) { swap(&a, &b) }
                var result: [TerminalLink.Span] = []
                for y in a.y...b.y {
                    let row = y - top.y
                    guard row >= 0, row < Int(rows) else { continue }
                    let first = y == a.y ? a.x : 0, last = y == b.y ? b.x : Int(columns) - 1
                    if first <= last { result.append(TerminalLink.Span(row: row, columns: first...last)) }
                }
                return result
            }
            var selected = Self.emptySelection
            let hasSelected = ghostty_search_get(handle, GHOSTTY_SEARCH_DATA_SELECTED_MATCH, &selected) == GHOSTTY_SUCCESS
            return (list.map(spans).filter { !$0.isEmpty }, hasSelected ? spans(selected) : [])
        }
    }

    private static var emptySelection: GhosttySelection {
        var selection = GhosttySelection()
        selection.size = MemoryLayout<GhosttySelection>.size
        return selection
    }

    private static func viewportOrigin(_ terminal: GhosttyTerminal) -> GhosttyGridRef {
        var point = GhosttyPoint()
        point.tag = GHOSTTY_POINT_TAG_VIEWPORT
        point.value.coordinate = GhosttyPointCoordinate(x: 0, y: 0)
        var ref = GhosttyGridRef()
        ref.size = MemoryLayout<GhosttyGridRef>.size
        ghostty_terminal_grid_ref(terminal, point, &ref)
        return ref
    }

    private static func screenPoint(_ terminal: GhosttyTerminal, _ ref: GhosttyGridRef) -> (x: Int, y: Int)? {
        var ref = ref
        var coordinate = GhosttyPointCoordinate()
        guard ghostty_terminal_point_from_grid_ref(terminal, &ref, GHOSTTY_POINT_TAG_SCREEN, &coordinate) == GHOSTTY_SUCCESS else { return nil }
        return (Int(coordinate.x), Int(coordinate.y))
    }
}
