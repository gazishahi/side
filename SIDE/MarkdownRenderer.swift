import AppKit
import SideAgents

/// A small, deliberately non-exhaustive line/regex-based markdown renderer — headers, bold,
/// italic, inline code, fenced code blocks, bullet lists, blockquotes, and links. Matches this
/// codebase's existing preference for lightweight hand-rolled text processing (see
/// SyntaxHighlighter) over pulling in a full CommonMark implementation for a preview feature.
enum MarkdownRenderer {
    /// Marks each rendered header run with its GitHub-style slug, so a preview view can resolve
    /// an in-document `[label](#some-header)` link to a real location in the attributed string
    /// instead of handing `#some-header` to the OS as if it were a web URL (which either fails
    /// or bounces uselessly into the browser).
    static let anchorSlugKey = NSAttributedString.Key("SideMarkdownAnchorSlug")
    /// The custom scheme fragment links render as (`side-anchor:<slug>`) — a preview's link
    /// delegate intercepts these and scrolls; real http(s) links keep their default behavior.
    static let anchorScheme = "side-anchor"

    /// GitHub-style: lowercase, alphanumerics kept, spaces to hyphens, everything else dropped.
    static func anchorSlug(for headerText: String) -> String {
        var slug = ""
        for character in headerText.lowercased() {
            if character.isLetter || character.isNumber { slug.append(character) }
            else if character == " " || character == "-" { slug.append("-") }
        }
        while slug.contains("--") { slug = slug.replacingOccurrences(of: "--", with: "-") }
        return slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

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
                .backgroundColor: DS.Color.scrimSoft
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
                // Scaled with the text setting (audit 29.3), and semibold: nothing is bold below 15.
                let size: CGFloat = [28, 24, 20, 17, 15, 14][min(level - 1, 5)]
                let font = DS.Text.custom(size, weight: size >= 15 ? .bold : .semibold)
                let header = NSMutableAttributedString(attributedString: renderInline(text, baseFont: font, textColor: textColor))
                header.addAttribute(anchorSlugKey, value: anchorSlug(for: text), range: NSRange(location: 0, length: header.length))
                result.append(header)
                result.append(NSAttributedString(string: "\n\n"))
                continue
            }
            if let (marker, itemText) = matchListItem(line) {
                flushParagraph()
                // Hanging indent: wrapped lines align under the item's *text*, not under the
                // bullet/number — without this, any list item long enough to wrap collapsed
                // back to the left margin and stopped reading as a list at all.
                let markerString = NSAttributedString(string: marker, attributes: [.font: baseFont, .foregroundColor: textColor])
                let paragraph = NSMutableParagraphStyle()
                paragraph.firstLineHeadIndent = 0
                paragraph.headIndent = ceil(markerString.size().width)
                paragraph.paragraphSpacing = 2
                let item = NSMutableAttributedString(attributedString: markerString)
                item.append(renderInline(itemText, baseFont: baseFont, textColor: textColor))
                item.append(NSAttributedString(string: "\n"))
                item.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: item.length))
                result.append(item)
                continue
            }
            if line.hasPrefix(">") {
                flushParagraph()
                let text = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                let markerString = NSAttributedString(string: "\u{258E} ", attributes: [.font: baseFont, .foregroundColor: NSColor.systemGray])
                let paragraph = NSMutableParagraphStyle()
                paragraph.firstLineHeadIndent = 0
                paragraph.headIndent = ceil(markerString.size().width)
                let quote = NSMutableAttributedString(attributedString: markerString)
                quote.append(renderInline(text, baseFont: baseFont, textColor: textColor.withAlphaComponent(0.75)))
                quote.append(NSAttributedString(string: "\n"))
                quote.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: quote.length))
                result.append(quote)
                continue
            }
            paragraphBuffer += (paragraphBuffer.isEmpty ? "" : " ") + line
        }
        flushParagraph()
        flushCodeBlock()
        return result
    }

    /// `- `/`* ` bullets and `1. `-style ordered items, returned as (rendered marker prefix,
    /// remaining item text). Ordered items keep their own number rather than being renumbered —
    /// this is a renderer, not a formatter.
    private static func matchListItem(_ line: String) -> (marker: String, text: String)? {
        if line.hasPrefix("- ") || line.hasPrefix("* ") {
            return ("\u{2022}  ", String(line.dropFirst(2)))
        }
        var index = line.startIndex
        var digits = 0
        while index < line.endIndex, line[index].isNumber, digits < 4 {
            digits += 1
            index = line.index(after: index)
        }
        guard digits > 0, index < line.endIndex, line[index] == "." else { return nil }
        let afterDot = line.index(after: index)
        guard afterDot < line.endIndex, line[afterDot] == " " else { return nil }
        return ("\(line[line.startIndex..<index]).  ", String(line[line.index(after: afterDot)...]))
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
                    .font: codeFont, .foregroundColor: textColor, .backgroundColor: DS.Color.scrimSoft
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
                if urlString.hasPrefix("#") {
                    // In-document fragment — never a web URL. Rendered under a custom scheme so
                    // the preview's link delegate scrolls to the matching header (see
                    // `anchorSlugKey`) instead of the OS trying to open "#section" externally.
                    linkAttrs[.link] = URL(string: "\(anchorScheme):\(anchorSlug(for: String(urlString.dropFirst())))") as Any
                } else if let url = URL(string: urlString) {
                    linkAttrs[.link] = url
                }
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
