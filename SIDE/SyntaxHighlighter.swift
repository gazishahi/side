import AppKit

enum SyntaxHighlighter {
    private struct Rule { let regex: NSRegularExpression; let color: NSColor; var italic: Bool = false; var groupIndex: Int = 0 }

    private static let keywordColor = NSColor(red: 0.78, green: 0.48, blue: 0.96, alpha: 1)
    private static let stringColor = NSColor(red: 0.94, green: 0.60, blue: 0.44, alpha: 1)
    private static let commentColor = DS.Color.comment
    private static let numberColor = NSColor(red: 0.68, green: 0.80, blue: 0.98, alpha: 1)
    private static let headingColor = NSColor(red: 0.55, green: 0.85, blue: 0.65, alpha: 1)
    private static let jsxTagColor = NSColor(red: 0.42, green: 0.82, blue: 0.66, alpha: 1)
    private static let jsxAttrColor = NSColor(red: 0.55, green: 0.75, blue: 0.98, alpha: 1)
    private static let typeColor = NSColor(red: 0.98, green: 0.78, blue: 0.45, alpha: 1)
    private static let functionCallColor = NSColor(red: 0.92, green: 0.87, blue: 0.58, alpha: 1)
    private static let declarationColor = NSColor(red: 0.95, green: 0.82, blue: 0.60, alpha: 1)
    private static let propertyColor = NSColor(red: 0.56, green: 0.82, blue: 0.92, alpha: 1)

    static let maxHighlightableLength = 2_000_000

    struct ColorRun { let range: NSRange; let color: NSColor; let italic: Bool }

    /// Pure regex matching over an immutable String — safe to run on a background queue.
    /// Splitting this out from attribute application is what lets the expensive part of
    /// highlighting (running a dozen-plus regexes over the whole file) happen off the main
    /// thread instead of stalling the UI every time the debounce timer fires.
    nonisolated static func computeRuns(text: String, url: URL) -> [ColorRun] {
        guard text.utf16.count < maxHighlightableLength else { return [] }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var runs: [ColorRun] = []
        for rule in rules(for: url.pathExtension.lowercased()) {
            rule.regex.enumerateMatches(in: text, range: full) { match, _, _ in
                guard let match, match.range(at: rule.groupIndex).location != NSNotFound else { return }
                runs.append(ColorRun(range: match.range(at: rule.groupIndex), color: rule.color, italic: rule.italic))
            }
        }
        return runs
    }

    /// Cheap: just sets precomputed attribute ranges, no regex evaluation. Must run on the main
    /// thread since it mutates a live NSTextStorage.
    static func applyRuns(_ runs: [ColorRun], to textStorage: NSTextStorage, baseColor: NSColor, font: NSFont) {
        // begin/endEditing coalesces the whole batch into one layout+display pass. Without it
        // every addAttribute notified the layout manager separately, which measured at 113ms
        // on a 3,400-line file — roughly seven dropped frames, 200ms after every typing pause.
        textStorage.beginEditing()
        defer { textStorage.endEditing() }
        let full = NSRange(location: 0, length: textStorage.length)
        textStorage.addAttribute(.foregroundColor, value: baseColor, range: full)
        textStorage.addAttribute(.font, value: font, range: full)
        guard textStorage.length < maxHighlightableLength else { return }
        let italicFont = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        for run in runs {
            guard NSMaxRange(run.range) <= textStorage.length else { continue }
            textStorage.addAttribute(.foregroundColor, value: run.color, range: run.range)
            if run.italic { textStorage.addAttribute(.font, value: italicFont, range: run.range) }
        }
    }

    /// Synchronous convenience for the initial-load path, where the file is about to be
    /// displayed anyway and there's no debounce to benefit from splitting the work.
    static func apply(to textStorage: NSTextStorage, url: URL, baseColor: NSColor, font: NSFont) {
        let runs = computeRuns(text: textStorage.string, url: url)
        applyRuns(runs, to: textStorage, baseColor: baseColor, font: font)
    }

    private static func rules(for ext: String) -> [Rule] {
        switch ext {
        case "swift":
            return codeRules(keywords: swiftKeywords, lineComment: "//", blockComment: true)
                + declarationRules(varKeywords: ["let", "var"], funcKeywords: ["func"])
        case "tsx", "jsx":
            return codeRules(keywords: jsKeywords, lineComment: "//", blockComment: true, jsx: true, typeAnnotations: ext == "tsx")
                + declarationRules(varKeywords: ["const", "let", "var"], funcKeywords: ["function"])
        case "ts":
            return codeRules(keywords: jsKeywords, lineComment: "//", blockComment: true, typeAnnotations: true)
                + declarationRules(varKeywords: ["const", "let", "var"], funcKeywords: ["function"])
        case "js", "mjs", "cjs":
            return codeRules(keywords: jsKeywords, lineComment: "//", blockComment: true)
                + declarationRules(varKeywords: ["const", "let", "var"], funcKeywords: ["function"])
        case "py":
            return codeRules(keywords: pyKeywords, lineComment: "#", blockComment: false)
                + declarationRules(varKeywords: [], funcKeywords: ["def"])
        case "rs":
            return codeRules(keywords: rustKeywords, lineComment: "//", blockComment: true)
                + declarationRules(varKeywords: ["let", "const", "static"], funcKeywords: ["fn"])
        case "go":
            return codeRules(keywords: goKeywords, lineComment: "//", blockComment: true)
                + declarationRules(varKeywords: ["var", "const"], funcKeywords: ["func"])
        case "lua":
            return codeRules(keywords: luaKeywords, lineComment: "--", blockComment: false)
                + declarationRules(varKeywords: ["local"], funcKeywords: ["function"])
        case "rb":
            return codeRules(keywords: rubyKeywords, lineComment: "#", blockComment: false)
                + declarationRules(varKeywords: [], funcKeywords: ["def"])
        case "c", "h", "cpp", "hpp", "cc", "cxx":
            return codeRules(keywords: cKeywords, lineComment: "//", blockComment: true)
                + declarationRules(varKeywords: [], funcKeywords: [])
        case "json": return jsonRules
        case "md", "markdown": return markdownRules
        default: return []
        }
    }

    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: options)
    }

    private static func codeRules(keywords: [String], lineComment: String, blockComment: Bool, jsx: Bool = false, typeAnnotations: Bool = false) -> [Rule] {
        var rules: [Rule] = []
        // Lowest precedence first; later rules override earlier ones on overlapping ranges.
        if let r = regex("\\b[A-Za-z_]\\w*(?=\\()") { rules.append(Rule(regex: r, color: functionCallColor)) }
        if let r = regex("\\b[a-zA-Z_]\\w*(?=\\s*:(?!:))") { rules.append(Rule(regex: r, color: propertyColor)) }
        if let r = regex("\\b(\(keywords.joined(separator: "|")))\\b") { rules.append(Rule(regex: r, color: keywordColor)) }
        if let r = regex("\\b\\d+(\\.\\d+)?\\b") { rules.append(Rule(regex: r, color: numberColor)) }
        if typeAnnotations {
            if let r = regex("\\b(string|number|boolean|any|void|unknown|never|object|symbol|bigint)\\b") { rules.append(Rule(regex: r, color: typeColor)) }
            if let r = regex(":\\s*([A-Z]\\w*(?:<[^>]*>)?(?:\\[\\])?)") { rules.append(Rule(regex: r, color: typeColor, groupIndex: 1)) }
        }
        if jsx {
            if let r = regex("</?[A-Za-z][\\w.]*") { rules.append(Rule(regex: r, color: jsxTagColor)) }
            if let r = regex("\\b[a-zA-Z][\\w-]*(?=\\=(\"|\\{))") { rules.append(Rule(regex: r, color: jsxAttrColor)) }
        }
        if let r = regex("\"(?:[^\"\\\\]|\\\\.)*\"|'(?:[^'\\\\]|\\\\.)*'|`(?:[^`\\\\]|\\\\.)*`") { rules.append(Rule(regex: r, color: stringColor)) }
        if let r = regex("\(NSRegularExpression.escapedPattern(for: lineComment)).*$", [.anchorsMatchLines]) { rules.append(Rule(regex: r, color: commentColor, italic: true)) }
        if blockComment, let r = regex("/\\*[\\s\\S]*?\\*/") { rules.append(Rule(regex: r, color: commentColor, italic: true)) }
        return rules
    }

    private static func declarationRules(varKeywords: [String], funcKeywords: [String]) -> [Rule] {
        var rules: [Rule] = []
        if !varKeywords.isEmpty, let r = regex("\\b(?:\(varKeywords.joined(separator: "|")))\\s+([A-Za-z_]\\w*)") {
            rules.append(Rule(regex: r, color: declarationColor, groupIndex: 1))
        }
        for kw in funcKeywords {
            if let r = regex("\\b\(kw)\\s+([A-Za-z_]\\w*)") { rules.append(Rule(regex: r, color: declarationColor, groupIndex: 1)) }
        }
        if let r = regex("\\bclass\\s+([A-Za-z_]\\w*)") { rules.append(Rule(regex: r, color: declarationColor, groupIndex: 1)) }
        return rules
    }

    private static var jsonRules: [Rule] {
        var rules: [Rule] = []
        if let r = regex("\\b-?\\d+(\\.\\d+)?\\b") { rules.append(Rule(regex: r, color: numberColor)) }
        if let r = regex("\\b(true|false|null)\\b") { rules.append(Rule(regex: r, color: keywordColor)) }
        if let r = regex("\"(?:[^\"\\\\]|\\\\.)*\"") { rules.append(Rule(regex: r, color: stringColor)) }
        if let r = regex("\"(?:[^\"\\\\]|\\\\.)*\"(?=\\s*:)") { rules.append(Rule(regex: r, color: propertyColor)) }
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
    private static let rustKeywords = ["fn", "let", "mut", "if", "else", "match", "return", "struct", "enum", "impl", "trait", "pub", "use", "mod", "crate", "self", "Self", "super", "for", "while", "loop", "break", "continue", "true", "false", "None", "Some", "Ok", "Err", "async", "await", "move", "ref", "where", "as", "in", "dyn", "unsafe", "static", "const", "type"]
    private static let goKeywords = ["func", "package", "import", "var", "const", "type", "struct", "interface", "if", "else", "for", "range", "return", "break", "continue", "switch", "case", "default", "go", "defer", "chan", "select", "map", "true", "false", "nil", "iota"]
    private static let luaKeywords = ["function", "local", "if", "then", "else", "elseif", "end", "return", "for", "while", "do", "repeat", "until", "break", "true", "false", "nil", "and", "or", "not", "in"]
    private static let rubyKeywords = ["def", "end", "if", "elsif", "else", "unless", "class", "module", "return", "do", "while", "until", "case", "when", "then", "begin", "rescue", "ensure", "raise", "yield", "self", "nil", "true", "false", "and", "or", "not", "require", "require_relative", "attr_accessor", "private", "public", "protected", "new"]
    private static let cKeywords = ["int", "float", "double", "char", "void", "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "return", "struct", "class", "public", "private", "protected", "namespace", "using", "static", "const", "unsigned", "signed", "long", "short", "typedef", "enum", "union", "template", "virtual", "new", "delete", "this", "true", "false", "nullptr", "auto", "sizeof", "volatile", "extern", "inline", "try", "catch", "throw"]
}
