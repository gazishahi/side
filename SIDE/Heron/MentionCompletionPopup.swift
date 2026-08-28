import AppKit

/// The `@`-mention candidate list: a floating, non-activating panel under the caret.
///
/// Hand-rolled rather than using `NSTextView.complete(_:)`, which was tried first and is wrong
/// here for two independent reasons:
///
/// 1. It *inserts text* when it resolves, and that insertion fires `textDidChange` — calling it
///    from there recursed until the stack died (`EXC_BAD_ACCESS: excessive recursion`).
/// 2. Even with the recursion fixed, a single candidate is committed *immediately*, so typing
///    `@src/gre` became `@src/greeter.ts/gre` — AppKit finished the word mid-keystroke and the
///    rest of what you typed landed after it. `complete(_:)` is built for an explicit trigger
///    (Escape/F5), not for as-you-type suggestions.
///
/// This panel only ever *shows* things. Text changes exclusively when the composer asks it for
/// the current selection, which is what keeps typing and completion from fighting.
@MainActor
final class MentionCompletionPopup: NSObject {
    /// Called when the user accepts a row.
    var onAccept: ((String) -> Void)?

    private let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 340, height: 0),
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true
    )
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private var candidates: [String] = []

    private static let rowHeight: CGFloat = 22
    private static let maxVisibleRows = 8

    var isVisible: Bool { panel.isVisible }
    var selectedCandidate: String? {
        let row = tableView.selectedRow
        return candidates.indices.contains(row) ? candidates[row] : nil
    }

    override init() {
        super.init()
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .popUpMenu
        // Non-activating *and* not key: the composer must keep focus, or every keystroke after
        // the list appears would go somewhere else.
        panel.hidesOnDeactivate = true

        let background = NSVisualEffectView()
        background.material = .menu
        background.blendingMode = .withinWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = DS.Radius.control
        background.layer?.masksToBounds = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("path"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = Self.rowHeight
        tableView.backgroundColor = .clear
        tableView.style = .plain
        tableView.selectionHighlightStyle = .regular
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)
        tableView.intercellSpacing = NSSize(width: 0, height: 0)

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: background.topAnchor, constant: DS.Spacing.xs),
            scrollView.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -DS.Spacing.xs),
            scrollView.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: background.trailingAnchor),
        ])
        panel.contentView = background
    }

    /// Shows (or updates) the list under `caretRect`, in screen coordinates. An empty candidate
    /// list hides the panel rather than showing an empty box.
    func show(candidates: [String], below caretRect: NSRect, parent: NSWindow?) {
        guard !candidates.isEmpty, let parent else { return hide() }
        let selectionSurvives = selectedCandidate.flatMap(candidates.firstIndex(of:))
        self.candidates = candidates
        tableView.reloadData()
        // Keep the highlighted row if it's still in the list, so refining a query doesn't yank
        // the selection out from under someone about to press Return.
        tableView.selectRowIndexes([selectionSurvives ?? 0], byExtendingSelection: false)

        let rows = min(candidates.count, Self.maxVisibleRows)
        let height = CGFloat(rows) * Self.rowHeight + DS.Spacing.m
        var frame = NSRect(x: caretRect.minX, y: caretRect.minY - height - 4, width: 340, height: height)
        // Flip above the caret when there's no room below — the composer sits at the bottom of
        // the window, so this is the common case rather than an edge case.
        if let screen = parent.screen, frame.minY < screen.visibleFrame.minY {
            frame.origin.y = caretRect.maxY + 4
        }
        panel.setFrame(frame, display: false)
        if !panel.isVisible { parent.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        candidates = []
    }

    /// Arrow-key navigation, driven by the composer's key handling since the panel never takes
    /// focus.
    func moveSelection(by delta: Int) {
        guard !candidates.isEmpty else { return }
        let next = min(max(tableView.selectedRow + delta, 0), candidates.count - 1)
        tableView.selectRowIndexes([next], byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    func acceptSelection() {
        guard let candidate = selectedCandidate else { return }
        hide()
        onAccept?(candidate)
    }

    @objc private func rowClicked() {
        acceptSelection()
    }
}

extension MentionCompletionPopup: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { candidates.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("MentionRow")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView ?? {
            let cell = NSTableCellView()
            let label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingHead  // the tail of a path is the identifying part
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: DS.Spacing.m),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -DS.Spacing.m),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            cell.identifier = identifier
            return cell
        }()
        cell.textField?.stringValue = candidates[row]
        cell.textField?.font = DS.Text.code(11)
        return cell
    }
}
