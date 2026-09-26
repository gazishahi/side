import AppKit
import Heron

/// A parsed unified diff — the data half of the diff viewer. Deliberately its own type rather
/// than view-internal state so anything that produces `git diff` text (Review's branch diff,
/// Make's hunks, Heron's edit proposals) can feed the same renderer.
struct UnifiedDiff {
    struct Line: Equatable {
        enum Kind { case added, removed, context }
        let kind: Kind
        /// Numbers as 32 bits, -1 for none: a big diff has a hundred thousand of these.
        private let old: Int32
        private let new: Int32
        var oldNumber: Int? { old >= 0 ? Int(old) : nil }
        var newNumber: Int? { new >= 0 ? Int(new) : nil }
        /// The line's text, a slice of the diff it came from: a change set of 100,000 lines
        /// used to be as many strings of their own.
        let slice: Substring
        var text: String { String(slice) }

        init(kind: Kind, oldNumber: Int?, newNumber: Int?, text: String) {
            self.init(kind: kind, oldNumber: oldNumber, newNumber: newNumber, slice: Substring(text))
        }

        init(kind: Kind, oldNumber: Int?, newNumber: Int?, slice: Substring) {
            self.kind = kind
            old = oldNumber.map(Int32.init) ?? -1
            new = newNumber.map(Int32.init) ?? -1
            self.slice = slice
        }
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
        /// First to last new-side line the diff adds or keeps as context — what an instruct
        /// about this file points at.
        var changedNewLines: ClosedRange<Int>? {
            let added = hunks.flatMap(\.lines).filter { $0.kind == .added }.compactMap(\.newNumber)
            let numbers = added.isEmpty ? hunks.flatMap(\.lines).compactMap(\.newNumber) : added
            guard let low = numbers.min(), let high = numbers.max() else { return nil }
            return low...high
        }
    }

    var files: [File] = []

    /// Hunk-only text (no `diff --git` headers) — what `GitDiffComputer.unifiedDiffText`
    /// produces for proposal diffs. Wraps the shared line parser in a synthetic single file.
    static func parseHunks(_ text: String) -> [Hunk] {
        guard !text.isEmpty else { return [] }
        let wrapped = "diff --git a/x b/x\n" + text
        return parse(wrapped).files.first?.hunks ?? []
    }

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

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") {
                closeFile()
                // `diff --git a/path b/path` — take the b/ side (the file's current name).
                let bPath = line.range(of: " b/").map { String(line[$0.upperBound...]) } ?? String(line)
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
                currentHunk = Hunk(header: String(line))
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
                        slice: line.dropFirst()))
                newLine += 1
            } else if line.hasPrefix("-") {
                currentHunk?.lines.append(
                    Line(
                        kind: .removed, oldNumber: oldLine, newNumber: nil,
                        slice: line.dropFirst()))
                oldLine += 1
            } else if line.hasPrefix("\\") {
                continue  // "\ No newline at end of file" — metadata, not content.
            } else {
                currentHunk?.lines.append(
                    Line(
                        kind: .context, oldNumber: oldLine, newNumber: newLine,
                        slice: line.dropFirst(line.isEmpty ? 0 : 1)))
                oldLine += 1
                newLine += 1
            }
        }
        closeFile()
        return diff
    }
}

/// A file's diff as a card (`DiffFileCardView`) and the shared hunk renderer (`DiffBody`), for
/// Think's proposal cards, which show one small diff each. Review and the checkpoint sheet show
/// whole change sets with `DiffDocumentView` (Alloy), which costs what's on screen.
/// How a file's hunks are laid out. Unified is the shape every diff tool shares and the one that
/// fits Think's 620pt proposal cards; split needs two gutters and two code columns, which only
/// Review has the width for — so Think stays unified regardless of this setting.
enum DiffLayout: String, CaseIterable {
    case unified, sideBySide

    private static let key = "SideDiffLayout"
    static var preferred: DiffLayout {
        get { UserDefaults.standard.string(forKey: key).flatMap(DiffLayout.init) ?? .unified }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}

/// Pairs a hunk's lines into rows for a two-column view.
///
/// Context lines sit on both sides. A run of removals followed by a run of additions is a
/// *change*, and its lines pair up index-wise — the third removed line opposite the third added —
/// which is what makes a one-line edit read as one row with the old text left and the new text
/// right, instead of two rows with a blank each. Whatever the shorter run lacks is a blank cell,
/// so the two columns stay the same height row for row.
enum SideBySideRows {
    struct Row: Equatable {
        let left: UnifiedDiff.Line?
        let right: UnifiedDiff.Line?
        /// Set for the hunk-header row, which spans conceptually but renders in the left column.
        let headerText: String?
        var isHeader: Bool { headerText != nil }

        init(left: UnifiedDiff.Line?, right: UnifiedDiff.Line?) { self.left = left; self.right = right; headerText = nil }
        init(header: String) { left = nil; right = nil; headerText = header }
    }

    static func build(_ hunk: UnifiedDiff.Hunk) -> [Row] {
        var rows: [Row] = [Row(header: hunk.header)]
        var removed: [UnifiedDiff.Line] = []
        var added: [UnifiedDiff.Line] = []
        func flush() {
            let count = max(removed.count, added.count)
            for index in 0..<count {
                rows.append(Row(left: index < removed.count ? removed[index] : nil,
                                right: index < added.count ? added[index] : nil))
            }
            removed.removeAll(); added.removeAll()
        }
        for line in hunk.lines {
            switch line.kind {
            case .removed: added.isEmpty ? removed.append(line) : { flush(); removed.append(line) }()
            case .added: added.append(line)
            case .context:
                flush()
                rows.append(Row(left: line, right: line))
            }
        }
        flush()
        return rows
    }
}

/// One file: a `code` header row on canvas (chevron, path, +/− counts, NEW/DELETED) over its
/// diff body, which is the `raised` surface (§4.2). Clicking the header folds the body —
/// instantly: expansion is not something anyone waits to watch.
final class DiffFileCardView: NSView {
    private let bodyScroll = NSScrollView()
    private let bodySurface = NSView()
    private let chevron = NSImageView()
    private let pathLabel = NSTextField(labelWithString: "")
    private let headerButton = HeaderClickView()
    private var isCollapsed = false
    private var bodyHeightConstraint: NSLayoutConstraint?
    private var bodyBottomGap: NSLayoutConstraint?
    /// Set from the text's *measured* height once it has been laid out, not from a guess.
    private var bodyHeight: CGFloat = 0
    private static let maximumBodyHeight: CGFloat = 420

    private static let addedText = DiffBody.addedText
    private static let removedText = DiffBody.removedText

    /// The height the text actually needs, from the layout manager that will draw it.
    private static func measuredHeight(of textView: NSTextView) -> CGFloat {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else {
            return maximumBodyHeight
        }
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container).height
        // A little breathing room below the last line, and never zero for an empty diff.
        return max(24, ceil(used) + textView.textContainerInset.height * 2 + 4)
    }

    /// "Instruct…" in the header, revealed on hover; nil hides it.
    var onInstruct: ((NSView) -> Void)? {
        didSet {
            instructButton.isHidden = onInstruct == nil
            headerButton.instructAction = onInstruct == nil ? nil : { [weak self] in self?.instructTapped() }
        }
    }
    private let instructButton = NSButton(title: "", target: nil, action: nil)
    private var headerTracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let headerTracking { removeTrackingArea(headerTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        headerTracking = area
    }
    override func mouseEntered(with event: NSEvent) { instructButton.animator().alphaValue = 1 }
    override func mouseExited(with event: NSEvent) { instructButton.animator().alphaValue = 0 }
    @objc private func instructTapped() { onInstruct?(instructButton) }

    init(file: UnifiedDiff.File, layout: DiffLayout = .unified) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        chevron.image = NSImage(
            systemSymbolName: "chevron.down", accessibilityDescription: "Collapse")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
        chevron.contentTintColor = .secondaryLabelColor
        chevron.wantsLayer = true

        pathLabel.stringValue = file.path
        pathLabel.font = DS.Text.code(12, weight: .medium)
        // The expanded file reads in the label colour; folded ones recede (§4.2).
        pathLabel.textColor = .labelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle

        let counts = NSTextField(labelWithString: "")
        let countsText = NSMutableAttributedString()
        countsText.append(
            NSAttributedString(
                string: "+\(file.addedCount)",
                attributes: [
                    .font: DS.Text.code(11, weight: .semibold),
                    .foregroundColor: Self.addedText,
                ]))
        countsText.append(
            NSAttributedString(
                string: "  −\(file.removedCount)",
                attributes: [
                    .font: DS.Text.code(11, weight: .semibold),
                    .foregroundColor: Self.removedText,
                ]))
        counts.attributedStringValue = countsText

        var headerViews: [NSView] = [chevron, pathLabel]
        if file.isNew || file.isDeleted {
            let badge = NSTextField(labelWithString: file.isNew ? "NEW" : "DELETED")
            badge.font = DS.Text.caption(.bold)
            badge.textColor = file.isNew ? Self.addedText : Self.removedText
            headerViews.append(badge)
        }
        headerViews.append(NSView())  // flexible spacer
        instructButton.isBordered = false
        instructButton.attributedTitle = NSAttributedString(string: "Instruct\u{2026}", attributes: [.font: DS.Text.caption(.medium), .foregroundColor: NSColor.labelColor])
        instructButton.target = self
        instructButton.action = #selector(instructTapped)
        instructButton.alphaValue = 0
        instructButton.isHidden = true
        instructButton.setAccessibilityLabel("Instruct about \(file.path)")
        headerViews.append(instructButton)
        headerViews.append(counts)
        let header = NSStackView(views: headerViews)
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = DS.Spacing.m
        header.translatesAutoresizingMaskIntoConstraints = false
        if let spacer = headerViews.dropLast().last {
            spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        }

        headerButton.onClick = { [weak self] in self?.toggleCollapsed() }
        headerButton.fileDescription = Self.accessibilityDescription(for: file)
        headerButton.isCollapsed = false
        headerButton.translatesAutoresizingMaskIntoConstraints = false
        headerButton.addSubview(header)

        let bodyDocument: NSView
        let measureFrom: NSTextView
        switch layout {
        case .unified:
            let bodyText = DiffBody.makeBodyTextView()
            DiffBody.fill(bodyText, hunks: file.hunks)
            bodyDocument = bodyText
            measureFrom = bodyText
        case .sideBySide:
            let rows = file.hunks.flatMap(SideBySideRows.build)
            let left = DiffBody.makeBodyTextView()
            let right = DiffBody.makeBodyTextView()
            DiffBody.fillColumn(left, rows: rows, side: .left)
            DiffBody.fillColumn(right, rows: rows, side: .right)
            // One document holding both columns, so a single scroller moves them together and a
            // row's two halves can never drift apart. Equal widths; a hairline between.
            let divider = NSBox()
            divider.boxType = .custom
            divider.borderType = .noBorder
            divider.fillColor = DS.Color.hairline
            divider.translatesAutoresizingMaskIntoConstraints = false
            divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
            let columns = SideBySideDocumentView(left: left, right: right, divider: divider)
            bodyDocument = columns
            measureFrom = left
        }
        // Measured from the laid-out glyphs rather than assumed from a line count.
        //
        // The previous version multiplied the line count by a hard-coded 17pt. That number is
        // not the font's actual line height, and it also counted a synthetic extra line per
        // hunk, so every card reserved more room than its text occupied — visible as a large
        // band of empty space under the last line of a diff. Sized to content up to a cap, so
        // one enormous file still scrolls inside its own card instead of making the page
        // unusable.
        bodyHeight = min(Self.measuredHeight(of: measureFrom), Self.maximumBodyHeight)
        bodyScroll.documentView = bodyDocument
        bodyScroll.drawsBackground = false
        bodyScroll.hasVerticalScroller = true
        bodyScroll.translatesAutoresizingMaskIntoConstraints = false
        // Without this, the text view draws past the shrinking scroll frame during the fold
        // animation and slides visibly over the header row above it.
        bodyScroll.wantsLayer = true
        bodyScroll.layer?.masksToBounds = true

        // The diff body is the card: `raised`, radius 10, no border (§4.2).
        bodySurface.wantsLayer = true
        bodySurface.layer?.cornerRadius = DS.Radius.surface
        bodySurface.layer?.masksToBounds = true
        bodySurface.bindLayerBackground(DS.Color.raised)
        bodySurface.translatesAutoresizingMaskIntoConstraints = false
        bodySurface.addSubview(bodyScroll)

        addSubview(headerButton)
        addSubview(bodySurface)
        let bodyConstraint = bodyScroll.heightAnchor.constraint(equalToConstant: bodyHeight)
        bodyHeightConstraint = bodyConstraint
        let bottomGap = bodySurface.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.bodyGap)
        bodyBottomGap = bottomGap
        NSLayoutConstraint.activate([
            headerButton.topAnchor.constraint(equalTo: topAnchor),
            headerButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerButton.heightAnchor.constraint(equalToConstant: 34),
            header.leadingAnchor.constraint(equalTo: headerButton.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: headerButton.trailingAnchor),
            header.centerYAnchor.constraint(equalTo: headerButton.centerYAnchor),
            bodySurface.topAnchor.constraint(equalTo: headerButton.bottomAnchor),
            bodySurface.leadingAnchor.constraint(equalTo: leadingAnchor),
            bodySurface.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomGap,
            bodyScroll.topAnchor.constraint(equalTo: bodySurface.topAnchor),
            bodyScroll.leadingAnchor.constraint(equalTo: bodySurface.leadingAnchor),
            bodyScroll.trailingAnchor.constraint(equalTo: bodySurface.trailingAnchor),
            bodyScroll.bottomAnchor.constraint(equalTo: bodySurface.bottomAnchor),
            bodyConstraint,
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Reads the way someone would say it out loud, and leads with the filename so a rotor
    /// list of these is scannable: "greeter.ts, 12 added, 3 removed, new file".
    private static func accessibilityDescription(for file: UnifiedDiff.File) -> String {
        var parts = [file.path]
        parts.append(file.addedCount == 1 ? "1 line added" : "\(file.addedCount) lines added")
        parts.append(file.removedCount == 1 ? "1 line removed" : "\(file.removedCount) lines removed")
        if file.isNew { parts.append("new file") }
        if file.isDeleted { parts.append("deleted file") }
        return parts.joined(separator: ", ")
    }

    /// Space under an expanded body before the next file's hairline.
    private static let bodyGap: CGFloat = 10

    private func toggleCollapsed() {
        isCollapsed.toggle()
        headerButton.isCollapsed = isCollapsed
        // Without this, VoiceOver keeps reading the state it was told at build time — the
        // element's own value changed, and nothing else announces it.
        NSAccessibility.post(element: headerButton, notification: .valueChanged)
        chevron.image = NSImage(
            systemSymbolName: isCollapsed ? "chevron.right" : "chevron.down",
            accessibilityDescription: isCollapsed ? "Expand" : "Collapse")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
        pathLabel.textColor = isCollapsed ? .secondaryLabelColor : .labelColor
        bodySurface.isHidden = isCollapsed
        bodyHeightConstraint?.constant = isCollapsed ? 0 : bodyHeight
        bodyBottomGap?.constant = isCollapsed ? 0 : -Self.bodyGap
    }

}

/// The shared hunk-body renderer — one attributed string with line-number gutters and
/// full-line tints, plus the custom text stack whose layout manager extends those tints to the
/// full line width. Used by Review's per-file cards and Think's proposal cards, so a diff reads
/// identically wherever it appears.
enum DiffBody {
    static let addedText = DS.Color.statusVerified
    static let removedText = DS.Color.statusFailed
    static let addedFill = DS.Color.diffAdded
    static let removedFill = DS.Color.diffRemoved
    static let hunkColor = NSColor.tertiaryLabelColor

    /// `[old# pad][new# pad] text` per line — one attributed string, not a view per line,
    /// which would melt on a thousand-line diff.
    static func attributedBody(hunks: [UnifiedDiff.Hunk]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let font = DS.Text.code(11, weight: .regular)
        let numberColor = NSColor.quaternaryLabelColor
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping

        func pad(_ number: Int?) -> String {
            guard let number else { return String(repeating: " ", count: 5) }
            return String(repeating: " ", count: max(0, 5 - "\(number)".count)) + "\(number)"
        }

        for hunk in hunks {
            result.append(NSAttributedString(
                string: (result.length == 0 ? "" : "\n") + "  \(hunk.header)\n",
                attributes: [.font: font, .foregroundColor: hunkColor, .paragraphStyle: paragraph]))
            for line in hunk.lines {
                let textColor: NSColor
                var background: NSColor?
                switch line.kind {
                case .added: textColor = addedText; background = addedFill
                case .removed: textColor = removedText; background = removedFill
                case .context: textColor = .secondaryLabelColor; background = nil
                }
                var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: numberColor, .paragraphStyle: paragraph]
                if let background { attrs[.backgroundColor] = background }
                result.append(NSAttributedString(string: "\(pad(line.oldNumber)) \(pad(line.newNumber))  ", attributes: attrs))
                attrs[.foregroundColor] = textColor
                result.append(NSAttributedString(string: line.text + "\n", attributes: attrs))
            }
        }
        return result
    }

    enum Side { case left, right }

    /// One column of a side-by-side view: `[num]  text` per row, the same fills as unified, and a
    /// faint wash on a blank cell so the eye reads it as "nothing here" rather than as an empty
    /// line of code. Row count and line breaking are identical to the other column's by
    /// construction — every row emits exactly one clipped line — which is what keeps the two
    /// columns aligned without any cross-measurement.
    static func attributedColumn(rows: [SideBySideRows.Row], side: Side) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let font = DS.Text.code(11, weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        func pad(_ number: Int?) -> String {
            guard let number else { return String(repeating: " ", count: 5) }
            return String(repeating: " ", count: max(0, 5 - "\(number)".count)) + "\(number)"
        }
        var isFirstHeader = true
        for row in rows {
            if row.isHeader {
                // The header text lives in the left column; the right gets a matching blank row.
                let text = side == .left ? "  \(row.headerText ?? "")" : ""
                result.append(NSAttributedString(
                    string: (isFirstHeader ? "" : "\n") + text + "\n",
                    attributes: [.font: font, .foregroundColor: hunkColor, .paragraphStyle: paragraph]))
                isFirstHeader = false
                continue
            }
            let line = side == .left ? row.left : row.right
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.quaternaryLabelColor, .paragraphStyle: paragraph]
            guard let line else {
                attrs[.backgroundColor] = DS.Color.scrimFaint
                result.append(NSAttributedString(string: pad(nil) + "  \n", attributes: attrs))
                continue
            }
            let textColor: NSColor
            switch line.kind {
            case .added: textColor = addedText; attrs[.backgroundColor] = addedFill
            case .removed: textColor = removedText; attrs[.backgroundColor] = removedFill
            case .context: textColor = .secondaryLabelColor
            }
            result.append(NSAttributedString(string: "\(pad(side == .left ? line.oldNumber : line.newNumber))  ", attributes: attrs))
            attrs[.foregroundColor] = textColor
            result.append(NSAttributedString(string: line.text + "\n", attributes: attrs))
        }
        return result
    }

    static func fillColumn(_ textView: DiffBodyTextView, rows: [SideBySideRows.Row], side: Side) {
        textView.textStorage?.setAttributedString(attributedColumn(rows: rows, side: side))
        textView.setLineKinds(rows: rows, side: side)
    }

    /// A text view whose layout manager extends `.backgroundColor` fills to the full line
    /// width — assembled manually because that requires a custom NSLayoutManager.
    static func makeBodyTextView() -> DiffBodyTextView {
        let storage = NSTextStorage()
        let layoutManager = FullWidthBackgroundLayoutManager()
        storage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)
        let textView = DiffBodyTextView(frame: .zero, textContainer: textContainer)
        textView.isEditable = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.autoresizingMask = [.width]
        return textView
    }

    /// Fills a body view with a file's hunks *and* the per-line kinds its accessibility text
    /// needs. Always use this rather than assigning the text storage directly, or the AX
    /// reading silently falls back to unmarked text.
    static func fill(_ textView: DiffBodyTextView, hunks: [UnifiedDiff.Hunk]) {
        textView.textStorage?.setAttributedString(attributedBody(hunks: hunks))
        textView.setLineKinds(hunks)
    }
}

/// The diff body, with the gutter's meaning available as words.
///
/// The visual design carries add/remove in color and a gutter bar — deliberately, since `+`/`-`
/// prefixes make a diff harder to read and can't be copied cleanly. But color is the *only*
/// carrier, which means the text a screen reader (or anyone who can't distinguish those greens
/// and reds) receives is a flat wall of code where nothing says which lines changed. That's the
/// gutter-meaning gap the audit named.
///
/// The fix keeps the visible text untouched and marks up only what accessibility reads: each
/// changed line is prefixed "added, " or "removed, ", and hunk headers become "section, ".
final class DiffBodyTextView: NSTextView {
    /// One entry per rendered line, in order, mirroring `DiffBody.attributedBody`'s output.
    private enum LineKind { case hunkHeader, added, removed, context }
    private var lineKinds: [LineKind] = []

    /// One entry per row, for one column of a split view. A blank cell reads as context — there
    /// is nothing to announce about it — and the header row as a section, same as unified.
    func setLineKinds(rows: [SideBySideRows.Row], side: DiffBody.Side) {
        var kinds: [LineKind] = []
        var isFirstHeader = true
        for row in rows {
            if row.isHeader {
                if !isFirstHeader { kinds.append(.context) }
                kinds.append(.hunkHeader)
                isFirstHeader = false
                continue
            }
            switch (side == .left ? row.left : row.right)?.kind {
            case .added?: kinds.append(.added)
            case .removed?: kinds.append(.removed)
            case .context?, nil: kinds.append(.context)
            }
        }
        lineKinds = kinds
    }

    func setLineKinds(_ hunks: [UnifiedDiff.Hunk]) {
        var kinds: [LineKind] = []
        for hunk in hunks {
            if !kinds.isEmpty { kinds.append(.context) }  // the blank separator line
            kinds.append(.hunkHeader)
            for line in hunk.lines {
                switch line.kind {
                case .added: kinds.append(.added)
                case .removed: kinds.append(.removed)
                case .context: kinds.append(.context)
                }
            }
        }
        lineKinds = kinds
    }

    /// Marked text, built from the real content so it can't drift out of sync with what's shown.
    /// Exposed as the AX value: VoiceOver reads a text area's value, and a value that omits the
    /// one thing a diff is *for* isn't worth the fidelity of leaving it unmarked.
    private func accessibleText() -> String {
        let raw = string
        guard !lineKinds.isEmpty else { return raw }
        var marked: [String] = []
        for (index, line) in raw.components(separatedBy: "\n").enumerated() {
            // A trailing empty component from the final newline has no kind and no content.
            guard index < lineKinds.count else {
                if !line.isEmpty { marked.append(line) }
                continue
            }
            switch lineKinds[index] {
            case .added: marked.append("added, " + line)
            case .removed: marked.append("removed, " + line)
            case .hunkHeader: marked.append("section, " + line)
            case .context: marked.append(line)
            }
        }
        return marked.joined(separator: "\n")
    }

    override func accessibilityLabel() -> String? { "Diff" }
    override func accessibilityValue() -> String? { accessibleText() }
    /// Kept consistent with the value above — a length that describes different text than the
    /// value is worse than either alone.
    override func accessibilityNumberOfCharacters() -> Int { accessibleText().count }
}

/// The card header's click target — a plain view with a click handler, so the whole header row
/// (not just the chevron glyph) toggles the fold.
private final class HeaderClickView: NSView {
    var onClick: (() -> Void)?
    /// Everything the header says visually, so the AX label can say it too. "Toggle diff" told
    /// a screen-reader user there was a control here but not what it acted on — with a dozen
    /// cards on a Review page that's a dozen identical, useless announcements.
    var fileDescription = ""
    var isCollapsed = false

    override func mouseDown(with event: NSEvent) { onClick?() }
    /// The path/count labels inside the header would otherwise swallow the click — same
    /// route-decorative-hits-to-the-row trick TrackRowView uses.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        // A real control in the header (Instruct…) keeps its own click.
        return hit is NSButton ? hit : self
    }
    /// Reaches "Instruct…" without hovering for it.
    var instructAction: (() -> Void)?
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard let instructAction else { return nil }
        return [NSAccessibilityCustomAction(name: "Instruct…") { instructAction(); return true }]
    }

    // Hand-rolled click target — invisible and dead to accessibility without these.
    override func isAccessibilityElement() -> Bool { true }
    /// A disclosure triangle is what it behaves like, and the role is what tells VoiceOver to
    /// read the expanded state at all.
    override func accessibilityRole() -> NSAccessibility.Role? { .disclosureTriangle }
    override func accessibilityLabel() -> String? { fileDescription }
    override func accessibilityValue() -> Any? { isCollapsed ? "collapsed" : "expanded" }
    /// Named for the *effect*, which is what a rotor's action list shows.
    override func accessibilityActionDescription(_ action: NSAccessibility.Action) -> String? {
        action == .press ? (isCollapsed ? "Expand" : "Collapse") : nil
    }
    override func isAccessibilityExpanded() -> Bool { !isCollapsed }
    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
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


/// Both columns of a split diff in one scroll document: equal widths, a hairline between, heights
/// driven by the columns' own text so the enclosing card can measure one of them.
final class SideBySideDocumentView: NSView {
    init(left: NSTextView, right: NSTextView, divider: NSView) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        for view in [left, divider, right] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        left.autoresizingMask = []
        right.autoresizingMask = []
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: leadingAnchor),
            left.topAnchor.constraint(equalTo: topAnchor),
            left.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: left.trailingAnchor),
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            right.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            right.trailingAnchor.constraint(equalTo: trailingAnchor),
            right.topAnchor.constraint(equalTo: topAnchor),
            right.bottomAnchor.constraint(equalTo: bottomAnchor),
            left.widthAnchor.constraint(equalTo: right.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    /// Tracks the clip view's width so both columns fill it; the height is the text's own.
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard let clip = superview as? NSClipView else { return }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalTo: clip.widthAnchor),
            topAnchor.constraint(equalTo: clip.topAnchor),
            leadingAnchor.constraint(equalTo: clip.leadingAnchor),
        ])
    }
}
