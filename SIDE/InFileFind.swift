import Foundation

/// Find and replace in one document (the palette's This File mode): the matches for a query
/// with its options, and the edits a replace makes. Works on an `NSString` (Alloy hands out one
/// over its rope without copying), in UTF-16 ranges like the editor.
struct InFileFind: Equatable {
    struct Options: Equatable {
        var caseSensitive = false
        var wholeWord = false
        var regularExpression = false
    }

    var query: String
    var options: Options

    /// Past this, the rest aren't marked or listed; the count says "10,000+".
    static let matchLimit = 10_000

    /// The pattern this query means, or nil for an empty query or an invalid expression.
    func expression() -> NSRegularExpression? {
        guard !query.isEmpty else { return nil }
        var pattern = options.regularExpression ? query : NSRegularExpression.escapedPattern(for: query)
        if options.wholeWord { pattern = "\\b(?:" + pattern + ")\\b" }
        var flags: NSRegularExpression.Options = [.anchorsMatchLines]
        if !options.caseSensitive { flags.insert(.caseInsensitive) }
        return try? NSRegularExpression(pattern: pattern, options: flags)
    }

    /// Why a regular expression doesn't compile, for the header to say.
    func expressionError() -> String? {
        guard options.regularExpression, !query.isEmpty, expression() == nil else { return nil }
        return "Not a valid regular expression"
    }

    struct Result: Equatable {
        var ranges: [NSRange]
        var truncated: Bool
    }

    func matches(in text: NSString) -> Result {
        if let literal = literalMatches(in: text) { return literal }
        guard let expression = expression() else { return Result(ranges: [], truncated: false) }
        // A flat copy for the expression engine, which reads the text a character at a time:
        // through a rope view that's twice as slow, and the copy is a fraction of a millisecond.
        let text = text.copy() as? NSString ?? text
        var ranges: [NSRange] = []
        var truncated = false
        expression.enumerateMatches(in: text as String, options: [], range: NSRange(location: 0, length: text.length)) { match, _, stop in
            guard let match, match.range.length > 0 else { return }
            if ranges.count == Self.matchLimit { truncated = true; stop.pointee = true; return }
            ranges.append(match.range)
        }
        return Result(ranges: ranges, truncated: truncated)
    }

    /// Plain text (not an expression), searched directly over the text's UTF-16: several times
    /// faster than the same search through NSRegularExpression. Nil when that path can't give
    /// the same answer: an expression, or a case-insensitive query with non-ASCII letters
    /// (Unicode case folding is the regex engine's to do).
    private func literalMatches(in text: NSString) -> Result? {
        guard !options.regularExpression, !query.isEmpty else { return nil }
        let needle = Array(query.utf16)
        let folds = !options.caseSensitive
        if folds, needle.contains(where: { $0 > 0x7F }) { return nil }
        func fold(_ c: unichar) -> unichar { folds && c >= 0x41 && c <= 0x5A ? c + 32 : c }
        let pattern = needle.map(fold)
        let length = text.length, m = pattern.count
        /// A word character as `\b` sees one: letters, digits, marks, the underscore.
        func isWordChar(_ c: unichar) -> Bool {
            if c < 0x80 { return (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F }
            guard let scalar = Unicode.Scalar(c) else { return true } // half of a pair: a letter outside the BMP, most likely
            return CharacterSet.alphanumerics.contains(scalar) || CharacterSet.nonBaseCharacters.contains(scalar)
        }
        // `\b` beside a query that starts or ends in punctuation means something else; the
        // expression engine handles that.
        if options.wholeWord, !(isWordChar(pattern[0]) && isWordChar(pattern[m - 1])) { return nil }
        guard m <= length else { return Result(ranges: [], truncated: false) }
        // The text in chunks, each overlapping the last by the needle's length, so a match
        // across a chunk's edge is found once.
        // Horspool's skip table over the folded needle's last byte-sized values.
        var skip = [Int](repeating: m, count: 256)
        for i in 0..<(m - 1) { skip[Int(pattern[i] & 0xFF)] = m - 1 - i }
        var ranges: [NSRange] = []
        var nextAllowed = 0
        let chunk = 1 << 16
        var buffer = [unichar](repeating: 0, count: chunk + m + 1)
        var base = 0
        while base <= length - m {
            let count = min(chunk + m + 1, length - base)
            buffer.withUnsafeMutableBufferPointer { text.getCharacters($0.baseAddress!, range: NSRange(location: base, length: count)) }
            // Matches starting in this chunk (the overlap's belong to the next); one character
            // before and after each is loaded too, for the whole-word test.
            let lastStart = min(count - m, chunk - 1)
            var i = 0
            while i <= lastStart {
                let tail = fold(buffer[i + m - 1])
                if tail == pattern[m - 1] {
                    var j = 0
                    while j < m - 1, fold(buffer[i + j]) == pattern[j] { j += 1 }
                    if j == m - 1 {
                        var whole = true
                        if options.wholeWord {
                            let before: unichar? = i > 0 ? buffer[i - 1] : (base > 0 ? text.character(at: base - 1) : nil)
                            let after: unichar? = i + m < count ? buffer[i + m] : nil
                            whole = !(before.map(isWordChar) ?? false) && !(after.map(isWordChar) ?? false)
                        }
                        // Matches don't overlap: one running into this chunk from the last
                        // rules out any that start inside it.
                        if whole, base + i >= nextAllowed {
                            if ranges.count == Self.matchLimit { return Result(ranges: ranges, truncated: true) }
                            ranges.append(NSRange(location: base + i, length: m))
                            nextAllowed = base + i + m
                            i += m
                            continue
                        }
                    }
                }
                i += skip[Int(tail & 0xFF)]
            }
            base += chunk
        }
        return Result(ranges: ranges, truncated: false)
    }

    /// What a match is replaced with: the template's `$1`… filled in for a regular expression,
    /// the text as typed otherwise.
    func replacement(for range: NSRange, in text: NSString, template: String) -> String {
        guard options.regularExpression, let expression = expression(),
              let match = expression.firstMatch(in: text as String, options: [], range: range) else { return template }
        return expression.replacementString(for: match, in: text as String, offset: 0, template: template)
    }

    /// Replace All: every match, as edits in the text as it stands (applied as one step).
    func replaceAllEdits(in text: NSString, template: String) -> [(range: NSRange, text: String)] {
        matches(in: text).ranges.map { ($0, replacement(for: $0, in: text, template: template)) }
    }

    /// The match at or after `location` (wrapping to the first), or before it (wrapping to the last).
    static func index(of ranges: [NSRange], from location: Int, forward: Bool) -> Int? {
        guard !ranges.isEmpty else { return nil }
        if forward {
            return ranges.firstIndex { $0.location >= location } ?? 0
        }
        return ranges.lastIndex { $0.location < location } ?? ranges.count - 1
    }

    /// The query to prefill from a selection: one line of it, if it's short.
    static func query(fromSelection selection: String) -> String? {
        guard !selection.isEmpty, selection.count <= 200, !selection.contains("\n") else { return nil }
        return selection
    }
}
