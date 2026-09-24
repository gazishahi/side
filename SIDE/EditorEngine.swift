import AppKit
import Heron

// MARK: - The seam (SIDE_RFC_ALLOY.md, step 0)

/// Every way Make touches its editor, named. Today `TextKitEditorEngine` (an `NSTextView`)
/// implements it; Alloy will implement the same thing, and Make switches without knowing.
///
/// Ranges are UTF-16 `NSRange`s throughout, because that's what LSP positions, `NSString` and
/// AppKit's text input all speak. Alloy's rope keeps UTF-16 counts for exactly this.
@MainActor
protocol EditorEngine: AnyObject, Sendable {
    var delegate: EditorEngineDelegate? { get set }

    /// What Make lays out: the scrolling text, and the line-number gutter beside it.
    var scrollView: NSScrollView { get }
    var gutterView: NSView { get }
    /// The view that takes focus, anchors popovers and hosts overlays that scroll with the text.
    var textView: NSView { get }

    /// A new document this engine can show (a tab's text).
    func makeDocument(_ text: String) -> EditorDocument
    /// Shows a document, with the tab's own undo stack; nil shows nothing.
    func attach(_ document: EditorDocument?, undoManager: UndoManager?)
    var document: EditorDocument? { get }

    var appearance: EditorAppearance { get set }
    var isEditable: Bool { get set }
    var selectedRange: NSRange { get set }
    var visibleRect: NSRect { get }

    func scrollRangeToVisible(_ range: NSRange)
    /// Where a range sits in `textView`'s coordinates.
    func rect(forCharacterRange range: NSRange) -> NSRect
    /// Where a range sits on screen (the completion panel's anchor), or nil if it isn't laid out.
    func screenRect(forCharacterRange range: NSRange) -> NSRect?
    /// Inserts as if typed: undoable, and reported to the delegate like any other edit.
    func insertText(_ text: String, replacementRange: NSRange)
    func focus()

    // The gutter's marks, keyed by one-based line.
    var lineDiffMarks: [Int: GitDiffMark] { get set }
    var lineDiagnostics: [Int: LSPDiagnosticSeverity] { get set }
    func invalidateGutter()
    /// Redraws what depends on the selection (the current-line band).
    func setNeedsDisplay()
}

/// A tab's text. Owned by the tab, shown by an engine.
@MainActor
protocol EditorDocument: AnyObject, Sendable {
    var string: String { get }
    /// UTF-16 length.
    var length: Int { get }
    /// Replaces everything outside the undo stack (loading, reloading, applying an agent's edit,
    /// format on save).
    func replaceAll(with text: String)
    /// Colors the whole document now.
    func highlight(url: URL, appearance: EditorAppearance)
    /// Applies colors computed off the main thread.
    func applyHighlight(_ runs: [SyntaxHighlighter.ColorRun], appearance: EditorAppearance)
    /// Replaces one kind of decoration everywhere in the document.
    func setDecorations(_ kind: EditorDecoration, _ marks: [(range: NSRange, color: NSColor)])
}

enum EditorDecoration {
    /// A dotted underline in the diagnostic's color.
    case diagnostic
    /// A background tint on a matched bracket pair.
    case bracketMatch
}

struct EditorAppearance {
    var font: NSFont
    var textColor: NSColor
    var background: NSColor
}

/// What the editor tells Make.
@MainActor
protocol EditorEngineDelegate: AnyObject {
    func editorTextDidChange(_ engine: EditorEngine)
    func editorSelectionDidChange(_ engine: EditorEngine)
    /// A typed change is about to happen; false to handle it yourself (auto-pairing).
    func editor(_ engine: EditorEngine, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool
    /// A key command (moveUp:, insertNewline:…); true if handled.
    func editor(_ engine: EditorEngine, doCommandBy selector: Selector) -> Bool
    func editor(_ engine: EditorEngine, definitionRequestedAt characterIndex: Int)
    func editor(_ engine: EditorEngine, clickedDiffMark mark: GitDiffMark, line: Int, event: NSEvent)
    func editor(_ engine: EditorEngine, clickedDiagnostic severity: LSPDiagnosticSeverity, line: Int, event: NSEvent)
}

// MARK: - TextKit (today's editor)

/// Make's editor as it has always been: `NSTextView` on TextKit 1, with the line-number gutter.
@MainActor
final class TextKitEditorEngine: NSObject, EditorEngine, NSTextViewDelegate {
    weak var delegate: EditorEngineDelegate?
    let scrollView = NSScrollView()
    private let editor = EditorTextView()
    private var gutter: LineNumberGutterView!
    private(set) var document: EditorDocument?

    var gutterView: NSView { gutter }
    var textView: NSView { editor }

    var appearance: EditorAppearance {
        didSet { applyAppearance() }
    }

    init(appearance: EditorAppearance) {
        self.appearance = appearance
        super.init()
        editor.isRichText = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextCompletionEnabled = false
        editor.usesFindBar = true
        editor.isIncrementalSearchingEnabled = true
        editor.insertionPointColor = .controlAccentColor
        editor.textContainerInset = NSSize(width: 16, height: 12)
        editor.delegate = self
        editor.onDefinitionRequested = { [weak self] index in
            guard let self else { return }
            self.delegate?.editor(self, definitionRequestedAt: index)
        }
        editor.isEditable = false
        scrollView.documentView = editor
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        gutter = LineNumberGutterView(textView: editor, scrollView: scrollView)
        gutter.onMarkClicked = { [weak self] line, mark, event in
            guard let self else { return }
            self.delegate?.editor(self, clickedDiffMark: mark, line: line, event: event)
        }
        gutter.onDiagnosticClicked = { [weak self] line, severity, event in
            guard let self else { return }
            self.delegate?.editor(self, clickedDiagnostic: severity, line: line, event: event)
        }
        applyAppearance()
    }

    private func applyAppearance() {
        editor.font = appearance.font
        editor.textColor = appearance.textColor
        editor.backgroundColor = appearance.background
        scrollView.backgroundColor = appearance.background
        // Typing attributes can be left pointing at a previous document's font or color,
        // especially in a new empty document with no run to inherit from; reset them so typed
        // characters are never invisible.
        editor.typingAttributes = [.foregroundColor: appearance.textColor, .font: appearance.font]
        gutter.invalidate()
    }

    func makeDocument(_ text: String) -> EditorDocument { TextStorageDocument(text) }

    func attach(_ document: EditorDocument?, undoManager: UndoManager?) {
        self.document = document
        editor.layoutManager?.replaceTextStorage((document as? TextStorageDocument)?.storage ?? NSTextStorage())
        editor.tabUndoManager = undoManager
        editor.typingAttributes = [.foregroundColor: appearance.textColor, .font: appearance.font]
        gutter.invalidate()
    }

    var isEditable: Bool {
        get { editor.isEditable }
        set { editor.isEditable = newValue }
    }

    var selectedRange: NSRange {
        get { editor.selectedRange() }
        set { editor.setSelectedRange(newValue) }
    }

    var visibleRect: NSRect { editor.visibleRect }

    func scrollRangeToVisible(_ range: NSRange) { editor.scrollRangeToVisible(range) }

    func rect(forCharacterRange range: NSRange) -> NSRect {
        guard let layoutManager = editor.layoutManager, let container = editor.textContainer else { return editor.visibleRect }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        rect.origin.x += editor.textContainerOrigin.x
        rect.origin.y += editor.textContainerOrigin.y
        if rect.width < 1 { rect.size.width = 1 }
        return rect
    }

    func screenRect(forCharacterRange range: NSRange) -> NSRect? {
        var actual = NSRange(location: 0, length: 0)
        let rect = editor.firstRect(forCharacterRange: range, actualRange: &actual)
        return rect == .zero ? nil : rect
    }

    func insertText(_ text: String, replacementRange: NSRange) {
        editor.insertText(text, replacementRange: replacementRange)
    }

    func focus() { editor.window?.makeFirstResponder(editor) }

    var lineDiffMarks: [Int: GitDiffMark] {
        get { gutter.lineDiffMarks }
        set { gutter.lineDiffMarks = newValue }
    }

    var lineDiagnostics: [Int: LSPDiagnosticSeverity] {
        get { gutter.lineDiagnostics }
        set { gutter.lineDiagnostics = newValue }
    }

    func invalidateGutter() { gutter.invalidate() }
    func setNeedsDisplay() { editor.needsDisplay = true }

    // MARK: NSTextViewDelegate, forwarded

    func textDidChange(_ notification: Notification) { delegate?.editorTextDidChange(self) }
    func textViewDidChangeSelection(_ notification: Notification) { delegate?.editorSelectionDidChange(self) }

    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        delegate?.editor(self, shouldChangeTextIn: affectedCharRange, replacementString: replacementString) ?? true
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        delegate?.editor(self, doCommandBy: commandSelector) ?? false
    }
}

/// A tab's text as TextKit holds it.
@MainActor
final class TextStorageDocument: EditorDocument {
    let storage: NSTextStorage
    /// Where each decoration kind was last drawn, so replacing one clears only its own ranges:
    /// a full-document strip would make TextKit re-lay-out the whole file on every keystroke.
    private var decorated: [EditorDecoration: [NSRange]] = [:]

    init(_ text: String) { storage = NSTextStorage(string: text) }

    var string: String { storage.string }
    var length: Int { storage.length }

    func replaceAll(with text: String) {
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text)
        decorated = [:]
    }

    func highlight(url: URL, appearance: EditorAppearance) {
        SyntaxHighlighter.apply(to: storage, url: url, baseColor: appearance.textColor, font: appearance.font)
    }

    func applyHighlight(_ runs: [SyntaxHighlighter.ColorRun], appearance: EditorAppearance) {
        SyntaxHighlighter.applyRuns(runs, to: storage, baseColor: appearance.textColor, font: appearance.font)
    }

    func setDecorations(_ kind: EditorDecoration, _ marks: [(range: NSRange, color: NSColor)]) {
        let keys: [NSAttributedString.Key] = kind == .diagnostic ? [.underlineStyle, .underlineColor] : [.backgroundColor]
        for range in decorated[kind] ?? [] where NSMaxRange(range) <= storage.length {
            for key in keys { storage.removeAttribute(key, range: range) }
        }
        var applied: [NSRange] = []
        for mark in marks where NSMaxRange(mark.range) <= storage.length {
            switch kind {
            case .diagnostic:
                storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue, range: mark.range)
                storage.addAttribute(.underlineColor, value: mark.color, range: mark.range)
            case .bracketMatch:
                storage.addAttribute(.backgroundColor, value: mark.color, range: mark.range)
            }
            applied.append(mark.range)
        }
        decorated[kind] = applied
    }
}

final class EditorTextView: NSTextView {
    var tabUndoManager: UndoManager?
    override var undoManager: UndoManager? { tabUndoManager }
    var onDefinitionRequested: ((Int) -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        guard onDefinitionRequested != nil else { return menu }
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        let item = NSMenuItem(title: "Jump to Definition", action: #selector(triggerJumpToDefinition(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = index
        menu?.insertItem(item, at: 0)
        menu?.insertItem(NSMenuItem.separator(), at: 1)
        return menu
    }

    @objc private func triggerJumpToDefinition(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        onDefinitionRequested?(index)
    }

    private static let currentLineHighlightColor = DS.Color.scrimFaint

    /// Real NSTextView override point for exactly this: a full-width current-line band,
    /// matching Xcode/Cursor. Skipped whenever there's an active selection, same as both.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard selectedRange().length == 0, let layoutManager, textContainer != nil else { return }
        var lineRect: NSRect
        if layoutManager.numberOfGlyphs == 0 {
            // A brand-new empty document has no glyphs at all — extraLineFragmentRect is
            // NSLayoutManager's dedicated rect for the empty trailing line in that case.
            lineRect = layoutManager.extraLineFragmentRect
            guard lineRect.width > 0 || lineRect.height > 0 else { return }
        } else {
            let charIndex = min(selectedRange().location, (string as NSString).length)
            let glyphIndex = min(layoutManager.glyphIndexForCharacter(at: charIndex), layoutManager.numberOfGlyphs - 1)
            lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        }
        let origin = textContainerOrigin
        lineRect.origin.x = 0
        lineRect.origin.y += origin.y
        lineRect.size.width = max(bounds.width, lineRect.width + origin.x)
        Self.currentLineHighlightColor.setFill()
        lineRect.fill()
    }
}
