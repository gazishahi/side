import AlloyCore
import AlloyRender
import AppKit

/// A mark in the gutter beside a line: a change bar (added, modified), a notch between lines
/// (removed), or a dot (a diagnostic).
public struct GutterMark: Equatable {
    public enum Style: Equatable { case bar, notch, dot }
    public var style: Style
    public var color: NSColor
    public init(style: Style, color: NSColor) {
        self.style = style
        self.color = color
    }
}

/// Line numbers and marks, beside the editor and scrolled with it. Lines are one-based here,
/// as people (and Make's diff and diagnostics code) count them.
@MainActor
public final class AlloyGutterView: NSView {
    public static let width: CGFloat = 44
    weak var editor: AlloyEditorView?
    public var font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular) { didSet { needsDisplay = true } }
    public var numberColor = NSColor.tertiaryLabelColor { didSet { needsDisplay = true } }
    public var backgroundColor = NSColor.textBackgroundColor { didSet { needsDisplay = true } }
    /// Marks by one-based line.
    public var marks: [Int: [GutterMark]] = [:] { didSet { needsDisplay = true } }
    /// A click on a line (one-based) that has marks.
    public var onClick: ((Int, NSEvent) -> Void)?

    public override var isFlipped: Bool { true }

    public override func draw(_ dirtyRect: NSRect) {
        backgroundColor.setFill()
        bounds.fill()
        guard let editor else { return }
        let layout = editor.documentLayout
        let viewport = editor.viewport
        // The gutter's top edge sits where the viewport's does.
        let top = editor.scrollView.convert(editor.scrollView.contentView.frame.origin, to: self).y + editor.scrollView.contentView.contentInsets.top
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: numberColor]
        for (line, y, laid) in layout.visibleLines(from: viewport.minY, to: viewport.maxY) {
            let rowTop = top + (y - viewport.minY)
            let lineHeight = layout.lineHeight
            let height = CGFloat(laid.rows.count) * lineHeight
            let number = "\(line + 1)" as NSString
            let size = number.size(withAttributes: attributes)
            // On the text's baseline (row top + the text font's ascent), right-aligned. `draw(at:)`
            // places the string's top, and its baseline falls the number font's ascent below.
            let top = rowTop + layout.ascent - font.ascender
            number.draw(at: CGPoint(x: Self.width - size.width - 8, y: top), withAttributes: attributes)
            for mark in marks[line + 1] ?? [] {
                mark.color.setFill()
                switch mark.style {
                case .bar: NSRect(x: 0, y: rowTop, width: 3, height: height).fill()
                case .notch: NSRect(x: 0, y: rowTop - 1, width: 3, height: 3).fill()
                case .dot:
                    let size: CGFloat = 6
                    NSBezierPath(ovalIn: NSRect(x: 7, y: rowTop + (lineHeight - size) / 2, width: size, height: size)).fill()
                }
            }
        }
    }

    /// The one-based line under a point in the gutter.
    public func line(at point: CGPoint) -> Int? {
        guard let editor else { return nil }
        let top = editor.scrollView.convert(editor.scrollView.contentView.frame.origin, to: self).y + editor.scrollView.contentView.contentInsets.top
        let documentY = editor.viewport.minY + (point.y - top)
        return editor.documentLayout.line(atY: documentY).line + 1
    }

    public override func mouseDown(with event: NSEvent) {
        guard let line = line(at: convert(event.locationInWindow, from: nil)), marks[line] != nil else { return }
        onClick?(line, event)
    }
}
