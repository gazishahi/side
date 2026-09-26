import AppKit

/// A small floating card by the text: signature help above the caret, a hover's type and docs
/// above the word. It never takes focus or clicks; it goes when what it describes does.
@MainActor
final class InfoCard {
    static let maxWidth: CGFloat = 520
    static let maxHeight: CGFloat = 280

    private let panel = CompletionPanel()
    private let label = NSTextField(wrappingLabelWithString: "")
    private let scroll = NSScrollView()
    private(set) var content = NSAttributedString()

    var isVisible: Bool { panel.isVisible }

    init() {
        label.isSelectable = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let body = NSView()
        body.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: DS.Spacing.m),
            label.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -DS.Spacing.m),
            label.topAnchor.constraint(equalTo: body.topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -2),
        ])
        panel.ignoresMouseEvents = true
        panel.contentView = MakeWorkspaceViewController.makeFloatingPanelSurface(embedding: body, cornerRadius: DS.Radius.surface, padding: 6)
        panel.setAccessibilityRole(.helpTag)
    }

    /// Shows `content` next to `anchor` (a screen rect): above it if there's room, else below.
    /// The size `content` needs, measured once per content (a hover shown again, signature help
    /// re-asked with the same answer, costs no layout).
    private var measured: NSSize = .zero

    func show(_ content: NSAttributedString, near anchor: NSRect, in window: NSWindow, preferAbove: Bool = true) {
        if !content.isEqual(to: self.content) || measured == .zero {
            self.content = content
            label.attributedStringValue = content
            label.preferredMaxLayoutWidth = Self.maxWidth - 2 * DS.Spacing.m
            measured = label.sizeThatFits(NSSize(width: Self.maxWidth - 2 * DS.Spacing.m, height: .greatestFiniteMagnitude))
        }
        let fitting = measured
        let width = min(Self.maxWidth, ceil(fitting.width) + 2 * DS.Spacing.m + 2)
        let height = min(Self.maxHeight, ceil(fitting.height) + 16)
        let screen = window.screen?.visibleFrame ?? window.frame
        var x = anchor.minX - DS.Spacing.m
        x = max(screen.minX + 8, min(x, screen.maxX - width - 8))
        // Inside the window where it fits (over the text it's about), else anywhere on screen.
        let top = min(screen.maxY, window.frame.maxY - 36), bottom = max(screen.minY, window.frame.minY)
        let above = anchor.maxY + 4, below = anchor.minY - height - 4
        let y: CGFloat
        if preferAbove, above + height <= top { y = above }
        else if below >= bottom { y = below }
        else if above + height <= screen.maxY { y = above }
        else { y = max(screen.minY, below) }
        let frame = NSRect(x: x, y: y, width: width, height: height)
        // Drawn with the next display pass, not forced now.
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        // Attached once and left attached: adding and removing a child window each time is
        // window-server work (most of what showing a card cost).
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        if !panel.isVisible {
            panel.orderFront(nil)
            NSAccessibility.post(element: panel, notification: .layoutChanged)
        }
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }

    /// Before its window closes.
    func detach() {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }
}

/// Markdown as language servers write it, drawn simply: fenced and inline code in the editor's
/// font, `**bold**`, links as their text, and the commonest marks gone.
enum MarkdownLite {
    static func attributed(_ markdown: String, size: CGFloat = 12, color: NSColor = .labelColor) -> NSMutableAttributedString {
        let body = DS.Text.body(), code = DS.Text.code(size - 0.5, weight: .regular)
        let result = NSMutableAttributedString()
        var inFence = false
        var paragraph: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            if result.length > 0 { result.append(NSAttributedString(string: "\n\n")) }
            result.append(inline(paragraph.joined(separator: "\n"), body: body, code: code, color: color))
            paragraph = []
        }

        var fenceLines: [String] = []
        for line in markdown.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inFence {
                    if result.length > 0 { result.append(NSAttributedString(string: "\n\n")) }
                    result.append(NSAttributedString(string: fenceLines.joined(separator: "\n"), attributes: [.font: code, .foregroundColor: color]))
                    fenceLines = []
                } else {
                    flushParagraph()
                }
                inFence.toggle()
                continue
            }
            if inFence { fenceLines.append(line); continue }
            if line.trimmingCharacters(in: .whitespaces).isEmpty || line.hasPrefix("---") || line.hasPrefix("___") {
                flushParagraph()
                continue
            }
            paragraph.append(line.hasPrefix("#") ? String(line.drop(while: { $0 == "#" || $0 == " " })) : line)
        }
        if inFence, !fenceLines.isEmpty {
            if result.length > 0 { result.append(NSAttributedString(string: "\n\n")) }
            result.append(NSAttributedString(string: fenceLines.joined(separator: "\n"), attributes: [.font: code, .foregroundColor: color]))
        }
        flushParagraph()
        return result
    }

    /// One paragraph: `code`, **bold**, *emphasis* and _emphasis_ (as plain), [links](…).
    static func inline(_ text: String, body: NSFont, code: NSFont, color: NSColor) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let bold = NSFontManager.shared.convert(body, toHaveTrait: .boldFontMask)
        var i = text.startIndex
        var plain = ""
        func flush() {
            guard !plain.isEmpty else { return }
            out.append(NSAttributedString(string: plain, attributes: [.font: body, .foregroundColor: color]))
            plain = ""
        }
        while i < text.endIndex {
            let rest = text[i...]
            if rest.hasPrefix("`"), let close = rest.dropFirst().firstIndex(of: "`") {
                flush()
                out.append(NSAttributedString(string: String(rest[rest.index(after: rest.startIndex)..<close]), attributes: [.font: code, .foregroundColor: color]))
                i = text.index(after: close)
                continue
            }
            if rest.hasPrefix("**"), let close = rest.dropFirst(2).range(of: "**") {
                flush()
                out.append(NSAttributedString(string: String(rest[rest.index(rest.startIndex, offsetBy: 2)..<close.lowerBound]), attributes: [.font: bold, .foregroundColor: color]))
                i = close.upperBound
                continue
            }
            if rest.hasPrefix("["), let closeBracket = rest.firstIndex(of: "]"),
               text.index(after: closeBracket) < text.endIndex, text[text.index(after: closeBracket)] == "(",
               let closeParen = text[closeBracket...].firstIndex(of: ")") {
                plain += text[text.index(after: i)..<closeBracket]
                i = text.index(after: closeParen)
                continue
            }
            let atWordStart = i == text.startIndex || text[text.index(before: i)].isWhitespace || "([".contains(text[text.index(before: i)])
            if (rest.hasPrefix("*") || rest.hasPrefix("_")), rest.count > 2, atWordStart {
                let mark = rest.first!
                let after = rest.dropFirst()
                if let first = after.first, first != " ", first != mark, let close = after.firstIndex(of: mark),
                   text[text.index(before: close)] != " " {
                    plain += after[after.startIndex..<close]
                    i = text.index(after: close)
                    continue
                }
            }
            plain.append(text[i])
            i = text.index(after: i)
        }
        flush()
        return out
    }
}

/// Rename's field: over the symbol, in the editor's font, the name selected. Return commits,
/// Escape or clicking away cancels.
@MainActor
final class RenameField: NSObject, NSTextFieldDelegate {
    private let panel: KeyPanel
    private let field = NSTextField()
    var onCommit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    private var finished = false

    private final class KeyPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    init(name: String) {
        panel = KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = true
        field.stringValue = name
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.setAccessibilityLabel("New name")
        field.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = MakeWorkspaceViewController.makeFloatingPanelSurface(embedding: field, cornerRadius: DS.Radius.control, padding: 4)
        NotificationCenter.default.addObserver(self, selector: #selector(resigned), name: NSWindow.didResignKeyNotification, object: panel)
    }

    func show(over anchor: NSRect, in window: NSWindow, font: NSFont) {
        field.font = font
        let width = max(160, (field.stringValue as NSString).size(withAttributes: [.font: font]).width + 80)
        let height = ceil(font.ascender - font.descender + font.leading) + 12
        panel.setFrame(NSRect(x: anchor.minX - 8, y: anchor.midY - height / 2, width: width, height: height), display: true)
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) { finish(commit: true); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) { finish(commit: false); return true }
        return false
    }

    @objc private func resigned() { finish(commit: false) }

    private func finish(commit: Bool) {
        guard !finished else { return }
        finished = true
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        NotificationCenter.default.removeObserver(self)
        if commit { onCommit?(name) } else { onCancel?() }
    }
}
