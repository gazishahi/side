import AppKit
import SideAgents

/// The Review stage: "checkpoints, diffs, rationale, test evidence, and promotion decisions"
/// per the constitution's stage table — the surface where a track's accumulated work (its
/// checkpoints, and the cumulative diff they produced against the project's base branch) gets
/// looked at as a whole and, when ready, promoted into `main`.
///
/// Laid out changes first (SIDE_RFC_FIND_REVIEW_TRACKS.md, R1): the track and its two actions,
/// Publish and Promote, in the window's top row; a summary card (what the agent last said about
/// the work, verification and risks, and the checkpoints as a timeline to pick a range from);
/// then the changed files beside their diffs, each with a check to mark it viewed.
final class ReviewWorkspaceViewController: NSViewController {
    private weak var trackStore: TrackStore?
    private weak var sessionStore: AgentSessionStore?
    private var canonicalRoot: URL?
    private var currentTrack: Track?
    private var currentWorkingDirectory: URL?

    /// One sentence and the one action that fixes it (§6).
    private let emptyState: DS.EmptyState = {
        let state = DS.EmptyState()
        state.symbol = ShellViewController.Stage.review.symbol
        return state
    }()
    var onEmptyStateAction: ((EmptyStateAction) -> Void)?

    // The top row: the track's intent, `branch → base · N ahead`, then Publish and Promote.
    private let titleLabel = NSTextField(labelWithString: "")
    private let headerRow = NSStackView()
    private let headerDetail = NSTextField(labelWithString: "")
    // Real label set per-track in refresh() — "to main" isn't right for a stacked track, whose
    // actual base is its parent's branch.
    private let promoteButton = ChipButton(symbolName: nil, accessibilityLabel: "Promote this track's changes to its base branch", height: ReviewWorkspaceViewController.promoteHeight)
    /// Review's publishing half: push the branch, open a pull request, check the remote. Quiet
    /// beside Promote, which stays the one primary action.
    private let publishButton = ChipButton(symbolName: nil, accessibilityLabel: "Publish this track: push its branch or open a pull request", height: ReviewWorkspaceViewController.promoteHeight)
    private let publishHost = NSView()
    private let promoteHost = NSView()

    // The summary card.
    private let summaryCard = NSView()
    private let summaryStack = NSStackView()
    /// Who last spoke about the work and when; the text is what they said.
    private let accountMeta = NSTextField(labelWithString: "")
    private let accountText = NSTextField(wrappingLabelWithString: "")
    private let accountMore = NSButton(title: "", target: nil, action: nil)
    private let accountRow = NSStackView()
    private var accountExpanded = false
    /// The decision lines: verification recency, sibling overlap, and what Publish or Promote
    /// last said. Hidden when there is nothing to say — a line that's always present is a line
    /// nobody reads.
    private let verificationLine = DS.StatusLabel(state: .idle, text: "")
    private let overlapLine = DS.StatusLabel(state: .needsYou, text: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let summaryHairline = NSBox()
    private let timelineView = CheckpointTimelineView()
    private let noCheckpoints = NSTextField(wrappingLabelWithString: "No checkpoints yet. One is created automatically the first time an approved edit or command lands on this track.")
    /// Under the timeline: what the range is, and the chosen checkpoint's details and actions.
    private let rangeLabel = NSTextField(labelWithString: "")
    private let rangeMeta = NSTextField(labelWithString: "")
    private let copyButton = ReviewWorkspaceViewController.textAction("Copy SHA")
    private let undoButton = ReviewWorkspaceViewController.textAction("Undo\u{2026}")
    private let everythingButton = ReviewWorkspaceViewController.textAction("All changes")
    private let rangeRow = NSStackView()
    private let timelineRow = NSStackView()
    private var timelineWidth: NSLayoutConstraint?

    // The changes.
    private let diffTitle = NSTextField(labelWithString: "")
    private let diffTotals = NSTextField(labelWithString: "")
    /// Unified / Split. A segmented control rather than a checkbox because the two are peers, not
    /// an option and its absence; persisted, because a layout choice is a habit, not a mood.
    private let diffLayoutControl = NSSegmentedControl(labels: ["Unified", "Split"], trackingMode: .selectOne, target: nil, action: nil)
    /// Collapses every file's diff, or expands them all once they are (the owner, 2026-10-01).
    private let foldAllButton = NSButton(title: "Collapse All", target: nil, action: nil)
    private let diffToolbar = NSStackView()
    private let rail = ReviewFileRail()
    /// The review queue (phase 4): who has uncommitted changes, in the list's place while there
    /// are any; its last entry, the whole branch, is the list as before.
    private let queueRail = ReviewQueueRail()
    private var queue = ReviewQueue()
    /// The queue's chosen group; nil shows the whole branch.
    private var queueSelection: Int? = 0
    private var queueGeneration = 0
    private var queueActive: Bool { !queue.groups.isEmpty && queueSelection != nil }
    /// The queue is being read: the branch's diff waits for it rather than drawing first and
    /// being replaced a moment later.
    private var queueLoading = false
    private var queueRetries = 0
    private var pendingBranchDiff: (text: String, everything: Bool)?
    /// The chosen group's hunks as the diff shows them: by file, in order.
    private var shownHunks: [[ReviewQueue.Hunk]] = []
    private var approvedKeys: Set<String> = []
    private let approveAllButton = NSButton(title: "Approve All", target: nil, action: nil)
    private let commitButton = NSButton(title: "Commit Approved\u{2026}", target: nil, action: nil)
    private let discardButton = NSButton(title: "Discard\u{2026}", target: nil, action: nil)
    private var railWidth: NSLayoutConstraint?
    private var diffLeading: NSLayoutConstraint?
    private var cardTop: NSLayoutConstraint?
    /// Every file's changes in one Alloy document (SIDE_RFC_FIND_REVIEW_TRACKS.md, R2).
    private let diffViewer = DiffDocumentView()
    /// "Instruct…" on a file: (relative path, lines, anchor). The shell owns the conversation.
    var onInstructRequested: ((String, ClosedRange<Int>, NSView) -> Void)? {
        didSet { diffViewer.onInstruct = onInstructRequested }
    }

    /// The checkpoints, newest first, and the timeline over those on the branch.
    private var allCheckpoints: [Checkpoint] = []
    private var timeline = CheckpointTimeline(nodes: [])
    private var currentBaseRef = "main"
    /// Bumped per diff load, so a slow one for an old range doesn't land over a newer one.
    private var diffGeneration = 0
    private var viewedStore: ReviewViewedStore { .shared }

    override func loadView() { view = NSView() }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Restyles itself on a text-size change (`textScaleChanged`): not the follower's.
        TextScaleFollower.exempt(view)
        view.wantsLayer = true
        view.bindLayerBackground(DS.Translucency.under(DS.Color.canvas))
        NotificationCenter.default.addObserver(self, selector: #selector(textScaleChanged), name: DS.Text.scaleDidChangeNotification, object: nil)
        // A checkpoint created, renamed or verified while the stage is on screen shows at once.
        NotificationCenter.default.addObserver(self, selector: #selector(checkpointsChanged), name: AgentSessionStore.checkpointsDidChangeNotification, object: nil)

        buildTopRow()
        buildSummaryCard()
        buildChanges()

        view.addSubview(summaryCard)
        view.addSubview(diffToolbar)
        view.addSubview(rail)
        view.addSubview(queueRail)
        view.addSubview(diffViewer)
        view.addSubview(emptyState)
        let top = summaryCard.topAnchor.constraint(equalTo: view.topAnchor, constant: ChromeHost.rowHeight + DS.Spacing.m)
        cardTop = top
        let width = rail.widthAnchor.constraint(equalToConstant: ReviewFileRail.width)
        railWidth = width
        let leading = diffViewer.leadingAnchor.constraint(equalTo: rail.trailingAnchor, constant: DS.Spacing.m)
        diffLeading = leading
        NSLayoutConstraint.activate([
            top,
            summaryCard.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Self.margin),
            summaryCard.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Self.margin),
            // The card is as tall as it needs, up to about half the stage (the text inside it
            // truncates first).
            summaryCard.heightAnchor.constraint(lessThanOrEqualTo: view.heightAnchor, multiplier: 0.5),

            rail.topAnchor.constraint(equalTo: summaryCard.bottomAnchor, constant: DS.Spacing.xl),
            rail.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Self.margin - DS.Spacing.l),
            width,
            rail.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            queueRail.topAnchor.constraint(equalTo: rail.topAnchor),
            queueRail.leadingAnchor.constraint(equalTo: rail.leadingAnchor),
            queueRail.trailingAnchor.constraint(equalTo: rail.trailingAnchor),
            queueRail.bottomAnchor.constraint(equalTo: rail.bottomAnchor),

            diffToolbar.topAnchor.constraint(equalTo: rail.topAnchor),
            diffToolbar.heightAnchor.constraint(equalToConstant: ReviewFileRail.headerHeight),
            diffToolbar.leadingAnchor.constraint(equalTo: diffViewer.leadingAnchor, constant: DS.Spacing.xs),
            diffToolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Self.margin),

            diffViewer.topAnchor.constraint(equalTo: diffToolbar.bottomAnchor, constant: DS.Spacing.s),
            leading,
            diffViewer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Self.margin),
            diffViewer.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyState.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyState.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
        queueRail.isHidden = true
        queueRail.onSelect = { [weak self] index in self?.selectQueueGroup(index) }
        queueRail.onSelectPath = { [weak self] path in
            guard let self, let file = self.diffViewer.diff.files.firstIndex(where: { $0.path == path }) else { return }
            self.diffViewer.scrollToFile(file)
        }
        for name in [Attribution.didChangeNotification, HookInbox.didChangeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(queueSourcesChanged), name: name, object: nil)
        }
        // Not just `showEmptyState(true)` — `reloadForTrackSwitch` can (and typically does, on
        // a restored window) run before this view ever loads, since it's only added as a child
        // and given a chance to load when the Review segment is first actually clicked.
        refresh()
    }

    private func buildTopRow() {
        titleLabel.font = DS.Text.heading()
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        headerDetail.font = DS.Text.code(11.5, weight: .regular)
        headerDetail.textColor = .secondaryLabelColor
        headerDetail.lineBreakMode = .byTruncatingTail
        headerDetail.setContentCompressionResistancePriority(.init(200), for: .horizontal)

        // ChipButtons on glass capsules, the composer's controls: the capsule is the chrome, and
        // `glassBackdrop` makes button and capsule press as one object.
        promoteButton.onPress = { [weak self] in self?.promoteTapped() }
        promoteButton.settlesOnRelease = true
        publishButton.onPress = { [weak self] in self?.publishTapped() }
        publishButton.settlesOnRelease = true
        publishButton.contentTintColor = .secondaryLabelColor
        publishButton.setAttributedLabel(
            NSAttributedString(string: "Publish\u{2026}", attributes: [.font: DS.Text.body(.medium), .foregroundColor: NSColor.secondaryLabelColor]),
            identity: "publish"
        )
        for (host, button) in [(publishHost, publishButton), (promoteHost, promoteButton)] {
            // Pill-shaped: radius exactly half the height.
            let glass = DS.makeGlass(cornerRadius: Self.promoteHeight / 2)
            button.glassBackdrop = glass
            host.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(glass)
            host.addSubview(button)
            host.setContentCompressionResistancePriority(.required, for: .horizontal)
            NSLayoutConstraint.activate([
                glass.topAnchor.constraint(equalTo: host.topAnchor),
                glass.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                glass.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                glass.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                button.centerYAnchor.constraint(equalTo: host.centerYAnchor),
                button.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: DS.Spacing.xl),
                button.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -DS.Spacing.xl),
                host.heightAnchor.constraint(equalToConstant: Self.promoteHeight),
            ])
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = DS.Spacing.l
        headerRow.setClippingResistancePriority(.defaultLow, for: .horizontal)
        for view in [titleLabel, headerDetail, spacer, publishHost, promoteHost] as [NSView] { headerRow.addArrangedSubview(view) }
        headerRow.setCustomSpacing(DS.Spacing.m, after: publishHost)
    }

    private func buildSummaryCard() {
        summaryCard.translatesAutoresizingMaskIntoConstraints = false
        summaryCard.wantsLayer = true
        summaryCard.bindLayerBackground(DS.Color.raised)
        summaryCard.layer?.cornerRadius = DS.Radius.surface

        accountMeta.font = DS.Text.caption(.medium)
        accountMeta.textColor = .secondaryLabelColor
        accountMore.isBordered = false
        accountMore.target = self
        accountMore.action = #selector(toggleAccount)
        accountMore.setContentHuggingPriority(.required, for: .horizontal)
        let metaSpacer = NSView()
        metaSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        accountRow.orientation = .horizontal
        accountRow.alignment = .firstBaseline
        accountRow.spacing = DS.Spacing.m
        for view in [accountMeta, metaSpacer, accountMore] as [NSView] { accountRow.addArrangedSubview(view) }
        accountText.font = DS.Text.body()
        accountText.textColor = .labelColor
        // Wrapping, with the last visible line truncated: a truncating line break mode would
        // make the field a single line.
        accountText.lineBreakMode = .byWordWrapping
        accountText.cell?.truncatesLastVisibleLine = true
        accountText.maximumNumberOfLines = Self.accountLines
        accountText.isSelectable = true
        accountText.setContentCompressionResistancePriority(.init(250), for: .vertical)

        statusLabel.font = DS.Text.caption()
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 2
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        summaryHairline.boxType = .custom
        summaryHairline.borderType = .noBorder
        summaryHairline.fillColor = DS.Color.hairline
        summaryHairline.translatesAutoresizingMaskIntoConstraints = false
        summaryHairline.heightAnchor.constraint(equalToConstant: 1).isActive = true

        timelineView.translatesAutoresizingMaskIntoConstraints = false
        timelineView.onChange = { [weak self] timeline in self?.rangeChanged(timeline) }
        noCheckpoints.font = DS.Text.caption()
        noCheckpoints.textColor = .tertiaryLabelColor

        rangeLabel.font = DS.Text.body(.semibold)
        rangeLabel.lineBreakMode = .byTruncatingTail
        rangeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        rangeMeta.lineBreakMode = .byTruncatingTail
        rangeMeta.setContentCompressionResistancePriority(.init(240), for: .horizontal)
        copyButton.target = self
        copyButton.action = #selector(copySHATapped)
        undoButton.target = self
        undoButton.action = #selector(undoCheckpointTapped)
        everythingButton.target = self
        everythingButton.action = #selector(showEverythingTapped)
        let rangeSpacer = NSView()
        rangeSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        rangeRow.orientation = .horizontal
        rangeRow.alignment = .firstBaseline
        rangeRow.spacing = DS.Spacing.m
        for view in [rangeLabel, rangeMeta, rangeSpacer, everythingButton, copyButton, undoButton] as [NSView] { rangeRow.addArrangedSubview(view) }
        rangeRow.setCustomSpacing(DS.Spacing.l, after: everythingButton)
        rangeRow.setCustomSpacing(DS.Spacing.l, after: copyButton)

        summaryStack.orientation = .vertical
        summaryStack.alignment = .leading
        summaryStack.spacing = DS.Spacing.s
        summaryStack.edgeInsets = NSEdgeInsets(top: DS.Spacing.xl, left: DS.Spacing.section, bottom: DS.Spacing.s, right: DS.Spacing.section)
        summaryStack.translatesAutoresizingMaskIntoConstraints = false
        // The timeline and what it's showing share a row: the card is a summary, and each line
        // of it is a line less of diff.
        timelineRow.orientation = .horizontal
        timelineRow.alignment = .top
        timelineRow.spacing = DS.Spacing.section
        timelineRow.addArrangedSubview(timelineView)
        timelineRow.addArrangedSubview(rangeRow)
        let width = timelineView.widthAnchor.constraint(equalToConstant: 120)
        timelineWidth = width
        width.isActive = true
        rangeRow.topAnchor.constraint(equalTo: timelineView.topAnchor, constant: 2).isActive = true
        let rows: [NSView] = [accountRow, accountText, verificationLine, overlapLine, statusLabel, summaryHairline, timelineRow, noCheckpoints]
        for row in rows { summaryStack.addArrangedSubview(row) }
        summaryStack.setCustomSpacing(DS.Spacing.xs, after: accountRow)
        summaryStack.setCustomSpacing(DS.Spacing.l, after: accountText)
        summaryStack.setCustomSpacing(DS.Spacing.l, after: statusLabel)
        summaryStack.setCustomSpacing(DS.Spacing.l, after: summaryHairline)
        summaryCard.addSubview(summaryStack)
        NSLayoutConstraint.activate([
            summaryStack.topAnchor.constraint(equalTo: summaryCard.topAnchor),
            summaryStack.leadingAnchor.constraint(equalTo: summaryCard.leadingAnchor),
            summaryStack.trailingAnchor.constraint(equalTo: summaryCard.trailingAnchor),
            summaryStack.bottomAnchor.constraint(equalTo: summaryCard.bottomAnchor),
        ])
        // Full width inside the card: a wrapping label or the timeline otherwise takes only the
        // width its content needs.
        let inset = -DS.Spacing.section * 2
        for row in rows where row !== verificationLine && row !== overlapLine && row !== noCheckpoints {
            row.widthAnchor.constraint(equalTo: summaryStack.widthAnchor, constant: inset).isActive = true
        }
        verificationLine.widthAnchor.constraint(lessThanOrEqualTo: summaryStack.widthAnchor, constant: inset).isActive = true
        overlapLine.widthAnchor.constraint(lessThanOrEqualTo: summaryStack.widthAnchor, constant: inset).isActive = true
        overlapLine.isHidden = true
        statusLabel.isHidden = true
        // One line each; the whole list of shared paths is in the tooltip.
        for line in [verificationLine, overlapLine] {
            line.subviews.compactMap { $0 as? NSTextField }.forEach { $0.lineBreakMode = .byTruncatingTail; $0.maximumNumberOfLines = 1; $0.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        }
    }

    private func buildChanges() {
        diffTitle.font = DS.Text.body(.semibold)
        diffTitle.lineBreakMode = .byTruncatingTail
        diffTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        diffTotals.lineBreakMode = .byTruncatingTail
        diffTotals.setContentCompressionResistancePriority(.init(240), for: .horizontal)
        diffLayoutControl.controlSize = .small
        diffLayoutControl.font = DS.Text.caption()
        diffLayoutControl.selectedSegment = DiffLayout.preferred == .unified ? 0 : 1
        diffLayoutControl.target = self
        diffLayoutControl.action = #selector(diffLayoutChanged)
        diffLayoutControl.setAccessibilityLabel("Diff layout")
        foldAllButton.bezelStyle = .accessoryBarAction
        foldAllButton.controlSize = .small
        foldAllButton.font = DS.Text.caption()
        foldAllButton.target = self
        foldAllButton.action = #selector(foldAllTapped)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        diffToolbar.orientation = .horizontal
        diffToolbar.alignment = .centerY
        diffToolbar.spacing = DS.Spacing.l
        diffToolbar.translatesAutoresizingMaskIntoConstraints = false
        approveAllButton.bezelStyle = .accessoryBarAction
        approveAllButton.controlSize = .small
        approveAllButton.font = DS.Text.caption(.medium)
        approveAllButton.target = self
        approveAllButton.action = #selector(approveAllTapped)
        approveAllButton.isHidden = true
        approveAllButton.setAccessibilityIdentifier("review.approveAll")
        for (button, action, id) in [(commitButton, #selector(commitApprovedTapped), "review.commitApproved"), (discardButton, #selector(discardTapped), "review.discard")] {
            button.bezelStyle = .accessoryBarAction
            button.controlSize = .small
            button.font = DS.Text.caption(.medium)
            button.target = self
            button.action = action
            button.isHidden = true
            button.setAccessibilityIdentifier(id)
        }
        for view in [diffTitle, diffTotals, spacer, discardButton, approveAllButton, commitButton, foldAllButton, diffLayoutControl] as [NSView] { diffToolbar.addArrangedSubview(view) }
        diffViewer.onFoldChange = { [weak self] _, _ in self?.refreshFoldAllButton() }

        rail.onSelect = { [weak self] index in self?.diffViewer.scrollToFile(index) }
        rail.onToggleViewed = { [weak self] index, viewed in self?.setViewed(index, viewed) }
        diffViewer.onTopFileChange = { [weak self] index in self?.rail.follow(index) }
    }

    @objc private func foldAllTapped() {
        diffViewer.setAllFolded(!diffViewer.allFolded)
        refreshFoldAllButton()
    }

    /// "Expand All" once everything is collapsed, "Collapse All" while anything is open.
    func refreshFoldAllButton() {
        let collapse = !diffViewer.allFolded
        foldAllButton.title = collapse ? "Collapse All" : "Expand All"
        foldAllButton.setAccessibilityLabel(collapse ? "Collapse all files" : "Expand all files")
        foldAllButton.isEnabled = !diffViewer.diff.files.isEmpty
    }

    /// Narrow windows give the diff the whole width; the list comes back when there's room.
    override func viewDidLayout() {
        super.viewDidLayout()
        // The empty state hides the list; layout mustn't bring it back.
        let showQueue = view.bounds.width >= Self.railMinimumStageWidth && !queue.groups.isEmpty && emptyState.isHidden
        let showRail = view.bounds.width >= Self.railMinimumStageWidth && (!rail.items.isEmpty || showQueue) && emptyState.isHidden
        rail.isHidden = !showRail || showQueue
        queueRail.isHidden = !showQueue
        let width = showRail ? ReviewFileRail.width : 0
        if railWidth?.constant != width {
            railWidth?.constant = width
            diffLeading?.constant = showRail ? DS.Spacing.m : DS.Spacing.l
        }
    }

    // MARK: - Letting go while away

    /// Review's diff can be most of what Side holds (a 500-file change set is tens of MB of
    /// parsed lines). Away from Review for a while, it goes; coming back loads it again, which
    /// is quick (git's diff and a document of rows), at the file that was on top.
    private static let releaseAfter: TimeInterval = 30
    private var releaseWork: DispatchWorkItem?
    private var releasedAtFile: Int?

    override func viewDidDisappear() {
        super.viewDidDisappear()
        releaseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.view.window == nil, !self.diffViewer.diff.files.isEmpty else { return }
            self.releasedAtFile = self.rail.selectedIndex ?? 0
            self.diffViewer.releaseDocument()
            self.rail.items = []
        }
        releaseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.releaseAfter, execute: work)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        releaseWork?.cancel()
        releaseWork = nil
        if releasedAtFile != nil, currentTrack != nil { loadDiff() }
    }

    // MARK: - The review queue (SIDE_RFC_SESSIONS.md, phase 4)

    /// The checkout Changes is on: its uncommitted changes are the queue's.
    private var queueRoot: URL? { currentWorkingDirectory ?? canonicalRoot }

    @objc private func queueSourcesChanged() {
        guard isViewLoaded, view.window != nil else { return }
        refreshQueue()
    }

    /// Reads the checkout's uncommitted changes and who wrote each hunk, off the main thread.
    private func refreshQueue() {
        guard let root = queueRoot, trackStore != nil else { queueLoading = false; return applyQueue(ReviewQueue()) }
        queueGeneration += 1
        let generation = queueGeneration
        queueLoading = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // git busy (a commit just made, the index locked): the queue as it was, and again soon.
            guard let diff = Self.uncommittedDiff(cwd: root.path) else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self, self.queueGeneration == generation, self.queueRetries < 10 else { return }
                    self.queueRetries += 1
                    self.refreshQueue()
                }
                return
            }
            let queue = ReviewQueue.build(diff: diff) { path in
                let file = root.appendingPathComponent(path)
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
                return Attribution.shared.owners(of: file, text: text)
            }
            // Approvals of hunks that are gone (committed, discarded, rewritten) go too.
            ReviewApprovals.shared.keep(only: Set(queue.groups.flatMap(\.hunks).map(\.key)), in: root)
            DispatchQueue.main.async {
                guard let self, self.queueGeneration == generation else { return }
                self.queueLoading = false
                self.queueRetries = 0
                self.applyQueue(queue)
                // Nothing to queue: the branch's diff, if it came meanwhile.
                if !self.queueActive, let pending = self.pendingBranchDiff { self.showDiff(pending.text, everything: pending.everything) }
                self.pendingBranchDiff = nil
            }
        }
    }

    /// What isn't committed in `cwd`, untracked files included, as one `git diff`; nil when git
    /// couldn't say (the index locked mid-commit), which isn't "nothing".
    nonisolated static func uncommittedDiff(cwd: String) -> String? {
        // No HEAD: a repository with no commits has nothing to compare with; one whose HEAD
        // couldn't be read just now (mid-commit) isn't that.
        guard GitPaths.runGit(["rev-parse", "--verify", "--quiet", "HEAD"], cwd: cwd).success else {
            return GitPaths.runGit(["rev-list", "-n", "1", "--all"], cwd: cwd).output.isEmpty ? "" : nil
        }
        let tracked = GitPaths.runGitRaw(["diff", "--no-color", "--no-ext-diff", "HEAD"], cwd: cwd)
        guard tracked.success else { return nil }
        var diff = tracked.output
        let untracked = GitPaths.runGitRaw(["ls-files", "--others", "--exclude-standard"], cwd: cwd).output.split(separator: "\n").prefix(50)
        for file in untracked {
            diff += GitPaths.runGitRaw(["diff", "--no-color", "--no-index", "--", "/dev/null", String(file)], cwd: cwd).output
        }
        while diff.hasSuffix("\n") { diff.removeLast() }
        return diff
    }

    private func applyQueue(_ next: ReviewQueue) {
        let wasActive = queueActive
        if let root = queueRoot { approvedKeys = ReviewApprovals.shared.approved(in: root) }
        let chosenAuthor = queueSelection.flatMap { queue.groups.indices.contains($0) ? queue.groups[$0].author : nil }
        queue = next
        // The same author stays chosen as the queue changes; else the first.
        if queueSelection != nil {
            queueSelection = chosenAuthor.flatMap { author in next.groups.firstIndex { $0.author == author } } ?? (next.groups.isEmpty ? nil : 0)
            if next.groups.isEmpty { queueSelection = 0 }
        }
        queueRail.items = next.groups.map { group in
            ReviewQueueRail.Item(title: group.title, detail: queueDetail(group), icon: queueIcon(group.author), paths: group.paths)
        }
        queueRail.selected = queueActive ? queueSelection : nil
        view.needsLayout = true
        if queueActive {
            showQueueGroup()
        } else if wasActive {
            // Nothing left to review: the branch as before.
            refreshBranch()
        }
    }

    private func queueIcon(_ author: Author) -> NSImage? {
        switch author.kind {
        case .session: return ProgramMarks.image(forProgram: author.agent)
        case .you: return NSImage(systemSymbolName: "person.fill", accessibilityDescription: nil)
        case .shared: return NSImage(systemSymbolName: "person.2.fill", accessibilityDescription: nil)
        case .unknown: return NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: nil)
        }
    }

    /// "Finished · +12 −3 · 2 files": the session's state when the hooks know it, its size.
    private func queueDetail(_ group: ReviewQueue.Group) -> String {
        var parts: [String] = []
        if group.author.kind == .session, let id = group.author.sessionID, let session = HookInbox.shared.sessions.sessions[id] {
            parts.append(session.state.word)
        } else if group.author.kind == .session {
            parts.append(group.author.name)
        }
        let approved = group.hunks.filter { approvedKeys.contains($0.key) }.count
        if approved == group.hunks.count {
            parts.append("Approved")
        } else {
            parts.append("+\(group.added) \u{2212}\(group.removed)")
            parts.append(approved > 0 ? "\(approved) of \(group.hunks.count) approved" : "\(group.paths.count) file\(group.paths.count == 1 ? "" : "s")")
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    private func selectQueueGroup(_ index: Int?) {
        queueSelection = index
        view.needsLayout = true
        if queueActive { showQueueGroup() } else { refreshBranch() }
    }

    /// The chosen group's hunks, as a diff of their own.
    private func showQueueGroup() {
        guard let index = queueSelection, queue.groups.indices.contains(index) else { return }
        let group = queue.groups[index]
        // Laid out first: the list taking the files' place can change the diff's width, and
        // a diff drawn before that had its numbers rows below its lines.
        view.layoutSubtreeIfNeeded()
        shownHunks = group.paths.map { path in group.hunks.filter { $0.path == path } }
        diffViewer.render(diffText: group.diffText, emptyMessage: "No changes.")
        diffViewer.hunkApproval = { [weak self] file, hunk in
            guard let self, self.shownHunks.indices.contains(file), self.shownHunks[file].indices.contains(hunk) else { return nil }
            return self.approvedKeys.contains(self.shownHunks[file][hunk].key)
        }
        diffViewer.onToggleHunkApproval = { [weak self] file, hunk, approved in
            guard let self, self.shownHunks.indices.contains(file), self.shownHunks[file].indices.contains(hunk) else { return }
            self.setApproved([self.shownHunks[file][hunk]], approved)
        }
        refreshApproveAll()
        diffTitle.stringValue = group.title
        let totals = NSMutableAttributedString(string: "\(group.paths.count) file\(group.paths.count == 1 ? "" : "s")  ", attributes: [.font: DS.Text.caption(), .foregroundColor: NSColor.secondaryLabelColor])
        totals.append(NSAttributedString(string: "+\(group.added)", attributes: [.font: DS.Text.code(11, weight: .medium), .foregroundColor: DiffBody.addedText]))
        totals.append(NSAttributedString(string: " \u{2212}\(group.removed)", attributes: [.font: DS.Text.code(11, weight: .medium), .foregroundColor: DiffBody.removedText]))
        diffTotals.attributedStringValue = totals
        refreshFoldAllButton()
    }

    private func setApproved(_ hunks: [ReviewQueue.Hunk], _ approved: Bool) {
        guard let root = queueRoot else { return }
        let keys = hunks.map(\.key)
        ReviewApprovals.shared.set(keys, approved: approved, in: root)
        if approved { approvedKeys.formUnion(keys) } else { approvedKeys.subtract(keys) }
        diffViewer.refreshHunkControls()
        refreshApproveAll()
        queueRail.items = queue.groups.map { group in
            ReviewQueueRail.Item(title: group.title, detail: queueDetail(group), icon: queueIcon(group.author), paths: group.paths)
        }
    }

    /// Approve All, or, with everything approved, Unapprove All.
    private func refreshApproveAll() {
        guard queueActive, let index = queueSelection, queue.groups.indices.contains(index) else {
            for button in [approveAllButton, commitButton, discardButton] { button.isHidden = true }
            return
        }
        let hunks = queue.groups[index].hunks
        let approved = hunks.filter { approvedKeys.contains($0.key) }.count
        approveAllButton.title = approved == hunks.count ? "Unapprove All" : "Approve All"
        approveAllButton.isHidden = false
        // Commit what's approved; Discard what isn't wanted (what isn't approved, or all of it).
        commitButton.isHidden = approved == 0
        commitButton.title = approved == hunks.count ? "Commit\u{2026}" : "Commit \(approved) Approved\u{2026}"
        discardButton.isHidden = false
    }

    private var chosenGroup: ReviewQueue.Group? {
        queueSelection.flatMap { queue.groups.indices.contains($0) ? queue.groups[$0] : nil }
    }

    /// The approved hunks, committed with a message drafted from the request.
    @objc private func commitApprovedTapped() {
        guard let group = chosenGroup, let root = queueRoot, let window = view.window else { return }
        let hunks = group.hunks.filter { approvedKeys.contains($0.key) }
        guard !hunks.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = hunks.count == group.hunks.count ? "Commit these changes?" : "Commit the \(hunks.count) approved changes?"
        alert.informativeText = "To \(baseBranchShown ?? currentTrack?.branchName ?? "this branch"). Only what you approved is committed; the rest stays as it is."
        let field = NSTextField(string: ReviewGit.draftMessage(for: group))
        field.placeholderString = "Commit message"
        field.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Commit")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let message = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty else { self?.reportQueueFailure("A commit needs a message."); return }
            self?.runQueueAction { ReviewGit.commit(hunks, message: message, cwd: root.path).map { _ in () } }
        }
    }

    /// The session's changes taken out of the files, once you say so; refused where someone
    /// else's later lines are inside them.
    @objc private func discardTapped() {
        guard let group = chosenGroup, let root = queueRoot, let window = view.window else { return }
        let unapproved = group.hunks.filter { !approvedKeys.contains($0.key) }
        let hunks = unapproved.isEmpty ? group.hunks : unapproved
        let files = Set(hunks.map(\.path)).count
        let alert = NSAlert()
        alert.alertStyle = .warning
        let whose = group.author.kind == .session ? "\(group.author.name)\u{2019}s" : group.author.kind == .you ? "your" : "these"
        alert.messageText = unapproved.isEmpty || unapproved.count == group.hunks.count
            ? "Discard \(whose) changes to \(files) file\(files == 1 ? "" : "s")?"
            : "Discard the \(hunks.count) changes you haven\u{2019}t approved?"
        alert.informativeText = "They\u{2019}re taken out of the files, as if never written. This can\u{2019}t be undone from Side."
        alert.addButton(withTitle: "Discard")
        alert.buttons.first?.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.runQueueAction {
                ReviewGit.discard(hunks, author: group.author, owners: { path in
                    let file = root.appendingPathComponent(path)
                    guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
                    return Attribution.shared.owners(of: file, text: text)
                }, cwd: root.path)
            }
        }
    }

    /// Off the main thread; then the queue again, or what stopped it.
    private func runQueueAction(_ action: @escaping @Sendable () -> Result<Void, ReviewGit.Failure>) {
        setStatus("Working\u{2026}")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = action()
            DispatchQueue.main.async {
                guard let self else { return }
                self.setStatus("")
                if case .failure(let failure) = result { self.reportQueueFailure(failure.message) } else { self.lastQueueFailure = nil }
                self.refreshQueue()
                // And once git has finished with what it just did (its index, its hooks).
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refreshQueue() }
            }
        }
    }

    private func reportQueueFailure(_ message: String) {
        lastQueueFailure = message
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "That wasn\u{2019}t done"
        alert.informativeText = message
        alert.beginSheetModal(for: window)
    }
    private(set) var lastQueueFailure: String?

    /// Testing: the actions without their sheets.
    func commitApprovedForTesting(message: String) {
        guard let group = chosenGroup, let root = queueRoot else { return }
        let hunks = group.hunks.filter { approvedKeys.contains($0.key) }
        guard !hunks.isEmpty else { lastQueueFailure = "nothing approved"; return }
        runQueueAction { ReviewGit.commit(hunks, message: message, cwd: root.path).map { _ in () } }
    }
    func discardForTesting() {
        guard let group = chosenGroup, let root = queueRoot else { return }
        runQueueAction {
            ReviewGit.discard(group.hunks, author: group.author, owners: { path in
                let file = root.appendingPathComponent(path)
                return (try? String(contentsOf: file, encoding: .utf8)).map { Attribution.shared.owners(of: file, text: $0) } ?? []
            }, cwd: root.path)
        }
    }

    @objc private func approveAllTapped() {
        guard let index = queueSelection, queue.groups.indices.contains(index) else { return }
        let hunks = queue.groups[index].hunks
        setApproved(hunks, !hunks.allSatisfy { approvedKeys.contains($0.key) })
    }

    var approvalsForTesting: String { diffViewer.hunkControlsForTesting.joined(separator: " ") + " | " + approveAllButton.title }
    func toggleHunkForTesting(file: Int, hunk: Int) { diffViewer.toggleHunkForTesting(file: file, hunk: hunk) }
    func approveAllForTesting() { approveAllTapped() }
    var queueActionsForTesting: String {
        [commitButton, approveAllButton, discardButton].filter { !$0.isHidden }.map(\.title).joined(separator: ", ") + (lastQueueFailure.map { " | failed: \($0)" } ?? "")
    }

    /// The whole branch, as Changes showed it before the queue.
    private func refreshBranch() {
        diffViewer.hunkApproval = nil
        for button in [approveAllButton, commitButton, discardButton] { button.isHidden = true }
        if currentTrack != nil {
            loadDiff()
        } else if let root = queueRoot, let trackStore {
            refreshBase(root: root, hasTracks: trackStore.tracks.contains { $0.status != .archived })
        }
    }

    var queueForTesting: [String] { queueRail.items.map { "\($0.title) | \($0.detail) | \($0.paths.joined(separator: ","))" } }
    func selectQueueForTesting(_ index: Int?) { queueRail.selected = index; selectQueueGroup(index) }

    // MARK: - Wiring

    func configure(trackStore: TrackStore, sessionStore: AgentSessionStore, canonicalRoot: URL) {
        // Another project: nothing of the last one's diff, list or timeline carries over, even
        // when the two have a track of the same name.
        if self.canonicalRoot != nil, self.canonicalRoot != canonicalRoot {
            currentTrack = nil
            timeline = CheckpointTimeline(nodes: [])
            accountExpanded = false
            releasedAtFile = nil
            clearDiff()
        }
        self.trackStore = trackStore
        self.sessionStore = sessionStore
        self.canonicalRoot = canonicalRoot
    }

    func reloadForTrackSwitch(trackKey: String?, workingDirectory: URL) {
        currentWorkingDirectory = workingDirectory
        let next = trackKey.flatMap { key in trackStore?.tracks.first { $0.branchName == key } }
        if next?.branchName != currentTrack?.branchName {
            timeline = CheckpointTimeline(nodes: [])
            accountExpanded = false
            clearDiff()
        }
        currentTrack = next
        refresh()
    }

    // MARK: - Rendering

    /// `message` overrides the default copy — the empty state has to say *which* thing is
    /// missing (no project, no repo, no track), since the remedy differs for each.
    private func showEmptyState(_ empty: Bool, message: String? = nil, action: (title: String, kind: EmptyStateAction)? = nil) {
        if empty {
            clearDiff()
            emptyState.configure(message ?? Self.defaultEmptyStateText, action: action?.title, handler: action.map { action in { [weak self] in self?.onEmptyStateAction?(action.kind) } })
        }
        emptyState.isHidden = !empty
        for view in [summaryCard, diffToolbar, rail, diffViewer] as [NSView] { view.isHidden = empty }
        // No track means no title, branch or actions to show; empty chips read as broken.
        headerRow.isHidden = empty
        if !empty { view.needsLayout = true }
    }

    /// Drops the shown diff and its file list, and any diff or refresh still on its way.
    private func clearDiff() {
        diffGeneration += 1
        refreshGeneration += 1
        rail.items = []
        if !diffViewer.diff.files.isEmpty { diffViewer.releaseDocument() }
        diffTotals.attributedStringValue = NSAttributedString()
    }

    private var refreshGeneration = 0

    private static let defaultEmptyStateText = "Changes shows what a track has changed."
    private static let promoteHeight: CGFloat = 26
    private static let margin: CGFloat = 16
    private static let accountLines = 3
    private static let accountExpandedLines = 14
    /// Below this the file list gives its width to the diff.
    private static let railMinimumStageWidth: CGFloat = 820

    /// A borderless NSButton draws its title in the default label colour and ignores
    /// `contentTintColor`, so the accent has to come from an attributed title — same reason the
    /// changes pill sets one. Re-applied on enablement changes because an attributed title also
    /// opts out of AppKit's automatic dimming.
    private var promoteTitleText = "Promote"

    private func setPromoteTitle(_ text: String) {
        promoteTitleText = text
        applyPromoteTitle()
    }

    private func setPromoteEnabled(_ enabled: Bool) {
        promoteButton.isEnabled = enabled
        applyPromoteTitle()
    }

    private func applyPromoteTitle() {
        let color: NSColor = promoteButton.isEnabled ? DS.Color.accent : .tertiaryLabelColor
        // Both, and both are needed: a borderless NSButton tints its title with
        // `contentTintColor` on top of whatever an attributed title asks for.
        promoteButton.contentTintColor = color
        promoteButton.setAttributedLabel(
            NSAttributedString(string: promoteTitleText, attributes: [.font: DS.Text.body(.semibold), .foregroundColor: color]),
            identity: "\(promoteTitleText)|\(promoteButton.isEnabled)"
        )
    }

    @objc private func textScaleChanged() { refresh() }

    @objc private func diffLayoutChanged() {
        DiffLayout.preferred = diffLayoutControl.selectedSegment == 0 ? .unified : .sideBySide
        diffViewer.diffLayout = DiffLayout.preferred
    }

    /// A checkpoint was created, renamed, or verified while this stage was on screen.
    @objc private func checkpointsChanged() {
        guard isViewLoaded, view.window != nil else { return }
        refresh()
    }

    @objc private func toggleAccount() {
        accountExpanded.toggle()
        applyAccountExpansion()
    }

    private func applyAccountExpansion() {
        accountText.maximumNumberOfLines = accountExpanded ? Self.accountExpandedLines : Self.accountLines
        // Collapsed, the paragraphs run together so three lines hold three lines of words, not
        // a sentence and two blank lines.
        accountText.stringValue = accountExpanded ? accountFull : accountFull.split(separator: "\n").joined(separator: " ")
        accountMore.attributedTitle = NSAttributedString(string: accountExpanded ? "Show less" : "Show more", attributes: [.font: DS.Text.caption(.medium), .foregroundColor: NSColor.secondaryLabelColor])
        accountMore.isHidden = !accountTextIsLong
        view.needsLayout = true
    }

    private var accountTextIsLong = false
    private var accountFull = ""

    private func refresh() {
        guard isViewLoaded else { return }
        refreshQueue()
        // Review never consulted repoState, so a plain folder got "Switch to a track to review
        // its work" — advice the user cannot follow, since tracks require a repo.
        if trackStore == nil {
            showEmptyState(true, message: "Open a project to review its work.", action: ("Open Project…", .openProject))
            return
        }
        if let repository = trackStore?.soleRepositoryInside {
            showEmptyState(true, message: "Changes works from commits. This folder isn\u{2019}t a repository, but \u{201C}\(repository.lastPathComponent)\u{201D} inside it is.",
                           action: ("Open \u{201C}\(repository.lastPathComponent)\u{201D}", .openRepositoryInside))
            return
        }
        if trackStore?.repoState == .notAGitRepo {
            if !DeveloperTools.gitInstalled {
                showEmptyState(true, message: "Changes works from commits. \(DeveloperTools.missingMessage)", action: ("Install Git…", .initializeGit))
            } else {
                showEmptyState(true, message: "Changes works from commits, and this project isn't a git repository yet.", action: ("Initialize Git…", .initializeGit))
            }
            return
        }
        guard let track = currentTrack, let trackStore else {
            // On the base itself, with no track: its own work (every branch has something to
            // show in Changes, SIDE_RFC_GIT_TRACKS.md).
            if let trackStore, let root = currentWorkingDirectory ?? canonicalRoot {
                refreshBase(root: root, hasTracks: trackStore.tracks.contains { $0.status != .archived })
                return
            }
            showEmptyState(true, message: Self.defaultEmptyStateText, action: ("New Track", .newTrack))
            return
        }
        setBaseMode(nil)
        showEmptyState(false)
        setStatus("")

        currentBaseRef = Self.baseRef(for: track, trackStore: trackStore)
        let baseRef = currentBaseRef
        titleLabel.stringValue = track.intent.isEmpty ? track.branchName : track.intent
        headerDetail.stringValue = "\(track.branchName) \u{2192} \(baseRef)"
        setPromoteTitle("Promote to \(baseRef)\u{2026}")
        setPromoteEnabled(false)

        allCheckpoints = (sessionStore?.checkpoints(forTrackKey: track.branchName) ?? []).sorted { $0.createdAt > $1.createdAt }
        // Verification recency, stated before anyone reaches for Promote (§4.2, audit H14).
        if let summary = Self.verificationSummary(checkpoints: allCheckpoints) {
            verificationLine.set(state: summary.state, text: summary.text)
            verificationLine.isHidden = false
        } else {
            verificationLine.isHidden = true
        }

        guard let canonicalRoot else { return }
        let cwd = canonicalRoot.path
        let branchName = track.branchName
        // Every other track's base, resolved on the main thread — `trackStore` isn't safe to
        // read from the background, and this is a handful of dictionary lookups.
        let siblingTracks = trackStore.tracks.filter {
            $0.branchName != branchName && $0.status != .archived && $0.status != .completed
        }
        let baseRefsByBranch = Dictionary(uniqueKeysWithValues: siblingTracks.map { ($0.branchName, Self.baseRef(for: $0, trackStore: trackStore)) })
        let intentsByBranch = Dictionary(uniqueKeysWithValues: siblingTracks.map { ($0.branchName, $0.intent) })
        let chronological = Array(allCheckpoints.reversed().enumerated()).map { (checkpoint: $0.element, number: $0.offset + 1) }
        // Where Promote would merge, and whether it can: resolved here (main-actor state), and
        // checked for a dirty base off-main, so a disabled Promote says why before the click.
        let target = mergeTarget(for: track, trackStore: trackStore)
        let previous = timeline
        refreshGeneration += 1
        let generation = refreshGeneration

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // One spawn: every commit on the branch not yet in its base; checkpoints are ahead
            // when their commit is among them, and only those are on the timeline.
            let aheadList = GitPaths.runGit(["rev-list", "\(baseRef)..\(branchName)"], cwd: cwd)
            let aheadSHAs = aheadList.success ? aheadList.output.split(separator: "\n").map(String.init) : []
            func ahead(_ sha: String) -> Bool { aheadSHAs.contains { $0.hasPrefix(sha) || sha.hasPrefix($0) } }
            let onBranch = chronological.filter { $0.checkpoint.gitCommitSHA.map(ahead) ?? false }
            var built = CheckpointTimeline.build(baseRef: baseRef, branch: branchName, checkpoints: onBranch, tipSHA: aheadSHAs.first)
            built.keepSelection(of: previous)
            let blockedReason: String? = {
                guard let target else { return "\u{201C}\(baseRef)\u{201D}\u{2019}s working copy has been removed. Resume it in Bracks to promote into it." }
                let name = target.isParent ? "\u{201C}\(baseRef)\u{201D}" : "Your main working copy"
                // A status git couldn't read is not a clean tree (audit GIT-11).
                guard let dirty = GitPaths.dirtyPaths(cwd: target.root.path) else { return "git couldn\u{2019}t read the status of \(name), so Side can\u{2019}t tell whether it has uncommitted changes." }
                return dirty.isEmpty ? nil : "\(name) has uncommitted changes. Commit or stash them first."
            }()
            let hasChanges = !aheadSHAs.isEmpty || !GitDiffComputer.refDiff(fromRef: baseRef, toRef: branchName, cwd: cwd, contextLines: 0).isEmpty
            // One `git diff --name-only` per track — cheap, and it costs the model nothing:
            // this is awareness for the human, not context for the agent.
            var changedPathsByBranch = [branchName: TrackOverlap.changedPaths(branch: branchName, baseRef: baseRef, cwd: cwd)]
            for (branch, base) in baseRefsByBranch {
                changedPathsByBranch[branch] = TrackOverlap.changedPaths(branch: branch, baseRef: base, cwd: cwd)
            }
            let siblings = TrackOverlap.siblings(of: branchName, changedPathsByBranch: changedPathsByBranch, intentsByBranch: intentsByBranch)
            DispatchQueue.main.async {
                guard let self, self.refreshGeneration == generation, self.currentTrack?.branchName == branchName else { return }
                let ahead = built.nodes.filter { if case .checkpoint = $0.kind { return true } else { return false } }.count
                self.headerDetail.stringValue = "\(branchName) \u{2192} \(baseRef) \u{00B7} \(ahead) checkpoint\(ahead == 1 ? "" : "s") ahead"
                self.setPromoteEnabled(hasChanges && blockedReason == nil)
                if let blockedReason, hasChanges { self.setStatus(blockedReason) }
                if let headline = TrackOverlap.headline(for: siblings) {
                    let paths = TrackOverlap.sharedPathsSummary(for: siblings)
                    self.overlapLine.set(state: .needsYou, text: "\(headline). \(paths)")
                    self.overlapLine.toolTip = paths
                    self.overlapLine.isHidden = false
                } else {
                    self.overlapLine.isHidden = true
                }
                self.showTimeline(built)
            }
        }
    }

    /// What the agent said about the checkpoint the range ends at (the newest, unless one is
    /// chosen): its own account of that work, a few lines of it, the rest behind Show more. It's
    /// there to read; nothing in the card asks for an answer. A checkpoint with no account hides it.
    private func showAccount(for checkpoint: Checkpoint?, number: Int?) {
        let account = checkpoint.flatMap { sessionStore?.agentAccount(for: $0) }
        let text = account.map { Self.plainText(fromMarkdown: $0.text) } ?? ""
        accountRow.isHidden = text.isEmpty
        accountText.isHidden = text.isEmpty
        guard let account, let checkpoint, !text.isEmpty else { return }
        let who = account.agentId.flatMap { ACPAgent.agent(id: $0)?.displayName }
            ?? (checkpoint.provenance.modelId.isEmpty ? "The agent" : checkpoint.provenance.modelId)
        accountMeta.stringValue = "\(who), about checkpoint \(number.map(String.init) ?? "") \u{00B7} \(Self.relativeTime(account.at))"
        accountFull = text
        accountTextIsLong = text.count > 280 || text.filter { $0 == "\n" }.count >= Self.accountLines
        applyAccountExpansion()
    }

    /// An agent's Markdown as the words it says: emphasis and code marks dropped, headings and
    /// list markers kept as plain lines. The card is a summary, not a rendering.
    static func plainText(fromMarkdown markdown: String) -> String {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        // Code fences go; the code inside stays, as lines.
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.hasPrefix("```") }.map { line -> String in
            var line = String(line)
            while line.hasPrefix("#") { line.removeFirst() }
            let text = (try? AttributedString(markdown: line.trimmingCharacters(in: .whitespaces), options: options)).map { String($0.characters) } ?? line
            return text
        }
        var result: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty, result.last?.isEmpty ?? true { continue }
            result.append(trimmed)
        }
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func showTimeline(_ built: CheckpointTimeline) {
        let changed = built != timeline || diffViewer.diff.files.isEmpty
        timeline = built
        let hasCheckpoints = built.nodes.count > 2 || built.nodes.contains { if case .checkpoint = $0.kind { return true } else { return false } }
        timelineRow.isHidden = !hasCheckpoints
        noCheckpoints.isHidden = hasCheckpoints || !allCheckpoints.isEmpty
        summaryStack.setCustomSpacing(hasCheckpoints || !noCheckpoints.isHidden ? DS.Spacing.l : 0, after: summaryHairline)
        summaryHairline.isHidden = !hasCheckpoints && noCheckpoints.isHidden
        // As wide as its nodes want, up to a third of the card; the label takes the rest.
        timelineWidth?.constant = min(CGFloat(built.nodes.count - 1) * 56 + 40, max(160, summaryCard.bounds.width / 3))
        timelineView.timeline = built
        updateRangeRow()
        if changed { loadDiff() }
    }

    private func rangeChanged(_ next: CheckpointTimeline) {
        timeline = next
        updateRangeRow()
        loadDiff()
    }

    @objc private func showEverythingTapped() {
        var next = timeline
        next.selectEverything()
        timelineView.timeline = next
        rangeChanged(next)
    }

    private var selectedCheckpoint: Checkpoint? {
        guard let node = timeline.single, case .checkpoint(let id, _) = node.kind else { return nil }
        return allCheckpoints.first { $0.id == id }
    }

    /// "All changes", "3 · Add a login form" with its details, or "Checkpoints 2 to 4".
    private func updateRangeRow() {
        // The account of the range's last checkpoint.
        let end = timeline.nodes.indices.contains(timeline.hi) ? timeline.nodes[timeline.hi] : nil
        let last = timeline.nodes.last { if case .checkpoint = $0.kind { return true } else { return false } }
        if case .checkpoint(let id, let number)? = (end?.kind == .now ? last?.kind : end?.kind) {
            showAccount(for: allCheckpoints.first { $0.id == id }, number: number)
        } else {
            showAccount(for: nil, number: nil)
        }
        let checkpoint = selectedCheckpoint
        copyButton.isHidden = checkpoint?.gitCommitSHA == nil
        undoButton.isHidden = checkpoint?.gitCommitSHA == nil
        everythingButton.isHidden = timeline.isEverything || timeline.nodes.count < 2
        rangeRow.isHidden = timelineRow.isHidden
        if let checkpoint, case .checkpoint(_, let number)? = timeline.single?.kind {
            rangeLabel.stringValue = "\(number) \u{00B7} \(checkpoint.declaredIntent.isEmpty ? "No description" : checkpoint.declaredIntent)"
            rangeMeta.attributedStringValue = Self.checkpointMeta(checkpoint)
            rangeMeta.toolTip = checkpoint.verification.flatMap { $0.passed ? nil : $0.outputExcerpt }
        } else {
            rangeLabel.stringValue = CheckpointTimelineView.describe(timeline)
            let count = timeline.nodes.filter { if case .checkpoint = $0.kind { return true } else { return false } }.count
            rangeMeta.attributedStringValue = NSAttributedString(
                string: timeline.isEverything ? "\(count) checkpoint\(count == 1 ? "" : "s") ahead of \(currentBaseRef)" : "",
                attributes: [.font: DS.Text.caption(), .foregroundColor: NSColor.secondaryLabelColor]
            )
            rangeMeta.toolTip = nil
        }
        if !queueActive { diffTitle.stringValue = timeline.isEverything || timeline.nodes.count < 2 ? "Changes vs \(currentBaseRef)" : CheckpointTimelineView.describe(timeline) }
    }

    /// The diff for the range: base to tip by default, or between two checkpoints.
    private func loadDiff() {
        guard let track = currentTrack, let canonicalRoot else { return }
        diffGeneration += 1
        let generation = diffGeneration
        let refs = timeline.nodes.count > 1 ? timeline.refs : (currentBaseRef, track.branchName)
        let everything = timeline.isEverything || timeline.nodes.count < 2
        let branchName = track.branchName
        let cwd = canonicalRoot.path
        if diffViewer.diff.files.isEmpty { diffViewer.renderLoading() }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let text = GitDiffComputer.refDiff(fromRef: refs.0, toRef: refs.1, cwd: cwd)
            DispatchQueue.main.async {
                guard let self, self.diffGeneration == generation, self.currentTrack?.branchName == branchName else { return }
                self.showDiff(text, everything: everything)
            }
        }
    }

    /// A file to show once the diff lists it: the Agent panel's "Changes" on a file.
    private var pendingRevealPath: String?

    func revealFile(path: String) {
        if let file = diffViewer.diff.files.firstIndex(where: { $0.path == path }) {
            diffViewer.scrollToFile(file)
            rail.follow(file)
        } else {
            pendingRevealPath = path
        }
    }

    private func showDiff(_ text: String, everything: Bool) {
        // The queue is showing one group's changes: the branch's diff waits for "Whole branch".
        guard !queueActive else { return }
        if queueLoading, queueSelection != nil { pendingBranchDiff = (text, everything); return }
        guard let trackKey = viewedKey else { return }
        let store = viewedStore
        diffViewer.render(diffText: text, emptyMessage: baseBranchShown != nil ? "No changes." : everything ? "No changes against \(currentBaseRef)." : "No changes in this range.") { diff in
            Set(diff.files.indices.filter { store.isViewed(diff.files[$0], track: trackKey) })
        }
        let files = diffViewer.diff.files
        rail.items = files.map { file in
            ReviewFileRail.Item(path: file.path, added: file.addedCount, removed: file.removedCount,
                                isNew: file.isNew, isDeleted: file.isDeleted, viewed: store.isViewed(file, track: trackKey))
        }
        let added = files.reduce(0) { $0 + $1.addedCount }, removed = files.reduce(0) { $0 + $1.removedCount }
        let totals = NSMutableAttributedString(string: "\(files.count) file\(files.count == 1 ? "" : "s")  ", attributes: [.font: DS.Text.caption(), .foregroundColor: NSColor.secondaryLabelColor])
        totals.append(NSAttributedString(string: "+\(added)", attributes: [.font: DS.Text.code(11, weight: .medium), .foregroundColor: DiffBody.addedText]))
        totals.append(NSAttributedString(string: " \u{2212}\(removed)", attributes: [.font: DS.Text.code(11, weight: .medium), .foregroundColor: DiffBody.removedText]))
        diffTotals.attributedStringValue = files.isEmpty ? NSAttributedString() : totals
        diffTotals.setAccessibilityLabel("\(files.count) files, \(added) lines added, \(removed) removed")
        refreshFoldAllButton()
        view.needsLayout = true
        if let path = pendingRevealPath, let file = files.firstIndex(where: { $0.path == path }) {
            pendingRevealPath = nil
            releasedAtFile = nil
            diffViewer.scrollToFile(file)
            rail.follow(file)
            return
        }
        if let file = releasedAtFile, files.indices.contains(file) {
            diffViewer.scrollToFile(file)
            rail.follow(file)
        } else if let first = files.indices.first {
            rail.follow(first)
        }
        releasedAtFile = nil
    }

    /// A check flipped in the list: remember it, and fold (or open) the file in the diff.
    private func setViewed(_ index: Int, _ viewed: Bool) {
        guard let key = viewedKey, diffViewer.diff.files.indices.contains(index), rail.items.indices.contains(index) else { return }
        viewedStore.set(viewed, diffViewer.diff.files[index], track: key)
        rail.items[index].viewed = viewed
        diffViewer.setFolded(index, viewed)
        refreshFoldAllButton()
    }

    /// `model · time · +a −r · N files · N commands · <verification word>` — the word coloured
    /// only when it's a result (verified or failed); unverified stays in the caption's grey.
    static func checkpointMeta(_ checkpoint: Checkpoint) -> NSAttributedString {
        let base: [NSAttributedString.Key: Any] = [.font: DS.Text.caption(), .foregroundColor: NSColor.secondaryLabelColor]
        var parts: [NSAttributedString] = []
        func plain(_ text: String) { parts.append(NSAttributedString(string: text, attributes: base)) }
        if !checkpoint.provenance.modelId.isEmpty { plain(checkpoint.provenance.modelId) }
        plain(relativeTime(checkpoint.createdAt))
        if !checkpoint.fileChanges.isEmpty {
            let added = checkpoint.fileChanges.reduce(0) { $0 + $1.added }
            let removed = checkpoint.fileChanges.reduce(0) { $0 + $1.removed }
            let delta = NSMutableAttributedString(string: "+\(added)", attributes: base.merging([.foregroundColor: DS.Color.statusVerified]) { $1 })
            delta.append(NSAttributedString(string: " \u{2212}\(removed)", attributes: base.merging([.foregroundColor: DS.Color.statusFailed]) { $1 }))
            parts.append(delta)
        }
        if !checkpoint.changedFilePaths.isEmpty {
            plain("\(checkpoint.changedFilePaths.count) file\(checkpoint.changedFilePaths.count == 1 ? "" : "s")")
        }
        if !checkpoint.commandsRun.isEmpty {
            plain("\(checkpoint.commandsRun.count) command\(checkpoint.commandsRun.count == 1 ? "" : "s")")
        }
        switch checkpoint.verification {
        case .none: plain("unverified")
        case .some(let v) where v.passed:
            parts.append(NSAttributedString(string: "verified", attributes: base.merging([.foregroundColor: DS.Color.statusVerified]) { $1 }))
        case .some(let v):
            parts.append(NSAttributedString(string: v.exitCode.map { "failed (exit \($0))" } ?? "failed", attributes: base.merging([.foregroundColor: DS.Color.statusFailed]) { $1 }))
        }
        let result = NSMutableAttributedString()
        for (index, part) in parts.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: " \u{00B7} ", attributes: base)) }
            result.append(part)
        }
        return result
    }

    private static func textAction(_ title: String) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.isBordered = false
        button.attributedTitle = NSAttributedString(string: title, attributes: [.font: DS.Text.caption(.medium), .foregroundColor: NSColor.labelColor])
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    @objc private func copySHATapped() {
        guard let sha = selectedCheckpoint?.gitCommitSHA, !sha.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sha, forType: .string)
        setStatus("Copied \(sha.prefix(7)).")
    }

    /// The decision header's verification line (§4.2) — time, and where the newest result sits
    /// relative to the newest checkpoint, for the four cases. `nil` with no checkpoints: there
    /// is nothing yet that could have been verified.
    static func verificationSummary(checkpoints: [Checkpoint], now: Date = Date()) -> (state: DS.StatusState, text: String)? {
        let newestFirst = checkpoints.sorted { $0.createdAt > $1.createdAt }
        guard !newestFirst.isEmpty else { return nil }
        guard let index = newestFirst.firstIndex(where: { $0.verification != nil }),
              let verification = newestFirst[index].verification else { return (.idle, "Unverified") }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        let when = formatter.localizedString(for: verification.ranAt, relativeTo: now)
        guard verification.passed else {
            let how = verification.exitCode.map { "exit \($0)" } ?? "no exit status"
            return (.failed, "Failed \u{00B7} \(verification.taskName) \(how), \(when)")
        }
        guard index > 0 else {
            return (.verified, "Verified \u{00B7} \(verification.taskName) passed \(when), after the latest checkpoint")
        }
        let plural = index == 1 ? "" : "s"
        return (.idle, "Verified \(index) checkpoint\(plural) ago \u{00B7} \(index) unverified since")
    }

    /// "Verified, but not the newest changes." A pass on checkpoint N said nothing about N+1…N+3,
    /// yet the dialog treated the most recent pass as current. `ranAt` was stored and never
    /// compared. (2026-09-01 audit, H14c.) `nil` when the newest checkpoint is itself verified, or
    /// when nothing is verified at all — those cases have their own wording.
    static func verificationStalenessCaveat(checkpoints: [Checkpoint]) -> String? {
        let newestFirst = checkpoints.sorted { $0.createdAt > $1.createdAt }
        guard let newest = newestFirst.first, newest.verification == nil,
              let verifiedIndex = newestFirst.firstIndex(where: { $0.verification?.passed == true }) else { return nil }
        let behind = verifiedIndex
        return "The last passing verification was \(behind) checkpoint\(behind == 1 ? "" : "s") ago. The newest changes have not been verified."
    }

    // MARK: - Undo

    /// Reverses a checkpoint's changes — as a *new commit*, never by rewriting history. See
    /// `CheckpointRestore` for why that's the only defensible choice here.
    @objc private func undoCheckpointTapped() {
        guard let target = selectedCheckpoint,
              let track = currentTrack,
              let checkpoints = sessionStore?.checkpoints(forTrackKey: track.branchName),
              let worktreePath = track.workingDirectoryPath ?? canonicalRoot?.path,
              let window = view.window else { return }
        CheckpointUndo.present(target: target, checkpoints: checkpoints, worktreePath: worktreePath, window: window) { [weak self] message, color, changed in
            self?.setStatus(message, color)
            if changed { self?.refresh() }
        }
    }

    // MARK: Tests

    var railForTesting: ReviewFileRail { rail }
    var diffForTesting: DiffDocumentView { diffViewer }
    var timelineForTesting: CheckpointTimelineView { timelineView }
    var summaryTextForTesting: String? { accountText.isHidden ? nil : accountText.stringValue }
    func setViewedForTesting(_ index: Int, _ viewed: Bool) { setViewed(index, viewed) }
    func selectRangeForTesting(_ next: CheckpointTimeline) { timelineView.timeline = next; rangeChanged(next) }

    // MARK: - Publish (the Integration half of Review)

    /// Where git runs for this track: its own worktree (the branch is checked out there), else
    /// the shared checkout. Any checkout of the repository sees every branch and remote.
    private var repositoryPath: String? { currentWorkingDirectory?.path ?? canonicalRoot?.path }

    // MARK: - The base branch's own work

    /// The branch shown when there's no track: the base, with its uncommitted work and its
    /// commits not yet on its upstream. Nil when a track is shown.
    private var baseBranchShown: String?
    /// What the viewed checkmarks are remembered under: the track, or the base branch.
    private var viewedKey: String? { currentTrack?.branchName ?? baseBranchShown }

    struct BaseWork: Sendable {
        var branch: String
        var upstream: String?
        var unpushed: Int
        var uncommitted: Int
        var diff: String

        /// "3 uncommitted · 2 commits not on origin/main"
        var summary: String {
            var parts: [String] = []
            if uncommitted > 0 { parts.append("\(uncommitted) uncommitted change\(uncommitted == 1 ? "" : "s")") }
            if unpushed > 0, let upstream { parts.append("\(unpushed) commit\(unpushed == 1 ? "" : "s") not on \(upstream)") }
            return parts.joined(separator: " \u{00B7} ")
        }
    }

    /// The checkout's own work: against its upstream when it has one (what isn't pushed, and
    /// what isn't committed), else against its last commit. New files are included.
    nonisolated static func baseWork(cwd: String) -> BaseWork? {
        let head = GitPaths.runGit(["symbolic-ref", "--quiet", "--short", "HEAD"], cwd: cwd)
        let branch = head.success ? head.output : "HEAD"
        let upstreamRead = GitPaths.runGit(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], cwd: cwd)
        let upstream = upstreamRead.success && !upstreamRead.output.isEmpty ? upstreamRead.output : nil
        let unpushed = upstream.flatMap { Int(GitPaths.runGit(["rev-list", "--count", "\($0)..HEAD"], cwd: cwd).output) } ?? 0
        guard let dirty = GitPaths.dirtyPaths(cwd: cwd) else { return nil }
        guard GitPaths.runGit(["rev-parse", "--verify", "--quiet", "HEAD"], cwd: cwd).success else {
            return BaseWork(branch: branch, upstream: nil, unpushed: 0, uncommitted: dirty.count, diff: "")
        }
        var diff = GitPaths.runGitRaw(["diff", "--no-color", "--no-ext-diff", upstream ?? "HEAD"], cwd: cwd).output
        let untracked = GitPaths.runGitRaw(["ls-files", "--others", "--exclude-standard"], cwd: cwd).output
            .split(separator: "\n").prefix(50)
        for file in untracked {
            // Exits 1 for a difference, which is the point: the output is what's wanted.
            diff += GitPaths.runGitRaw(["diff", "--no-color", "--no-index", "--", "/dev/null", String(file)], cwd: cwd).output
        }
        // Without its last newline, as `refDiff` gives it: the parser read one more, empty line.
        while diff.hasSuffix("\n") { diff.removeLast() }
        return BaseWork(branch: branch, upstream: upstream, unpushed: unpushed, uncommitted: dirty.count, diff: diff)
    }

    private func refreshBase(root: URL, hasTracks: Bool) {
        let cwd = root.path
        refreshGeneration += 1
        let generation = refreshGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let work = Self.baseWork(cwd: cwd)
            DispatchQueue.main.async {
                guard let self, self.refreshGeneration == generation, self.currentTrack == nil else { return }
                guard let work, !work.diff.isEmpty else {
                    self.setBaseMode(nil)
                    let message = work.map { "Nothing has changed on \($0.branch): no uncommitted work, and nothing waiting to be pushed." } ?? Self.defaultEmptyStateText
                    self.showEmptyState(true, message: message, action: hasTracks ? ("Choose a Track\u{2026}", .chooseTrack) : ("New Track", .newTrack))
                    return
                }
                self.showEmptyState(false)
                self.setBaseMode(work)
                self.showDiff(work.diff, everything: true)
            }
        }
    }

    /// The header and card for the base's own work, or (nil) back to a track's: no Promote or
    /// Publish (the base is where things land), no checkpoints, a line saying what's there.
    private func setBaseMode(_ work: BaseWork?) {
        let base = work != nil
        baseBranchShown = work?.branch
        promoteHost.isHidden = base
        publishHost.isHidden = base
        guard let work else { return }
        currentBaseRef = work.upstream ?? "HEAD"
        titleLabel.stringValue = work.branch
        headerDetail.stringValue = "Base \u{00B7} \(work.summary)"
        for row in [accountRow, accountText, verificationLine, overlapLine, summaryHairline, timelineRow, rangeRow, noCheckpoints] as [NSView] { row.isHidden = true }
        setStatus(work.upstream == nil ? "Uncommitted work on \(work.branch). It has no upstream, so this is against its last commit." : "What \(work.branch) has that \(work.upstream!) doesn\u{2019}t: commits not yet pushed, and uncommitted work.")
        if !queueActive { diffTitle.stringValue = work.upstream.map { "Changes vs \($0)" } ?? "Uncommitted changes" }
    }

    var baseModeForTesting: String { baseBranchShown.map { "\($0) \(headerDetail.stringValue) files=\(rail.items.count)" } ?? (emptyState.isHidden ? "track" : "empty") }

    private func setStatus(_ text: String, _ color: NSColor = .secondaryLabelColor) {
        statusLabel.stringValue = text
        statusLabel.textColor = color
        statusLabel.isHidden = text.isEmpty
    }

    /// Reads the remote state (and any pull request) off the main thread, then shows the menu.
    private func publishTapped() {
        guard let track = currentTrack, let trackStore, let cwd = repositoryPath else { return }
        let baseRef = Self.baseRef(for: track, trackStore: trackStore)
        let branch = track.branchName
        setStatus("Checking the remote\u{2026}")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let state = Publishing.state(branch: branch, baseRef: baseRef, cwd: cwd)
            let hasGH = GitHubCLI.executable() != nil
            let pullRequest: GitHubCLI.PullRequest?
            if hasGH, state.isOnRemote, case .github? = state.remote?.web {
                pullRequest = GitHubCLI.pullRequest(branch: branch, cwd: cwd)
            } else {
                pullRequest = nil
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.setStatus("")
                self.showPublishMenu(track: track, baseRef: baseRef, cwd: cwd, state: state, hasGH: hasGH, pullRequest: pullRequest)
            }
        }
    }

    private func showPublishMenu(track: Track, baseRef: String, cwd: String, state: Publishing.State, hasGH: Bool, pullRequest: GitHubCLI.PullRequest?) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func item(_ title: String, subtitle: String? = nil, enabled: Bool = true, action: (() -> Void)? = nil) {
            let entry = PublishMenuItem(title: title, handler: action)
            entry.subtitle = subtitle
            entry.isEnabled = enabled && action != nil
            menu.addItem(entry)
        }
        guard let remote = state.remote else {
            item("No remote", subtitle: "Add one in a terminal: git remote add origin <url>", enabled: false)
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: publishButton.bounds.height + 4), in: publishButton)
            return
        }
        let branch = track.branchName
        item("\(remote.name) \u{00B7} \(remote.web?.displayName ?? remote.url)", enabled: false)
        menu.addItem(.separator())

        let pushSubtitle: String
        var canPush = true
        if state.remoteOnly > 0 {
            pushSubtitle = "\(remote.name) has \(state.remoteOnly) commit\(state.remoteOnly == 1 ? "" : "s") this branch doesn't. Pull them into the track first."
            canPush = false
        } else if !state.isOnRemote {
            pushSubtitle = "Not on \(remote.name) yet \u{00B7} \(state.unpushed) commit\(state.unpushed == 1 ? "" : "s")"
        } else if state.unpushed > 0 {
            pushSubtitle = "\(state.unpushed) commit\(state.unpushed == 1 ? "" : "s") to push"
        } else {
            pushSubtitle = "Up to date with \(remote.name)"
            canPush = false
        }
        item("Push \u{201C}\(branch)\u{201D}", subtitle: pushSubtitle, enabled: canPush) { [weak self] in
            self?.confirmPush(branch: branch, remote: remote, cwd: cwd, commits: state.unpushed)
        }

        if let pullRequest {
            item("View Pull Request #\(pullRequest.number)", subtitle: pullRequest.state.capitalized) { NSWorkspace.shared.open(pullRequest.url) }
        } else if let web = remote.web {
            let needsPush = !state.isOnRemote || state.unpushed > 0
            let kind = { if case .gitlab = web { return "Merge Request" } else { return "Pull Request" } }()
            if !state.baseIsOnRemote {
                item("Open \(kind)\u{2026}", subtitle: "\(baseRef) isn't on \(remote.name). Push it first.", enabled: false)
            } else {
                let finishes = hasGH && { if case .github = web { return true } else { return false } }() ? "" : " \u{00B7} finishes on \(web.displayName.split(separator: "/").first ?? "")"
                item(needsPush ? "Push and Open \(kind)\u{2026}" : "Open \(kind)\u{2026}", subtitle: "Into \(baseRef)\(finishes)", enabled: canPush || !needsPush) { [weak self] in
                    self?.confirmPullRequest(track: track, baseRef: baseRef, remote: remote, web: web, cwd: cwd, pushFirst: needsPush, commits: state.unpushed, useGH: hasGH)
                }
            }
        }

        menu.addItem(.separator())
        item("Check \(remote.name) for New Commits", subtitle: nil) { [weak self] in
            self?.fetchRemote(remote: remote, baseRef: baseRef, branch: branch, cwd: cwd)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: publishButton.bounds.height + 4), in: publishButton)
    }

    private func confirmPush(branch: String, remote: Publishing.Remote, cwd: String, commits: Int) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Push \u{201C}\(branch)\u{201D} to \(remote.name)?"
        alert.informativeText = "Publishes \(commits) commit\(commits == 1 ? "" : "s") to \(remote.web?.displayName ?? remote.url). Anyone with access to that repository can see them."
        alert.addButton(withTitle: "Push")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.setStatus("Pushing\u{2026}")
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Publishing.push(branch: branch, remote: remote.name, cwd: cwd)
                DispatchQueue.main.async {
                    self?.setStatus(result.message, result.succeeded ? DS.Color.statusVerified : DS.Color.statusNeedsYou)
                }
            }
        }
    }

    private func confirmPullRequest(track: Track, baseRef: String, remote: Publishing.Remote, web: Publishing.WebHost, cwd: String, pushFirst: Bool, commits: Int, useGH: Bool) {
        guard let window = view.window else { return }
        let direct = useGH && { if case .github = web { return true } else { return false } }()
        let alert = NSAlert()
        alert.messageText = "Open a pull request into \(baseRef)?"
        var detail = pushFirst ? "Pushes \(commits) commit\(commits == 1 ? "" : "s") to \(remote.name) first. " : ""
        detail += direct
            ? "Side opens it on GitHub with gh, as you. The description lists the track's checkpoints and what was verified."
            : "Your browser opens the new pull request page with the title and description filled in; you finish it there."
        alert.informativeText = detail
        let title = NSTextField(frame: NSRect(x: 0, y: 0, width: TracksWorkspaceViewController.alertFieldWidth, height: 24))
        title.stringValue = track.intent.isEmpty ? track.branchName : track.intent
        title.setAccessibilityLabel("Pull request title")
        alert.accessoryView = title
        alert.addButton(withTitle: "Open Pull Request")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = title
        let body = Publishing.pullRequestBody(intent: track.intent, checkpoints: sessionStore?.checkpoints(forTrackKey: track.branchName) ?? [])
        let branch = track.branchName
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let titleText = title.stringValue.trimmingCharacters(in: .whitespaces).isEmpty ? branch : title.stringValue
            self?.setStatus(pushFirst ? "Pushing\u{2026}" : "Opening the pull request\u{2026}")
            DispatchQueue.global(qos: .userInitiated).async {
                if pushFirst {
                    let pushed = Publishing.push(branch: branch, remote: remote.name, cwd: cwd)
                    guard pushed.succeeded else {
                        DispatchQueue.main.async { self?.setStatus(pushed.message, DS.Color.statusNeedsYou) }
                        return
                    }
                }
                if direct {
                    let created = GitHubCLI.create(base: baseRef, branch: branch, title: titleText, body: body, cwd: cwd)
                    DispatchQueue.main.async {
                        switch created {
                        case .success(let url):
                            self?.setStatus("Pull request opened.", DS.Color.statusVerified)
                            NSWorkspace.shared.open(url)
                        case .failure(let failure):
                            self?.setStatus("Couldn't open the pull request: \(failure.message)", DS.Color.statusNeedsYou)
                        }
                    }
                } else if let url = Publishing.newPullRequestURL(host: web, base: baseRef, branch: branch, title: titleText, body: body) {
                    DispatchQueue.main.async {
                        self?.setStatus("Finish the pull request in your browser.")
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }

    private func fetchRemote(remote: Publishing.Remote, baseRef: String, branch: String, cwd: String) {
        setStatus("Checking \(remote.name)\u{2026}")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fetched = Publishing.fetch(remote: remote.name, cwd: cwd)
            let state = Publishing.state(branch: branch, baseRef: baseRef, cwd: cwd)
            DispatchQueue.main.async {
                guard fetched.succeeded else { self?.setStatus(fetched.message, DS.Color.statusNeedsYou); return }
                if state.baseBehindRemote > 0 {
                    self?.setStatus("\(baseRef) on \(remote.name) has \(state.baseBehindRemote) commit\(state.baseBehindRemote == 1 ? "" : "s") you don't have yet. Update \(baseRef) before promoting.", DS.Color.statusNeedsYou)
                } else if state.remoteOnly > 0 {
                    self?.setStatus("\(remote.name) has \(state.remoteOnly) commit\(state.remoteOnly == 1 ? "" : "s") on \(branch) this track doesn't.", DS.Color.statusNeedsYou)
                } else {
                    self?.setStatus("Up to date with \(remote.name).", DS.Color.statusVerified)
                }
            }
        }
    }

    // MARK: - Promote

    @objc private func promoteTapped() {
        guard let track = currentTrack, let trackStore, let window = view.window else { return }
        let baseRef = Self.baseRef(for: track, trackStore: trackStore)
        guard let target = mergeTarget(for: track, trackStore: trackStore) else {
            setStatus("\u{201C}\(baseRef)\u{201D}'s working copy has been removed. Resume it in Bracks before promoting into it.", DS.Color.statusNeedsYou)
            return
        }
        // Verification is the point of recording it: promoting known-broken work should take a
        // deliberate second decision, not the same click as promoting verified work. A *failed*
        // verification is stated as such and the default button becomes Cancel; merely
        // unverified is mentioned without obstructing, since plenty of work legitimately has no
        // test to run.
        let checkpoints = sessionStore?.checkpoints(forTrackKey: track.branchName) ?? []
        let latestVerified = checkpoints.sorted { $0.createdAt > $1.createdAt }.first { $0.verification != nil }
        let failedVerification = latestVerified?.verification.flatMap { $0.passed ? nil : $0 }
        let staleness = Self.verificationStalenessCaveat(checkpoints: checkpoints)
        let orphaned = Self.orphanedStackNote(for: track, trackStore: trackStore, checkpoints: checkpoints)
        let unpromoted = trackStore.unpromotedChildren(of: track)

        let alert = NSAlert()
        alert.messageText = failedVerification == nil ? "Promote to \(baseRef)?" : "Promote work that failed \(failedVerification!.taskName)?"
        var detail = "This merges \(track.branchName) into \(baseRef) in \(target.isParent ? "that track's" : "your main") working copy. \(track.intent.isEmpty ? "" : "\u{201C}\(track.intent)\u{201D}")"
        if let failedVerification {
            alert.alertStyle = .warning
            detail += "\n\n\(failedVerification.taskName) last ran against this track and did not pass"
                + (failedVerification.exitCode.map { " (exit \($0))" } ?? "")
                + ". Promoting merges it anyway."
        } else if latestVerified == nil, !checkpoints.isEmpty {
            detail += "\n\nNothing has been verified on this track: no task has been run against these changes."
        } else if let staleness {
            detail += "\n\n" + staleness
        }
        if let orphaned {
            alert.alertStyle = .warning
            detail += "\n\n" + orphaned
        }
        if let stranded = Self.unpromotedStackNote(unpromoted, baseRef: baseRef) {
            alert.alertStyle = .warning
            detail += "\n\n" + stranded
        }
        alert.informativeText = detail
        alert.addButton(withTitle: unpromoted.isEmpty ? "Promote" : "Promote and Restack")
        alert.addButton(withTitle: "Cancel")
        // Cancel is the safe default when the evidence says the work is broken, isn't all this
        // track's, or would leave stacked work behind.
        if failedVerification != nil || orphaned != nil || !unpromoted.isEmpty { alert.buttons.last?.keyEquivalent = "\r"; alert.buttons.first?.keyEquivalent = "" }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.promote(track: track, baseRef: baseRef, mergeRoot: target.root, trackStore: trackStore, restack: !unpromoted.isEmpty)
        }
    }

    /// Where a track's changes actually land, and what they land on top of. A root track's base
    /// is the project default, merged into the canonical (shared) checkout — unchanged from
    /// before stacking existed. A stacked track's base is its *parent's own branch*, and that
    /// only exists checked out in the parent's own worktree — never the canonical root, which
    /// might be sitting on a completely different branch. `nil` means there's nowhere to merge
    /// into right now (a stacked track whose parent's worktree was removed via "Remove Working
    /// Copy" and hasn't been re-materialized).
    private func mergeTarget(for track: Track, trackStore: TrackStore) -> (root: URL, isParent: Bool)? {
        guard let parentId = track.parentTrackId, let parent = trackStore.tracks.first(where: { $0.id == parentId }) else {
            guard let canonicalRoot else { return nil }
            return (canonicalRoot, false)
        }
        guard let parentPath = parent.workingDirectoryPath else { return nil }
        return (URL(fileURLWithPath: parentPath), true)
    }

    /// A stacked track whose parent track was deleted: with no parent, its base falls back to
    /// the default branch, and its branch still carries the parent's commits, so promoting it
    /// merges the deleted track's work into main too (2026-09-30 audit, H14). Nil for any
    /// other track. Says how many of the commits are this track's own checkpoints.
    static func orphanedStackNote(for track: Track, trackStore: TrackStore, checkpoints: [Checkpoint]) -> String? {
        guard let parentId = track.parentTrackId, !trackStore.tracks.contains(where: { $0.id == parentId }) else { return nil }
        let baseRef = trackStore.defaultBranchName()
        let ahead = GitPaths.runGit(["rev-list", "\(baseRef)..\(track.branchName)"], cwd: trackStore.projectRoot.path)
        let shas = ahead.success ? ahead.output.split(separator: "\n").map(String.init) : []
        let own = shas.filter { sha in checkpoints.contains { $0.gitCommitSHA.map { sha.hasPrefix($0) || $0.hasPrefix(sha) } ?? false } }.count
        let others = shas.count - own
        guard others > 0 else { return nil }
        return "This track was stacked on a track that has since been deleted, so its branch also carries that track\u{2019}s work: \(others) of its \(shas.count) commit\(shas.count == 1 ? "" : "s") ahead of \(baseRef) aren\u{2019}t this track\u{2019}s checkpoints. Promoting merges all of them into \(baseRef)."
    }

    /// Promoting a track that still has stacked tracks on it: they promote into this track's
    /// branch, and once this track has landed nothing would carry their work further. Names
    /// them and says what Promote and Restack does. Nil when nothing is stacked and unpromoted.
    static func unpromotedStackNote(_ children: [Track], baseRef: String) -> String? {
        guard !children.isEmpty else { return nil }
        let one = children.count == 1
        let names = ListFormatter.localizedString(byJoining: children.map { "\u{201C}\($0.intent.isEmpty ? $0.branchName : $0.intent)\u{201D}" })
        return "\(names) \(one ? "is" : "are") stacked on this track and \(one ? "hasn\u{2019}t" : "haven\u{2019}t") been promoted into it. "
            + "Promote and Restack lands this track on \(baseRef) and stacks \(one ? "it" : "them") on \(baseRef) instead, so \(one ? "its" : "their") changes still reach \(baseRef) when promoted. "
            + "To land \(one ? "it" : "them") with this track, cancel and promote \(one ? "it" : "them") first."
    }

    static func baseRef(for track: Track, trackStore: TrackStore) -> String {
        guard let parentId = track.parentTrackId, let parent = trackStore.tracks.first(where: { $0.id == parentId }) else {
            return trackStore.defaultBranchName()
        }
        return parent.branchName
    }

    /// Runs entirely against `mergeRoot` — the track's actual base's own working copy (the
    /// canonical checkout for a root track, the parent track's own worktree for a stacked one) —
    /// never the track's own worktree, since promoting means moving the *base* forward, not the
    /// track's. Never leaves that working copy mid-merge: any conflict aborts immediately rather
    /// than leaving other windows/stages looking at a half-merged base.
    private func promote(track: Track, baseRef: String, mergeRoot: URL, trackStore: TrackStore, restack: Bool = false) {
        setPromoteEnabled(false)
        setStatus("Promoting\u{2026}")
        let cwd = mergeRoot.path
        let branchName = track.branchName
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = Self.performMerge(branchName: branchName, baseRef: baseRef, intent: track.intent, cwd: cwd)
            DispatchQueue.main.async {
                guard let self else { return }
                self.setStatus(outcome.message, outcome.succeeded ? DS.Color.statusVerified : DS.Color.statusNeedsYou)
                self.setPromoteEnabled(true)
                if outcome.succeeded {
                    if restack { trackStore.restackChildren(of: track) }
                    trackStore.setStatus(.completed, for: track)
                    self.refresh()
                }
            }
        }
    }

    // Internal rather than private so the refusal paths can be exercised against a real repo.
    static func performMerge(branchName: String, baseRef: String, intent: String, cwd: String) -> (succeeded: Bool, message: String) {
        // A status git couldn't read is not a clean tree (2026-09-30 audit, GIT-11).
        guard let dirty = GitPaths.dirtyPaths(cwd: cwd) else {
            return (false, "⚠︎ git couldn\u{2019}t read the status of \(cwd), so Side can\u{2019}t tell whether it has uncommitted changes. Nothing was promoted.")
        }
        guard dirty.isEmpty else {
            return (false, "⚠︎ Your main working copy has uncommitted changes. Commit or stash them first.")
        }
        // A detached HEAD is a hard refusal, not a skipped checkout. `symbolic-ref` fails when
        // HEAD points at a commit rather than a branch; the old code took that failure as "no
        // branch to compare against" and merged anyway — onto the detached commit — then printed
        // "✓ Promoted to main" and marked the track completed while main had not moved and the
        // merge commit was reachable only through the reflog. False success on the one action
        // "main is canonical" exists to protect. Found by the 2026-09-01 audit.
        let currentBranch = GitPaths.runGit(["symbolic-ref", "--short", "HEAD"], cwd: cwd)
        guard currentBranch.success else {
            return (false, "⚠︎ The checkout at \(cwd) is detached, not on any branch. Check out \(baseRef) there first, then promote.")
        }
        if currentBranch.output != baseRef {
            let checkout = GitPaths.runGit(["checkout", baseRef], cwd: cwd)
            guard checkout.success else { return (false, "⚠︎ Couldn't check out \(baseRef): \(checkout.output.prefix(200))") }
            // Trust the branch we are on, not the command that was supposed to put us there.
            let landed = GitPaths.runGit(["symbolic-ref", "--short", "HEAD"], cwd: cwd)
            guard landed.success, landed.output == baseRef else {
                return (false, "⚠︎ Expected to be on \(baseRef) after checkout but HEAD is \(landed.output.isEmpty ? "detached" : landed.output). Nothing was merged.")
            }
        }
        let ahead = GitPaths.runGit(["rev-list", "--count", "\(baseRef)..\(branchName)"], cwd: cwd)
        if ahead.success, Int(ahead.output) == 0 {
            return (false, "Nothing to promote. There are no commits ahead of \(baseRef).")
        }
        let mergeAttempt = GitPaths.runGit(["merge", "--no-commit", "--no-ff", branchName], cwd: cwd)
        guard mergeAttempt.success else {
            GitPaths.runGit(["merge", "--abort"], cwd: cwd)
            return (false, "⚠︎ Merging would conflict with \(baseRef). Resolve it manually (for example, rebase the track) and try again.")
        }
        let message = intent.isEmpty ? "Merge \(branchName)" : "Merge: \(intent)"
        let commit = GitPaths.runGit(["commit", "-m", message], cwd: cwd)
        guard commit.success else {
            GitPaths.runGit(["merge", "--abort"], cwd: cwd)
            return (false, "⚠︎ Couldn't finalize the merge commit.")
        }
        let sha = GitPaths.runGit(["rev-parse", "--short", "HEAD"], cwd: cwd)
        return (true, "✓ Promoted to \(baseRef) (\(sha.success ? sha.output : "?")).")
    }

    // MARK: - Static helpers

    private static func makeMetaLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = DS.Text.body()
        label.textColor = .tertiaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private static func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

extension ReviewWorkspaceViewController: StageChromeProviding {
    /// Nothing scrolls under the top row: the summary card starts below it.
    var scrollViewUnderTopRow: NSScrollView? { nil }
    var topRowContent: NSView? { loadViewIfNeeded(); return headerRow }

    func setBottomObstruction(_ height: CGFloat) {
        loadViewIfNeeded()
        // The diff and the file list run to the bottom edge and scroll under the bar.
        let inset = height > 0 ? height + DS.Spacing.l : 0
        diffViewer.bottomInset = inset
        rail.bottomInset = inset
        queueRail.bottomInset = inset
    }

    func setTopObstruction(_ height: CGFloat) {
        loadViewIfNeeded()
        cardTop?.constant = height + DS.Spacing.m
    }
}

/// A menu item that runs a closure: Publish's items carry their action with them.
private final class PublishMenuItem: NSMenuItem {
    private let handler: (() -> Void)?
    init(title: String, handler: (() -> Void)?) {
        self.handler = handler
        super.init(title: title, action: handler == nil ? nil : #selector(run), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func run() { handler?() }
}
