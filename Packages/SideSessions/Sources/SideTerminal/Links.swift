import Foundation
import GhosttyVt

extension Terminal {
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
        guard let regex else { return nil }
        let text = row.text as NSString
        for match in regex.matches(in: row.text, range: NSRange(location: 0, length: text.length)) where match.range.length > 0 {
            // Ghostty skips a match right after `$` (a variable, not a path).
            if match.range.location > 0, text.character(at: match.range.location - 1) == UInt16(UInt8(ascii: "$")) { continue }
            let first = row.columns[match.range.location]
            let last = row.columns[min(row.columns.count - 1, match.range.location + match.range.length - 1)]
            if column >= first, column <= last {
                return text.substring(with: match.range).trimmingCharacters(in: .whitespaces)
            }
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
