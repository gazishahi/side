import AppKit

/// A small, deliberately non-exhaustive line/regex-based markdown renderer — headers, bold,
/// italic, inline code, fenced code blocks, bullet lists, blockquotes, and links. Matches this
/// codebase's existing preference for lightweight hand-rolled text processing (see
/// SyntaxHighlighter) over pulling in a full CommonMark implementation for a preview feature.
enum MarkdownRenderer {
    static func render(_ markdown: String, baseFont: NSFont, textColor: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let lines = markdown.components(separatedBy: "\n")
        var inCodeBlock = false
        var codeBlockLines: [String] = []
        var paragraphBuffer = ""

        func codeFont() -> NSFont { .monospacedSystemFont(ofSize: baseFont.pointSize - 1, weight: .regular) }

        func flushParagraph() {
            guard !paragraphBuffer.isEmpty else { return }
            result.append(renderInline(paragraphBuffer, baseFont: baseFont, textColor: textColor))
            result.append(NSAttributedString(string: "\n\n"))
            paragraphBuffer = ""
        }

        func flushCodeBlock() {
            guard !codeBlockLines.isEmpty else { return }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: codeFont(), .foregroundColor: textColor,
                .backgroundColor: NSColor(white: 1, alpha: 0.06)
            ]
            result.append(NSAttributedString(string: codeBlockLines.joined(separator: "\n"), attributes: attrs))
            result.append(NSAttributedString(string: "\n\n"))
            codeBlockLines = []
        }

        for line in lines {
            if line.hasPrefix("```") {
                if inCodeBlock { flushCodeBlock() } else { flushParagraph() }
                inCodeBlock.toggle()
                continue
            }
            if inCodeBlock { codeBlockLines.append(line); continue }
            if line.isEmpty { flushParagraph(); continue }

            if let (level, text) = matchHeader(line) {
                flushParagraph()
                let size: CGFloat = [28, 24, 20, 17, 15, 14][min(level - 1, 5)]
                let font = NSFont.systemFont(ofSize: size, weight: .bold)
                result.append(renderInline(text, baseFont: font, textColor: textColor))
                result.append(NSAttributedString(string: "\n\n"))
                continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flushParagraph()
                let bullet = NSMutableAttributedString(string: "\u{2022}  ", attributes: [.font: baseFont, .foregroundColor: textColor])
                bullet.append(renderInline(String(line.dropFirst(2)), baseFont: baseFont, textColor: textColor))
                bullet.append(NSAttributedString(string: "\n"))
                result.append(bullet)
                continue
            }
            if line.hasPrefix(">") {
                flushParagraph()
                let text = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                let quote = NSMutableAttributedString(string: "\u{258E} ", attributes: [.font: baseFont, .foregroundColor: NSColor.systemGray])
                quote.append(renderInline(text, baseFont: baseFont, textColor: textColor.withAlphaComponent(0.75)))
                quote.append(NSAttributedString(string: "\n"))
                result.append(quote)
                continue
            }
            paragraphBuffer += (paragraphBuffer.isEmpty ? "" : " ") + line
        }
        flushParagraph()
        flushCodeBlock()
        return result
    }

    private static func matchHeader(_ line: String) -> (Int, String)? {
        var level = 0
        var idx = line.startIndex
        while idx < line.endIndex, line[idx] == "#", level < 6 {
            level += 1
            idx = line.index(after: idx)
        }
        guard level > 0, idx < line.endIndex, line[idx] == " " else { return nil }
        return (level, String(line[line.index(after: idx)...]))
    }

    /// Non-overlapping left-to-right scan for `**bold**`, `*italic*`, `` `code` `` and
    /// `[label](url)`, falling through to plain text for anything else — not a real parser,
    /// just enough to make prose read naturally.
    private static func renderInline(_ text: String, baseFont: NSFont, textColor: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let chars = Array(text)
        let baseAttrs: [NSAttributedString.Key: Any] = [.font: baseFont, .foregroundColor: textColor]
        var i = 0
        while i < chars.count {
            if chars[i] == "`", let end = findMarker(chars, from: i + 1, marker: Array("`")) {
                let codeFont = NSFont.monospacedSystemFont(ofSize: baseFont.pointSize - 1, weight: .regular)
                result.append(NSAttributedString(string: String(chars[(i + 1)..<end]), attributes: [
                    .font: codeFont, .foregroundColor: textColor, .backgroundColor: NSColor(white: 1, alpha: 0.08)
                ]))
                i = end + 1
                continue
            }
            if i + 1 < chars.count, chars[i] == "*", chars[i + 1] == "*", let end = findMarker(chars, from: i + 2, marker: Array("**")) {
                let boldFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)
                result.append(NSAttributedString(string: String(chars[(i + 2)..<end]), attributes: [.font: boldFont, .foregroundColor: textColor]))
                i = end + 2
                continue
            }
            if chars[i] == "*", let end = findMarker(chars, from: i + 1, marker: Array("*")) {
                let italicFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
                result.append(NSAttributedString(string: String(chars[(i + 1)..<end]), attributes: [.font: italicFont, .foregroundColor: textColor]))
                i = end + 1
                continue
            }
            if chars[i] == "[", let closeBracket = findChar(chars, from: i + 1, char: "]"),
               closeBracket + 1 < chars.count, chars[closeBracket + 1] == "(",
               let closeParen = findChar(chars, from: closeBracket + 2, char: ")") {
                let label = String(chars[(i + 1)..<closeBracket])
                let urlString = String(chars[(closeBracket + 2)..<closeParen])
                var linkAttrs = baseAttrs
                linkAttrs[.foregroundColor] = NSColor.linkColor
                linkAttrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                if let url = URL(string: urlString) { linkAttrs[.link] = url }
                result.append(NSAttributedString(string: label, attributes: linkAttrs))
                i = closeParen + 1
                continue
            }
            result.append(NSAttributedString(string: String(chars[i]), attributes: baseAttrs))
            i += 1
        }
        return result
    }

    private static func findMarker(_ chars: [Character], from start: Int, marker: [Character]) -> Int? {
        var i = start
        while i + marker.count <= chars.count {
            if Array(chars[i..<(i + marker.count)]) == marker { return i }
            i += 1
        }
        return nil
    }

    private static func findChar(_ chars: [Character], from start: Int, char: Character) -> Int? {
        var i = start
        while i < chars.count {
            if chars[i] == char { return i }
            i += 1
        }
        return nil
    }
}
