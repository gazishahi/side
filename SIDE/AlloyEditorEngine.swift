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
        }
        // Make tracks "back to what's saved" from its tab's undo manager; Alloy keeps its own
        // history, so it announces undo and redo the way UndoManager does.
        view.onUndoRedo = { [weak self] redo in
            guard let manager = self?.undoManager else { return }
            NotificationCenter.default.post(name: redo ? .NSUndoManagerDidRedoChange : .NSUndoManagerDidUndoChange, object: manager)
        }
        view.onEffectiveAppearanceChange = { [weak self] in self?.applyAppearance(fontChanged: false) }
        view.gutter.onClick = { [weak self] line, event in self?.gutterClicked(line: line, event: event) }
        applyAppearance(fontChanged: false)
    }

    private var isDark: Bool {
        view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

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
        view.theme = RenderTheme(background: components(appearance.background), text: components(appearance.textColor),
                                 selection: components(.selectedTextBackgroundColor), caret: components(.controlAccentColor),
                                 currentLine: components(DS.Color.scrimFaint))
        view.gutter.backgroundColor = DS.Color.canvas
        view.gutter.font = DS.Text.code(11, weight: .regular)
        (document as? AlloyEditorDocument)?.highlighter?.theme = .side(dark: isDark)
        refreshDecorations()
    }

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
            document.highlighter?.theme = .side(dark: self.isDark)
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
        document.highlighter?.theme = .side(dark: isDark)
        refreshDecorations()
    }

    private func refreshDecorations() {
        guard let document = document as? AlloyEditorDocument else { view.decorations = []; return }
        var decorations: [Decoration] = []
        for (kind, marks) in document.decorations {
            for mark in marks {
                decorations.append(Decoration(range: mark.range.location..<(mark.range.location + mark.range.length), color: components(mark.color),
                                              style: kind == .diagnostic ? .dottedUnderline : .background))
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

    /// Outside undo: the history describes the old text. Applied as one edit over what differs,
    /// so an agent's change to one function keeps the rest of the file's layout and colors.
    func replaceAll(with text: String) {
        guard let edit = buffer.replaceAll(with: text) else { return }
        highlighter?.apply([edit], newText: buffer.text)
        decorations = [:]
        onDecorationsChange?()
    }

    /// Tree-sitter for the file's language; it follows edits itself, so this only (re)creates it
    /// when the file's extension changes (a tab saved under a new name). A language not built yet
    /// is built off the main thread first: the text paints now and its colors follow.
    func highlight(url: URL, appearance: EditorAppearance) {
        let ext = url.pathExtension.lowercased()
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
        highlighter = SyntaxHighlighter(fileExtension: ext, text: buffer.text, theme: .side(dark: isDarkProvider()))
        highlighter?.onInvalidate = { [weak self] in self?.onColorsChange?() }
        onHighlighterChange?()
        onColorsChange?()
    }

    func setDecorations(_ kind: EditorDecoration, _ marks: [(range: NSRange, color: NSColor)]) {
        decorations[kind] = marks
        onDecorationsChange?()
    }
}
