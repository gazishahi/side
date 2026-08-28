import AppKit
import UniformTypeIdentifiers

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// Document view for the transcript. Flipped so blocks stack from the top down — an unflipped
/// scroll-view document view pins sparse content to the bottom, the same trap the Tracks ledger
/// hit.
private final class TranscriptContainerView: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
}

/// The Think stage: a *projection* of an `AgentRunner` — it owns no conversation state of its
/// own anymore. The loop, the streaming accumulator, and the approval pause all live on the
/// runner (`Heron/AgentRunner.swift`), which is owned by `ProjectContext` and outlives this view
/// across stage switches, track switches, and even this window closing while another window
/// keeps the project open. This controller's only job is: render whichever runner it's currently
/// attached to, and forward Send/Stop/Apply/Reject back to it.
final class ThinkWorkspaceViewController: NSViewController, NSPopoverDelegate {
    private let transcriptScroll = NSScrollView()
    private let transcriptContainer = TranscriptContainerView()
    private let transcriptStack = NSStackView()
    private let composer = ComposerView()
    /// One glass pill above the composer's trailing end — "Claude Sonnet 5 · Build · 1%" —
    /// opening a popover with the real controls. One pill instead of five chips: the composer
    /// stays a thin iMessage capsule holding only input affordances, and everything that
    /// describes the *session* (model, effort, scope, autonomy, context) lives together in one
    /// place. A popover rather than menus: roomier, anchors and flips natively (no upward-menu
    /// arithmetic), and lets three-way choices be segmented controls, which is how macOS says
    /// "pick one of three."
    private let sessionPill = ChipButton(symbolName: nil, accessibilityLabel: "Model, mode, and context for this track")
    private let sessionPillGlass = DS.makeGlass(cornerRadius: 14)
    /// Changed-files pill, bottom-left above the composer — the session pill's opposite number.
    private let changesPill = ChipButton(symbolName: "pencil.line", accessibilityLabel: "Files changed in this conversation")
    private let changesPillGlass = DS.makeGlass(cornerRadius: 14)
    /// A soft wash rising from the pill's bottom edge in the current scope's color.
    private let pillModeTint = GradientEdgeView(cornerRadius: 14)
    private var sessionPopover: NSPopover?
    /// The + button: outside the composer on its own glass circle, exactly as Messages places
    /// it. Attach-like actions plus the rare conversation-level ones.
    private let plusButton = ChipButton(symbolName: "plus", accessibilityLabel: "Add a file reference, or manage this conversation")
    private let plusGlass = DS.makeGlass(cornerRadius: 19)
    /// The explainer lives here now — visible only while there's nothing else to look at,
    /// instead of as a permanent first line of every conversation.
    private let emptyStateLabel = NSTextField(wrappingLabelWithString: "Ask about this project. The agent can read files, propose edits, and run commands — everything it changes waits for your approval.")

    private var runnerManager: AgentRunnerManager?
    /// Which project's usage the header reports — set alongside `runnerManager`.
    private var projectPath: String?
    /// Where a track's model choice lives. Weak isn't needed — `TrackStore` outlives this view
    /// (it's owned by `ProjectContext`), and this is reassigned on every `configure`.
    private var trackStore: TrackStore?
    /// Backs `@`-mention completion. Rebuilt when the attached track's working directory
    /// changes — a track's worktree is its own directory, so the candidate list has to follow.
    private let fileIndex = ProjectFileIndex()
    private var usageObserverToken: UUID?
    /// Set by `ShellViewController` — Think can't reach Make directly, and shouldn't.
    var onRevealFileRequested: ((URL) -> Void)?
    /// Set by the shell: switches the window to the Review stage, where checkpoints hold the
    /// durable record of what changed.
    var onOpenReviewRequested: (() -> Void)?
    /// Branch-name key, "" for "no active track" — same convention as Make/Run.
    private var attachedTrackKey: String?
    private var runner: AgentRunner?
    private var observerToken: UUID?
    /// Parallel to `runner.entries` — the view currently rendering each entry, so a streamed
    /// delta or a proposal resolution can update one block in place instead of rebuilding the
    /// whole transcript on every token.
    private var entryViews: [NSView] = []
    /// Streamed-text updates waiting for the next flush tick, latest text per entry. Tokens
    /// arrive far faster than a resize animation can play; applying each one restarted the
    /// animation every few milliseconds, which *is* the jitter — nothing ever finished moving.
    private var pendingStreamIndices: Set<Int> = []
    private var streamFlushScheduled = false
    /// Every entry that streamed since the last phase change — finalized (one markdown render)
    /// when streaming ends, because mid-stream the bubble shows plain appended text.
    private var activeStreamIndices: Set<Int> = []

    override func loadView() { view = NSView() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.wantsLayer = true
        ChromeBackground.install(in: view)

        sessionPill.onPress = { [weak self] in self?.showSessionPopover() }
        sessionPill.glassBackdrop = sessionPillGlass
        sessionPill.companionOverlay = pillModeTint
        sessionPill.translatesAutoresizingMaskIntoConstraints = false
        plusButton.setSymbol("plus", pointSize: 14)
        plusButton.onPress = { [weak self] in self?.showPlusPopover() }
        plusButton.glassBackdrop = plusGlass
        plusGlass.translatesAutoresizingMaskIntoConstraints = false


        transcriptStack.orientation = .vertical
        transcriptStack.alignment = .leading
        transcriptStack.spacing = DS.Spacing.s
        transcriptStack.edgeInsets = NSEdgeInsets(top: DS.Spacing.xl, left: DS.Spacing.xxl, bottom: DS.Spacing.xl, right: DS.Spacing.xxl)
        transcriptStack.translatesAutoresizingMaskIntoConstraints = false
        transcriptContainer.addSubview(transcriptStack)
        transcriptContainer.translatesAutoresizingMaskIntoConstraints = false
        // Layer-backed document view: lets the clip view translate a rasterized tree rather than
        // asking every visible subview to redraw as it moves.
        transcriptContainer.wantsLayer = true
        transcriptScroll.documentView = transcriptContainer
        transcriptScroll.hasVerticalScroller = true
        transcriptScroll.drawsBackground = false
        transcriptScroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(transcriptScroll)

        composer.placeholder = "Ask about this project…"
        composer.mentionCandidates = { [weak self] partial in
            self?.fileIndex.matches(for: partial) ?? []
        }
        composer.slashCandidates = { partial in
            Self.slashCommands
                .filter { partial.isEmpty || $0.name.hasPrefix(partial.lowercased()) }
                .map { "/\($0.name) — \($0.blurb)" }
        }
        composer.onSlashCommand = { [weak self] name in self?.performSlashCommand(name) }
        composer.onAction = { [weak self] in self?.composerActionTapped() }
        composer.onCycleMode = { [weak self] in self?.cycleScope() }
        view.addSubview(composer)
        // Added after the scroll view on purpose: everything down here floats over the
        // transcript, and subview order is what keeps scrolled bubbles from painting across it.
        view.addSubview(plusGlass)
        view.addSubview(plusButton)
        view.addSubview(sessionPillGlass)
        view.addSubview(pillModeTint)
        view.addSubview(sessionPill)
        changesPill.glassBackdrop = changesPillGlass
        changesPill.onPress = { [weak self] in self?.onOpenReviewRequested?() }
        changesPill.toolTip = "Open Review"
        changesPill.isHidden = true
        changesPillGlass.isHidden = true
        view.addSubview(changesPillGlass)
        view.addSubview(changesPill)

        emptyStateLabel.font = DS.Text.body()
        emptyStateLabel.textColor = .tertiaryLabelColor
        emptyStateLabel.alignment = .center
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyStateLabel)

        NSLayoutConstraint.activate([
            emptyStateLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyStateLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            // Full bleed to the window's bottom: the composer *floats over* the transcript on
            // glass, no separating line — the messages refract under it as they scroll, which is
            // the whole point of the material. The scroll view gets a bottom content inset in
            // viewDidLayout so the last message can still clear the composer.
            transcriptScroll.topAnchor.constraint(equalTo: view.topAnchor),
            transcriptScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            transcriptScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            transcriptScroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            // Width pinned to the clip view so wrapping labels lay out against a known width
            // instead of growing horizontally forever.
            transcriptContainer.widthAnchor.constraint(equalTo: transcriptScroll.contentView.widthAnchor),
            transcriptStack.topAnchor.constraint(equalTo: transcriptContainer.topAnchor),
            transcriptStack.leadingAnchor.constraint(equalTo: transcriptContainer.leadingAnchor),
            transcriptStack.trailingAnchor.constraint(equalTo: transcriptContainer.trailingAnchor),
            transcriptStack.bottomAnchor.constraint(equalTo: transcriptContainer.bottomAnchor),
            // The + sits beside the capsule, its glass circle bottom-aligned with it.
            plusGlass.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: DS.Spacing.xxl),
            plusGlass.bottomAnchor.constraint(equalTo: composer.bottomAnchor, constant: -3),
            plusGlass.widthAnchor.constraint(equalToConstant: 38),
            plusGlass.heightAnchor.constraint(equalToConstant: 38),
            plusButton.centerXAnchor.constraint(equalTo: plusGlass.centerXAnchor),
            plusButton.centerYAnchor.constraint(equalTo: plusGlass.centerYAnchor),
            composer.leadingAnchor.constraint(equalTo: plusGlass.trailingAnchor, constant: DS.Spacing.m),
            composer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -DS.Spacing.xxl),
            composer.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -DS.Spacing.xl),
            // The session pill floats just above the composer's trailing corner.
            sessionPill.trailingAnchor.constraint(equalTo: composer.trailingAnchor, constant: -DS.Spacing.xs),
            sessionPill.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -DS.Spacing.s),
            sessionPillGlass.topAnchor.constraint(equalTo: sessionPill.topAnchor, constant: -2),
            sessionPillGlass.bottomAnchor.constraint(equalTo: sessionPill.bottomAnchor, constant: 2),
            sessionPillGlass.leadingAnchor.constraint(equalTo: sessionPill.leadingAnchor, constant: -DS.Spacing.s),
            sessionPillGlass.trailingAnchor.constraint(equalTo: sessionPill.trailingAnchor, constant: DS.Spacing.s),
            pillModeTint.topAnchor.constraint(equalTo: sessionPillGlass.topAnchor),
            pillModeTint.bottomAnchor.constraint(equalTo: sessionPillGlass.bottomAnchor),
            pillModeTint.leadingAnchor.constraint(equalTo: sessionPillGlass.leadingAnchor),
            pillModeTint.trailingAnchor.constraint(equalTo: sessionPillGlass.trailingAnchor),
            // Mirror of the session pill, on the composer's leading corner.
            changesPill.leadingAnchor.constraint(equalTo: composer.leadingAnchor, constant: DS.Spacing.xs),
            changesPill.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -DS.Spacing.s),
            changesPillGlass.topAnchor.constraint(equalTo: changesPill.topAnchor, constant: -2),
            changesPillGlass.bottomAnchor.constraint(equalTo: changesPill.bottomAnchor, constant: 2),
            changesPillGlass.leadingAnchor.constraint(equalTo: changesPill.leadingAnchor, constant: -DS.Spacing.s),
            changesPillGlass.trailingAnchor.constraint(equalTo: changesPill.trailingAnchor, constant: DS.Spacing.s),
        ])

        // The header's token/cost figures come from a store the runner writes to directly, so
        // they need their own refresh signal — a run's usage lands after `.phaseChanged`, not
        // with it.
        usageObserverToken = UsageStore.shared.addChangeObserver { [weak self] in
            self?.refreshSessionPill()
        }
        // History deleted from Preferences tears down the runners this view is projecting, so
        // it has to re-attach — otherwise the transcript on screen outlives its own file.
        NotificationCenter.default.addObserver(
            self, selector: #selector(conversationsDeleted),
            name: HistoryViewController.conversationsDeletedNotification, object: nil
        )
        // Fonts are set when each entry view is built, so a text-size change only reaches an
        // open transcript by rebuilding it. A setting that applied to future windows only is a
        // setting people stop trusting.
        NotificationCenter.default.addObserver(
            self, selector: #selector(textScaleChanged),
            name: DS.Text.scaleDidChangeNotification, object: nil
        )

        renderFull()
    }

    deinit {
        if let usageObserverToken { UsageStore.shared.removeChangeObserver(usageObserverToken) }
    }

    /// Keeps the last message reachable above the floating composer. Recomputed on layout
    /// because the composer grows with wrapped text.
    override func viewDidLayout() {
        super.viewDidLayout()
        transcriptScroll.automaticallyAdjustsContentInsets = false
        let overlap = composer.frame.height + 26 /* pill */ + DS.Spacing.xl + DS.Spacing.l
        if abs(transcriptScroll.contentInsets.bottom - overlap) > 0.5 {
            transcriptScroll.contentInsets = NSEdgeInsets(top: DS.Spacing.m, left: 0, bottom: overlap, right: 0)
            transcriptScroll.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: overlap - DS.Spacing.l, right: 0)
        }
    }

    /// Same responder-chain lesson Make/Tracks already learned: without explicitly claiming
    /// first responder on appearance, nothing in this stage's hierarchy holds it and
    /// menu-routed actions targeting this controller silently go nowhere.
    override func viewDidAppear() {
        super.viewDidAppear()
        refreshSessionPill()
        composer.focus()
        // Mirrors RunWorkspaceViewController.clearUnseenOutput: becoming visible is what counts
        // as "the human looked at this," clearing the doneUnread badge Tracks would otherwise
        // keep showing for a finished run nobody's actually seen yet.
        runner?.acknowledgeCompletion()
    }

    /// Detaches observation only — the runner itself is untouched and keeps running. A window
    /// closing was never a reason for an agent conversation to stop; that's the whole point of
    /// the runner living on `ProjectContext` instead of on this view.
    func prepareForClose() {
        detach()
    }

    // MARK: - Project/track wiring (ShellViewController calls these)

    func configure(runnerManager: AgentRunnerManager, trackStore: TrackStore, projectPath: String, trackKey: String?) {
        self.runnerManager = runnerManager
        self.trackStore = trackStore
        self.projectPath = projectPath
        attach(trackKey: trackKey)
    }

    /// Cancel-observation → get new runner → rebuild. Deliberately does **not** stop whatever
    /// runner this view was previously attached to — with the loop living on `AgentRunner`
    /// rather than on this view, a track switch no longer has any state here left to wedge.
    func reloadForTrackSwitch(trackKey: String?) {
        attach(trackKey: trackKey)
    }

    private func attach(trackKey: String?) {
        detach()
        attachedTrackKey = trackKey
        refreshFileIndex()
        if let runnerManager {
            let newRunner = runnerManager.runner(forTrackKey: trackKey ?? "")
            runner = newRunner
            observerToken = newRunner.addObserver { [weak self] event in self?.handle(event) }
        } else {
            runner = nil
        }
        if isViewLoaded {
            renderFull()
            if view.window != nil { runner?.acknowledgeCompletion() }
        }
    }

    private func detach() {
        if let runner, let observerToken { runner.removeObserver(observerToken) }
        observerToken = nil
    }

    // MARK: - Runner events

    private func handle(_ event: AgentRunEvent) {
        switch event {
        case .reset:
            renderFull()
        case .appended(let index):
            appendEntryView(at: index)
            refreshSessionPill()
        case .updated(let index):
            if case .assistantText = runner?.entries[safe: index]?.kind {
                pendingStreamIndices.insert(index)
                activeStreamIndices.insert(index)
                scheduleStreamFlush()
            } else {
                updateEntryView(at: index)
            }
        case .phaseChanged:
            finalizeStreamedBubbles()
            updateSendButton()
            refreshSessionPill()
            // A blocked/finished phase change can happen while this stage is the one on screen
            // (a stall firing, a round-trip cap hitting) — same acknowledgement as viewDidAppear,
            // just triggered by the runner instead of by becoming visible. `view.window != nil`
            // is the cheap proxy for "currently on screen": `show(_:)` removes a hidden stage's
            // view from the hierarchy entirely, which clears it.
            if isViewLoaded, view.window != nil { runner?.acknowledgeCompletion() }
        }
    }

    // MARK: - Sending

    private func composerActionTapped() {
        guard let runner else {
            appendLocalNotice("Open a project first — Think conversations belong to a project.")
            return
        }
        if runner.phase == .streaming || runner.phase == .runningTools {
            runner.stop()
            return
        }
        guard runner.phase != .awaitingApproval else { return }
        let text = composer.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = composer.attachmentPayloads()
        guard !text.isEmpty || !attachments.isEmpty else { return }
        composer.clear()
        runner.send(text, attachments: attachments)
    }

    private func updateSendButton() {
        let phase = runner?.phase ?? .idle
        composer.setBusy(phase == .streaming || phase == .runningTools)
        let awaitingApproval = phase == .awaitingApproval
        composer.isEnabled = !awaitingApproval
        composer.placeholder = awaitingApproval
            ? "Apply or reject the proposed change above to continue…"
            : "Ask about this project…"
    }

    @objc private func textScaleChanged() {
        refreshSessionPill()
        renderFull()
    }

    @objc private func conversationsDeleted() {
        attach(trackKey: attachedTrackKey)
    }

    // MARK: - Model + effort

    /// What this track will actually use: its own choice where it has one, the app default
    /// otherwise. Mirrors `AgentRunner.resolvedSelection()` deliberately — the header must show
    /// what the next request will do, not what someone once picked.
    private func resolvedSelection() -> (providerId: String, modelId: String, effort: AgentEffort, isTrackSpecific: Bool) {
        let registry = ProviderRegistryStore.shared
        let storedProviderId: String? = trackStore?.modelSelection(forTrackKey: attachedTrackKey ?? "").providerId
        let storedModelId: String? = trackStore?.modelSelection(forTrackKey: attachedTrackKey ?? "").modelId
        let storedEffort: AgentEffort? = trackStore?.modelSelection(forTrackKey: attachedTrackKey ?? "").effort

        let providerId: String = storedProviderId ?? registry.activeProviderId
        let definition = registry.provider(for: providerId) ?? registry.provider(for: registry.activeProviderId)
        // Falls back rather than showing a model that no longer exists: a provider's model list
        // can change under a stored selection, and `resolveAdapter` falls back the same way.
        var modelId: String = definition?.defaultModelId ?? ""
        if let requested = storedModelId, let match = definition?.models.first(where: { $0.id == requested }) {
            modelId = match.id
        }
        let isTrackSpecific = storedProviderId != nil || storedModelId != nil || storedEffort != nil
        return (providerId, modelId, storedEffort ?? .default, isTrackSpecific)
    }

    /// The + popover — same presentation as the pill, same feel.
    private func showPlusPopover() {
        let actions = PlusActionsViewController()
        actions.onAttach = { [weak self] in self?.insertMentionTrigger() }
        actions.onAttachImage = { [weak self] in self?.pickImageAttachment() }
        actions.onCompact = { [weak self] in self?.compactConversation() }
        actions.onNewConversation = { [weak self] in self?.startNewConversation() }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = actions
        popover.show(relativeTo: plusButton.bounds, of: plusButton, preferredEdge: .maxY)
    }

    /// The + popover's "Attach Image…" — an open panel filtered to what the models accept.
    private func pickImageAttachment() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.png, .jpeg, .gif, .webP]
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let image = NSImage(contentsOf: url) { composer.addImageAttachment(image) }
        }
    }

    @objc private func insertMentionTrigger() {
        composer.focus()
        composer.insertText("@")
    }

    /// The pill's popover: every session control in one place, as real controls.
    private func showSessionPopover() {
        let settings = SessionSettingsViewController()
        settings.snapshot = sessionSnapshot()
        settings.onModelChosen = { [weak self] providerId, modelId in
            guard let self else { return }
            if let providerId, let modelId {
                let current = self.resolvedSelection()
                self.trackStore?.setModelSelection(providerId: providerId, modelId: modelId, effort: current.effort, for: self.attachedTrackKey ?? "")
            } else {
                // nil/nil is "App Default" — clear the track's own choice entirely.
                self.trackStore?.setModelSelection(providerId: nil, modelId: nil, effort: nil, for: self.attachedTrackKey ?? "")
            }
            self.refreshSessionPill()
            settings.snapshot = self.sessionSnapshot()
        }
        settings.onEffortChosen = { [weak self] effort in
            guard let self else { return }
            let current = self.resolvedSelection()
            // Choosing effort pins the model too: otherwise "high effort" would silently move to
            // a different model the moment someone changed the app default.
            self.trackStore?.setModelSelection(providerId: current.providerId, modelId: current.modelId, effort: effort, for: self.attachedTrackKey ?? "")
            self.refreshSessionPill()
        }
        settings.onScopeChosen = { [weak self] scope in
            guard let self else { return }
            // Leaving a read-only scope keeps whatever autonomy was set; entering one leaves it
            // stored but inert, so switching back restores it.
            self.trackStore?.setMode(AgentMode(scope: scope, autonomy: self.currentMode().autonomy), forTrackKey: self.attachedTrackKey ?? "")
            self.refreshSessionPill()
            settings.snapshot = self.sessionSnapshot()
        }
        settings.onAutonomyChosen = { [weak self] autonomy in
            guard let self else { return }
            self.trackStore?.setMode(AgentMode(scope: self.currentMode().scope, autonomy: autonomy), forTrackKey: self.attachedTrackKey ?? "")
            self.refreshSessionPill()
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = settings
        popover.delegate = self
        popover.show(relativeTo: sessionPill.bounds, of: sessionPill, preferredEdge: .maxY)
        sessionPopover = popover
    }

    private func sessionSnapshot() -> SessionSettingsViewController.Snapshot {
        let selection = resolvedSelection()
        let mode = currentMode()
        var usageLine = ""
        var spendLine: String?
        var budgetLine: String?
        if let runner {
            let usage = runner.contextUsage()
            usageLine = "Context: \(UsageFormatting.tokens(usage.usedTokens)) of \(UsageFormatting.tokens(usage.windowTokens)) tokens (\(Int((usage.fraction * 100).rounded()))%)"
        }
        if let projectPath {
            let trackKey = attachedTrackKey ?? ""
            let totals = UsageStore.shared.totals(projectPath: projectPath, trackKey: trackKey)
            if totals.totalTokens > 0 {
                var line = "This track: \(UsageFormatting.tokens(totals.totalTokens)) tokens"
                let priced = UsageStore.shared.records.filter { $0.projectPath == projectPath && $0.trackKey == trackKey }
                if priced.allSatisfy({ ModelPricing.isPriced(modelId: $0.modelId) }) {
                    let cost = priced.reduce(0.0) { $0 + (ModelPricing.estimatedCost(modelId: $1.modelId, totals: $1.totals) ?? 0) }
                    line += " · ~\(UsageFormatting.cost(cost))"
                }
                spendLine = line
            }
        }
        switch UsageBudget.status() {
        case .approaching(let spent, let limit):
            budgetLine = "Budget: \(UsageFormatting.cost(spent)) of \(UsageFormatting.cost(limit)) this month"
        case .exceeded(let spent, let limit):
            budgetLine = "Budget reached — \(UsageFormatting.cost(spent)) of \(UsageFormatting.cost(limit))"
        case .unlimited, .withinBudget:
            break
        }
        return .init(
            providerId: selection.providerId, modelId: selection.modelId,
            isTrackSpecific: selection.isTrackSpecific, effort: selection.effort, mode: mode,
            usageLine: usageLine, spendLine: spendLine, budgetLine: budgetLine
        )
    }

    /// The directory `@`-mentions resolve against: the track's own worktree when it has one,
    /// which is the same directory `AgentRunner` hands its tools.
    private func refreshFileIndex() {
        guard let projectPath else { return }
        let root = trackStore?.tracks.first { $0.branchName == (attachedTrackKey ?? "") }?.workingDirectoryPath
        let url = URL(fileURLWithPath: root ?? projectPath)
        fileIndex.refresh(root: url) {}
    }

    /// Existence check for bare-path linking — same root, same containment rule as opening.
    private func mentionedFileExists(_ path: String) -> Bool {
        guard let projectPath else { return false }
        let root = trackStore?.tracks.first { $0.branchName == (attachedTrackKey ?? "") }?.workingDirectoryPath ?? projectPath
        let url = URL(fileURLWithPath: root).appendingPathComponent(path).standardizedFileURL
        guard url.path.hasPrefix(URL(fileURLWithPath: root).standardizedFileURL.path + "/") else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    /// Opens a clicked mention in Make, resolved against the same directory the mention itself
    /// resolved against. Silently does nothing for a path that no longer exists — a stale
    /// mention in old scrollback shouldn't produce an error dialog years later.
    private func openMentionedFile(_ path: String) {
        guard let projectPath else { return }
        let root = trackStore?.tracks.first { $0.branchName == (attachedTrackKey ?? "") }?.workingDirectoryPath ?? projectPath
        let url = URL(fileURLWithPath: root).appendingPathComponent(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return }
        onRevealFileRequested?(url)
    }

    /// Shift+Tab in the composer walks Ask → Plan → Build → Ask, same as Cursor and Claude Code.
    private func cycleScope() {
        let all = AgentToolScope.allCases
        let current = currentMode()
        let next = all[((all.firstIndex(of: current.scope) ?? 0) + 1) % all.count]
        trackStore?.setMode(AgentMode(scope: next, autonomy: current.autonomy), forTrackKey: attachedTrackKey ?? "")
        refreshSessionPill()
    }

    private func currentMode() -> AgentMode {
        trackStore?.mode(forTrackKey: attachedTrackKey ?? "") ?? .default
    }

    /// One hue per tool scope, applied sparingly (pill edge, send button): the mode is a safety
    /// property, so the color is a signal, not a theme.
    private static func tint(for scope: AgentToolScope) -> NSColor {
        switch scope {
        case .ask: return .systemBlue
        case .plan: return .systemPurple
        case .build: return .systemOrange
        }
    }

    func popoverDidClose(_ notification: Notification) {
        sessionPopover = nil
        if pillRefreshDeferred {
            pillRefreshDeferred = false
            refreshSessionPill()
        }
    }

    private func resolvedSelectionModelName() -> String {
        let selection = resolvedSelection()
        return ProviderRegistryStore.shared.provider(for: selection.providerId)?
            .models.first { $0.id == selection.modelId }?.displayName ?? selection.modelId
    }

    @objc private func compactConversation() {
        guard let runner else { return }
        let usage = runner.contextUsage()
        let alert = NSAlert()
        alert.messageText = "Compact this conversation?"
        // Says what is lost, what it costs, and that it can't be undone — all three, because this
        // deletes the user's conversation to make room.
        alert.informativeText = "The turns so far (\(UsageFormatting.tokens(usage.usedTokens)) tokens) are replaced by a summary the model writes of them. Detail beyond that summary is gone, and this can't be undone. Checkpoints and your files are untouched.\n\nWriting the summary costs one request."
        alert.addButton(withTitle: "Compact")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        runner.compact { [weak self] _ in
            self?.renderFull()
            self?.refreshSessionPill()
        }
    }

    @objc private func startNewConversation() {
        guard let runner, !runner.entries.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Start a new conversation?"
        alert.informativeText = "This conversation is discarded — not summarized. Use Compact instead if the agent should carry what it learned forward. Checkpoints, usage history, and your files are untouched."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        runner.startNewConversation()
        renderFull()
        refreshSessionPill()
    }

    /// Set when a refresh arrives while the settings popover is open; honored on close.
    private var pillRefreshDeferred = false

    /// The pill's face: model · scope · context, tinted by how full the window is.
    private func refreshSessionPill() {
        // Color updates always land — changing a segmented control in the popover should recolor
        // the pill edge and send button immediately, and color doesn't move the anchor.
        let scopeTint = Self.tint(for: currentMode().scope)
        pillModeTint.color = scopeTint.withAlphaComponent(0.16)
        composer.setModeTint(scopeTint)
        // The popover is anchored to the pill: resizing the pill mid-edit visibly drags the
        // popover sideways. Hold the label until the popover closes.
        if sessionPopover?.isShown == true {
            pillRefreshDeferred = true
            return
        }
        let mode = currentMode()
        var title = "\(resolvedSelectionModelName()) · \(mode.scope.displayName)"
        var tint = NSColor.secondaryLabelColor
        if let runner {
            let usage = runner.contextUsage()
            title += " · \(Int((usage.fraction * 100).rounded()))%"
            switch usage.status {
            case .comfortable: break
            case .approaching: tint = .systemOrange
            case .critical: tint = .systemRed
            }
        }
        // Animated only on a real change — this refresh runs constantly (usage observer, phase
        // changes) and animating a no-op layout pass would fight other in-flight animations.
        let labelChanged = sessionPill.title != " \(title) "
        if labelChanged, view.window != nil {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                context.allowsImplicitAnimation = true
                sessionPill.setLabel(title, tint: tint)
                view.layoutSubtreeIfNeeded()
            }
        } else {
            sessionPill.setLabel(title, tint: tint)
        }
        sessionPillGlass.isHidden = sessionPill.isHidden
        pillModeTint.isHidden = sessionPill.isHidden
        refreshChangesPill()
    }

    /// "3 files +42 −7" — cumulative applied edits this conversation; click opens Review.
    private func refreshChangesPill() {
        let counts = runner?.appliedEditCounts ?? []
        let isEmpty = counts.isEmpty
        if !isEmpty {
            let added = counts.reduce(0) { $0 + $1.added }
            let removed = counts.reduce(0) { $0 + $1.removed }
            let label = "\(counts.count) file\(counts.count == 1 ? "" : "s") +\(added) −\(removed)"
            if changesPill.title != " \(label) " {
                changesPill.setLabel(label, tint: .secondaryLabelColor)
            }
        }
        guard changesPill.isHidden != isEmpty else { return }
        changesPill.isHidden = isEmpty
        changesPillGlass.isHidden = isEmpty
        if !isEmpty { DS.Motion.appear(changesPill) }
    }

    // MARK: - Slash commands

    /// Everything a chip can do, reachable without leaving the keyboard. The list is the router
    /// below, restated — a command that exists here but does nothing is worse than no palette.
    private static let slashCommands: [(name: String, blurb: String)] = [
        ("compact", "summarize the conversation to free up context"),
        ("new", "discard this conversation and start fresh"),
        ("ask", "read-only: answer questions"),
        ("plan", "read-only: produce a plan"),
        ("build", "full tools: edits and commands"),
        ("manual", "approve every edit and command"),
        ("guarded", "auto-run safe commands"),
        ("full", "auto-apply edits too"),
    ]

    private func performSlashCommand(_ name: String) {
        switch name {
        case "compact": compactConversation()
        case "new": startNewConversation()
        case "ask", "plan", "build":
            guard let scope = AgentToolScope(rawValue: name) else { return }
            trackStore?.setMode(AgentMode(scope: scope, autonomy: currentMode().autonomy), forTrackKey: attachedTrackKey ?? "")
            refreshSessionPill()
        case "manual", "guarded", "full":
            guard let autonomy = AgentAutonomy(rawValue: name) else { return }
            trackStore?.setMode(AgentMode(scope: currentMode().scope, autonomy: autonomy), forTrackKey: attachedTrackKey ?? "")
            refreshSessionPill()
        default:
            break
        }
    }

    // MARK: - Transcript rendering

    private func renderFull() {
        transcriptStack.arrangedSubviews.forEach {
            transcriptStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        entryViews.removeAll()
        for (index, entry) in (runner?.entries ?? []).enumerated() {
            let view = makeEntryView(entry)
            entryViews.append(view)
            addBlock(view, topSpacing: index == 0 ? 0 : Self.spacing(before: entry.kind))
        }
        emptyStateLabel.isHidden = !(runner?.entries.isEmpty ?? true)
        updateSendButton()
        scrollToBottom()
    }

    private func appendEntryView(at index: Int) {
        guard let entries = runner?.entries, entries.indices.contains(index) else { return }
        guard entryViews.count == index else {
            // Out of sync with the runner (shouldn't happen outside a bug) — safest recovery is
            // a full rebuild rather than rendering into the wrong position.
            renderFull()
            return
        }
        let entry = entries[index]
        let view = makeEntryView(entry)
        entryViews.append(view)
        addBlock(view, topSpacing: index == 0 ? 0 : Self.spacing(before: entry.kind))
        emptyStateLabel.isHidden = true
        // Only live appends animate — `renderFull` (reattach, track switch) lays the whole
        // history out instantly rather than replaying every arrival.
        animateIn(view)
    }

    /// The standard arrival (see `DS.Motion`) over the block's settled Auto Layout position.
    private func animateIn(_ view: NSView) {
        transcriptContainer.layoutSubtreeIfNeeded()
        DS.Motion.appear(view)
    }

    private func updateEntryView(at index: Int) {
        guard let entries = runner?.entries, entries.indices.contains(index), entryViews.indices.contains(index) else { return }
        let entry = entries[index]
        switch entry.kind {
        case .assistantText(let text):
            // One flush per tick, not one per token — see scheduleStreamFlush. The growth *and*
            // the scroll ride the same animation group: the old code animated the bubble but
            // snapped the scroll instantly on every token, so the view yanked downward against
            // its own growth animation — that fight was most of the jitter.
            guard let bubble = (entryViews[index] as? BubbleRowView)?.bubble else { return }
            let clip = transcriptScroll.contentView
            // Only follow the stream if the user is already at the bottom; never yank someone
            // who scrolled up to read.
            let wasAtBottom = clip.bounds.maxY >= transcriptContainer.bounds.height - 80
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                context.allowsImplicitAnimation = true
                bubble.setBody(text, streaming: true)
                // The whole transcript's layout, not just the bubble's subtree — the rows below
                // have to glide down in the same animation as the bubble's growth.
                self.transcriptContainer.layoutSubtreeIfNeeded()
                if wasAtBottom {
                    let maxY = max(0, self.transcriptContainer.bounds.height - clip.bounds.height + self.transcriptScroll.contentInsets.bottom)
                    clip.animator().setBoundsOrigin(NSPoint(x: 0, y: maxY))
                }
            }
            if wasAtBottom { transcriptScroll.reflectScrolledClipView(clip) }
            return  // scrollToBottom below would snap; the animated follow above replaces it.
        case .proposal(let presentation):
            guard let card = entryViews[index] as? ProposedEditView, let resolution = presentation.resolution else { return }
            let label = resolution.label
            card.showResolution(label.text, color: Self.color(for: label.color))
        case .commandProposal(let presentation):
            guard let card = entryViews[index] as? CommandProposalView, let resolution = presentation.resolution else { return }
            Self.showCommandResolution(card, resolution)
        default:
            break // Only streamed assistant text and proposal resolutions mutate in place.
        }
        scrollToBottom()
    }

    /// One `RunTranscriptEntry` → exactly one view. Headers ("You"/"Assistant") aren't a
    /// separate entry — they're drawn as part of the same block as the text they belong to.
    private func makeEntryView(_ entry: RunTranscriptEntry) -> NSView {
        switch entry.kind {
        case .meta(let text):
            return makeLabel(text, font: DS.Text.control(), color: .tertiaryLabelColor)
        case .userImage(let data):
            return ImageBubbleRowView(imageData: data, alignRight: true)
        case .userText(let text):
            // iMessage-shaped: sent messages are solid-accent bubbles hugging their own content
            // against the trailing edge; no "You" header — the side and color carry that.
            let bubble = TextBlockView(style: .sent, body: text, maxBubbleWidth: 460, pathResolver: { [weak self] path in self?.mentionedFileExists(path) ?? false })
            bubble.onMentionClicked = { [weak self] path in self?.openMentionedFile(path) }
            return BubbleRowView(bubble: bubble, alignRight: true)
        case .assistantText(let text):
            let bubble = TextBlockView(style: .received, body: text, maxBubbleWidth: 620, pathResolver: { [weak self] path in self?.mentionedFileExists(path) ?? false })
            // The agent quotes paths back constantly; making those live too means "@" and a
            // plain mention behave the same wherever they appear.
            bubble.onMentionClicked = { [weak self] path in self?.openMentionedFile(path) }
            return BubbleRowView(bubble: bubble, alignRight: false)
        case .toolCall(let name, let summary):
            // System text: these are status lines in a chat, not terminal output.
            return makeLabel("→ \(name)\(summary)", font: DS.Text.caption(), color: .secondaryLabelColor)
        case .toolResult(let text, let isError):
            return makeLabel(text, font: DS.Text.caption(), color: isError ? .systemOrange : .secondaryLabelColor)
        case .failure(let text):
            let bubble = TextBlockView(style: .error, body: text, maxBubbleWidth: 620)
            return BubbleRowView(bubble: bubble, alignRight: false)
        case .proposal(let presentation):
            let card = ProposedEditView(edit: presentation.edit, diffText: presentation.diffText)
            if let resolution = presentation.resolution {
                let label = resolution.label
                card.showResolution(label.text, color: Self.color(for: label.color))
            } else {
                let proposalId = entry.id
                card.onApply = { [weak self] in self?.runner?.resolve(proposalId: proposalId, decision: .apply) }
                card.onReject = { [weak self] in self?.runner?.resolve(proposalId: proposalId, decision: .reject) }
            }
            return card
        case .commandProposal(let presentation):
            let card = CommandProposalView(command: presentation.command)
            if let resolution = presentation.resolution {
                Self.showCommandResolution(card, resolution)
            } else {
                let proposalId = entry.id
                card.onApply = { [weak self] in self?.runner?.resolve(proposalId: proposalId, decision: .apply) }
                card.onReject = { [weak self] in self?.runner?.resolve(proposalId: proposalId, decision: .reject) }
            }
            return card
        }
    }

    private static func showCommandResolution(_ card: CommandProposalView, _ resolution: CommandPresentation.Resolution) {
        switch resolution {
        case .executed(let output):
            let preview = output.isEmpty ? "(no output)" : String(output.prefix(300))
            card.showResolution("Ran — \(preview)", color: .systemGreen)
        case .rejected:
            card.showResolution("Rejected", color: .secondaryLabelColor)
        }
    }

    private static func spacing(before kind: RunTranscriptEntry.Kind) -> CGFloat {
        switch kind {
        case .meta, .userText, .userImage, .assistantText, .proposal, .commandProposal: return 8
        case .toolCall, .toolResult, .failure: return 4
        }
    }

    private static func color(for semantic: ProposalPresentation.ResolutionColor) -> NSColor {
        switch semantic {
        case .success: return .systemGreen
        case .neutral: return .secondaryLabelColor
        case .warning: return .systemOrange
        case .failure: return .systemRed
        }
    }

    /// Rendered directly into the transcript, with no runner behind it — only reachable when no
    /// project is open at all, since `configure` is always called before this stage is visible
    /// once a project exists.
    private func appendLocalNotice(_ text: String) {
        addBlock(makeLabel(text, font: DS.Text.control(), color: .tertiaryLabelColor), topSpacing: transcriptStack.arrangedSubviews.isEmpty ? 0 : 8)
    }

    private func makeLabel(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = font
        label.textColor = color
        label.isSelectable = true
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func addBlock(_ view: NSView, topSpacing: CGFloat? = nil) {
        if let topSpacing, let previous = transcriptStack.arrangedSubviews.last {
            transcriptStack.setCustomSpacing(topSpacing, after: previous)
        }
        transcriptStack.addArrangedSubview(view)
        // Full-width blocks: wrapping labels need a definite width to compute their height, and
        // diff cards should span the transcript rather than hug their content.
        view.widthAnchor.constraint(equalTo: transcriptStack.widthAnchor, constant: -(transcriptStack.edgeInsets.left + transcriptStack.edgeInsets.right)).isActive = true
        scrollToBottom()
    }

    /// Applies at most one streamed-text update per ~50ms — comfortably faster than the eye
    /// needs, comfortably slower than tokens arrive, and long enough for each growth animation
    /// to actually play. Also caps markdown re-parsing at 20/s instead of per-token.
    private func scheduleStreamFlush() {
        guard !streamFlushScheduled else { return }
        streamFlushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.035) { [weak self] in
            guard let self else { return }
            self.streamFlushScheduled = false
            let indices = self.pendingStreamIndices
            self.pendingStreamIndices = []
            for index in indices.sorted() { self.updateEntryView(at: index) }
        }
    }

    /// One markdown render per streamed message, after it stops changing. Mid-stream the bubble
    /// holds plain text so tokens can be *appended* to the text storage; this settles the final
    /// form (bold, code runs, mention links) in a single pass.
    private func finalizeStreamedBubbles() {
        let indices = activeStreamIndices
        activeStreamIndices = []
        pendingStreamIndices = []
        guard let entries = runner?.entries else { return }
        for index in indices {
            guard entries.indices.contains(index), entryViews.indices.contains(index),
                  case .assistantText(let text) = entries[index].kind,
                  let bubble = (entryViews[index] as? BubbleRowView)?.bubble else { continue }
            bubble.setBody(text)
        }
        if !indices.isEmpty { transcriptContainer.layoutSubtreeIfNeeded() }
    }

    private func scrollToBottom() {
        // After the next layout pass, so the newly added block's height is already accounted
        // for — scrolling before layout lands short of the real bottom.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.transcriptContainer.layoutSubtreeIfNeeded()
            let maxY = max(0, self.transcriptContainer.bounds.height - self.transcriptScroll.contentView.bounds.height)
            self.transcriptScroll.contentView.scroll(to: NSPoint(x: 0, y: maxY))
            self.transcriptScroll.reflectScrolledClipView(self.transcriptScroll.contentView)
        }
    }
}

/// One chat bubble, iMessage-shaped: a solid rounded fill hugging its own content, no header —
/// which side it sits on and what color it is carry "who said this." Body text renders through
/// `MarkdownRenderer` (the same one Make's preview uses), and a streamed delta re-measures the
/// bubble's width in place so it grows with the response instead of being sized once.
private final class TextBlockView: NSView, NSTextViewDelegate {
    enum Style {
        case sent      // the user: accent-filled, white text
        case received  // the assistant: gray-filled, standard text
        case error     // a failure: red-tinted, keeps a small header since it isn't a chat turn

        var fillColor: NSColor {
            switch self {
            case .sent: return .controlAccentColor
            case .received: return DS.Color.bg4
            case .error: return NSColor.systemRed.withAlphaComponent(0.18)
            }
        }
        var textColor: NSColor {
            switch self {
            case .sent: return .white
            case .received: return .labelColor
            case .error: return .systemRed
            }
        }
    }

    /// An `NSTextView`, not an `NSTextField`. This is the scroll-stutter fix, third attempt and
    /// the structural one: a text *field* draws its whole attributed string through
    /// NSStringDrawing whenever any part of it needs display, so an 8,000-character compaction
    /// summary re-rendered end-to-end on every scroll frame that clipped it. A text view owns a
    /// layout manager and draws only the glyph ranges actually visible. It also gives mentions
    /// real `.link` handling — click, pointing-hand cursor, and AX — replacing a hand-rolled
    /// hitTest/cursor-rect/glyph-measurement stack that was itself a source of per-frame work.
    private let bodyText = NSTextView()
    /// Called with a project-relative path when a mention in this bubble is clicked. Set by the
    /// row builder; nil for bubbles where mentions aren't meaningful.
    var onMentionClicked: ((String) -> Void)?
    private let style: Style
    private let maxBubbleWidth: CGFloat
    private let bodyWidthConstraint: NSLayoutConstraint
    private let bodyHeightConstraint: NSLayoutConstraint
    /// The raw source text (not the rendered `NSAttributedString`) — kept so Copy hands back
    /// what was actually said, not whatever `MarkdownRenderer` happened to produce.
    private(set) var plainText: String = ""

    private static let insets = NSEdgeInsets(top: 7, left: 12, bottom: 8, right: 12)

    /// Which side the speech tail points, if any. Errors are notices, not speech — no tail.
    private var tail: Tail {
        switch style {
        case .sent: return .trailing
        case .received: return .leading
        case .error: return .none
        }
    }
    enum Tail { case none, leading, trailing }
    /// How far the tail pokes past the bubble body. The body is inset by this on the tail side,
    /// so autolayout sees one rect and the curve lives inside it.
    static let tailWidth: CGFloat = 6

    /// Answers "is this token a real project file?" — set at init so the *first* render can
    /// already link paths the agent quotes without an @ (which is how it usually writes them).
    private let pathResolver: ((String) -> Bool)?

    init(style: Style, body: String, maxBubbleWidth: CGFloat, pathResolver: ((String) -> Bool)? = nil) {
        self.style = style
        self.maxBubbleWidth = maxBubbleWidth
        self.pathResolver = pathResolver
        self.bodyWidthConstraint = bodyText.widthAnchor.constraint(equalToConstant: 10)
        self.bodyHeightConstraint = bodyText.heightAnchor.constraint(equalToConstant: 10)

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        // The bubble shape — rounded rect plus the speech tail — is drawn in draw(_:), not a
        // layer cornerRadius: a tail isn't expressible as a corner radius, which is the whole
        // difference between "rounded rectangle" and "speech bubble."
        wantsLayer = true

        bodyText.isEditable = false
        bodyText.isSelectable = true
        bodyText.drawsBackground = false
        bodyText.textContainerInset = .zero
        bodyText.textContainer?.lineFragmentPadding = 0
        bodyText.delegate = self
        // Mentions carry their own colors; without this, AppKit repaints every link blue.
        bodyText.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        bodyText.translatesAutoresizingMaskIntoConstraints = false

        var topAnchorForBody = topAnchor
        var topConstant = Self.insets.top
        if case .error = style {
            let headerLabel = NSTextField(labelWithString: "Error")
            headerLabel.font = DS.Text.caption(.semibold)
            headerLabel.textColor = .systemRed
            headerLabel.translatesAutoresizingMaskIntoConstraints = false
            addSubview(headerLabel)
            NSLayoutConstraint.activate([
                headerLabel.topAnchor.constraint(equalTo: topAnchor, constant: Self.insets.top),
                headerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.insets.left),
            ])
            topAnchorForBody = headerLabel.bottomAnchor
            topConstant = 3
        }

        addSubview(bodyText)
        let leadingInset = Self.insets.left + (tail == .leading ? Self.tailWidth : 0)
        let trailingInset = Self.insets.right + (tail == .trailing ? Self.tailWidth : 0)
        NSLayoutConstraint.activate([
            bodyText.topAnchor.constraint(equalTo: topAnchorForBody, constant: topConstant),
            bodyText.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leadingInset),
            bodyText.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -trailingInset),
            bodyText.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.insets.bottom),
            bodyWidthConstraint,
            bodyHeightConstraint,
        ])
        setBody(body)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // UIKit-style coordinates so the classic bubble path (written for iOS, where y grows
    // downward) transfers verbatim.
    override var isFlipped: Bool { true }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    /// The iMessage bubble: a rounded rect whose bottom tail-side corner sweeps out into a small
    /// curl. This is all a "speech bubble" is — the widely-circulated pair of bezier paths from
    /// the shape Apple ships, one per direction, with the corner radius baked into the curve
    /// control points (which is why it ignores DS.Radius).
    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width
        let h = bounds.height
        let path = NSBezierPath()
        switch tail {
        case .none:
            path.appendRoundedRect(bounds, xRadius: DS.Radius.bubble, yRadius: DS.Radius.bubble)
        case .trailing:
            path.move(to: NSPoint(x: w - 22, y: h))
            path.line(to: NSPoint(x: 17, y: h))
            path.curve(to: NSPoint(x: 0, y: h - 17), controlPoint1: NSPoint(x: 7.61, y: h), controlPoint2: NSPoint(x: 0, y: h - 7.61))
            path.line(to: NSPoint(x: 0, y: 17))
            path.curve(to: NSPoint(x: 17, y: 0), controlPoint1: NSPoint(x: 0, y: 7.61), controlPoint2: NSPoint(x: 7.61, y: 0))
            path.line(to: NSPoint(x: w - 21, y: 0))
            path.curve(to: NSPoint(x: w - 4, y: 17), controlPoint1: NSPoint(x: w - 11.61, y: 0), controlPoint2: NSPoint(x: w - 4, y: 7.61))
            path.line(to: NSPoint(x: w - 4, y: h - 11))
            path.curve(to: NSPoint(x: w, y: h), controlPoint1: NSPoint(x: w - 4, y: h - 1), controlPoint2: NSPoint(x: w, y: h))
            path.line(to: NSPoint(x: w + 0.05, y: h - 0.01))
            path.curve(to: NSPoint(x: w - 11.04, y: h - 4.04), controlPoint1: NSPoint(x: w - 4.07, y: h + 0.43), controlPoint2: NSPoint(x: w - 8.16, y: h - 1.06))
            path.curve(to: NSPoint(x: w - 22, y: h), controlPoint1: NSPoint(x: w - 16, y: h), controlPoint2: NSPoint(x: w - 19, y: h))
        case .leading:
            path.move(to: NSPoint(x: 22, y: h))
            path.line(to: NSPoint(x: w - 17, y: h))
            path.curve(to: NSPoint(x: w, y: h - 17), controlPoint1: NSPoint(x: w - 7.61, y: h), controlPoint2: NSPoint(x: w, y: h - 7.61))
            path.line(to: NSPoint(x: w, y: 17))
            path.curve(to: NSPoint(x: w - 17, y: 0), controlPoint1: NSPoint(x: w, y: 7.61), controlPoint2: NSPoint(x: w - 7.61, y: 0))
            path.line(to: NSPoint(x: 21, y: 0))
            path.curve(to: NSPoint(x: 4, y: 17), controlPoint1: NSPoint(x: 11.61, y: 0), controlPoint2: NSPoint(x: 4, y: 7.61))
            path.line(to: NSPoint(x: 4, y: h - 11))
            path.curve(to: NSPoint(x: 0, y: h), controlPoint1: NSPoint(x: 4, y: h - 1), controlPoint2: NSPoint(x: 0, y: h))
            path.line(to: NSPoint(x: -0.05, y: h - 0.01))
            path.curve(to: NSPoint(x: 11.04, y: h - 4.04), controlPoint1: NSPoint(x: 4.07, y: h + 0.43), controlPoint2: NSPoint(x: 8.16, y: h - 1.06))
            path.curve(to: NSPoint(x: 22, y: h), controlPoint1: NSPoint(x: 16, y: h), controlPoint2: NSPoint(x: 19, y: h))
        }
        path.close()
        style.fillColor.setFill()
        path.fill()
    }

    /// The text view's own link plumbing — replaces a hand-rolled hitTest/glyph-rect stack.
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL, url.scheme == "side-mention" else { return false }
        let path = String(url.absoluteString.dropFirst("side-mention://".count))
            .removingPercentEncoding ?? ""
        guard !path.isEmpty else { return false }
        onMentionClicked?(path)
        return true
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityLabel() -> String? { plainText }
    /// The bubble speaks for its content, so the label inside it must not also be an element —
    /// otherwise VoiceOver reads every message twice (an audit caught exactly that).
    override func accessibilityChildren() -> [Any]? { [] }

    /// Parsed-markdown cache, keyed by text + style + text scale.
    ///
    /// Think re-renders every bubble whenever the stage is entered (it's a projection of the
    /// runner, not a retained view tree), and markdown parsing dominates that. A single large
    /// bubble — a compaction summary is thousands of characters — made entering Think stutter
    /// every time. Bounded so a long conversation can't turn the cache into the leak that
    /// `AgentSessionStore` was restructured to remove.
    private static var renderCache: [String: NSAttributedString] = [:]
    private static var renderCacheKeys: [String] = []
    private static let renderCacheLimit = 64

    private static func renderedMarkdown(_ text: String, style: Style) -> NSAttributedString {
        let key = "\(style)|\(DS.Text.Scale.current.rawValue)|\(text)"
        if let cached = renderCache[key] { return cached }
        let rendered = MarkdownRenderer.render(text, baseFont: DS.Text.body(), textColor: style.textColor)
        renderCache[key] = rendered
        renderCacheKeys.append(key)
        if renderCacheKeys.count > renderCacheLimit, let oldest = renderCacheKeys.first {
            renderCacheKeys.removeFirst()
            renderCache.removeValue(forKey: oldest)
        }
        return rendered
    }

    /// True while the text storage holds the plain streaming form rather than rendered markdown.
    private var isShowingStreamingPlainText = false

    func setBody(_ text: String, streaming: Bool = false) {
        // Mid-stream: plain text, appended. Replacing the whole attributed string per flush
        // invalidates and repaints the entire message — which read as the message "refreshing"
        // as it arrived. Appending only the delta leaves everything already on screen alone;
        // the markdown pass happens once, when the stream finishes.
        if streaming {
            let previous = plainText
            plainText = text
            let attrs: [NSAttributedString.Key: Any] = [.font: DS.Text.body(), .foregroundColor: style.textColor]
            if isShowingStreamingPlainText, text.hasPrefix(previous), let storage = bodyText.textStorage {
                let delta = String(text.dropFirst(previous.count))
                if !delta.isEmpty { storage.append(NSAttributedString(string: delta, attributes: attrs)) }
            } else {
                bodyText.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attrs))
                isShowingStreamingPlainText = true
            }
            // Measured with trailing newlines trimmed: the model often ends a chunk on "\n\n",
            // and sizing to it left a blank band at the bubble's bottom until the final render
            // stripped it.
            var trimmed = text
            while let last = trimmed.last, last.isNewline || last == " " { trimmed.removeLast() }
            fitToContent(NSAttributedString(string: trimmed, attributes: attrs), monotonicWidth: true)
            return
        }
        isShowingStreamingPlainText = false
        plainText = text
        let rendered = NSMutableAttributedString(attributedString: Self.renderedMarkdown(text, style: style))
        // The renderer terminates every block with "\n\n" — fine in a document preview, but in
        // a bubble that trailing run becomes visible empty space below the last line.
        while rendered.length > 0, let last = rendered.string.last, last.isNewline || last == " " {
            rendered.deleteCharacters(in: NSRange(location: rendered.length - 1, length: 1))
        }
        // Mentions read as references and act like them: tinted, underlined, and clickable
        // straight into Make — as real `.link` attributes, so the text view supplies the click
        // handling and cursor itself. Styling the *rendered* string keeps ranges aligned with
        // what's on screen after markdown processing.
        for range in FileMentionResolver.tokenRanges(in: rendered.string) {
            let token = (rendered.string as NSString).substring(with: range)
            let path = String(token.dropFirst())
            let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
            guard let url = URL(string: "side-mention://\(encoded)") else { continue }
            rendered.addAttributes([
                .link: url,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                // On the accent-filled sent bubble, accent-on-accent would vanish; white already
                // reads as emphasis there, so underline carries it instead.
                .foregroundColor: style == .sent ? NSColor.white : NSColor.controlAccentColor,
                .font: DS.Text.code(11.5, weight: .medium),
            ], range: range)
        }
        linkBarePaths(in: rendered)
        bodyText.textStorage?.setAttributedString(rendered)
        fitToContent(rendered, monotonicWidth: false)
    }

    private static let barePathPattern = try? NSRegularExpression(
        // Something/with/a/slash ending in .ext — the shape of a quoted project path. Existence
        // is checked before linking, so prose that merely looks path-ish stays prose.
        pattern: #"[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)+\.[A-Za-z0-9]{1,8}"#
    )

    /// The agent quotes paths constantly without `@` — those become the same live links a
    /// mention gets, but only when the file actually exists in the project.
    private func linkBarePaths(in rendered: NSMutableAttributedString) {
        guard let pathResolver, let regex = Self.barePathPattern else { return }
        let text = rendered.string as NSString
        for match in regex.matches(in: rendered.string, range: NSRange(location: 0, length: text.length)) {
            let range = match.range
            guard rendered.attribute(.link, at: range.location, effectiveRange: nil) == nil else { continue }
            let path = text.substring(with: range)
            guard pathResolver(path) else { continue }
            let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
            guard let url = URL(string: "side-mention://\(encoded)") else { continue }
            rendered.addAttributes([
                .link: url,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .foregroundColor: style == .sent ? NSColor.white : NSColor.controlAccentColor,
            ], range: range)
        }
    }

    /// Hug the content: measure against the cap and clamp the view to exactly what it needs —
    /// a short "ok" is a small pill, a long reply a full-width-capped block. Mid-stream the
    /// width only grows: re-measuring both directions as words arrive made the edge wobble.
    private func fitToContent(_ rendered: NSAttributedString, monotonicWidth: Bool) {
        let availableWidth = maxBubbleWidth - Self.insets.left - Self.insets.right
        let bounding = rendered.boundingRect(
            with: NSSize(width: availableWidth, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let measuredWidth = max(10, min(ceil(bounding.width) + 2, availableWidth))
        bodyWidthConstraint.constant = monotonicWidth ? max(bodyWidthConstraint.constant, measuredWidth) : measuredWidth
        bodyHeightConstraint.constant = max(10, ceil(bounding.height) + 1)
    }
}

/// One attached image in the transcript: rounded, capped, pinned to its sender's side. Sized
/// at init from the decoded image so layout never has to ask the bitmap anything again.
private final class ImageBubbleRowView: NSView {
    private let imageData: Data

    init(imageData: Data, alignRight: Bool) {
        self.imageData = imageData
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = DS.Radius.bubble
        imageView.layer?.masksToBounds = true
        var displaySize = NSSize(width: 160, height: 120)
        if let image = NSImage(data: imageData), image.size.width > 0, image.size.height > 0 {
            imageView.image = image
            let cap: CGFloat = 260
            let scale = min(1, min(cap / image.size.width, cap / image.size.height))
            displaySize = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        }
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: displaySize.width),
            imageView.heightAnchor.constraint(equalToConstant: displaySize.height),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            alignRight
                ? imageView.trailingAnchor.constraint(equalTo: trailingAnchor)
                : imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
        ])
        toolTip = "Click to open"
        setAccessibilityLabel("Attached image")
        setAccessibilityRole(.image)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        ImagePreviewOpener.open(data: imageData)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// A transparent full-width transcript row holding one bubble pinned to its side, plus the
/// hover-revealed Copy affordance sitting *outside* the bubble (inside, it collided with text
/// and got clipped by the bubble's rounded corners) — iMessage's "actions live beside the
/// bubble, not on it" arrangement.
private final class BubbleRowView: NSView {
    let bubble: TextBlockView
    private let copyButton = NSButton(title: "", target: nil, action: nil)
    private var trackingArea: NSTrackingArea?

    init(bubble: TextBlockView, alignRight: Bool) {
        self.bubble = bubble
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(bubble)

        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")?.withSymbolConfiguration(config)
        copyButton.isBordered = false
        copyButton.contentTintColor = .tertiaryLabelColor
        copyButton.alphaValue = 0
        copyButton.target = self
        copyButton.action = #selector(copyTapped)
        copyButton.toolTip = "Copy message"
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(copyButton)

        var constraints = [
            bubble.topAnchor.constraint(equalTo: topAnchor),
            bubble.bottomAnchor.constraint(equalTo: bottomAnchor),
            copyButton.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -6),
            copyButton.widthAnchor.constraint(equalToConstant: 22),
            copyButton.heightAnchor.constraint(equalToConstant: 22),
        ]
        if alignRight {
            constraints += [
                bubble.trailingAnchor.constraint(equalTo: trailingAnchor),
                bubble.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 60),
                copyButton.trailingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: -6),
            ]
        } else {
            constraints += [
                bubble.leadingAnchor.constraint(equalTo: leadingAnchor),
                bubble.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -60),
                copyButton.leadingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: 6),
            ]
        }
        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { copyButton.animator().alphaValue = 1 }
    override func mouseExited(with event: NSEvent) { copyButton.animator().alphaValue = 0 }

    @objc private func copyTapped() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(bubble.plainText, forType: .string)
        // Quick confirmation: the icon crossfades to a green check, then back — the "it worked"
        // beat every copy affordance owes the user.
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            copyButton.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self else { return }
            self.copyButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")?.withSymbolConfiguration(config)
            self.copyButton.contentTintColor = .systemGreen
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                self.copyButton.animator().alphaValue = 1
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
                guard let self else { return }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.15
                    self.copyButton.animator().alphaValue = 0
                } completionHandler: { [weak self] in
                    guard let self else { return }
                    let normalConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
                    self.copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")?.withSymbolConfiguration(normalConfig)
                    self.copyButton.contentTintColor = .tertiaryLabelColor
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.15
                        self.copyButton.animator().alphaValue = 1
                    }
                }
            }
        }
    }
}

/// The chat input: a rounded container that grows with its text (one to six lines), an embedded
/// circular send button that becomes a stop button while the agent is busy, Return to send and
/// Shift-Return for a newline — the input treatment every real chat app trains people to expect,
/// replacing the single-line text field + "Send" push button.
/// Finds the `@…` token under the caret. Not `rangeForUserCompletion` + `complete(_:)` — see
/// `MentionCompletionPopup` for why that approach was abandoned.



/// A segmented control whose selection *slides*: a Liquid Glass thumb springs between segments
/// instead of the stock control's instant swap. NSSegmentedControl has no animated selection and
/// no glass style, and this is the popover's whole feel — three of these in a row.
private final class SlidingSegmentedControl: NSView {
    var onChange: ((Int) -> Void)?
    private(set) var selectedIndex = 0
    var isEnabledControl = true {
        didSet { alphaValue = isEnabledControl ? 1 : 0.4 }
    }

    /// The glass rides inside a plain container, and the *container* is what animates: glass
    /// views don't reliably animate frame changes themselves, and animating a plain NSView with
    /// the glass autoresizing inside it does.
    private let thumbContainer = NSView()
    private let track = NSView()
    private var buttons: [NSButton] = []
    private var lastLayoutBounds = NSRect.zero

    init(titles: [String]) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        track.wantsLayer = true
        track.layer?.backgroundColor = DS.Color.scrimFaint.cgColor
        track.layer?.cornerRadius = 14
        addSubview(track)
        let glass = DS.makeGlass(cornerRadius: 12)
        glass.translatesAutoresizingMaskIntoConstraints = true
        glass.autoresizingMask = [.width, .height]
        thumbContainer.addSubview(glass)
        addSubview(thumbContainer)
        for (index, title) in titles.enumerated() {
            let button = NSButton(title: title, target: self, action: #selector(segmentTapped(_:)))
            button.isBordered = false
            button.font = DS.Text.control(.medium)
            button.tag = index
            addSubview(button)
            buttons.append(button)
        }
        heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Manual layout: equal-width segments, thumb under the selected one. Simpler and more
    // animatable than constraint juggling for a fixed-height three-way control.
    override func layout() {
        super.layout()
        track.frame = bounds
        let width = bounds.width / CGFloat(max(buttons.count, 1))
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(x: CGFloat(index) * width, y: 0, width: width, height: bounds.height)
        }
        // Snap the thumb only when the control actually resized. Unconditional placement here
        // is why the slide never showed: selecting a segment re-bolds a label, that schedules a
        // layout pass, and this line teleported the thumb to its destination mid-animation.
        if bounds != lastLayoutBounds {
            lastLayoutBounds = bounds
            thumbContainer.frame = thumbFrame(for: selectedIndex)
            thumbContainer.subviews.first?.frame = thumbContainer.bounds
        }
    }

    private func thumbFrame(for index: Int) -> NSRect {
        let width = bounds.width / CGFloat(max(buttons.count, 1))
        return NSRect(x: CGFloat(index) * width + 2, y: 2, width: width - 4, height: bounds.height - 4)
    }

    func select(_ index: Int, animated: Bool) {
        guard buttons.indices.contains(index) else { return }
        selectedIndex = index
        refreshTitles()
        guard animated else {
            thumbContainer.frame = thumbFrame(for: index)
            thumbContainer.subviews.first?.frame = thumbContainer.bounds
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.32
            // A slight overshoot on the way in — the same spring language as the pill press.
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 1.2, 0.35, 1)
            context.allowsImplicitAnimation = true
            thumbContainer.animator().frame = thumbFrame(for: index)
        }
    }

    private func refreshTitles() {
        for (index, button) in buttons.enumerated() {
            button.contentTintColor = index == selectedIndex ? .labelColor : .secondaryLabelColor
        }
    }

    @objc private func segmentTapped(_ sender: NSButton) {
        guard isEnabledControl, sender.tag != selectedIndex else { return }
        select(sender.tag, animated: true)
        onChange?(sender.tag)
    }
}


/// A menu-style row for an action popover: accent highlight on hover, the classic menu blink on
/// click. NSButton can't do either without fighting its cell, and the missing feedback was the
/// complaint — you couldn't tell which option you'd picked.
/// A rounded view whose backing layer is a bottom-up gradient wash of one color — the mode
/// indicator on the session pill. Layer-hosting so the gradient tracks the view's size for free.
private final class GradientEdgeView: NSView {
    private let gradient = CAGradientLayer()

    var color: NSColor = .clear {
        didSet { gradient.colors = [color.cgColor, NSColor.clear.cgColor] }
    }

    init(cornerRadius: CGFloat) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        // y=0 is the bottom in an unflipped layer: the wash rises from the bottom edge and is
        // gone by 80% of the height.
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 0.8)
        gradient.cornerRadius = cornerRadius
        gradient.masksToBounds = true
        layer = gradient
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class PopoverActionRow: NSView {
    private let highlight = NSView()
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let action: () -> Void
    private var trackingArea: NSTrackingArea?

    init(symbol: String, title: String, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        highlight.wantsLayer = true
        // Concentric with the popover's own corner: inner radius ≈ outer radius − inset. The
        // control token (6) was tuned for chips and read as a mismatched rectangle in here.
        highlight.layer?.cornerRadius = 8
        highlight.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        highlight.alphaValue = 0
        highlight.translatesAutoresizingMaskIntoConstraints = false
        addSubview(highlight)

        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
        icon.contentTintColor = .labelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)

        label.stringValue = title
        label.font = DS.Text.control()
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            highlight.topAnchor.constraint(equalTo: topAnchor),
            highlight.bottomAnchor.constraint(equalTo: bottomAnchor),
            highlight.leadingAnchor.constraint(equalTo: leadingAnchor),
            highlight.trailingAnchor.constraint(equalTo: trailingAnchor),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DS.Spacing.l),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: DS.Spacing.s),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -DS.Spacing.l),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setHighlighted(_ on: Bool) {
        highlight.alphaValue = on ? 1 : 0
        label.textColor = on ? .white : .labelColor
        icon.contentTintColor = on ? .white : .labelColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { setHighlighted(true) }
    override func mouseExited(with event: NSEvent) { setHighlighted(false) }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        // The menu blink — off, on, then act. Feedback that the click landed, before the
        // popover disappears out from under it.
        setHighlighted(false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            self?.setHighlighted(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) { self?.action() }
        }
    }
}

/// The + button's popover — the same presentation as the session pill, because it feels right:
/// anchored, arrowed, springy. Rows read like menu items but live in the popover material.
private final class PlusActionsViewController: NSViewController {
    var onAttach: (() -> Void)?
    var onAttachImage: (() -> Void)?
    var onCompact: (() -> Void)?
    var onNewConversation: (() -> Void)?

    override func loadView() { view = NSView() }

    override func viewDidLoad() {
        super.viewDidLoad()
        let rows = [
            PopoverActionRow(symbol: "photo", title: "Attach Image…") { [weak self] in self?.dismissThen(self?.onAttachImage) },
            PopoverActionRow(symbol: "at", title: "Add File Reference") { [weak self] in self?.dismissThen(self?.onAttach) },
            PopoverActionRow(symbol: "arrow.down.right.and.arrow.up.left", title: "Compact Conversation…") { [weak self] in self?.dismissThen(self?.onCompact) },
            PopoverActionRow(symbol: "square.and.pencil", title: "New Conversation…") { [weak self] in self?.dismissThen(self?.onNewConversation) },
        ]
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: DS.Spacing.m, left: DS.Spacing.m, bottom: DS.Spacing.m, right: DS.Spacing.m)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            view.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
        ])
        for row in rows {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -DS.Spacing.m * 2).isActive = true
        }
    }

    private func dismissThen(_ handler: (() -> Void)?) {
        view.window?.performClose(nil)
        handler?()
    }

}

/// The session pill's popover: model, thinking effort, tool scope, autonomy, and the context /
/// spend figures — as real macOS controls rather than stacked menus. Three-way choices are
/// segmented controls; the model list is a popup grouped by provider.
private final class SessionSettingsViewController: NSViewController {
    struct Snapshot {
        var providerId: String
        var modelId: String
        var isTrackSpecific: Bool
        var effort: AgentEffort
        var mode: AgentMode
        var usageLine: String
        var spendLine: String?
        var budgetLine: String?
    }

    var snapshot: Snapshot? { didSet { if isViewLoaded { apply() } } }
    /// nil/nil means "App Default."
    var onModelChosen: ((String?, String?) -> Void)?
    var onEffortChosen: ((AgentEffort) -> Void)?
    var onScopeChosen: ((AgentToolScope) -> Void)?
    var onAutonomyChosen: ((AgentAutonomy) -> Void)?

    private let modelPopup = NSPopUpButton()
    private let effortControl = SlidingSegmentedControl(titles: AgentEffort.allCases.map { $0 == .standard ? "Standard" : $0.shortLabel.capitalized })
    private let scopeControl = SlidingSegmentedControl(titles: AgentToolScope.allCases.map(\.displayName))
    private let autonomyControl = SlidingSegmentedControl(titles: AgentAutonomy.allCases.map { $0.shortLabel.capitalized })
    private let autonomyCaption = NSTextField(wrappingLabelWithString: "")
    private let usageLabel = NSTextField(labelWithString: "")
    private let spendLabel = NSTextField(labelWithString: "")
    private let budgetLabel = NSTextField(labelWithString: "")

    override func loadView() { view = NSView() }

    override func viewDidLoad() {
        super.viewDidLoad()

        func caption(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = DS.Text.micro()
            label.textColor = .tertiaryLabelColor
            return label
        }

        modelPopup.target = self
        modelPopup.action = #selector(modelChanged)

        effortControl.onChange = { [weak self] index in
            guard AgentEffort.allCases.indices.contains(index) else { return }
            self?.onEffortChosen?(AgentEffort.allCases[index])
        }
        scopeControl.onChange = { [weak self] index in
            guard AgentToolScope.allCases.indices.contains(index) else { return }
            self?.onScopeChosen?(AgentToolScope.allCases[index])
        }
        autonomyControl.onChange = { [weak self] index in
            guard AgentAutonomy.allCases.indices.contains(index) else { return }
            self?.onAutonomyChosen?(AgentAutonomy.allCases[index])
        }
        for control in [effortControl, scopeControl, autonomyControl] {
            control.widthAnchor.constraint(equalToConstant: 312).isActive = true
        }

        autonomyCaption.font = DS.Text.micro()
        autonomyCaption.textColor = .tertiaryLabelColor
        autonomyCaption.preferredMaxLayoutWidth = 300

        for label in [usageLabel, spendLabel, budgetLabel] {
            label.font = DS.Text.caption()
            label.textColor = .secondaryLabelColor
        }

        let separator = NSBox()
        separator.boxType = .separator

        let stack = NSStackView(views: [
            caption("MODEL"), modelPopup,
            caption("THINKING"), effortControl,
            caption("WHAT THE AGENT CAN DO"), scopeControl,
            caption("WITHOUT ASKING"), autonomyControl, autonomyCaption,
            separator, usageLabel, spendLabel, budgetLabel,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DS.Spacing.s
        stack.setCustomSpacing(DS.Spacing.xl, after: modelPopup)
        stack.setCustomSpacing(DS.Spacing.xl, after: effortControl)
        stack.setCustomSpacing(DS.Spacing.xl, after: scopeControl)
        stack.setCustomSpacing(DS.Spacing.xl, after: autonomyCaption)
        stack.edgeInsets = NSEdgeInsets(top: DS.Spacing.xxl, left: DS.Spacing.xxl, bottom: DS.Spacing.xxl, right: DS.Spacing.xxl)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            view.widthAnchor.constraint(greaterThanOrEqualToConstant: 340),
        ])
        apply()
    }

    private func apply() {
        guard let snapshot else { return }
        let registry = ProviderRegistryStore.shared

        modelPopup.removeAllItems()
        // Without this, NSMenu re-enables every item itself and the provider headers become
        // selectable rows, which is how a provider ended up choosable as a model.
        modelPopup.menu?.autoenablesItems = false
        // First row is "follow the app default" — a distinct state from "happens to match it."
        let defaultProvider = registry.provider(for: registry.activeProviderId)
        let defaultName = defaultProvider?.models.first { $0.id == defaultProvider?.defaultModelId }?.displayName ?? "default"
        modelPopup.addItem(withTitle: "App Default (\(defaultName))")
        modelPopup.lastItem?.representedObject = ["", ""]
        // Long lists: a separator between providers keeps the flat list scannable, and NSMenu
        // scrolls natively once it outgrows the screen — a provider with forty models is a
        // scrolling section, not a broken popover.
        for provider in registry.providers where !provider.models.isEmpty {
            modelPopup.menu?.addItem(.separator())
            if registry.providers.count > 1 {
                let header = NSMenuItem(title: provider.displayName, action: nil, keyEquivalent: "")
                header.isEnabled = false
                modelPopup.menu?.addItem(header)
            }
            for model in provider.models {
                modelPopup.addItem(withTitle: model.displayName)
                // Menu-only indentation under the provider header — leading spaces in the title
                // used to travel into the closed button's face.
                modelPopup.lastItem?.indentationLevel = registry.providers.count > 1 ? 1 : 0
                modelPopup.lastItem?.representedObject = [provider.id, model.id]
            }
        }
        if snapshot.isTrackSpecific {
            let index = (0..<modelPopup.numberOfItems).first { index in
                (modelPopup.item(at: index)?.representedObject as? [String]) == [snapshot.providerId, snapshot.modelId]
            }
            modelPopup.selectItem(at: index ?? 0)
        } else {
            modelPopup.selectItem(at: 0)
        }

        let animated = view.window != nil
        effortControl.select(AgentEffort.allCases.firstIndex(of: snapshot.effort) ?? 0, animated: animated)
        scopeControl.select(AgentToolScope.allCases.firstIndex(of: snapshot.mode.scope) ?? 0, animated: animated)
        autonomyControl.select(AgentAutonomy.allCases.firstIndex(of: snapshot.mode.autonomy) ?? 0, animated: animated)
        // Nothing to auto-approve in a read-only scope — dimmed rather than hidden, so the
        // axis doesn't appear to vanish when someone switches to Ask.
        autonomyControl.isEnabledControl = snapshot.mode.autonomyIsMeaningful
        autonomyCaption.stringValue = snapshot.mode.autonomyIsMeaningful
            ? snapshot.mode.autonomy.displayName
            : "Autonomy applies in Build — read-only scopes have nothing to auto-approve."

        usageLabel.stringValue = snapshot.usageLine
        spendLabel.stringValue = snapshot.spendLine ?? ""
        spendLabel.isHidden = snapshot.spendLine == nil
        budgetLabel.stringValue = snapshot.budgetLine ?? ""
        budgetLabel.isHidden = snapshot.budgetLine == nil
        budgetLabel.textColor = .systemOrange
    }

    @objc private func modelChanged() {
        guard let pair = modelPopup.selectedItem?.representedObject as? [String], pair.count == 2 else { return }
        if pair[0].isEmpty { onModelChosen?(nil, nil) } else { onModelChosen?(pair[0], pair[1]) }
    }



}

/// One control of the composer's bottom row: a small icon-plus-word capsule that pops a menu.
///
/// Not an `NSPopUpButton`. The pull-downs this replaces carried AppKit's arrow-and-bezel
/// styling, crowded titles ("Anthropic · Claude Sonnet 5 · low"), and menus that mixed two
/// decisions each — the visual noise being complained about was mostly *them*. A chip shows one
/// short fact, reveals it's interactive on hover, and owns exactly one menu. The menu pops from
/// the action (mouse-up), which is what makes an upward menu survive — popping from `mouseDown`
/// gets dismissed by its own mouse-up, the failure recorded in the design charter.
private final class ChipButton: NSButton {
    var menuProvider: (() -> NSMenu)?
    /// Alternative to `menuProvider` for chips that present something other than a menu.
    var onPress: (() -> Void)?
    /// The glass view rendered behind this button, so the press spring moves both as one object.
    weak var glassBackdrop: NSView?
    /// Anything else layered on the pill (the mode-tint wash) that must dip and spring with it.
    weak var companionOverlay: NSView?
    /// Hover pill for bare chips; off for buttons that sit on their own glass, where a
    /// rounded-rect hover inside a capsule reads as a seam (the exact complaint).
    var showsHover = false
    private var tracking: NSTrackingArea?

    init(symbolName: String?, accessibilityLabel: String) {
        super.init(frame: .zero)
        isBordered = false
        title = ""  // NSButton's default title is literally "Button"
        imagePosition = symbolName == nil ? .noImage : .imageLeading
        font = DS.Text.caption(.medium)
        contentTintColor = .secondaryLabelColor
        wantsLayer = true
        layer?.cornerRadius = DS.Radius.control
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 24).isActive = true
        setAccessibilityLabel(accessibilityLabel)
        if let symbolName { setSymbol(symbolName) }
        target = self
        action = #selector(pressed)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setSymbol(_ name: String, pointSize: CGFloat = 10.5) {
        image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium))
    }

    func setLabel(_ text: String, tint: NSColor = .secondaryLabelColor) {
        title = text.isEmpty ? "" : " \(text) "
        contentTintColor = tint
    }

    /// The Liquid Glass press, in two halves. Press: the pill eases down to 93% and *stays*
    /// there while the mouse is held — the "pushed back" state. Release: it springs out with a
    /// small overshoot. Both halves apply to the button and its glass together, so the whole
    /// pill moves as one object.
    ///
    /// `mouseDown` blocks in NSButton's tracking loop until release, which is exactly the shape
    /// this needs: dip before, release after, action (menu/popover) in between — Core Animation
    /// runs on the render server, so the release bounce plays even while a popped menu blocks
    /// the run loop.
    override func mouseDown(with event: NSEvent) {
        pressDown(self)
        if let glassBackdrop { pressDown(glassBackdrop) }
        if let companionOverlay { pressDown(companionOverlay) }
        super.mouseDown(with: event)
        pressRelease(self)
        if let glassBackdrop { pressRelease(glassBackdrop) }
        if let companionOverlay { pressRelease(companionOverlay) }
    }

    @objc private func pressed() {
        if let onPress { return onPress() }
        guard let menu = menuProvider?() else { return }
        // NSButton is *flipped*, so "above" is negative y.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -menu.size.height - DS.Spacing.s), in: self)
    }

    private func centeredLayer(_ view: NSView) -> CALayer? {
        view.wantsLayer = true
        guard let layer = view.layer else { return nil }
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: view.frame.midX, y: view.frame.midY)
        return layer
    }

    private func pressDown(_ view: NSView) {
        guard let layer = centeredLayer(view) else { return }
        layer.removeAnimation(forKey: "springRelease")
        let dip = CABasicAnimation(keyPath: "transform.scale")
        dip.toValue = 0.93
        dip.duration = 0.16
        dip.timingFunction = CAMediaTimingFunction(name: .easeOut)
        // Held, not removed: the pill stays pushed back for as long as the mouse is down.
        dip.fillMode = .forwards
        dip.isRemovedOnCompletion = false
        layer.add(dip, forKey: "springDown")
    }

    private func pressRelease(_ view: NSView) {
        guard let layer = centeredLayer(view) else { return }
        layer.removeAnimation(forKey: "springDown")
        let spring = CAKeyframeAnimation(keyPath: "transform.scale")
        spring.values = [0.93, 1.04, 0.99, 1]
        spring.keyTimes = [0, 0.45, 0.8, 1]
        spring.duration = 0.36
        spring.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeOut),
        ]
        layer.add(spring, forKey: "springRelease")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        if showsHover { layer?.backgroundColor = DS.Color.scrimSoft.cgColor }
    }
    override func mouseExited(with event: NSEvent) { layer?.backgroundColor = nil }
}

private final class ComposerTextView: NSTextView {
    /// Handles images pasted or dropped into the field; returns true when consumed. Set by
    /// ComposerView, which owns the attachment strip.
    var onImagesDropped: (([NSImage]) -> Bool)?

    private static func imageURLs(on pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]
        return (pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]) ?? []
    }

    /// ⌘V with a screenshot on the clipboard attaches it. Text still wins when both are
    /// present (copying from a browser often carries both) — attaching is only for pastes
    /// that would otherwise do nothing.
    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        var images = Self.imageURLs(on: pasteboard).compactMap { NSImage(contentsOf: $0) }
        if images.isEmpty, pasteboard.string(forType: .string) == nil {
            images = (pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage]) ?? []
        }
        if !images.isEmpty, onImagesDropped?(images) == true { return }
        super.paste(sender)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if !Self.imageURLs(on: sender.draggingPasteboard).isEmpty { return .copy }
        return super.draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let images = Self.imageURLs(on: sender.draggingPasteboard).compactMap { NSImage(contentsOf: $0) }
        if !images.isEmpty, onImagesDropped?(images) == true { return true }
        return super.performDragOperation(sender)
    }

    /// Drawn by the text view itself at the glyph origin the layout manager uses, so it can
    /// never disagree with the insertion point — the overlay-label approach kept drifting by a
    /// couple of points (the label cell pads its title rect; the container inset doesn't).
    var placeholderString: String = ""
    var showsPlaceholder = true

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, showsPlaceholder, !placeholderString.isEmpty else { return }
        let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0),
                             y: textContainerInset.height)
        NSAttributedString(string: placeholderString, attributes: [
            .font: font ?? DS.Text.body(),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]).draw(at: origin)
    }

    /// The range of the mention being typed, or nil when the caret isn't inside one. Extends back
    /// to the `@` so `@src/deep/nes` is one token rather than stopping at each `/`.
    /// The `/command` token being typed, or nil. Only at the very start of the message — a
    /// slash mid-sentence is a path or a date, and hijacking it would make "src/main.c" untypable.
    var slashRange: NSRange? {
        let text = string as NSString
        guard text.length > 0, text.character(at: 0) == unichar(UInt8(ascii: "/")) else { return nil }
        let caret = selectedRange().location
        var end = 0
        while end < text.length {
            guard let scalar = Unicode.Scalar(text.character(at: end)),
                  !CharacterSet.whitespacesAndNewlines.contains(scalar) else { break }
            end += 1
        }
        guard caret <= end else { return nil }
        return NSRange(location: 0, length: end)
    }

    var mentionRange: NSRange? {
        let text = string as NSString
        let caret = selectedRange().location
        guard caret > 0, caret <= text.length else { return nil }
        var index = caret - 1
        while index >= 0 {
            let character = text.character(at: index)
            if character == unichar(UInt8(ascii: "@")) {
                // An `@` inside a word (an email address) isn't a mention.
                if index > 0, let previous = Unicode.Scalar(text.character(at: index - 1)),
                   !CharacterSet.whitespacesAndNewlines.contains(previous) {
                    return nil
                }
                return NSRange(location: index, length: caret - index)
            }
            if let scalar = Unicode.Scalar(character), CharacterSet.whitespacesAndNewlines.contains(scalar) {
                return nil
            }
            index -= 1
        }
        return nil
    }
}

/// A queued image in the composer: 48pt rounded thumbnail with an always-visible ✕. No hover
/// dance — on a surface this small, discoverable beats tidy.
private final class AttachmentChipView: NSView {
    private let onPreview: () -> Void
    private let onRemove: () -> Void

    init(thumbnail: NSImage, onPreview: @escaping () -> Void, onRemove: @escaping () -> Void) {
        self.onPreview = onPreview
        self.onRemove = onRemove
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let imageView = NSImageView()
        imageView.image = thumbnail
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = DS.Radius.control
        imageView.layer?.masksToBounds = true
        imageView.layer?.borderWidth = 1
        imageView.layer?.borderColor = NSColor.separatorColor.cgColor
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)

        let removeButton = NSButton(title: "", target: self, action: #selector(removeTapped))
        removeButton.isBordered = false
        removeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove attachment")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        removeButton.contentTintColor = .secondaryLabelColor
        removeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(removeButton)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 48),
            heightAnchor.constraint(equalToConstant: 48),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            removeButton.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            removeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func removeTapped() { onRemove() }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPreview()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// Opens image bytes in the system viewer via a temp file — a full in-app lightbox isn't
/// worth building until something needs more than "let me look at that closely."
enum ImagePreviewOpener {
    static func open(data: Data, mediaType: String? = nil) {
        let ext: String
        if let mediaType {
            ext = mediaType == "image/png" ? "png" : "jpg"
        } else {
            // Sniff PNG's signature; everything else we produce is JPEG.
            ext = data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "png" : "jpg"
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("side-image-\(UUID().uuidString).\(ext)")
        guard (try? data.write(to: url)) != nil else { return }
        NSWorkspace.shared.open(url)
    }
}

private final class ComposerView: NSView, NSTextViewDelegate {
    /// One handler for the button and Return alike — the owner decides whether that means
    /// send or stop based on the runner's phase.
    var onAction: (() -> Void)?
    /// Shift+Tab — cycle the agent's tool scope without leaving the keyboard.
    var onCycleMode: (() -> Void)?

    private let textView = ComposerTextView()

    /// One image queued for the next send — already downscaled and encoded.
    private struct ImageAttachment {
        let id = UUID()
        let data: Data
        let mediaType: String
        let thumbnail: NSImage
    }
    private var attachments: [ImageAttachment] = []
    private let attachmentStrip = NSStackView()
    private var stripHeightConstraint: NSLayoutConstraint!
    private var stripTopConstraint: NSLayoutConstraint!
    var hasAttachments: Bool { !attachments.isEmpty }
    /// Supplies `@`-mention candidates. Set by the owner, which knows the track's working
    /// directory; nil until then, and completion simply does nothing in that case.
    var mentionCandidates: ((String) -> [String])?
    /// Slash commands: candidates for a typed prefix (rows shown as "/name — what it does"),
    /// and the handler that runs one. Set by the owner, which knows what the commands mean.
    var slashCandidates: ((String) -> [String])?
    var onSlashCommand: ((String) -> Void)?
    private let mentionPopup = MentionCompletionPopup()
    /// Whether the popup currently holds slash commands (accepting runs one) rather than
    /// mention paths (accepting inserts one).
    private var popupShowsCommands = false
    /// True from mic-tap until text arrives (or the field is cleared) — keeps the placeholder
    /// from sitting underneath dictation's glowing cursor.
    private var isDictating = false
    private let scroll = NSScrollView()

    private let actionButton = CircularIconButton(diameter: 28)
    private let micButton = NSButton()
    private var textHeightConstraint: NSLayoutConstraint!
    /// Includes the text container's own 8pt vertical padding each side.
    private static let minTextHeight: CGFloat = 36
    private static let maxTextHeight: CGFloat = 136
    /// Half the single-row height: 36pt text area + 4pt scroll insets each side = 44.
    static let capsuleRadius: CGFloat = 22

    var text: String { textView.string }

    var placeholder: String = "" {
        didSet {
            textView.placeholderString = placeholder
            textView.needsDisplay = true
        }
    }

    var isEnabled: Bool = true {
        didSet {
            textView.isEditable = isEnabled
            actionButton.isEnabled = isEnabled
            alphaValue = isEnabled ? 1 : 0.6
        }
    }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        // The composer is *itself* the glass capsule — one pill, no pill-inside-a-pill. The +
        // button lives outside in the stage on its own glass circle, as Messages arranges it.
        let glass = DS.makeGlass(cornerRadius: Self.capsuleRadius)
        addSubview(glass)

        textView.font = DS.Text.body()
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.delegate = self
        mentionPopup.onAccept = { [weak self] row in
            guard let self else { return }
            if self.popupShowsCommands {
                // Rows read "/name — description"; the name is the command.
                let name = String(row.split(separator: " ").first?.dropFirst() ?? "")
                self.clear()
                self.onSlashCommand?(name)
            } else {
                self.insertMention(row)
            }
        }
        // Vertical inset computed so one line of the actual font sits centered in the
        // single-line band — a fixed 8pt left the text riding high once the font shrank to the
        // body role (36 - ~16 line = 20 of slack, split 8/12 toward the top).
        let lineHeight = ceil(NSLayoutManager().defaultLineHeight(for: textView.font ?? DS.Text.body()))
        textView.textContainerInset = NSSize(width: 12, height: max(8, (Self.minTextHeight - lineHeight) / 2))
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.autoresizingMask = [.width]
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        micButton.isBordered = false
        micButton.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Dictate")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
        micButton.contentTintColor = .tertiaryLabelColor
        micButton.target = self
        micButton.action = #selector(micTapped)
        micButton.toolTip = "Dictate"
        micButton.translatesAutoresizingMaskIntoConstraints = false

        actionButton.setGradientFill(.controlAccentColor)
        actionButton.target = self
        actionButton.action = #selector(actionTapped)
        setBusy(false)

        attachmentStrip.orientation = .horizontal
        attachmentStrip.alignment = .centerY
        attachmentStrip.spacing = DS.Spacing.s
        attachmentStrip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(attachmentStrip)
        textView.onImagesDropped = { [weak self] images in
            guard let self, !images.isEmpty else { return false }
            for image in images { self.addImageAttachment(image) }
            return true
        }

        addSubview(scroll)
        addSubview(micButton)
        addSubview(actionButton)
        textHeightConstraint = scroll.heightAnchor.constraint(equalToConstant: Self.minTextHeight)
        stripHeightConstraint = attachmentStrip.heightAnchor.constraint(equalToConstant: 0)
        stripTopConstraint = attachmentStrip.topAnchor.constraint(equalTo: topAnchor, constant: 0)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            textHeightConstraint,
            // The scroll hugs the capsule and the padding lives *inside* the text container:
            // dictation draws a glow around the insertion cursor, and with the old tight scroll
            // frame that glow clipped on every edge. Same visual text position, more headroom.
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DS.Spacing.s),
            scroll.trailingAnchor.constraint(equalTo: micButton.leadingAnchor, constant: -2),
            // The attachment strip sits above the text inside the same capsule; both its
            // height and its top pad collapse to zero when nothing is attached, so the empty
            // composer's geometry is untouched.
            stripTopConstraint,
            stripHeightConstraint,
            // Same x as the first glyph of the text: the scroll's inset plus the container's.
            attachmentStrip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DS.Spacing.s + 12),
            attachmentStrip.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: attachmentStrip.bottomAnchor, constant: DS.Spacing.xs),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -DS.Spacing.xs),
            // Mic and send are centered on the *single-line band* — the bottom capsule-height of
            // the field — not inset from the bottom edge, which is what left them sitting low.
            // As the field grows they stay pinned to that band, like Messages.
            micButton.trailingAnchor.constraint(equalTo: actionButton.leadingAnchor, constant: -DS.Spacing.m),
            micButton.centerYAnchor.constraint(equalTo: bottomAnchor, constant: -Self.capsuleRadius),
            actionButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DS.Spacing.m),
            actionButton.centerYAnchor.constraint(equalTo: bottomAnchor, constant: -Self.capsuleRadius),
        ])
    }

    // MARK: - Image attachments

    /// Downscales, encodes, and queues an image for the next send, with a removable chip in
    /// the strip. Encoding happens here — at attach time, once — not at send time.
    ///
    /// Chips are added and removed *individually*, never rebuilt wholesale: tearing the strip
    /// down and re-adding every chip replayed the appear animation on images that hadn't
    /// changed, and the double layout pass read as a flicker on collapse.
    func addImageAttachment(_ image: NSImage) {
        guard let encoded = Self.encodeForUpload(image) else { return }
        let attachment = ImageAttachment(data: encoded.data, mediaType: encoded.mediaType, thumbnail: encoded.thumbnail)
        attachments.append(attachment)
        let chip = AttachmentChipView(
            thumbnail: attachment.thumbnail,
            onPreview: { ImagePreviewOpener.open(data: attachment.data, mediaType: attachment.mediaType) },
            onRemove: { [weak self] in self?.removeAttachment(id: attachment.id) }
        )
        chip.identifier = NSUserInterfaceItemIdentifier(attachment.id.uuidString)
        attachmentStrip.addArrangedSubview(chip)
        updateStripSpace(animated: true)
        DS.Motion.appear(chip)
    }

    func attachmentPayloads() -> [AgentImageAttachment] {
        attachments.map { AgentImageAttachment(mediaType: $0.mediaType, base64: $0.data.base64EncodedString()) }
    }

    private func removeAttachment(id: UUID) {
        attachments.removeAll { $0.id == id }
        guard let chip = attachmentStrip.arrangedSubviews.first(where: { $0.identifier?.rawValue == id.uuidString }) else {
            return updateStripSpace(animated: true)
        }
        // The object leaves, then the space closes — a short fade first, so the collapse never
        // shows a band of empty strip where the chip just was.
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            chip.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            chip.removeFromSuperview()
            self?.updateStripSpace(animated: true)
        })
    }

    /// Opens or closes the strip's slot in the capsule. The grow/shrink is a layout shift right
    /// under the cursor — animated so it reads as the composer making room, not jumping.
    private func updateStripSpace(animated: Bool) {
        let targetHeight: CGFloat = attachments.isEmpty ? 0 : 48
        let targetTop: CGFloat = attachments.isEmpty ? 0 : DS.Spacing.m
        guard stripHeightConstraint.constant != targetHeight || stripTopConstraint.constant != targetTop else { return }
        guard animated else {
            stripHeightConstraint.constant = targetHeight
            stripTopConstraint.constant = targetTop
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            stripHeightConstraint.constant = targetHeight
            stripTopConstraint.constant = targetTop
            superview?.layoutSubtreeIfNeeded()
        }
    }

    /// Longest side capped at 1568px (the API's documented sweet spot — anything bigger is
    /// downscaled server-side anyway, after being paid for). PNG when there's alpha,
    /// JPEG otherwise; a retina screenshot lands in the low hundreds of KB.
    private static func encodeForUpload(_ image: NSImage) -> (data: Data, mediaType: String, thumbnail: NSImage)? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              cg.width > 0, cg.height > 0 else { return nil }
        let scale = min(1, 1568 / CGFloat(max(cg.width, cg.height)))
        let targetWidth = max(1, Int(CGFloat(cg.width) * scale))
        let targetHeight = max(1, Int(CGFloat(cg.height) * scale))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: targetWidth, pixelsHigh: targetHeight,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = NSSize(width: targetWidth, height: targetHeight)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            .draw(in: NSRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        NSGraphicsContext.restoreGraphicsState()
        let alphaInfo = cg.alphaInfo
        let hasAlpha = !(alphaInfo == .none || alphaInfo == .noneSkipLast || alphaInfo == .noneSkipFirst)
        let encoded: (Data, String)?
        if hasAlpha, let png = rep.representation(using: .png, properties: [:]) {
            encoded = (png, "image/png")
        } else if let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
            encoded = (jpeg, "image/jpeg")
        } else {
            encoded = nil
        }
        guard let (data, mediaType) = encoded, let thumbnail = NSImage(data: data) else { return nil }
        return (data, mediaType, thumbnail)
    }

    /// System dictation into the field — the same thing Edit → Start Dictation does. Honest
    /// speech-to-text without shipping a speech stack; a real transcription pipeline can replace
    /// it later without the button moving.
    @objc private func micTapped() {
        window?.makeFirstResponder(textView)
        // The placeholder has to go *now*: dictation draws its glowing insertion cursor at the
        // text origin, and the placeholder sat under it until the first words arrived. (The
        // startup delay itself is macOS spinning up the dictation service — not ours to fix.)
        isDictating = true
        textView.showsPlaceholder = false
        textView.needsDisplay = true
        NSApp.sendAction(Selector(("startDictation:")), to: nil, from: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func clear() {
        // Sending has to take the candidate list down with it, or it hangs over an empty field.
        isDictating = false
        mentionPopup.hide()
        // No animation on send: the whole composer resets at once, same as the text clearing.
        attachments.removeAll()
        attachmentStrip.arrangedSubviews.forEach { $0.removeFromSuperview() }
        updateStripSpace(animated: false)
        textView.string = ""
        textDidChange(Notification(name: NSText.didChangeNotification))
    }

    func focus() {
        window?.makeFirstResponder(textView)
    }

    /// Types on the user's behalf — used by the + menu to start an @-mention, which then opens
    /// the same completion popup typing it by hand would.
    func insertText(_ text: String) {
        textView.insertText(text, replacementRange: textView.selectedRange())
    }

    /// The send button carries the scope color — the thing you look at as you commit a message.
    func setModeTint(_ color: NSColor) {
        actionButton.setGradientFill(color)
    }

    func setBusy(_ busy: Bool) {
        actionButton.setSymbol(busy ? "stop.fill" : "arrow.up", pointSize: 11, weight: .bold, color: .white, accessibilityLabel: busy ? "Stop" : "Send")
    }

    @objc private func actionTapped() { onAction?() }

    func textDidChange(_ notification: Notification) {
        if !textView.string.isEmpty { isDictating = false }
        textView.showsPlaceholder = !isDictating
        textView.needsDisplay = true
        updateMentionPopup()
        highlightMentions()
        guard let layoutManager = textView.layoutManager, let textContainer = textView.textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer).height + textView.textContainerInset.height * 2
        let target = min(max(used, Self.minTextHeight), Self.maxTextHeight)
        if textHeightConstraint.constant != target {
            textHeightConstraint.constant = target
            scroll.hasVerticalScroller = target >= Self.maxTextHeight
        }
    }

    /// Return sends, Shift-Return inserts the newline.
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // While the list is up it owns the arrows, Return, Tab, and Escape — anything else falls
        // through to normal editing, so typing never stops working.
        if mentionPopup.isVisible {
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                mentionPopup.moveSelection(by: -1)
                return true
            case #selector(NSResponder.moveDown(_:)):
                mentionPopup.moveSelection(by: 1)
                return true
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
                mentionPopup.acceptSelection()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                mentionPopup.hide()
                return true
            default:
                break
            }
        }
        if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
            onCycleMode?()
            return true
        }
        guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { return false }
        onAction?()
        return true
    }

    /// Tints `@…` tokens so a mention reads as a reference rather than as prose.
    ///
    /// Applied as *temporary* layout attributes, not to the text storage: editing storage inside
    /// a change notification is how the earlier recursion crash happened, and temporary
    /// attributes exist precisely for transient styling like this. They also can't end up in the
    /// text the user copies out.
    private func highlightMentions() {
        guard let layoutManager = textView.layoutManager else { return }
        let full = NSRange(location: 0, length: (textView.string as NSString).length)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
        for range in FileMentionResolver.tokenRanges(in: textView.string) {
            layoutManager.addTemporaryAttributes([
                .foregroundColor: NSColor.controlAccentColor,
                .backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.12),
            ], forCharacterRange: range)
        }
    }

    /// Shows or hides the candidate list for whatever mention is under the caret. Only ever
    /// *displays* — the text is untouched until someone accepts a row, which is what keeps this
    /// from fighting the keystrokes that triggered it.
    private func updateMentionPopup() {
        // A leading "/" is a command, and wins over mentions — same immediate-open rule as `@`.
        if let slash = textView.slashRange, let slashCandidates {
            let partial = String((textView.string as NSString).substring(with: slash).dropFirst())
            let commands = slashCandidates(partial)
            guard !commands.isEmpty else { return mentionPopup.hide() }
            popupShowsCommands = true
            mentionPopup.truncatesHead = false
            var caretRect = textView.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
            if caretRect == .zero { caretRect = window?.convertToScreen(convert(bounds, to: nil)) ?? .zero }
            mentionPopup.show(candidates: commands, below: caretRect, parent: window)
            return
        }
        popupShowsCommands = false
        mentionPopup.truncatesHead = true
        // `length >= 1` — a bare `@` opens the list immediately, which is what every other
        // harness does and what someone typing `@` is asking for.
        guard let range = textView.mentionRange, range.length >= 1, let mentionCandidates else {
            return mentionPopup.hide()
        }
        let token = (textView.string as NSString).substring(with: range)
        let partial = String(token.dropFirst())
        let matches = mentionCandidates(partial)
        guard !matches.isEmpty else { return mentionPopup.hide() }

        // Positioned against the caret's own rect so the list tracks the text, not the field.
        var caretRect = textView.firstRect(forCharacterRange: NSRange(location: range.location, length: 0), actualRange: nil)
        if caretRect == .zero { caretRect = window?.convertToScreen(convert(bounds, to: nil)) ?? .zero }
        mentionPopup.show(candidates: matches, below: caretRect, parent: window)
    }

    /// Replaces the typed token with the accepted path, plus a trailing space so the next word
    /// isn't swallowed into the mention.
    private func insertMention(_ path: String) {
        guard let range = textView.mentionRange else { return }
        let replacement = "@\(path) "
        if textView.shouldChangeText(in: range, replacementString: replacement) {
            textView.replaceCharacters(in: range, with: replacement)
            textView.didChangeText()
        }
        textView.setSelectedRange(NSRange(location: range.location + (replacement as NSString).length, length: 0))
    }
}
