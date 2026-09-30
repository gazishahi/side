import AppKit
import Heron

/// Plain `NSView` subviews (labels, chip containers) don't accept first responder, so without
/// this the responder chain never reaches `TracksWorkspaceViewController` while its stage is
/// visible — see the comment on `viewDidAppear` below.
///
/// Also overrides `isFlipped`: as an `NSScrollView` document view, an unflipped view (the
/// default) gets positioned at the *bottom* of the clip view whenever its content doesn't fill
/// the whole visible height — with just a banner and a couple of cards, that left the ledger
/// pinned to the bottom of the window with a large empty gap above it instead of starting at
/// the top.
private final class FocusableContainerView: NSView {
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    /// ↑ ↓ and Return, for the list.
    var onKey: ((NSEvent) -> Bool)?
    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }
}

/// Colors for the grouped-card ledger. Deliberately restrained: one neutral card surface, one
/// hairline, no per-status color coding — the section label already says the status in words, so
/// a colored dot repeating it would just be noise. The app's own accent shows up only on buttons.
/// Thin forwarding layer onto `DS` (the charter's token file) — kept so Tracks' many call sites
/// didn't all churn in the migration, but every value now has exactly one definition.


final class TracksWorkspaceViewController: NSViewController {
    private let scrollView = NSScrollView()
    private let documentContainer = FocusableContainerView()
    /// The selected track, in full, beside the list (T1). Hidden when the stage is narrow.
    private let detailView = TrackDetailView()
    private var selectedTrackID: UUID?
    private var listWidth: NSLayoutConstraint?
    private var listToEdge: NSLayoutConstraint?
    private weak var sessionStore: AgentSessionStore?
    /// The rows as shown, top to bottom, for moving the selection with the keys.
    private var shownTrackOrder: [UUID] = []
    private var rowViews: [UUID: TrackRowView] = [:]
    private static let listWidthValue: CGFloat = 360
    private static let detailMinimumStageWidth: CGFloat = 740
    private let contentStack = NSStackView()

    private let newTrackButton = NSButton(title: "New Track", target: nil, action: nil)
    /// Filters intent and branch — archived tracks included (constitution: "search retrieves
    /// archived work").
    private let searchField = NSSearchField()
    private var searchQuery: String { searchField.stringValue.trimmingCharacters(in: .whitespaces) }
    /// Branches Side didn't create, fetched off the render path; one line, not rows.
    private var untrackedBranchCount = 0
    private let showArchivedButton = NSButton(checkboxWithTitle: "Show Archived", target: nil, action: nil)
    private let archivedCountLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private var statusLabelHideWorkItem: DispatchWorkItem?
    private let headerStack = NSStackView()
    /// "Tracks" and its counts, in the window's top row (Direction 02 §3.2).
    private let topHeader = NSStackView()
    private let topTitle = NSTextField(labelWithString: "Tracks")
    private let topCounts = NSTextField(labelWithString: "")
    private let topControlsRow = NSStackView()

    /// Populated asynchronously by `refreshGitSummariesIfNeeded()` — never read from git
    /// synchronously during a render. Rows just show nothing extra until their entry arrives.
    private var gitSummaryCache: [UUID: TrackStore.GitSummary] = [:]
    private var isRefreshingGitSummaries = false

    private var trackStore: TrackStore? {
        didSet { refreshUI() }
    }
    /// Non-creating lookups only (`existingRunner`) — this view must never spin up a runner just
    /// by rendering a row for a track that's never had an agent touch it.
    private var runnerManager: AgentRunnerManager?

    /// ShellViewController owns `TrackStore.onChange` and `AgentRunnerManager`'s debounced
    /// change multicast (it also has to keep Make's per-track file memory and the stage badge in
    /// sync), so it calls this instead of this controller wiring either callback itself.
    func refresh() { refreshUI() }

    @objc private func textScaleChanged() { refreshUI() }

    /// ShellViewController supplies this — it owns the cross-stage guard (unsaved Make edits)
    /// and decides what happens after a successful switch (land on Make). `nil` in the
    /// completion means the switch failed or was cancelled; otherwise it carries what happened
    /// to any uncommitted changes so it can be surfaced to the user.
    var onSwitchRequested: ((Track, @escaping (TrackSwitchOutcome?) -> Void) -> Void)?

    /// A verb that lands on a specific stage — Review's "Review" goes to Review, not Think.
    var onOpenStageRequested: ((Track, ShellViewController.Stage) -> Void)?

    /// ShellViewController resolves unsaved Make edits before letting a new track's checkout
    /// proceed — same guard `onSwitchRequested` uses, since creating a track moves `HEAD` just
    /// like switching to an existing one does.
    var onCreateTrackRequested: ((@escaping (Bool) -> Void) -> Void)?

    /// A brand-new track is already active by construction (unlike switching to an existing,
    /// currently-inactive one), so it can't be routed through `onSwitchRequested` — that closure's
    /// caller no-ops when asked to "switch" to whatever's already active. This is the separate
    /// notification for "a track now exists and is checked out — reflect that."
    var onTrackCreated: ((Track) -> Void)?

    /// Fired after switching to an existing (previously untracked) branch — no `Track` exists yet,
    /// just a branch name, so this can't reuse `onTrackCreated` either. ShellViewController reloads
    /// Make/Run onto this branch's own memory and lands on Make, same as it does after creating one.
    var onBranchSwitched: ((String) -> Void)?

    /// ShellViewController uses this to drop the deleted track's per-track state elsewhere
    /// (Make's remembered file, Run's terminal sessions) — this controller only owns the ledger
    /// itself, not those other stages' bookkeeping.
    var onTrackDeleted: ((Track) -> Void)?
    /// Set by the shell, which performs empty-state actions (§6).
    var onEmptyStateAction: ((EmptyStateAction) -> Void)?

    func configure(with store: TrackStore, runnerManager: AgentRunnerManager, sessionStore: AgentSessionStore? = nil) {
        self.runnerManager = runnerManager
        self.sessionStore = sessionStore
        trackStore = store
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // Catches drift from branch switches made outside Side (a terminal in Run, another git
        // client) since the last time this stage was visible — not just at project-open time.
        trackStore?.reconcile()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Unlike Make (editor grabs focus on file open) or Run (the terminal view grabs it on
        // activate), nothing here claims first responder on its own — without this, the
        // responder chain never reaches this controller, so menu-routed actions like "Track >
        // New Track…" silently go nowhere while this stage is visible.
        view.window?.makeFirstResponder(documentContainer)
    }

    private var showArchived = false

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    override func loadView() { view = NSView() }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildView()
        NotificationCenter.default.addObserver(
            self, selector: #selector(textScaleChanged),
            name: DS.Text.scaleDidChangeNotification, object: nil
        )
    }

    private func buildView() {
        view.wantsLayer = true
        ChromeBackground.install(in: view)

        newTrackButton.target = self
        newTrackButton.action = #selector(newTrackTapped)
        newTrackButton.bezelStyle = .push
        // The screen's one accent-filled action (§4 shared rules).
        newTrackButton.bezelColor = .controlAccentColor
        newTrackButton.keyEquivalent = "\r"

        searchField.placeholderString = "Search tracks"
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        searchField.setAccessibilityLabel("Search tracks")

        showArchivedButton.target = self
        showArchivedButton.action = #selector(showArchivedToggled)

        archivedCountLabel.font = DS.Text.caption()
        archivedCountLabel.textColor = .tertiaryLabelColor

        statusLabel.font = DS.Text.caption()
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.alphaValue = 0

        topControlsRow.orientation = .horizontal
        topControlsRow.alignment = .centerY
        topControlsRow.spacing = DS.Spacing.xl
        [newTrackButton, searchField, showArchivedButton, archivedCountLabel, statusLabel].forEach(topControlsRow.addArrangedSubview)

        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = DS.Spacing.l
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerStack.addArrangedSubview(topControlsRow)
        view.addSubview(headerStack)

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = DS.Spacing.section
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        // NSScrollView doesn't auto-manage this for its documentView the way NSStackView does
        // for arranged subviews — without it, AppKit's autoresizing-mask-derived constraints
        // (from this view's zero starting frame) fight the explicit Auto Layout constraints
        // below, and the resulting conflict can shrink the whole window to near-zero width.
        documentContainer.translatesAutoresizingMaskIntoConstraints = false
        documentContainer.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: documentContainer.topAnchor, constant: 2),
            contentStack.leadingAnchor.constraint(equalTo: documentContainer.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: documentContainer.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: documentContainer.bottomAnchor, constant: -20)
        ])

        scrollView.documentView = documentContainer
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        view.addSubview(detailView)
        let width = scrollView.widthAnchor.constraint(equalToConstant: Self.listWidthValue)
        let edge = scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16)
        listWidth = width
        listToEdge = edge
        edge.isActive = true
        wireDetail()
        documentContainer.onKey = { [weak self] event in self?.handleListKey(event) ?? false }

        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 16 + ChromeHost.rowHeight),
            headerStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            headerStack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
            scrollView.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 14),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            detailView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            detailView.leadingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: 16),
            detailView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            detailView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),

            documentContainer.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentContainer.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor)
        ])
    }

    // MARK: - The selected track

    /// Wide enough, the list narrows and the selected track shows beside it.
    override func viewDidLayout() {
        super.viewDidLayout()
        let showDetail = view.bounds.width >= Self.detailMinimumStageWidth && trackStore != nil && trackStore?.repoState != .notAGitRepo
        if detailView.isHidden == showDetail {
            detailView.isHidden = !showDetail
            listToEdge?.isActive = !showDetail
            listWidth?.isActive = showDetail
            renderLedger()
        }
    }

    private var showsDetail: Bool { !detailView.isHidden }

    private func wireDetail() {
        detailView.isHidden = true
        detailView.onSwitch = { [weak self] in
            guard let self, let track = self.selectedTrack else { return }
            self.requestSwitch(to: track)
        }
        detailView.onOpenStage = { [weak self] stage in
            guard let self, let track = self.selectedTrack else { return }
            self.onOpenStageRequested?(track, stage)
        }
        detailView.onMore = { [weak self] anchor in
            guard let self, let track = self.selectedTrack else { return }
            self.buildContextMenu(for: track).popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 4), in: anchor)
        }
    }

    private var selectedTrack: Track? { selectedTrackID.flatMap { id in trackStore?.tracks.first { $0.id == id } } }

    private func select(_ track: Track) {
        selectedTrackID = track.id
        for (id, row) in rowViews { row.isSelected = id == track.id }
        rowViews[track.id]?.scrollToVisible(rowViews[track.id]?.bounds ?? .zero)
        updateDetail()
    }

    /// The pane, from the selected track (or the current one, or the first, when none is).
    private func updateDetail() {
        guard showsDetail, let store = trackStore else { return }
        if selectedTrack == nil || !shownTrackOrder.contains(selectedTrackID!) {
            let current = store.tracks.first { $0.status == .active && shownTrackOrder.contains($0.id) }
            selectedTrackID = current?.id ?? shownTrackOrder.first
            for (id, row) in rowViews { row.isSelected = id == selectedTrackID }
        }
        guard let track = selectedTrack else { detailView.show(nil); return }
        let activity = activity(for: track)
        let checkpoints = (sessionStore?.checkpoints(forTrackKey: track.branchName) ?? []).sorted { $0.createdAt > $1.createdAt }
        let harness = store.harness(forTrackKey: track.branchName)
        let agent = harness?.displayName ?? ([track.modelId].compactMap { $0 }.first.map { "Side\u{2019}s agent \u{00B7} \($0)" } ?? "Side\u{2019}s agent")
        let parent = track.parentTrackId.flatMap { id in store.tracks.first { $0.id == id } }
        detailView.show(TrackDetail(
            track: track,
            isCurrent: track.status == .active,
            state: DS.StatusState(track: track.displayStatus, activity: activity),
            stateText: TrackRowView.statusText(activity: activity, status: track.displayStatus),
            baseRef: ReviewWorkspaceViewController.baseRef(for: track, trackStore: store),
            summary: gitSummaryCache[track.id],
            agent: agent,
            autonomy: track.autonomy?.displayName,
            parentIntent: parent.map { $0.intent.isEmpty ? $0.branchName : $0.intent },
            subtracks: store.tracks.filter { $0.parentTrackId == track.id }.count,
            checkpoints: Array(checkpoints.prefix(5)),
            checkpointCount: checkpoints.count
        ))
    }

    /// ↑ ↓ move the selection; Return switches to it.
    private func handleListKey(_ event: NSEvent) -> Bool {
        guard showsDetail, !shownTrackOrder.isEmpty else { return false }
        let index = selectedTrackID.flatMap { shownTrackOrder.firstIndex(of: $0) }
        switch event.specialKey {
        case .downArrow?:
            let next = min(shownTrackOrder.count - 1, (index ?? -1) + 1)
            if let track = trackStore?.tracks.first(where: { $0.id == shownTrackOrder[next] }) { select(track) }
            return true
        case .upArrow?:
            let next = max(0, (index ?? 1) - 1)
            if let track = trackStore?.tracks.first(where: { $0.id == shownTrackOrder[next] }) { select(track) }
            return true
        case .carriageReturn?, .enter?:
            if let track = selectedTrack, track.status != .active { requestSwitch(to: track) }
            return true
        default:
            return false
        }
    }

    // MARK: - Tests

    var detailForTesting: TrackDetailView { detailView }
    var selectedTrackForTesting: Track? { selectedTrack }
    func selectForTesting(_ track: Track) { select(track) }
    func keyForTesting(_ event: NSEvent) -> Bool { handleListKey(event) }

    // MARK: - Building the grouped-card content

    /// Single entry point for "the ledger's contents might have changed" — rebuilds the banner and
    /// every status group from scratch (track lists here are always small, tens of entries at
    /// most, so a full rebuild is simpler than diffing) and kicks off a background refresh of
    /// each row's git ahead/behind/uncommitted summary. Deliberately two separate steps: the
    /// rebuild itself stays synchronous and cheap (in-memory only), while the git calls that back
    /// `gitSummaryText` run off-thread and just re-render again once they land — a ledger with
    /// more than a couple of tracks would otherwise block the main thread on a chain of blocking
    /// `git` subprocess spawns every single time the ledger changes.
    private func refreshUI() {
        refreshTopHeader()
        renderLedger()
        refreshGitSummariesIfNeeded()
        refreshUntrackedBranchCount()
    }

    private func refreshGitSummariesIfNeeded() {
        guard !isRefreshingGitSummaries, let store = trackStore, store.repoState != .notAGitRepo else { return }
        isRefreshingGitSummaries = true
        // Every main-actor value the git work needs is snapshotted *here*, on the main actor,
        // and carried into the background as plain data. The old shape captured `store` itself
        // and called into it from the background queue, reading `tracks` and the default branch
        // while main was free to mutate them — a real race the compiler couldn't see, because
        // TrackStore declared no isolation for it to check.
        let inputs = store.tracks.map { store.gitSummaryInputs(for: $0) }
        let summarize = store.gitSummary
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var results: [UUID: TrackStore.GitSummary] = [:]
            for input in inputs { results[input.track.id] = summarize(input) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRefreshingGitSummaries = false
                self.gitSummaryCache = results
                self.renderLedger()
            }
        }
    }

    private func renderLedger() {
        contentStack.arrangedSubviews.forEach {
            contentStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        shownTrackOrder = []
        rowViews = [:]
        defer { updateDetail() }

        // A plain folder with no `.git` yet (or one where it disappeared) can't do anything
        // Tracks-related — every git call would just fail. Show that plainly instead of letting
        // raw git stderr leak into the banner as if it were a branch name.
        // `trackStore == nil` means no project is open at all — and the old expression
        // (`repoState != .notAGitRepo`) was *true* in that case, since nil compares unequal to
        // anything. So Tracks showed "No tracks yet — create one to get started." beside an
        // enabled New Track button whose handler immediately `guard let store` returned: a
        // button that looked ready and silently did nothing.
        let hasProject = trackStore != nil
        let isRepo = hasProject && trackStore?.repoState != .notAGitRepo
        newTrackButton.isEnabled = isRepo
        searchField.isEnabled = isRepo
        showArchivedButton.isEnabled = isRepo
        guard hasProject else {
            addEmptyState("Open a project to see its tracks.", action: "Open Project…") { [weak self] in self?.onEmptyStateAction?(.openProject) }
            updateArchivedCountLabel()
            return
        }
        guard isRepo else {
            let banner = makeNotAGitRepoBanner()
            contentStack.addArrangedSubview(banner)
            banner.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
            updateArchivedCountLabel()
            return
        }

        if trackStore?.isDetachedHead == true {
            let banner = makeDetachedHeadBanner()
            contentStack.addArrangedSubview(banner)
            banner.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        } else if let branch = trackStore?.untrackedBranch {
            let banner = makeBannerCard(branchName: branch)
            contentStack.addArrangedSubview(banner)
            banner.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }

        let needsYou = needsYouTracks()
        let pinnedIDs = Set(needsYou.map(\.id))
        // Everything not pinned, flat on canvas; a pinned track appears once, in the group.
        let rest = families().map { $0.filter { !pinnedIDs.contains($0.id) } }.filter { !$0.isEmpty }
        if needsYou.isEmpty && rest.isEmpty {
            if searchQuery.isEmpty {
                addEmptyState("A track is one line of work, on its own branch.", action: "New Track") { [weak self] in self?.newTrackTapped() }
            } else {
                let empty = NSTextField(labelWithString: "No tracks match \u{201C}\(searchQuery)\u{201D}.")
                empty.font = DS.Text.body()
                empty.textColor = .tertiaryLabelColor
                contentStack.addArrangedSubview(empty)
                empty.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
            }
        } else {
            // Pinned first, on `raised` — the one grouped surface on the stage (§4.1). Drawn
            // from activity, not `TrackStatus`: a blocked agent on a `.waiting` track would
            // otherwise sink into rows that read as "nothing happening."
            if !needsYou.isEmpty {
                let group = makeGroup(label: "NEEDS YOU", tracks: needsYou)
                contentStack.addArrangedSubview(group)
                group.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
            }
            if !rest.isEmpty {
                let list = makeRows(tracks: rest.flatMap { $0 }, onRaised: false)
                contentStack.addArrangedSubview(list)
                list.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
            }
        }
        if untrackedBranchCount > 0 && searchQuery.isEmpty {
            let line = makeUntrackedBranchesLine(count: untrackedBranchCount)
            contentStack.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }

        updateArchivedCountLabel()
    }

    /// Archived work shows when asked for — the toggle, or a search, which reaches it too.
    /// §6: one sentence and its one action, centred in the space the list would fill.
    private func addEmptyState(_ text: String, action: String, handler: @escaping () -> Void) {
        let state = DS.EmptyState()
        state.configure(text, action: action, handler: handler)
        state.edgeInsets = NSEdgeInsets(top: 80, left: 0, bottom: 0, right: 0)
        contentStack.addArrangedSubview(state)
        state.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
    }

    /// For the shell's "Initialize Git…" from other stages' empty states.
    func initializeGit() { initializeGitTapped() }

    private func visibleTracks() -> [Track] {
        let all = trackStore?.tracks ?? []
        let query = searchQuery
        guard !query.isEmpty else { return showArchived ? all : all.filter { $0.status != .archived } }
        return all.filter { $0.intent.localizedCaseInsensitiveContains(query) || $0.branchName.localizedCaseInsensitiveContains(query) }
    }

    @objc private func searchChanged() { renderLedger() }

    /// One line per project for branches Side didn't create (§4.1) — adopting one is the
    /// existing "switch to an existing branch" flow.
    private func makeUntrackedBranchesLine(count: Int) -> NSView {
        let label = NSTextField(labelWithString: count == 1 ? "1 untracked branch" : "\(count) untracked branches")
        label.font = DS.Text.caption()
        label.textColor = .secondaryLabelColor
        let adopt = NSButton(title: "", target: self, action: #selector(switchExistingBranchTapped))
        adopt.isBordered = false
        adopt.attributedTitle = NSAttributedString(string: "Adopt…", attributes: [.font: DS.Text.caption(.medium), .foregroundColor: NSColor.labelColor])
        let row = NSStackView(views: [label, adopt])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = DS.Spacing.m
        row.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        return row
    }

    private func refreshUntrackedBranchCount() {
        guard let store = trackStore, store.repoState != .notAGitRepo else { return }
        store.availableBranchesToAdopt { [weak self] branches in
            guard let self, self.untrackedBranchCount != branches.count else { return }
            self.untrackedBranchCount = branches.count
            self.renderLedger()
        }
    }

    /// Grouped by lineage rather than by status — a stacked track's card is its root plus every
    /// descendant, so "your branch, and its worktrees underneath it" is the shape on screen, not
    /// an artifact you have to reconstruct from a breadcrumb. Status now lives on each row (see
    /// `TrackRowView`'s status pill) instead of being the thing that decides which card a track
    /// lands in. Families are ordered by whichever member was active most recently, so a family
    /// with fresh child activity still surfaces near the top even if its root has gone quiet.
    private func families() -> [[Track]] {
        let all = visibleTracks()
        let byId = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        var childrenOf: [UUID: [Track]] = [:]
        var roots: [Track] = []
        for track in all {
            if let parentId = track.parentTrackId, byId[parentId] != nil {
                childrenOf[parentId, default: []].append(track)
            } else {
                roots.append(track)
            }
        }
        func collect(_ track: Track) -> [Track] {
            [track] + (childrenOf[track.id] ?? []).flatMap(collect)
        }
        // Live families first, then parked/finished ones; newest first within each, so the
        // oldest parked work sinks to the bottom (§4.1).
        func isResting(_ family: [Track]) -> Bool { family.allSatisfy { [.parked, .completed, .archived].contains($0.status) } }
        return roots
            .map(collect)
            .sorted { lhs, rhs in
                if isResting(lhs) != isResting(rhs) { return !isResting(lhs) }
                return (lhs.map(\.lastActiveAt).max() ?? .distantPast) > (rhs.map(\.lastActiveAt).max() ?? .distantPast)
            }
    }

    /// The runner never writes `TrackStatus` — this is entirely a machine-computed, ephemeral
    /// view over `AgentActivity`, recomputed on every render rather than cached anywhere.
    private func activity(for track: Track) -> AgentActivity {
        runnerManager?.existingRunner(forTrackKey: track.branchName)?.activity ?? .none
    }

    /// Ordered by how long each track has actually been waiting on a decision — oldest first —
    /// rather than `Track.lastActiveAt` (which only updates on a track switch, so a track you
    /// left the instant before it blocked would misleadingly rank above one that's been sitting
    /// unaddressed for hours). Falls back to `lastActiveAt` only for the situation that should
    /// never happen (a track reads as `.needsYou` but its runner has no `needsYouSince` recorded),
    /// so a row still renders somewhere sane instead of silently vanishing from this section.
    private func needsYouTracks() -> [Track] {
        (trackStore?.tracks ?? [])
            .filter { activity(for: $0).wantsAttention }
            .sorted { needsYouSince(for: $0) < needsYouSince(for: $1) }
    }

    private func needsYouSince(for track: Track) -> Date {
        runnerManager?.existingRunner(forTrackKey: track.branchName)?.needsYouSince ?? track.lastActiveAt
    }

    private func makeGroup(label: String, tracks: [Track]) -> NSView {
        let groupStack = NSStackView()
        groupStack.orientation = .vertical
        groupStack.alignment = .leading
        groupStack.spacing = DS.Spacing.s

        // Uppercase only for 11 pt section labels (§4 shared rules).
        let labelField = NSTextField(labelWithString: label)
        labelField.font = DS.Text.custom(11, weight: .semibold)
        labelField.textColor = .secondaryLabelColor
        groupStack.addArrangedSubview(labelField)

        let card = makeRows(tracks: tracks, onRaised: true)
        groupStack.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: groupStack.widthAnchor).isActive = true

        return groupStack
    }

    /// Rows with hairlines between them. On `raised` (the pinned group) the tone *is* the card,
    /// with 6/14 padding; everywhere else the rows sit flat on canvas (§4.1).
    private func makeRows(tracks: [Track], onRaised: Bool) -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = DS.Radius.surface
        if onRaised { card.bindLayerBackground(DS.Color.raised) }
        card.layer?.masksToBounds = true

        let rowsStack = NSStackView()
        rowsStack.orientation = .vertical
        rowsStack.spacing = 0
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        let ordered = nestedOrder(tracks)
        for (index, entry) in ordered.enumerated() {
            // A child's connector keeps running downward when the next row is a sibling child;
            // for the last child it stops at this row's curve.
            let nextIsChild = index + 1 < ordered.count && ordered[index + 1].indent
            let row = makeRow(for: entry.track, indent: entry.indent, connectorContinues: entry.indent && nextIsChild)
            row.hoverTone = onRaised ? DS.Color.overlay : DS.Color.raised
            row.layer?.cornerRadius = DS.Radius.control
            rowsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
            if index < ordered.count - 1 {
                // When the next row is a child, inset the hairline past the connector column so
                // the branch line runs unbroken from parent to child instead of being sliced.
                let inset: CGFloat = nextIsChild ? 14 + TrackRowView.indentWidth : 0
                let hairlineRow = NSView()
                hairlineRow.translatesAutoresizingMaskIntoConstraints = false
                let hairline = NSBox()
                hairline.boxType = .custom
                hairline.borderType = .noBorder
                hairline.fillColor = DS.Color.hairline
                hairline.translatesAutoresizingMaskIntoConstraints = false
                hairlineRow.addSubview(hairline)
                NSLayoutConstraint.activate([
                    hairlineRow.heightAnchor.constraint(equalToConstant: 1),
                    hairline.leadingAnchor.constraint(equalTo: hairlineRow.leadingAnchor, constant: inset),
                    hairline.trailingAnchor.constraint(equalTo: hairlineRow.trailingAnchor),
                    hairline.topAnchor.constraint(equalTo: hairlineRow.topAnchor),
                    hairline.bottomAnchor.constraint(equalTo: hairlineRow.bottomAnchor),
                ])
                rowsStack.addArrangedSubview(hairlineRow)
                hairlineRow.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
            }
        }

        card.addSubview(rowsStack)
        let padding: CGFloat = onRaised ? 6 : 0
        NSLayoutConstraint.activate([
            rowsStack.topAnchor.constraint(equalTo: card.topAnchor, constant: padding),
            rowsStack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            rowsStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -padding)
        ])
        return card
    }

    /// Reorders a status section's tracks so a stacked track's row immediately follows its
    /// parent's row (when both landed in the same section), rather than sitting wherever
    /// `lastActiveAt` happened to place it — the hierarchy should read top-to-bottom, not be
    /// inferred from a breadcrumb alone. A track whose parent isn't in this same section (or
    /// whose parent id doesn't resolve to a live track) renders as its own root, unindented;
    /// the breadcrumb in its meta text is what still communicates its real parent in that case.
    private func nestedOrder(_ tracks: [Track]) -> [(track: Track, indent: Bool)] {
        let idsInSection = Set(tracks.map(\.id))
        var childrenOf: [UUID: [Track]] = [:]
        var roots: [Track] = []
        for track in tracks {
            if let parentId = track.parentTrackId, idsInSection.contains(parentId) {
                childrenOf[parentId, default: []].append(track)
            } else {
                roots.append(track)
            }
        }
        var result: [(Track, Bool)] = []
        func append(_ track: Track, indent: Bool) {
            result.append((track, indent))
            for child in childrenOf[track.id] ?? [] {
                append(child, indent: true)
            }
        }
        for root in roots { append(root, indent: false) }
        return result
    }

    private func makeRow(for track: Track, indent: Bool = false, connectorContinues: Bool = false) -> TrackRowView {
        var metaText = track.status == .active
            ? "active now"
            : Self.relativeDateFormatter.localizedString(for: track.lastActiveAt, relativeTo: Date())
        if let summary = gitSummaryCache[track.id] {
            // Beside the pane, the size is the pane's to say; the row stays one short line.
            let gitBits = gitSummaryText(summary, includeSize: !showsDetail)
            if !gitBits.isEmpty { metaText += " · \(gitBits)" }
        }
        // A coordinator's row carries its subtracks' state (multi-agent RFC, step 3): a subtrack
        // that needs you lights its coordinator too, so the umbrella never reads as quiet while
        // one of its children waits.
        let children = (trackStore?.tracks ?? []).filter { $0.parentTrackId == track.id && $0.spawnedByCoordinator && ![.completed, .archived].contains($0.status) }
        var rowActivity = activity(for: track)
        if !children.isEmpty {
            let activities = children.map(activity(for:))
            let needing = activities.filter(\.wantsAttention).count
            let working = activities.filter { $0 == .working }.count
            var rollup = "\(children.count) subtrack\(children.count == 1 ? "" : "s")"
            if needing > 0 { rollup += ", \(needing) need\(needing == 1 ? "s" : "") you" } else if working > 0 { rollup += ", \(working) working" }
            metaText += " · \(rollup)"
            if !rowActivity.wantsAttention {
                if needing > 0 { rowActivity = .needsYou } else if rowActivity == .none, working > 0 { rowActivity = .working }
            }
        }
        let row = TrackRowView(
            intentText: track.intent,
            branchText: track.branchName,
            metaText: metaText,
            activity: rowActivity,
            status: track.displayStatus,
            indent: indent,
            connectorContinues: connectorContinues
        )
        row.menu = buildContextMenu(for: track)
        row.onDoubleClick = { [weak self] in self?.requestSwitch(to: track) }
        // Beside the detail pane, a click selects and the row stays compact: its verbs are the
        // pane's. Without the pane, the row is the whole story, as before.
        row.compact = showsDetail
        row.onClick = { [weak self] in
            guard let self, self.showsDetail else { return }
            self.select(track)
            self.view.window?.makeFirstResponder(self.documentContainer)
        }
        row.isSelected = showsDetail && selectedTrackID == track.id
        shownTrackOrder.append(track.id)
        rowViews[track.id] = row
        row.onVerb = { [weak self] verb in
            guard let self else { return }
            switch verb {
            case .respond, .retry: self.onOpenStageRequested?(track, .think)
            case .review: self.onOpenStageRequested?(track, .review)
            case .open, .resume: self.requestSwitch(to: track)
            }
        }
        row.onWatch = { [weak self] in self?.onOpenStageRequested?(track, .think) }
        row.onMenuButtonTapped = { [weak self] button in
            guard let self else { return }
            self.buildContextMenu(for: track).popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        }
        return row
    }

    /// Turns raw ahead/behind/dirty counts into the short fragment appended to a row's meta
    /// line — omits anything that's zero/nil so a clean, caught-up track just shows its
    /// relative-time text with nothing extra, same as before this existed.
    private func gitSummaryText(_ summary: TrackStore.GitSummary, includeSize: Bool = true) -> String {
        var parts: [String] = []
        if summary.aheadCount > 0 { parts.append("\(summary.aheadCount) ahead") }
        if summary.behindCount > 0 { parts.append("\(summary.behindCount) behind") }
        if let uncommitted = summary.uncommittedCount, uncommitted > 0 {
            parts.append("\(uncommitted) uncommitted")
        }
        if includeSize, let bytes = summary.diskUsageBytes {
            parts.append(Self.byteCountFormatter.string(fromByteCount: Int64(bytes)))
        }
        return parts.joined(separator: ", ")
    }

    /// Same container language as the status cards — a plain informational row, not an alert. No
    /// color fill; it just looks like one more inset group, because functionally that's what it is.
    /// Shared by all three "something needs your attention before the ledger makes sense" banners
    /// (untracked branch, detached HEAD, no git repo yet) so they read as one consistent affordance.
    private func makeInfoBannerCard(symbolName: String, text: String, buttonTitle: String?, action: Selector?) -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = DS.Radius.surface
        card.bindLayerBackground(DS.Color.raised)
        // A real SF Symbol instead of a hand-drawn circle-plus-letter: renders properly centered
        // for free, and reads as native rather than a homemade approximation of one.
        let glyph = NSImageView(image: NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) ?? NSImage())
        glyph.contentTintColor = .tertiaryLabelColor
        glyph.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            glyph.widthAnchor.constraint(equalToConstant: 16),
            glyph.heightAnchor.constraint(equalToConstant: 16)
        ])

        let label = NSTextField(labelWithString: text)
        label.font = DS.Text.body()
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // Some banners are purely informational — there is no action to offer.
        var views: [NSView] = [glyph, label]
        if let buttonTitle, let action {
            let button = NSButton(title: buttonTitle, target: self, action: action)
            button.bezelStyle = .rounded
            button.controlSize = .small
            views.append(button)
        }

        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = DS.Spacing.l
        stack.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 11),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -11),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14)
        ])
        return card
    }

    private func makeBannerCard(branchName: String) -> NSView {
        makeInfoBannerCard(
            symbolName: "info.circle",
            text: "You're on \u{201C}\(branchName)\u{201D}, which isn't a track yet.",
            buttonTitle: "Turn into a Track…",
            action: #selector(promoteBranchTapped)
        )
    }

    private func makeNotAGitRepoBanner() -> NSView {
        makeInfoBannerCard(
            symbolName: "exclamationmark.circle",
            text: "This project isn't a git repository yet. Tracks needs one to manage branches.",
            buttonTitle: "Initialize Git…",
            action: #selector(initializeGitTapped)
        )
    }

    private func makeDetachedHeadBanner() -> NSView {
        makeInfoBannerCard(
            symbolName: "info.circle",
            text: "You're not on any branch right now (a detached checkout).",
            buttonTitle: "Turn into a Track…",
            action: #selector(detachedHeadPromoteTapped)
        )
    }

    /// Not private: referenced cross-file via `#selector` for the "Track > New Track…" menu item
    /// (MakeWorkspaceViewController.buildMenu()), which reaches this through the responder chain
    /// while the Tracks stage is active — same pattern already used for Run's menu items.
    /// An alert's accessory width. The macOS 26 alert is narrower than older ones, and NSAlert
    /// doesn't widen itself for a wider accessory — at 280 the field and the fork picker ran
    /// past the sheet's right edge. Matches Make's rename/new-file fields.
    static let alertFieldWidth: CGFloat = 240

    @objc func newTrackTapped() { newTrack(prefill: nil) }

    /// `prefill`: the intent typed in the switcher, ready to confirm.
    func newTrack(prefill: String?) {
        guard let window = view.window, let store = trackStore else { return }
        let alert = NSAlert()
        alert.messageText = "New Track"
        alert.informativeText = "What are you working on?"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: Self.alertFieldWidth, height: 24))
        field.placeholderString = "Fix the save-conflict race"
        if let prefill { field.stringValue = prefill }

        // A base-track picker only makes sense once there's another track worth forking from —
        // completed/archived tracks are presumed already merged up, so they're not offered as a
        // base. With nothing eligible, keep the dialog exactly as simple as it's always been
        // rather than showing a picker with only the default-branch option in it.
        let stackableBases = store.tracks.filter { [.active, .waiting, .reviewReady].contains($0.status) }
        let basePopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: Self.alertFieldWidth, height: 24))
        if !stackableBases.isEmpty {
            basePopup.addItem(withTitle: "Fork from \(store.defaultBranchName())")
            for track in stackableBases {
                basePopup.addItem(withTitle: "Fork from \u{201C}\(track.intent)\u{201D} (\(track.branchName))")
                basePopup.lastItem?.representedObject = track
            }
            let stack = NSStackView(views: [field, basePopup])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = DS.Spacing.m
            // NSAlert sizes the sheet from accessoryView.frame before Auto Layout resolves
            // anything — see CommandProposalView/AddProviderForm for the same lesson learned
            // the hard way earlier.
            stack.frame = NSRect(x: 0, y: 0, width: Self.alertFieldWidth, height: 60)
            for view in [field, basePopup] { view.widthAnchor.constraint(equalToConstant: Self.alertFieldWidth).isActive = true }
            alert.accessoryView = stack
        } else {
            alert.accessoryView = field
        }

        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let intent = field.stringValue
            let baseTrack = basePopup.selectedItem?.representedObject as? Track
            // Creating a track moves HEAD immediately (it's checked out as part of creation, not
            // as a separate step), so unsaved Make edits need resolving first — same guard a
            // switch to an existing track goes through.
            self.onCreateTrackRequested? { [weak self] proceed in
                guard let self, proceed else { return }
                self.trackStore?.createTrack(intent: intent, baseTrack: baseTrack) { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .success(let (track, outcome)):
                        self.onTrackCreated?(track)
                        self.announce(outcome: outcome)
                    case .failure(TrackStore.TrackError.repositoryHasNoCommits):
                        self.offerInitialCommit(window: window) { [weak self] in
                            self?.trackStore?.createTrack(intent: intent, baseTrack: baseTrack) { [weak self] result in
                                switch result {
                                case .success(let (track, outcome)):
                                    self?.onTrackCreated?(track)
                                    self?.announce(outcome: outcome)
                                case .failure(let error):
                                    self?.showError(error, title: "Couldn't create track", window: window)
                                }
                            }
                        }
                    case .failure(let error):
                        self.showError(error, title: "Couldn't create track", window: window)
                    }
                }
            }
        }
    }

    /// Checks out a branch that already exists (locally or on the remote) but isn't a track yet —
    /// e.g. a teammate's branch, or one made before Tracks existed. Lands as an untracked branch,
    /// same as if you'd checked it out from a terminal; the existing banner offers to fold it into
    /// a track from there.
    @objc private func switchExistingBranchTapped() {
        guard let window = view.window else { return }
        trackStore?.availableBranchesToAdopt { [weak self] branches in
            guard let self, let window = self.view.window else { return }
            guard !branches.isEmpty else {
                let alert = NSAlert()
                alert.messageText = "No Branches to Switch To"
                alert.informativeText = "Every branch in this repository is already a track."
                alert.addButton(withTitle: "OK")
                alert.beginSheetModal(for: window)
                return
            }
            let alert = NSAlert()
            alert.messageText = "Switch to Existing Branch"
            alert.informativeText = "Choose a branch that isn't a track yet."
            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: Self.alertFieldWidth, height: 24))
            popup.addItems(withTitles: branches)
            alert.accessoryView = popup
            alert.addButton(withTitle: "Switch")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self, response == .alertFirstButtonReturn, let branch = popup.titleOfSelectedItem else { return }
                self.performSwitchToExistingBranch(branch)
            }
        }
    }

    private func performSwitchToExistingBranch(_ branchName: String) {
        // Moves HEAD just like creating a track does, so it goes through the same unsaved-changes
        // guard first.
        onCreateTrackRequested? { [weak self] proceed in
            guard let self, proceed else { return }
            self.trackStore?.switchToExistingBranch(branchName) { [weak self] result in
                guard let self, let window = self.view.window else { return }
                switch result {
                case .success(let outcome):
                    self.onBranchSwitched?(branchName)
                    self.announce(outcome: outcome)
                case .failure(let error):
                    self.showError(error, title: "Couldn't switch branches", window: window)
                }
            }
        }
    }

    @objc private func showArchivedToggled() {
        showArchived = showArchivedButton.state == .on
        refreshUI()
    }

    /// Visible only while archived tracks are hidden — once the checkbox reveals them, the count
    /// is redundant with what's already on screen.
    private func updateArchivedCountLabel() {
        let count = (trackStore?.tracks ?? []).filter { $0.status == .archived }.count
        archivedCountLabel.stringValue = (!showArchived && count > 0) ? "\(count) archived" : ""
    }

    @objc private func promoteBranchTapped() {
        guard let window = view.window, trackStore?.untrackedBranch != nil else { return }
        let alert = NSAlert()
        alert.messageText = "Turn Into a Track"
        alert.informativeText = "What are you working on?"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: Self.alertFieldWidth, height: 24))
        field.placeholderString = "Fix the save-conflict race"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let intent = field.stringValue
            self.trackStore?.promoteCurrentBranch(intent: intent) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    self.refreshUI()
                case .failure(let error):
                    self.showError(error, title: "Couldn't create track", window: window)
                }
            }
        }
    }

    /// A repository with no commits: say so plainly, and make the empty initial commit if asked.
    private func offerInitialCommit(window: NSWindow, then retry: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = "This repository has no commits yet"
        alert.informativeText = "A track branches from a commit, and there isn't one. Side can make an empty initial commit (none of your files are included), then create the track."
        alert.addButton(withTitle: "Make Initial Commit")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.trackStore?.makeInitialCommit { [weak self] result in
                switch result {
                case .success: retry()
                case .failure(let error): self?.showError(error, title: "Couldn't make the initial commit", window: window)
                }
            }
        }
    }

    @objc private func initializeGitTapped() {
        guard let window = view.window else { return }
        trackStore?.initializeGitRepo { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.refreshUI()
            case .failure(let error):
                self.showError(error, title: "Couldn't initialize git", window: window)
            }
        }
    }

    @objc private func detachedHeadPromoteTapped() {
        guard let window = view.window, trackStore?.isDetachedHead == true else { return }
        let alert = NSAlert()
        alert.messageText = "Turn Into a Track"
        alert.informativeText = "What are you working on?"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: Self.alertFieldWidth, height: 24))
        field.placeholderString = "Fix the save-conflict race"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let intent = field.stringValue
            // A new branch is created at the current detached commit, so this moves HEAD's
            // *name* but not its position — still goes through the same unsaved-changes guard
            // as any other operation that touches the working tree.
            self.onCreateTrackRequested? { [weak self] proceed in
                guard let self, proceed else { return }
                self.trackStore?.createTrackFromDetachedHead(intent: intent) { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .success(let (track, outcome)):
                        self.onTrackCreated?(track)
                        self.announce(outcome: outcome)
                    case .failure(let error):
                        self.showError(error, title: "Couldn't create track", window: window)
                    }
                }
            }
        }
    }

    private func requestSwitch(to track: Track) {
        guard track.status != .active else { return }
        onSwitchRequested?(track) { [weak self] outcome in
            guard let self, let outcome else { return }
            self.announce(outcome: outcome)
        }
    }

    /// Tracks switch entirely through plain `git checkout` in the one shared working directory,
    /// so uncommitted changes have to go somewhere — this is the only place that tells the user
    /// where. Without it, a stash-and-pop that works perfectly is indistinguishable from one that
    /// silently ate their changes.
    private func announce(outcome: TrackSwitchOutcome) {
        var parts: [String] = []
        if let stashed = outcome.stashedFileCount {
            parts.append("Stashed \(stashed) uncommitted change\(stashed == 1 ? "" : "s") from the track you left")
        }
        if outcome.restoreConflicted {
            parts.append("couldn't cleanly restore this track's stashed changes. Resolve the conflict; the stash is still there if you need it")
        } else if let restored = outcome.restoredFileCount {
            parts.append("restored \(restored) stashed change\(restored == 1 ? "" : "s") for this track")
        }
        guard !parts.isEmpty else { return }
        let message = parts.joined(separator: "; ")
        showStatus(message.prefix(1).uppercased() + message.dropFirst())
    }

    private func showStatus(_ message: String) {
        statusLabelHideWorkItem?.cancel()
        statusLabel.stringValue = message
        statusLabel.animator().alphaValue = 1
        let hideWorkItem = DispatchWorkItem { [weak self] in
            self?.statusLabel.animator().alphaValue = 0
        }
        statusLabelHideWorkItem = hideWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: hideWorkItem)
    }

    private func showError(_ error: Error, title: String, window: NSWindow) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    // MARK: - Context menu (Rename / Switch / Park / Archive / Mark Completed / Delete)

    /// Built fresh per row at render time (rows themselves are rebuilt from scratch on every
    /// change, see `refreshUI`), so there's no need for the dynamic `menuNeedsUpdate` dance a
    /// persistent `NSTableView` would require — the track a menu belongs to never goes stale.
    private func buildContextMenu(for track: Track) -> NSMenu {
        let menu = NSMenu()
        addItem(to: menu, title: "Rename…", action: #selector(renameTrackMenuItem(_:)), track: track)
        // The old single "Auto-run Commands" checkbox is now the autonomy axis of the track's
        // mode — same setting, said properly. Tool scope is chosen in Think, next to the
        // conversation it shapes; this menu carries the part that's about *trust*, which is a
        // property of the track a reader of the ledger wants to see.
        let modeItem = menu.addItem(withTitle: "Autonomy", action: nil, keyEquivalent: "")
        let modeMenu = NSMenu()
        for autonomy in AgentAutonomy.allCases {
            let item = modeMenu.addItem(withTitle: autonomy.displayName, action: #selector(setAutonomyMenuItem(_:)), keyEquivalent: "")
            item.representedObject = [track, autonomy.rawValue] as [Any]
            item.state = track.mode.autonomy == autonomy ? .on : .off
        }
        modeItem.submenu = modeMenu
        // Which engine runs the conversation: Heron, or an outside agent on the user's own
        // account (SIDE_RFC_BYO_HARNESS.md).
        let agentItem = menu.addItem(withTitle: "Agent", action: nil, keyEquivalent: "")
        let agentMenu = NSMenu()
        let heron = agentMenu.addItem(withTitle: "Heron", action: #selector(setHarnessMenuItem(_:)), keyEquivalent: "")
        heron.representedObject = [track, ""] as [Any]
        heron.state = track.harnessId == nil ? .on : .off
        agentMenu.addItem(NSMenuItem.separator())
        for agent in ACPAgent.known {
            let item = agentMenu.addItem(withTitle: agent.displayName, action: #selector(setHarnessMenuItem(_:)), keyEquivalent: "")
            item.representedObject = [track, agent.id] as [Any]
            item.state = track.harnessId == agent.id ? .on : .off
        }
        agentItem.submenu = agentMenu
        // Available regardless of status — the whole point is watching/working on two tracks
        // side by side, and that's just as useful for a parked or completed track as an active
        // one (reviewing old work while something else runs, say).
        addItem(to: menu, title: "Open in New Window", action: #selector(openInNewWindowMenuItem(_:)), track: track)
        if let parentId = track.parentTrackId, let parent = trackStore?.tracks.first(where: { $0.id == parentId }) {
            addItem(to: menu, title: "Pull from \u{201C}\(parent.intent)\u{201D}", action: #selector(pullFromParentMenuItem(_:)), track: track)
        }
        menu.addItem(NSMenuItem.separator())

        switch track.status {
        case .active:
            addItem(to: menu, title: "Mark Review Ready", action: #selector(markReviewReadyTrack(_:)), track: track)
            addItem(to: menu, title: "Park", action: #selector(parkTrack(_:)), track: track)
            addItem(to: menu, title: "Mark Completed", action: #selector(completeTrack(_:)), track: track)
            addItem(to: menu, title: "Archive", action: #selector(archiveTrack(_:)), track: track)
        case .waiting:
            addItem(to: menu, title: "Switch to Track", action: #selector(switchTrackMenuItem(_:)), track: track)
            addItem(to: menu, title: "Mark Review Ready", action: #selector(markReviewReadyTrack(_:)), track: track)
            addItem(to: menu, title: "Park", action: #selector(parkTrack(_:)), track: track)
            addItem(to: menu, title: "Mark Completed", action: #selector(completeTrack(_:)), track: track)
            addItem(to: menu, title: "Archive", action: #selector(archiveTrack(_:)), track: track)
        case .reviewReady:
            addItem(to: menu, title: "Switch to Track", action: #selector(switchTrackMenuItem(_:)), track: track)
            addItem(to: menu, title: "Park", action: #selector(parkTrack(_:)), track: track)
            addItem(to: menu, title: "Mark Completed", action: #selector(completeTrack(_:)), track: track)
            addItem(to: menu, title: "Archive", action: #selector(archiveTrack(_:)), track: track)
        case .parked:
            addItem(to: menu, title: "Resume", action: #selector(switchTrackMenuItem(_:)), track: track)
            addItem(to: menu, title: "Mark Completed", action: #selector(completeTrack(_:)), track: track)
            addItem(to: menu, title: "Archive", action: #selector(archiveTrack(_:)), track: track)
        case .completed:
            addItem(to: menu, title: "Resume", action: #selector(switchTrackMenuItem(_:)), track: track)
            addItem(to: menu, title: "Archive", action: #selector(archiveTrack(_:)), track: track)
        case .archived:
            addItem(to: menu, title: "Resume", action: #selector(switchTrackMenuItem(_:)), track: track)
        }

        // Deleting the active track would mean deleting the branch you're currently standing on
        // — not offered here; TrackStore itself also refuses it as a last line of defense.
        if track.status != .active {
            menu.addItem(NSMenuItem.separator())
            // Only offered once there's actually a worktree to reclaim — a track that's never
            // been materialized, or one that's already had its working copy removed, has
            // nothing here to free.
            if track.workingDirectoryPath != nil {
                addItem(to: menu, title: "Remove Working Copy…", action: #selector(removeWorkingCopyMenuItem(_:)), track: track)
            }
            addItem(to: menu, title: "Delete…", action: #selector(deleteTrackMenuItem(_:)), track: track)
        }
        menu.items.forEach { $0.target = self }
        return menu
    }

    private func addItem(to menu: NSMenu, title: String, action: Selector, track: Track) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.representedObject = track
    }

    @objc private func switchTrackMenuItem(_ sender: NSMenuItem) {
        guard let track = sender.representedObject as? Track else { return }
        requestSwitch(to: track)
    }

    /// Sets the autonomy axis of this track's mode — how much the agent may do without asking.
    /// Manual keeps every edit and command waiting; Guarded auto-runs allowlisted commands;
    /// Full also auto-applies edits. The command allowlist is a floor at every level.
    @objc private func setHarnessMenuItem(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [Any], pair.count == 2,
              let track = pair[0] as? Track, let id = pair[1] as? String else { return }
        trackStore?.setHarness(id.isEmpty ? nil : id, forTrackKey: track.branchName)
    }

    @objc private func setAutonomyMenuItem(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [Any], pair.count == 2,
              let track = pair[0] as? Track, let raw = pair[1] as? String,
              let autonomy = AgentAutonomy(rawValue: raw) else { return }
        // Keeps the track's existing scope — this menu only sets trust.
        trackStore?.setMode(AgentMode(scope: track.mode.scope, autonomy: autonomy), forTrackKey: track.branchName)
    }

    /// Opens a brand-new window on this same project, landed directly on this track — never
    /// disturbs whatever track this window (or any other) is currently showing.
    @objc private func openInNewWindowMenuItem(_ sender: NSMenuItem) {
        guard let track = sender.representedObject as? Track, let projectRoot = trackStore?.projectRoot else { return }
        AppDelegate.shared?.openTrackInNewWindow(projectRoot: projectRoot, trackKey: track.branchName)
    }

    @objc private func markReviewReadyTrack(_ sender: NSMenuItem) {
        guard let track = sender.representedObject as? Track else { return }
        trackStore?.setStatus(.reviewReady, for: track)
    }

    @objc private func parkTrack(_ sender: NSMenuItem) {
        guard let track = sender.representedObject as? Track else { return }
        trackStore?.setStatus(.parked, for: track)
    }

    @objc private func completeTrack(_ sender: NSMenuItem) {
        guard let track = sender.representedObject as? Track else { return }
        trackStore?.setStatus(.completed, for: track)
    }

    @objc private func archiveTrack(_ sender: NSMenuItem) {
        guard let track = sender.representedObject as? Track else { return }
        trackStore?.setStatus(.archived, for: track)
    }

    @objc private func renameTrackMenuItem(_ sender: NSMenuItem) {
        guard let track = sender.representedObject as? Track, let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Track"
        alert.informativeText = "What are you working on?"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: Self.alertFieldWidth, height: 24))
        field.stringValue = track.intent
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.trackStore?.renameTrack(track, to: field.stringValue) { [weak self] result in
                guard let self, case .failure(let error) = result else { return }
                self.showError(error, title: "Couldn't rename track", window: window)
            }
        }
    }

    /// Reversible, unlike Delete — the branch and its history stay exactly as they are; only
    /// the worktree directory on disk goes away, and the row's own "Resume"/"Watch" action
    /// re-materializes it on demand later, same as a legacy pre-worktree track.
    @objc private func removeWorkingCopyMenuItem(_ sender: NSMenuItem) {
        guard let track = sender.representedObject as? Track, let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Remove Working Copy for \u{201C}\(track.intent)\u{201D}?"
        alert.informativeText = "Frees the disk space this track's checkout uses. The \u{201C}\(track.branchName)\u{201D} branch and its history are untouched. Switching back to this track re-creates the working copy."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.trackStore?.removeWorkingCopy(for: track) { [weak self] result in
                guard let self else { return }
                if case .failure(let error) = result {
                    self.showError(error, title: "Couldn't remove working copy", window: window)
                }
            }
        }
    }

    /// Blocked while the track's own agent has something in flight — a pull rewrites the working
    /// copy underneath it (a merge commit, possibly conflicted files) exactly the kind of
    /// out-from-under-you change the approval pause exists to prevent. `.blocked`/`.finishedTurn`
    /// aren't busy in that sense — nothing is actively touching the worktree in those phases — so
    /// this is deliberately narrower than "does this track have a runner at all."
    @objc private func pullFromParentMenuItem(_ sender: NSMenuItem) {
        guard let track = sender.representedObject as? Track, let window = view.window else { return }
        if runnerManager?.existingRunner(forTrackKey: track.branchName)?.phase.isBusy == true {
            showStatus("⚠︎ This track's agent is still running. Wait for it to finish before pulling.")
            return
        }
        trackStore?.pullFromParent(track) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                self.showStatus(message)
            case .failure(let error):
                self.showError(error, title: "Couldn't pull", window: window)
            }
        }
    }

    @objc private func deleteTrackMenuItem(_ sender: NSMenuItem) {
        guard let track = sender.representedObject as? Track, let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete \u{201C}\(track.intent)\u{201D}?"
        alert.informativeText = "This removes the track from the list. It can't be undone."
        let deleteBranchCheckbox = NSButton(checkboxWithTitle: "Also delete the \u{201C}\(track.branchName)\u{201D} branch", target: nil, action: nil)
        deleteBranchCheckbox.state = .off
        alert.accessoryView = deleteBranchCheckbox
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let alsoDeleteBranch = deleteBranchCheckbox.state == .on
            self.performDelete(track, alsoDeleteBranch: alsoDeleteBranch, discardUncommittedChanges: false, window: window)
        }
    }

    private func performDelete(_ track: Track, alsoDeleteBranch: Bool, discardUncommittedChanges: Bool, window: NSWindow) {
            self.trackStore?.deleteTrack(track, alsoDeleteBranch: alsoDeleteBranch, discardUncommittedChanges: discardUncommittedChanges) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    self.onTrackDeleted?(track)
                case .failure(let error as TrackStore.TrackError):
                    if case .worktreeHasUncommittedChanges(let count) = error {
                        // Refused before touching anything. The first dialog said "removes the
                        // track from the list", which is what the user consented to — losing
                        // uncommitted work is a different decision and gets its own question,
                        // with the number in it.
                        let confirm = NSAlert()
                        confirm.alertStyle = .critical
                        confirm.messageText = "Discard \(count) uncommitted change\(count == 1 ? "" : "s")?"
                        confirm.informativeText = "This track's working copy has work that was never checkpointed. Deleting the track will destroy it. This can't be undone."
                        confirm.addButton(withTitle: "Discard and Delete")
                        confirm.addButton(withTitle: "Cancel")
                        confirm.beginSheetModal(for: window) { [weak self] response in
                            guard let self, response == .alertFirstButtonReturn else { return }
                            self.performDelete(track, alsoDeleteBranch: alsoDeleteBranch, discardUncommittedChanges: true, window: window)
                        }
                        return
                    }
                    if error == .cannotDeleteTrackWithLiveChildren || error == .cannotDeleteActive {
                        // Refused before touching anything — the track record is still fully
                        // intact, so cleaning up its sessions/runner here would discard live state
                        // for a track that never actually went away.
                        self.showError(error, title: "Couldn't delete track", window: window)
                        return
                    }
                    // Only `.gitBranchDeleteFailed` reaches here, which fires after `tracks.removeAll`.
                    self.onTrackDeleted?(track)
                    self.showError(error, title: "Track deleted", window: window)
                case .failure(let error):
                    self.onTrackDeleted?(track)
                    self.showError(error, title: "Track deleted", window: window)
                }
            }
    }
}

/// The git-graph-style branch line for a stacked child row: drops from the top edge (where the
/// parent row, or the previous sibling's continuation, sits) and curves rightward into this
/// row's content at its vertical center. When more siblings follow, the vertical line also
/// continues through to the bottom edge, so consecutive children chain into one trunk with a
/// curve peeling off at each row.
private final class TrackConnectorView: NSView {
    private let continues: Bool
    private static let trunkX: CGFloat = 20
    private static let curveRadius: CGFloat = 9

    init(continues: Bool) {
        self.continues = continues
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath()
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        let x = Self.trunkX
        let midY = bounds.midY
        // Drop from the top, then peel off into the row.
        path.move(to: NSPoint(x: x, y: 0))
        path.line(to: NSPoint(x: x, y: midY - Self.curveRadius))
        path.curve(to: NSPoint(x: x + Self.curveRadius, y: midY),
                   controlPoint1: NSPoint(x: x, y: midY),
                   controlPoint2: NSPoint(x: x, y: midY))
        path.line(to: NSPoint(x: x + Self.curveRadius + 4, y: midY))
        if continues {
            path.move(to: NSPoint(x: x, y: midY - Self.curveRadius))
            path.line(to: NSPoint(x: x, y: bounds.maxY))
        }
        DS.Color.hairlineStrong.setStroke()
        path.stroke()
    }
}

/// A row's trailing action is the specific verb for what the track needs, never a stage name
/// that goes somewhere else (Direction 02 §4.1, audit A-3).
enum TrackRowVerb: Equatable {
    case respond   // an approval or question is waiting → Think
    case retry     // the run failed → Think
    case review    // review-ready, or a finished run nobody has looked at → Review
    case open      // live work → switch to it
    case resume    // parked, completed, archived → switch back to it

    var title: String {
        switch self {
        case .respond: return "Respond"
        case .retry: return "Retry"
        case .review: return "Review"
        case .open: return "Open"
        case .resume: return "Resume"
        }
    }

    /// Attention verbs stay on screen; the rest appear on hover with the secondary actions.
    var alwaysVisible: Bool { self == .respond || self == .retry || self == .review }

    static func primary(status: TrackStatus, activity: AgentActivity) -> TrackRowVerb {
        switch activity {
        case .needsYou: return .respond
        case .failed: return .retry
        case .doneUnread: return .review
        case .none, .working, .doneSeen: break
        }
        switch status {
        case .reviewReady: return .review
        case .parked, .completed, .archived: return .resume
        case .active, .waiting: return .open
        }
    }
}

/// One row inside a status card: intent (primary), branch chip + relative time + agent activity
/// (secondary), and a primary-action/kebab pair. The kebab always only appears on hover; the
/// primary button does too *unless* it's `.review`/`.markReviewReady`, per `alwaysVisible` above.
private final class TrackRowView: NSView {
    var onVerb: ((TrackRowVerb) -> Void)?
    var onClick: (() -> Void)?
    /// The selected row, beside the detail pane.
    var isSelected = false { didSet { applyBackground() } }
    /// Beside the detail pane: no verbs of its own (the pane has them), only More on hover.
    var compact = false {
        didSet {
            primaryButton.isHidden = compact
            watchButton.isHidden = compact || verb == .respond || verb == .retry
        }
    }
    private var isHovered = false
    /// "Watch": straight to the track's conversation, whatever its state.
    var onWatch: (() -> Void)?
    var onMenuButtonTapped: ((NSButton) -> Void)?
    var onDoubleClick: (() -> Void)?

    private let actionsStack = NSStackView()
    private let primaryButton = NSButton(title: "", target: nil, action: nil)
    private let watchButton = NSButton(title: "Watch", target: nil, action: nil)
    private let menuButton = NSButton(title: "\u{22EF}", target: nil, action: nil)
    private let hoverActions = NSStackView()
    private var trackingArea: NSTrackingArea?
    private let verb: TrackRowVerb

    private var accessibilitySummary = ""

    static let indentWidth: CGFloat = 26

    init(intentText: String, branchText: String, metaText: String, activity: AgentActivity, status: TrackStatus, indent: Bool = false, connectorContinues: Bool = false) {
        verb = TrackRowVerb.primary(status: status, activity: activity)

        super.init(frame: .zero)
        accessibilitySummary = "\(intentText), \(trackStatusText(for: status)), \(branchText)"
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        let intentLabel = NSTextField(labelWithString: intentText)
        // The subject is the only semibold (§4 shared rules). Parked work recedes a step;
        // archived work recedes further — it's only on screen because it was asked for.
        switch status {
        case .parked, .completed:
            intentLabel.font = DS.Text.body(.medium)
            intentLabel.textColor = .secondaryLabelColor
        case .archived:
            intentLabel.font = DS.Text.body(.medium)
            intentLabel.textColor = .quaternaryLabelColor
        case .active, .waiting, .reviewReady:
            intentLabel.font = DS.Text.body(.semibold)
            intentLabel.textColor = .labelColor
        }
        intentLabel.lineBreakMode = .byTruncatingTail

        let branchLabel = NSTextField(labelWithString: branchText)
        branchLabel.font = DS.Text.code(11, weight: .regular)
        branchLabel.textColor = .secondaryLabelColor

        let chip = NSView()
        chip.wantsLayer = true
        chip.bindLayerBackground(DS.Color.overlay)
        chip.layer?.cornerRadius = DS.Radius.control
        chip.translatesAutoresizingMaskIntoConstraints = false
        branchLabel.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(branchLabel)
        NSLayoutConstraint.activate([
            branchLabel.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 5),
            branchLabel.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -5),
            branchLabel.topAnchor.constraint(equalTo: chip.topAnchor, constant: 1),
            branchLabel.bottomAnchor.constraint(equalTo: chip.bottomAnchor, constant: -1)
        ])

        // Now that cards are grouped by lineage rather than by status, a row's status is no
        // longer implied by which section it's filed under — it needs to say so itself. Dot and
        // text (Direction 02 §2.4): the agent's activity when there is any, else the lifecycle.
        let statusLabel = DS.StatusLabel(
            state: DS.StatusState(track: status, activity: activity),
            text: Self.agentChipInfo(for: activity)?.text ?? trackStatusText(for: status))

        let sepLabel = NSTextField(labelWithString: "\u{00B7}")
        sepLabel.font = DS.Text.caption()
        sepLabel.textColor = .tertiaryLabelColor

        let metaLabel = NSTextField(labelWithString: metaText)
        metaLabel.font = DS.Text.caption()
        metaLabel.textColor = .secondaryLabelColor

        let metaRow = NSStackView(views: [statusLabel, chip, sepLabel, metaLabel])
        metaRow.orientation = .horizontal
        metaRow.alignment = .centerY
        metaRow.spacing = DS.Spacing.s

        let mainStack = NSStackView(views: [intentLabel, metaRow])
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = DS.Spacing.xxs
        mainStack.translatesAutoresizingMaskIntoConstraints = false

        // Text actions, not bezels (§4 shared rules): the screen's one filled button is New Track.
        Self.styleTextAction(primaryButton, title: verb.title, emphasized: verb.alwaysVisible)
        primaryButton.target = self
        primaryButton.action = #selector(handlePrimaryActionTapped)
        Self.styleTextAction(watchButton, title: "Watch", emphasized: false)
        watchButton.target = self
        watchButton.action = #selector(handleWatchTapped)
        // Respond and Retry already go to the conversation; Watch would say the same thing twice.
        watchButton.isHidden = verb == .respond || verb == .retry

        menuButton.isBordered = false
        menuButton.font = DS.Text.heading()
        menuButton.contentTintColor = .secondaryLabelColor
        menuButton.target = self
        menuButton.action = #selector(handleMenuTapped)
        menuButton.setAccessibilityLabel("More actions")

        hoverActions.orientation = .horizontal
        hoverActions.alignment = .centerY
        hoverActions.spacing = DS.Spacing.l
        hoverActions.addArrangedSubview(menuButton)
        hoverActions.addArrangedSubview(watchButton)
        hoverActions.alphaValue = 0

        actionsStack.orientation = .horizontal
        actionsStack.alignment = .centerY
        actionsStack.spacing = DS.Spacing.l
        actionsStack.translatesAutoresizingMaskIntoConstraints = false
        actionsStack.addArrangedSubview(hoverActions)
        actionsStack.addArrangedSubview(primaryButton)
        primaryButton.alphaValue = verb.alwaysVisible ? 1 : 0

        addSubview(mainStack)
        addSubview(actionsStack)
        var constraints = [
            mainStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: indent ? 14 + Self.indentWidth : 14),
            mainStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            mainStack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 6),
            mainStack.trailingAnchor.constraint(lessThanOrEqualTo: actionsStack.leadingAnchor, constant: -12),
            actionsStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            actionsStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 52)
        ]
        // The connector is what actually reads as "this branches from the row above" — a line
        // dropping from the parent that curves into this row, git-graph style, continuing
        // downward past this row when more siblings follow.
        if indent {
            let connector = TrackConnectorView(continues: connectorContinues)
            connector.translatesAutoresizingMaskIntoConstraints = false
            addSubview(connector)
            constraints.append(contentsOf: [
                connector.widthAnchor.constraint(equalToConstant: 14 + Self.indentWidth),
                connector.leadingAnchor.constraint(equalTo: leadingAnchor),
                connector.topAnchor.constraint(equalTo: topAnchor),
                connector.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
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

    /// Set by the owner for rows sitting on a `raised` group, where hover takes `overlay`.
    var hoverTone = DS.Color.raised

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        applyBackground()
        hoverActions.animator().alphaValue = 1
        primaryButton.animator().alphaValue = 1
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        applyBackground()
        hoverActions.animator().alphaValue = 0
        primaryButton.animator().alphaValue = verb.alwaysVisible ? 1 : 0
    }

    private func applyBackground() {
        if isSelected { bindLayerBackground(DS.Color.selectedCapsule) } else if isHovered { bindLayerBackground(hoverTone) } else { layer?.backgroundColor = nil }
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        if event.clickCount == 2 { onDoubleClick?() } else if event.clickCount == 1 { onClick?() }
    }

    /// The status as the row's label says it: the agent's activity, else the lifecycle.
    static func statusText(activity: AgentActivity, status: TrackStatus) -> String {
        agentChipInfo(for: activity)?.text ?? trackStatusText(for: status)
    }

    /// Routes clicks that land on a purely-decorative descendant (the intent/branch/meta labels)
    /// back to this row, so double-click-to-switch works no matter where in the row you click —
    /// but leaves genuine control hits (the primary/kebab buttons) alone.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let result = super.hitTest(point) else { return nil }
        if result === self || result === primaryButton || result === menuButton || result === watchButton { return result }
        return self
    }

    // The whole row is hand-assembled — name it for accessibility (press = switch to track).
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { accessibilitySummary }
    override func accessibilityPerformPress() -> Bool {
        onDoubleClick?()
        return true
    }
    /// The hover-only verbs are reachable without a pointer (§4 shared rules, audit 30.7).
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        var actions = [NSAccessibilityCustomAction(name: verb.title) { [weak self] in
            guard let self else { return false }
            self.onVerb?(self.verb)
            return true
        }]
        if !watchButton.isHidden {
            actions.append(NSAccessibilityCustomAction(name: "Watch") { [weak self] in self?.onWatch?(); return true })
        }
        actions.append(NSAccessibilityCustomAction(name: "More actions") { [weak self] in
            guard let self else { return false }
            self.onMenuButtonTapped?(self.menuButton)
            return true
        })
        return actions
    }

    @objc private func handlePrimaryActionTapped() { onVerb?(verb) }
    @objc private func handleWatchTapped() { onWatch?() }
    @objc private func handleMenuTapped() { onMenuButtonTapped?(menuButton) }

    private static func styleTextAction(_ button: NSButton, title: String, emphasized: Bool) {
        button.isBordered = false
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: DS.Text.body(emphasized ? .semibold : .regular),
            .foregroundColor: emphasized ? NSColor.labelColor : NSColor.secondaryLabelColor,
        ])
    }

    /// Short label + semantic color for the always-on activity indicator in the meta row — `nil`
    /// for `.none`, since a track with no agent history shouldn't show an empty chip.
    private static func agentChipInfo(for activity: AgentActivity) -> (text: String, color: NSColor)? {
        switch activity {
        case .none: return nil
        case .working: return ("Working", DS.Color.statusWorking)
        case .needsYou: return ("Needs you", DS.Color.statusNeedsYou)
        case .failed: return ("Failed", DS.Color.statusFailed)
        case .doneUnread: return ("Done", DS.Color.statusVerified)
        case .doneSeen: return ("Done", DS.Color.statusIdle)
        }
    }
}

/// The lifecycle status as a word.
private func trackStatusText(for status: TrackStatus) -> String {
    switch status {
    case .active: return "Active"
    case .waiting: return "Waiting"
    case .reviewReady: return "Review Ready"
    case .parked: return "Parked"
    case .completed: return "Completed"
    case .archived: return "Archived"
    }
}

extension TracksWorkspaceViewController: StageChromeProviding {
    var topRowContent: NSView? {
        loadViewIfNeeded()
        if topHeader.arrangedSubviews.isEmpty {
            topTitle.font = DS.Text.heading()
            topCounts.font = DS.Text.caption()
            topCounts.textColor = .tertiaryLabelColor
            topHeader.orientation = .horizontal
            topHeader.alignment = .firstBaseline
            topHeader.spacing = DS.Spacing.m
            topHeader.addArrangedSubview(topTitle)
            topHeader.addArrangedSubview(topCounts)
            refreshTopHeader()
        }
        return topHeader
    }

    func setBottomObstruction(_ height: CGFloat) {
        loadViewIfNeeded()
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: height > 0 ? height : 0, right: 0)
        detailView.bottomInset = height
    }

    /// `N active · N parked · N archived` — informational only; no limit, no nudge.
    fileprivate func refreshTopHeader() {
        let tracks = trackStore?.tracks ?? []
        let active = tracks.filter { $0.status == .active || $0.status == .waiting || $0.status == .reviewReady }.count
        let parked = tracks.filter { $0.status == .parked }.count
        let archived = tracks.filter { $0.status == .archived || $0.status == .completed }.count
        topCounts.stringValue = "\(active) active · \(parked) parked · \(archived) archived"
    }
}
