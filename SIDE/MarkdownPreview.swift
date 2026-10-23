import AlloyCore
import AlloyRender
import AlloySyntax
import AppKit
import Heron
import SwiftMath

/// Make's Markdown preview: a document to read, not a rendering of the source. CommonMark
/// parsed by Foundation (`AttributedString(markdown:)`, so nesting, emphasis, tables and rules
/// are right), set in the reading font on a centered column, with code blocks as cards colored
/// by Alloy's highlighter, inline code as chips, and quotes with a bar.
///
/// `MarkdownRenderer` stays for Think's bubbles and Instruct's notes, which are chat text.
enum MarkdownPreview {
    struct Style {
        var bodySize: CGFloat
        var textColor: NSColor
        var dark: Bool

        /// Reading text a little larger than code: 16 pt at the editor's standard 14.
        static func current(dark: Bool) -> Style {
            Style(bodySize: (DS.Text.CodeSize.editor * 1.15).rounded(), textColor: .labelColor, dark: dark)
        }
        var body: NSFont { DS.Text.Fonts.font(.reading, size: bodySize) }
        var code: NSFont { DS.Text.Fonts.font(.editor, size: (bodySize * 0.84).rounded()) }
        func heading(_ level: Int) -> NSFont {
            let scale: [CGFloat] = [1.75, 1.4, 1.2, 1.05, 1, 0.92]
            let font = DS.Text.Fonts.font(.reading, size: (bodySize * scale[min(level, 6) - 1]).rounded(), weight: .semibold)
            return NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        }
        /// The widest the text column gets: a comfortable measure for prose.
        var columnWidth: CGFloat { (bodySize * 45).rounded() }
    }

    // What the layout manager draws behind text.
    static let codeBlockKey = NSAttributedString.Key("SidePreviewCodeBlock")
    static let inlineCodeKey = NSAttributedString.Key("SidePreviewInlineCode")
    static let quoteKey = NSAttributedString.Key("SidePreviewQuote")
    static let ruleKey = NSAttributedString.Key("SidePreviewRule")
    static let tableHeaderKey = NSAttributedString.Key("SidePreviewTableHeader")

    /// The indent a code block's card starts at (its text sits `codePadding` inside).
    static let codeCardIndentKey = NSAttributedString.Key("SidePreviewCodeCardIndent")
    static let codePadding: CGFloat = 16
    static let listIndent: CGFloat = 26
    static let quoteIndent: CGFloat = 20

    @MainActor static func render(_ markdown: String, style: Style) -> NSAttributedString {
        // Front matter isn't Markdown: the parser read it as a rule and run-on text. It's split
        // off and shown as a card of properties instead (2026-10-23, the owner).
        let front = frontMatter(markdown)
        // Math out first: Markdown would read its _ and * as emphasis. Each formula leaves a
        // marker, typeset back in once the rest is set.
        let (markdown, formulas) = extractMath(front?.body ?? markdown)
        let options = AttributedString.MarkdownParsingOptions(allowsExtendedAttributes: true, interpretedSyntax: .full,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
            return NSAttributedString(string: markdown, attributes: [.font: style.body, .foregroundColor: style.textColor])
        }
        var builder = Builder(style: style)
        if let front, !front.properties.isEmpty { builder.addProperties(front.properties) }
        for run in parsed.runs {
            builder.add(String(parsed[run.range].characters), intent: run.presentationIntent,
                        inline: run.inlinePresentationIntent ?? [], link: run.link, image: run.imageURL)
        }
        return openedClear(of: typesetMath(formulas, in: builder.finish(), style: style))
    }

    // MARK: Math

    struct Formula: Equatable {
        var latex: String
        var display: Bool
    }

    private static let inlineOpen: Character = "\u{E000}", inlineClose: Character = "\u{E001}"
    private static let displayOpen: Character = "\u{E002}", displayClose: Character = "\u{E003}"

    /// `$…$` and `\(…\)` inline, `$$…$$` and `\[…\]` displayed, each replaced by a marker; never
    /// inside code. An inline `$` opens only before a non-space and closes only after one, and
    /// not before a digit, so prices stay text ("$5 and $10"); `\$` is a dollar.
    static func extractMath(_ markdown: String) -> (String, [Formula]) {
        let chars = Array(markdown)
        var out = "", formulas: [Formula] = []
        var i = 0, inFence = false, atLineStart = true
        func marker(_ formula: Formula) -> String {
            formulas.append(formula)
            let index = String(formulas.count - 1)
            return formula.display ? "\n\n\(displayOpen)\(index)\(displayClose)\n\n" : "\(inlineOpen)\(index)\(inlineClose)"
        }
        /// Where `close` next appears from `start` (before a blank line when `multiline`), or nil.
        func find(_ close: String, from start: Int, multiline: Bool) -> Int? {
            let target = Array(close)
            var j = start
            while j + target.count <= chars.count {
                if chars[j] == "\n" {
                    if !multiline { return nil }
                    if j + 1 < chars.count, chars[j + 1] == "\n" { return nil }
                }
                if chars[j] == "\\", target[0] != "\\" { j += 2; continue }
                if Array(chars[j..<(j + target.count)]) == target { return j }
                j += 1
            }
            return nil
        }
        while i < chars.count {
            let c = chars[i]
            if atLineStart {
                let rest = String(chars[i..<min(chars.count, i + 200)]).drop { $0 == " " }
                if rest.hasPrefix("```") || rest.hasPrefix("~~~") { inFence.toggle() }
            }
            if inFence || c == "\n" {
                out.append(c)
                atLineStart = c == "\n"
                i += 1
                continue
            }
            atLineStart = false
            // Inline code: through its closing run of backticks, untouched.
            if c == "`" {
                var run = 0
                while i + run < chars.count, chars[i + run] == "`" { run += 1 }
                let fence = String(repeating: "`", count: run)
                if let end = find(fence, from: i + run, multiline: true) {
                    out += String(chars[i..<(end + run)])
                    i = end + run
                } else {
                    out += fence
                    i += run
                }
                continue
            }
            if c == "\\", i + 1 < chars.count {
                let next = chars[i + 1]
                if next == "$" { out += "\\$"; i += 2; continue }
                if next == "(" || next == "[", let end = find(next == "(" ? "\\)" : "\\]", from: i + 2, multiline: next == "[") {
                    let latex = String(chars[(i + 2)..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !latex.isEmpty {
                        out += marker(Formula(latex: latex, display: next == "["))
                        i = end + 2
                        continue
                    }
                }
                out.append(c); out.append(next)
                i += 2
                continue
            }
            if c == "$" {
                if i + 1 < chars.count, chars[i + 1] == "$", let end = find("$$", from: i + 2, multiline: true) {
                    let latex = String(chars[(i + 2)..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !latex.isEmpty {
                        out += marker(Formula(latex: latex, display: true))
                        i = end + 2
                        continue
                    }
                }
                if i + 1 < chars.count, !chars[i + 1].isWhitespace, chars[i + 1] != "$" {
                    var j = i + 1
                    var end: Int?
                    while j < chars.count, chars[j] != "\n" {
                        if chars[j] == "\\" { j += 2; continue }
                        if chars[j] == "$" {
                            let after = j + 1 < chars.count ? chars[j + 1] : " "
                            if !chars[j - 1].isWhitespace, !after.isNumber { end = j }
                            break
                        }
                        j += 1
                    }
                    if let end {
                        out += marker(Formula(latex: String(chars[(i + 1)..<end]), display: false))
                        i = end + 1
                        continue
                    }
                }
            }
            out.append(c)
            i += 1
        }
        return (out, formulas)
    }

    /// A typeset formula, kept: a preview sets its text again on every edit.
    private final class Typeset {
        let image: NSImage
        let descent: CGFloat
        init(image: NSImage, descent: CGFloat) { self.image = image; self.descent = descent }
    }
    // NSCache is thread-safe.
    nonisolated(unsafe) private static let typesetCache: NSCache<NSString, Typeset> = { let cache = NSCache<NSString, Typeset>(); cache.countLimit = 500; return cache }()

    /// The markers replaced by their formulas, typeset in Latin Modern at the text's size and
    /// color; a displayed one centered on its own line. One SwiftMath can't read stays as its
    /// source, as code, with the reason on hover.
    static func typesetMath(_ formulas: [Formula], in rendered: NSAttributedString, style: Style) -> NSAttributedString {
        guard !formulas.isEmpty else { return rendered }
        let out = NSMutableAttributedString(attributedString: rendered)
        var color = NSColor.black
        NSAppearance(named: style.dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            color = style.textColor.usingColorSpace(.sRGB) ?? color
        }
        let pattern = try! NSRegularExpression(pattern: "[\u{E000}\u{E002}](\\d+)[\u{E001}\u{E003}]")
        let matches = pattern.matches(in: out.string, range: NSRange(location: 0, length: out.length))
        for match in matches.reversed() {
            guard let index = Int((out.string as NSString).substring(with: match.range(at: 1))), formulas.indices.contains(index) else { continue }
            let formula = formulas[index]
            var attributes = out.attributes(at: match.range.location, effectiveRange: nil)
            attributes[.attachment] = nil
            let size = (formula.display ? style.bodySize * 1.15 : style.bodySize).rounded()
            let key = "\(formula.display)|\(size)|\(style.dark)|\(formula.latex)" as NSString
            var typeset = typesetCache.object(forKey: key)
            var problem: String?
            if typeset == nil {
                var image = MathImage(latex: formula.latex, fontSize: size, textColor: color, labelMode: formula.display ? .display : .text)
                let (error, rendered, layout) = image.asImage()
                if let rendered, error == nil {
                    rendered.accessibilityDescription = formula.latex
                    typeset = Typeset(image: rendered, descent: layout?.descent ?? 0)
                    typesetCache.setObject(typeset!, forKey: key)
                } else {
                    problem = error?.localizedDescription ?? "This formula couldn't be typeset."
                }
            }
            let replacement: NSAttributedString
            if let typeset {
                let attachment = NSTextAttachment()
                attachment.image = typeset.image
                attachment.bounds = NSRect(x: 0, y: -typeset.descent, width: typeset.image.size.width, height: typeset.image.size.height)
                let piece = NSMutableAttributedString(attachment: attachment)
                piece.addAttributes(attributes.filter { $0.key == .paragraphStyle || $0.key == .link }, range: NSRange(location: 0, length: piece.length))
                replacement = piece
            } else {
                var code = attributes
                code[.font] = style.code
                code[inlineCodeKey] = true
                code[.toolTip] = problem
                let source = formula.display ? "$$\(formula.latex)$$" : "$\(formula.latex)$"
                replacement = NSAttributedString(string: source, attributes: code)
            }
            out.replaceCharacters(in: match.range, with: replacement)
            if formula.display {
                let paragraph = (out.string as NSString).paragraphRange(for: NSRange(location: match.range.location, length: 0))
                let centered = ((out.attribute(.paragraphStyle, at: match.range.location, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
                centered.alignment = .center
                centered.paragraphSpacingBefore = max(centered.paragraphSpacingBefore, style.bodySize * 0.4)
                out.addAttribute(.paragraphStyle, value: centered, range: paragraph)
            }
        }
        return out
    }

    /// A card drawn around the document's first paragraph reaches above the text, where nothing
    /// is drawn, and lost its top corners (2026-10-23, the owner): the first paragraph gets no
    /// space before it. A short empty line ahead of the card gives it room.
    static func openedClear(of rendered: NSAttributedString) -> NSAttributedString {
        guard rendered.length > 0, rendered.attribute(codeBlockKey, at: 0, effectiveRange: nil) != nil else { return rendered }
        let spacer = NSMutableParagraphStyle()
        spacer.minimumLineHeight = codePadding
        spacer.maximumLineHeight = codePadding
        let out = NSMutableAttributedString(string: "\n", attributes: [.paragraphStyle: spacer, .font: DS.Text.caption()])
        out.append(rendered)
        return out
    }

    // MARK: Front matter

    struct Property: Equatable {
        var key: String
        var values: [String]
    }

    /// YAML front matter at the very top (`---` lines around it), read as simple properties:
    /// `key: value`, `key: [a, b]`, and `key:` followed by `- item` lines. Anything fancier keeps
    /// its text as the value. Nil when the document doesn't start with front matter.
    static func frontMatter(_ markdown: String) -> (properties: [Property], body: String)? {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.indices.dropFirst().first(where: { ["---", "..."].contains(lines[$0].trimmingCharacters(in: .whitespaces)) }) else { return nil }
        func unquoted(_ text: String) -> String {
            let text = text.trimmingCharacters(in: .whitespaces)
            guard text.count >= 2, let first = text.first, let last = text.last, first == last, first == "\"" || first == "'" else { return text }
            return String(text.dropFirst().dropLast())
        }
        var properties: [Property] = []
        for line in lines[1..<end] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if trimmed.hasPrefix("- "), !properties.isEmpty {
                properties[properties.count - 1].values.append(unquoted(String(trimmed.dropFirst(2))))
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("["), value.hasSuffix("]") {
                let items = value.dropFirst().dropLast().split(separator: ",").map { unquoted(String($0)) }.filter { !$0.isEmpty }
                properties.append(Property(key: key, values: items))
            } else {
                properties.append(Property(key: key, values: value.isEmpty ? [] : [unquoted(value)]))
            }
        }
        return (properties, lines[(end + 1)...].joined(separator: "\n"))
    }

    // MARK: Building

    @MainActor private struct Builder {
        let style: Style
        let out = NSMutableAttributedString()
        private var block: Int?
        private var paragraph = NSParagraphStyle.default
        private var seenItems: Set<Int> = []
        private var itemsInList: [Int: Int] = [:]
        private var codeText = ""
        private var code: (identity: Int, language: String?, indent: CGFloat)?
        private var table: (identity: Int, rows: [[NSAttributedString]], header: Int?, indent: CGFloat)?
        private var cell: (row: Int, column: Int)?
        private var nextCodeBlock = 0
        /// Where the heading being built starts: its anchor slug is its whole text, set when it ends.
        private var headingStart: Int?
        private var previousWasList = false

        init(style: Style) { self.style = style }

        /// The front matter as a card: each key in a quiet column, its value beside it, a list's
        /// items (tags) as chips.
        mutating func addProperties(_ properties: [Property]) {
            let size = (style.bodySize * 0.86).rounded()
            let valueFont = DS.Text.Fonts.font(.reading, size: size)
            let keyFont = DS.Text.Fonts.font(.reading, size: (size * 0.92).rounded(), weight: .medium)
            let padding = MarkdownPreview.codePadding
            let keyColumn = (size * 7.5).rounded()
            for (index, property) in properties.enumerated() {
                let p = NSMutableParagraphStyle()
                p.firstLineHeadIndent = padding
                p.headIndent = padding + keyColumn
                p.tailIndent = -padding
                p.tabStops = [NSTextTab(textAlignment: .left, location: padding + keyColumn)]
                p.lineHeightMultiple = 1.35
                p.paragraphSpacingBefore = index == 0 ? padding : 0
                p.paragraphSpacing = index == properties.count - 1 ? (style.bodySize * 1.2 + padding).rounded() : 2
                let card: [NSAttributedString.Key: Any] = [.paragraphStyle: p, MarkdownPreview.codeBlockKey: -1, MarkdownPreview.codeCardIndentKey: CGFloat(0)]
                let line = NSMutableAttributedString(string: property.key + "\t", attributes: card.merging([.font: keyFont, .foregroundColor: NSColor.secondaryLabelColor]) { $1 })
                if property.values.count > 1 || property.key.lowercased() == "tags" {
                    for (position, value) in property.values.enumerated() {
                        if position > 0 { line.append(NSAttributedString(string: "  ", attributes: card.merging([.font: valueFont]) { $1 })) }
                        line.append(NSAttributedString(string: value.replacingOccurrences(of: " ", with: "\u{00A0}"), attributes: card.merging([
                            .font: valueFont, .foregroundColor: style.textColor, MarkdownPreview.inlineCodeKey: true,
                        ]) { $1 }))
                    }
                } else {
                    line.append(NSAttributedString(string: property.values.first ?? "", attributes: card.merging([.font: valueFont, .foregroundColor: style.textColor]) { $1 }))
                }
                line.append(NSAttributedString(string: "\n", attributes: card.merging([.font: valueFont]) { $1 }))
                out.append(line)
            }
            paragraph = (out.attribute(.paragraphStyle, at: out.length - 1, effectiveRange: nil) as? NSParagraphStyle) ?? paragraph
        }

        mutating func add(_ text: String, intent: PresentationIntent?, inline: InlinePresentationIntent, link: URL?, image: URL?) {
            let components = intent?.components ?? []
            let kinds = components.map(\.kind)

            // A code block collects its text and is set when it ends.
            if let first = components.first, case .codeBlock(let language) = first.kind {
                if code?.identity != first.identity {
                    flushCode()
                    flushTable()
                    endBlock()
                    code = (first.identity, language, indent(for: kinds))
                    block = first.identity
                }
                codeText += text
                return
            }
            flushCode()

            // A table collects its cells and is set when it ends.
            if let tableIndex = kinds.firstIndex(where: { if case .table = $0 { return true }; return false }) {
                let tableIdentity = components[tableIndex].identity
                if table?.identity != tableIdentity {
                    flushTable()
                    endBlock()
                    table = (tableIdentity, [], nil, indent(for: Array(kinds[(tableIndex + 1)...])))
                    block = tableIdentity
                }
                var row = 0, column = 0, isHeader = false
                for kind in kinds {
                    switch kind {
                    case .tableCell(let c): column = c
                    case .tableRow(let r): row = r
                    case .tableHeaderRow: isHeader = true; row = 0
                    default: break
                    }
                }
                // Body rows count from 1 after a header; empty rows are dropped when it's set.
                let rowIndex = isHeader ? 0 : row
                if isHeader { table?.header = 0 }
                while (table?.rows.count ?? 0) <= rowIndex { table?.rows.append([]) }
                while (table?.rows[rowIndex].count ?? 0) <= column { table?.rows[rowIndex].append(NSAttributedString()) }
                let piece = inlineText(text, font: isHeader ? NSFontManager.shared.convert(style.body, toHaveTrait: .boldFontMask) : style.body,
                                       color: style.textColor, inline: inline, link: link, image: image)
                let existing = NSMutableAttributedString(attributedString: table!.rows[rowIndex][column])
                existing.append(piece)
                table?.rows[rowIndex][column] = existing
                return
            }
            flushTable()

            let identity = components.first?.identity ?? -1
            if identity != block {
                endBlock()
                block = identity
                startBlock(components)
            }

            if kinds.contains(where: { if case .thematicBreak = $0 { return true }; return false }) {
                out.append(NSAttributedString(string: "\u{00A0}", attributes: [.font: style.body, .paragraphStyle: paragraph, MarkdownPreview.ruleKey: true]))
                return
            }
            var font = style.body
            var color = style.textColor
            var extra: [NSAttributedString.Key: Any] = [:]
            if let first = components.first, case .header(let level) = first.kind {
                font = style.heading(level)
            }
            if kinds.contains(where: { if case .blockQuote = $0 { return true }; return false }) {
                color = .secondaryLabelColor
                if let quote = components.first(where: { if case .blockQuote = $0.kind { return true }; return false }) {
                    extra[MarkdownPreview.quoteKey] = quote.identity
                }
            }
            // Soft line breaks inside a paragraph read as spaces.
            let piece = NSMutableAttributedString(attributedString: inlineText(text.replacingOccurrences(of: "\n", with: " "), font: font, color: color, inline: inline, link: link, image: image))
            let range = NSRange(location: 0, length: piece.length)
            piece.addAttribute(.paragraphStyle, value: paragraph, range: range)
            for (key, value) in extra { piece.addAttribute(key, value: value, range: range) }
            out.append(piece)
        }

        /// The indent from enclosing lists and quotes.
        private func indent(for kinds: [PresentationIntent.Kind]) -> CGFloat {
            var indent: CGFloat = 0
            for kind in kinds {
                switch kind {
                case .orderedList, .unorderedList: indent += MarkdownPreview.listIndent
                case .blockQuote: indent += MarkdownPreview.quoteIndent
                default: break
                }
            }
            return indent
        }

        private mutating func startBlock(_ components: [PresentationIntent.IntentType]) {
            let kinds = components.map(\.kind)
            let indent = indent(for: kinds)
            let body = style.bodySize
            let p = NSMutableParagraphStyle()
            p.lineHeightMultiple = 1.3
            p.paragraphSpacing = (body * 0.75).rounded()
            p.firstLineHeadIndent = indent
            p.headIndent = indent
            if let first = components.first, case .header(let level) = first.kind {
                p.lineHeightMultiple = 1.15
                p.paragraphSpacingBefore = level <= 2 ? (body * 1.3).rounded() : (body * 0.9).rounded()
                p.paragraphSpacing = (body * 0.45).rounded()
            }
            // A list item's first paragraph carries its marker, hanging in the indent.
            var marker: String?
            if let item = components.first(where: { if case .listItem = $0.kind { return true }; return false }),
               case .listItem(let ordinal) = item.kind, !seenItems.contains(item.identity) {
                seenItems.insert(item.identity)
                let list = components.first { if case .orderedList = $0.kind { return true }; if case .unorderedList = $0.kind { return true }; return false }
                let depth = kinds.filter { if case .orderedList = $0 { return true }; if case .unorderedList = $0 { return true }; return false }.count
                if let list, case .orderedList = list.kind {
                    marker = "\(ordinal)."
                } else {
                    marker = ["•", "◦", "▪︎"][min(depth, 3) - 1]
                }
                p.firstLineHeadIndent = indent - MarkdownPreview.listIndent + 4
                p.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
                p.defaultTabInterval = MarkdownPreview.listIndent
                p.paragraphSpacing = (body * 0.3).rounded()
            } else if kinds.contains(where: { if case .listItem = $0 { return true }; return false }) {
                p.paragraphSpacing = (body * 0.3).rounded()
            }
            // The first block after a list (or a code card's own spacing aside) gets room above it,
            // since list items sit close together.
            let inList = kinds.contains { if case .listItem = $0 { return true }; return false }
            if previousWasList, !inList { p.paragraphSpacingBefore = max(p.paragraphSpacingBefore, (body * 0.5).rounded()) }
            previousWasList = inList
            paragraph = p
            if let first = components.first, case .header = first.kind { headingStart = out.length }
            if let marker {
                out.append(NSAttributedString(string: marker + "\t", attributes: [
                    .font: style.body, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: p,
                ]))
            }
        }

        private mutating func endBlock() {
            if let start = headingStart {
                headingStart = nil
                let range = NSRange(location: start, length: out.length - start)
                out.addAttribute(MarkdownRenderer.anchorSlugKey, value: MarkdownRenderer.anchorSlug(for: out.attributedSubstring(from: range).string), range: range)
            }
            guard block != nil, out.length > 0 else { return }
            out.append(NSAttributedString(string: "\n", attributes: [.font: style.body, .paragraphStyle: paragraph]))
            block = nil
        }

        private func inlineText(_ text: String, font: NSFont, color: NSColor, inline: InlinePresentationIntent, link: URL?, image: URL?) -> NSAttributedString {
            var font = font
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color]
            var text = text
            if inline.contains(.code) {
                font = NSFont(descriptor: style.code.fontDescriptor, size: (font.pointSize * 0.86).rounded()) ?? style.code
                attributes[MarkdownPreview.inlineCodeKey] = true
                // A short span keeps together, so its chip isn't split across a line break.
                if text.count <= 40 { text = text.replacingOccurrences(of: " ", with: "\u{00A0}") }
            }
            if inline.contains(.stronglyEmphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            if inline.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            if inline.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link {
                if link.absoluteString.hasPrefix("#") {
                    attributes[.link] = URL(string: "\(MarkdownRenderer.anchorScheme):\(MarkdownRenderer.anchorSlug(for: String(link.absoluteString.dropFirst())))") as Any
                } else {
                    attributes[.link] = link
                }
            }
            if image != nil {
                text = text.isEmpty ? "image" : text
                attributes[.foregroundColor] = NSColor.secondaryLabelColor
            }
            attributes[.font] = font
            return NSAttributedString(string: text, attributes: attributes)
        }

        /// A code block: its own paragraphs (one per line) inset in a card, colored by Alloy's
        /// highlighter when it knows the fence's language.
        private mutating func flushCode() {
            guard let block = code else { return }
            code = nil
            var source = codeText
            codeText = ""
            if source.hasSuffix("\n") { source.removeLast() }
            let id = nextCodeBlock
            nextCodeBlock += 1
            let lines = source.components(separatedBy: "\n")
            let highlighter = MarkdownPreview.highlighter(for: block.language, text: source, dark: style.dark)
            let padding = MarkdownPreview.codePadding
            for (index, line) in lines.enumerated() {
                let p = NSMutableParagraphStyle()
                p.firstLineHeadIndent = block.indent + padding
                p.headIndent = block.indent + padding
                p.tailIndent = -padding
                p.lineHeightMultiple = 1.2
                p.lineBreakMode = .byCharWrapping
                p.paragraphSpacingBefore = index == 0 ? (style.bodySize * 0.4 + padding).rounded() : 0
                p.paragraphSpacing = index == lines.count - 1 ? (style.bodySize * 0.8 + padding).rounded() : 0
                let piece = NSMutableAttributedString(string: line + (index == lines.count - 1 ? "" : "\n"), attributes: [
                    .font: style.code, .foregroundColor: style.textColor, .paragraphStyle: p,
                    MarkdownPreview.codeBlockKey: id, MarkdownPreview.codeCardIndentKey: block.indent,
                ])
                if let highlighter {
                    let length = (line as NSString).length
                    for span in highlighter.spans(forLine: index) where span.range.upperBound <= length {
                        let c = span.color
                        piece.addAttribute(.foregroundColor, value: NSColor(srgbRed: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: CGFloat(c.w)),
                                           range: NSRange(location: span.range.lowerBound, length: span.range.count))
                    }
                }
                out.append(piece)
            }
            paragraph = (out.attribute(.paragraphStyle, at: out.length - 1, effectiveRange: nil) as? NSParagraphStyle) ?? paragraph
        }

        /// A table: cells on tab stops at their widest, the header bold over a rule.
        private mutating func flushTable() {
            guard var table else { return }
            self.table = nil
            table.rows.removeAll { $0.allSatisfy { $0.length == 0 } }
            let columns = table.rows.map(\.count).max() ?? 0
            var widths = [CGFloat](repeating: 0, count: columns)
            for row in table.rows { for (c, cell) in row.enumerated() { widths[c] = max(widths[c], ceil(cell.size().width)) } }
            var stops: [NSTextTab] = []
            var x = table.indent
            for width in widths.dropLast() { x += width + 28; stops.append(NSTextTab(textAlignment: .left, location: x)) }
            for (r, row) in table.rows.enumerated() {
                let p = NSMutableParagraphStyle()
                p.tabStops = stops
                p.firstLineHeadIndent = table.indent
                p.headIndent = table.indent
                p.lineHeightMultiple = 1.3
                p.paragraphSpacingBefore = r == 0 ? (style.bodySize * 0.3).rounded() : (r == 1 && table.header != nil ? 6 : 0)
                p.paragraphSpacing = r == table.rows.count - 1 ? (style.bodySize * 0.8).rounded() : 4
                let line = NSMutableAttributedString()
                for (c, cell) in row.enumerated() {
                    if c > 0 { line.append(NSAttributedString(string: "\t", attributes: [.font: style.body])) }
                    line.append(cell)
                }
                line.append(NSAttributedString(string: r == table.rows.count - 1 ? "" : "\n", attributes: [.font: style.body]))
                line.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: line.length))
                if r == 0, table.header != nil { line.addAttribute(MarkdownPreview.tableHeaderKey, value: true, range: NSRange(location: 0, length: line.length)) }
                out.append(line)
                paragraph = p
            }
        }

        mutating func finish() -> NSAttributedString {
            flushCode()
            flushTable()
            endBlock()
            return out
        }
    }

    // MARK: Code colors

    /// Fence names people write, to the extensions Alloy knows.
    private static let fenceExtensions: [String: String] = [
        "swift": "swift", "ts": "ts", "typescript": "ts", "tsx": "tsx", "js": "js", "javascript": "js", "jsx": "jsx",
        "py": "py", "python": "py", "rs": "rs", "rust": "rs", "go": "go", "golang": "go", "lua": "lua", "rb": "rb", "ruby": "rb",
        "c": "c", "h": "c", "cpp": "cpp", "c++": "cpp", "cc": "cpp", "json": "json", "jsonc": "json", "md": "md", "markdown": "md",
    ]

    /// Alloy's highlighter for a block, if its language is known and already built (building
    /// one takes ~100 ms, so that happens off the main thread and the preview redraws when done).
    @MainActor fileprivate static func highlighter(for language: String?, text: String, dark: Bool) -> SyntaxHighlighter? {
        guard let language = language?.lowercased().split(separator: " ").first.map(String.init),
              let ext = fenceExtensions[language] else { return nil }
        guard SyntaxLanguage.loaded(forExtension: ext) != nil else {
            pendingLanguages.insert(ext)
            return nil
        }
        return SyntaxHighlighter(fileExtension: ext, text: Rope(text), theme: .side(dark: dark))
    }

    @MainActor private static var pendingLanguages: Set<String> = []

    /// Builds the languages the last render wanted, then calls back (on the main actor) so the
    /// preview can render again, colored. Nothing to build, no call.
    @MainActor static func prepareLanguages(then done: @escaping @MainActor () -> Void) {
        let wanted = pendingLanguages
        pendingLanguages = []
        guard !wanted.isEmpty else { return }
        Task.detached(priority: .userInitiated) {
            for ext in wanted { _ = SyntaxLanguage.forExtension(ext) }
            await MainActor.run { done() }
        }
    }
}

// MARK: - The view

/// The preview's text view: TextKit 1 with `MarkdownPreviewLayoutManager` for the cards and
/// chips, and a column that stays centered at a reading width however wide the window is.
final class MarkdownPreviewTextView: NSTextView {
    var columnWidth: CGFloat = 720 { didSet { centerColumn() } }
    var onAppearanceChange: (() -> Void)?

    static func make() -> MarkdownPreviewTextView {
        let storage = NSTextStorage()
        let layout = MarkdownPreviewLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        let view = MarkdownPreviewTextView(frame: .zero, textContainer: container)
        view.isVerticallyResizable = true
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.autoresizingMask = [.width]
        view.linkTextAttributes = [.foregroundColor: NSColor.controlAccentColor, .cursor: NSCursor.pointingHand]
        return view
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        centerColumn()
    }

    private func centerColumn() {
        let side = max(28, ((bounds.width - columnWidth) / 2).rounded())
        let inset = NSSize(width: side, height: 44)
        if textContainerInset != inset { textContainerInset = inset }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}

/// Draws what the preview's attributes ask for behind the text: code-block cards, inline-code
/// chips, quote bars, rules, and the line under a table's header.
final class MarkdownPreviewLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first, storage.length > 0 else { return }
        let visible = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let whole = NSRange(location: 0, length: storage.length)
        let width = container.size.width

        func lines(_ characters: NSRange) -> (top: CGFloat, bottom: CGFloat)? {
            let glyphs = glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
            guard glyphs.length > 0 else { return nil }
            let first = lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            let last = lineFragmentUsedRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil)
            return (first.minY, last.maxY)
        }

        // Code cards: each block whole, however little of it is on screen.
        var drawn: Set<Int> = []
        storage.enumerateAttribute(MarkdownPreview.codeBlockKey, in: visible) { value, range, _ in
            guard let id = value as? Int, !drawn.contains(id) else { return }
            drawn.insert(id)
            var block = NSRange()
            _ = storage.attribute(MarkdownPreview.codeBlockKey, at: range.location, longestEffectiveRange: &block, in: whole)
            guard let (top, bottom) = lines(block) else { return }
            let indent = storage.attribute(MarkdownPreview.codeCardIndentKey, at: block.location, effectiveRange: nil) as? CGFloat ?? 0
            let pad = MarkdownPreview.codePadding - 4
            let card = NSRect(x: origin.x + indent, y: origin.y + top - pad, width: width - indent, height: bottom - top + pad * 2)
            DS.Color.scrimSoft.setFill()
            NSBezierPath(roundedRect: card, xRadius: DS.Radius.surface, yRadius: DS.Radius.surface).fill()
        }

        // Inline code: a chip behind each piece, per line it spans.
        storage.enumerateAttribute(MarkdownPreview.inlineCodeKey, in: visible) { value, range, _ in
            guard value != nil else { return }
            // Per line, from the glyphs' own bounds: a span that wraps gets a chip on each line,
            // each as wide as its text (not to the line's end).
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, lineGlyphs, _ in
                let piece = NSIntersectionRange(glyphs, lineGlyphs)
                guard piece.length > 0 else { return }
                let rect = self.boundingRect(forGlyphRange: piece, in: container)
                let chip = rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -3, dy: 1)
                DS.Color.scrimSoft.setFill()
                NSBezierPath(roundedRect: chip, xRadius: DS.Radius.control * 0.7, yRadius: DS.Radius.control * 0.7).fill()
            }
        }

        // Quotes: a bar down the left of the whole quote.
        var quotes: Set<Int> = []
        storage.enumerateAttribute(MarkdownPreview.quoteKey, in: visible) { value, range, _ in
            guard let id = value as? Int, !quotes.contains(id) else { return }
            quotes.insert(id)
            var quote = NSRange()
            _ = storage.attribute(MarkdownPreview.quoteKey, at: range.location, longestEffectiveRange: &quote, in: whole)
            guard let (top, bottom) = lines(quote),
                  let style = storage.attribute(.paragraphStyle, at: quote.location, effectiveRange: nil) as? NSParagraphStyle else { return }
            let x = origin.x + style.headIndent - MarkdownPreview.quoteIndent + 2
            NSColor.tertiaryLabelColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: origin.y + top, width: 3, height: bottom - top), xRadius: 1.5, yRadius: 1.5).fill()
        }

        // Rules and the line under a table's header.
        for key in [MarkdownPreview.ruleKey, MarkdownPreview.tableHeaderKey] {
            storage.enumerateAttribute(key, in: visible) { value, range, _ in
                guard value != nil, let (top, bottom) = lines(range) else { return }
                let y = key == MarkdownPreview.ruleKey ? (top + bottom) / 2 : bottom + 3
                DS.Color.hairline.setFill()
                NSRect(x: origin.x, y: (origin.y + y).rounded(), width: width, height: 1).fill()
            }
        }
    }
}
