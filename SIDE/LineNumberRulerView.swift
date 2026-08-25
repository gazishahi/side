import AppKit

final class LineNumberGutterView: NSView {
    private weak var textView: NSTextView?
    private weak var scrollView: NSScrollView?
    private let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    static let width: CGFloat = 44
    var lineDiffMarks: [Int: GitDiffMark] = [:] { didSet { needsDisplay = true } }
    var onMarkClicked: ((Int, GitDiffMark, NSEvent) -> Void)?
    var lineDiagnostics: [Int: LSPDiagnosticSeverity] = [:] { didSet { needsDisplay = true } }
    var onDiagnosticClicked: ((Int, LSPDiagnosticSeverity, NSEvent) -> Void)?

    private static let addedColor = NSColor(red: 0.42, green: 0.78, blue: 0.48, alpha: 1)
    private static let modifiedColor = NSColor(red: 0.85, green: 0.68, blue: 0.35, alpha: 1)
    private static let removedColor = NSColor(red: 0.86, green: 0.42, blue: 0.42, alpha: 1)
    private static let errorColor = NSColor(red: 0.92, green: 0.35, blue: 0.35, alpha: 1)
    private static let warningColor = NSColor(red: 0.93, green: 0.75, blue: 0.3, alpha: 1)
    private static let hintColor = NSColor(white: 0.55, alpha: 1)

    private static func color(for severity: LSPDiagnosticSeverity) -> NSColor {
        switch severity {
        case .error: return errorColor
        case .warning: return warningColor
        case .information, .hint: return hintColor
        }
    }

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        self.scrollView = scrollView
        super.init(frame: .zero)
        wantsLayer = true
        NotificationCenter.default.addObserver(self, selector: #selector(invalidate), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { NotificationCenter.default.removeObserver(self) }

    override var isFlipped: Bool { true }

    @objc func invalidate() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.098, alpha: 1).setFill()
        bounds.fill()
        guard let textView, let layoutManager = textView.layoutManager, let textContainer = textView.textContainer, let scrollView else { return }

        let text = textView.string as NSString
        let textLength = text.length
        guard textLength >= 0 else { return }

        let offsetY = scrollView.contentView.bounds.origin.y
        let visibleRect = NSRect(x: 0, y: offsetY, width: textView.bounds.width, height: bounds.height)
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        var characterRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        // Clamp defensively: the text can be edited/replaced concurrently with a queued redraw.
        characterRange.location = min(max(0, characterRange.location), textLength)
        characterRange.length = min(characterRange.length, textLength - characterRange.location)

        var lineNumber = text.substring(to: characterRange.location).components(separatedBy: "\n").count
        var index = characterRange.location
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(white: 0.42, alpha: 1)]

        var safetyCounter = 0
        let maxIterations = 5000
        while index <= NSMaxRange(characterRange) {
            safetyCounter += 1
            if safetyCounter > maxIterations { break }
            guard index >= 0, index <= textLength else { break }

            var lineRect: NSRect
            var lineRange = NSRange(location: index, length: 0)
            if index >= textLength {
                // Past the last character. Only an actual phantom final line — an empty document,
                // or text ending in a newline — gets a number here, at the layout manager's
                // extraLineFragmentRect. The old code resolved this position through
                // lineRange/glyphIndexForCharacter, which clamps back onto the *previous* line's
                // fragment and printed this number on top of that line's — the "1 and 2
                // overlapped" bug on short files.
                guard layoutManager.extraLineFragmentTextContainer != nil else { break }
                lineRect = layoutManager.extraLineFragmentRect
            } else {
                lineRange = text.lineRange(for: NSRange(location: index, length: 0))
                guard lineRange.location <= layoutManager.numberOfGlyphs else { break }
                let glyphIndex = layoutManager.glyphIndexForCharacter(at: lineRange.location)
                guard glyphIndex >= 0 else { break }
                lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            }
            lineRect.origin.y += textView.textContainerInset.height

            let numberString = "\(lineNumber)" as NSString
            let size = numberString.size(withAttributes: attributes)
            let drawRect = NSRect(x: Self.width - size.width - 8, y: lineRect.minY - offsetY, width: size.width, height: lineRect.height)
            numberString.draw(in: drawRect, withAttributes: attributes)

            if let mark = lineDiffMarks[lineNumber] {
                switch mark {
                case .added:
                    Self.addedColor.setFill()
                    NSRect(x: 0, y: lineRect.minY - offsetY, width: 3, height: lineRect.height).fill()
                case .modified:
                    Self.modifiedColor.setFill()
                    NSRect(x: 0, y: lineRect.minY - offsetY, width: 3, height: lineRect.height).fill()
                case .removedBefore:
                    Self.removedColor.setFill()
                    NSRect(x: 0, y: lineRect.minY - offsetY - 1, width: 3, height: 3).fill()
                }
            }

            if let severity = lineDiagnostics[lineNumber] {
                Self.color(for: severity).setFill()
                let dotSize: CGFloat = 6
                let dotRect = NSRect(x: 7, y: lineRect.minY - offsetY + (lineRect.height - dotSize) / 2, width: dotSize, height: dotSize)
                NSBezierPath(ovalIn: dotRect).fill()
            }

            if index >= textLength { break }
            let nextIndex = NSMaxRange(lineRange)
            guard nextIndex > index else { break }
            index = nextIndex
            lineNumber += 1
            if index > NSMaxRange(characterRange) { break }
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let textView, let layoutManager = textView.layoutManager, let textContainer = textView.textContainer, let scrollView else { return }
        let point = convert(event.locationInWindow, from: nil)
        let offsetY = scrollView.contentView.bounds.origin.y
        let adjustedY = point.y + offsetY - textView.textContainerInset.height
        let glyphIndex = layoutManager.glyphIndex(for: NSPoint(x: 0, y: adjustedY), in: textContainer)
        guard glyphIndex < layoutManager.numberOfGlyphs || layoutManager.numberOfGlyphs == 0 else { return }
        let charIndex = layoutManager.numberOfGlyphs == 0 ? 0 : layoutManager.characterIndexForGlyph(at: glyphIndex)
        let text = textView.string as NSString
        guard charIndex <= text.length else { return }
        let lineNumber = text.substring(to: min(charIndex, text.length)).components(separatedBy: "\n").count
        if let severity = lineDiagnostics[lineNumber] {
            onDiagnosticClicked?(lineNumber, severity, event)
            return
        }
        if let mark = lineDiffMarks[lineNumber] {
            onMarkClicked?(lineNumber, mark, event)
        }
    }
}
