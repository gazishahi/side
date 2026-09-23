import AppKit
import Heron
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
    private var composerBottom: NSLayoutConstraint!
    private let changesGroup = NSView()
    private let sessionGroup = NSView()
    private var undockedPillConstraints: [NSLayoutConstraint] = []
    private var editingChipLeading: NSLayoutConstraint!
    private var pillsDocked = false
    /// The band at the bottom of the window something else is drawn over; the composer sits
    /// above it. Zero when nothing is.
    private var bottomObstruction: CGFloat = 0
    /// The conversation's title, shown in the window's top row (Direction 02 §3.2).
    private let conversationTitle = NSTextField(labelWithString: "")
    /// The composer holds text while focused — the window's chrome recedes then.
    var onComposerEngagedChanged: ((Bool) -> Void)?
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
    // No symbol: the coloured +/− counts already say what this is, and a glyph beside them
    // is one more thing competing for the glance.
    private let changesPill = ChipButton(symbolName: nil, accessibilityLabel: "Files changed in this conversation")
    private let changesPillGlass = DS.makeGlass(cornerRadius: 14)
    /// The pending queued message, shown above the composer while a turn is running.
    private let queuedChip = ChipButton(symbolName: "clock", accessibilityLabel: "Queued message — click to edit")
    private let queuedChipGlass = DS.makeGlass(cornerRadius: 14)
    private let editingChip = ChipButton(symbolName: "pencil", accessibilityLabel: "Editing a sent message — click to cancel")
    private let editingChipGlass = DS.makeGlass(cornerRadius: 14)
    /// A soft wash rising from the pill's bottom edge in the current scope's color.
    private let pillModeTint = GradientEdgeView(cornerRadius: 14)
    private var sessionPopover: NSPopover?
    /// The + button: outside the composer on its own glass circle, exactly as Messages places
    /// it. Attach-like actions plus the rare conversation-level ones.
    private let plusButton = ChipButton(symbolName: "plus", accessibilityLabel: "Add a file reference, or manage this conversation")
    private let plusGlass = DS.makeGlass(cornerRadius: 19)
    /// The explainer lives here now — visible only while there's nothing else to look at,
    /// instead of as a permanent first line of every conversation.
    /// One sentence and the one action that fixes it (§6): open a project, initialise git, start
    /// a track — Think works on a track — or, on a track with nothing said yet, just a line.
    private let emptyState = DS.EmptyState()
    /// Set by the shell, which performs empty-state actions.
    var onEmptyStateAction: ((EmptyStateAction) -> Void)?
    /// The active provider can take a message. Read on attach and whenever the window becomes
    /// main again (Preferences closing is the usual reason it changed); not per keystroke — it's a
    /// Keychain read.
    private var modelReady = true
    private var mainWindowObserver: NSObjectProtocol?

    private var runnerManager: AgentRunnerManager?
    /// Which project's usage the header reports — set alongside `runnerManager`.
    private var projectPath: String?
    /// Where a track's model choice lives. Weak isn't needed — `TrackStore` outlives this view
    /// (it's owned by `ProjectContext`), and this is reassigned on every `configure`.
    private var trackStore: TrackStore?
    /// Backs `@`-mention completion. Rebuilt when the attached track's working directory
    /// changes — a track's worktree is its own directory, so the candidate list has to follow.
    private let fileIndex = ProjectFileIndex()
    private var fileIndexRefresh: DispatchWorkItem?
    private var usageObserverToken: UUID?
    /// Set by `ShellViewController` — Think can't reach Make directly, and shouldn't.
    var onRevealFileRequested: ((URL) -> Void)?
    /// A mention with a line range (`@path#L12-L40`) opens at its first line.
    var onRevealFileAtLineRequested: ((URL, Int) -> Void)?
    /// Set by the shell: switches the window to the Review stage, where checkpoints hold the
    /// durable record of what changed.
    var onOpenReviewRequested: (() -> Void)?
    /// Set by the shell: to the Run stage, where the command's terminal is.
    var onOpenRunRequested: (() -> Void)?
    /// Set by the shell: presents a checkpoint's files and diff as a sheet over Think (§5.1).
    var onOpenCheckpointRequested: ((UUID) -> Void)?
    /// Branch-name key, "" for "no active track" — same convention as Make/Run.
    private var attachedTrackKey: String?
    private var runner: (any Harness)?
    /// Which engine this view is attached to (nil for Heron) — the shell compares it with the
    /// track's choice to know when to reattach.
    var attachedHarnessName: String? { runner?.harnessName }
    private var observerToken: UUID?
    /// Parallel to `runner.entries` — the view currently rendering each entry, so a streamed
    /// delta or a proposal resolution can update one block in place instead of rebuilding the
    /// whole transcript on every token.
    private var entryViews: [NSView] = []
    /// The open "Worked…" group collecting consecutive tool lines; closed by any non-tool
    /// entry or by the run finishing.
    private weak var currentWorkGroup: WorkGroupView?
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
        composer.onSetUpModel = { [weak self] in self?.onEmptyStateAction?(.setUpModel) }
        composer.onCycleMode = { [weak self] in self?.cycleScope() }
        composer.onEscape = { [weak self] in self?.escapePressed() ?? false }
        composer.onEngagedChanged = { [weak self] engaged in self?.onComposerEngagedChanged?(engaged) }
        // Newest first, deduplicated: pressing Up three times to get past the same message
        // repeated is friction, not history.
        composer.messageHistory = { [weak self] in
            guard let entries = self?.runner?.entries else { return [] }
            var seen: Set<String> = []
            var result: [String] = []
            for entry in entries.reversed() {
                guard case .userText(let text) = entry.kind else { continue }
                guard seen.insert(text).inserted else { continue }
                result.append(text)
            }
            return result
        }
        view.addSubview(composer)
        // Added after the scroll view on purpose: everything down here floats over the
        // transcript, and subview order is what keeps scrolled bubbles from painting across it.
        view.addSubview(plusGlass)
        view.addSubview(plusButton)
        // Each pill travels with its glass as one group, so the window's bar can take the pair
        // into its row (see `barAccessories`) without the pill leaving its backdrop behind.
        for group in [changesGroup, sessionGroup] {
            group.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(group)
        }
        sessionGroup.addSubview(sessionPillGlass)
        sessionGroup.addSubview(pillModeTint)
        sessionGroup.addSubview(sessionPill)
        changesPill.glassBackdrop = changesPillGlass
        changesPill.onPress = { [weak self] in self?.showChangedFiles() }
        changesPill.toolTip = "What this conversation changed"
        changesPill.isHidden = true
        changesPillGlass.isHidden = true
        changesGroup.addSubview(changesPillGlass)
        changesGroup.addSubview(changesPill)
        changesGroup.isHidden = true
        queuedChip.glassBackdrop = queuedChipGlass
        queuedChip.onPress = { [weak self] in self?.editQueuedMessage() }
        queuedChip.isHidden = true
        queuedChipGlass.isHidden = true
        view.addSubview(queuedChipGlass)
        view.addSubview(queuedChip)
        editingChip.glassBackdrop = editingChipGlass
        editingChip.onPress = { [weak self] in
            self?.composer.clear()
            self?.endEditingMessage()
        }
        editingChip.isHidden = true
        editingChipGlass.isHidden = true
        view.addSubview(editingChipGlass)
        view.addSubview(editingChip)

        view.addSubview(emptyState)

        composerBottom = composer.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -DS.Spacing.xl)
        // Where the pills sit when the window has no bar to take them: above the composer's
        // corners, as before.
        undockedPillConstraints = [
            sessionPill.trailingAnchor.constraint(equalTo: composer.trailingAnchor, constant: -DS.Spacing.xs),
            sessionPill.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -DS.Spacing.s),
            changesPill.leadingAnchor.constraint(equalTo: composer.leadingAnchor, constant: DS.Spacing.xs),
            changesPill.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -DS.Spacing.s),
        ]
        editingChipLeading = editingChip.leadingAnchor.constraint(equalTo: changesPill.trailingAnchor, constant: DS.Spacing.xl + DS.Spacing.s * 2)
        NSLayoutConstraint.activate(undockedPillConstraints + [editingChipLeading])
        NSLayoutConstraint.activate([
            emptyState.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyState.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
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
            composerBottom,
            // The session pill floats just above the composer's trailing corner.
            sessionGroup.topAnchor.constraint(equalTo: sessionPillGlass.topAnchor),
            sessionGroup.bottomAnchor.constraint(equalTo: sessionPillGlass.bottomAnchor),
            sessionGroup.leadingAnchor.constraint(equalTo: sessionPillGlass.leadingAnchor),
            sessionGroup.trailingAnchor.constraint(equalTo: sessionPillGlass.trailingAnchor),
            sessionPillGlass.topAnchor.constraint(equalTo: sessionPill.topAnchor, constant: -2),
            sessionPillGlass.bottomAnchor.constraint(equalTo: sessionPill.bottomAnchor, constant: 2),
            sessionPillGlass.leadingAnchor.constraint(equalTo: sessionPill.leadingAnchor, constant: -DS.Spacing.s),
            sessionPillGlass.trailingAnchor.constraint(equalTo: sessionPill.trailingAnchor, constant: DS.Spacing.s),
            pillModeTint.topAnchor.constraint(equalTo: sessionPillGlass.topAnchor),
            pillModeTint.bottomAnchor.constraint(equalTo: sessionPillGlass.bottomAnchor),
            pillModeTint.leadingAnchor.constraint(equalTo: sessionPillGlass.leadingAnchor),
            pillModeTint.trailingAnchor.constraint(equalTo: sessionPillGlass.trailingAnchor),
            // Mirror of the session pill, on the composer's leading corner.
            changesGroup.topAnchor.constraint(equalTo: changesPillGlass.topAnchor),
            changesGroup.bottomAnchor.constraint(equalTo: changesPillGlass.bottomAnchor),
            changesGroup.leadingAnchor.constraint(equalTo: changesPillGlass.leadingAnchor),
            changesGroup.trailingAnchor.constraint(equalTo: changesPillGlass.trailingAnchor),
            changesPillGlass.topAnchor.constraint(equalTo: changesPill.topAnchor, constant: -2),
            changesPillGlass.bottomAnchor.constraint(equalTo: changesPill.bottomAnchor, constant: 2),
            changesPillGlass.leadingAnchor.constraint(equalTo: changesPill.leadingAnchor, constant: -DS.Spacing.s),
            changesPillGlass.trailingAnchor.constraint(equalTo: changesPill.trailingAnchor, constant: DS.Spacing.s),
            // Above the pills, so it reads as "next" rather than as part of the session chrome.
            queuedChip.leadingAnchor.constraint(equalTo: composer.leadingAnchor, constant: DS.Spacing.xs),
            queuedChip.trailingAnchor.constraint(lessThanOrEqualTo: composer.trailingAnchor, constant: -DS.Spacing.xs),
            queuedChip.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -(DS.Spacing.s + 30)),
            queuedChipGlass.topAnchor.constraint(equalTo: queuedChip.topAnchor, constant: -2),
            queuedChipGlass.bottomAnchor.constraint(equalTo: queuedChip.bottomAnchor, constant: 2),
            queuedChipGlass.leadingAnchor.constraint(equalTo: queuedChip.leadingAnchor, constant: -DS.Spacing.s),
            queuedChipGlass.trailingAnchor.constraint(equalTo: queuedChip.trailingAnchor, constant: DS.Spacing.s),
            // Beside the changes pill rather than on a row of its own: they're both one-line
            // status capsules on the same band above the composer, and stacking them pushed the
            // transcript up by a whole row for a state that lasts a few seconds.
            // `xl` plus both glass overhangs. Each capsule's glass backdrop extends `s` past its
            // button on every side, so a bare 12pt button-to-button gap put the two glass edges
            // exactly touching — the chips read as one smeared capsule.
            editingChip.trailingAnchor.constraint(lessThanOrEqualTo: composer.trailingAnchor, constant: -DS.Spacing.xs),
            editingChip.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -(DS.Spacing.s + 2)),
            editingChipGlass.topAnchor.constraint(equalTo: editingChip.topAnchor, constant: -2),
            editingChipGlass.bottomAnchor.constraint(equalTo: editingChip.bottomAnchor, constant: 2),
            editingChipGlass.leadingAnchor.constraint(equalTo: editingChip.leadingAnchor, constant: -DS.Spacing.s),
            editingChipGlass.trailingAnchor.constraint(equalTo: editingChip.trailingAnchor, constant: DS.Spacing.s),
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
        NotificationCenter.default.addObserver(
            self, selector: #selector(projectFilesDidChange(_:)),
            name: ProjectWatcher.didChangeNotification, object: nil
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
        let overlap = composer.frame.height + (pillsDocked ? 0 : 26) /* pill row */ + composerGap + DS.Spacing.l
        if abs(transcriptScroll.contentInsets.bottom - overlap) > 0.5 {
            // The transcript starts below the window's top row and scrolls up underneath it.
            transcriptScroll.contentInsets = NSEdgeInsets(top: ChromeHost.rowHeight + DS.Spacing.m, left: 0, bottom: overlap, right: 0)
            // The track runs down the window's edge beside the composer and stops above the bar,
            // as Make's does. Ending it above the composer left the thumb ~150 pt short of the
            // bottom when the chat was scrolled all the way down (owner, 2026-09-23). The
            // contents' own inset still stands, so this moves only the track.
            transcriptScroll.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: bottomObstruction + DS.Spacing.s - overlap, right: 0)
        }
    }

    /// Same responder-chain lesson Make/Tracks already learned: without explicitly claiming
    /// first responder on appearance, nothing in this stage's hierarchy holds it and
    /// menu-routed actions targeting this controller silently go nowhere.
    override func viewDidAppear() {
        super.viewDidAppear()
        refreshModelReadiness()
        if let window = view.window, mainWindowObserver == nil {
            mainWindowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeMainNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshModelReadiness() }
            }
        }
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

    /// Composer to window bottom: its usual margin, or the covered band plus a 10 pt gap so the
    /// composer and whatever is beneath it read as one stack.
    private var composerGap: CGFloat { bottomObstruction > 0 ? bottomObstruction + 10 : DS.Spacing.xl }

    private func refreshConversationTitle() {
        let firstMessage = runner?.entries.lazy.compactMap { entry -> String? in
            if case .userText(let text) = entry.kind { return text }
            return nil
        }.first
        let title = firstMessage.map { $0.split(whereSeparator: \.isNewline).first.map(String.init) ?? $0 } ?? "New conversation"
        conversationTitle.stringValue = title
    }

    private func attach(trackKey: String?) {
        detach()
        attachedTrackKey = trackKey
        refreshFileIndex()
        // Think works on a track (§6): with none, there's no conversation to attach to — the
        // empty state offers to start one.
        if let runnerManager, let trackKey, !trackKey.isEmpty {
            let newRunner = runnerManager.runner(forTrackKey: trackKey)
            runner = newRunner
            observerToken = newRunner.addObserver { [weak self] event in self?.handle(event) }
            // An outside agent's model and mode are only known once it opens a session; open it
            // now so the pill shows them before the first message (RFC step 4).
            newRunner.prepareSession()
        } else {
            runner = nil
        }
        refreshModelReadiness()
        if isViewLoaded {
            renderFull()
            if view.window != nil { runner?.acknowledgeCompletion() }
        }
    }

    /// Which empty state, if any: no project → Open Project; not a repository → Initialize Git;
    /// no track → New Track (or Choose a Track when some exist); an empty conversation → a line.
    private func refreshEmptyState() {
        guard isViewLoaded else { return }
        let hasEntries = !(runner?.entries.isEmpty ?? true)
        emptyState.isHidden = hasEntries
        composer.isEnabled = runner != nil && runner?.phase != .awaitingApproval
        guard !hasEntries else { return }
        let act: (EmptyStateAction) -> () -> Void = { action in { [weak self] in self?.onEmptyStateAction?(action) } }
        if runnerManager == nil {
            emptyState.configure("Open a project to start a conversation.", action: "Open Project…", handler: act(.openProject))
        } else if trackStore?.repoState == .notAGitRepo {
            emptyState.configure("Conversations happen on tracks, and tracks need git.", action: "Initialize Git…", handler: act(.initializeGit))
        } else if runner == nil {
            let hasTracks = trackStore?.tracks.contains { $0.status != .archived } ?? false
            emptyState.configure("Think works on a track.", action: hasTracks ? "Choose a Track…" : "New Track", handler: act(hasTracks ? .chooseTrack : .newTrack))
        } else {
            emptyState.configure("Ask anything about this track — every change waits for your approval.", action: nil, handler: nil)
        }
    }

    private func refreshModelReadiness() {
        modelReady = runner?.isReadyToSend ?? true
        guard isViewLoaded else { return }
        composer.setNeedsModelSetup(!modelReady)
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
            refreshConversationTitle()
        case .appended(let index):
            appendEntryView(at: index)
            if index == 0 || conversationTitle.stringValue == "New conversation" { refreshConversationTitle() }
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
            refreshEditAffordances()
            if runner?.phase.isBusy != true {
                currentWorkGroup?.finish()
                currentWorkGroup = nil
            }
            finalizeStreamedBubbles()
            updateSendButton()
            refreshSessionPill()
            (sessionPopover?.contentViewController as? AgentSessionSettingsViewController)?.refresh()
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
        guard let runner else { return }
        // While the agent is working the button means Stop — but pressing Return with text in
        // the composer means "send this next", which is what every other harness does and what
        // typing during a long turn obviously intends. Without this the keystroke was simply
        // swallowed and the thought was lost.
        if runner.phase == .streaming || runner.phase == .runningTools {
            let pending = composer.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if pending.isEmpty {
                runner.stop()
            } else {
                enqueue(pending, attachments: composer.attachmentPayloads())
                composer.clear()
            }
            return
        }
        guard runner.phase != .awaitingApproval else { return }
        let text = composer.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = composer.attachmentPayloads()
        guard !text.isEmpty || !attachments.isEmpty else { return }
        // Standing instructions from a file that arrived with the repo get the user's eyes
        // before they get the system prompt — see ProjectRules.
        guard confirmProjectRulesIfNeeded() else { return }
        // Checked before clearing: a message that can't be sent must stay in the composer
        // rather than vanishing behind a muted notice.
        guard runner.isReadyToSend else {
            // "Set up a model…" (§6): straight to Providers; the message stays where it is.
            refreshModelReadiness()
            onEmptyStateAction?(.setUpModel)
            return
        }
        composer.clear()
        if let turnId = editingTurnId {
            endEditingMessage()
            runner.editAndResend(turnId: turnId, text: text, attachments: attachments)
            return
        }
        runner.send(text, attachments: attachments)
    }

    // MARK: - Editing a sent message

    /// The turn whose text is currently loaded in the composer, if any.
    private var editingTurnId: UUID?
    private weak var editingRow: BubbleRowView?

    private func refreshEditAffordances() {
        let allowed = runner?.phase.isBusy != true
        for view in entryViews {
            (view as? BubbleRowView)?.editEnabled = allowed
        }
    }

    private func beginEditingMessage(turnId: UUID, row: BubbleRowView) {
        guard let runner, !runner.phase.isBusy else { return }
        guard let draft = runner.editableMessage(turnId: turnId) else { return }
        // A second edit replaces the first rather than stacking — same reasoning as the one-slot
        // message queue: "I've changed my mind about which one" is what a second click means.
        endEditingMessage()
        editingTurnId = turnId
        editingRow = row
        row.setEditing(true)
        composer.setText(draft.text)
        composer.setAttachments(draft.attachments)
        refreshEditingBanner()
        composer.focus()
    }

    private func endEditingMessage() {
        editingRow?.setEditing(false)
        editingRow = nil
        editingTurnId = nil
        refreshEditingBanner()
    }

    /// Reuses the queued-message chip's slot: both say "the composer is holding something other
    /// than a fresh message," and two competing banners in one place would be worse than one that
    /// can only ever show one state at a time (the composer cannot be both, since editing is
    /// refused while a turn is running and queuing only happens while one is).
    private func refreshEditingBanner() {
        guard editingTurnId != nil else {
            refreshQueuedMessageChip()
            return
        }
        editingChip.setLabel("Editing — sending moves the rest to a branch", tint: .secondaryLabelColor)
        editingChip.toolTip = "Escape to cancel. The replaced turns are kept as a separate conversation."
        editingChip.isHidden = false
        editingChipGlass.isHidden = false
        queuedChip.isHidden = true
        queuedChipGlass.isHidden = true
        DS.Motion.appear(editingChip)
    }

    /// Escape cancels, in the order the user most likely means: a queued message first (it
    /// hasn't been sent, so cancelling it costs nothing), then a running turn.
    private func escapePressed() -> Bool {
        // Editing first: it's the state the user is most likely looking at, and cancelling it
        // costs nothing — the message it was going to replace is still there.
        if editingTurnId != nil {
            composer.clear()
            endEditingMessage()
            return true
        }
        if queuedMessage != nil {
            queuedMessage = nil
            refreshQueuedMessageChip()
            return true
        }
        guard let runner, runner.phase == .streaming || runner.phase == .runningTools else { return false }
        runner.stop()
        return true
    }

    private func updateSendButton() {
        let phase = runner?.phase ?? .idle
        let busy = phase == .streaming || phase == .runningTools
        composer.setBusy(busy)
        let awaitingApproval = phase == .awaitingApproval
        composer.isEnabled = !awaitingApproval
        composer.placeholder = runner == nil
            ? "Start a track to begin a conversation"
            : awaitingApproval
            ? "Apply or reject the proposed change above to continue…"
            : (busy ? "Working — your next message will be sent when it finishes…" : "Ask about this project…")
        // A turn just ended: send whatever was typed while it was running.
        if !busy, !awaitingApproval { flushQueuedMessage() }
    }

    /// One queued message, not a queue.
    ///
    /// Deliberately: a backlog of messages fired blind at an agent whose earlier answers the
    /// user hasn't read is worse than losing the surplus. Typing a second message replaces the
    /// first, which is what "I've thought about it more" almost always means.
    private var queuedMessage: (text: String, attachments: [AgentImageAttachment])?

    private func enqueue(_ text: String, attachments: [AgentImageAttachment]) {
        queuedMessage = (text, attachments)
        refreshQueuedMessageChip()
    }

    private func flushQueuedMessage() {
        guard let queued = queuedMessage, let runner, runner.isReadyToSend else { return }
        queuedMessage = nil
        refreshQueuedMessageChip()
        runner.send(queued.text, attachments: queued.attachments)
    }

    /// Shows the queued message where the user can see and undo it.
    ///
    /// The first version only printed a transcript notice, which is the wrong shape twice over:
    /// a queued message is *pending state*, not a historical event, and a notice can't be
    /// edited or cancelled. Clicking the chip puts the text back in the composer — the only
    /// honest way to offer editing, since the queue holds one message and editing it is
    /// indistinguishable from re-queuing it.
    private func refreshQueuedMessageChip() {
        editingChip.isHidden = true
        editingChipGlass.isHidden = true
        guard let queued = queuedMessage else {
            queuedChip.isHidden = true
            queuedChipGlass.isHidden = true
            return
        }
        let oneLine = queued.text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        let preview = oneLine.count > 60 ? String(oneLine.prefix(60)) + "…" : oneLine
        let attachmentNote = queued.attachments.isEmpty
            ? ""
            : " (+\(queued.attachments.count) image\(queued.attachments.count == 1 ? "" : "s"))"
        queuedChip.setLabel("Queued: \(preview)\(attachmentNote)", tint: .secondaryLabelColor)
        queuedChip.toolTip = "Click to edit — puts this back in the composer"
        queuedChip.isHidden = false
        queuedChipGlass.isHidden = false
        DS.Motion.appear(queuedChip)
    }

    /// Returns the queued message to the composer for editing, which also cancels the send.
    private func editQueuedMessage() {
        guard let queued = queuedMessage else { return }
        queuedMessage = nil
        refreshQueuedMessageChip()
        composer.focus()
        composer.insertText(queued.text)
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
        actions.onOpenRules = { [weak self] in self?.openProjectRules() }
        actions.onShowHistory = { [weak self] in self?.showConversationHistory() }
        actions.onCompact = { [weak self] in self?.compactConversation() }
        actions.onNewConversation = { [weak self] in self?.startNewConversation() }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = actions
        popover.show(relativeTo: plusButton.bounds, of: plusButton, preferredEdge: .maxY)
    }

    /// Asks once per (file, contents) before a repo's rules file is allowed to shape requests.
    ///
    /// Returns false only when the user chooses to look at the file first — the send is then
    /// abandoned with the message still in the composer, so nothing is lost. Declining just
    /// leaves the rules inactive; the conversation proceeds without them.
    private func confirmProjectRulesIfNeeded() -> Bool {
        guard let projectPath else { return true }
        let root = URL(fileURLWithPath: trackStore?.tracks.first { $0.branchName == (attachedTrackKey ?? "") }?.workingDirectoryPath ?? projectPath)
        // Two files arrive with a repository and change what the agent does: the rules file
        // shapes what it says, the tasks file decides what `run_task` executes. Both get the same
        // per-content consent before they take effect.
        if let rules = ProjectRules.pendingAcknowledgement(projectRoot: root) {
            let name = rules.url.lastPathComponent
            let outcome = askToAcknowledge(
                title: "Use \(name) as standing instructions?",
                detail: "This project contains \(name), which tells agents how to work in it. "
                    + "Side would include it in every request for this project.\n\n"
                    + "Files like this arrive with a cloned repository, so read it first if the project isn't yours — "
                    + "it shapes what the agent does, though it can never waive your approval of edits and commands.",
                acceptTitle: "Use These Rules", file: rules,
                acceptedNotice: "\(name) is now included in every request for this project."
            )
            guard outcome else { return false }
        }
        if let tasks = ProjectTasks.pendingDeclaration(projectRoot: root) {
            let outcome = askToAcknowledge(
                title: "Use this project's declared tasks?",
                detail: "This project contains \(ProjectTasks.declarationPath), which names commands the agent can run "
                    + "with run_task — its build, test, and verify steps.\n\n"
                    + "It arrives with a cloned repository, so read it first if the project isn't yours: a task named "
                    + "\u{201C}test\u{201D} can run anything. Until you accept it, Side uses what it detects from the "
                    + "project's own manifests instead. Each task still shows an approval card unless the track auto-runs commands.",
                acceptTitle: "Use These Tasks", file: tasks,
                acceptedNotice: "\(ProjectTasks.declarationPath) is now the source of this project's tasks."
            )
            guard outcome else { return false }
        }
        return true
    }

    /// One consent dialog. Returns false only when the user chose to look at the file first — that
    /// is a "not yet", and the message stays in the composer.
    private func askToAcknowledge(title: String, detail: String, acceptTitle: String, file: (url: URL, contents: String), acceptedNotice: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: acceptTitle)
        alert.addButton(withTitle: "Show Me the File")
        alert.addButton(withTitle: "Not Now")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            ProjectRules.acknowledge(url: file.url, contents: file.contents)
            appendLocalNotice(acceptedNotice)
            return true
        case .alertSecondButtonReturn:
            onRevealFileRequested?(file.url)
            return false
        default:
            return true
        }
    }

    /// Opens the project's rules file in Make, creating it from the template when there is
    /// none — the file only helps if writing the first one is a single click.
    private func openProjectRules() {
        guard let projectPath else { return }
        let root = trackStore?.tracks.first { $0.branchName == (attachedTrackKey ?? "") }?.workingDirectoryPath ?? projectPath
        let rootURL = URL(fileURLWithPath: root)
        if let existing = ProjectRules.candidateNames
            .map({ rootURL.appendingPathComponent($0) })
            .first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            onRevealFileRequested?(existing)
            return
        }
        let url = rootURL.appendingPathComponent(ProjectRules.preferredFileName)
        guard (try? ProjectRules.template.write(to: url, atomically: true, encoding: .utf8)) != nil else { return }
        // Written by the user, here, on purpose — asking them to acknowledge their own file
        // would be theatre.
        ProjectRules.acknowledge(url: url, contents: ProjectRules.template.trimmingCharacters(in: .whitespacesAndNewlines))
        appendLocalNotice("Created \(ProjectRules.preferredFileName) — what you write there is included in every Think request for this project.")
        onRevealFileRequested?(url)
    }

    /// The history picker: every past conversation on this track, newest first.
    private func showConversationHistory() {
        guard let runner else { return }
        let conversations = runner.archivedConversations
        guard !conversations.isEmpty else {
            appendLocalNotice("No past conversations on this track yet — starting a new one files the current one here.")
            return
        }
        let picker = ConversationHistoryViewController()
        picker.conversations = conversations
        picker.onSelect = { [weak self] id in
            guard let self, let runner = self.runner else { return }
            guard runner.openArchivedConversation(id: id) else {
                self.appendLocalNotice("Couldn't reopen that conversation.")
                return
            }
            self.refreshSessionPill()
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = picker
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
        if let runner, runner.harnessName != nil {
            let agentSettings = AgentSessionSettingsViewController()
            agentSettings.harness = runner
            agentSettings.harnessId = trackStore?.harness(forTrackKey: attachedTrackKey ?? "")?.id
            agentSettings.onAgentChosen = { [weak self] id in self?.chooseAgent(id) }
            presentSessionPopover(agentSettings)
            return
        }
        let settings = SessionSettingsViewController()
        settings.onAgentChosen = { [weak self] id in self?.chooseAgent(id) }
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
        presentSessionPopover(settings)
    }

    private func presentSessionPopover(_ content: NSViewController) {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = content
        popover.delegate = self
        popover.show(relativeTo: sessionPill.bounds, of: sessionPill, preferredEdge: .maxY)
        sessionPopover = popover
    }

    /// The pill's AGENT row (RFC step 4): the same choice as Tracks › Agent. The track's store
    /// change swaps the engine and reattaches Think (`ShellViewController.syncHarnesses`).
    private func chooseAgent(_ id: String) {
        sessionPopover?.close()
        guard let trackKey = attachedTrackKey, !trackKey.isEmpty else { return }
        let current = trackStore?.harness(forTrackKey: trackKey)?.id ?? ""
        guard id != current else { return }
        if let agent = ACPAgent.agent(id: id), AgentAvailability.isInstalled(agent) == false {
            appendLocalNotice("\(agent.displayName) isn't installed. Install it in a terminal, then pick it again:\n\n\(agent.installHint)")
            return
        }
        // Switching puts the current engine away; mid-turn that would drop work in flight.
        if runner?.phase.isBusy == true || runner?.phase == .awaitingApproval {
            appendLocalNotice("Stop the current turn before switching agents.")
            return
        }
        trackStore?.setHarness(id.isEmpty ? nil : id, forTrackKey: trackKey)
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
    /// Make's watcher covers the same worktree Think's mentions resolve against; a change there
    /// makes this index stale. Coalesced, since a build writes hundreds of files in a second.
    @objc private func projectFilesDidChange(_ notification: Notification) {
        fileIndexRefresh?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.fileIndex.markStale()
            self?.refreshFileIndex()
        }
        fileIndexRefresh = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: item)
    }

    private func refreshFileIndex() {
        guard let projectPath else { return }
        let root = trackStore?.tracks.first { $0.branchName == (attachedTrackKey ?? "") }?.workingDirectoryPath
        let url = URL(fileURLWithPath: root ?? projectPath)
        fileIndex.refresh(root: url) {}
    }

    /// Existence check for bare-path linking — same root, same containment rule as opening.
    /// `path#L12-L40` → (path, 12); a plain path has no line.
    private static func splitLineSuffix(_ token: String) -> (path: String, line: Int?) {
        guard let match = token.range(of: #"#L(\d+)(-L\d+)?$"#, options: .regularExpression) else { return (token, nil) }
        let digits = token[match].dropFirst(2).prefix { $0.isNumber }
        return (String(token[..<match.lowerBound]), Int(digits))
    }

    private func mentionedFileExists(_ token: String) -> Bool {
        let path = Self.splitLineSuffix(token).path
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
    private func openMentionedFile(_ token: String) {
        let (path, line) = Self.splitLineSuffix(token)
        guard let projectPath else { return }
        let root = trackStore?.tracks.first { $0.branchName == (attachedTrackKey ?? "") }?.workingDirectoryPath ?? projectPath
        let url = URL(fileURLWithPath: root).appendingPathComponent(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return }
        if let line { onRevealFileAtLineRequested?(url, line) } else { onRevealFileRequested?(url) }
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
        alert.informativeText = "This conversation is filed under History — you can reopen it any time. The agent starts fresh and won't carry anything forward; use Compact instead if it should. Checkpoints, usage history, and your files are untouched."
        alert.addButton(withTitle: "Start New")
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
        // Scope is Heron's; an outside agent's pill isn't tinted by a scope it doesn't have.
        let isOutsideAgent = runner?.harnessName != nil
        let scopeTint = isOutsideAgent ? NSColor.controlAccentColor : Self.tint(for: currentMode().scope)
        pillModeTint.color = isOutsideAgent ? .clear : scopeTint.withAlphaComponent(0.16)
        composer.setModeTint(scopeTint)
        // The popover is anchored to the pill: resizing the pill mid-edit visibly drags the
        // popover sideways. Hold the label until the popover closes.
        if sessionPopover?.isShown == true {
            pillRefreshDeferred = true
            return
        }
        let mode = currentMode()
        // An outside agent names itself and its own model; Heron's model and scope don't apply
        // to it (RFC D6).
        var title: String
        if let runner, let agentName = runner.harnessName {
            let model = runner.agentOptions.first { $0.category == .model }?.currentChoice?.name
            title = [agentName, model].compactMap { $0 }.joined(separator: " · ")
        } else {
            title = "\(resolvedSelectionModelName()) · \(mode.scope.displayName)"
        }
        var tint = NSColor.secondaryLabelColor
        // Until an outside agent reports usage there's no window to be a percentage of.
        if let runner, runner.harnessName == nil || runner.contextUsage().windowTokens > 0 {
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
                context.duration = DS.Motion.duration(0.22)
                context.timingFunction = DS.Motion.curve
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

    /// The panel behind the changes pill: every file this conversation edited, with its own
    /// line counts, each row opening in Make.
    ///
    /// The pill was already the collapsed form of this — it reported "3 files +42 −7" and then
    /// sent you to Review, which is the right *eventual* destination but the wrong answer to
    /// "which files?". Answering that in place is what every other harness does, and the parts
    /// were all here already: the runner records per-file counts, and Review knows how to
    /// promote and undo.
    private func showChangedFiles() {
        guard let runner, !runner.appliedEditCounts.isEmpty else { return }
        let panel = ChangedFilesViewController()
        panel.files = runner.appliedEditCounts.map {
            ChangedFilesViewController.Row(path: $0.path, added: $0.added, removed: $0.removed)
        }
        panel.onOpenFile = { [weak self] path in self?.openMentionedFile(path) }
        panel.onOpenReview = { [weak self] in self?.onOpenReviewRequested?() }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = panel
        popover.show(relativeTo: changesPill.bounds, of: changesPill, preferredEdge: .maxY)
    }

    /// "3 files +42 −7" — cumulative applied edits this conversation.
    private func refreshChangesPill() {
        let counts = runner?.appliedEditCounts ?? []
        let isEmpty = counts.isEmpty
        if !isEmpty {
            let added = counts.reduce(0) { $0 + $1.added }
            let removed = counts.reduce(0) { $0 + $1.removed }
            let identity = "\(counts.count)|\(added)|\(removed)|\(pillsDocked)"
            if changesPill.labelIdentity != identity {
                // Green and red, matching the panel behind the pill and every diff in the app —
                // the counts are the part worth reading at a glance, and a uniformly grey label
                // makes them the part that reads last.
                let label = NSMutableAttributedString(
                    string: "\(counts.count) file\(counts.count == 1 ? "" : "s")  ",
                    attributes: [.font: pillFont, .foregroundColor: NSColor.secondaryLabelColor]
                )
                label.append(NSAttributedString(
                    string: "+\(added)",
                    attributes: [.font: pillFont, .foregroundColor: NSColor.systemGreen]
                ))
                label.append(NSAttributedString(
                    string: " −\(removed)",
                    attributes: [.font: pillFont, .foregroundColor: NSColor.systemRed]
                ))
                changesPill.setAttributedLabel(label, identity: identity)
            }
        }
        guard changesPill.isHidden != isEmpty else { return }
        changesPill.isHidden = isEmpty
        changesPillGlass.isHidden = isEmpty
        changesGroup.isHidden = isEmpty
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
        ("rules", "open this project's standing instructions for the agent"),
        ("history", "reopen a past conversation on this track"),
    ]

    private func performSlashCommand(_ name: String) {
        switch name {
        case "compact": compactConversation()
        case "new": startNewConversation()
        case "rules": openProjectRules()
        case "history": showConversationHistory()
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
        // A message queued against the conversation being replaced has nowhere to go.
        queuedMessage = nil
        refreshQueuedMessageChip()
        // Pending flushes index into the entry list being replaced. Carrying them across a
        // track switch or a reset made the next flush call setBody(streaming:) against a
        // different conversation's entries — stripping markdown, code blocks, and file links
        // off an unrelated finished message.
        pendingStreamIndices = []
        activeStreamIndices = []
        transcriptStack.arrangedSubviews.forEach {
            transcriptStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        entryViews.removeAll()
        currentWorkGroup = nil
        for (index, entry) in (runner?.entries ?? []).enumerated() {
            appendRendered(entry, isFirst: index == 0)
        }
        // Finished at the last entry's own timestamp, not now — this is the rehydration path.
        currentWorkGroup?.finish()
        currentWorkGroup = nil
        refreshEmptyState()
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
        let view = appendRendered(entry, isFirst: index == 0)
        emptyState.isHidden = true
        // Only live appends animate — `renderFull` (reattach, track switch) lays the whole
        // history out instantly rather than replaying every arrival. A line that joined an
        // existing group animates the group's header count, not itself.
        if view.superview === transcriptStack { animateIn(view) }
    }

    /// One entry → one view, placed either directly in the transcript or — for tool lines —
    /// inside the current "Worked…" group, ChatGPT-style: the underlying activity is collapsed
    /// behind a header that counts steps and time, expandable whenever.
    @discardableResult
    private func appendRendered(_ entry: RunTranscriptEntry, isFirst: Bool) -> NSView {
        let view = makeEntryView(entry)
        entryViews.append(view)
        let isToolLine: Bool
        switch entry.kind {
        // Reasoning belongs in the group for the same reason tool lines do: it is the underlying
        // work, and the group is what keeps it out of the way until asked for.
        case .toolCall, .toolResult, .thinking: isToolLine = true
        default: isToolLine = false
        }
        if isToolLine {
            let group: WorkGroupView
            if let open = currentWorkGroup, open === transcriptStack.arrangedSubviews.last {
                group = open
            } else {
                group = WorkGroupView(startedAt: entry.createdAt)
                addBlock(group, topSpacing: isFirst ? 0 : Self.spacing(before: entry.kind))
                currentWorkGroup = group
            }
            var isStep = false
            var isThinking = false
            if case .toolCall = entry.kind { isStep = true }
            // Reasoning is not a step. Counting it would inflate "3 steps" into "4 steps" for a
            // turn that called three tools, and the step count is how someone judges how much the
            // agent actually did.
            if case .thinking = entry.kind { isThinking = true }
            group.addLine(view, isStep: isStep, isThinking: isThinking, at: entry.createdAt)
        } else {
            currentWorkGroup?.finish()
            currentWorkGroup = nil
            addBlock(view, topSpacing: isFirst ? 0 : Self.spacing(before: entry.kind))
        }
        return view
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
                context.duration = DS.Motion.duration(0.14)
                context.timingFunction = DS.Motion.curve
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
            guard let card = entryViews[index] as? ProposedEditView else { return }
            // Three ways a proposal card changes after it appears: another fragment of a
            // streaming preview arrived, the preview became a real validated proposal, or a
            // decision was made about one.
            card.update(edit: presentation.edit, diffText: presentation.diffText, isStreaming: presentation.isStreaming)
            if let resolution = presentation.resolution {
                let label = resolution.label
                card.showResolution(label.text, color: Self.color(for: label.color))
            } else if !presentation.isStreaming {
                let proposalId = entry.id
                card.onApply = { [weak self] in self?.runner?.resolve(proposalId: proposalId, decision: .apply) }
                card.onReject = { [weak self] in self?.runner?.resolve(proposalId: proposalId, decision: .reject) }
                card.wholeFileDiff = wholeFileDiffProvider(for: presentation.edit)
                card.enableDecision()
            }
        case .commandProposal(let presentation):
            guard let card = entryViews[index] as? CommandProposalView, let resolution = presentation.resolution else { return }
            showCommandResolution(card, presentation.command, resolution)
        case .thinking(let text):
            guard let label = entryViews[index] as? NSTextField else { return }
            label.stringValue = Self.condensedThinking(text)
        case .checkpoint(_, let text):
            (entryViews[index] as? CheckpointLineButton)?.setText(text)
        case .permissionRequest(let presentation):
            if let chosen = presentation.chosenOptionName { (entryViews[index] as? PermissionRequestView)?.showChoice(chosen) }
        case .toolCall(let name, let summary):
            // An outside agent reports a tool's result on its own line (ACP tool_call_update).
            (entryViews[index] as? LinkedTextLine)?.configure(
                text: "→ \(name)\(summary)", font: DS.Text.caption(), color: .secondaryLabelColor,
                existingPath: { [weak self] path in self?.mentionedFileExists(path) ?? false }
            )
        case .meta(let text):
            // Checkpoint markers are rewritten once the agent describes what it did, so a meta
            // line is not write-once. Without this the data updated and the label didn't: Review
            // showed the agent's summary while the transcript still showed the request that
            // prompted it, and the two disagreed until the next full rebuild.
            (entryViews[index] as? NSTextField)?.stringValue = text
        default:
            break // Everything else is written once and never revised.
        }
        scrollToBottom()
    }

    /// One `RunTranscriptEntry` → exactly one view. Headers ("You"/"Assistant") aren't a
    /// separate entry — they're drawn as part of the same block as the text they belong to.
    private func makeEntryView(_ entry: RunTranscriptEntry) -> NSView {
        switch entry.kind {
        case .meta(let text):
            return makeLabel(text, font: DS.Text.body(), color: .tertiaryLabelColor)
        case .permissionRequest(let presentation):
            // An outside agent asking before it acts: its own options, its own words (RFC D3).
            let card = PermissionRequestView(presentation: presentation)
            let entryId = entry.id
            card.onChoose = { [weak self] optionId in self?.runner?.answerPermission(proposalId: entryId, optionId: optionId) }
            return card
        case .checkpoint(let id, let text):
            // Same quiet line as any meta note, but it opens that checkpoint's files and diff in
            // a sheet — no trip to Review to see what just changed (§5.1).
            let line = CheckpointLineButton(text: text)
            line.onOpen = { [weak self] in self?.onOpenCheckpointRequested?(id) }
            return line
        case .userImage(let data):
            return ImageBubbleRowView(imageData: data, alignRight: true)
        case .userText(let text):
            // iMessage-shaped: sent messages are solid-accent bubbles hugging their own content
            // against the trailing edge; no "You" header — the side and color carry that.
            let bubble = TextBlockView(style: .sent, body: text, maxBubbleWidth: 460, pathResolver: { [weak self] path in self?.mentionedFileExists(path) ?? false })
            bubble.onMentionClicked = { [weak self] path in self?.openMentionedFile(path) }
            let row = BubbleRowView(bubble: bubble, alignRight: true)
            // Only a message that came from a persisted turn can be edited — a locally-rendered
            // notice has nothing in the session to fork at.
            if let turnId = entry.sourceTurnId {
                row.onEdit = { [weak self, weak row] in
                    guard let self, let row else { return }
                    self.beginEditingMessage(turnId: turnId, row: row)
                }
            }
            return row
        case .assistantText(let text):
            let bubble = TextBlockView(style: .received, body: text, maxBubbleWidth: 620, pathResolver: { [weak self] path in self?.mentionedFileExists(path) ?? false })
            // The agent quotes paths back constantly; making those live too means "@" and a
            // plain mention behave the same wherever they appear.
            bubble.onMentionClicked = { [weak self] path in self?.openMentionedFile(path) }
            return BubbleRowView(bubble: bubble, alignRight: false)
        case .thinking(let text):
            // Italic and dimmer than a tool line: it reads as the model's aside rather than as
            // something it did. Wrapping, because reasoning is prose and truncating it mid-clause
            // would leave a line that says less than nothing.
            let label = makeLabel(Self.condensedThinking(text), font: DS.Text.caption(), color: .tertiaryLabelColor)
            label.font = NSFontManager.shared.convert(DS.Text.caption(), toHaveTrait: .italicFontMask)
            return label
        case .toolCall(let name, let summary):
            // System text, not terminal output — and its paths are live.
            return makeToolLine("→ \(name)\(summary)", color: .secondaryLabelColor)
        case .toolResult(let text, let isError):
            return makeToolLine(text, color: isError ? .systemOrange : .secondaryLabelColor)
        case .failure(let text):
            let bubble = TextBlockView(style: .error, body: text, maxBubbleWidth: 620)
            return BubbleRowView(bubble: bubble, alignRight: false)
        case .proposal(let presentation):
            let card = ProposedEditView(edit: presentation.edit, diffText: presentation.diffText, isStreaming: presentation.isStreaming)
            if presentation.isStreaming {
                // Nothing to wire up: the buttons are hidden until the arguments land.
            } else if let resolution = presentation.resolution {
                let label = resolution.label
                card.showResolution(label.text, color: Self.color(for: label.color))
            } else {
                let proposalId = entry.id
                card.onApply = { [weak self] in self?.runner?.resolve(proposalId: proposalId, decision: .apply) }
                card.onReject = { [weak self] in self?.runner?.resolve(proposalId: proposalId, decision: .reject) }
                card.wholeFileDiff = wholeFileDiffProvider(for: presentation.edit)
            }
            return card
        case .commandProposal(let presentation):
            let card = CommandProposalView(command: presentation.command)
            if let resolution = presentation.resolution {
                showCommandResolution(card, presentation.command, resolution)
            } else {
                let proposalId = entry.id
                card.onApply = { [weak self] in self?.runner?.resolve(proposalId: proposalId, decision: .apply) }
                card.onReject = { [weak self] in self?.runner?.resolve(proposalId: proposalId, decision: .reject) }
            }
            return card
        }
    }

    /// The whole file with the proposal's changes, computed off-main from the proposal's own
    /// base and proposed content (held until it's resolved).
    private func wholeFileDiffProvider(for edit: ProposedEdit) -> ((@escaping (String) -> Void) -> Void)? {
        guard !edit.proposedContent.isEmpty || edit.isNewFile, let projectPath else { return nil }
        let base = edit.baseContent, proposed = edit.proposedContent
        let root = URL(fileURLWithPath: projectPath)
        return { completion in
            DispatchQueue.global(qos: .userInitiated).async {
                let full = GitDiffComputer.unifiedDiffText(original: base, proposed: proposed, projectRoot: root, contextLines: 1_000_000)
                DispatchQueue.main.async { completion(full) }
            }
        }
    }

    private func showCommandResolution(_ card: CommandProposalView, _ command: ProposedCommand, _ resolution: CommandPresentation.Resolution) {
        switch resolution {
        case .executed(let output) where command.fetchURL != nil:
            // A fetched page isn't terminal output: a short preview, no terminal to open.
            let preview = output.isEmpty ? "(no content)" : String(output.prefix(300))
            card.showResolution("Fetched — \(preview)", color: DS.Color.statusVerified)
        case .executed(let output):
            // The terminal's tail, in place (§5.1): what it printed, and the way to its terminal.
            card.showResolution("Ran", color: DS.Color.statusVerified)
            card.showOutputTail(output, onOpenInRun: { [weak self] in self?.onOpenRunRequested?() })
        case .rejected:
            card.showResolution("Rejected", color: .secondaryLabelColor)
        }
    }

    private static func spacing(before kind: RunTranscriptEntry.Kind) -> CGFloat {
        switch kind {
        case .meta, .checkpoint, .userText, .userImage, .assistantText, .proposal, .commandProposal, .permissionRequest: return 8
        case .toolCall, .toolResult, .failure, .thinking: return 4
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
        addBlock(makeLabel(text, font: DS.Text.body(), color: .tertiaryLabelColor), topSpacing: transcriptStack.arrangedSubviews.isEmpty ? 0 : 8)
    }

    /// A tool-activity line whose file paths are clickable.
    ///
    /// These lines are where the agent says what it *did* — "→ read_file path: src/x.ts" — so
    /// the path in them is the most obviously clickable thing in the transcript, and it wasn't.
    /// Bubbles already linkify paths; this brings the same treatment to the lines inside a
    /// Worked group.
    private func makeToolLine(_ text: String, color: NSColor) -> NSView {
        let view = LinkedTextLine()
        view.configure(
            text: text, font: DS.Text.caption(), color: color,
            existingPath: { [weak self] path in self?.mentionedFileExists(path) ?? false }
        )
        view.onPathClicked = { [weak self] path in self?.openMentionedFile(path) }
        return view
    }

    /// Reasoning, trimmed to something a collapsed group can hold.
    ///
    /// Claude 4 and later already return *summarized* thinking, so this is a bound rather than a
    /// summarizer — but a bound is still needed: a local model asked to reason hard will happily
    /// produce twenty thousand characters, and an unbounded label inside a scroll view inside a
    /// group is how a transcript starts dropping frames on every token.
    private static let maxThinkingCharacters = 2_000

    static func condensedThinking(_ text: String) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\n\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > maxThinkingCharacters else { return collapsed }
        // The tail, not the head: reasoning ends where it concluded, and the conclusion is the
        // part worth reading.
        return "…" + String(collapsed.suffix(maxThinkingCharacters))
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
        // Captured so a flush scheduled before a track switch can't apply to the runner that
        // replaced it.
        let scheduledFor = runner
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.035) { [weak self] in
            guard let self else { return }
            self.streamFlushScheduled = false
            guard self.runner === scheduledFor else { return }
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
            // `+ contentInsets.bottom` is load-bearing, and its absence was a shipping bug: the
            // composer floats *over* the transcript, so the real bottom is the content height
            // plus the inset reserving room for it. Without the inset this scrolled to a bottom
            // short by exactly the composer's height, parking the last block underneath it —
            // and when that block was an edit proposal, its Apply and Reject buttons were
            // covered by the composer and could not be clicked at all. The single most
            // important interaction in the app was unreachable, and no test caught it because
            // every test asserts on the model, not on what the composer happens to overlap.
            let maxY = max(0, self.transcriptContainer.bounds.height
                - self.transcriptScroll.contentView.bounds.height
                + self.transcriptScroll.contentInsets.bottom)
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
            case .received: return DS.Color.bubbleReceived
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
        // A bubble built before Think was first on screen got its own frame but never ran its
        // own layout pass, so the text view inside stayed 0×0: every bubble drawn, no text in
        // any, until re-entering Think rebuilt them in-window (owner, 2026-09-23).
        needsLayout = true
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

/// Consecutive tool activity collapsed behind a "Worked 7s · 3 steps" header — the ChatGPT
/// treatment: the work is there for whoever wants it, and one quiet line for everyone else.
/// Lines are added as they happen; the header ticks while the run is live and settles on the
/// final duration when it finishes.
/// One line of text whose file paths are clickable, sized to its content.
///
/// An `NSTextView` rather than an `NSTextField` for the same reason the bubbles use one: it
/// supports real `.link` attributes, so AppKit supplies the hit-testing and the cursor instead
/// of this having to hand-roll glyph geometry.
private final class LinkedTextLine: NSView, NSTextViewDelegate {
    var onPathClicked: ((String) -> Void)?
    private let textView = NSTextView()
    private var widthConstraint: NSLayoutConstraint!
    private var heightConstraint: NSLayoutConstraint!

    /// Same shape rule the bubbles use: something/with/a/slash ending in an extension.
    private static let pathPattern = try? NSRegularExpression(
        pattern: #"[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)+\.[A-Za-z0-9]{1,8}"#
    )

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.delegate = self
        textView.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        textView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textView)
        widthConstraint = textView.widthAnchor.constraint(equalToConstant: 10)
        heightConstraint = textView.heightAnchor.constraint(equalToConstant: 10)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: topAnchor),
            textView.leadingAnchor.constraint(equalTo: leadingAnchor),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor),
            textView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            widthConstraint, heightConstraint,
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(text: String, font: NSFont, color: NSColor, existingPath: (String) -> Bool) {
        let rendered = NSMutableAttributedString(
            string: text, attributes: [.font: font, .foregroundColor: color]
        )
        if let regex = Self.pathPattern {
            let ns = text as NSString
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let path = ns.substring(with: match.range)
                // Existence-checked, so prose that merely looks path-shaped stays prose — the
                // same rule the bubbles apply.
                guard existingPath(path) else { continue }
                let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
                guard let url = URL(string: "side-mention://\(encoded)") else { continue }
                rendered.addAttributes([
                    .link: url,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .foregroundColor: NSColor.controlAccentColor,
                ], range: match.range)
            }
        }
        textView.textStorage?.setAttributedString(rendered)
        let cap: CGFloat = 620
        let bounding = rendered.boundingRect(
            with: NSSize(width: cap, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        widthConstraint.constant = max(10, min(ceil(bounding.width) + 2, cap))
        heightConstraint.constant = max(10, ceil(bounding.height) + 1)
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL, url.scheme == "side-mention" else { return false }
        let path = String(url.absoluteString.dropFirst("side-mention://".count)).removingPercentEncoding ?? ""
        guard !path.isEmpty else { return false }
        onPathClicked?(path)
        return true
    }
}

/// `internal` rather than `private` so its collapse geometry and hit region can be tested.
/// Three separate layout bugs shipped here because the only check was a screenshot.
/// The clickable header of a `WorkGroupView`, exposed to accessibility as the disclosure it is.
///
/// The group toggles via `mouseDown` and a `hitTest` override — invisible to VoiceOver, which
/// meant the agent's reasoning (rendered inside the group since `a324fb0`) and every tool line
/// were mouse-gated. Mirrors `HeaderClickView` in the diff cards: one element, a disclosure
/// role, an expanded state, and a press action that calls the same `toggle()` a click does.
/// (2026-09-01 audit, H15.)
final class WorkGroupHeaderView: NSStackView {
    var onPress: (() -> Void)?
    var isExpandedForAccessibility: () -> Bool = { false }
    var titleForAccessibility: () -> String = { "" }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .disclosureTriangle }
    override func accessibilityLabel() -> String? { titleForAccessibility() }
    override func accessibilityValue() -> Any? { isExpandedForAccessibility() ? "expanded" : "collapsed" }
    override func isAccessibilityExpanded() -> Bool { isExpandedForAccessibility() }
    override func accessibilityActionDescription(_ action: NSAccessibility.Action) -> String? {
        action == .press ? (isExpandedForAccessibility() ? "Collapse" : "Expand") : nil
    }
    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}

final class WorkGroupView: NSView {
    /// Collapsing is done by hiding an **arranged subview of a stack view**, which is the one
    /// mechanism in AppKit that actually removes a view from layout.
    ///
    /// Two wrong answers came first. `content.isHidden` alone did nothing, because the content
    /// was positioned by explicit constraints and a hidden view still contributes its intrinsic
    /// height — that was the tall empty band between messages. Pinning its height to
    /// `fittingSize` instead under-measured wrapping text, so the expanded content overflowed
    /// its own bounds and drew on top of the next message. A stack view answers both: hidden
    /// arranged subviews collapse to nothing, and visible ones get their natural height.
    private let outer = NSStackView()
    private let headerRow = WorkGroupHeaderView()
    private let chevron = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let content = NSStackView()
    private let startedAt: Date
    /// The last line this group received. The duration is measured to *here*, not to whenever
    /// `finish()` happens to be called: a rehydrated transcript finished every group at the
    /// timestamp of the conversation's final entry, so a two-step group from last night
    /// reported "Worked for 676m".
    private var lastLineAt: Date
    private var finishedAt: Date?
    private var stepCount = 0
    private var hasThinking = false
    private var expanded = false
    private var timer: Timer?
    private var didAnchorChevron = false
    private var finished: Bool { finishedAt != nil }

    init(startedAt: Date) {
        self.startedAt = startedAt
        self.lastLineAt = startedAt
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold))
        chevron.contentTintColor = .tertiaryLabelColor
        chevron.wantsLayer = true
        chevron.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            // Fixed size so the title never shifts: the first version swapped
            // chevron.right for chevron.down on a button, and those symbols differ in width.
            chevron.widthAnchor.constraint(equalToConstant: 10),
            chevron.heightAnchor.constraint(equalToConstant: 10),
        ])

        titleLabel.font = DS.Text.caption(.medium)
        titleLabel.textColor = .secondaryLabelColor

        headerRow.setViews([chevron, titleLabel], in: .leading)
        // One spoken element, not three: the chevron and the title are parts of the disclosure.
        chevron.setAccessibilityElement(false)
        titleLabel.setAccessibilityElement(false)
        headerRow.onPress = { [weak self] in self?.toggle() }
        headerRow.isExpandedForAccessibility = { [weak self] in self?.expanded ?? false }
        headerRow.titleForAccessibility = { [weak self] in self?.titleLabel.stringValue ?? "" }
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = DS.Spacing.s

        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = DS.Spacing.xs
        content.isHidden = true
        content.edgeInsets = NSEdgeInsets(top: DS.Spacing.xs, left: 20, bottom: 0, right: 0)

        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 0
        outer.addArrangedSubview(headerRow)
        outer.addArrangedSubview(content)
        outer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(outer)

        NSLayoutConstraint.activate([
            outer.topAnchor.constraint(equalTo: topAnchor),
            outer.leadingAnchor.constraint(equalTo: leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: trailingAnchor),
            outer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        refreshHeader()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The chevron's anchor point is set here, once, and never inside the animation. Changing
    /// `anchorPoint` *moves* a layer, so doing it on the first toggle made the glyph visibly
    /// jump before the rotation started.
    override func layout() {
        super.layout()
        guard !didAnchorChevron, chevron.frame.width > 0, let layer = chevron.layer else { return }
        didAnchorChevron = true
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: chevron.frame.midX, y: chevron.frame.midY)
    }

    // The ticking follows window membership instead of deinit (Swift 6 forbids touching the
    // main-actor Timer there): leaving the window stops the tick; coming back while still
    // unfinished resumes it, so a group discarded mid-run can't orphan a timer.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        timer?.invalidate()
        timer = nil
        if newWindow != nil, !finished {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                DispatchQueue.main.async { self?.refreshHeader() }
            }
        }
    }


    /// Clicks on the header toggle; clicks inside the expanded content fall through to that
    /// line's own links.
    ///
    /// The comparison is `>=`, not `<=`, and that sign is the whole bug history of this method:
    /// this view is **unflipped**, so its stack lays the header out at the *top*, which in
    /// AppKit's default geometry is *high* y. The first version tested `point.y <= maxY`, which
    /// matched everywhere when collapsed and nowhere useful when expanded — the group opened
    /// and then could never be closed.
    override func mouseDown(with event: NSEvent) {
        guard isInHeader(convert(event.locationInWindow, from: nil)) else {
            return super.mouseDown(with: event)
        }
        toggle()
    }

    /// Claims header-region points for this view *before* its subviews see them.
    ///
    /// Without this, `mouseDown` was never called at all: `NSTextField` hit-tests to itself and
    /// swallows the click, so the title label absorbed every press on the header. The very first
    /// version worked only by accident — the header *was* an NSButton, so the button's own
    /// action fired. Replacing it with a chevron plus a label silently removed the click target.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if bounds.contains(local), isInHeader(local) { return self }
        return super.hitTest(point)
    }

    /// This view is **unflipped**, so its stack lays the header out at the *top*, which in
    /// AppKit's default geometry is *high* y — hence `>=`. An earlier `<=` matched everywhere
    /// when collapsed and nowhere useful when expanded, so the group opened and never closed.
    func isInHeader(_ local: NSPoint) -> Bool {
        local.y >= headerRow.frame.minY - DS.Spacing.xs
    }

    override func resetCursorRects() {
        addCursorRect(headerRow.frame.insetBy(dx: 0, dy: -2), cursor: .pointingHand)
    }

    func addLine(_ view: NSView, isStep: Bool, isThinking: Bool = false, at date: Date) {
        content.addArrangedSubview(view)
        lastLineAt = max(lastLineAt, date)
        if isStep { stepCount += 1 }
        if isThinking { hasThinking = true }
        refreshHeader()
    }

    /// Finishes at the group's own last line, which is what the header claims to measure: the
    /// span of the tool work, not the age of the conversation.
    func finish() {
        guard !finished else { return }
        finishedAt = lastLineAt
        timer?.invalidate()
        timer = nil
        refreshHeader()
    }

    private static func format(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded()))
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }

    private func refreshHeader() {
        // Always stated: an earlier version hid the elapsed time whenever the work took under a
        // second, which is most of them, so in practice it never appeared.
        // Live, it ticks from the start; finished, it is the span between first and last line.
        let elapsed = Self.format((finishedAt ?? Date()).timeIntervalSince(startedAt))
        // A turn that reasoned and then answered without calling anything has a group with
        // content but no steps. "Worked for 3s · 0 steps" invites the question "doing what?" and
        // then refuses to answer it; thinking is what it was doing, so the header says so.
        if stepCount == 0, hasThinking {
            titleLabel.stringValue = finished ? "Thought for \(elapsed)" : "Thinking \(elapsed)"
        } else {
            let steps = "\(stepCount) step\(stepCount == 1 ? "" : "s")"
            titleLabel.stringValue = finished
                ? "Worked for \(elapsed) · \(steps)"
                : "Working \(elapsed) · \(steps)"
        }
        // On the header element — the disclosure VoiceOver lands on — and on the group too, which
        // stays a plain container (not an element) so its lines remain reachable underneath.
        headerRow.setAccessibilityLabel(titleLabel.stringValue)
        setAccessibilityLabel(titleLabel.stringValue)
    }

    /// Read by tests and by the header's accessibility state.
    var isExpanded: Bool { expanded }

    @objc func toggle() {
        expanded.toggle()
        NSAccessibility.post(element: headerRow, notification: .valueChanged)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = DS.Motion.duration(0.2)
            context.timingFunction = DS.Motion.curve
            context.allowsImplicitAnimation = true
            // Clockwise: on macOS a layer's positive rotation is counter-clockwise, so pointing
            // a right-facing chevron *down* is a negative angle. The first version used +90 and
            // pointed it up.
            chevron.layer?.transform = CATransform3DMakeRotation(expanded ? -.pi / 2 : 0, 0, 0, 1)
            content.isHidden = !expanded
            enclosingScrollView?.documentView?.layoutSubtreeIfNeeded()
        }
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
    private let editButton = NSButton(title: "", target: nil, action: nil)
    private let actions = NSStackView()
    private var trackingArea: NSTrackingArea?
    /// Set only for a message the user can rewrite — their own. Showing it on an assistant bubble
    /// would offer to edit what the agent said, which "no accidental surveillance" and
    /// attributability both rule out.
    var onEdit: (() -> Void)? {
        didSet { editButton.isHidden = onEdit == nil }
    }

    init(bubble: TextBlockView, alignRight: Bool) {
        self.bubble = bubble
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(bubble)

        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")?.withSymbolConfiguration(config)
        copyButton.isBordered = false
        copyButton.contentTintColor = .tertiaryLabelColor
        copyButton.target = self
        copyButton.action = #selector(copyTapped)
        copyButton.toolTip = "Copy message"
        copyButton.translatesAutoresizingMaskIntoConstraints = false

        editButton.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: "Edit")?.withSymbolConfiguration(config)
        editButton.isBordered = false
        editButton.contentTintColor = .tertiaryLabelColor
        editButton.target = self
        editButton.action = #selector(editTapped)
        editButton.toolTip = "Edit and re-send from here"
        editButton.isHidden = true
        editButton.translatesAutoresizingMaskIntoConstraints = false

        // One fading group, so hover reveals the row rather than each glyph separately.
        actions.orientation = .horizontal
        actions.spacing = 0
        actions.alphaValue = 0
        actions.translatesAutoresizingMaskIntoConstraints = false
        // Edit sits nearer the bubble on both sides: it's the consequential one, and the
        // consequential control belongs closest to the thing it acts on.
        for button in alignRight ? [copyButton, editButton] : [editButton, copyButton] {
            actions.addArrangedSubview(button)
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 22),
                button.heightAnchor.constraint(equalToConstant: 22),
            ])
        }
        addSubview(actions)

        var constraints = [
            bubble.topAnchor.constraint(equalTo: topAnchor),
            bubble.bottomAnchor.constraint(equalTo: bottomAnchor),
            actions.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -6),
        ]
        if alignRight {
            constraints += [
                bubble.trailingAnchor.constraint(equalTo: trailingAnchor),
                bubble.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 60),
                actions.trailingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: -6),
            ]
        } else {
            constraints += [
                bubble.leadingAnchor.constraint(equalTo: leadingAnchor),
                bubble.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -60),
                actions.leadingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: 6),
            ]
        }
        NSLayoutConstraint.activate(constraints)
    }

    /// Dims the bubble while its text is loaded in the composer being rewritten, so it's obvious
    /// which message the composer is about to replace.
    func setEditing(_ editing: Bool) {
        animator().alphaValue = editing ? 0.45 : 1
    }

    /// Off while a turn is running: forking a conversation mid-stream would rewind turns the
    /// model is still answering. Disabled rather than hidden, so the affordance doesn't appear
    /// and vanish as the agent starts and stops.
    var editEnabled: Bool = true {
        didSet {
            editButton.isEnabled = editEnabled
            editButton.toolTip = editEnabled
                ? "Edit and re-send from here"
                : "Wait for the current turn to finish"
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    // Checked against where the pointer actually is, not just which event arrived: rows are
    // built stacked at one origin and laid out a moment later, so a pointer resting there sent
    // every new row a mouseEntered — and no row ever got the matching exit. Every copy and edit
    // icon in the transcript showed at once until each row was hovered.
    private var pointerIsInside: Bool {
        guard let window else { return false }
        return bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }
    override func mouseEntered(with event: NSEvent) { actions.animator().alphaValue = pointerIsInside ? 1 : 0 }
    override func mouseExited(with event: NSEvent) { actions.animator().alphaValue = 0 }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        actions.alphaValue = 0
    }
    override func layout() {
        super.layout()
        // Settle to the truth after every layout pass — including showing them for a row that
        // has just been laid out under a pointer that never moved.
        let shouldShow = pointerIsInside && window?.isKeyWindow == true
        if (actions.alphaValue > 0) != shouldShow { actions.alphaValue = shouldShow ? 1 : 0 }
    }

    @objc private func editTapped() { onEdit?() }

    @objc private func copyTapped() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(bubble.plainText, forType: .string)
        // Quick confirmation: the icon crossfades to a green check, then back — the "it worked"
        // beat every copy affordance owes the user.
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = DS.Motion.duration(0.12)
            copyButton.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self else { return }
            self.copyButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")?.withSymbolConfiguration(config)
            self.copyButton.contentTintColor = .systemGreen
            NSAnimationContext.runAnimationGroup { context in
                context.duration = DS.Motion.duration(0.12)
                self.copyButton.animator().alphaValue = 1
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
                guard let self else { return }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = DS.Motion.duration(0.15)
                    self.copyButton.animator().alphaValue = 0
                } completionHandler: { [weak self] in
                    guard let self else { return }
                    let normalConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
                    self.copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")?.withSymbolConfiguration(normalConfig)
                    self.copyButton.contentTintColor = .tertiaryLabelColor
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = DS.Motion.duration(0.15)
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
        highlight.layer?.cornerRadius = DS.Radius.control
        highlight.bindLayerBackground(NSColor.controlAccentColor)
        highlight.alphaValue = 0
        highlight.translatesAutoresizingMaskIntoConstraints = false
        addSubview(highlight)

        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
        icon.contentTintColor = .labelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)

        label.stringValue = title
        label.font = DS.Text.body()
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

/// What this conversation changed: one row per file, with its own line counts.
///
/// Sorted by size of change rather than alphabetically — the file with forty edited lines is the
/// one worth looking at first, and a path list sorted by name buries it next to a one-line
/// import fix.
private final class ChangedFilesViewController: NSViewController {
    struct Row {
        let path: String
        let added: Int
        let removed: Int
    }

    var files: [Row] = []
    var onOpenFile: ((String) -> Void)?
    var onOpenReview: (() -> Void)?

    override func loadView() { view = NSView() }

    override func viewDidLoad() {
        super.viewDidLoad()

        let totalAdded = files.reduce(0) { $0 + $1.added }
        let totalRemoved = files.reduce(0) { $0 + $1.removed }
        let header = NSTextField(labelWithString: "\(files.count) file\(files.count == 1 ? "" : "s") changed")
        header.font = DS.Text.body(.semibold)
        header.textColor = .labelColor

        let counts = NSTextField(labelWithString: "+\(totalAdded)  −\(totalRemoved)")
        counts.font = DS.Text.caption(.medium)
        counts.textColor = .secondaryLabelColor

        let headerRow = NSStackView(views: [header, NSView(), counts])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.distribution = .fill

        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 1
        for file in files.sorted(by: { ($0.added + $0.removed) > ($1.added + $1.removed) }) {
            let row = ChangedFileRow(file: file) { [weak self] in
                self?.view.window?.performClose(nil)
                self?.onOpenFile?(file.path)
            }
            rows.addArrangedSubview(row)
        }

        // Review is where promoting and undoing live, so the panel points at it rather than
        // reimplementing either — this answers "which files", Review answers "now what".
        let reviewButton = NSButton(title: "Open Review", target: self, action: #selector(reviewTapped))
        reviewButton.bezelStyle = .rounded
        reviewButton.controlSize = .small
        reviewButton.font = DS.Text.caption()

        let stack = NSStackView(views: [headerRow, rows, reviewButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DS.Spacing.m
        stack.edgeInsets = NSEdgeInsets(top: DS.Spacing.l, left: DS.Spacing.l, bottom: DS.Spacing.l, right: DS.Spacing.l)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            view.widthAnchor.constraint(equalToConstant: 420),
            headerRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -DS.Spacing.l * 2),
            rows.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -DS.Spacing.l * 2),
        ])
        for case let row as ChangedFileRow in rows.arrangedSubviews {
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
    }

    @objc private func reviewTapped() {
        view.window?.performClose(nil)
        onOpenReview?()
    }
}

/// One changed file: directory dimmed, filename emphasized, counts right-aligned.
private final class ChangedFileRow: NSView {
    private let highlight = NSView()
    private let pathLabel = NSTextField(labelWithString: "")
    private let countsLabel = NSTextField(labelWithString: "")
    private let action: () -> Void
    private var trackingArea: NSTrackingArea?

    init(file: ChangedFilesViewController.Row, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = DS.Radius.control
        highlight.bindLayerBackground(NSColor.controlAccentColor)
        highlight.alphaValue = 0
        highlight.translatesAutoresizingMaskIntoConstraints = false
        addSubview(highlight)

        // The filename is what identifies the row; the directory is context. Dimming the
        // directory makes a list of deep paths scannable instead of a wall of slashes.
        let separator = (file.path as NSString).lastPathComponent
        let directory = String(file.path.dropLast(separator.count))
        let styled = NSMutableAttributedString(
            string: directory,
            attributes: [.font: DS.Text.body(), .foregroundColor: NSColor.tertiaryLabelColor]
        )
        styled.append(NSAttributedString(
            string: separator,
            attributes: [.font: DS.Text.body(.medium), .foregroundColor: NSColor.labelColor]
        ))
        pathLabel.attributedStringValue = styled
        pathLabel.lineBreakMode = .byTruncatingHead
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pathLabel)

        let counts = NSMutableAttributedString(
            string: "+\(file.added)",
            attributes: [.font: DS.Text.caption(.medium), .foregroundColor: NSColor.systemGreen]
        )
        counts.append(NSAttributedString(
            string: "  −\(file.removed)",
            attributes: [.font: DS.Text.caption(.medium), .foregroundColor: NSColor.systemRed]
        ))
        countsLabel.attributedStringValue = counts
        countsLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(countsLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            highlight.topAnchor.constraint(equalTo: topAnchor),
            highlight.bottomAnchor.constraint(equalTo: bottomAnchor),
            highlight.leadingAnchor.constraint(equalTo: leadingAnchor),
            highlight.trailingAnchor.constraint(equalTo: trailingAnchor),
            pathLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DS.Spacing.s),
            pathLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            countsLabel.leadingAnchor.constraint(greaterThanOrEqualTo: pathLabel.trailingAnchor, constant: DS.Spacing.m),
            countsLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DS.Spacing.s),
            countsLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        toolTip = file.path
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { highlight.alphaValue = 0.18 }
    override func mouseExited(with event: NSEvent) { highlight.alphaValue = 0 }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        action()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// The conversation history picker: one row per past conversation, newest first.
///
/// Rows lead with the conversation's own first message rather than a date, because that is what
/// someone recognizes it by — "the one where I asked about the migration", not "the one from
/// Tuesday". The date and size follow as secondary detail.
private final class ConversationHistoryViewController: NSViewController, NSSearchFieldDelegate {
    var conversations: [ArchivedConversation] = []
    var onSelect: ((UUID) -> Void)?

    private let searchField = NSSearchField()
    private let rows = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "")
    /// Enough to scroll through; the search field is what makes a long history usable, so the
    /// cap exists only to keep the popover from becoming taller than the screen.
    private static let maxRows = 200
    private static let visibleRowLimit = 8

    override func loadView() { view = NSView() }

    override func viewDidLoad() {
        super.viewDidLoad()

        searchField.placeholderString = "Search conversations"
        searchField.delegate = self
        searchField.font = DS.Text.body()
        searchField.translatesAutoresizingMaskIntoConstraints = false

        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 2
        rows.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = DS.Text.caption()
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        // Scrolled, because a history that has to fit in a popover is a history you stop
        // keeping. The row limit above sets the popover's height, not the list's length.
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = rows
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let container = NSStackView(views: [searchField, scroll, emptyLabel])
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = DS.Spacing.s
        container.edgeInsets = NSEdgeInsets(top: DS.Spacing.m, left: DS.Spacing.m, bottom: DS.Spacing.m, right: DS.Spacing.m)
        container.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(container)

        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: view.topAnchor),
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            view.widthAnchor.constraint(equalToConstant: 420),
            searchField.widthAnchor.constraint(equalTo: container.widthAnchor, constant: -DS.Spacing.m * 2),
            scroll.widthAnchor.constraint(equalTo: container.widthAnchor, constant: -DS.Spacing.m * 2),
            rows.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])
        rebuildRows(matching: "")
        // Typing should work the moment the popover opens.
        DispatchQueue.main.async { [weak self] in
            self?.view.window?.makeFirstResponder(self?.searchField)
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        rebuildRows(matching: searchField.stringValue)
    }

    /// Matches on the conversation's own title, case- and diacritic-insensitively — the same
    /// leniency the rest of the app's search uses, since nobody types "café" to find "cafe".
    private func matches(_ conversation: ArchivedConversation, _ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return conversation.title.range(
            of: query, options: [.caseInsensitive, .diacriticInsensitive]
        ) != nil
    }

    private func rebuildRows(matching query: String) {
        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let filtered = conversations.filter { matches($0, query) }.prefix(Self.maxRows)

        emptyLabel.isHidden = !filtered.isEmpty
        if filtered.isEmpty {
            emptyLabel.stringValue = query.isEmpty
                ? "No past conversations on this track yet."
                : "Nothing matches \u{201C}\(query)\u{201D}."
        }

        var rowHeights: CGFloat = 0
        for conversation in filtered {
            let row = ConversationHistoryRow(conversation: conversation) { [weak self] in
                self?.view.window?.performClose(nil)
                self?.onSelect?(conversation.id)
            }
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            rowHeights += 1
        }
        // The popover's height follows the *visible* rows, up to the limit; beyond that the
        // list scrolls rather than the popover growing past the screen.
        let shown = min(rowHeights, CGFloat(Self.visibleRowLimit))
        scrollHeight?.isActive = false
        let height = max(1, shown) * 42
        scrollHeight = rows.enclosingScrollView?.heightAnchor.constraint(equalToConstant: height)
        scrollHeight?.isActive = true
    }

    private var scrollHeight: NSLayoutConstraint?
}

/// One history row: title above, date and turn count below, menu-style highlight on hover.
private final class ConversationHistoryRow: NSView {
    private let highlight = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let action: () -> Void
    private var trackingArea: NSTrackingArea?

    init(conversation: ArchivedConversation, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = DS.Radius.control
        highlight.bindLayerBackground(NSColor.controlAccentColor)
        highlight.alphaValue = 0
        highlight.translatesAutoresizingMaskIntoConstraints = false
        addSubview(highlight)

        titleLabel.stringValue = conversation.title.isEmpty ? "Untitled conversation" : conversation.title
        titleLabel.font = DS.Text.body()
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let when = formatter.localizedString(for: conversation.archivedAt, relativeTo: Date())
        // A branch is labelled as one: it shares a prefix with the conversation still open, so
        // without this the picker offers two rows that differ only in a title nobody remembers
        // choosing.
        let kind = conversation.isBranch ? "branch · " : ""
        detailLabel.stringValue = "\(kind)\(when) · \(conversation.turnCount) turn\(conversation.turnCount == 1 ? "" : "s")"
        detailLabel.font = DS.Text.caption()
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(detailLabel)

        NSLayoutConstraint.activate([
            highlight.topAnchor.constraint(equalTo: topAnchor),
            highlight.bottomAnchor.constraint(equalTo: bottomAnchor),
            highlight.leadingAnchor.constraint(equalTo: leadingAnchor),
            highlight.trailingAnchor.constraint(equalTo: trailingAnchor),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DS.Spacing.l),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -DS.Spacing.l),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
            detailLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DS.Spacing.l),
            detailLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setHighlighted(_ on: Bool) {
        highlight.alphaValue = on ? 1 : 0
        titleLabel.textColor = on ? .white : .labelColor
        detailLabel.textColor = on ? NSColor.white.withAlphaComponent(0.8) : .secondaryLabelColor
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
        action()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// The + button's popover — the same presentation as the session pill, because it feels right:
/// anchored, arrowed, springy. Rows read like menu items but live in the popover material.
private final class PlusActionsViewController: NSViewController {
    var onAttach: (() -> Void)?
    var onAttachImage: (() -> Void)?
    var onOpenRules: (() -> Void)?
    var onShowHistory: (() -> Void)?
    var onCompact: (() -> Void)?
    var onNewConversation: (() -> Void)?

    override func loadView() { view = NSView() }

    override func viewDidLoad() {
        super.viewDidLoad()
        let rows = [
            PopoverActionRow(symbol: "photo", title: "Attach Image…") { [weak self] in self?.dismissThen(self?.onAttachImage) },
            PopoverActionRow(symbol: "text.book.closed", title: "Project Rules…") { [weak self] in self?.dismissThen(self?.onOpenRules) },
            PopoverActionRow(symbol: "clock.arrow.circlepath", title: "History…") { [weak self] in self?.dismissThen(self?.onShowHistory) },
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
    /// The AGENT row: an agent id, "" for Heron.
    var onAgentChosen: ((String) -> Void)?

    private lazy var agentPopup = AgentPicker.makePopup(currentId: nil, target: self, action: #selector(agentChanged))
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
            label.font = DS.Text.caption()
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

        autonomyCaption.font = DS.Text.caption()
        autonomyCaption.textColor = .tertiaryLabelColor
        autonomyCaption.preferredMaxLayoutWidth = 300

        for label in [usageLabel, spendLabel, budgetLabel] {
            label.font = DS.Text.caption()
            label.textColor = .secondaryLabelColor
        }

        let separator = NSBox()
        separator.boxType = .separator

        agentPopup.widthAnchor.constraint(equalToConstant: 312).isActive = true
        AgentAvailability.refresh { [weak self] in
            guard let self else { return }
            AgentPicker.fill(self.agentPopup, currentId: nil)
        }
        let stack = NSStackView(views: [
            caption("AGENT"), agentPopup,
            caption("MODEL"), modelPopup,
            caption("THINKING"), effortControl,
            caption("WHAT THE AGENT CAN DO"), scopeControl,
            caption("WITHOUT ASKING"), autonomyControl, autonomyCaption,
            separator, usageLabel, spendLabel, budgetLabel,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DS.Spacing.s
        stack.setCustomSpacing(DS.Spacing.xl, after: agentPopup)
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

    @objc private func agentChanged() {
        guard let id = agentPopup.selectedItem?.representedObject as? String else { return }
        onAgentChosen?(id)
    }

    @objc private func modelChanged() {
        guard let pair = modelPopup.selectedItem?.representedObject as? [String], pair.count == 2 else { return }
        if pair[0].isEmpty { onModelChosen?(nil, nil) } else { onModelChosen?(pair[0], pair[1]) }
    }



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

    /// Whether the caret sits on the first visual line — the condition under which Up means
    /// "recall" rather than "move the caret".
    var caretIsOnFirstLine: Bool {
        guard let layoutManager, let container = textContainer else { return true }
        let caret = selectedRange().location
        var effective = NSRange()
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: min(caret, max(0, (string as NSString).length - 1)))
        let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &effective)
        let firstRect = layoutManager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        _ = container
        return abs(lineRect.minY - firstRect.minY) < 0.5
    }

    /// Drawn by the text view itself at the glyph origin the layout manager uses, so it can
    /// never disagree with the insertion point — the overlay-label approach kept drifting by a
    /// couple of points (the label cell pads its title rect; the container inset doesn't).
    var placeholderString: String = ""
    var showsPlaceholder = true

    // The placeholder is drawn, so AppKit doesn't know it exists; say it, and what the field is
    // (§4.4, audit 30.10).
    override func accessibilityLabel() -> String? { "Message" }
    override func accessibilityPlaceholderValue() -> String? { placeholderString.isEmpty ? nil : placeholderString }

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
    /// Escape with no candidate list showing. Returns whether it was acted on.
    var onEscape: (() -> Bool)?
    /// The user's own past messages, newest first — supplied by the owner, which has the
    /// conversation. Consulted lazily so it always reflects the current track.
    var messageHistory: (() -> [String])?
    /// How far back the composer is currently showing, 0 meaning "the user's own draft".
    private var historyOffset = 0
    /// What was typed before recall started, so walking back down returns it rather than
    /// leaving the composer holding someone else's sentence.
    private var draftBeforeRecall: String?

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
    /// Fires when the composer starts or stops holding text while focused.
    var onEngagedChanged: ((Bool) -> Void)?
    private var isEngaged = false {
        didSet { if isEngaged != oldValue { onEngagedChanged?(isEngaged) } }
    }
    private let mentionPopup = MentionCompletionPopup()
    /// Whether the popup currently holds slash commands (accepting runs one) rather than
    /// mention paths (accepting inserts one).
    private var popupShowsCommands = false
    /// True from mic-tap until text arrives (or the field is cleared) — keeps the placeholder
    /// from sitting underneath dictation's glowing cursor.
    private var isDictating = false
    private let scroll = NSScrollView()

    private let actionButton = CircularIconButton(diameter: 28)
    /// Replaces Send while no model is set up (§6).
    private let setupButton = NSButton(title: "Set up a model…", target: nil, action: nil)
    var onSetUpModel: (() -> Void)?
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
        setupButton.bezelStyle = .push
        setupButton.controlSize = .small
        setupButton.bezelColor = .controlAccentColor
        setupButton.target = self
        setupButton.action = #selector(setupTapped)
        setupButton.isHidden = true
        setupButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(setupButton)
        NSLayoutConstraint.activate([
            setupButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DS.Spacing.m),
            setupButton.centerYAnchor.constraint(equalTo: bottomAnchor, constant: -Self.capsuleRadius),
        ])
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

    /// Loads text into the field as if it had been typed — used to put a sent message back for
    /// editing.
    func setText(_ text: String) {
        historyOffset = 0
        draftBeforeRecall = nil
        mentionPopup.hide()
        textView.string = text
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        textDidChange(Notification(name: NSText.didChangeNotification))
    }

    /// Restores a sent message's images. Routed back through `addImageAttachment` rather than
    /// pushed straight into `attachments`, so the strip, its chips, and the encoding all come from
    /// the one tested path — an image already within the upload cap survives the round trip
    /// unchanged.
    func setAttachments(_ payloads: [AgentImageAttachment]) {
        attachments.removeAll()
        attachmentStrip.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for payload in payloads {
            guard let data = Data(base64Encoded: payload.base64), let image = NSImage(data: data) else { continue }
            addImageAttachment(image)
        }
        updateStripSpace(animated: false)
    }

    private func removeAttachment(id: UUID) {
        attachments.removeAll { $0.id == id }
        guard let chip = attachmentStrip.arrangedSubviews.first(where: { $0.identifier?.rawValue == id.uuidString }) else {
            return updateStripSpace(animated: true)
        }
        // The object leaves, then the space closes — a short fade first, so the collapse never
        // shows a band of empty strip where the chip just was.
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = DS.Motion.duration(0.12)
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
            context.duration = DS.Motion.duration(0.18)
            context.timingFunction = DS.Motion.curve
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

    /// Walks the recall window. Returns whether it consumed the key.
    private func recallHistory(offset: Int) -> Bool {
        guard let history = messageHistory?(), !history.isEmpty else { return false }
        let target = historyOffset + offset
        guard target >= 0, target <= history.count else { return false }
        if historyOffset == 0, target > 0 { draftBeforeRecall = textView.string }
        historyOffset = target
        let text = target == 0 ? (draftBeforeRecall ?? "") : history[target - 1]
        textView.string = text
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        textDidChange(Notification(name: NSText.didChangeNotification))
        return true
    }

    func clear() {
        // A sent message ends the recall window — the next Up starts from the newest again.
        historyOffset = 0
        draftBeforeRecall = nil
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
    @objc private func setupTapped() { onSetUpModel?() }

    func setNeedsModelSetup(_ needed: Bool) {
        setupButton.isHidden = !needed
        actionButton.isHidden = needed
        // Dictation sits beside Send; the wider setup button takes both places.
        micButton.isHidden = needed
    }

    func textDidEndEditing(_ notification: Notification) { isEngaged = false }

    func textDidChange(_ notification: Notification) {
        isEngaged = !textView.string.isEmpty && textView.window?.firstResponder === textView
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
        // Escape stops the run — with the candidate list already handled above, so Escape's
        // first job is still dismissing it. Reaching for the mouse should never be the only way
        // to interrupt an agent.
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            return onEscape?() ?? false
        }
        // Shell-style recall, with the one guard that keeps it from breaking editing: Up only
        // recalls while the caret is on the first line, so inside a multi-line message it still
        // moves the caret. Down walks back toward the draft.
        if commandSelector == #selector(NSResponder.moveUp(_:)), self.textView.caretIsOnFirstLine {
            return recallHistory(offset: 1)
        }
        if commandSelector == #selector(NSResponder.moveDown(_:)), historyOffset > 0 {
            return recallHistory(offset: -1)
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

extension ThinkWorkspaceViewController: StageChromeProviding {
    var scrollViewUnderTopRow: NSScrollView? { loadViewIfNeeded(); return transcriptScroll }
    var topRowContent: NSView? {
        loadViewIfNeeded()
        conversationTitle.font = DS.Text.caption()
        conversationTitle.textColor = .secondaryLabelColor
        conversationTitle.lineBreakMode = .byTruncatingTail
        conversationTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        refreshConversationTitle()
        return conversationTitle
    }

    var barAccessories: (leading: NSView?, trailing: NSView?) {
        loadViewIfNeeded()
        return (changesGroup, sessionGroup)
    }

    /// The pills' type: the bar's own 13 pt medium when they sit in it, so every piece of the
    /// bar reads at one size; composer-caption size above the composer.
    private var pillFont: NSFont { pillsDocked ? DS.Text.body(.medium) : DS.Text.caption(.medium) }

    /// Docked: the pills live in the window's bar row and the editing chip takes the composer's
    /// leading corner. Undocked: back above the composer, where they were.
    func setAccessoriesDocked(_ docked: Bool) {
        loadViewIfNeeded()
        pillsDocked = docked
        // In the bar they are bar pieces: 40 pt glass capsules (36 pt chip + the glass's 2 pt
        // rim), the same height as the track pill and the stage control beside them.
        let chipHeight: CGFloat = docked ? ChromeHost.barHeight - 4 : 24
        for chip in [changesPill, sessionPill] { chip.setHeight(chipHeight); chip.font = pillFont }
        for glass in [changesPillGlass, sessionPillGlass] { DS.setGlassCornerRadius(glass, (chipHeight + 4) / 2) }
        pillModeTint.layer?.cornerRadius = (chipHeight + 4) / 2
        refreshChangesPill()
        refreshSessionPill()
        if !docked {
            for group in [changesGroup, sessionGroup] where group.superview !== view {
                group.removeFromSuperview()
                view.addSubview(group, positioned: .below, relativeTo: queuedChipGlass)
            }
        }
        NSLayoutConstraint.deactivate(undockedPillConstraints + [editingChipLeading])
        editingChipLeading = docked
            ? editingChip.leadingAnchor.constraint(equalTo: composer.leadingAnchor, constant: DS.Spacing.xs)
            : editingChip.leadingAnchor.constraint(equalTo: changesPill.trailingAnchor, constant: DS.Spacing.xl + DS.Spacing.s * 2)
        if !docked { NSLayoutConstraint.activate(undockedPillConstraints) }
        editingChipLeading.isActive = true
        view.needsLayout = true
    }

    func setBottomObstruction(_ height: CGFloat) {
        loadViewIfNeeded()
        bottomObstruction = height
        composerBottom.constant = -composerGap
        view.needsLayout = true
    }
}

/// A checkpoint marker in the transcript: reads like the other meta lines, underlines on hover,
/// and opens the checkpoint's sheet on click or VoiceOver press.
private final class CheckpointLineButton: NSButton {
    var onOpen: (() -> Void)?
    private var text = ""
    private var hovering = false { didSet { restyle() } }

    init(text: String) {
        super.init(frame: .zero)
        isBordered = false
        translatesAutoresizingMaskIntoConstraints = false
        target = self
        action = #selector(open)
        setText(text)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setText(_ text: String) {
        self.text = text
        restyle()
        setAccessibilityLabel(text)
        setAccessibilityHelp("Shows this checkpoint's files and changes")
    }

    private func restyle() {
        var attributes: [NSAttributedString.Key: Any] = [.font: DS.Text.body(), .foregroundColor: hovering ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor]
        if hovering { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        attributedTitle = NSAttributedString(string: text, attributes: attributes)
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    @objc private func open() { onOpen?() }
}

/// An outside agent's permission prompt: what it wants to do, and its own options as buttons —
/// the allow options first and emphasised. Once answered, the choice replaces the buttons.
private final class PermissionRequestView: NSView {
    var onChoose: ((String) -> Void)?
    private let buttonRow = NSStackView()
    private let choiceLabel = NSTextField(labelWithString: "")

    init(presentation: PermissionPresentation) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = DS.Radius.surface
        bindLayerBackground(DS.Color.raised)
        let title = NSTextField(wrappingLabelWithString: presentation.title)
        title.font = DS.Text.body(.semibold)
        buttonRow.orientation = .horizontal
        buttonRow.spacing = DS.Spacing.m
        let ordered = presentation.options.sorted { lhs, rhs in
            func rank(_ option: PermissionPresentation.Option) -> Int {
                switch option.kind { case .allowOnce: 0; case .allowAlways: 1; case .rejectOnce: 2; case .rejectAlways: 3; case nil: 4 }
            }
            return rank(lhs) < rank(rhs)
        }
        for (index, option) in ordered.enumerated() {
            let button = NSButton(title: option.name, target: self, action: #selector(chose(_:)))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.identifier = NSUserInterfaceItemIdentifier(option.id)
            if index == 0, option.kind == .allowOnce { button.keyEquivalent = "\r" }
            buttonRow.addArrangedSubview(button)
        }
        choiceLabel.font = DS.Text.caption(.medium)
        choiceLabel.textColor = .secondaryLabelColor
        choiceLabel.isHidden = true
        buttonRow.addArrangedSubview(choiceLabel)
        let stack = NSStackView(views: [title, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DS.Spacing.m
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            title.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -24),
        ])
        if let chosen = presentation.chosenOptionName { showChoice(chosen) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Permission request: \(presentation.title)")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func showChoice(_ name: String) {
        for view in buttonRow.arrangedSubviews where view is NSButton { view.isHidden = true }
        choiceLabel.stringValue = name
        choiceLabel.isHidden = false
    }

    @objc private func chose(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        onChoose?(id)
    }
}

