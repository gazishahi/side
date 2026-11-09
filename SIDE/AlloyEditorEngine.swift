import AlloyAppKit
import AlloyCore
import AlloyRender
import AlloySyntax
import AppKit
import SideAgents
import SwiftMath

/// Make's editor (SIDE_RFC_ALLOY.md): Alloy behind the `EditorEngine` seam.
@MainActor
final class AlloyEditorEngine: NSObject, EditorEngine, AlloyEditorDelegate {
    weak var delegate: EditorEngineDelegate?
    let view: AlloyEditorView
    private(set) var document: EditorDocument?
    private var undoManager: UndoManager?

    var containerView: NSView { view }
    var scrollView: NSScrollView { view.scrollView }
    var gutterView: NSView { view.gutter }
    var textView: NSView { view.textView }

    var appearance: EditorAppearance {
        didSet { applyAppearance(fontChanged: oldValue.font != appearance.font) }
    }

    /// Live Markdown (docs/SIDE_RFC_LIVE_MARKDOWN.md, step 1): prose in the reading font, at the
    /// preview's size, with bold, italic and code spans laid out in their own fonts.
    var isProse = false { didSet { if isProse != oldValue { applyProse() } } }
    private var proseFonts: [UInt8: CTFont] = [:]
    /// Live Markdown's blocks (pictures, rules, tables, front matter), and an edit count they
    /// follow.
    private let blocks = LiveMarkdownBlocks()
    private var textGeneration = 0

    /// The reading size the Markdown preview uses: a little larger than code.
    static var proseSize: CGFloat { (DS.Text.CodeSize.editor * 1.15).rounded() }

    private func applyProse() {
        proseFonts = [:]
        if isProse {
            view.setFont(DS.Text.Fonts.font(.reading, size: Self.proseSize) as CTFont)
            view.fontSpans = { [weak self] line in self?.proseSpans(line) ?? [] }
            view.concealment = { [weak self] line in self?.proseHidden(line) ?? [] }
            view.inlineReplacements = { [weak self] line in self?.proseReplacements(line) ?? [] }
        } else {
            view.inlineReplacements = nil
            view.concealment = nil
            view.fontSpans = nil
            view.setFont(appearance.font as CTFont)
        }
        applyLineBackground()
    }

    /// A line's emphasis, as font runs over the reading font.
    private func proseSpans(_ line: Int) -> [FontSpan] {
        guard let highlighter = (document as? AlloyEditorDocument)?.highlighter else { return [] }
        // Neighbors in the same font are one run (hiding splits `**bold**` into three spans).
        var runs: [(range: Range<Int>, emphasis: Emphasis)] = []
        for span in highlighter.spans(forLine: line) {
            let emphasis = span.emphasis.subtracting(.concealed)
            guard !emphasis.isEmpty else { continue }
            if let last = runs.last, last.range.upperBound == span.range.lowerBound, last.emphasis == emphasis {
                runs[runs.count - 1].range = last.range.lowerBound..<span.range.upperBound
            } else {
                runs.append((span.range, emphasis))
            }
        }
        return runs.map { FontSpan(range: $0.range, font: proseFont($0.emphasis)) }
    }

    /// The debugger's stopped line, and Live Markdown's front matter band.
    private func applyLineBackground() {
        let stopped = stoppedLine.map { ($0, components(DS.Color.statusVerified.withAlphaComponent(0.22))) }
        guard stopped != nil || isProse else { view.lineBackground = nil; return }
        view.lineBackground = { [weak self] line in
            if let stopped, stopped.0 == line { return stopped.1 }
            guard let self, self.isProse, let document = self.document as? AlloyEditorDocument, let context = self.blockContext else { return nil }
            return self.blocks.tint(line: line, text: document.buffer.text, context: context)
        }
    }

    /// What Live Markdown's blocks are drawn for: the column, the screen, the text's font and color.
    private var blockContext: LiveMarkdownBlocks.Context? {
        guard let document = document as? AlloyEditorDocument else { return nil }
        let layout = view.documentLayout
        let column = layout.wrapWidth ?? max(200, view.scrollView.contentView.bounds.width - layout.insets.width * 2)
        let text = view.theme.text
        return LiveMarkdownBlocks.Context(documentURL: document.url, columnWidth: column, scale: view.window?.backingScaleFactor ?? 2,
                                          appearance: view.effectiveAppearance, font: DS.Text.Fonts.font(.reading, size: Self.proseSize),
                                          lineHeight: layout.lineHeight,
                                          textColor: NSColor(srgbRed: CGFloat(text.x), green: CGFloat(text.y), blue: CGFloat(text.z), alpha: CGFloat(text.w)))
    }

    /// A line's replacements in Live Markdown: a block for the whole line (a picture, a rule),
    /// or a table's padding and the line's math.
    private func proseReplacements(_ line: Int) -> [InlineReplacement] {
        guard let document = document as? AlloyEditorDocument, let context = blockContext else { return [] }
        blocks.textChanged(textGeneration)
        let text = document.buffer.text
        let lineText = text.substring(text.range(ofLine: line))
        let block = blocks.replacements(line: line, lineText: lineText, text: text, context: context)
        if block.whole { return block.items }
        return (block.items + proseMath(line, columnWidth: context.columnWidth)).sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// A typeset formula, kept: lines are laid out again as the caret moves.
    private struct Formula {
        let image: CGImage
        let size: CGSize
        let descent: CGFloat
    }
    private var formulas: [String: Formula?] = [:]

    /// The line's TeX math (`$…$` inline, `$$…$$` displayed), typeset (step 4): drawn in its
    /// place away from the caret, in Latin Modern at the text's size and color, as the preview
    /// sets it. A formula SwiftMath can't read stays as its source.
    private func proseMath(_ line: Int, columnWidth: CGFloat) -> [InlineReplacement] {
        guard let document = document as? AlloyEditorDocument, let highlighter = document.highlighter else { return [] }
        var ranges: [Range<Int>] = []
        for span in highlighter.spans(forLine: line) where span.emphasis.contains(.math) {
            if let last = ranges.last, last.upperBound == span.range.lowerBound {
                ranges[ranges.count - 1] = last.lowerBound..<span.range.upperBound
            } else {
                ranges.append(span.range)
            }
        }
        guard !ranges.isEmpty else { return [] }
        let text = document.buffer.text
        let lineText = text.substring(text.range(ofLine: line)) as NSString
        let scale = view.window?.backingScaleFactor ?? 2
        let color = view.theme.text
        return ranges.compactMap { range in
            guard range.upperBound <= lineText.length else { return nil }
            let source = lineText.substring(with: NSRange(location: range.lowerBound, length: range.count))
            // Math that starts and ends on this line: a block running over lines stays source.
            guard source.count >= 3, source.hasPrefix("$"), source.hasSuffix("$") else { return nil }
            let display = source.hasPrefix("$$") && source.hasSuffix("$$") && source.count >= 5
            // Prices aren't math (the preview's rule): an inline $ opens before a non-space and
            // closes after one, not before a digit ("$5 to $10").
            if !display {
                let units = Array(source.utf16)
                let after = range.upperBound < lineText.length ? lineText.character(at: range.upperBound) : 0x20
                func space(_ unit: UInt16) -> Bool { unit == 0x20 || unit == 0x09 }
                if space(units[1]) || space(units[units.count - 2]) || (0x30...0x39).contains(after) { return nil }
            }
            let latex = String(source.dropFirst(display ? 2 : 1).dropLast(display ? 2 : 1)).trimmingCharacters(in: .whitespaces)
            guard !latex.isEmpty else { return nil }
            let size = (Self.proseSize * (display ? 1.15 : 1)).rounded()
            let key = "\(display)|\(size)|\(scale)|\(color)|\(latex)"
            let formula: Formula?
            if let known = formulas[key] {
                formula = known
            } else {
                formula = Self.typeset(latex, size: size, display: display, scale: scale,
                                       color: NSColor(srgbRed: CGFloat(color.x), green: CGFloat(color.y), blue: CGFloat(color.z), alpha: CGFloat(color.w)))
                if formulas.count > 500 { formulas.removeAll() }
                formulas[key] = formula
            }
            guard let formula else { return nil }
            // A displayed formula alone on its line: centered in the column.
            if display, range.lowerBound == 0, range.upperBound == lineText.length, formula.size.width < columnWidth {
                return InlineReplacement(range: range, image: formula.image, size: CGSize(width: columnWidth, height: formula.size.height),
                                         descent: formula.descent, key: key, drawSize: formula.size)
            }
            return InlineReplacement(range: range, image: formula.image, size: formula.size, descent: formula.descent, key: key)
        }
    }

    private static func typeset(_ latex: String, size: CGFloat, display: Bool, scale: CGFloat, color: NSColor) -> Formula? {
        var math = MathImage(latex: latex, fontSize: size, textColor: color, labelMode: display ? .display : .text)
        let (error, image, layout) = math.asImage()
        guard error == nil, let image, image.size.width > 0, image.size.height > 0 else { return nil }
        let width = Int(ceil(image.size.width * scale)), height = Int(ceil(image.size.height * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        context.scaleBy(x: scale, y: scale)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        guard let pixels = context.makeImage() else { return nil }
        return Formula(image: pixels, size: image.size, descent: layout?.descent ?? 0)
    }

    /// The markup a line hides away from the caret (step 3): `**`, `` ` ``, a link's URL, a
    /// heading's `#` with the space after it.
    private func proseHidden(_ line: Int) -> [Range<Int>] {
        guard let document = document as? AlloyEditorDocument, let highlighter = document.highlighter else { return [] }
        var ranges: [Range<Int>] = []
        for span in highlighter.spans(forLine: line) where span.emphasis.contains(.concealed) {
            if let last = ranges.last, last.upperBound == span.range.lowerBound {
                ranges[ranges.count - 1] = last.lowerBound..<span.range.upperBound
            } else {
                ranges.append(span.range)
            }
        }
        // A heading's marker takes the space after it along.
        if let first = ranges.first, first.lowerBound == 0 {
            let text = document.buffer.text
            let units = Array(text.substring(text.range(ofLine: line)).utf16)
            if units.first == 0x23 {  // #
                var end = first.upperBound
                while end < units.count, units[end] == 0x20 { end += 1 }
                ranges[0] = 0..<end
            }
        }
        return ranges
    }

    /// A heading's size against the text's, by level: the Markdown preview's scale.
    static let headingScale: [CGFloat] = [1.75, 1.4, 1.2, 1.05, 1, 0.92]

    /// The reading font with an emphasis: bold, italic, a heading's size, or code (the editor's
    /// font, a touch smaller, as inline code is in the preview).
    func proseFont(_ emphasis: Emphasis) -> CTFont {
        if let known = proseFonts[emphasis.rawValue] { return known }
        let level = emphasis.headingLevel
        let size = (Self.proseSize * (level > 0 ? Self.headingScale[level - 1] : 1)).rounded()
        var font: NSFont = emphasis.contains(.code) ? DS.Text.Fonts.font(.editor, size: (size * 0.88).rounded()) : DS.Text.Fonts.font(.reading, size: size)
        if emphasis.contains(.bold) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        if emphasis.contains(.italic) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        proseFonts[emphasis.rawValue] = font as CTFont
        return font as CTFont
    }

    init(appearance: EditorAppearance) {
        self.appearance = appearance
        // TextRenderer needs a Metal device; every Mac Side runs on has one.
        view = try! AlloyEditorView(buffer: TextBuffer(""), font: appearance.font as CTFont)
        super.init()
        view.delegate = self
        view.isEditable = false
        view.onTextChange = { [weak self] change in
            // A replacement updates its document's highlighter itself (shown or not).
            guard let self, change.reason != .replace, let document = self.document as? AlloyEditorDocument else { return }
            document.highlighter?.apply(change.edits, newText: document.buffer.text)
            document.onEdits?(change.edits)
        }
        // Make tracks "back to what's saved" from its tab's undo manager; Alloy keeps its own
        // history, so it announces undo and redo the way UndoManager does.
        view.onUndoRedo = { [weak self] redo in
            guard let manager = self?.undoManager else { return }
            NotificationCenter.default.post(name: redo ? .NSUndoManagerDidRedoChange : .NSUndoManagerDidUndoChange, object: manager)
        }
        view.onEffectiveAppearanceChange = { [weak self] in self?.applyAppearance(fontChanged: false) }
        view.gutter.onClick = { [weak self] line, event in self?.gutterClicked(line: line, event: event) }
        view.gutter.onNumberClick = { [weak self] line, event in
            guard let self else { return }
            self.delegate?.editor(self, clickedLineNumber: line, event: event)
        }
        view.onPointerMove = { [weak self] offset, modifiers in
            guard let self else { return }
            self.delegate?.editor(self, pointerAt: offset, modifiers: modifiers)
        }
        view.onPointerExit = { [weak self] in
            guard let self else { return }
            self.delegate?.editorPointerExited(self)
        }
        // Expand Selection grows through the syntax tree's nodes.
        view.onExpandSelection = { [weak self] range in
            (self?.document as? AlloyEditorDocument)?.highlighter?.enclosingRange(of: range)
        }
        view.onCommandClick = { [weak self] offset in
            guard let self else { return false }
            // Live Markdown: ⌘-click a remote picture's placeholder to load it.
            if self.isProse, let document = self.document as? AlloyEditorDocument {
                let text = document.buffer.text
                let line = text.substring(text.range(ofLine: text.line(containing: offset)))
                if let url = self.blocks.remoteAddress(line) { self.blocks.loadRemote(url); return true }
            }
            return self.delegate?.editor(self, commandClickedAt: offset) ?? false
        }
        blocks.onChange = { [weak self] in self?.view.stylesChanged() }
        applyAppearance(fontChanged: false)
        NotificationCenter.default.addObserver(self, selector: #selector(editorThemeChanged), name: EditorThemes.didChangeNotification, object: nil)
        // The accent (the caret) and the interface theme (the background) change without a change
        // of appearance.
        NotificationCenter.default.addObserver(self, selector: #selector(editorThemeChanged), name: DS.Appearance.didChangeNotification, object: nil)
    }

    /// The system's appearance: what picks the editor theme (Make's own view may take the
    /// theme's appearance for its chrome, which mustn't pick the other one).
    private var isDark: Bool { DS.Appearance.isDark }

    /// Resolves an NSColor for the view's light or dark appearance.
    private func components(_ color: NSColor) -> SIMD4<Float> {
        var resolved = color
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB) ?? color
        }
        return [Float(resolved.redComponent), Float(resolved.greenComponent), Float(resolved.blueComponent), Float(resolved.alphaComponent)]
    }

    private func applyAppearance(fontChanged: Bool) {
        if fontChanged { isProse ? applyProse() : view.setFont(appearance.font as CTFont) }
        // The chosen editor theme for this appearance (Settings → Appearance), or Side's own.
        // Translucent background takes the editor's alpha from DS.Translucency.editor.
        if let theme = EditorThemes.current(dark: isDark) {
            let background = DS.Translucency.editor(theme.background.nsColor)
            var renderTheme = theme.renderTheme
            renderTheme.background = components(background)
            view.theme = renderTheme
            view.gutter.backgroundColor = background
            view.gutter.numberColor = theme.lineNumbers.nsColor
            view.minimap.backgroundColor = background
        } else {
            view.theme = RenderTheme(background: components(appearance.background), text: components(appearance.textColor),
                                     selection: components(.selectedTextBackgroundColor), caret: components(DS.Color.accent),
                                     currentLine: components(DS.Color.scrimFaint))
            view.gutter.backgroundColor = DS.Translucency.editor(DS.Color.canvas)
            view.gutter.numberColor = .tertiaryLabelColor
            view.minimap.backgroundColor = DS.Translucency.editor(DS.Color.canvas)
        }
        view.gutter.font = DS.Text.code(11, weight: .regular)
        (document as? AlloyEditorDocument)?.highlighter?.theme = EditorThemes.syntax(dark: isDark)
        refreshDecorations()
    }

    @objc private func editorThemeChanged() { applyAppearance(fontChanged: false) }

    // MARK: Documents

    func makeDocument(_ text: String) -> EditorDocument {
        let document = AlloyEditorDocument(text)
        document.onDecorationsChange = { [weak self, weak document] in
            guard let self, let document, self.document === document else { return }
            self.refreshDecorations()
        }
        document.onColorsChange = { [weak self, weak document] in
            guard let self, let document, self.document === document else { return }
            self.view.stylesChanged()
        }
        document.onHighlighterChange = { [weak self, weak document] in
            guard let self, let document, self.document === document else { return }
            document.highlighter?.theme = EditorThemes.syntax(dark: self.isDark)
        }
        document.isDarkProvider = { [weak self] in self?.isDark ?? false }
        return document
    }

    func attach(_ document: EditorDocument?, undoManager: UndoManager?) {
        self.document = document
        self.undoManager = undoManager
        guard let document = document as? AlloyEditorDocument else {
            view.setBuffer(TextBuffer(""))
            view.styles = nil
            view.prepareStyles = nil
            view.decorations = []
            return
        }
        view.setBuffer(document.buffer)
        view.styles = { [weak document] line in document?.highlighter?.spans(forLine: line) ?? [] }
        view.prepareStyles = { [weak document] lines in document?.highlighter?.prepare(lines: lines) }
        document.highlighter?.theme = EditorThemes.syntax(dark: isDark)
        refreshDecorations()
    }

    private func refreshDecorations() {
        guard let document = document as? AlloyEditorDocument else { view.decorations = []; return }
        var decorations: [Decoration] = []
        // Drawn in this order, so the match Find is on sits over the others.
        let order: [EditorDecoration] = [.bracketMatch, .findMatch, .findCurrent, .diagnostic, .link]
        // Marks of a kind mostly share a color: converted once, not once per mark.
        var converted: [ObjectIdentifier: SIMD4<Float>] = [:]
        for kind in order {
            for mark in document.decorations[kind] ?? [] {
                let key = ObjectIdentifier(mark.color)
                let color = converted[key] ?? components(mark.color)
                converted[key] = color
                decorations.append(Decoration(range: mark.range.location..<(mark.range.location + mark.range.length), color: color,
                                              style: kind == .diagnostic ? .dottedUnderline : (kind == .link ? .underline : .background)))
            }
        }
        view.decorations = decorations
    }

    // MARK: The view

    var isEditable: Bool {
        get { view.isEditable }
        set { view.isEditable = newValue }
    }

    var selectedRange: NSRange {
        get {
            let range = view.buffer.selections.first?.range ?? 0..<0
            return NSRange(location: range.lowerBound, length: range.count)
        }
        set { view.setSelections([Selection(anchor: newValue.location, head: newValue.location + newValue.length)]) }
    }

    var visibleRect: NSRect { view.textView.visibleRect }

    func scrollRangeToVisible(_ range: NSRange) { view.scrollToVisible(offset: range.location) }

    func setLanguage(lineComment: String?, indentUnit: String) {
        view.lineComment = lineComment
        view.indentUnit = indentUnit
    }

    func centerRange(_ range: NSRange) {
        let line = view.rect(forCharacterRange: range.location..<range.location)
        let viewport = view.viewport
        // Already comfortably on screen: leave the view where it is.
        if line.minY >= viewport.minY + viewport.height * 0.15, line.maxY <= viewport.maxY - viewport.height * 0.15 { return }
        view.scrollY = line.midY - viewport.height / 2
    }

    func rect(forCharacterRange range: NSRange) -> NSRect {
        view.rect(forCharacterRange: range.location..<(range.location + range.length))
    }

    func screenRect(forCharacterRange range: NSRange) -> NSRect? {
        let rect = view.textView.firstRect(forCharacterRange: range, actualRange: nil)
        return rect == .zero ? nil : rect
    }

    func insertText(_ text: String, replacementRange: NSRange) {
        view.textView.insertText(text, replacementRange: replacementRange)
    }

    func insertSnippet(_ snippet: Snippet, replacing range: NSRange, alsoApplying extra: [(range: NSRange, text: String)]) {
        view.insert(snippet, replacing: range.location..<NSMaxRange(range),
                    alsoApplying: extra.map { TextEdit(range: $0.range.location..<NSMaxRange($0.range), text: $0.text) })
    }

    func applyEdits(_ edits: [(range: NSRange, text: String)]) {
        guard !edits.isEmpty else { return }
        view.buffer.apply(edits.map { TextEdit(range: $0.range.location..<($0.range.location + $0.range.length), text: $0.text) }, kind: .other)
    }

    func focus() { view.window?.makeFirstResponder(view.textView) }

    var lineDiffMarks: [Int: GitDiffMark] = [:] { didSet { refreshGutter() } }
    var lineDiagnostics: [Int: LSPDiagnosticSeverity] = [:] { didSet { refreshGutter() } }

    var lineBreakpoints: [Int: (enabled: Bool, verified: Bool)] = [:] { didSet { refreshGutter() } }

    var stoppedLine: Int? {
        didSet {
            guard stoppedLine != oldValue else { return }
            applyLineBackground()
        }
    }

    private func refreshGutter() {
        var marks: [Int: [GutterMark]] = [:]
        for (line, breakpoint) in lineBreakpoints {
            marks[line, default: []].append(GutterMark(style: .breakpoint(enabled: breakpoint.enabled, verified: breakpoint.verified), color: .systemBlue))
        }
        for (line, mark) in lineDiffMarks {
            switch mark {
            case .added: marks[line, default: []].append(GutterMark(style: .bar, color: DS.Color.statusVerified))
            case .modified: marks[line, default: []].append(GutterMark(style: .bar, color: DS.Color.statusNeedsYou))
            case .removedBefore: marks[line, default: []].append(GutterMark(style: .notch, color: DS.Color.statusFailed))
            }
        }
        for (line, severity) in lineDiagnostics {
            let color: NSColor
            switch severity {
            case .error: color = DS.Color.statusFailed
            case .warning: color = DS.Color.statusNeedsYou
            case .information, .hint: color = .tertiaryLabelColor
            }
            marks[line, default: []].append(GutterMark(style: .dot, color: color))
        }
        view.gutter.marks = marks
    }

    /// A diagnostic on the line wins over a change mark.
    private func gutterClicked(line: Int, event: NSEvent) {
        if let severity = lineDiagnostics[line] {
            delegate?.editor(self, clickedDiagnostic: severity, line: line, event: event)
        } else if let mark = lineDiffMarks[line] {
            delegate?.editor(self, clickedDiffMark: mark, line: line, event: event)
        }
    }

    func invalidateGutter() { view.gutter.needsDisplay = true }
    func setNeedsDisplay() { view.setNeedsRender() }

    // MARK: AlloyEditorDelegate, forwarded

    func editor(_ editor: AlloyEditorView, shouldChangeTextIn range: Range<Int>, replacementString: String) -> Bool {
        delegate?.editor(self, shouldChangeTextIn: NSRange(location: range.lowerBound, length: range.count), replacementString: replacementString) ?? true
    }

    func editor(_ editor: AlloyEditorView, doCommandBy selector: Selector) -> Bool {
        delegate?.editor(self, doCommandBy: selector) ?? false
    }

    func editorTextDidChange(_ editor: AlloyEditorView) {
        textGeneration += 1
        delegate?.editorTextDidChange(self)
    }
    func editorSelectionDidChange(_ editor: AlloyEditorView) { delegate?.editorSelectionDidChange(self) }

    func editor(_ editor: AlloyEditorView, menu: NSMenu, forCharacterAt offset: Int) -> NSMenu {
        guard delegate != nil else { return menu }
        let item = NSMenuItem(title: "Jump to Definition", action: #selector(jumpToDefinition(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = offset
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
        return menu
    }

    @objc private func jumpToDefinition(_ sender: NSMenuItem) {
        guard let offset = sender.representedObject as? Int else { return }
        delegate?.editor(self, definitionRequestedAt: offset)
    }
}

/// A tab's text on Alloy: a `TextBuffer` (with its own undo history) and its tree-sitter
/// highlighter, plus the marks Make draws on it.
@MainActor
final class AlloyEditorDocument: EditorDocument {
    let buffer: TextBuffer
    private(set) var highlighter: SyntaxHighlighter?
    private var highlightedExtension: String?
    private(set) var decorations: [EditorDecoration: [(range: NSRange, color: NSColor)]] = [:]
    var onDecorationsChange: (() -> Void)?
    var onColorsChange: (() -> Void)?
    /// A highlighter arrived after the document was shown (its language was still building).
    var onHighlighterChange: (() -> Void)?
    var isDarkProvider: () -> Bool = { false }
    /// Where the file is (Live Markdown finds its pictures from here).
    private(set) var url: URL?

    init(_ text: String) { buffer = TextBuffer(text) }

    var string: String { buffer.string }
    var text: NSString { RopeString.make(buffer.text) }
    var length: Int { buffer.text.utf16Count }
    var rope: Rope { buffer.text }
    var syntaxSymbols: SyntaxSymbolSource? { highlighter?.symbolSource() }
    var onEdits: (([AppliedEdit]) -> Void)?

    /// Outside undo: the history describes the old text. Applied as one edit over what differs,
    /// so an agent's change to one function keeps the rest of the file's layout and colors.
    func replaceAll(with text: String) {
        guard let edit = buffer.replaceAll(with: text) else { return }
        highlighter?.apply([edit], newText: buffer.text)
        onEdits?([edit])
        decorations = [:]
        onDecorationsChange?()
    }

    /// Tree-sitter for the file's language; it follows edits itself, so this only (re)creates it
    /// when the file's extension changes (a tab saved under a new name). A language not built yet
    /// is built off the main thread first: the text paints now and its colors follow.
    func highlight(url: URL, appearance: EditorAppearance) {
        self.url = url
        let ext = url.languageExtension
        guard ext != highlightedExtension else { return }
        highlightedExtension = ext
        guard SyntaxLanguage.supports(ext) else { highlighter = nil; onColorsChange?(); return }
        guard SyntaxLanguage.loaded(forExtension: ext) != nil else {
            highlighter = nil
            Task.detached(priority: .userInitiated) {
                _ = SyntaxLanguage.forExtension(ext)
                await MainActor.run { [weak self] in
                    guard let self, self.highlightedExtension == ext, self.highlighter == nil else { return }
                    self.makeHighlighter(ext)
                }
            }
            return
        }
        makeHighlighter(ext)
    }

    private func makeHighlighter(_ ext: String) {
        highlighter = SyntaxHighlighter(fileExtension: ext, text: buffer.text, theme: EditorThemes.syntax(dark: isDarkProvider()))
        highlighter?.onInvalidate = { [weak self] in self?.onColorsChange?() }
        onHighlighterChange?()
        onColorsChange?()
    }

    func applyEdits(_ edits: [(range: NSRange, text: String)]) {
        let textEdits = edits.map { TextEdit(range: $0.range.location..<NSMaxRange($0.range), text: $0.text) }
        // Shown, the editor hears the change and passes it on; not shown, it's passed on here.
        guard buffer.onChange == nil else { return buffer.apply(textEdits, kind: .other) }
        var applied: [AppliedEdit] = []
        buffer.onChange = { applied += $0.edits }
        buffer.apply(textEdits, kind: .other)
        buffer.onChange = nil
        guard !applied.isEmpty else { return }
        highlighter?.apply(applied, newText: buffer.text)
        onEdits?(applied)
    }

    func setDecorations(_ kind: EditorDecoration, _ marks: [(range: NSRange, color: NSColor)]) {
        decorations[kind] = marks
        onDecorationsChange?()
    }
}
