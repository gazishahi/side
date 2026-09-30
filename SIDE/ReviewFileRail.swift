import AppKit

/// Which files of a track's diff have been looked at (Review's "viewed" checks). A mark holds the
/// file's diff as it was when marked: when the diff changes (the agent edited it again, or a
/// different range is showing), the file is unviewed, because what was seen isn't what's there.
struct ReviewViewedStore {
    /// Per process under tests, like the other preferences, so a test's marks reach no one.
    nonisolated(unsafe) static var shared = ReviewViewedStore(defaults: NSClassFromString("XCTestCase") == nil
        ? .standard : UserDefaults(suiteName: "side.tests.review-viewed.\(ProcessInfo.processInfo.processIdentifier)") ?? .standard)

    let defaults: UserDefaults

    private func key(_ track: String) -> String { "SideReviewViewed.\(track)" }

    /// Path → the fingerprint it was marked at.
    func marks(track: String) -> [String: String] {
        defaults.dictionary(forKey: key(track)) as? [String: String] ?? [:]
    }

    func isViewed(_ file: UnifiedDiff.File, track: String) -> Bool {
        marks(track: track)[file.path] == Self.fingerprint(file)
    }

    func set(_ viewed: Bool, _ file: UnifiedDiff.File, track: String) {
        var marks = marks(track: track)
        marks[file.path] = viewed ? Self.fingerprint(file) : nil
        // Bounded: a track's marks are its changed files, but a long-lived one sees many.
        if marks.count > 2000 { marks = marks.filter { $0.key == file.path } }
        defaults.set(marks, forKey: key(track))
    }

    func forget(track: String) { defaults.removeObject(forKey: key(track)) }

    /// A hash of the file's diff: its lines and their kinds.
    static func fingerprint(_ file: UnifiedDiff.File) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        func mix(_ string: String) {
            for byte in string.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
            hash = (hash ^ 0x0A) &* 0x100000001b3
        }
        for hunk in file.hunks {
            for line in hunk.lines {
                switch line.kind {
                case .added: mix("+" + line.text)
                case .removed: mix("-" + line.text)
                case .context: mix(" " + line.text)
                }
            }
        }
        return String(hash, radix: 36)
    }
}

/// Review's file list beside the diff: each changed file's name, folder and +/− counts, with a
/// check to mark it viewed (which folds it in the diff). The file at the top of the diff is the
/// selected row; choosing a row brings its file up.
@MainActor
final class ReviewFileRail: NSView, NSTableViewDataSource, NSTableViewDelegate {
    struct Item: Equatable {
        var path: String
        var added: Int
        var removed: Int
        var isNew: Bool
        var isDeleted: Bool
        var viewed: Bool
    }

    var items: [Item] = [] { didSet { reload(from: oldValue) } }
    /// A row was chosen: bring that file up.
    var onSelect: ((Int) -> Void)?
    /// A file's check was flipped.
    var onToggleViewed: ((Int, Bool) -> Void)?

    private let title = NSTextField(labelWithString: "Files")
    private let progress = NSTextField(labelWithString: "")
    private let table = NSTableView()
    private let scroll = NSScrollView()
    /// Set while the diff moves the selection, so following it doesn't scroll the diff back.
    private var following = false
    static let width: CGFloat = 264
    /// The title row, as tall as the diff's toolbar beside it so the two read as one line.
    static let headerHeight: CGFloat = 24

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        title.font = DS.Text.custom(11, weight: .semibold)
        title.stringValue = "FILES"
        title.textColor = .secondaryLabelColor
        progress.font = DS.Text.caption()
        progress.textColor = .tertiaryLabelColor
        progress.alignment = .right

        let column = NSTableColumn(identifier: .init("file"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .inset
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.rowHeight = 30
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.allowsEmptySelection = true
        table.setAccessibilityLabel("Changed files")
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false

        for view in [title, progress, scroll] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.centerYAnchor.constraint(equalTo: topAnchor, constant: Self.headerHeight / 2),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DS.Spacing.l + DS.Spacing.xs),
            progress.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            progress.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DS.Spacing.xl),
            progress.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: DS.Spacing.m),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: Self.headerHeight + DS.Spacing.s),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// How much of the bottom something floats over: the list scrolls under it.
    var bottomInset: CGFloat = 0 {
        didSet { scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: bottomInset, right: 0) }
    }

    private func reload(from old: [Item]) {
        let viewed = items.filter(\.viewed).count
        progress.stringValue = items.isEmpty ? "" : "\(viewed) of \(items.count) viewed"
        progress.setAccessibilityLabel(progress.stringValue)
        // Same files: only the rows whose check changed.
        if old.count == items.count, zip(old, items).allSatisfy({ $0.path == $1.path }) {
            let changed = IndexSet(items.indices.filter { old[$0] != items[$0] })
            if !changed.isEmpty { table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0)) }
            return
        }
        table.reloadData()
    }

    /// The diff's top file, shown as the selection without moving the diff.
    /// At most ten times a second, ending where the diff did: while a fling passes a file a
    /// frame, selecting and scrolling the list for each one was a second table scrolling in step
    /// with the first (2026-09-30, the owner's report of 100%+ CPU in Review).
    func follow(_ index: Int) {
        pendingFollow = index
        guard !followScheduled else { return }
        followScheduled = true
        let wait = max(0, lastFollowAt + Self.followInterval - CACurrentMediaTime())
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self else { return }
            self.followScheduled = false
            self.lastFollowAt = CACurrentMediaTime()
            if let index = self.pendingFollow {
                self.pendingFollow = nil
                self.followNow(index)
            }
        }
    }

    private static let followInterval: CFTimeInterval = 0.1
    private var pendingFollow: Int?
    private var followScheduled = false
    private var lastFollowAt: CFTimeInterval = 0

    private func followNow(_ index: Int) {
        guard items.indices.contains(index), table.selectedRow != index else { return }
        following = true
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        table.scrollRowToVisible(index)
        following = false
    }

    var selectedIndex: Int? { table.selectedRow >= 0 ? table.selectedRow : nil }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: RailCell.identifier, owner: nil) as? RailCell ?? RailCell()
        cell.configure(items[row]) { [weak self] viewed in self?.onToggleViewed?(row, viewed) }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !following, table.selectedRow >= 0 else { return }
        onSelect?(table.selectedRow)
    }

    /// Space marks the selected file viewed, as the check does.
    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " ", let row = selectedIndex {
            onToggleViewed?(row, !items[row].viewed)
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: Tests

    var tableForTesting: NSTableView { table }
    var progressText: String { progress.stringValue }
}

/// One row: the check, the file name over its folder, the counts.
private final class RailCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ReviewRailCell")
    private let check = NSButton()
    private let name = NSTextField(labelWithString: "")
    private let folder = NSTextField(labelWithString: "")
    private let counts = NSTextField(labelWithString: "")
    private var onToggle: ((Bool) -> Void)?
    private var viewed = false

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        check.isBordered = false
        check.imagePosition = .imageOnly
        check.target = self
        check.action = #selector(toggled)
        check.setContentHuggingPriority(.required, for: .horizontal)
        name.font = DS.Text.body(.medium)
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        folder.font = DS.Text.caption()
        folder.textColor = .tertiaryLabelColor
        folder.lineBreakMode = .byTruncatingHead
        folder.setContentCompressionResistancePriority(.init(100), for: .horizontal)
        counts.setContentCompressionResistancePriority(.required, for: .horizontal)
        counts.setContentHuggingPriority(.required, for: .horizontal)
        for view in [check, name, folder, counts] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            check.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DS.Spacing.xs),
            check.centerYAnchor.constraint(equalTo: centerYAnchor),
            check.widthAnchor.constraint(equalToConstant: 18),
            name.leadingAnchor.constraint(equalTo: check.trailingAnchor, constant: DS.Spacing.s),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            folder.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: DS.Spacing.s),
            folder.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
            counts.leadingAnchor.constraint(greaterThanOrEqualTo: folder.trailingAnchor, constant: DS.Spacing.s),
            counts.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DS.Spacing.xs),
            counts.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ item: ReviewFileRail.Item, onToggle: @escaping (Bool) -> Void) {
        self.onToggle = onToggle
        viewed = item.viewed
        let url = item.path as NSString
        name.stringValue = url.lastPathComponent
        folder.stringValue = url.deletingLastPathComponent
        name.textColor = item.viewed ? .secondaryLabelColor : .labelColor
        let symbol = item.viewed ? "checkmark.circle.fill" : "circle"
        check.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
        check.contentTintColor = item.viewed ? DS.Color.statusVerified : .tertiaryLabelColor
        check.setAccessibilityLabel("Viewed")
        check.setAccessibilityRole(.checkBox)
        check.setAccessibilityValue(item.viewed ? 1 : 0)
        check.toolTip = item.viewed ? "Viewed. Click to unmark" : "Mark as viewed"

        let text = NSMutableAttributedString()
        let font = DS.Text.code(11, weight: .medium)
        if item.added > 0 || item.removed == 0 {
            text.append(NSAttributedString(string: "+\(item.added)", attributes: [.font: font, .foregroundColor: DiffBody.addedText]))
        }
        if item.removed > 0 {
            if text.length > 0 { text.append(NSAttributedString(string: " ", attributes: [.font: font])) }
            text.append(NSAttributedString(string: "\u{2212}\(item.removed)", attributes: [.font: font, .foregroundColor: DiffBody.removedText]))
        }
        counts.attributedStringValue = text
        counts.alphaValue = item.viewed ? 0.6 : 1

        var spoken = [url.lastPathComponent]
        if !folder.stringValue.isEmpty { spoken.append("in \(folder.stringValue)") }
        if item.isNew { spoken.append("new") }
        if item.isDeleted { spoken.append("deleted") }
        spoken.append("\(item.added) added, \(item.removed) removed")
        if item.viewed { spoken.append("viewed") }
        setAccessibilityLabel(spoken.joined(separator: ", "))
        setAccessibilityCustomActions([NSAccessibilityCustomAction(name: item.viewed ? "Mark as not viewed" : "Mark as viewed") { [weak self] in
            self?.toggled()
            return true
        }])
    }

    @objc private func toggled() { onToggle?(!viewed) }
}
