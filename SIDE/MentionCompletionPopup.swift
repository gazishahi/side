import AppKit
import Heron

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

    private static let rowHeight: CGFloat = 26
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

        // A floating panel can't use NSGlassEffectView: glass refracts content behind it *in
        // the same window*, and this panel is its own (transparent) window — the glass had
        // nothing to sample and rendered as a flat dark rect, which is why the palette looked
        // like it "lacked Liquid Glass." Behind-window vibrancy is the material that actually
        // samples what's under a panel — it's what system menus are built on.
        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = DS.Radius.surface
        background.maskImage = DS.roundedMask(radius: DS.Radius.surface)
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
    /// How rows truncate: paths keep their tail (the identifying part), commands keep their head.
    var truncatesHead = true

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
        let width: CGFloat = truncatesHead ? 340 : 420
        // Above the caret by default: the composer lives at the bottom of the window, so a
        // downward list lands outside it — over whatever app happens to be behind. Below is the
        // fallback for the rare caret near the top of a screen.
        var frame = NSRect(x: caretRect.minX, y: caretRect.maxY + 6, width: width, height: height)
        if let screen = parent.screen, frame.maxY > screen.visibleFrame.maxY {
            frame.origin.y = caretRect.minY - height - 6
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

/// Selection drawn as a rounded, inset pill: the stock rectangular highlight ran corner-to-
/// corner and poked square edges out of the rounded panel.
private final class PaletteRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let rect = bounds.insetBy(dx: DS.Spacing.s, dy: 1.5)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: DS.Radius.control, yRadius: DS.Radius.control).fill()
    }
}

extension MentionCompletionPopup: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { candidates.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        PaletteRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("MentionRow")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView ?? {
            let cell = NSTableCellView()
            let label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingHead
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: DS.Spacing.xxl),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -DS.Spacing.xxl),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            cell.identifier = identifier
            return cell
        }()
        cell.textField?.stringValue = candidates[row]
        // System text, not monospace: these are UI rows, not code. Paths still read fine, and
        // command descriptions stop looking like terminal output.
        cell.textField?.font = DS.Text.body()
        cell.textField?.textColor = .labelColor
        cell.textField?.lineBreakMode = truncatesHead ? .byTruncatingHead : .byTruncatingTail
        return cell
    }
}
