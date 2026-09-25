import AppKit
import Heron

// MARK: - The seam (SIDE_RFC_ALLOY.md, step 0)

/// Every way Make touches its editor, named. `AlloyEditorEngine` implements it; it began as the
/// seam Make crossed from TextKit to Alloy on, and keeps Make's code free of Alloy's types.
///
/// Ranges are UTF-16 `NSRange`s throughout, because that's what LSP positions, `NSString` and
/// AppKit's text input all speak. Alloy's rope keeps UTF-16 counts for exactly this.
@MainActor
protocol EditorEngine: AnyObject, Sendable {
    var delegate: EditorEngineDelegate? { get set }

    /// What Make lays out and hides (the editor's outermost view), the scroll view inside it
    /// (for content insets and the window's top-row chrome), and the gutter beside it.
    var containerView: NSView { get }
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
    /// The whole text as a String: a copy of the file, for what needs all of it (saving, the
    /// language server, the symbol index).
    var string: String { get }
    /// The text as an NSString that reads without copying, for looking around an offset (line
    /// ranges, bracket scans, the word at the caret). A snapshot: later edits don't change it.
    var text: NSString { get }
    /// UTF-16 length.
    var length: Int { get }
    /// Replaces everything outside the undo stack (loading, reloading, applying an agent's edit,
    /// format on save).
    func replaceAll(with text: String)
    /// Colors the document for its file's language (and again if the file is renamed).
    func highlight(url: URL, appearance: EditorAppearance)
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
