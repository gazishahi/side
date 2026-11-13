import Foundation
import GhosttyVt

/// A link under the pointer: what it opens, and the viewport cells it covers, row by row, so it
/// can be underlined where it is, across the rows it wraps onto.
public struct TerminalLink: Equatable, Sendable {
    public struct Span: Equatable, Sendable {
        public var row: Int
        public var columns: ClosedRange<Int>
        public init(row: Int, columns: ClosedRange<Int>) { self.row = row; self.columns = columns }
    }
    public var url: String
    public var spans: [Span]
    public init(url: String, spans: [Span]) { self.url = url; self.spans = spans }
}

extension Terminal {
    /// The link at a viewport cell: its OSC 8 hyperlink, or a URL or path in the text (Ghostty's
    /// pattern), either one followed across soft-wrapped rows.
    public func link(column: Int, row: Int) -> TerminalLink? {
        if let url = hyperlink(column: column, row: row) {
            // The run of cells with the same link, through the rows it wraps onto.
            var cells: [(row: Int, column: Int)] = [(row, column)]
            var at = (row: row, column: column)
            while let before = step(at, by: -1), hyperlink(column: before.column, row: before.row) == url { cells.insert(before, at: 0); at = before }
            at = (row, column)
            while let after = step(at, by: 1), hyperlink(column: after.column, row: after.row) == url { cells.append(after); at = after }
            return TerminalLink(url: url, spans: Self.spans(cells))
        }
        // The logical line: the rows before that wrap into this one, and those this wraps onto.
        var first = row, last = row
        while first > 0, isWrapped(row: first - 1) { first -= 1 }
        while last < rows - 1, isWrapped(row: last) { last += 1 }
        var text = ""
        var positions: [(row: Int, column: Int)] = []
        for y in first...last {
            let line = rowText(y)
            text += line.text
            positions += line.columns.map { (y, $0) }
        }
        guard let (url, covered) = ImplicitLinks.match(in: text, positions: positions, covering: { $0.row == row && $0.column == column })
        else { return nil }
        return TerminalLink(url: url, spans: Self.spans(covered))
    }

    /// Whether a viewport row soft-wraps onto the next.
    public func isWrapped(row: Int) -> Bool {
        lock.read {
            guard var ref = viewportRef(column: 0, row: row) else { return false }
            var line: GhosttyRow = 0
            guard ghostty_grid_ref_row(&ref, &line) == GHOSTTY_SUCCESS else { return false }
            var wrapped = false
            ghostty_row_get(line, GHOSTTY_ROW_DATA_WRAP, &wrapped)
            return wrapped
        }
    }

    /// The next cell in reading order, across a soft wrap but not a hard line break.
    private func step(_ at: (row: Int, column: Int), by delta: Int) -> (row: Int, column: Int)? {
        let column = at.column + delta
        if column >= 0, column < columns { return (at.row, column) }
        if delta < 0, at.row > 0, isWrapped(row: at.row - 1) { return (at.row - 1, columns - 1) }
        if delta > 0, at.row < rows - 1, isWrapped(row: at.row) { return (at.row + 1, 0) }
        return nil
    }

    private static func spans(_ cells: [(row: Int, column: Int)]) -> [TerminalLink.Span] {
        var spans: [TerminalLink.Span] = []
        for cell in cells {
            if let last = spans.last, last.row == cell.row, cell.column >= last.columns.lowerBound {
                spans[spans.count - 1].columns = last.columns.lowerBound...max(last.columns.upperBound, cell.column)
            } else {
                spans.append(TerminalLink.Span(row: cell.row, columns: cell.column...cell.column))
            }
        }
        return spans
    }

    /// The OSC 8 hyperlink of a cell in the viewport, if it has one.
    public func hyperlink(column: Int, row: Int) -> String? {
        lock.read {
            guard var ref = viewportRef(column: column, row: row) else { return nil }
            var length = 0
            guard ghostty_grid_ref_hyperlink_uri(&ref, nil, 0, &length) == GHOSTTY_OUT_OF_SPACE || length > 0, length > 0 else { return nil }
            var bytes = [UInt8](repeating: 0, count: length)
            guard ghostty_grid_ref_hyperlink_uri(&ref, &bytes, length, &length) == GHOSTTY_SUCCESS, length > 0 else { return nil }
            return String(decoding: bytes[0..<length], as: UTF8.self)
        }
    }

    /// A viewport row as text, and for each UTF-16 unit of it the column it came from (what an
    /// NSRegularExpression's ranges index). The right half of a wide character adds nothing; an
    /// empty cell is a space.
    public func rowText(_ row: Int) -> (text: String, columns: [Int]) {
        lock.read {
            var text = ""
            var columns: [Int] = []
            var graphemes = [UInt32](repeating: 0, count: 16)
            for column in 0..<self.columns {
                guard var ref = viewportRef(column: column, row: row) else { break }
                var cell: GhosttyCell = 0
                ghostty_grid_ref_cell(&ref, &cell)
                var wide = GHOSTTY_CELL_WIDE_NARROW
                ghostty_cell_get(cell, GHOSTTY_CELL_DATA_WIDE, &wide)
                if wide == GHOSTTY_CELL_WIDE_SPACER_TAIL || wide == GHOSTTY_CELL_WIDE_SPACER_HEAD { continue }
                var length = 0
                ghostty_grid_ref_graphemes(&ref, &graphemes, graphemes.count, &length)
                var piece = String.UnicodeScalarView()
                for i in 0..<min(length, graphemes.count) { if let u = UnicodeScalar(graphemes[i]) { piece.append(u) } }
                let string = piece.isEmpty ? " " : String(piece)
                text += string
                columns += Array(repeating: column, count: string.utf16.count)
            }
            return (text, columns)
        }
    }

    /// Under `lock`.
    func viewportRef(column: Int, row: Int) -> GhosttyGridRef? {
        var point = GhosttyPoint()
        point.tag = GHOSTTY_POINT_TAG_VIEWPORT
        point.value.coordinate = GhosttyPointCoordinate(x: UInt16(clamping: max(0, column)), y: UInt32(clamping: max(0, row)))
        var ref = GhosttyGridRef()
        ref.size = MemoryLayout<GhosttyGridRef>.size
        return ghostty_terminal_grid_ref(handle, point, &ref) == GHOSTTY_SUCCESS ? ref : nil
    }
}

/// URLs and paths in plain text, found the way Ghostty finds them: its link pattern, as SwiftTerm
/// ported it to ICU (SwiftTerm's Terminal.swift, ghosttyImplicitLinkRegex, MIT), which is also
/// what Side's terminal matched with SwiftTerm, so links work the same in both engines.
public enum ImplicitLinks {
    /// The link in `row` that covers `column`, if any.
    public static func link(in row: (text: String, columns: [Int]), at column: Int) -> String? {
        match(in: row.text, positions: row.columns, covering: { $0 == column })?.url
    }

    /// The link in `text` that covers a position, with the positions it covers (trailing spaces
    /// left off). `positions` gives each UTF-16 unit of `text` its position, a column or a cell.
    static func match<P>(in text: String, positions: [P], covering: (P) -> Bool) -> (url: String, positions: [P])? {
        guard let regex, !positions.isEmpty else { return nil }
        let string = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: string.length)) where match.range.length > 0 {
            // Ghostty skips a match right after `$` (a variable, not a path).
            if match.range.location > 0, string.character(at: match.range.location - 1) == UInt16(UInt8(ascii: "$")) { continue }
            let url = string.substring(with: match.range).trimmingCharacters(in: .whitespaces)
            let leading = string.substring(with: match.range).prefix { $0 == " " }.utf16.count
            let start = match.range.location + leading, end = min(positions.count, start + url.utf16.count)
            guard start < end else { continue }
            let covered = Array(positions[start..<end])
            if covered.contains(where: covering) { return (url, covered) }
        }
        return nil
    }

    static let regex: NSRegularExpression? = {
        let urlSchemes = #"https?://|mailto:|ftp://|file:|ssh:|git://|ssh://|tel:|magnet:|ipfs://|ipns://|gemini://|gopher://|news:"#
        let ipv6URLPattern = #"(?:\[[:0-9a-fA-F]+\](?::[0-9]+)?)"#
        let schemeURLChars = #"[\w\-.~:/?#@!$&*+,;=%]"#
        let pathChars = #"[\w\-.~:\/?#@!$&*+;=%]"#
        let noTrailingPunctuation = #"(?<![,.])"#
        let noTrailingColon = #"(?<!:)"#
        let trailingSpacesAtEOL = #"(?: +(?= *$))?"#
        let dottedPathLookahead = #"(?=[\w\-.~:\/?#@!$&*+;=%]*\.)"#
        let nonDottedPathLookahead = #"(?![\w\-.~:\/?#@!$&*+;=%]*\.)"#
        let dottedPathSpaceSegments = #"(?:(?<!:) (?!\w+:\/\/)[\w\-.~:\/?#@!$&*+;=%]*[\/.])*"#
        let anyPathSpaceSegments = #"(?:(?<!:) (?!\w+:\/\/)[\w\-.~:\/?#@!$&*+;=%]+)*"#
        let bracketedWordSuffix = #"(?:[\(\[]\w*[\)\]])"#
        let schemeURLToken = "(?:" + ipv6URLPattern + "|" + schemeURLChars + "(?:" + bracketedWordSuffix + ")?)"
        let schemeURLBranch = "(?:" + urlSchemes + ")" + schemeURLToken + "+" + noTrailingPunctuation
        let rootedOrRelativePathPrefix = #"(?:\.\.\/|\.\/|(?<!\w)~\/|(?:[\w][\w\-.]*\/)*(?<!\w)\$[A-Za-z_]\w*\/|\.[\w][\w\-.]*\/|(?<![\w~\/])\/(?!\/))"#
        let rootedOrRelativePathBranch = rootedOrRelativePathPrefix + "(?:"
            + dottedPathLookahead + pathChars + "+" + dottedPathSpaceSegments + noTrailingColon + trailingSpacesAtEOL + "|"
            + nonDottedPathLookahead + pathChars + "+" + anyPathSpaceSegments + noTrailingColon + trailingSpacesAtEOL + ")"
        let bareRelativePathPrefix = #"(?<!\w)[\w][\w\-.]*\/"#
        let bareRelativePathBranch = dottedPathLookahead + bareRelativePathPrefix + pathChars + "+" + dottedPathSpaceSegments
            + noTrailingColon + trailingSpacesAtEOL
        return try? NSRegularExpression(pattern: schemeURLBranch + "|" + rootedOrRelativePathBranch + "|" + bareRelativePathBranch)
    }()
}
