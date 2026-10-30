import AlloyAppKit
import AlloyCore
import AlloyRender
import AlloySyntax
import AppKit
import Heron

/// Review's diff (SIDE_RFC_FIND_REVIEW_TRACKS.md, R2): every file in one read-only Alloy
/// document, so a change set of any size costs what's on screen. Alloy lays out and draws only
/// the visible lines; file headers are views over their rows, made only for the files in view.
///
/// Each file is two header rows (its path, hidden under the header view, then a blank row),
/// then, unless folded, its hunks: a `@@` row and the lines. Split is two documents with the
/// same rows, scrolled together. Lines are tinted edge to edge, colored by the file's language
/// where Alloy knows it, numbered old and new in the gutter, and read to VoiceOver as
/// "added, …" and "removed, …".
@MainActor
final class DiffDocumentView: NSView {
    var diffLayout: DiffLayout = .preferred { didSet { if diffLayout != oldValue { rebuild(keepingPosition: true) } } }
    /// How much of the bottom something floats over (the stage bar): the text scrolls under it.
    var bottomInset: CGFloat = 0 { didSet { applyInsets() } }

    private func applyInsets() {
        for column in columns {
            column.editor.scrollView.automaticallyAdjustsContentInsets = false
            column.editor.scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: bottomInset, right: 0)
        }
    }

    /// "Instruct…" on a file's header: its path, the new-side lines it touches, the anchor.
    var onInstruct: ((String, ClosedRange<Int>, NSView) -> Void)?
    /// The file at the top of the view changed (scrolling): Review's file list follows it.
    var onTopFileChange: ((Int) -> Void)?
    /// A file was folded or opened from its header.
    var onFoldChange: ((Int, Bool) -> Void)?
    private var topFile: Int?

    private(set) var diff = UnifiedDiff()
    private var folded: Set<Int> = []
    private var message: NSTextField?

    /// One row of a column. Both columns of a split share the kinds, so they line up.
    private enum Row {
        case fileTop(Int), fileBottom(Int), gap
        case hunk(file: Int, header: String)
        case line(file: Int, LineInfo)
    }

    /// What a row needs of its line once the column's text is built: its kind and numbers.
    /// The line itself (its text) was copied into every row, most of a big diff's memory.
    private struct LineInfo {
        /// nil: the blank opposite an added or removed line in a split.
        let kind: UnifiedDiff.Line.Kind?
        let old: Int32
        let new: Int32
        init(_ line: UnifiedDiff.Line?) {
            kind = line?.kind
            old = line?.oldNumber.map(Int32.init) ?? -1
            new = line?.newNumber.map(Int32.init) ?? -1
        }
        var oldNumber: Int? { old >= 0 ? Int(old) : nil }
        var newNumber: Int? { new >= 0 ? Int(new) : nil }
    }

    private struct Column {
        let editor: AlloyEditorView
        var rows: [Row] = []
        /// Per file: its rows' text in this column, for syntax colors, and where its lines start.
        var fileText: [Int: (firstRow: Int, rows: [Int])] = [:]
        var highlighters: [Int: SyntaxHighlighter?] = [:]
        /// Files by when they were last colored; past `highlighterLimit`, the oldest lets go.
        var highlighterOrder: [Int] = []
        /// Per row: its index among its file's line rows (-1 for other rows), and its length.
        var localIndex: [Int] = []
        var lengths: [Int] = []
        /// Each file's header row.
        var headerRow: [Int: Int] = [:]
        let side: DiffBody.Side?
    }

    private var columns: [Column] = []
    /// Bumped on every rebuild, so work started for old columns doesn't land in new ones.
    private var columnsGeneration = 0
    /// Files waiting to see whether they stay in view long enough to color (column side, file).
    private var pendingHighlights: Set<String> = []
    /// How long a file has to stay on screen before it's colored. A fling passes hundreds of
    /// files; coloring each one it passed started a full parse per file, on its own queue, and
    /// used every core (the owner's report, 2026-09-30: 100–167% CPU, and lag). Plain text for
    /// a moment, then color, costs almost nothing.
    private static let highlightDelay: TimeInterval = 0.15
    private let divider = NSBox()
    /// The file headers over their rows, in this view's coordinates; only those in view exist.
    private let headerLayer = HeaderLayerView()
    private var headers: [Int: DiffFileHeader] = [:]
    private var syncingScroll = false

    /// Syntax trees kept at once: a screen shows a few files; scrolling through hundreds
    /// shouldn't keep a tree for each.
    private static let highlighterLimit = 12
    private static let gutterWidthUnified: CGFloat = 86
    private static let gutterWidthSplit: CGFloat = 52

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        NotificationCenter.default.addObserver(self, selector: #selector(editorThemeChanged), name: EditorThemes.didChangeNotification, object: nil)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = DS.Radius.surface
        layer?.masksToBounds = true
        divider.boxType = .custom
        divider.borderType = .noBorder
        divider.fillColor = DS.Color.hairline
        headerLayer.translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Showing a diff

    func renderLoading() { show(message: "Loading diff…") }

    /// Lets go of the document and the parsed diff (Review, away for a while).
    func releaseDocument() {
        tearDownColumns()
        columnsGeneration += 1
        diff = UnifiedDiff()
        folded = []
        topFile = nil
    }

    /// `folding` picks the files that start folded (Review folds the ones marked viewed).
    func render(diffText: String, emptyMessage: String = "No changes against this base.", folding: ((UnifiedDiff) -> Set<Int>)? = nil) {
        diff = UnifiedDiff.parse(diffText)
        folded = folding?(diff) ?? []
        topFile = nil
        guard !diff.files.isEmpty else { show(message: emptyMessage); return }
        message?.removeFromSuperview()
        message = nil
        rebuild(keepingPosition: false)
        // Parsing and building let go of a lot at once; the pages go back to the system rather
        // than sitting in the allocator as free space counted against Side.
        DispatchQueue.main.async { malloc_zone_pressure_relief(nil, 0) }
    }

    private func show(message text: String) {
        tearDownColumns()
        message?.removeFromSuperview()
        let label = NSTextField(labelWithString: text)
        label.font = DS.Text.body()
        label.textColor = .tertiaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: DS.Spacing.section),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])
        message = label
        layer?.backgroundColor = nil
    }

    /// The files' row where the first visible line is, to keep the view there across a rebuild.
    private func anchor() -> (file: Int, offset: CGFloat)? {
        guard let first = columns.first else { return nil }
        let top = first.editor.scrollY
        let row = first.editor.documentLayout.line(atY: top).line
        guard first.rows.indices.contains(row) else { return nil }
        guard let file = file(atRow: row, in: first), let headerRow = first.headerRow[file] else { return nil }
        return (file, top - first.editor.documentLayout.caretRect(at: first.editor.buffer.text.offset(ofLine: headerRow)).minY)
    }

    private func rebuild(keepingPosition: Bool) {
        guard !diff.files.isEmpty else { return }
        // A theme of the other appearance: the headers and numbers take its appearance, as
        // Make's chrome does, so they read on its background. First: the change of appearance
        // may rebuild at once.
        let chrome = EditorThemes.chromeAppearance()
        if appearance?.name != chrome?.name {
            appearance = chrome
            DS.LayerBindings.reapplyAll()
        }
        let keep = keepingPosition ? anchor() : nil
        tearDownColumns()
        columnsGeneration += 1
        layer?.backgroundColor = backdrop.cgColor
        for header in Array(headers.values) + headerPool { header.bindLayerBackground(backdrop) }
        let sides: [DiffBody.Side?] = diffLayout == .sideBySide ? [.left, .right] : [nil]
        for side in sides {
            guard let column = makeColumn(side: side) else { return }
            columns.append(column)
        }
        layoutColumns()
        applyInsets()
        if let keep, let first = columns.first, let headerRow = first.headerRow[keep.file] {
            first.editor.layoutSubtreeIfNeeded()
            let y = first.editor.documentLayout.caretRect(at: first.editor.buffer.text.offset(ofLine: headerRow)).minY + keep.offset
            for column in columns { column.editor.scrollY = y }
        }
        refreshHeaders()
    }

    private func tearDownColumns() {
        for column in columns {
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: column.editor.scrollView.contentView)
            NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: column.editor.scrollView.contentView)
            column.editor.gutter.removeFromSuperview()
            column.editor.removeFromSuperview()
        }
        columns = []
        divider.removeFromSuperview()
        headerLayer.removeFromSuperview()
        headers.values.forEach { $0.removeFromSuperview() }
        headers = [:]
        headerPool.forEach { $0.removeFromSuperview() }
        headerPool = []
    }

    // MARK: Columns

    private func makeColumn(side: DiffBody.Side?) -> Column? {
        var rows: [Row] = []
        var fileText: [Int: (firstRow: Int, rows: [Int])] = [:]
        // The column's text built with its rows, straight from the diff's slices.
        var text = ""
        var lengths = [Int]()
        func add(_ row: Row, _ slice: Substring? = nil) {
            if !rows.isEmpty { text.append("\n") }
            if let slice { text.append(contentsOf: slice) }
            lengths.append(slice?.utf16.count ?? 0)
            rows.append(row)
        }
        for (index, file) in diff.files.enumerated() {
            // Space after a file's lines; a folded file is only its header, so none.
            if index > 0, !folded.contains(index - 1) { add(.gap) }
            add(.fileTop(index))
            add(.fileBottom(index))
            guard !folded.contains(index) else { continue }
            var own: [Int] = []
            for hunk in file.hunks {
                add(.hunk(file: index, header: hunk.header), Substring(hunk.header))
                if let side {
                    for pair in SideBySideRows.build(hunk) where !pair.isHeader {
                        own.append(rows.count)
                        let line = side == .left ? pair.left : pair.right
                        add(.line(file: index, LineInfo(line)), line?.slice)
                    }
                } else {
                    for line in hunk.lines {
                        own.append(rows.count)
                        add(.line(file: index, LineInfo(line)), line.slice)
                    }
                }
            }
            fileText[index] = (own.first ?? rows.count, own)
        }
        var localIndex = [Int](repeating: -1, count: rows.count)
        for (_, own) in fileText { for (i, row) in own.rows.enumerated() { localIndex[row] = i } }
        let font = DS.Text.Fonts.font(.editor, size: 12)
        guard let editor = try? AlloyEditorView(buffer: TextBuffer(text), font: font as CTFont) else { return nil }
        editor.isEditable = false
        editor.wrapsLines = false
        // A diff folds by file, from its headers; indentation folds would cut through hunks.
        editor.isFoldingEnabled = false
        // No band above the first file: its header starts at the top edge, as each later one
        // starts at its own row.
        editor.documentLayout.insets = CGSize(width: 12, height: 0)
        editor.accessibilityName = side == nil ? "Diff" : (side == .left ? "Diff, before" : "Diff, after")
        var column = Column(editor: editor, rows: rows, fileText: fileText, side: side)
        column.localIndex = localIndex
        column.lengths = lengths
        for (row, kind) in rows.enumerated() { if case .fileTop(let file) = kind { column.headerRow[file] = row } }
        configure(&column)
        return column
    }

    private func configure(_ column: inout Column) {
        let editor = column.editor
        let rows = column.rows
        let side = column.side
        let lengths = column.lengths
        // The system's appearance picks the theme; this view may wear the theme's own.
        let dark = DS.Appearance.isDark
        func tint(_ color: NSColor) -> SIMD4<Float> {
            var resolved = color
            effectiveAppearance.performAsCurrentDrawingAppearance { resolved = color.usingColorSpace(.sRGB) ?? color }
            return [Float(resolved.redComponent), Float(resolved.greenComponent), Float(resolved.blueComponent), Float(resolved.alphaComponent)]
        }
        editor.gutter.font = DS.Text.code(11, weight: .regular)
        if let theme = EditorThemes.current(dark: dark) {
            editor.theme = RenderTheme(background: theme.background.simd, text: theme.text.simd, selection: theme.selection.simd,
                                       caret: [0, 0, 0, 0], currentLine: [0, 0, 0, 0])
            editor.gutter.backgroundColor = theme.background.nsColor
            editor.gutter.numberColor = theme.lineNumbers.nsColor
        } else {
            editor.gutter.numberColor = .quaternaryLabelColor
            editor.gutter.backgroundColor = DS.Color.raised
            editor.theme = RenderTheme(background: tint(DS.Color.raised), text: tint(.labelColor), selection: tint(.selectedTextBackgroundColor),
                                       caret: [0, 0, 0, 0], currentLine: [0, 0, 0, 0])
        }
        let added = tint(DiffBody.addedFill), removed = tint(DiffBody.removedFill), blank = tint(DS.Color.scrimFaint)
        editor.lineBackground = { row in
            guard rows.indices.contains(row), case .line(_, let line) = rows[row] else { return nil }
            switch line.kind {
            case .added?: return added
            case .removed?: return removed
            case nil: return blank
            case .context?: return nil
            }
        }
        let hunkColor = tint(DiffBody.hunkColor), addedText = tint(DiffBody.addedText), removedText = tint(DiffBody.removedText)
        let secondary = tint(.secondaryLabelColor)
        editor.styles = { [weak self] row in
            guard let self, rows.indices.contains(row) else { return [] }
            let length = lengths[row]
            switch rows[row] {
            case .hunk: return [StyleSpan(range: 0..<length, color: hunkColor)]
            case .line(let file, let line):
                if let spans = self.syntaxSpans(file: file, row: row, dark: dark, columnSide: side), !spans.isEmpty { return spans }
                let color: SIMD4<Float>
                switch line.kind {
                case .added?: color = addedText
                case .removed?: color = removedText
                default: color = secondary
                }
                return [StyleSpan(range: 0..<length, color: color)]
            default: return []
            }
        }
        // Old and new numbers in the gutter; nothing beside headers.
        func pad(_ number: Int?) -> String {
            guard let number else { return "     " }
            let text = "\(number)"
            return String(repeating: " ", count: max(0, 5 - text.count)) + text
        }
        editor.gutter.label = { row in
            guard rows.indices.contains(row), case .line(_, let line) = rows[row], line.kind != nil else { return nil }
            switch side {
            case .left?: return pad(line.oldNumber)
            case .right?: return pad(line.newNumber)
            case nil: return pad(line.oldNumber) + " " + pad(line.newNumber)
            }
        }
        // What the eye gets from color, in words.
        let paths = diff.files.map(\.path)
        editor.accessibilityLinePrefix = { row in
            guard rows.indices.contains(row) else { return nil }
            switch rows[row] {
            case .fileTop(let file): return "file, \(paths[file])"
            case .hunk: return "section, "
            case .line(_, let line):
                switch line.kind {
                case .added?: return "added, "
                case .removed?: return "removed, "
                default: return nil
                }
            default: return nil
            }
        }
        editor.scrollView.contentView.postsBoundsChangedNotifications = true
        editor.scrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(columnScrolled(_:)), name: NSView.boundsDidChangeNotification, object: editor.scrollView.contentView)
        // Resized (first layout included): which headers are in view changes too.
        NotificationCenter.default.addObserver(self, selector: #selector(columnResized), name: NSView.frameDidChangeNotification, object: editor.scrollView.contentView)
    }

    /// Syntax colors for a row from its file's highlighter (built the first time the file is on
    /// screen, from that file's rows in this column), or nil for a language Alloy doesn't know.
    private func syntaxSpans(file: Int, row: Int, dark: Bool, columnSide: DiffBody.Side?) -> [StyleSpan]? {
        guard let index = columns.firstIndex(where: { $0.side == columnSide }) else { return nil }
        if columns[index].highlighters[file] == nil {
            // Nothing yet: if the file is still on screen after `highlightDelay`, build it off
            // the main thread (its text, its first parse). Plain until then.
            let key = "\(String(describing: columnSide))-\(file)"
            guard pendingHighlights.insert(key).inserted else { return nil }
            let generation = columnsGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.highlightDelay) { [weak self] in
                guard let self else { return }
                self.pendingHighlights.remove(key)
                guard self.columnsGeneration == generation,
                      let i = self.columns.firstIndex(where: { $0.side == columnSide }),
                      self.columns[i].highlighters[file] == nil,
                      self.filesInView(self.columns[i]).contains(file) else { return }
                self.startHighlighter(file: file, column: i, dark: dark, columnSide: columnSide)
            }
            return nil
        }
        guard let highlighter = columns[index].highlighters[file] ?? nil, columns[index].localIndex.indices.contains(row) else { return nil }
        let local = columns[index].localIndex[row]
        return local >= 0 ? highlighter.spans(forLine: local) : nil
    }

    /// The files with a row on screen in a column.
    private func filesInView(_ column: Column) -> Set<Int> {
        let editor = column.editor
        let layoutModel = editor.documentLayout
        let top = layoutModel.line(atY: max(0, editor.viewport.minY)).line
        let bottom = min(layoutModel.line(atY: editor.drawingRect.maxY).line, column.rows.count - 1)
        guard top <= bottom else { return [] }
        return Set((top...bottom).compactMap { file(atRow: $0, in: column) })
    }

    private func startHighlighter(file: Int, column index: Int, dark: Bool, columnSide: DiffBody.Side?) {
        columns[index].highlighters[file] = .some(nil)
        columns[index].highlighterOrder.append(file)
        if columns[index].highlighterOrder.count > Self.highlighterLimit {
            let oldest = columns[index].highlighterOrder.removeFirst()
            columns[index].highlighters[oldest] = nil
        }
        let ext = SyntaxLanguage.languageExtension(forFileName: (diff.files[file].path as NSString).lastPathComponent)
        guard SyntaxLanguage.supports(ext), let own = columns[index].fileText[file] else { return }
        let buffer = columns[index].editor.buffer.text
        let rowsOfFile = own.rows
        let generation = columnsGeneration
        Task.detached(priority: .utility) { [weak self] in
            let text = Rope(rowsOfFile.map { buffer.substring(buffer.range(ofLine: $0)) }.joined(separator: "\n"))
            await MainActor.run { [weak self] in
                guard let self, self.columnsGeneration == generation,
                      let i = self.columns.firstIndex(where: { $0.side == columnSide }),
                      self.columns[i].highlighterOrder.contains(file) else { return }
                let built = SyntaxHighlighter(fileExtension: ext, text: text, theme: EditorThemes.syntax(dark: dark), parseInBackground: true)
                built?.onInvalidate = { [weak self] in self?.columns.forEach { $0.editor.setNeedsRender() } }
                self.columns[i].highlighters[file] = .some(built)
            }
        }
    }

    private func layoutColumns() {
        let gutterWidth = diffLayout == .sideBySide ? Self.gutterWidthSplit : Self.gutterWidthUnified
        var previous: NSView?
        for (index, column) in columns.enumerated() {
            let gutter = column.editor.gutter
            for view in [gutter, column.editor as NSView] {
                view.translatesAutoresizingMaskIntoConstraints = false
                addSubview(view)
            }
            let leading = previous?.trailingAnchor ?? leadingAnchor
            NSLayoutConstraint.activate([
                gutter.topAnchor.constraint(equalTo: topAnchor), gutter.bottomAnchor.constraint(equalTo: bottomAnchor),
                gutter.leadingAnchor.constraint(equalTo: leading), gutter.widthAnchor.constraint(equalToConstant: gutterWidth),
                column.editor.topAnchor.constraint(equalTo: topAnchor), column.editor.bottomAnchor.constraint(equalTo: bottomAnchor),
                column.editor.leadingAnchor.constraint(equalTo: gutter.trailingAnchor),
            ])
            if index == 0, columns.count > 1 {
                divider.translatesAutoresizingMaskIntoConstraints = false
                addSubview(divider)
                NSLayoutConstraint.activate([
                    divider.topAnchor.constraint(equalTo: topAnchor), divider.bottomAnchor.constraint(equalTo: bottomAnchor),
                    divider.leadingAnchor.constraint(equalTo: column.editor.trailingAnchor), divider.widthAnchor.constraint(equalToConstant: 1),
                ])
                previous = divider
            } else {
                previous = column.editor
            }
        }
        if let last = columns.last { last.editor.trailingAnchor.constraint(equalTo: trailingAnchor).isActive = true }
        if columns.count == 2 {
            columns[0].editor.widthAnchor.constraint(equalTo: columns[1].editor.widthAnchor).isActive = true
        }
        addSubview(headerLayer)
        NSLayoutConstraint.activate([
            headerLayer.topAnchor.constraint(equalTo: topAnchor), headerLayer.bottomAnchor.constraint(equalTo: bottomAnchor),
            headerLayer.leadingAnchor.constraint(equalTo: leadingAnchor), headerLayer.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    // MARK: Scrolling

    @objc private func columnScrolled(_ note: Notification) {
        guard let clip = note.object as? NSClipView else { return }
        // Split: the other column follows, row for row.
        if columns.count == 2, !syncingScroll, let moved = columns.first(where: { $0.editor.scrollView.contentView === clip }) {
            syncingScroll = true
            // The clip's own origin, not `scrollY` (which clamps): a rubber-band past either end
            // is mirrored too, so the rows never slip apart.
            let origin = moved.editor.scrollView.contentView.bounds.origin
            for column in columns where column.editor !== moved.editor {
                column.editor.scrollView.contentView.setBoundsOrigin(NSPoint(x: column.editor.scrollView.contentView.bounds.origin.x, y: origin.y))
                column.editor.scrollView.reflectScrolledClipView(column.editor.scrollView.contentView)
            }
            syncingScroll = false
        }
        refreshHeaders()
    }

    @objc private func columnResized() { refreshHeaders() }

    override func layout() {
        super.layout()
        refreshHeaders()
    }

    /// Headers for the files whose header rows are in view, placed over them; the rest go.
    private func refreshHeaders() {
        guard let first = columns.first else { return }
        let editor = first.editor
        let layoutModel = editor.documentLayout
        let visible = editor.viewport
        let topRow = layoutModel.line(atY: max(0, visible.minY - layoutModel.lineHeight * 2)).line
        // To the bottom of what's drawn, the part under the bar included.
        let bottomRow = layoutModel.line(atY: editor.drawingRect.maxY).line
        var wanted: Set<Int> = []
        if topRow <= bottomRow {
            for row in topRow...min(bottomRow, first.rows.count - 1) {
                if case .fileTop(let file) = first.rows[row] { wanted.insert(file) }
            }
        }
        // The file at the top keeps its header in view while its lines scroll under it, until
        // the next file's header pushes it up.
        let current = file(atRow: layoutModel.line(atY: visible.minY).line, in: first)
        if let current { wanted.insert(current) }
        for (file, view) in headers where !wanted.contains(file) {
            // Kept for the next file that comes into view (`makeHeader`), not rebuilt for it.
            view.isHidden = true
            view.onToggle = nil
            view.onInstruct = nil
            headerPool.append(view)
            headers[file] = nil
        }
        let height = layoutModel.lineHeight * 2
        let clipTop = editor.scrollView.contentView.bounds.minY
        func top(of file: Int) -> CGFloat? {
            first.headerRow[file].map { layoutModel.caretRect(at: editor.buffer.text.offset(ofLine: $0)).minY }
        }
        for file in wanted {
            guard let rowTop = top(of: file) else { continue }
            let header = headers[file] ?? makeHeader(file)
            headers[file] = header
            // Document y → this view (flipped header layer): the clip view's top edge is ours.
            var y = rowTop - clipTop
            let pinned = file == current && y < 0
            if file == current {
                y = max(y, 0)
                // Pushed up by the next header, and the gap row before it (a folded file has none).
                let gap = folded.contains(file) ? 0 : layoutModel.lineHeight
                if let next = top(of: file + 1) { y = min(y, next - clipTop - height - gap) }
            }
            header.frame = NSRect(x: 0, y: y, width: bounds.width, height: height)
            header.isPinned = pinned
        }
        if let window {
            let pointer = headerLayer.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            for header in headers.values { header.setHovered(header.frame.contains(pointer), animated: false) }
        }
        if let current, current != topFile {
            topFile = current
            onTopFileChange?(current)
        }
    }

    /// Headers out of view, kept to reuse (a handful: as many as were on screen at once).
    private var headerPool: [DiffFileHeader] = []

    /// The document's color: the editor theme's background, or Side's raised surface.
    private var backdrop: NSColor { EditorThemes.current(dark: DS.Appearance.isDark)?.background.nsColor ?? DS.Color.raised }

    private func makeHeader(_ index: Int) -> DiffFileHeader {
        let file = diff.files[index]
        let header: DiffFileHeader
        if let reused = headerPool.popLast() {
            header = reused
            header.isHidden = false
        } else {
            header = DiffFileHeader()
            headerLayer.addSubview(header)
        }
        header.bindLayerBackground(backdrop)
        header.configure(file: file, folded: folded.contains(index))
        header.onToggle = { [weak self] in self?.toggleFold(index) }
        header.showsTopRule = index > 0
        if let onInstruct, !file.isDeleted, let span = file.changedNewLines {
            header.onInstruct = { anchor in onInstruct(file.path, span, anchor) }
        }
        return header
    }

    private func toggleFold(_ index: Int) {
        let folding = !folded.contains(index)
        setFolded(index, folding)
        onFoldChange?(index, folding)
    }

    /// Folds or opens a file, keeping what's on screen where it is. A file folded while it's
    /// the one at the top keeps its header there, so the next file comes up under it.
    func setFolded(_ index: Int, _ fold: Bool) {
        guard diff.files.indices.contains(index), folded.contains(index) != fold else { return }
        if fold { folded.insert(index) } else { folded.remove(index) }
        let pinned = topFile == index
        rebuild(keepingPosition: true)
        if pinned { scrollToFile(index) }
    }

    func isFolded(_ index: Int) -> Bool { folded.contains(index) }

    /// Whether every file is folded (an empty change set counts as not).
    var allFolded: Bool { !diff.files.isEmpty && folded.count == diff.files.count }

    /// Folds or opens every file at once, in one rebuild, the file at the top kept there.
    func setAllFolded(_ fold: Bool) {
        let target: Set<Int> = fold ? Set(diff.files.indices) : []
        guard target != folded else { return }
        let top = topFile
        folded = target
        rebuild(keepingPosition: true)
        if let top { scrollToFile(top) }
        onFoldChange?(top ?? 0, fold)
    }

    /// Brings a file's header to the top.
    func scrollToFile(_ index: Int) {
        guard let first = columns.first, let row = first.headerRow[index] else { return }
        first.editor.layoutSubtreeIfNeeded()
        let y = first.editor.documentLayout.caretRect(at: first.editor.buffer.text.offset(ofLine: row)).minY
        let limit = max(0, first.editor.documentLayout.contentHeight + first.editor.scrollView.contentInsets.bottom - first.editor.scrollView.contentView.bounds.height)
        for column in columns { column.editor.scrollY = min(y, limit) }
        refreshHeaders()
    }

    /// The file a row belongs to; the gap before a file belongs to the one above it.
    private func file(atRow row: Int, in column: Column) -> Int? {
        guard column.rows.indices.contains(row) else { return nil }
        if case .gap = column.rows[row] {
            return column.rows.indices.contains(row + 1) ? max(0, fileIndex(of: column.rows[row + 1]) - 1) : nil
        }
        return fileIndex(of: column.rows[row])
    }

    private func fileIndex(of row: Row) -> Int {
        switch row {
        case .fileTop(let f), .fileBottom(let f): return f
        case .hunk(let f, _), .line(let f, _): return f
        case .gap: return 0
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        guard !diff.files.isEmpty, message == nil else { return }
        rebuild(keepingPosition: true)
    }

    /// Another editor theme: the diff is drawn in it too.
    @objc private func editorThemeChanged() {
        guard !diff.files.isEmpty, message == nil else { return }
        columns.indices.forEach { columns[$0].highlighters = [:] }
        rebuild(keepingPosition: true)
    }

    // MARK: Tests

    var rowCount: Int { columns.first?.rows.count ?? 0 }
    var visibleHeaderCount: Int { headers.count }
    var editors: [AlloyEditorView] { columns.map(\.editor) }
    /// Where each header sits in this view, by file.
    var headerFramesForTesting: [Int: NSRect] { headers.mapValues(\.frame) }
    func toggleFoldForTesting(_ file: Int) { toggleFold(file) }
}

/// The file headers' layer: flipped, and transparent to clicks except on a header.
private final class HeaderLayerView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// One file's header over its rows: chevron, path, NEW / DELETED, "Instruct…" on hover, the
/// +/− counts. Clicking it folds the file.
@MainActor
final class DiffFileHeader: NSView {
    var onToggle: (() -> Void)?
    /// Held at the top while its file's lines scroll under it: a hairline marks the edge.
    var isPinned = false { didSet { if isPinned != oldValue { hairline.isHidden = !isPinned } } }
    private let hairline = NSBox()
    /// A rule above every file but the first, so files stay apart without bands of color.
    var showsTopRule = false { didSet { topRule.isHidden = !showsTopRule } }
    private let topRule = NSBox()
    var onInstruct: ((NSView) -> Void)? { didSet { instructButton.isHidden = onInstruct == nil } }
    private let instructButton = NSButton(title: "", target: nil, action: nil)
    private var folded = false
    private var describedAs = ""
    private let chevron = NSImageView()
    private let path = NSTextField(labelWithString: "")
    private let counts = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    private static let chevronRight = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
    private static let chevronDown = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold))

    convenience init(file: UnifiedDiff.File, folded: Bool) {
        self.init()
        configure(file: file, folded: folded)
    }

    /// Built once and reused: a fling past hundreds of files made a header for each, with its
    /// stack of views and constraints, and that was most of the main thread's time while
    /// scrolling (2026-09-30, the owner's report of 100%+ CPU). `configure` changes what it shows.
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        // The document's own color: a band of another shade between files read as a gap.
        bindLayerBackground(DS.Color.raised)

        chevron.contentTintColor = .secondaryLabelColor
        path.font = DS.Text.code(12, weight: .medium)
        path.lineBreakMode = .byTruncatingMiddle
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        badge.font = DS.Text.caption(.bold)
        var views: [NSView] = [chevron, path, badge]
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        views.append(spacer)
        instructButton.isBordered = false
        instructButton.attributedTitle = NSAttributedString(string: "Instruct\u{2026}", attributes: [.font: DS.Text.caption(.medium), .foregroundColor: NSColor.labelColor])
        instructButton.target = self
        instructButton.action = #selector(instructTapped)
        instructButton.alphaValue = 0
        instructButton.isHidden = true
        views.append(instructButton)
        views.append(counts)
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = DS.Spacing.m
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        hairline.boxType = .custom
        hairline.borderType = .noBorder
        hairline.fillColor = DS.Color.hairline
        hairline.isHidden = true
        hairline.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hairline)
        topRule.boxType = .custom
        topRule.borderType = .noBorder
        topRule.fillColor = DS.Color.hairline
        topRule.isHidden = true
        topRule.translatesAutoresizingMaskIntoConstraints = false
        addSubview(topRule)
        NSLayoutConstraint.activate([
            topRule.leadingAnchor.constraint(equalTo: leadingAnchor),
            topRule.trailingAnchor.constraint(equalTo: trailingAnchor),
            topRule.topAnchor.constraint(equalTo: topAnchor),
            topRule.heightAnchor.constraint(equalToConstant: 1),
        ])
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DS.Spacing.l),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DS.Spacing.l),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            hairline.bottomAnchor.constraint(equalTo: bottomAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(file: UnifiedDiff.File, folded: Bool) {
        self.folded = folded
        var parts = [file.path]
        parts.append(file.addedCount == 1 ? "1 line added" : "\(file.addedCount) lines added")
        parts.append(file.removedCount == 1 ? "1 line removed" : "\(file.removedCount) lines removed")
        if file.isNew { parts.append("new file") }
        if file.isDeleted { parts.append("deleted file") }
        describedAs = parts.joined(separator: ", ")
        chevron.image = (folded ? Self.chevronRight : Self.chevronDown) ?? NSImage()
        path.stringValue = file.path
        path.textColor = folded ? .secondaryLabelColor : .labelColor
        let text = NSMutableAttributedString(string: "+\(file.addedCount)", attributes: [.font: DS.Text.code(11, weight: .semibold), .foregroundColor: DiffBody.addedText])
        text.append(NSAttributedString(string: "  −\(file.removedCount)", attributes: [.font: DS.Text.code(11, weight: .semibold), .foregroundColor: DiffBody.removedText]))
        counts.attributedStringValue = text
        badge.isHidden = !(file.isNew || file.isDeleted)
        badge.stringValue = file.isNew ? "NEW" : "DELETED"
        badge.textColor = file.isNew ? DiffBody.addedText : DiffBody.removedText
        instructButton.setAccessibilityLabel("Instruct about \(file.path)")
        isPinned = false
        setHovered(false, animated: false)
    }

    override func mouseDown(with event: NSEvent) { onToggle?() }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit is NSButton ? hit : self
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    /// Whether the pointer is over it. Set from the diff while it scrolls too: a header that
    /// moves out from under a still pointer gets no exit event.
    func setHovered(_ hovered: Bool, animated: Bool = true) {
        let alpha: CGFloat = hovered ? 1 : 0
        guard instructButton.alphaValue != alpha else { return }
        if animated { DS.Motion.fade { instructButton.animator().alphaValue = alpha } } else { instructButton.alphaValue = alpha }
    }
    @objc private func instructTapped() { onInstruct?(instructButton) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    // A disclosure, as the card header was: its file, its counts, and whether it's open.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .disclosureTriangle }
    override func accessibilityLabel() -> String? { describedAs }
    override func accessibilityValue() -> Any? { folded ? "collapsed" : "expanded" }
    override func isAccessibilityExpanded() -> Bool { !folded }
    override func accessibilityActionDescription(_ action: NSAccessibility.Action) -> String? {
        action == .press ? (folded ? "Expand" : "Collapse") : nil
    }
    override func accessibilityPerformPress() -> Bool { onToggle?(); return true }
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard onInstruct != nil else { return nil }
        return [NSAccessibilityCustomAction(name: "Instruct…") { [weak self] in self?.instructTapped(); return true }]
    }
}
