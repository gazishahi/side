import AppKit
import SideAgents

/// Agent's side panel (SIDE_RFC_AGENT_PANEL.md): what the agent is doing to the branch, beside
/// the conversation. Four sections, each hidden while it has nothing to say: the agent's plan,
/// the branch's changed files, its Terminal tabs, its latest checkpoints. About the branch, not
/// the conversation: switching conversations on a track leaves it as it is.
///
/// One raised card, docked at the stage's trailing edge or floating over it; the stage decides
/// which (`ThinkWorkspaceViewController.layoutBranchPanel`).
final class AgentBranchPanel: NSView {
    static let width: CGFloat = 280

    struct FileChange: Equatable {
        let path: String
        let added: Int
        let removed: Int
    }

    struct CheckpointLine: Equatable {
        let id: UUID
        let text: String
        let state: DS.StatusState
        let word: String
    }

    struct Content: Equatable {
        var plan: [AgentPlanItem] = []
        var files: [FileChange] = []
        var terminals: [TracksWorkspaceViewController.BoardSession] = []
        var checkpoints: [CheckpointLine] = []
        var isEmpty: Bool { plan.isEmpty && files.isEmpty && terminals.isEmpty && checkpoints.isEmpty }
    }

    var onOpenFile: ((String) -> Void)?
    var onShowFileInChanges: ((String) -> Void)?
    var onOpenTerminal: ((UUID) -> Void)?
    var onOpenCheckpoint: ((UUID) -> Void)?

    private(set) var content = Content()
    private let scroll = NSScrollView()
    private let stack = FlippedStack()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "Nothing on this branch yet. The agent\u{2019}s plan, the files it changes, its terminals and checkpoints show here.")

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = DS.Radius.surface
        layer?.cornerCurve = .continuous
        bindLayerBackground(DS.Color.raised)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Branch panel")

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DS.Spacing.l
        stack.edgeInsets = NSEdgeInsets(top: DS.Spacing.l, left: DS.Spacing.m, bottom: DS.Spacing.l, right: DS.Spacing.m)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        emptyLabel.font = DS.Text.caption()
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ])
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Redraws only when something it shows changed.
    func show(_ content: Content) {
        guard content != self.content else { return }
        self.content = content
        rebuild()
    }

    /// Floating over the conversation: a shadow sets it off. Docked: none.
    func setFloating(_ floating: Bool) {
        shadow = floating ? {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
            shadow.shadowBlurRadius = 18
            shadow.shadowOffset = NSSize(width: 0, height: -4)
            return shadow
        }() : nil
    }

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let inner = Self.width - DS.Spacing.m * 2
        func add(_ section: NSView) {
            stack.addArrangedSubview(section)
            section.widthAnchor.constraint(equalToConstant: inner).isActive = true
        }
        if content.isEmpty {
            add(emptyLabel)
            return
        }
        if !content.plan.isEmpty {
            let done = content.plan.filter { $0.status == .completed }.count
            add(section("Plan", detail: "\(done) of \(content.plan.count)", rows: content.plan.map(planRow)))
        }
        if !content.files.isEmpty {
            let added = content.files.reduce(0) { $0 + $1.added }, removed = content.files.reduce(0) { $0 + $1.removed }
            add(section("Changed Files", detail: counts(added, removed), rows: content.files.map(fileRow)))
        }
        if !content.terminals.isEmpty {
            add(section("Terminals", detail: nil, rows: content.terminals.map(terminalRow)))
        }
        if !content.checkpoints.isEmpty {
            add(section("Checkpoints", detail: nil, rows: content.checkpoints.map(checkpointRow)))
        }
    }

    // MARK: Sections

    private func section(_ title: String, detail: String?, rows: [NSView]) -> NSView {
        let header = NSTextField(labelWithString: title)
        header.font = DS.Text.caption(.semibold)
        header.textColor = .secondaryLabelColor
        let headerRow = NSStackView(views: [header])
        headerRow.orientation = .horizontal
        headerRow.edgeInsets = NSEdgeInsets(top: 0, left: DS.Spacing.s, bottom: 0, right: DS.Spacing.s)
        if let detail {
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let label = NSTextField(labelWithString: detail)
            label.font = DS.Text.caption()
            label.textColor = .tertiaryLabelColor
            headerRow.addArrangedSubview(spacer)
            headerRow.addArrangedSubview(label)
        }
        let column = NSStackView(views: [headerRow] + rows)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 1
        column.setCustomSpacing(DS.Spacing.xs, after: headerRow)
        for view in column.arrangedSubviews { view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        column.setAccessibilityElement(true)
        column.setAccessibilityRole(.group)
        column.setAccessibilityLabel(title)
        return column
    }

    private func counts(_ added: Int, _ removed: Int) -> String { "+\(added) \u{2212}\(removed)" }

    private func planRow(_ item: AgentPlanItem) -> NSView {
        let symbol: String, tint: NSColor, textColor: NSColor, weight: NSFont.Weight
        switch item.status {
        case .completed: (symbol, tint, textColor, weight) = ("checkmark.circle.fill", DS.Color.statusVerified, .secondaryLabelColor, .regular)
        case .inProgress: (symbol, tint, textColor, weight) = ("circle.inset.filled", .labelColor, .labelColor, .medium)
        case .pending: (symbol, tint, textColor, weight) = ("circle", .tertiaryLabelColor, .labelColor, .regular)
        }
        let row = PanelRow(symbol: symbol, tint: tint, title: item.content, titleColor: textColor, weight: weight, wraps: true)
        row.setAccessibilityLabel("\(item.content), \(item.status == .completed ? "done" : item.status == .inProgress ? "in progress" : "to do")")
        return row
    }

    private func fileRow(_ file: FileChange) -> NSView {
        let name = (file.path as NSString).lastPathComponent
        let folder = (file.path as NSString).deletingLastPathComponent
        let trailing = NSTextField(labelWithAttributedString: {
            let text = NSMutableAttributedString(string: "+\(file.added)", attributes: [.font: DS.Text.caption(.medium), .foregroundColor: NSColor.systemGreen])
            text.append(NSAttributedString(string: " \u{2212}\(file.removed)", attributes: [.font: DS.Text.caption(.medium), .foregroundColor: NSColor.systemRed]))
            return text
        }())
        let row = PanelRow(symbol: nil, tint: nil, title: name, detail: folder.isEmpty ? nil : folder, trailing: trailing)
        row.toolTip = file.path
        row.onClick = { [weak self] in self?.onOpenFile?(file.path) }
        row.hoverAction = ("Changes", { [weak self] in self?.onShowFileInChanges?(file.path) })
        row.setAccessibilityLabel("\(file.path), \(file.added) added, \(file.removed) removed")
        return row
    }

    private func terminalRow(_ session: TracksWorkspaceViewController.BoardSession) -> NSView {
        let status = DS.StatusLabel(state: session.state, text: session.word)
        let row = PanelRow(image: ProgramMarks.image(forProgram: session.program), title: session.title, trailing: status)
        row.onClick = { [weak self] in self?.onOpenTerminal?(session.id) }
        row.setAccessibilityLabel("\(session.title), \(session.word)")
        return row
    }

    private func checkpointRow(_ checkpoint: CheckpointLine) -> NSView {
        let status = DS.StatusLabel(state: checkpoint.state, text: checkpoint.word)
        let row = PanelRow(symbol: nil, tint: nil, title: checkpoint.text, trailing: status)
        row.onClick = { [weak self] in self?.onOpenCheckpoint?(checkpoint.id) }
        row.setAccessibilityLabel("\(checkpoint.text), \(checkpoint.word)")
        return row
    }

    // MARK: Data

    /// The branch's files against its base: committed since the base, staged, unstaged and
    /// untracked, with line counts. Off the main thread: it runs git.
    nonisolated static func changedFiles(cwd: String, base: String) -> [FileChange] {
        // Against where the branch left its base, so the base moving on isn't counted.
        let mergeBase = GitPaths.runGitRaw(["merge-base", base, "HEAD"], cwd: cwd)
        let from = mergeBase.success ? mergeBase.output.trimmingCharacters(in: .whitespacesAndNewlines) : "HEAD"
        var files: [String: FileChange] = [:]
        let diff = GitPaths.runGitRaw(["diff", "--numstat", "--no-renames", from.isEmpty ? "HEAD" : from], cwd: cwd)
        if diff.success {
            for line in diff.output.split(separator: "\n") {
                let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
                guard parts.count == 3 else { continue }
                files[parts[2]] = FileChange(path: parts[2], added: Int(parts[0]) ?? 0, removed: Int(parts[1]) ?? 0)
            }
        }
        let untracked = GitPaths.runGitRaw(["ls-files", "--others", "--exclude-standard"], cwd: cwd)
        if untracked.success {
            for path in untracked.output.split(separator: "\n").map(String.init) where files[path] == nil {
                let url = URL(fileURLWithPath: cwd).appendingPathComponent(path)
                // A count, not a read of anything big: past a megabyte it's a file, not lines.
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let lines = size < 1_000_000 ? (try? String(contentsOf: url, encoding: .utf8)).map { $0.split(separator: "\n", omittingEmptySubsequences: false).count - ($0.hasSuffix("\n") ? 1 : 0) } ?? 0 : 0
                files[path] = FileChange(path: path, added: lines, removed: 0)
            }
        }
        return files.values.sorted { $0.path < $1.path }
    }

    /// A checkpoint's verification, as one word.
    static func checkpointLine(_ checkpoint: Checkpoint) -> CheckpointLine {
        let text = checkpoint.declaredIntent.isEmpty ? "Checkpoint" : checkpoint.declaredIntent
        guard let verification = checkpoint.verification else { return CheckpointLine(id: checkpoint.id, text: text, state: .idle, word: "Unverified") }
        return verification.passed
            ? CheckpointLine(id: checkpoint.id, text: text, state: .verified, word: "Verified")
            : CheckpointLine(id: checkpoint.id, text: text, state: .failed, word: "Failed")
    }
}

private final class FlippedStack: NSStackView {
    override var isFlipped: Bool { true }
}

/// One line in the panel: an optional mark, a title (and a dimmer detail), something trailing.
/// Clickable ones highlight on hover; a hover action fades in over the trailing slot.
private final class PanelRow: NSView {
    var onClick: (() -> Void)? { didSet { updateCursor() } }
    var hoverAction: (title: String, perform: () -> Void)? {
        didSet {
            guard let hoverAction else { return }
            actionButton.attributedTitle = NSAttributedString(string: hoverAction.title, attributes: [.font: DS.Text.caption(.medium), .foregroundColor: NSColor.controlAccentColor])
            actionButton.isHidden = false
        }
    }
    private let highlight = NSView()
    private let actionButton = NSButton(title: "", target: nil, action: nil)
    private let trailingView: NSView?
    private var trackingArea: NSTrackingArea?

    convenience init(symbol: String?, tint: NSColor?, title: String, titleColor: NSColor = .labelColor, weight: NSFont.Weight = .regular,
                     wraps: Bool = false, detail: String? = nil, trailing: NSView? = nil) {
        let image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        self.init(image: image, tint: tint, title: title, titleColor: titleColor, weight: weight, wraps: wraps, detail: detail, trailing: trailing)
    }

    init(image: NSImage?, tint: NSColor? = .secondaryLabelColor, title: String, titleColor: NSColor = .labelColor, weight: NSFont.Weight = .regular,
         wraps: Bool = false, detail: String? = nil, trailing: NSView? = nil) {
        trailingView = trailing
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)

        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = DS.Radius.control
        highlight.bindLayerBackground(DS.Color.hoverCapsule)
        highlight.alphaValue = 0
        highlight.translatesAutoresizingMaskIntoConstraints = false
        addSubview(highlight)

        let label = wraps ? NSTextField(wrappingLabelWithString: title) : NSTextField(labelWithString: title)
        label.font = DS.Text.caption(weight)
        label.textColor = titleColor
        label.lineBreakMode = wraps ? .byWordWrapping : .byTruncatingTail
        label.maximumNumberOfLines = wraps ? 3 : 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var views: [NSView] = []
        if let image {
            let icon = NSImageView(image: image)
            icon.symbolConfiguration = .init(pointSize: 11, weight: .medium)
            icon.contentTintColor = tint
            icon.imageScaling = .scaleProportionallyDown
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.widthAnchor.constraint(equalToConstant: 14).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 14).isActive = true
            views.append(icon)
        }
        views.append(label)
        if let detail {
            let dim = NSTextField(labelWithString: detail)
            dim.font = DS.Text.caption()
            dim.textColor = .tertiaryLabelColor
            dim.lineBreakMode = .byTruncatingHead
            dim.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(240), for: .horizontal)
            views.append(dim)
        }
        let text = NSStackView(views: views)
        text.orientation = .horizontal
        // A wrapping title's mark stays level with its first line.
        text.alignment = wraps ? .top : .centerY
        text.spacing = DS.Spacing.s
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(text)

        actionButton.isBordered = false
        actionButton.target = self
        actionButton.action = #selector(performHoverAction)
        actionButton.isHidden = true
        actionButton.alphaValue = 0
        actionButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(actionButton)

        var constraints = [
            highlight.topAnchor.constraint(equalTo: topAnchor),
            highlight.bottomAnchor.constraint(equalTo: bottomAnchor),
            highlight.leadingAnchor.constraint(equalTo: leadingAnchor),
            highlight.trailingAnchor.constraint(equalTo: trailingAnchor),
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DS.Spacing.s),
            text.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 26),
            actionButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DS.Spacing.s),
            actionButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]
        if let trailing {
            trailing.translatesAutoresizingMaskIntoConstraints = false
            trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
            addSubview(trailing)
            constraints += [
                trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DS.Spacing.s),
                trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
                text.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -DS.Spacing.s),
            ]
        } else {
            constraints.append(text.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -DS.Spacing.s))
        }
        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    private func setHovered(_ hovered: Bool) {
        guard onClick != nil else { return }
        DS.Motion.fade { [self] in
            highlight.animator().alphaValue = hovered ? 1 : 0
            // The hover action takes the trailing slot, which keeps its width: nothing reflows.
            if hoverAction != nil {
                actionButton.animator().alphaValue = hovered ? 1 : 0
                trailingView?.animator().alphaValue = hovered ? 0 : 1
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onClick else { return false }
        onClick()
        return true
    }

    private func updateCursor() {
        setAccessibilityRole(onClick == nil ? .staticText : .button)
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() { if onClick != nil { addCursorRect(bounds, cursor: .pointingHand) } }

    @objc private func performHoverAction() { hoverAction?.perform() }
}
