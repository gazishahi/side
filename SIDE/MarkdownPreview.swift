import AlloyCore
import AlloyRender
import AlloySyntax
import AppKit
import Heron

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
        let options = AttributedString.MarkdownParsingOptions(allowsExtendedAttributes: true, interpretedSyntax: .full,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
            return NSAttributedString(string: markdown, attributes: [.font: style.body, .foregroundColor: style.textColor])
        }
        var builder = Builder(style: style)
        for run in parsed.runs {
            builder.add(String(parsed[run.range].characters), intent: run.presentationIntent,
                        inline: run.inlinePresentationIntent ?? [], link: run.link, image: run.imageURL)
        }
        return builder.finish()
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
