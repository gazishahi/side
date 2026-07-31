import AppKit

final class LineNumberGutterView: NSView {
    private weak var textView: NSTextView?
    private weak var scrollView: NSScrollView?
    private let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    static let width: CGFloat = 44

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        self.scrollView = scrollView
        super.init(frame: .zero)
        wantsLayer = true
        NotificationCenter.default.addObserver(self, selector: #selector(invalidate), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    @objc func invalidate() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.098, alpha: 1).setFill()
        bounds.fill()
        guard let textView, let layoutManager = textView.layoutManager, let textContainer = textView.textContainer, let scrollView else { return }

        let offsetY = scrollView.contentView.bounds.origin.y
        let visibleRect = NSRect(x: 0, y: offsetY, width: textView.bounds.width, height: bounds.height)
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let characterRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let text = textView.string as NSString

        var lineNumber = text.substring(to: characterRange.location).components(separatedBy: "\n").count
        var index = characterRange.location
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(calibratedWhite: 0.42, alpha: 1)]

        while index <= NSMaxRange(characterRange) {
            let lineRange = text.lineRange(for: NSRange(location: index, length: 0))
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: lineRange.location)
            var lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            lineRect.origin.y += textView.textContainerInset.height

            let numberString = "\(lineNumber)" as NSString
            let size = numberString.size(withAttributes: attributes)
            let drawRect = NSRect(x: Self.width - size.width - 8, y: lineRect.minY - offsetY, width: size.width, height: lineRect.height)
            numberString.draw(in: drawRect, withAttributes: attributes)

            if lineRange.location >= text.length { break }
            index = NSMaxRange(lineRange)
            lineNumber += 1
            if index > NSMaxRange(characterRange) { break }
        }
    }
}
