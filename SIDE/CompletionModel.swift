import AlloyCore
import Foundation

/// Make's autocomplete, apart from its view (SIDE_RFC_IDE_ESSENTIALS.md, L2). A server is asked
/// once per word (or at its trigger characters); every keystroke after that filters and ranks
/// the list it sent, here, with no round trip, unless it said its list was incomplete.
struct CompletionSession {
    /// Where the word being completed starts (UTF-16), and where the caret was when the
    /// server was asked: what its edits' ranges were counted against.
    let wordStart: Int
    let requestCaret: Int
    private(set) var list = LSPCompletionList(items: [], isIncomplete: false)
    private var candidates: [Candidate] = []
    /// Indices into `list.items`, best first, for what's typed now.
    private(set) var shown: [Int] = []
    private(set) var query = ""
    /// A reply has arrived (an empty list is still an answer).
    private(set) var hasReply = false

    init(wordStart: Int, requestCaret: Int) {
        self.wordStart = wordStart
        self.requestCaret = requestCaret
    }

    var shownItems: [LSPCompletionItem] { shown.map { list.items[$0] } }

    /// The server's answer (or the buffer's words), ranked for `query`.
    mutating func receive(_ list: LSPCompletionList, query: String) {
        self.list = list
        candidates = list.items.map { Candidate($0) }
        hasReply = true
        filter(query)
    }

    /// Resolved details for an item (documentation, edits), kept for as long as the list is.
    mutating func update(_ item: LSPCompletionItem, at index: Int) {
        guard list.items.indices.contains(index) else { return }
        list.items[index] = item
    }

    mutating func filter(_ query: String) {
        self.query = query
        let needle = Array(query.lowercased().utf16), exact = Array(query.utf16)
        var scored: [(index: Int, score: Int)] = []
        scored.reserveCapacity(min(candidates.count, 512))
        for (index, candidate) in candidates.enumerated() {
            guard let score = CompletionRanker.score(candidate, needle: needle, exact: exact) else { continue }
            scored.append((index, score))
        }
        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            let sa = candidates[a.index].sortKey, sb = candidates[b.index].sortKey
            if sa != sb { return sa < sb }
            return a.index < b.index
        }
        shown = scored.map(\.index)
    }

    /// Which row starts selected: an item the server preselected when nothing's typed yet.
    var initialSelection: Int {
        guard query.isEmpty, let preselected = shown.firstIndex(where: { list.items[$0].preselect }) else { return 0 }
        return preselected
    }
}

/// One item's text, prepared once per reply so filtering a few thousand items a keystroke is
/// cheap.
struct Candidate {
    let lower: [UInt16]
    let exact: [UInt16]
    let sortKey: String

    init(_ item: LSPCompletionItem) {
        let text = item.matchText
        lower = Array(text.lowercased().utf16)
        exact = Array(text.utf16)
        sortKey = item.sortText ?? item.label
    }

    init(text: String) {
        lower = Array(text.lowercased().utf16)
        exact = Array(text.utf16)
        sortKey = text
    }
}

enum CompletionRanker {
    /// How well `needle` (lowercased) matches a candidate as a subsequence; nil if it doesn't.
    /// A prefix beats a match that starts later; matches at word starts (`_x`, `fooBar`'s `B`)
    /// and runs of consecutive characters score higher, as does matching the typed case.
    static func score(_ candidate: Candidate, needle: [UInt16], exact: [UInt16]) -> Int? {
        guard !needle.isEmpty else { return 0 }
        let hay = candidate.lower
        guard hay.count >= needle.count else { return nil }
        var score = 0
        var position = 0
        var previousMatch = -2
        for (k, unit) in needle.enumerated() {
            var found = -1
            while position < hay.count {
                if hay[position] == unit { found = position; break }
                position += 1
            }
            guard found >= 0 else { return nil }
            // Not next to the last match: a later word start (getThing's T for "gT") reads as
            // meant, if the rest of what's typed still fits after it.
            if k > 0, found != previousMatch + 1, !isWordStart(candidate.exact, found) {
                var later = found + 1
                while later < hay.count {
                    if hay[later] == unit, isWordStart(candidate.exact, later) {
                        if isSubsequence(needle[(k + 1)...], of: hay[(later + 1)...]) { found = later }
                        break
                    }
                    later += 1
                }
            }
            if found == 0 { score += 8 }
            if found == previousMatch + 1 { score += 5 }
            if found > 0 && isWordStart(candidate.exact, found) { score += 4 }
            if k < exact.count, candidate.exact[found] == exact[k] { score += 1 }
            score -= min(3, found - previousMatch - 1)
            previousMatch = found
            position = found + 1
        }
        if hay.starts(with: needle) { score += 20 }
        // A shorter name is the likelier one, all else equal.
        score -= min(10, (hay.count - needle.count) / 4)
        return score
    }

    private static func isSubsequence(_ needle: ArraySlice<UInt16>, of hay: ArraySlice<UInt16>) -> Bool {
        var i = needle.startIndex
        for unit in hay where i < needle.endIndex && unit == needle[i] { i += 1 }
        return i == needle.endIndex
    }

    private static func isWordStart(_ text: [UInt16], _ index: Int) -> Bool {
        guard index > 0 else { return true }
        let previous = text[index - 1], current = text[index]
        let underscore: UInt16 = 0x5F
        if previous == underscore || previous == 0x2D || previous == 0x2E { return true }
        return isLower(previous) && isUpper(current)
    }

    private static func isLower(_ unit: UInt16) -> Bool { unit >= 0x61 && unit <= 0x7A }
    private static func isUpper(_ unit: UInt16) -> Bool { unit >= 0x41 && unit <= 0x5A }
}

enum CompletionText {
    /// A word character: what a completion's word is made of.
    static func isWordUnit(_ unit: UInt16) -> Bool {
        (unit >= 0x30 && unit <= 0x39) || (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A) || unit == 0x5F || unit == 0x24 || unit > 0x7F
    }

    /// Where the word ending at `caret` starts.
    static func wordStart(in text: NSString, caret: Int) -> Int {
        var start = min(caret, text.length)
        while start > 0, isWordUnit(text.character(at: start - 1)) { start -= 1 }
        return start
    }

    /// A snippet as plain text (until Alloy has placeholders, step 2): `${1:name}` becomes
    /// `name`, `$1` and `$0` go. Returns the text and where the caret goes in it: the first
    /// tab stop, or the end.
    static func plain(snippet: String) -> (text: String, caret: Int) {
        var out: [UInt16] = []
        var caret: Int?
        let units = Array(snippet.utf16)
        var i = 0
        func isDigit(_ u: UInt16) -> Bool { u >= 0x30 && u <= 0x39 }
        while i < units.count {
            let u = units[i]
            if u == 0x5C, i + 1 < units.count { out.append(units[i + 1]); i += 2; continue }   // \x
            if u == 0x24, i + 1 < units.count {                                                // $
                if isDigit(units[i + 1]) {
                    var j = i + 1
                    while j < units.count, isDigit(units[j]) { j += 1 }
                    if caret == nil { caret = out.count }
                    i = j
                    continue
                }
                if units[i + 1] == 0x7B {                                                      // ${
                    var j = i + 2
                    while j < units.count, isDigit(units[j]) { j += 1 }
                    if j > i + 2, j < units.count, units[j] == 0x3A || units[j] == 0x7C || units[j] == 0x7D {
                        if caret == nil { caret = out.count }
                        if units[j] == 0x7D { i = j + 1; continue }
                        // ${1:default} keeps the default; ${1|a,b|} keeps the first choice.
                        let isChoice = units[j] == 0x7C
                        var k = j + 1, depth = 1
                        var body: [UInt16] = []
                        while k < units.count, depth > 0 {
                            if units[k] == 0x5C, k + 1 < units.count { body.append(units[k + 1]); k += 2; continue }
                            if units[k] == 0x7B { depth += 1 } else if units[k] == 0x7D { depth -= 1; if depth == 0 { break } }
                            body.append(units[k]); k += 1
                        }
                        if isChoice {
                            let choice = body.split(separator: 0x2C, maxSplits: 1).first.map(Array.init) ?? []
                            out += choice.filter { $0 != 0x7C }
                        } else {
                            out += plain(snippet: String(utf16CodeUnits: body, count: body.count)).text.utf16
                        }
                        i = k + 1
                        continue
                    }
                }
            }
            out.append(u)
            i += 1
        }
        return (String(utf16CodeUnits: out, count: out.count), caret ?? out.count)
    }

    /// The words of `texts`, for completing where there's no server: identifiers of three or more
    /// characters, each once, most frequent first. Stops after `limit` UTF-16 units so a huge
    /// file costs a bounded time.
    static func bufferWords(_ texts: [Rope], excluding: String, limit: Int = 2_000_000) -> [String] {
        var counts: [String: Int] = [:]
        var budget = limit
        for text in texts {
            for chunk in text.chunks {
                var word: [UInt16] = []
                for unit in chunk.utf16 {
                    if isWordUnit(unit) { word.append(unit); continue }
                    if word.count >= 3, !isDigit(word[0]) { counts[String(utf16CodeUnits: word, count: word.count), default: 0] += 1 }
                    word.removeAll(keepingCapacity: true)
                }
                // A word split across chunks is counted as its two halves: rare, and harmless.
                if word.count >= 3, !isDigit(word[0]) { counts[String(utf16CodeUnits: word, count: word.count), default: 0] += 1 }
                budget -= chunk.utf16.count
                if budget <= 0 { break }
            }
            if budget <= 0 { break }
        }
        counts[excluding] = nil
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }

    static func isDigit(_ unit: UInt16) -> Bool { unit >= 0x30 && unit <= 0x39 }
}

/// What accepting an item changes, in the text as it is now.
enum CompletionEdits {
    struct Result {
        var all: [(range: NSRange, text: String)]
        var caretAfter: Int
    }

    /// The item's replacement over the word (its server's range if it gave one, stretched over
    /// what was typed since it was asked), and its extra edits (auto-imports) where they don't
    /// overlap. `replacing` uses an insert-or-replace item's replace range. Nil if the ranges
    /// don't make sense any more.
    static func edits(for item: LSPCompletionItem, session: CompletionSession, caret: Int, text: Rope, replacing: Bool) -> Result? {
        var start = session.wordStart
        var end = caret
        var newText = item.insertText ?? item.label
        let requestLine = text.line(containing: session.wordStart)
        let lineStart = text.offset(ofLine: requestLine)
        let requestColumn = session.requestCaret - lineStart
        let typed = caret - session.requestCaret
        /// A position the server counted before the typing since: past its caret on the request's
        /// line, it moved with what was typed; at the caret, it's where typing began.
        func offset(_ position: LSPPosition) -> Int {
            if position.line == requestLine, position.character > requestColumn {
                return lineStart + position.character + typed
            }
            return text.offset(line: position.line, column: position.character)
        }
        if let edit = item.textEdit {
            let range = (replacing ? nil : item.insertRange) ?? edit.range
            start = offset(range.start)
            end = offset(range.end)
            if range.end.line == requestLine, range.end.character == requestColumn { end = caret }
            newText = edit.newText
        }
        guard start <= end, start <= caret, end <= text.utf16Count else { return nil }
        var caretInText = (newText as NSString).length
        if item.insertTextFormat == 2 {
            let plain = CompletionText.plain(snippet: newText)
            newText = plain.text
            caretInText = plain.caret
        }
        let main = (range: NSRange(location: start, length: end - start), text: newText)
        var all = [main]
        var shift = 0
        for extra in item.additionalTextEdits {
            let a = text.offset(line: extra.range.start.line, column: extra.range.start.character)
            let b = text.offset(line: extra.range.end.line, column: extra.range.end.character)
            guard a <= b, b <= start || a >= end else { continue }
            guard !all.contains(where: { NSIntersectionRange($0.range, NSRange(location: a, length: b - a)).length > 0 || $0.range.location == a }) else { continue }
            all.append((NSRange(location: a, length: b - a), extra.newText))
            if b <= start { shift += (extra.newText as NSString).length - (b - a) }
        }
        return Result(all: all, caretAfter: start + shift + caretInText)
    }
}

extension LSPCompletionItem {
    /// A letter and a color for the kind, the way Xcode marks its list.
    var kindBadge: (letter: String, hue: KindHue) {
        switch kind {
        case 2, 3, 4: return ("f", .method)          // method, function, constructor
        case 5, 10: return ("P", .property)          // field, property
        case 6, 12: return ("V", .variable)          // variable, value
        case 7: return ("C", .type)                  // class
        case 8: return ("I", .type)                  // interface
        case 9: return ("M", .module)                // module
        case 13: return ("E", .type)                 // enum
        case 20: return ("e", .constant)             // enum member
        case 21: return ("K", .constant)             // constant
        case 22: return ("S", .type)                 // struct
        case 25: return ("T", .type)                 // type parameter
        case 14: return ("k", .keyword)              // keyword
        case 15: return ("s", .keyword)              // snippet
        case 17, 19: return ("F", .module)           // file, folder
        default: return ("·", .other)
        }
    }

    enum KindHue { case method, property, variable, type, module, constant, keyword, other }
}
