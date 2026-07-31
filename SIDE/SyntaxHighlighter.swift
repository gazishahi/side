import AppKit

enum SyntaxHighlighter {
    private struct Rule { let regex: NSRegularExpression; let color: NSColor }

    private static let keywordColor = NSColor(calibratedRed: 0.78, green: 0.48, blue: 0.96, alpha: 1)
    private static let stringColor = NSColor(calibratedRed: 0.94, green: 0.60, blue: 0.44, alpha: 1)
    private static let commentColor = NSColor(calibratedWhite: 0.45, alpha: 1)
    private static let numberColor = NSColor(calibratedRed: 0.68, green: 0.80, blue: 0.98, alpha: 1)
    private static let headingColor = NSColor(calibratedRed: 0.55, green: 0.85, blue: 0.65, alpha: 1)

    static let maxHighlightableLength = 2_000_000

    static func apply(to textStorage: NSTextStorage, url: URL, baseColor: NSColor, font: NSFont) {
        let full = NSRange(location: 0, length: textStorage.length)
        textStorage.addAttribute(.foregroundColor, value: baseColor, range: full)
        textStorage.addAttribute(.font, value: font, range: full)
        guard textStorage.length < maxHighlightableLength else { return }
        let text = textStorage.string
        for rule in rules(for: url.pathExtension.lowercased()) {
            rule.regex.enumerateMatches(in: text, range: full) { match, _, _ in
                guard let range = match?.range else { return }
                textStorage.addAttribute(.foregroundColor, value: rule.color, range: range)
            }
        }
    }

    private static func rules(for ext: String) -> [Rule] {
        switch ext {
        case "swift": return codeRules(keywords: swiftKeywords, lineComment: "//", blockComment: true)
        case "ts", "tsx", "js", "jsx", "mjs", "cjs": return codeRules(keywords: jsKeywords, lineComment: "//", blockComment: true)
        case "py": return codeRules(keywords: pyKeywords, lineComment: "#", blockComment: false)
        case "json": return jsonRules
        case "md", "markdown": return markdownRules
        default: return []
        }
    }

    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: options)
    }

    private static func codeRules(keywords: [String], lineComment: String, blockComment: Bool) -> [Rule] {
        var rules: [Rule] = []
        if let r = regex("\\b(\(keywords.joined(separator: "|")))\\b") { rules.append(Rule(regex: r, color: keywordColor)) }
        if let r = regex("\\b\\d+(\\.\\d+)?\\b") { rules.append(Rule(regex: r, color: numberColor)) }
        if let r = regex("\"(?:[^\"\\\\]|\\\\.)*\"|'(?:[^'\\\\]|\\\\.)*'|`(?:[^`\\\\]|\\\\.)*`") { rules.append(Rule(regex: r, color: stringColor)) }
        if let r = regex("\(NSRegularExpression.escapedPattern(for: lineComment)).*$", [.anchorsMatchLines]) { rules.append(Rule(regex: r, color: commentColor)) }
        if blockComment, let r = regex("/\\*[\\s\\S]*?\\*/") { rules.append(Rule(regex: r, color: commentColor)) }
        return rules
    }

    private static var jsonRules: [Rule] {
        var rules: [Rule] = []
        if let r = regex("\"(?:[^\"\\\\]|\\\\.)*\"") { rules.append(Rule(regex: r, color: stringColor)) }
        if let r = regex("\\b-?\\d+(\\.\\d+)?\\b") { rules.append(Rule(regex: r, color: numberColor)) }
        if let r = regex("\\b(true|false|null)\\b") { rules.append(Rule(regex: r, color: keywordColor)) }
        return rules
    }

    private static var markdownRules: [Rule] {
        var rules: [Rule] = []
        if let r = regex("^#{1,6}\\s.*$", [.anchorsMatchLines]) { rules.append(Rule(regex: r, color: headingColor)) }
        if let r = regex("\\*\\*[^*]+\\*\\*") { rules.append(Rule(regex: r, color: keywordColor)) }
        if let r = regex("`[^`]+`") { rules.append(Rule(regex: r, color: stringColor)) }
        if let r = regex("\\[[^\\]]*\\]\\([^)]*\\)") { rules.append(Rule(regex: r, color: numberColor)) }
        return rules
    }

    private static let swiftKeywords = ["func", "let", "var", "if", "else", "guard", "return", "struct", "class", "enum", "protocol", "extension", "import", "private", "public", "internal", "fileprivate", "static", "final", "override", "init", "self", "Self", "nil", "true", "false", "for", "in", "while", "switch", "case", "default", "break", "continue", "throw", "throws", "try", "catch", "do", "async", "await", "weak", "unowned", "typealias", "associatedtype", "where", "as", "is", "some", "any"]
    private static let jsKeywords = ["function", "const", "let", "var", "if", "else", "return", "class", "extends", "import", "export", "from", "default", "new", "this", "null", "undefined", "true", "false", "for", "of", "in", "while", "switch", "case", "break", "continue", "throw", "try", "catch", "finally", "async", "await", "typeof", "instanceof", "interface", "type", "enum", "implements", "public", "private", "protected", "readonly", "static"]
    private static let pyKeywords = ["def", "class", "if", "elif", "else", "return", "import", "from", "as", "for", "while", "break", "continue", "pass", "try", "except", "finally", "raise", "with", "lambda", "None", "True", "False", "and", "or", "not", "in", "is", "yield", "async", "await", "self"]
}
