import AppKit

/// A parsed unified diff — the data half of the diff viewer. Deliberately its own type rather
/// than view-internal state so anything that produces `git diff` text (Review's branch diff,
/// Make's hunks, Heron's edit proposals) can feed the same renderer.
struct UnifiedDiff {
    struct Line {
        enum Kind { case added, removed, context }
        let kind: Kind
        let oldNumber: Int?
        let newNumber: Int?
        let text: String
    }

    struct Hunk {
        let header: String
        var lines: [Line] = []
    }

    struct File {
        let path: String
        let isNew: Bool
        let isDeleted: Bool
        var hunks: [Hunk] = []
        var addedCount: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .added }.count } }
        var removedCount: Int {
            hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .removed }.count }
        }
    }

    var files: [File] = []

    /// Parses full `git diff` output (with `diff --git` file headers). Header-only oddities
    /// (mode changes, binary files) come through as a file with zero hunks, which the card
    /// renders as just its header row — better than dropping them silently.
    static func parse(_ text: String) -> UnifiedDiff {
        var diff = UnifiedDiff()
        guard !text.isEmpty else { return diff }
        var currentFile: File?
        var currentHunk: Hunk?
        var oldLine = 0
        var newLine = 0

        func closeHunk() {
            if let hunk = currentHunk { currentFile?.hunks.append(hunk) }
            currentHunk = nil
        }
        func closeFile() {
            closeHunk()
            if let file = currentFile { diff.files.append(file) }
            currentFile = nil
        }

        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("diff --git ") {
                closeFile()
                // `diff --git a/path b/path` — take the b/ side (the file's current name).
                let bPath = line.range(of: " b/").map { String(line[$0.upperBound...]) } ?? line
                currentFile = File(path: bPath, isNew: false, isDeleted: false)
                continue
            }
            if line.hasPrefix("new file mode") {
                currentFile = currentFile.map {
                    File(path: $0.path, isNew: true, isDeleted: false, hunks: $0.hunks)
                }
                continue
            }
            if line.hasPrefix("deleted file mode") {
                currentFile = currentFile.map {
                    File(path: $0.path, isNew: false, isDeleted: true, hunks: $0.hunks)
                }
                continue
            }
            if line.hasPrefix("index ") || line.hasPrefix("--- ") || line.hasPrefix("+++ ")
                || line.hasPrefix("old mode") || line.hasPrefix("new mode")
                || line.hasPrefix("similarity index") || line.hasPrefix("rename ")
                || line.hasPrefix("Binary files")
            {
                continue
            }
            if line.hasPrefix("@@") {
                closeHunk()
                currentHunk = Hunk(header: line)
                // "@@ -oldStart,oldCount +newStart,newCount @@ …"
                let parts = line.split(separator: " ")
                if parts.count >= 3 {
                    oldLine =
                        Int(parts[1].dropFirst().split(separator: ",").first.map(String.init) ?? "")
                        ?? 0
                    newLine =
                        Int(parts[2].dropFirst().split(separator: ",").first.map(String.init) ?? "")
                        ?? 0
                }
                continue
            }
            guard currentHunk != nil else { continue }
            if line.hasPrefix("+") {
                currentHunk?.lines.append(
                    Line(
                        kind: .added, oldNumber: nil, newNumber: newLine,
                        text: String(line.dropFirst())))
                newLine += 1
            } else if line.hasPrefix("-") {
                currentHunk?.lines.append(
                    Line(
                        kind: .removed, oldNumber: oldLine, newNumber: nil,
                        text: String(line.dropFirst())))
                oldLine += 1
            } else if line.hasPrefix("\\") {
                continue  // "\ No newline at end of file" — metadata, not content.
            } else {
                currentHunk?.lines.append(
                    Line(
                        kind: .context, oldNumber: oldLine, newNumber: newLine,
                        text: String(line.dropFirst(line.isEmpty ? 0 : 1))))
                oldLine += 1
                newLine += 1
            }
        }
        closeFile()
        return diff
    }
}

/// The diff viewer: one collapsible card per file — filename header with +/− counts, line
/// numbers in a gutter, full-line tints for added/removed — instead of raw `git diff` text.
/// The design charter's flagship component; Review uses it today, Make's hunk review and
/// Heron's proposal cards are meant to adopt it.
final class DiffViewer: NSStackView {
    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 12
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func renderLoading() {
        arrangedSubviews.forEach { $0.removeFromSuperview() }
        let loading = NSTextField(labelWithString: "Loading diff…")
        loading.font = .systemFont(ofSize: 12)
        loading.textColor = .tertiaryLabelColor
        addArrangedSubview(loading)
    }

    func render(diffText: String) {
        arrangedSubviews.forEach { $0.removeFromSuperview() }
        let diff = UnifiedDiff.parse(diffText)
        guard !diff.files.isEmpty else {
            let empty = NSTextField(labelWithString: "No changes against this base.")
            empty.font = .systemFont(ofSize: 12)
            empty.textColor = .tertiaryLabelColor
            addArrangedSubview(empty)
            return
        }
        for file in diff.files {
            let card = DiffFileCardView(file: file)
            addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
    }
}

/// One file's card: header row (chevron, path, +/− counts, NEW/DELETED badge) over the rendered
/// hunk body; clicking the header collapses/expands the body.
final class DiffFileCardView: NSView {
    private let bodyScroll = NSScrollView()
    private let chevron = NSImageView()
    private var isCollapsed = false
    private var bodyHeightConstraint: NSLayoutConstraint?
    private let bodyHeight: CGFloat

    private static let addedText = NSColor(red: 0.45, green: 0.82, blue: 0.55, alpha: 1)
    private static let removedText = NSColor(red: 0.92, green: 0.50, blue: 0.48, alpha: 1)
    private static let addedFill = NSColor(red: 0.30, green: 0.85, blue: 0.40, alpha: 0.09)
    private static let removedFill = NSColor(red: 0.95, green: 0.35, blue: 0.30, alpha: 0.09)
    private static let hunkColor = NSColor(red: 0.55, green: 0.72, blue: 0.95, alpha: 1)

    init(file: UnifiedDiff.File) {
        // Sized to content up to a cap, so one file's giant diff scrolls inside its own card
        // instead of making the page unusable.
        let lineCount = file.hunks.reduce(0) { $0 + $1.lines.count + 1 }
        bodyHeight = min(CGFloat(lineCount) * 17 + 12, 420)

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = DS.Radius.card
        layer?.borderWidth = 1
        layer?.borderColor = DS.Color.hairline.cgColor
        layer?.backgroundColor = DS.Color.bg1.cgColor
        layer?.masksToBounds = true

        chevron.image = NSImage(
            systemSymbolName: "chevron.down", accessibilityDescription: "Collapse")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
        chevron.contentTintColor = .secondaryLabelColor
        chevron.wantsLayer = true

        let pathLabel = NSTextField(labelWithString: file.path)
        pathLabel.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        pathLabel.textColor = .labelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle

        let counts = NSTextField(labelWithString: "")
        let countsText = NSMutableAttributedString()
        countsText.append(
            NSAttributedString(
                string: "+\(file.addedCount)",
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold),
                    .foregroundColor: Self.addedText,
                ]))
        countsText.append(
            NSAttributedString(
                string: "  −\(file.removedCount)",
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold),
                    .foregroundColor: Self.removedText,
                ]))
        counts.attributedStringValue = countsText

        var headerViews: [NSView] = [chevron, pathLabel]
        if file.isNew || file.isDeleted {
            let badge = NSTextField(labelWithString: file.isNew ? "NEW" : "DELETED")
            badge.font = .systemFont(ofSize: 9.5, weight: .bold)
            badge.textColor = file.isNew ? Self.addedText : Self.removedText
            headerViews.append(badge)
        }
        headerViews.append(NSView())  // flexible spacer
        headerViews.append(counts)
        let header = NSStackView(views: headerViews)
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false
        if let spacer = headerViews.dropLast().last {
            spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        }

        let headerButton = HeaderClickView()
        headerButton.onClick = { [weak self] in self?.toggleCollapsed() }
        headerButton.translatesAutoresizingMaskIntoConstraints = false
        headerButton.addSubview(header)

        // Manual text stack so the layout manager can extend background fills to the full
        // line width (see FullWidthBackgroundLayoutManager).
        let storage = NSTextStorage()
        let layoutManager = FullWidthBackgroundLayoutManager()
        storage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(
            size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)
        let bodyText = NSTextView(frame: .zero, textContainer: textContainer)
        bodyText.isEditable = false
        bodyText.drawsBackground = false
        bodyText.textContainerInset = NSSize(width: 0, height: 4)
        bodyText.autoresizingMask = [.width]
        storage.setAttributedString(Self.renderBody(file))
        bodyScroll.documentView = bodyText
        bodyScroll.drawsBackground = false
        bodyScroll.hasVerticalScroller = true
        bodyScroll.translatesAutoresizingMaskIntoConstraints = false
        // Without this, the text view draws past the shrinking scroll frame during the fold
        // animation and slides visibly over the header row above it.
        bodyScroll.wantsLayer = true
        bodyScroll.layer?.masksToBounds = true

        let divider = NSBox()
        divider.boxType = .custom
        divider.borderType = .noBorder
        divider.fillColor = DS.Color.hairline
        divider.translatesAutoresizingMaskIntoConstraints = false

        addSubview(headerButton)
        addSubview(divider)
        addSubview(bodyScroll)
        let bodyConstraint = bodyScroll.heightAnchor.constraint(equalToConstant: bodyHeight)
        bodyHeightConstraint = bodyConstraint
        NSLayoutConstraint.activate([
            headerButton.topAnchor.constraint(equalTo: topAnchor),
            headerButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerButton.heightAnchor.constraint(equalToConstant: 34),
            header.leadingAnchor.constraint(equalTo: headerButton.leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: headerButton.trailingAnchor, constant: -12),
            header.centerYAnchor.constraint(equalTo: headerButton.centerYAnchor),
            divider.topAnchor.constraint(equalTo: headerButton.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),
            bodyScroll.topAnchor.constraint(equalTo: divider.bottomAnchor),
            bodyScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            bodyScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            bodyScroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            bodyConstraint,
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func toggleCollapsed() {
        isCollapsed.toggle()
        // Rotate the chevron a quarter turn rather than swapping glyphs — same duration as the
        // fold itself so the two read as one gesture.
        if let layer = chevron.layer {
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer.position = CGPoint(x: chevron.frame.midX, y: chevron.frame.midY)
            let rotate = CABasicAnimation(keyPath: "transform.rotation.z")
            rotate.fromValue = isCollapsed ? 0 : CGFloat.pi / 2
            rotate.toValue = isCollapsed ? CGFloat.pi / 2 : 0
            rotate.duration = 0.18
            rotate.timingFunction = CAMediaTimingFunction(name: .easeOut)
            rotate.isRemovedOnCompletion = false
            rotate.fillMode = .forwards
            layer.add(rotate, forKey: "chevronTurn")
        }
        // Expanding pairs the height animation with a fade-in — revealing already-laid-out
        // text through a growing clip reads as glitchy clipping; fading it in as the card
        // grows reads as content arriving.
        if !isCollapsed { bodyScroll.alphaValue = 0 }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            bodyHeightConstraint?.constant = isCollapsed ? 0 : bodyHeight
            bodyScroll.animator().alphaValue = isCollapsed ? 0 : 1
            window?.layoutIfNeeded()
        } completionHandler: { [weak self] in
            guard let self else { return }
            if self.isCollapsed { self.bodyScroll.alphaValue = 1 }
        }
    }

    /// The body as one attributed string — `[old# pad][new# pad] text` per line, full-line
    /// background tints for adds/removes — rather than a view per line, which would melt on a
    /// thousand-line diff.
    private static func renderBody(_ file: UnifiedDiff.File) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let numberColor = NSColor(white: 0.42, alpha: 1)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping

        func pad(_ number: Int?) -> String {
            guard let number else { return String(repeating: " ", count: 5) }
            return String(repeating: " ", count: max(0, 5 - "\(number)".count)) + "\(number)"
        }

        for hunk in file.hunks {
            result.append(
                NSAttributedString(
                    string: (result.length == 0 ? "" : "\n") + "  \(hunk.header)\n",
                    attributes: [
                        .font: font, .foregroundColor: hunkColor, .paragraphStyle: paragraph,
                    ]))
            for line in hunk.lines {
                let textColor: NSColor
                var background: NSColor?
                switch line.kind {
                case .added:
                    textColor = addedText
                    background = addedFill
                case .removed:
                    textColor = removedText
                    background = removedFill
                case .context:
                    textColor = .secondaryLabelColor
                    background = nil
                }
                var attrs: [NSAttributedString.Key: Any] = [
                    .font: font, .foregroundColor: numberColor, .paragraphStyle: paragraph,
                ]
                if let background { attrs[.backgroundColor] = background }
                result.append(
                    NSAttributedString(
                        string: "\(pad(line.oldNumber)) \(pad(line.newNumber))  ", attributes: attrs
                    ))
                attrs[.foregroundColor] = textColor
                result.append(NSAttributedString(string: line.text + "\n", attributes: attrs))
            }
        }
        return result
    }
}

/// The card header's click target — a plain view with a click handler, so the whole header row
/// (not just the chevron glyph) toggles the fold.
private final class HeaderClickView: NSView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        NSLog("DEBUG header mouseDown")
        onClick?()
    }
    /// The path/count labels inside the header would otherwise swallow the click — same
    /// route-decorative-hits-to-the-row trick TrackRowView uses.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }
}

/// Extends `.backgroundColor` attribute fills to the container's full width — a text
/// background normally stops at the last glyph, which left the diff's add/remove tints
/// looking like highlighter strokes instead of full-line row tints.
private final class FullWidthBackgroundLayoutManager: NSLayoutManager {
    override func fillBackgroundRectArray(
        _ rectArray: UnsafePointer<NSRect>, count rectCount: Int,
        forCharacterRange charRange: NSRange, color: NSColor
    ) {
        let fullWidth = textContainers.first?.size.width ?? 0
        var extended = (0..<rectCount).map { index -> NSRect in
            var rect = rectArray[index]
            rect.origin.x = 0
            rect.size.width = max(rect.width, fullWidth)
            return rect
        }
        extended.withUnsafeBufferPointer { buffer in
            super.fillBackgroundRectArray(
                buffer.baseAddress!, count: rectCount, forCharacterRange: charRange, color: color)
        }
    }
}
