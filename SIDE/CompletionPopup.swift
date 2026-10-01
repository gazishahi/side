import AppKit

/// Make's completion list: a floating panel under the caret, a badge for each item's kind, its
/// type on the right, and the selected item's documentation beside the list. It never takes
/// focus; Make routes ↑ ↓ Return Tab and Escape to it.
@MainActor
final class CompletionPopup: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    static let rowHeight: CGFloat = 22
    static let maxVisibleRows = 9
    static let listWidth: CGFloat = 360
    static let docsWidth: CGFloat = 300

    private let panel = CompletionPanel()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let docs = NSTextField(wrappingLabelWithString: "")
    private let docsBox = NSView()
    private var docsWidthConstraint: NSLayoutConstraint!
    private(set) var items: [LSPCompletionItem] = []
    private(set) var selectedIndex = 0
    /// The selected row changed (to fetch its documentation).
    var onSelect: ((Int) -> Void)?
    /// A row was double-clicked.
    var onAccept: (() -> Void)?

    var isVisible: Bool { panel.isVisible }

    override init() {
        super.init()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("completion"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.setAccessibilityLabel("Completions")

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        scroll.translatesAutoresizingMaskIntoConstraints = false

        docs.font = DS.Text.caption()
        docs.textColor = .secondaryLabelColor
        docs.maximumNumberOfLines = 14
        docs.lineBreakMode = .byTruncatingTail
        docs.translatesAutoresizingMaskIntoConstraints = false
        docs.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        docsBox.translatesAutoresizingMaskIntoConstraints = false
        docsBox.addSubview(docs)
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        docsBox.addSubview(divider)

        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(scroll)
        row.addSubview(docsBox)
        docsWidthConstraint = docsBox.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            scroll.topAnchor.constraint(equalTo: row.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            scroll.widthAnchor.constraint(equalToConstant: Self.listWidth),
            docsBox.leadingAnchor.constraint(equalTo: scroll.trailingAnchor),
            docsBox.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            docsBox.topAnchor.constraint(equalTo: row.topAnchor),
            docsBox.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            docsWidthConstraint,
            divider.leadingAnchor.constraint(equalTo: docsBox.leadingAnchor),
            divider.topAnchor.constraint(equalTo: docsBox.topAnchor, constant: 2),
            divider.bottomAnchor.constraint(equalTo: docsBox.bottomAnchor, constant: -2),
            docs.leadingAnchor.constraint(equalTo: docsBox.leadingAnchor, constant: 10),
            docs.trailingAnchor.constraint(equalTo: docsBox.trailingAnchor, constant: -10),
            docs.topAnchor.constraint(equalTo: docsBox.topAnchor, constant: 3),
            docs.bottomAnchor.constraint(lessThanOrEqualTo: docsBox.bottomAnchor, constant: -3),
        ])
        panel.contentView = MakeWorkspaceViewController.makeFloatingPanelSurface(embedding: row, cornerRadius: DS.Radius.surface, padding: 5)
    }

    /// Shows `items` under the caret (above it if there's no room below), `selected` selected.
    func show(_ items: [LSPCompletionItem], selected: Int, caret: NSRect, in window: NSWindow) {
        let appearing = !panel.isVisible
        self.items = items
        selectedIndex = max(0, min(selected, items.count - 1))
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        table.scrollRowToVisible(selectedIndex)
        refreshDocs()
        place(caret: caret, in: window)
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
        // When the list appears, not as each keystroke refilters it (that would talk over typing).
        if appearing, items.indices.contains(selectedIndex) {
            Spoken.announce("\(items.count) completion\(items.count == 1 ? "" : "s"). \(Self.spoken(items[selectedIndex]))")
        }
    }

    /// An item as said aloud: its label and what the server says it is.
    static func spoken(_ item: LSPCompletionItem) -> String {
        [item.label, item.detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    func hide() {
        items = []
        guard panel.isVisible || panel.parent != nil else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    func moveSelection(_ delta: Int) {
        guard !items.isEmpty else { return }
        select(max(0, min(items.count - 1, selectedIndex + delta)))
        Spoken.row(Self.spoken(items[selectedIndex]), at: selectedIndex, of: items.count)
    }

    /// An item's details arrived (documentation from `resolve`).
    func update(_ item: LSPCompletionItem, at index: Int) {
        guard items.indices.contains(index) else { return }
        items[index] = item
        table.reloadData(forRowIndexes: IndexSet(integer: index), columnIndexes: IndexSet(integer: 0))
        if index == selectedIndex {
            refreshDocs()
            if let window = panel.parent, let caret = lastCaret { place(caret: caret, in: window) }
        }
    }

    private func select(_ index: Int) {
        selectedIndex = index
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        table.scrollRowToVisible(index)
        refreshDocs()
        if let window = panel.parent, let caret = lastCaret { place(caret: caret, in: window) }
        onSelect?(index)
    }

    @objc private func doubleClicked() {
        guard table.clickedRow >= 0 else { return }
        selectedIndex = table.clickedRow
        onAccept?()
    }

    private var lastCaret: NSRect?

    private func place(caret: NSRect, in window: NSWindow) {
        lastCaret = caret
        let rows = max(1, min(Self.maxVisibleRows, items.count))
        let height = CGFloat(rows) * Self.rowHeight + 10
        let width = Self.listWidth + docsWidthConstraint.constant + 10
        let screen = window.screen?.visibleFrame ?? window.frame
        var x = caret.minX - 30
        x = min(x, screen.maxX - width - 8)
        x = max(x, screen.minX + 8)
        var y = caret.minY - height - 4
        if y < screen.minY + 8 { y = caret.maxY + 4 }
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }

    private func refreshDocs() {
        guard items.indices.contains(selectedIndex) else { docsWidthConstraint.constant = 0; return }
        let item = items[selectedIndex]
        let text = NSMutableAttributedString()
        if let detail = item.detail, !detail.isEmpty {
            text.append(NSAttributedString(string: detail, attributes: [.font: DS.Text.code(11, weight: .regular), .foregroundColor: NSColor.labelColor]))
        }
        if let doc = item.documentation?.trimmingCharacters(in: .whitespacesAndNewlines), !doc.isEmpty {
            if text.length > 0 { text.append(NSAttributedString(string: "\n\n")) }
            text.append(NSAttributedString(string: Self.plainMarkdown(doc), attributes: [.font: DS.Text.caption(), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        docs.attributedStringValue = text
        docsBox.isHidden = text.length == 0
        docsWidthConstraint.constant = text.length == 0 ? 0 : Self.docsWidth
    }

    /// Documentation as a server writes it, readable as text: fences and the commonest marks go.
    static func plainMarkdown(_ markdown: String) -> String {
        markdown
            .components(separatedBy: "\n")
            .filter { !$0.hasPrefix("```") }
            .joined(separator: "\n")
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: #"(?<![\w*])\*(?=\S)([^*\n]+?)(?<=\S)\*(?![\w*])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "\n\n\n", with: "\n\n")
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard items.indices.contains(row) else { return nil }
        let id = NSUserInterfaceItemIdentifier("completionRow")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? CompletionRowView ?? CompletionRowView()
        cell.identifier = id
        cell.configure(items[row])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        guard row >= 0, row != selectedIndex else { return }
        select(row)
    }
}

/// One completion: its kind's badge, the label (with the signature a server puts after it),
/// and a type or module on the right.
@MainActor
private final class CompletionRowView: NSTableCellView {
    private let badge = NSTextField(labelWithString: "")
    private let label = NSTextField(labelWithString: "")
    private let trailing = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        for field in [badge, label, trailing] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.lineBreakMode = .byTruncatingTail
            addSubview(field)
        }
        badge.font = DS.Text.code(10, weight: .semibold)
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.cornerRadius = DS.Radius.control / 2
        label.font = DS.Text.code(12, weight: .regular)
        trailing.font = DS.Text.code(11, weight: .regular)
        trailing.textColor = .tertiaryLabelColor
        trailing.alignment = .right
        label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        trailing.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 16),
            badge.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 7),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailing.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 10),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ item: LSPCompletionItem) {
        let (letter, hue) = item.kindBadge
        badge.stringValue = letter
        let color = Self.color(hue)
        badge.textColor = color
        badge.layer?.backgroundColor = color.withAlphaComponent(0.16).cgColor
        let text = NSMutableAttributedString(string: item.label, attributes: [.foregroundColor: NSColor.labelColor])
        if let signature = item.labelDetail, !signature.isEmpty {
            text.append(NSAttributedString(string: signature, attributes: [.foregroundColor: NSColor.secondaryLabelColor]))
        }
        label.attributedStringValue = text
        trailing.stringValue = item.labelDescription ?? item.detail.map { $0.components(separatedBy: "\n").first ?? $0 } ?? ""
        setAccessibilityLabel([item.label, item.labelDetail, trailing.stringValue].compactMap { $0 }.joined(separator: " "))
    }

    private static func color(_ hue: LSPCompletionItem.KindHue) -> NSColor {
        switch hue {
        case .method: return .systemBlue
        case .property: return .systemTeal
        case .variable: return .systemGreen
        case .type: return .systemPurple
        case .module: return .systemBrown
        case .constant: return .systemOrange
        case .keyword: return .systemPink
        case .other: return .secondaryLabelColor
        }
    }
}

final class CompletionPanel: NSPanel {
    convenience init() {
        self.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
