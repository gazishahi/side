import Foundation

struct CodeSymbol {
    let name: String
    let line: Int
    let kind: String
}

enum SymbolIndexer {
    static func symbols(in text: String, ext: String) -> [CodeSymbol] {
        switch ext {
        case "swift": return extract(text, patterns: swiftPatterns)
        case "ts", "tsx", "js", "jsx", "mjs", "cjs": return extract(text, patterns: jsPatterns)
        case "py": return extract(text, patterns: pyPatterns)
        default: return []
        }
    }

    private struct Pattern { let regex: NSRegularExpression; let kind: String }

    private static func extract(_ text: String, patterns: [Pattern]) -> [CodeSymbol] {
        var results: [CodeSymbol] = []
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        for pattern in patterns {
            pattern.regex.enumerateMatches(in: text, range: full) { match, _, _ in
                guard let match, match.numberOfRanges > 1 else { return }
                let nameRange = match.range(at: 1)
                guard nameRange.location != NSNotFound else { return }
                let name = ns.substring(with: nameRange)
                let line = ns.substring(to: match.range.location).components(separatedBy: "\n").count
                results.append(CodeSymbol(name: name, line: line, kind: pattern.kind))
            }
        }
        return results.sorted { $0.line < $1.line }
    }

    private static func regex(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    }

    private static var swiftPatterns: [Pattern] {
        var patterns: [Pattern] = []
        if let r = regex("\\bfunc\\s+([A-Za-z_]\\w*)") { patterns.append(Pattern(regex: r, kind: "func")) }
        if let r = regex("\\b(?:class|struct|enum|protocol|extension)\\s+([A-Za-z_]\\w*)") { patterns.append(Pattern(regex: r, kind: "type")) }
        if let r = regex("^\\s*(?:static\\s+)?(?:let|var)\\s+([A-Za-z_]\\w*)") { patterns.append(Pattern(regex: r, kind: "property")) }
        return patterns
    }

    private static var jsPatterns: [Pattern] {
        var patterns: [Pattern] = []
        if let r = regex("\\bfunction\\s+([A-Za-z_]\\w*)") { patterns.append(Pattern(regex: r, kind: "func")) }
        if let r = regex("\\bclass\\s+([A-Za-z_]\\w*)") { patterns.append(Pattern(regex: r, kind: "type")) }
        if let r = regex("^\\s*(?:export\\s+)?(?:const|let|var)\\s+([A-Za-z_]\\w*)\\s*=") { patterns.append(Pattern(regex: r, kind: "const")) }
        if let r = regex("^\\s*(?:export\\s+)?(?:async\\s+)?function\\*?\\s*([A-Za-z_]\\w*)\\s*\\(") { patterns.append(Pattern(regex: r, kind: "func")) }
        return patterns
    }

    private static var pyPatterns: [Pattern] {
        var patterns: [Pattern] = []
        if let r = regex("^\\s*def\\s+([A-Za-z_]\\w*)") { patterns.append(Pattern(regex: r, kind: "func")) }
        if let r = regex("^\\s*class\\s+([A-Za-z_]\\w*)") { patterns.append(Pattern(regex: r, kind: "type")) }
        return patterns
    }
}
