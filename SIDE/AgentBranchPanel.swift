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
        /// The branch, and the base it's measured against.
        var branch = ""
        var base = ""
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
    /// The header's actions: the whole branch in Changes, its terminal, and closing the panel.
    var onReviewChanges: (() -> Void)?
    var onShowTerminal: (() -> Void)?
    var onClose: (() -> Void)?

    private(set) var content = Content()
    private let scroll = NSScrollView()
    private let stack = FlippedStack()
    private let header = PanelHeader()

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
        stack.spacing = DS.Spacing.section
        stack.edgeInsets = NSEdgeInsets(top: DS.Spacing.m, left: DS.Spacing.m, bottom: DS.Spacing.l, right: DS.Spacing.m)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        header.onReview = { [weak self] in self?.onReviewChanges?() }
        header.onTerminal = { [weak self] in self?.onShowTerminal?() }
        header.onClose = { [weak self] in self?.onClose?() }
        addSubview(header)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
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
        let changedShape = content.isEmpty != self.content.isEmpty
        self.content = content
        header.set(branch: content.branch, base: content.base, hasChanges: !content.files.isEmpty, hasTerminals: !content.terminals.isEmpty)
        // A change of what it says reads as one change: the old sections fade into the new.
        DS.Motion.crossfade(scroll, duration: changedShape ? DS.Motion.presentDuration : DS.Motion.fadeDuration)
        rebuild()
    }

    // MARK: Showing and hiding

    func reveal(floating: Bool) { DS.Motion.revealEdgePanel(self, floating: floating) }
    func dismiss(floating: Bool, completion: @escaping @MainActor () -> Void) { DS.Motion.dismissEdgePanel(self, floating: floating, completion: completion) }
    func cancelDismiss() { DS.Motion.cancelEdgeDismiss(self) }

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
            add(PanelEmptyState())
            return
        }
        if !content.plan.isEmpty {
            let done = content.plan.filter { $0.status == .completed }.count
            add(section("Plan", detail: "\(done) of \(content.plan.count) done", rows: content.plan.map(planRow)))
        }
        if !content.files.isEmpty {
            let added = content.files.reduce(0) { $0 + $1.added }, removed = content.files.reduce(0) { $0 + $1.removed }
            add(section(content.files.count == 1 ? "1 Changed File" : "\(content.files.count) Changed Files", detail: counts(added, removed), rows: content.files.map(fileRow)))
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
        // Side's one uppercase: the section label, tracked (Direction 02 §2.6).
        let header = NSTextField(labelWithAttributedString: NSAttributedString(string: title.uppercased(), attributes: DS.Text.sectionLabelAttributes))
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
            let text = NSMutableAttributedString(string: "+\(file.added)", attributes: [.font: DS.Text.caption(.medium), .foregroundColor: DS.Color.statusVerified])
            text.append(NSAttributedString(string: " \u{2212}\(file.removed)", attributes: [.font: DS.Text.caption(.medium), .foregroundColor: DS.Color.statusFailed]))
            return text
        }())
        let row = PanelRow(image: FileIcon.image(for: URL(fileURLWithPath: file.path), isDirectory: false, size: 14), tint: nil, title: name, detail: folder.isEmpty ? nil : folder, trailing: trailing)
        row.toolTip = "\(file.path)\nClick to open in Editor"
        row.onClick = { [weak self] in self?.onOpenFile?(file.path) }
        row.hoverActions = [
            .init(symbol: "doc.text", help: "Open in Editor") { [weak self] in self?.onOpenFile?(file.path) },
            .init(symbol: "plus.forwardslash.minus", help: "Show in Changes") { [weak self] in self?.onShowFileInChanges?(file.path) },
        ]
        row.setAccessibilityLabel("\(file.path), \(file.added) added, \(file.removed) removed")
        return row
    }

    private func terminalRow(_ session: TracksWorkspaceViewController.BoardSession) -> NSView {
        let status = DS.StatusLabel(state: session.state, text: session.word)
        let row = PanelRow(image: ProgramMarks.image(forProgram: session.program), title: session.title, trailing: status)
        row.onClick = { [weak self] in self?.onOpenTerminal?(session.id) }
        row.toolTip = "Go to this terminal"
        row.setAccessibilityLabel("\(session.title), \(session.word)")
        return row
    }

    private func checkpointRow(_ checkpoint: CheckpointLine) -> NSView {
        let status = DS.StatusLabel(state: checkpoint.state, text: checkpoint.word)
        let row = PanelRow(symbol: nil, tint: nil, title: checkpoint.text, trailing: status)
        row.onClick = { [weak self] in self?.onOpenCheckpoint?(checkpoint.id) }
        row.toolTip = "Open this checkpoint"
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
    struct HoverAction {
        let symbol: String
        let help: String
        let perform: () -> Void
    }
    /// Shown on hover over the trailing slot, as small icon buttons with their names as help.
    var hoverActions: [HoverAction] = [] {
        didSet {
            actions.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for (index, action) in hoverActions.enumerated() {
                let button = NSButton(image: NSImage(systemSymbolName: action.symbol, accessibilityDescription: action.help) ?? NSImage(), target: self, action: #selector(performHoverAction(_:)))
                button.isBordered = false
                button.symbolConfiguration = .init(pointSize: 11, weight: .medium)
                button.contentTintColor = .secondaryLabelColor
                button.toolTip = action.help
                button.tag = index
                actions.addArrangedSubview(button)
            }
            actions.isHidden = hoverActions.isEmpty
            if !hoverActions.isEmpty {
                setAccessibilityCustomActions(hoverActions.map { action in NSAccessibilityCustomAction(name: action.help) { action.perform(); return true } })
            }
        }
    }
    private let highlight = NSView()
    private let actions = NSStackView()
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

        actions.spacing = DS.Spacing.s
        actions.isHidden = true
        actions.alphaValue = 0
        actions.translatesAutoresizingMaskIntoConstraints = false
        addSubview(actions)

        var constraints = [
            highlight.topAnchor.constraint(equalTo: topAnchor),
            highlight.bottomAnchor.constraint(equalTo: bottomAnchor),
            highlight.leadingAnchor.constraint(equalTo: leadingAnchor),
            highlight.trailingAnchor.constraint(equalTo: trailingAnchor),
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DS.Spacing.s),
            text.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 26),
            actions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DS.Spacing.s),
            actions.centerYAnchor.constraint(equalTo: centerYAnchor),
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
            if !hoverActions.isEmpty {
                actions.animator().alphaValue = hovered ? 1 : 0
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

    @objc private func performHoverAction(_ sender: NSButton) {
        guard hoverActions.indices.contains(sender.tag) else { return }
        hoverActions[sender.tag].perform()
    }
}

/// The panel's head: the branch and its base, and what to do with it. Review Changes opens the
/// whole branch in Changes; Terminal goes to its terminal; × closes the panel.
private final class PanelHeader: NSView {
    var onReview: (() -> Void)?
    var onTerminal: (() -> Void)?
    var onClose: (() -> Void)?
    private let name = NSTextField(labelWithString: "")
    private let base = NSTextField(labelWithString: "")
    private lazy var review = PanelHeaderButton(symbol: "plus.forwardslash.minus", title: "Review Changes") { [weak self] in self?.onReview?() }
    private lazy var terminal = PanelHeaderButton(symbol: DS.Glyph.name("terminal"), title: "Terminal") { [weak self] in self?.onTerminal?() }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        let glyph = NSImageView(image: DS.Glyph.image(named: DS.Glyph.name("branches"), pointSize: 14) ?? NSImage())
        glyph.contentTintColor = .secondaryLabelColor
        name.font = DS.Text.heading()
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        base.font = DS.Text.caption()
        base.textColor = .tertiaryLabelColor
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close the panel") ?? NSImage(), target: self, action: #selector(closeTapped))
        close.isBordered = false
        close.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        close.contentTintColor = .tertiaryLabelColor
        close.toolTip = "Close the panel (\(Shortcuts.display("view.agentPanel")))"
        let buttons = NSStackView(views: [review, terminal])
        buttons.spacing = DS.Spacing.s
        let rule = NSView()
        rule.bindLayerBackground(DS.Color.hairline)
        for view in [glyph, name, base, close, buttons, rule] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DS.Spacing.l + 2),
            glyph.centerYAnchor.constraint(equalTo: name.centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 14),
            name.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: DS.Spacing.s),
            name.topAnchor.constraint(equalTo: topAnchor, constant: DS.Spacing.l + 2),
            name.trailingAnchor.constraint(lessThanOrEqualTo: close.leadingAnchor, constant: -DS.Spacing.s),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DS.Spacing.l),
            close.centerYAnchor.constraint(equalTo: name.centerYAnchor),
            base.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            base.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 1),
            buttons.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DS.Spacing.l),
            buttons.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -DS.Spacing.l),
            buttons.topAnchor.constraint(equalTo: base.bottomAnchor, constant: DS.Spacing.l),
            rule.topAnchor.constraint(equalTo: buttons.bottomAnchor, constant: DS.Spacing.l),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DS.Spacing.l),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DS.Spacing.l),
            rule.heightAnchor.constraint(equalToConstant: 1),
            rule.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func set(branch: String, base: String, hasChanges: Bool, hasTerminals: Bool) {
        name.stringValue = branch.isEmpty ? "This branch" : branch
        self.base.stringValue = base.isEmpty || base == branch ? "" : "from \(base)"
        review.isEnabled = hasChanges
        review.toolTip = hasChanges ? "Open the branch\u{2019}s changes in Changes" : "Nothing changed on this branch yet"
        terminal.toolTip = hasTerminals ? "Go to this branch\u{2019}s terminal" : "Open a terminal on this branch"
    }

    @objc private func closeTapped() { onClose?() }
}

/// A small action in the panel's head: a symbol and a word on a capsule of the hover tone,
/// pressing in under the pointer.
private final class PanelHeaderButton: NSView {
    private let perform: () -> Void
    private let label: NSTextField
    private let icon: NSImageView
    var isEnabled = true { didSet { alphaValue = isEnabled ? 1 : 0.45 } }

    init(symbol: String, title: String, perform: @escaping () -> Void) {
        self.perform = perform
        label = NSTextField(labelWithString: title)
        icon = NSImageView(image: DS.Glyph.image(named: symbol, pointSize: 11) ?? NSImage())
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        bindLayerBackground(DS.Color.hoverCapsule)
        layer?.cornerRadius = DS.Radius.control
        layer?.cornerCurve = .continuous
        icon.symbolConfiguration = .init(pointSize: 11, weight: .medium)
        icon.contentTintColor = .labelColor
        label.font = DS.Text.caption(.medium)
        for view in [icon, label] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DS.Spacing.m),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 13),
            icon.heightAnchor.constraint(equalToConstant: 13),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: DS.Spacing.s),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DS.Spacing.l),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseDown(with event: NSEvent) { if isEnabled { DS.Motion.press(self, down: true, amount: 1.04) } }
    override func mouseUp(with event: NSEvent) {
        DS.Motion.press(self, down: false)
        guard isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        perform()
    }
    override func accessibilityPerformPress() -> Bool { guard isEnabled else { return false }; perform(); return true }
    override func resetCursorRects() { if isEnabled { addCursorRect(bounds, cursor: .pointingHand) } }
}

/// Nothing on the branch yet: what will show here, set as an empty state.
private final class PanelEmptyState: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        let glyph = NSImageView(image: DS.Glyph.image(named: DS.Glyph.name("agent"), pointSize: 22) ?? NSImage())
        glyph.contentTintColor = .tertiaryLabelColor
        let title = NSTextField(labelWithString: "Nothing here yet")
        title.font = DS.Text.body(.medium)
        title.textColor = .secondaryLabelColor
        let detail = NSTextField(wrappingLabelWithString: "As the agent works, its plan, the files it changes, its terminals and checkpoints appear here.")
        detail.font = DS.Text.caption()
        detail.textColor = .tertiaryLabelColor
        detail.alignment = .center
        let stack = NSStackView(views: [glyph, title, detail])
        stack.orientation = .vertical
        stack.spacing = DS.Spacing.s
        stack.setCustomSpacing(DS.Spacing.m, after: glyph)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 40),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DS.Spacing.l),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DS.Spacing.l),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
