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
    }

    struct Snapshot: Equatable {
        var title: String                 // intent, or "<default branch> · No track"
        var state: DS.StatusState
        var stateName: String
        var projectName: String?
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
    var onOpenTracks: (() -> Void)?

    private(set) var snapshot = Snapshot.empty
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
        for view in [dot, titleLabel, extraLabel, tornOutGlyph] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        extraTrailing = extraLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DS.Spacing.m)
        titleTrailing = titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DS.Spacing.m)
        glyphTrailing = tornOutGlyph.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DS.Spacing.m)
        glyphAfterTitle = tornOutGlyph.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: DS.Spacing.s)
        glyphAfterExtra = tornOutGlyph.leadingAnchor.constraint(equalTo: extraLabel.trailingAnchor, constant: DS.Spacing.s)
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DS.Spacing.m),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: DS.Spacing.s),
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
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func refresh() {
        snapshot = snapshotProvider?() ?? .empty
        dot.state = snapshot.state
        titleLabel.stringValue = snapshot.title
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
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 || event.keyCode == 36 { togglePopover() } else { super.keyDown(with: event) }
    }

    func togglePopover() {
        if let popover, popover.isShown { popover.close(); return }
        refresh()
        let content = TrackPopoverViewController(snapshot: snapshot)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = content
        content.onSelect = { [weak self, weak popover] row in popover?.close(); self?.onSelectRow?(row) }
        content.onNewTrack = { [weak self, weak popover] in popover?.close(); self?.onNewTrack?() }
        content.onOpenTracks = { [weak self, weak popover] in popover?.close(); self?.onOpenTracks?() }
        self.popover = popover
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
    }
}

/// The pill's popover: header (project, branch, file), filter, grouped rows, footer.
private final class TrackPopoverViewController: NSViewController, NSSearchFieldDelegate {
    var onSelect: ((TrackPill.Row) -> Void)?
    var onNewTrack: (() -> Void)?
    var onOpenTracks: (() -> Void)?
    private let snapshot: TrackPill.Snapshot
    private let filterField = NSSearchField()
    private let list = NSStackView()

    init(snapshot: TrackPill.Snapshot) {
        self.snapshot = snapshot
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

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
        if let project = snapshot.projectName {
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

        filterField.placeholderString = "Filter tracks"
        filterField.delegate = self
        filterField.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(filterField)

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = list
        scroll.translatesAutoresizingMaskIntoConstraints = false
        list.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(scroll)

        let newTrack = NSButton(title: "New Track…", target: self, action: #selector(newTrackTapped))
        let openTracks = NSButton(title: "Open Tracks", target: self, action: #selector(openTracksTapped))
        for button in [newTrack, openTracks] { button.bezelStyle = .rounded; button.controlSize = .small }
        let footer = NSStackView(views: [newTrack, NSView(), openTracks])
        footer.orientation = .horizontal
        footer.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(footer)

        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 340),
            filterField.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -28),
            scroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -28),
            scroll.heightAnchor.constraint(lessThanOrEqualToConstant: 360),
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

    func controlTextDidChange(_ obj: Notification) { rebuild(filter: filterField.stringValue) }

    private func rebuild(filter raw: String) {
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        // Filtering starts at two characters — one letter matches nearly every intent.
        let query = raw.trimmingCharacters(in: .whitespaces)
        let matches: (TrackPill.Row) -> Bool = { row in
            query.count < 2 || row.title.localizedCaseInsensitiveContains(query) || row.detail.localizedCaseInsensitiveContains(query)
        }
        let groups: [(String, [TrackPill.Row])] = [
            ("Needs you", snapshot.needsYou), ("Active", snapshot.active), ("Parked", snapshot.parked),
            ("Other projects", snapshot.otherProjects),
        ]
        for (title, rows) in groups {
            let shown = rows.filter(matches)
            guard !shown.isEmpty else { continue }
            let label = NSTextField(labelWithAttributedString: NSAttributedString(string: title.uppercased(), attributes: DS.Text.sectionLabelAttributes))
            let labelBox = NSStackView(views: [label])
            labelBox.edgeInsets = NSEdgeInsets(top: DS.Spacing.m, left: 0, bottom: DS.Spacing.xs, right: 0)
            list.addArrangedSubview(labelBox)
            for row in shown {
                let view = TrackPopoverRow(row: row) { [weak self] in self?.onSelect?(row) }
                list.addArrangedSubview(view)
                view.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            }
        }
    }

    @objc private func newTrackTapped() { onNewTrack?() }
    @objc private func openTracksTapped() { onOpenTracks?() }
}

private final class TrackPopoverRow: NSView {
    private let action: () -> Void
    private let highlight = NSView()
    private var trackingArea: NSTrackingArea?

    init(row: TrackPill.Row, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = DS.Radius.control
        highlight.bindLayerBackground(DS.Color.overlay)
        highlight.alphaValue = 0
        highlight.translatesAutoresizingMaskIntoConstraints = false
        addSubview(highlight)
        let dot = DS.StatusDot(state: row.state)
        let title = NSTextField(labelWithString: row.title)
        title.font = DS.Text.body(row.isCurrent ? .semibold : .regular)
        title.lineBreakMode = .byTruncatingTail
        let detail = NSTextField(labelWithString: row.detail)
        detail.font = DS.Text.code(11)
        detail.textColor = .tertiaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        let check = NSImageView(image: NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Current") ?? NSImage())
        check.contentTintColor = .secondaryLabelColor
        check.isHidden = !row.isCurrent
        let texts = NSStackView(views: [title, detail])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 1
        let stack = NSStackView(views: [dot, texts, NSView(), check])
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
        setAccessibilityLabel("\(row.title), \(row.state.name)\(row.isCurrent ? ", current" : "")")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }
    override func mouseEntered(with event: NSEvent) { highlight.alphaValue = 1 }
    override func mouseExited(with event: NSEvent) { highlight.alphaValue = 0 }
    override func mouseUp(with event: NSEvent) { action() }
    override func accessibilityPerformPress() -> Bool { action(); return true }
}
