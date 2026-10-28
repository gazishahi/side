import AlloyRender
import AlloySyntax
import AppKit

/// A color as themes write it ("#RRGGBB", "#RRGGBBAA", "#RGB"), kept as RGBA.
struct ThemeColor: Codable, Equatable, Sendable {
    var r: Float, g: Float, b: Float, a: Float

    init(_ r: Float, _ g: Float, _ b: Float, _ a: Float = 1) { self.r = r; self.g = g; self.b = b; self.a = a }

    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("#") else { return nil }
        text.removeFirst()
        if text.count == 3 || text.count == 4 { text = text.map { "\($0)\($0)" }.joined() }
        guard text.count == 6 || text.count == 8, let value = UInt64(text, radix: 16) else { return nil }
        let hasAlpha = text.count == 8
        let v = hasAlpha ? value : (value << 8 | 0xFF)
        self.init(Float((v >> 24) & 0xFF) / 255, Float((v >> 16) & 0xFF) / 255, Float((v >> 8) & 0xFF) / 255, Float(v & 0xFF) / 255)
    }

    var simd: SIMD4<Float> { [r, g, b, a] }
    var nsColor: NSColor { NSColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a)) }
    /// Over `background`, as an opaque color (a theme's translucent selection, for a view that
    /// can't blend).
    func over(_ background: ThemeColor) -> ThemeColor {
        ThemeColor(r * a + background.r * (1 - a), g * a + background.g * (1 - a), b * a + background.b * (1 - a), 1)
    }
    var luminance: Float { 0.2126 * r + 0.7152 * g + 0.0722 * b }
}

/// An editor theme (SIDE_RFC_IDE_ESSENTIALS.md, L6): the editor's colors, the syntax colors by
/// tree-sitter capture, and optionally the terminal's. Side's own theme isn't one of these: it
/// follows the design tokens and the system appearance.
struct EditorTheme: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var isDark: Bool
    var background: ThemeColor
    var text: ThemeColor
    var selection: ThemeColor
    var caret: ThemeColor
    var currentLine: ThemeColor
    var lineNumbers: ThemeColor
    var syntax: [String: ThemeColor]
    var terminalBackground: ThemeColor?
    var terminalText: ThemeColor?
    /// The sixteen ANSI colors, normal then bright; nil to keep Side's.
    var ansi: [ThemeColor]?

    var renderTheme: RenderTheme {
        RenderTheme(background: background.simd, text: text.simd, selection: selection.simd, caret: caret.simd, currentLine: currentLine.simd)
    }

    var syntaxTheme: SyntaxTheme { SyntaxTheme(colors: syntax.mapValues(\.simd)) }
}

/// The themes Side has and which one each appearance uses.
@MainActor
enum EditorThemes {
    static let didChangeNotification = Notification.Name("SideEditorThemeDidChange")
    /// Side's own: the design tokens, light or dark with the system.
    static let sideID = "side"
    private static let lightKey = "SideEditorThemeLight", darkKey = "SideEditorThemeDark"

    static var defaults: UserDefaults { MakeWorkspaceViewController.preferences }

    /// The theme chosen for light and for dark appearance (Side's own unless chosen).
    static var lightThemeID: String {
        get { defaults.string(forKey: lightKey) ?? sideID }
        set { defaults.set(newValue, forKey: lightKey); announce() }
    }
    static var darkThemeID: String {
        get { defaults.string(forKey: darkKey) ?? sideID }
        set { defaults.set(newValue, forKey: darkKey); announce() }
    }

    /// The theme in use for an appearance; nil means Side's own.
    static func current(dark: Bool) -> EditorTheme? {
        let id = dark ? darkThemeID : lightThemeID
        guard id != sideID else { return nil }
        return all.first { $0.id == id }
    }

    /// The syntax colors for an appearance: the theme's, or Side's own.
    static func syntax(dark: Bool) -> SyntaxTheme { current(dark: dark)?.syntaxTheme ?? .side(dark: dark) }

    /// A dark theme in light appearance (or the other way round): the appearance Side's own
    /// views over the editor take, so their labels read on the theme's background. Nil when the
    /// theme matches the system, or Side's own is in use.
    static func chromeAppearance() -> NSAppearance? {
        let systemDark = DS.Appearance.isDark
        guard let theme = current(dark: systemDark), theme.isDark != systemDark else { return nil }
        return NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
    }

    static var all: [EditorTheme] { builtIn + imported }

    private static func announce() { NotificationCenter.default.post(name: didChangeNotification, object: nil) }

    // MARK: Imported themes, kept in Application Support

    private static var storeURL: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Side", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(NSClassFromString("XCTestCase") == nil ? "Themes.json" : "Themes.tests.\(ProcessInfo.processInfo.processIdentifier).json")
    }

    private static var cached: [EditorTheme]?

    static var imported: [EditorTheme] {
        get {
            if let cached { return cached }
            let loaded = (try? Data(contentsOf: storeURL)).flatMap { try? JSONDecoder().decode([EditorTheme].self, from: $0) } ?? []
            cached = loaded
            return loaded
        }
        set {
            cached = newValue
            try? JSONEncoder().encode(newValue).write(to: storeURL, options: .atomic)
            announce()
        }
    }

    /// Imports a VS Code theme file, replacing an earlier import of the same name. Returns it.
    @discardableResult
    static func importVSCodeTheme(_ data: Data, fallbackName: String) throws -> EditorTheme {
        let theme = try VSCodeTheme.parse(data, fallbackName: fallbackName)
        imported = imported.filter { $0.id != theme.id } + [theme]
        return theme
    }

    static func remove(_ id: String) {
        imported = imported.filter { $0.id != id }
        if lightThemeID == id { lightThemeID = sideID }
        if darkThemeID == id { darkThemeID = sideID }
    }

    // MARK: Built in

    /// A palette's roles, spread over the captures Side's grammars use.
    static func syntax(keyword: String, string: String, comment: String, number: String, type: String,
                       function: String, property: String, tag: String, heading: String, escape: String? = nil) -> [String: ThemeColor] {
        func c(_ hex: String) -> ThemeColor { ThemeColor(hex: hex)! }
        var colors: [String: ThemeColor] = [:]
        for capture in ["keyword", "conditional", "repeat", "include", "exception", "storageclass", "label", "attribute",
                        "charset", "import", "media", "keyframes", "supports"] { colors[capture] = c(keyword) }
        for capture in ["string", "character", "string.regex", "text.literal", "markup.raw"] { colors[capture] = c(string) }
        for capture in ["comment", "spell"] { colors[capture] = c(comment) }
        for capture in ["number", "float", "constant.numeric", "constant", "constant.builtin", "boolean", "variable.builtin"] { colors[capture] = c(number) }
        for capture in ["type", "type.builtin", "constructor", "namespace", "module"] { colors[capture] = c(type) }
        for capture in ["function", "method", "function.method", "function.call", "function.macro"] { colors[capture] = c(function) }
        for capture in ["property", "field", "variable.member", "variable.parameter", "parameter", "tag.attribute", "text.uri", "markup.link", "text.reference"] { colors[capture] = c(property) }
        colors["tag"] = c(tag)
        for capture in ["text.title", "markup.heading", "punctuation.special"] { colors[capture] = c(heading) }
        for capture in ["escape", "string.escape"] { colors[capture] = c(escape ?? number) }
        return colors
    }

    private static func ansi(_ hex: [String]) -> [ThemeColor] { hex.compactMap(ThemeColor.init(hex:)) }

    static let builtIn: [EditorTheme] = [
        EditorTheme(id: "github-light", name: "GitHub Light", isDark: false,
                    background: ThemeColor(hex: "#ffffff")!, text: ThemeColor(hex: "#1f2328")!, selection: ThemeColor(hex: "#b6d7ff")!,
                    caret: ThemeColor(hex: "#0969da")!, currentLine: ThemeColor(hex: "#eaeef280")!, lineNumbers: ThemeColor(hex: "#8c959f")!,
                    syntax: syntax(keyword: "#cf222e", string: "#0a3069", comment: "#6e7781", number: "#0550ae", type: "#953800",
                                   function: "#8250df", property: "#0550ae", tag: "#116329", heading: "#0550ae"),
                    terminalBackground: ThemeColor(hex: "#ffffff")!, terminalText: ThemeColor(hex: "#1f2328")!,
                    ansi: ansi(["#24292f", "#cf222e", "#116329", "#4d2d00", "#0969da", "#8250df", "#1b7c83", "#6e7781",
                                "#57606a", "#a40e26", "#1a7f37", "#633c01", "#218bff", "#a475f9", "#3192aa", "#8c959f"])),
        EditorTheme(id: "github-dark", name: "GitHub Dark", isDark: true,
                    background: ThemeColor(hex: "#0d1117")!, text: ThemeColor(hex: "#e6edf3")!, selection: ThemeColor(hex: "#264f78")!,
                    caret: ThemeColor(hex: "#58a6ff")!, currentLine: ThemeColor(hex: "#6e76811a")!, lineNumbers: ThemeColor(hex: "#6e7681")!,
                    syntax: syntax(keyword: "#ff7b72", string: "#a5d6ff", comment: "#8b949e", number: "#79c0ff", type: "#ffa657",
                                   function: "#d2a8ff", property: "#79c0ff", tag: "#7ee787", heading: "#1f6feb"),
                    terminalBackground: ThemeColor(hex: "#0d1117")!, terminalText: ThemeColor(hex: "#e6edf3")!,
                    ansi: ansi(["#484f58", "#ff7b72", "#3fb950", "#d29922", "#58a6ff", "#bc8cff", "#39c5cf", "#b1bac4",
                                "#6e7681", "#ffa198", "#56d364", "#e3b341", "#79c0ff", "#d2a8ff", "#56d4dd", "#ffffff"])),
        EditorTheme(id: "one-dark", name: "One Dark", isDark: true,
                    background: ThemeColor(hex: "#282c34")!, text: ThemeColor(hex: "#abb2bf")!, selection: ThemeColor(hex: "#3e4451")!,
                    caret: ThemeColor(hex: "#528bff")!, currentLine: ThemeColor(hex: "#2c313c")!, lineNumbers: ThemeColor(hex: "#636d83")!,
                    syntax: syntax(keyword: "#c678dd", string: "#98c379", comment: "#7f848e", number: "#d19a66", type: "#e5c07b",
                                   function: "#61afef", property: "#e06c75", tag: "#e06c75", heading: "#e06c75", escape: "#56b6c2"),
                    terminalBackground: ThemeColor(hex: "#282c34")!, terminalText: ThemeColor(hex: "#abb2bf")!,
                    ansi: ansi(["#3f4451", "#e06c75", "#98c379", "#e5c07b", "#61afef", "#c678dd", "#56b6c2", "#d7dae0",
                                "#4f5666", "#be5046", "#a5e075", "#d19a66", "#4dc4ff", "#de73ff", "#4cd1e0", "#e6e6e6"])),
    ]
}

/// A VS Code color theme (its `.json`) as an editor theme: `colors` for the editor and terminal,
/// `tokenColors` (TextMate scopes) mapped onto tree-sitter captures.
enum VSCodeTheme {
    enum ImportError: LocalizedError {
        case notATheme
        var errorDescription: String? { "That file isn't a VS Code color theme (no colors or tokenColors)." }
    }

    /// For each capture, the TextMate scopes that color it, most fitting first.
    static let scopes: [String: [String]] = [
        "keyword": ["keyword.control", "keyword", "storage.type", "storage"],
        "conditional": ["keyword.control.conditional", "keyword.control", "keyword"],
        "repeat": ["keyword.control.loop", "keyword.control", "keyword"],
        "include": ["keyword.control.import", "keyword.control", "keyword"],
        "exception": ["keyword.control.exception", "keyword.control", "keyword"],
        "storageclass": ["storage.modifier", "storage", "keyword"],
        "label": ["entity.name.label", "keyword"],
        "boolean": ["constant.language.boolean", "constant.language", "constant"],
        "constant.builtin": ["constant.language", "support.constant", "constant"],
        "constant": ["variable.other.constant", "constant.other", "constant"],
        "number": ["constant.numeric", "constant"], "float": ["constant.numeric", "constant"], "constant.numeric": ["constant.numeric", "constant"],
        "string": ["string.quoted", "string"], "character": ["constant.character", "string"],
        "string.regex": ["string.regexp", "string"],
        "escape": ["constant.character.escape", "constant.character"], "string.escape": ["constant.character.escape", "constant.character"],
        "comment": ["comment"], "spell": ["comment"],
        "type": ["entity.name.type", "support.type", "storage.type"], "type.builtin": ["support.type", "entity.name.type", "storage.type"],
        "constructor": ["entity.name.class", "entity.name.type"],
        "namespace": ["entity.name.namespace", "entity.name.type"], "module": ["entity.name.module", "entity.name.namespace", "entity.name.type"],
        "function": ["entity.name.function", "support.function"], "function.call": ["entity.name.function", "support.function"],
        "method": ["entity.name.function.member", "entity.name.function"], "function.method": ["entity.name.function.member", "entity.name.function"],
        "function.macro": ["entity.name.function.preprocessor", "entity.name.function"],
        "property": ["variable.other.property", "variable.other.object.property", "support.type.property-name", "meta.object-literal.key", "variable.other.member"],
        "field": ["variable.other.property", "variable.other.member", "support.type.property-name"],
        "variable.member": ["variable.other.member", "variable.other.property"],
        "variable.parameter": ["variable.parameter"], "parameter": ["variable.parameter"],
        "variable.builtin": ["variable.language", "support.variable"],
        "tag": ["entity.name.tag"], "tag.attribute": ["entity.other.attribute-name"], "attribute": ["entity.other.attribute-name", "storage.type.annotation"],
        "text.title": ["markup.heading", "entity.name.section"], "markup.heading": ["markup.heading", "entity.name.section"],
        "punctuation.special": ["punctuation.definition.heading", "markup.heading"],
        "text.literal": ["markup.inline.raw", "markup.raw", "string"], "markup.raw": ["markup.inline.raw", "markup.raw", "string"],
        "text.uri": ["markup.underline.link", "string.other.link"], "markup.link": ["markup.underline.link", "string.other.link"],
        "text.reference": ["string.other.link", "markup.underline.link"],
        "charset": ["keyword.control.at-rule", "keyword"], "import": ["keyword.control.at-rule", "keyword"],
        "media": ["keyword.control.at-rule", "keyword"], "keyframes": ["keyword.control.at-rule", "keyword"], "supports": ["keyword.control.at-rule", "keyword"],
    ]

    static func parse(_ data: Data, fallbackName: String) throws -> EditorTheme {
        guard let source = String(data: data, encoding: .utf8),
              let object = try? JSONSerialization.jsonObject(with: Data(stripJSONC(source).utf8)) as? [String: Any],
              object["colors"] != nil || object["tokenColors"] != nil else { throw ImportError.notATheme }
        let colors = (object["colors"] as? [String: Any] ?? [:]).compactMapValues { ($0 as? String).flatMap(ThemeColor.init(hex:)) }
        let background = colors["editor.background"] ?? ThemeColor(hex: "#1e1e1e")!
        let isDark: Bool = {
            switch (object["type"] as? String)?.lowercased() {
            case "light", "hc-light": return false
            case "dark", "hc", "hc-black": return true
            default: return background.luminance < 0.5
            }
        }()
        let text = colors["editor.foreground"] ?? colors["foreground"] ?? (isDark ? ThemeColor(hex: "#d4d4d4")! : ThemeColor(hex: "#1f1f1f")!)
        // The editor draws selections under the text, so a translucent one is fine as it is.
        let selection = colors["editor.selectionBackground"] ?? ThemeColor(text.r, text.g, text.b, 0.25)
        let caret = colors["editorCursor.foreground"] ?? text
        let currentLine = colors["editor.lineHighlightBackground"] ?? ThemeColor(text.r, text.g, text.b, 0.05)
        let lineNumbers = colors["editorLineNumber.foreground"] ?? ThemeColor(text.r, text.g, text.b, 0.45)

        // Token rules, in order (a later equal rule wins, as in VS Code); a rule's scope may be a
        // list, comma-separated, or an array. Descendant selectors ("meta.x entity.y") are too
        // contextual for a tree-sitter capture and are skipped.
        var rules: [(scope: String, color: ThemeColor)] = []
        for entry in object["tokenColors"] as? [[String: Any]] ?? [] {
            guard let settings = entry["settings"] as? [String: Any], let hex = settings["foreground"] as? String,
                  let color = ThemeColor(hex: hex) else { continue }
            let scopeList: [String]
            if let scope = entry["scope"] as? String { scopeList = scope.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
            else if let scopes = entry["scope"] as? [String] { scopeList = scopes.flatMap { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } } }
            else { continue }
            for scope in scopeList where !scope.isEmpty && !scope.contains(" ") { rules.append((scope, color)) }
        }
        var syntax: [String: ThemeColor] = [:]
        for (capture, candidates) in scopes {
            for candidate in candidates {
                // The most specific rule that covers the candidate scope; ties go to the later.
                var best: (length: Int, color: ThemeColor)?
                for rule in rules where candidate == rule.scope || candidate.hasPrefix(rule.scope + ".") {
                    if best == nil || rule.scope.count >= best!.length { best = (rule.scope.count, rule.color) }
                }
                if let best { syntax[capture] = best.color; break }
            }
        }
        let ansiNames = ["Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White"]
        let ansiKeys = ansiNames.map { "terminal.ansi\($0)" } + ansiNames.map { "terminal.ansiBright\($0)" }
        let ansi = ansiKeys.compactMap { colors[$0] }
        let name = (object["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName
        return EditorTheme(id: "vscode:" + name.lowercased().replacingOccurrences(of: " ", with: "-"), name: name, isDark: isDark,
                           background: background, text: text, selection: selection, caret: caret, currentLine: currentLine,
                           lineNumbers: lineNumbers, syntax: syntax,
                           terminalBackground: colors["terminal.background"] ?? background, terminalText: colors["terminal.foreground"] ?? text,
                           ansi: ansi.count == 16 ? ansi : nil)
    }

    /// VS Code themes are JSON with comments and trailing commas.
    static func stripJSONC(_ text: String) -> String {
        var out: [Character] = []
        var inString = false, escaped = false
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            let next = text.index(after: i) < text.endIndex ? text[text.index(after: i)] : nil
            if inString {
                out.append(c)
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                i = text.index(after: i)
                continue
            }
            if c == "\"" { inString = true; out.append(c); i = text.index(after: i); continue }
            if c == "/", next == "/" {
                while i < text.endIndex, text[i] != "\n" { i = text.index(after: i) }
                continue
            }
            if c == "/", next == "*" {
                i = text.index(i, offsetBy: 2, limitedBy: text.endIndex) ?? text.endIndex
                while i < text.endIndex {
                    if text[i] == "*", text.index(after: i) < text.endIndex, text[text.index(after: i)] == "/" { i = text.index(i, offsetBy: 2); break }
                    i = text.index(after: i)
                }
                continue
            }
            out.append(c)
            i = text.index(after: i)
        }
        // Trailing commas: a comma followed (past whitespace) by } or ].
        var result: [Character] = []
        var k = 0
        var inStr = false, esc = false
        while k < out.count {
            let c = out[k]
            if inStr {
                if esc { esc = false } else if c == "\\" { esc = true } else if c == "\"" { inStr = false }
                result.append(c); k += 1; continue
            }
            if c == "\"" { inStr = true }
            if c == "," {
                var j = k + 1
                while j < out.count, out[j].isWhitespace { j += 1 }
                if j < out.count, out[j] == "}" || out[j] == "]" { k += 1; continue }
            }
            result.append(c)
            k += 1
        }
        return String(result)
    }
}
