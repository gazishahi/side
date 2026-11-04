import AppKit
import SideAgents

/// Everything the Tracks stage's detail pane says about one track, gathered by the stage.
struct TrackDetail {
    var track: Track
    var isCurrent: Bool
    var state: DS.StatusState
    var stateText: String
    var baseRef: String
    var summary: TrackStore.GitSummary?
    var agent: String
    var autonomy: String?
    var parentIntent: String?
    var subtracks: Int
    /// Newest first, a few; `checkpointCount` is all of them.
    var checkpoints: [Checkpoint]
    var checkpointCount: Int
}

/// The Tracks stage's detail pane (SIDE_RFC_FIND_REVIEW_TRACKS.md, T1): the selected track's
/// name and state, where it lives, what it has changed, who works on it, its latest checkpoints,
/// and what you can do with it.
@MainActor
final class TrackDetailView: NSView {
    var onSwitch: (() -> Void)?
    var onOpenStage: ((ShellViewController.Stage) -> Void)?
    var onMore: ((NSView) -> Void)?

    private let stack = NSStackView()
    private let scroll = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "Select a track to see it here.")

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
    private static let bytes: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        bindLayerBackground(DS.Color.raised)
        layer?.cornerRadius = DS.Radius.surface

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DS.Spacing.m
        stack.edgeInsets = NSEdgeInsets(top: DS.Spacing.section, left: DS.Spacing.section, bottom: DS.Spacing.section, right: DS.Spacing.section)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedStackHost()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        emptyLabel.font = DS.Text.body()
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor), stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor), stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor), emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// How much of the bottom something floats over: the pane scrolls under it.
    var bottomInset: CGFloat = 0 {
        didSet {
            scroll.automaticallyAdjustsContentInsets = false
            scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: bottomInset, right: 0)
        }
    }

    /// What the pane says, for tests: its text, in order.
    private(set) var shownText: [String] = []

    func show(_ detail: TrackDetail?) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        shownText = []
        emptyLabel.isHidden = detail != nil
        scroll.isHidden = detail == nil
        guard let detail else { return }
        let track = detail.track
        let inset = -DS.Spacing.section * 2

        // The name, and its state.
        let title = NSTextField(wrappingLabelWithString: track.intent.isEmpty ? track.branchName : track.intent)
        title.font = DS.Text.title()
        title.isSelectable = true
        add(title, width: inset)
        let status = DS.StatusLabel(state: detail.state, text: detail.isCurrent ? "\(detail.stateText) \u{00B7} the current track" : detail.stateText)
        add(status)
        let branch = NSTextField(labelWithString: "\(track.branchName) \u{2192} \(detail.baseRef)")
        branch.font = DS.Text.code(12)
        branch.textColor = .secondaryLabelColor
        branch.lineBreakMode = .byTruncatingMiddle
        add(branch, width: inset)
        stack.setCustomSpacing(DS.Spacing.xl, after: branch)

        // What you can do with it.
        var actions: [NSView] = []
        if detail.isCurrent {
            actions.append(Self.textButton("Open in Editor", emphasized: true, target: self, action: #selector(openMake)))
        } else {
            let primary = NSButton(title: "Switch to Track", target: self, action: #selector(switchTapped))
            primary.bezelStyle = .push
            primary.bezelColor = .controlAccentColor
            primary.keyEquivalent = "\r"
            actions.append(primary)
        }
        actions.append(Self.textButton("Agent", emphasized: false, target: self, action: #selector(openThink)))
        actions.append(Self.textButton("Changes", emphasized: false, target: self, action: #selector(openReview)))
        let more = Self.textButton("\u{22EF}", emphasized: false, target: self, action: #selector(moreTapped(_:)))
        more.setAccessibilityLabel("More actions")
        more.toolTip = "Rename, open in a new window, park, archive, delete\u{2026}"
        actions.append(more)
        let actionRow = NSStackView(views: actions)
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = DS.Spacing.xl
        add(actionRow)
        stack.setCustomSpacing(DS.Spacing.section, after: actionRow)
        addHairline(inset)

        // Facts.
        var facts: [(String, String)] = []
        facts.append(("Last worked on", detail.isCurrent ? "Now" : Self.relative.localizedString(for: track.lastActiveAt, relativeTo: Date())))
        facts.append(("Created", Self.relative.localizedString(for: track.createdAt, relativeTo: Date())))
        if let summary = detail.summary {
            var parts: [String] = []
            parts.append(summary.aheadCount == 1 ? "1 commit ahead" : "\(summary.aheadCount) commits ahead")
            if summary.behindCount > 0 { parts.append("\(summary.behindCount) behind") }
            if let uncommitted = summary.uncommittedCount { parts.append(uncommitted == 0 ? "nothing uncommitted" : "\(uncommitted) uncommitted") }
            facts.append(("Changes", parts.joined(separator: ", ")))
            if let bytes = summary.diskUsageBytes { facts.append(("Working copy", Self.bytes.string(fromByteCount: Int64(bytes)))) }
        }
        if let path = track.workingDirectoryPath { facts.append(("Folder", (path as NSString).abbreviatingWithTildeInPath)) }
        facts.append(("Agent", detail.agent + (detail.autonomy.map { " \u{00B7} \($0)" } ?? "")))
        if let parent = detail.parentIntent { facts.append(("Stacked on", parent)) }
        if detail.subtracks > 0 { facts.append(("Subtracks", "\(detail.subtracks)")) }
        let grid = NSGridView(views: facts.map { label, value in
            let key = NSTextField(labelWithString: label)
            key.font = DS.Text.caption()
            key.textColor = .secondaryLabelColor
            let text = NSTextField(wrappingLabelWithString: value)
            text.font = DS.Text.body()
            text.isSelectable = true
            text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return [key, text]
        })
        grid.rowSpacing = DS.Spacing.m
        grid.columnSpacing = DS.Spacing.xl
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        add(grid, width: inset)
        shownText += facts.map { "\($0.0): \($0.1)" }
        stack.setCustomSpacing(DS.Spacing.section, after: grid)
        addHairline(inset)

        // The latest checkpoints.
        let heading = NSTextField(labelWithAttributedString: NSAttributedString(
            string: detail.checkpointCount > detail.checkpoints.count ? "CHECKPOINTS \u{00B7} LATEST \(detail.checkpoints.count) OF \(detail.checkpointCount)" : "CHECKPOINTS",
            attributes: DS.Text.sectionLabelAttributes))
        add(heading)
        if detail.checkpoints.isEmpty {
            let none = NSTextField(wrappingLabelWithString: "None yet. One is made when an agent's approved edit or command lands on this track.")
            none.font = DS.Text.caption()
            none.textColor = .tertiaryLabelColor
            add(none, width: inset)
        } else {
            for (offset, checkpoint) in detail.checkpoints.enumerated() {
                let number = detail.checkpointCount - offset
                let line = NSTextField(labelWithString: "")
                line.attributedStringValue = Self.checkpointLine(checkpoint, number: number)
                line.lineBreakMode = .byTruncatingTail
                line.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                add(line, width: inset)
            }
            let review = Self.textButton("See them in Changes", emphasized: false, target: self, action: #selector(openReview))
            add(review)
        }
    }

    private static func checkpointLine(_ checkpoint: Checkpoint, number: Int) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "\(number)  ", attributes: [.font: DS.Text.code(11), .foregroundColor: NSColor.tertiaryLabelColor])
        result.append(NSAttributedString(string: checkpoint.declaredIntent.isEmpty ? "No description" : checkpoint.declaredIntent,
                                         attributes: [.font: DS.Text.body(), .foregroundColor: NSColor.labelColor]))
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        result.append(NSAttributedString(string: "  \u{00B7}  " + formatter.localizedString(for: checkpoint.createdAt, relativeTo: Date()),
                                         attributes: [.font: DS.Text.caption(), .foregroundColor: NSColor.secondaryLabelColor]))
        if let verification = checkpoint.verification {
            result.append(NSAttributedString(string: "  \u{00B7}  " + (verification.passed ? "verified" : "failed"), attributes: [
                .font: DS.Text.caption(), .foregroundColor: verification.passed ? DS.Color.statusVerified : DS.Color.statusFailed,
            ]))
        }
        return result
    }

    private func add(_ view: NSView, width inset: CGFloat? = nil) {
        stack.addArrangedSubview(view)
        if let inset { view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: inset).isActive = true }
        if let field = view as? NSTextField { shownText.append(field.stringValue) }
        if let status = view as? DS.StatusLabel, let label = status.arrangedSubviews.compactMap({ $0 as? NSTextField }).first { shownText.append(label.stringValue) }
    }

    private func addHairline(_ inset: CGFloat) {
        let line = NSBox()
        line.boxType = .custom
        line.borderType = .noBorder
        line.fillColor = DS.Color.hairline
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        add(line, width: inset)
        stack.setCustomSpacing(DS.Spacing.section, after: line)
    }

    private static func textButton(_ title: String, emphasized: Bool, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.isBordered = false
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: DS.Text.body(emphasized ? .semibold : .medium),
            .foregroundColor: emphasized ? NSColor.controlAccentColor : NSColor.labelColor,
        ])
        return button
    }

    @objc private func switchTapped() { onSwitch?() }
    @objc private func openMake() { onOpenStage?(.make) }
    @objc private func openThink() { onOpenStage?(.think) }
    @objc private func openReview() { onOpenStage?(.review) }
    @objc private func moreTapped(_ sender: NSButton) { onMore?(sender) }
}

private final class FlippedStackHost: NSView {
    override var isFlipped: Bool { true }
}
