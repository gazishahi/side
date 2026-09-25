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
        guard let expression = expression() else { return Result(ranges: [], truncated: false) }
        var ranges: [NSRange] = []
        var truncated = false
        expression.enumerateMatches(in: text as String, options: [], range: NSRange(location: 0, length: text.length)) { match, _, stop in
            guard let match, match.range.length > 0 else { return }
            if ranges.count == Self.matchLimit { truncated = true; stop.pointee = true; return }
            ranges.append(match.range)
        }
        return Result(ranges: ranges, truncated: truncated)
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
