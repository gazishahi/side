import AlloyAppKit
import AlloyCore
import AlloyRender
import AlloySyntax
import AppKit
import Heron

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
            return self.delegate?.editor(self, commandClickedAt: offset) ?? false
        }
        applyAppearance(fontChanged: false)
        NotificationCenter.default.addObserver(self, selector: #selector(editorThemeChanged), name: EditorThemes.didChangeNotification, object: nil)
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
        if fontChanged { view.setFont(appearance.font as CTFont) }
        // The chosen editor theme for this appearance (Settings → Appearance), or Side's own.
        if let theme = EditorThemes.current(dark: isDark) {
            view.theme = theme.renderTheme
            view.gutter.backgroundColor = theme.background.nsColor
            view.gutter.numberColor = theme.lineNumbers.nsColor
            view.minimap.backgroundColor = theme.background.nsColor
        } else {
            view.theme = RenderTheme(background: components(appearance.background), text: components(appearance.textColor),
                                     selection: components(.selectedTextBackgroundColor), caret: components(.controlAccentColor),
                                     currentLine: components(DS.Color.scrimFaint))
            view.gutter.backgroundColor = DS.Color.canvas
            view.gutter.numberColor = .tertiaryLabelColor
            view.minimap.backgroundColor = DS.Color.canvas
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
            self.view.setNeedsRender()
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
            view.decorations = []
            return
        }
        view.setBuffer(document.buffer)
        view.styles = { [weak document] line in document?.highlighter?.spans(forLine: line) ?? [] }
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

    private func refreshGutter() {
        var marks: [Int: [GutterMark]] = [:]
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

    func editorTextDidChange(_ editor: AlloyEditorView) { delegate?.editorTextDidChange(self) }
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
