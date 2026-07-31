import AppKit

final class LineNumberGutterView: NSView {
    private weak var textView: NSTextView?
    private weak var scrollView: NSScrollView?
    private let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    static let width: CGFloat = 44
    var lineDiffMarks: [Int: GitDiffMark] = [:] { didSet { needsDisplay = true } }

    private static let addedColor = NSColor(calibratedRed: 0.42, green: 0.78, blue: 0.48, alpha: 1)
    private static let modifiedColor = NSColor(calibratedRed: 0.85, green: 0.68, blue: 0.35, alpha: 1)
    private static let removedColor = NSColor(calibratedRed: 0.86, green: 0.42, blue: 0.42, alpha: 1)

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
        NSColor(calibratedWhite: 0.098, alpha: 1).setFill()
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
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(calibratedWhite: 0.42, alpha: 1)]

        var safetyCounter = 0
        let maxIterations = 5000
        while index <= NSMaxRange(characterRange) {
            safetyCounter += 1
            if safetyCounter > maxIterations { break }
            guard index >= 0, index <= textLength else { break }

            let lineRange = text.lineRange(for: NSRange(location: index, length: 0))
            guard lineRange.location <= layoutManager.numberOfGlyphs || lineRange.location == textLength else { break }
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: lineRange.location)
            guard glyphIndex >= 0 else { break }
            var lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
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

            if lineRange.location >= textLength { break }
            let nextIndex = NSMaxRange(lineRange)
            guard nextIndex > index else { break }
            index = nextIndex
            lineNumber += 1
            if index > NSMaxRange(characterRange) { break }
        }
    }
}
