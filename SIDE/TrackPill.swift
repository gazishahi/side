import AppKit
import Heron

/// The window's track, as one control: status dot + intent; click for every track (Direction 02
/// §3.5). Placement-agnostic — it knows nothing about where the chrome puts it.
///
/// Also where the text the old toolbar and subtitle carried now lives: project, branch, and the
/// active file, in the popover's header. Hover shows a tooltip preview only; nothing is
/// available on hover alone.
final class TrackPill: NSView {
    struct Row: Equatable {
        let key: String          // branch name; "" for the no-track row
        let title: String
        let detail: String       // branch, or project name for another project's track
        let state: DS.StatusState
        var isCurrent = false
        /// Set for another window's project — selecting brings that window forward.
        var windowNumber: Int?
        /// When the track was last worked on; the switcher lists the most recent first.
        var lastActive: Date?
    }

    struct Snapshot: Equatable {
        var title: String                 // intent, or "<default branch> · Base"
        /// The base branch (key ""): heads the recent tracks, so working on it is one pick away.
        var base: Row?
        var state: DS.StatusState
        var stateName: String
        var projectName: String?
        /// The project's folder: its space's symbol and color lead the pill.
        var projectPath: String?
        var branch: String?
        var filePath: String?
        var needsYou: [Row] = []
        var active: [Row] = []
        var parked: [Row] = []
        var otherProjects: [Row] = []
        /// Other tracks in this project needing the user — shown as "+N" beside the intent,
        /// since the pill's own dot is only the current track's.
        var othersNeedingYou = 0
        /// This window holds a tab or terminal torn out of another window on the same track —
        /// a second view onto the same work, not a copy of it.
        var isTornOut = false

        static let empty = Snapshot(title: "No project", state: .idle, stateName: "Idle")
    }

    var snapshotProvider: (() -> Snapshot)?
    var onSelectRow: ((Row) -> Void)?
    var onNewTrack: (() -> Void)?
    /// "New track “…”" in the switcher: the typed words become the new track's intent.
    var onNewTrackNamed: ((String) -> Void)?
    var onOpenTracks: (() -> Void)?
    /// A horizontal swipe on the pill: -1 for the previous project, 1 for the next (Sill's
    /// context chip).
    var onSwipeProject: ((Int) -> Void)?
    /// The popover's project row: switch this window to that project.
    var onSwitchProject: ((URL) -> Void)?
    /// Its +: open another project (and switch to it).
    var onAddProject: (() -> Void)?

    private(set) var snapshot = Snapshot.empty
    /// The project's mark, where the track's dot was; the dot now rides on it only when the
    /// track has something to say (an idle ring there read as a glitch, the visual audit).
    private let projectGlyph = NSImageView()
    private let dot = DS.StatusDot(state: .idle)
    private let titleLabel = NSTextField(labelWithString: "")
    private let extraLabel = NSTextField(labelWithString: "")
    private let tornOutGlyph = NSImageView()
    private var extraTrailing: NSLayoutConstraint!
    private var titleTrailing: NSLayoutConstraint!
    private var glyphTrailing: NSLayoutConstraint!
    private var glyphAfterTitle: NSLayoutConstraint!
    private var glyphAfterExtra: NSLayoutConstraint!
    private var popover: NSPopover?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        titleLabel.font = DS.Text.body(.medium)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        // Just under the window's own stay-put priority (500): the name never widens the window,
        // but nothing weaker squeezes it either.
        titleLabel.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(490), for: .horizontal)
        extraLabel.font = DS.Text.caption()
        extraLabel.textColor = .secondaryLabelColor
        extraLabel.isHidden = true
        dot.setAccessibilityElement(false)
        tornOutGlyph.image = NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        tornOutGlyph.contentTintColor = .secondaryLabelColor
        tornOutGlyph.isHidden = true
        tornOutGlyph.setAccessibilityElement(false)
        tornOutGlyph.setContentCompressionResistancePriority(.required, for: .horizontal)
        // Plain constraints, not a stack: the pill is exactly as wide as its name until the bar
        // needs the room, and then the name truncates inside it. (A stack with lowered clipping
        // resistance let the pill shrink under its own text — the name overflowed the glass,
        // or "disappeared".)
        titleLabel.cell?.lineBreakMode = .byTruncatingTail
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        extraLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        projectGlyph.imageScaling = .scaleProportionallyDown
        projectGlyph.setAccessibilityElement(false)
        for view in [projectGlyph, dot, titleLabel, extraLabel, tornOutGlyph] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        extraTrailing = extraLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DS.Spacing.m)
        titleTrailing = titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DS.Spacing.m)
        glyphTrailing = tornOutGlyph.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DS.Spacing.m)
        glyphAfterTitle = tornOutGlyph.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: DS.Spacing.s)
        glyphAfterExtra = tornOutGlyph.leadingAnchor.constraint(equalTo: extraLabel.trailingAnchor, constant: DS.Spacing.s)
        NSLayoutConstraint.activate([
            projectGlyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DS.Spacing.m),
            projectGlyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            projectGlyph.widthAnchor.constraint(equalToConstant: 16), projectGlyph.heightAnchor.constraint(equalToConstant: 16),
            dot.centerXAnchor.constraint(equalTo: projectGlyph.trailingAnchor),
            dot.centerYAnchor.constraint(equalTo: projectGlyph.bottomAnchor, constant: -1),
            titleLabel.leadingAnchor.constraint(equalTo: projectGlyph.trailingAnchor, constant: DS.Spacing.s + 1),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            extraLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: DS.Spacing.s),
            extraLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            tornOutGlyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleTrailing,
            heightAnchor.constraint(equalToConstant: 28),
            widthAnchor.constraint(lessThanOrEqualToConstant: 280),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.popUpButton)
        // A project's new color or symbol shows at once.
        spacesObserver = NotificationCenter.default.addObserver(forName: ProjectSpaces.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }
    private var spacesObserver: NSObjectProtocol?
    private var hovering = false
    private var namingUntil = Date.distantPast
    private var showsProjectName: Bool { hovering || Date() < namingUntil }

    /// After a project switch: the project's name for a moment.
    func nameProjectBriefly() {
        namingUntil = Date().addingTimeInterval(1.6)
        refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.65) { [weak self] in self?.refresh() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; refresh() }
    override func mouseExited(with event: NSEvent) { hovering = false; refresh() }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func refresh() {
        snapshot = snapshotProvider?() ?? .empty
        dot.state = snapshot.state
        dot.isHidden = snapshot.state == .idle
        if let path = snapshot.projectPath {
            projectGlyph.image = ProjectSpaces.image(for: ProjectSpaces.shared.space(for: URL(fileURLWithPath: path)))
        } else {
            projectGlyph.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            projectGlyph.contentTintColor = .tertiaryLabelColor
        }
        // The project's name only when it's useful (Sill): for a moment after a switch, and
        // while the pointer is on the pill. Otherwise its mark says which project this is.
        if showsProjectName, let project = snapshot.projectName {
            titleLabel.stringValue = "\(project) \u{203A} \(snapshot.title)"
        } else {
            titleLabel.stringValue = snapshot.title
        }
        extraLabel.stringValue = "+\(snapshot.othersNeedingYou)"
        let showsExtra = snapshot.othersNeedingYou > 0
        let showsGlyph = snapshot.isTornOut
        extraLabel.isHidden = !showsExtra
        tornOutGlyph.isHidden = !showsGlyph
        // Whichever piece is last closes the pill: title, then "+N", then the torn-out glyph.
        NSLayoutConstraint.deactivate([titleTrailing, extraTrailing, glyphTrailing, glyphAfterTitle, glyphAfterExtra])
        if showsGlyph {
            NSLayoutConstraint.activate([glyphTrailing, showsExtra ? glyphAfterExtra : glyphAfterTitle])
        } else {
            (showsExtra ? extraTrailing : titleTrailing).isActive = true
        }
        var tip = [snapshot.projectName, snapshot.branch].compactMap { $0 }.joined(separator: " · ")
        if showsGlyph { tip += "\n" + Self.tornOutNote }
        toolTip = tip
        var label = "Current track: \(snapshot.title), \(snapshot.stateName)"
        if snapshot.othersNeedingYou > 0 { label += ". \(snapshot.othersNeedingYou) other tracks need you" }
        if showsGlyph { label += ". \(Self.tornOutNote)" }
        setAccessibilityLabel(label)
    }

    static let tornOutNote = "Torn-out window: another view of this track"

    // MARK: Interaction

    // No hover fill: the pill sits on its own glass, where a hover shape inside the capsule read
    // as a second control (owner, 2026-09-23). The press is the feedback.
    /// The bar's press: the pill's glass swells under the pointer and springs back on release,
    /// then the popover opens — the same feel as search and Think's pills beside it.
    override func mouseDown(with event: NSEvent) {
        let piece = superview ?? self
        piece.wantsLayer = true
        DS.Motion.press(piece, down: true, amount: ChipButton.pressScale)
    }
    override func mouseUp(with event: NSEvent) {
        DS.Motion.press(superview ?? self, down: false, amount: ChipButton.pressScale)
        if bounds.contains(convert(event.locationInWindow, from: nil)) { togglePopover() }
    }
    override var mouseDownCanMoveWindow: Bool { false }
    override func accessibilityPerformPress() -> Bool { togglePopover(); return true }

    // A two-finger swipe across the pill moves between projects, once per swipe.
    private var swipeTravel: CGFloat = 0
    private var swipeFired = false
    override func scrollWheel(with event: NSEvent) {
        guard event.hasPreciseScrollingDeltas, abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) || swipeTravel != 0 else {
            super.scrollWheel(with: event)
            return
        }
        if event.phase == .began { swipeTravel = 0; swipeFired = false }
        swipeTravel += event.scrollingDeltaX
        if !swipeFired, abs(swipeTravel) > 36 {
            swipeFired = true
            // Content follows the fingers: swiping left brings the next project.
            onSwipeProject?(swipeTravel < 0 ? 1 : -1)
        }
        if event.phase == .ended || event.phase == .cancelled { swipeTravel = 0; swipeFired = false }
    }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 || event.keyCode == 36 { togglePopover() } else { super.keyDown(with: event) }
    }

    func togglePopover() {
        if let popover, popover.isShown { popover.close(); return }
        refresh()
        let content = TrackSwitcherViewController(snapshot: snapshot)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = content
        content.onSelect = { [weak self, weak popover] row in popover?.close(); self?.onSelectRow?(row) }
        content.onNewTrack = { [weak self, weak popover] in popover?.close(); self?.onNewTrack?() }
        content.onNewTrackNamed = { [weak self, weak popover] name in popover?.close(); self?.onNewTrackNamed?(name) }
        content.onOpenTracks = { [weak self, weak popover] in popover?.close(); self?.onOpenTracks?() }
        content.onSwitchProject = { [weak self, weak popover] url in popover?.close(); self?.onSwitchProject?(url) }
        content.onAddProject = { [weak self, weak popover] in popover?.close(); self?.onAddProject?() }
        self.popover = popover
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
        content.focusFilter()
    }

    /// Tests: the switcher's content, as it would open now.
    func makeSwitcherForTesting() -> TrackSwitcherViewController {
        refresh()
        return TrackSwitcherViewController(snapshot: snapshot)
    }
}

/// The track switcher, the pill's popover (SIDE_RFC_FIND_REVIEW_TRACKS.md, T1): type to filter,
/// ↑ ↓ to move, Return to switch, Escape to close. Tracks that need you come first, then the rest
/// most recent first; a typed name nothing matches offers itself as a new track.
final class TrackSwitcherViewController: NSViewController, NSSearchFieldDelegate {
    var onSelect: ((TrackPill.Row) -> Void)?
    var onNewTrack: (() -> Void)?
    var onNewTrackNamed: ((String) -> Void)?
    var onOpenTracks: (() -> Void)?
    var onSwitchProject: ((URL) -> Void)?
    var onAddProject: (() -> Void)?
    private let snapshot: TrackPill.Snapshot
    private let filterField = NSSearchField()
    private let list = NSStackView()
    private let scroll = NSScrollView()

    /// What's listed, in order: a track, or the new-track offer.
    enum Item: Equatable {
        case track(TrackPill.Row)
        case newTrack(String)
    }
    private(set) var items: [Item] = []
    private(set) var highlighted: Int?
    private var rowViews: [TrackPopoverRow] = []

    init(snapshot: TrackPill.Snapshot) {
        self.snapshot = snapshot
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func focusFilter() { view.window?.makeFirstResponder(filterField) }

    override func loadView() {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = DS.Spacing.m
        root.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 12, right: 14)

        let header = NSStackView()
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = DS.Spacing.xxs
        // The projects, as the stage bar shows stages: each its mark, this one also its name.
        // One click moves the window there; the one left keeps running (ProjectSpaces).
        if let path = snapshot.projectPath {
            let current = URL(fileURLWithPath: path).standardizedFileURL.path
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = DS.Spacing.xs
            for space in ProjectSpaces.shared.shown(current: URL(fileURLWithPath: path)) {
                let isCurrent = space.path == current
                let chip = NSButton(title: isCurrent ? space.name : "", image: ProjectSpaces.image(for: space, pointSize: 13) ?? NSImage(), target: self, action: #selector(projectTapped(_:)))
                chip.isBordered = false
                chip.imagePosition = isCurrent ? .imageLeading : .imageOnly
                chip.imageHugsTitle = true
                chip.font = DS.Text.body(.semibold)
                chip.toolTip = isCurrent ? nil : space.name
                chip.identifier = NSUserInterfaceItemIdentifier(space.path)
                chip.setAccessibilityLabel(isCurrent ? "\(space.name), current project" : "Switch to \(space.name)")
                chip.wantsLayer = true
                if isCurrent { chip.layer?.cornerRadius = DS.Radius.control; chip.bindLayerBackground(DS.Color.selectedCapsule) }
                chip.menu = projectMenu(for: space, isCurrent: isCurrent)
                chip.translatesAutoresizingMaskIntoConstraints = false
                chip.heightAnchor.constraint(equalToConstant: 26).isActive = true
                chip.widthAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true
                row.addArrangedSubview(chip)
                // Something there wants you: the activity's dot on the project's mark.
                if !isCurrent, let state = ActivityCenter.shared.attention(forProject: space.path) {
                    let dot = DS.StatusDot(state: state)
                    dot.setAccessibilityElement(false)
                    chip.addSubview(dot)
                    NSLayoutConstraint.activate([
                        dot.centerXAnchor.constraint(equalTo: chip.trailingAnchor, constant: -6),
                        dot.centerYAnchor.constraint(equalTo: chip.bottomAnchor, constant: -6),
                    ])
                    chip.setAccessibilityLabel("Switch to \(space.name), \(state.name)")
                }
            }
            let add = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Open Another Project") ?? NSImage(), target: self, action: #selector(addProjectTapped))
            add.isBordered = false
            add.contentTintColor = .secondaryLabelColor
            add.toolTip = "Open Another Project\u{2026}"
            add.translatesAutoresizingMaskIntoConstraints = false
            add.widthAnchor.constraint(equalToConstant: 26).isActive = true
            add.heightAnchor.constraint(equalToConstant: 26).isActive = true
            row.addArrangedSubview(add)
            header.addArrangedSubview(row)
        } else if let project = snapshot.projectName {
            let label = NSTextField(labelWithString: project)
            label.font = DS.Text.body(.semibold)
            header.addArrangedSubview(label)
        }
        if snapshot.isTornOut {
            let label = NSTextField(labelWithString: TrackPill.tornOutNote)
            label.font = DS.Text.caption()
            label.textColor = .secondaryLabelColor
            header.addArrangedSubview(label)
        }
        for line in [snapshot.branch, snapshot.filePath].compactMap({ $0 }) {
            let label = NSTextField(labelWithString: line)
            label.font = DS.Text.code(11)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingMiddle
            header.addArrangedSubview(label)
        }
        root.addArrangedSubview(header)

        filterField.placeholderString = "Switch to a track, or name a new one"
        // The palette's field has no system focus ring either: the panel is the focus.
        filterField.focusRingType = .none
        filterField.delegate = self
        filterField.translatesAutoresizingMaskIntoConstraints = false
        filterField.setAccessibilityLabel("Filter tracks")
        root.addArrangedSubview(filterField)

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = list
        scroll.translatesAutoresizingMaskIntoConstraints = false
        list.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(scroll)

        let newTrack = Self.footerButton("New Track\u{2026}", shortcut: Shortcuts.display("track.new").nonEmpty, target: self, action: #selector(newTrackTapped))
        let openTracks = Self.footerButton("All Tracks", shortcut: nil, target: self, action: #selector(openTracksTapped))
        let footer = NSStackView(views: [newTrack, NSView(), openTracks])
        footer.orientation = .horizontal
        footer.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(footer)

        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 360),
            filterField.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -28),
            scroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -28),
            scroll.heightAnchor.constraint(lessThanOrEqualToConstant: 380),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 40),
            list.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            footer.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -28),
        ])
        view = root
        rebuild(filter: "")
        let heightFit = scroll.heightAnchor.constraint(equalTo: list.heightAnchor)
        heightFit.priority = .defaultHigh
        heightFit.isActive = true
    }

    private static func footerButton(_ title: String, shortcut: String?, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(title: "", target: target, action: action)
        button.isBordered = false
        let text = NSMutableAttributedString(string: title, attributes: [.font: DS.Text.caption(.medium), .foregroundColor: NSColor.labelColor])
        if let shortcut { text.append(NSAttributedString(string: "  " + shortcut, attributes: [.font: DS.Text.caption(), .foregroundColor: NSColor.tertiaryLabelColor])) }
        button.attributedTitle = text
        return button
    }

    func controlTextDidChange(_ obj: Notification) { rebuild(filter: filterField.stringValue) }

    /// The field keeps focus; the arrows, Return and Escape act on the list.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(1); return true
        case #selector(NSResponder.moveUp(_:)): move(-1); return true
        case #selector(NSResponder.insertNewline(_:)): activateHighlighted(); return true
        // Escape goes on to the popover, which closes.
        case #selector(NSResponder.cancelOperation(_:)): return false
        default: return false
        }
    }

    func setFilterForTesting(_ text: String) { filterField.stringValue = text; rebuild(filter: text) }
    func moveForTesting(_ delta: Int) { move(delta) }
    func activateForTesting() { activateHighlighted() }

    private func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        let next = min(items.count - 1, max(0, (highlighted ?? -1) + delta))
        setHighlight(next)
    }

    private func setHighlight(_ index: Int?) {
        highlighted = index
        for (i, row) in rowViews.enumerated() { row.isHighlighted = i == index }
        if let index, rowViews.indices.contains(index) { rowViews[index].scrollToVisible(rowViews[index].bounds) }
    }

    private func activateHighlighted() {
        guard let index = highlighted, items.indices.contains(index) else { return }
        activate(items[index])
    }

    private func activate(_ item: Item) {
        switch item {
        case .track(let row): onSelect?(row)
        case .newTrack(let name): onNewTrackNamed?(name)
        }
    }

    private func rebuild(filter raw: String) {
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        items = []
        rowViews = []
        let query = raw.trimmingCharacters(in: .whitespaces)
        let matches: (TrackPill.Row) -> Bool = { row in
            query.isEmpty || row.title.localizedCaseInsensitiveContains(query) || row.detail.localizedCaseInsensitiveContains(query)
        }
        let recent = { (rows: [TrackPill.Row]) in rows.sorted { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) } }
        let groups: [(String, [TrackPill.Row])] = [
            ("Needs you", snapshot.needsYou), ("Recent", (snapshot.base.map { [$0] } ?? []) + recent(snapshot.active)), ("Parked", recent(snapshot.parked)),
            ("Other projects", snapshot.otherProjects),
        ]
        for (title, rows) in groups {
            let shown = rows.filter(matches)
            guard !shown.isEmpty else { continue }
            addSectionLabel(title)
            for row in shown { addRow(.track(row)) }
        }
        let exact = groups.flatMap(\.1).contains { $0.title.compare(query, options: .caseInsensitive) == .orderedSame }
        if !query.isEmpty, !exact { addRow(.newTrack(query)) }
        if !items.contains(where: { if case .track(let row) = $0 { return !row.key.isEmpty } else { return true } }) {
            let empty = NSTextField(labelWithString: "No tracks yet. Type what you're working on to start one.")
            empty.font = DS.Text.caption()
            empty.textColor = .tertiaryLabelColor
            list.addArrangedSubview(empty)
        }
        // The first track that isn't the one already current: switching is what this is for.
        let firstOther = items.firstIndex { if case .track(let row) = $0 { return !row.isCurrent } else { return true } }
        setHighlight(query.isEmpty ? firstOther : (items.isEmpty ? nil : 0))
    }

    private func addSectionLabel(_ title: String) {
        let label = NSTextField(labelWithAttributedString: NSAttributedString(string: title.uppercased(), attributes: DS.Text.sectionLabelAttributes))
        let box = NSStackView(views: [label])
        box.edgeInsets = NSEdgeInsets(top: DS.Spacing.m, left: DS.Spacing.s, bottom: DS.Spacing.xs, right: 0)
        list.addArrangedSubview(box)
    }

    private func addRow(_ item: Item) {
        let index = items.count
        items.append(item)
        let view = TrackPopoverRow(item: item) { [weak self] in self?.activate(item) }
        view.onHover = { [weak self] in self?.setHighlight(index) }
        list.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        rowViews.append(view)
    }

    @objc private func newTrackTapped() { onNewTrack?() }
    /// A project's right-click menu: its color and symbol (Sill's), and closing it, which ends
    /// what it keeps running in the background. The one this window shows can't be closed here.
    private func projectMenu(for space: ProjectSpaces.Space, isCurrent: Bool) -> NSMenu {
        let menu = NSMenu()
        let names = ["Graphite", "Blue", "Purple", "Pink", "Red", "Orange", "Yellow", "Green", "Teal"]
        let colors = NSMenu()
        for (index, name) in names.enumerated() {
            let item = colors.addItem(withTitle: name, action: #selector(projectColorChosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.representedObject = space.path
            item.state = index == space.colorIndex % names.count ? .on : .off
            item.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [ProjectSpaces.palette[index]]))
        }
        menu.addItem(withTitle: "Color", action: nil, keyEquivalent: "").submenu = colors
        let symbols = NSMenu()
        for symbol in ProjectSpaces.symbols {
            let item = symbols.addItem(withTitle: "", action: #selector(projectSymbolChosen(_:)), keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)
            item.representedObject = [space.path, symbol]
            item.state = symbol == space.symbol ? .on : .off
        }
        menu.addItem(withTitle: "Symbol", action: nil, keyEquivalent: "").submenu = symbols
        menu.addItem(.separator())
        let close = menu.addItem(withTitle: "Close \u{201C}\(space.name)\u{201D}", action: isCurrent ? nil : #selector(projectCloseChosen(_:)), keyEquivalent: "")
        close.target = self
        close.representedObject = space.path
        return menu
    }

    @objc private func projectColorChosen(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        ProjectSpaces.shared.set(colorIndex: sender.tag, for: URL(fileURLWithPath: path))
    }

    @objc private func projectSymbolChosen(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2 else { return }
        ProjectSpaces.shared.set(symbol: pair[1], for: URL(fileURLWithPath: pair[0]))
    }

    @objc private func projectCloseChosen(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        ProjectSpaces.shared.remove(URL(fileURLWithPath: path))
    }

    @objc private func addProjectTapped() { onAddProject?() }

    @objc private func projectTapped(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        onSwitchProject?(URL(fileURLWithPath: path))
    }
    @objc private func openTracksTapped() { onOpenTracks?() }
}

private final class TrackPopoverRow: NSView {
    private let action: () -> Void
    private let highlight = NSView()
    private var trackingArea: NSTrackingArea?
    var onHover: (() -> Void)?
    var isHighlighted = false { didSet { highlight.alphaValue = isHighlighted ? 1 : 0 } }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    init(item: TrackSwitcherViewController.Item, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = DS.Radius.control
        highlight.bindLayerBackground(DS.Color.selectedCapsule)
        highlight.alphaValue = 0
        highlight.translatesAutoresizingMaskIntoConstraints = false
        addSubview(highlight)

        let leading: NSView
        let titleText: String, detailText: String, trailingText: String
        var isCurrent = false
        switch item {
        case .track(let row):
            let dot = DS.StatusDot(state: row.state)
            // A dot alone still says its word (Direction 03 §3.2).
            dot.toolTip = row.state.name
            leading = dot
            titleText = row.title
            detailText = row.detail
            isCurrent = row.isCurrent
            trailingText = row.isCurrent ? "Current" : row.lastActive.map { Self.relative.localizedString(for: $0, relativeTo: Date()) } ?? ""
            setAccessibilityLabel("\(row.title), \(row.state.name)\(row.isCurrent ? ", current" : "")")
        case .newTrack(let name):
            let plus = NSImageView(image: NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold)) ?? NSImage())
            plus.contentTintColor = .controlAccentColor
            leading = plus
            titleText = "New track \u{201C}\(name)\u{201D}"
            detailText = "Starts a branch for it"
            trailingText = "\u{21A9}"
            setAccessibilityLabel("New track, \(name)")
        }
        let title = NSTextField(labelWithString: titleText)
        title.font = DS.Text.body(isCurrent ? .semibold : .regular)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let detail = NSTextField(labelWithString: detailText)
        detail.font = DS.Text.code(11)
        detail.textColor = .tertiaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let trailing = NSTextField(labelWithString: trailingText)
        trailing.font = DS.Text.caption()
        trailing.textColor = .tertiaryLabelColor
        trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
        let texts = NSStackView(views: [title, detail])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 1
        let stack = NSStackView(views: [leading, texts, NSView(), trailing])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = DS.Spacing.m
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            highlight.topAnchor.constraint(equalTo: topAnchor), highlight.bottomAnchor.constraint(equalTo: bottomAnchor),
            highlight.leadingAnchor.constraint(equalTo: leadingAnchor), highlight.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DS.Spacing.s),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DS.Spacing.s),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: DS.Spacing.xs),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -DS.Spacing.xs),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }
    override func mouseEntered(with event: NSEvent) { onHover?() }
    override func mouseUp(with event: NSEvent) { action() }
    override func accessibilityPerformPress() -> Bool { action(); return true }
}
