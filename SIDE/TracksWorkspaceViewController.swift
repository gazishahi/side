import AppKit

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
}

/// Colors for the grouped-card ledger. Deliberately restrained: one neutral card surface, one
/// hairline, no per-status color coding — the section label already says the status in words, so
/// a colored dot repeating it would just be noise. The app's own accent shows up only on buttons.
private enum TracksPalette {
    static let cardBackground = NSColor(white: 0.145, alpha: 1)
    static let cardBorder = NSColor(white: 0.24, alpha: 1)
    static let hairline = NSColor(white: 0.24, alpha: 1)
    static let rowHover = NSColor(white: 0.195, alpha: 1)
    static let chip = NSColor(white: 0.21, alpha: 1)
}

final class TracksWorkspaceViewController: NSViewController {
    private let scrollView = NSScrollView()
    private let documentContainer = FocusableContainerView()
    private let contentStack = NSStackView()

    private let newTrackButton = NSButton(title: "New Track…", target: nil, action: nil)
    private let switchExistingBranchButton = NSButton(title: "Switch to Existing Branch…", target: nil, action: nil)
    private let showArchivedButton = NSButton(checkboxWithTitle: "Show Archived", target: nil, action: nil)
    private let archivedCountLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private var statusLabelHideWorkItem: DispatchWorkItem?
    private let headerStack = NSStackView()
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

    /// ShellViewController supplies this — it owns the cross-stage guard (unsaved Make edits)
    /// and decides what happens after a successful switch (land on Make). `nil` in the
    /// completion means the switch failed or was cancelled; otherwise it carries what happened
    /// to any uncommitted changes so it can be surfaced to the user.
    var onSwitchRequested: ((Track, @escaping (TrackSwitchOutcome?) -> Void) -> Void)?

    /// Jump straight to the review from the ledger row — the whole point of the row's
    /// state-dependent primary button surfacing "Review" instead of just "Switch" once a track
    /// needs a decision. For the active track this is just a stage switch; for any other track
    /// it's ShellViewController's job to switch to it first (same guard `onSwitchRequested`
    /// goes through) and land on Think instead of Make.
    var onReviewRequested: ((Track) -> Void)?

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

    func configure(with store: TrackStore, runnerManager: AgentRunnerManager) {
        self.runnerManager = runnerManager
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

    override func loadView() { view = NSView() }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildView()
    }

    private func buildView() {
        view.wantsLayer = true
        ChromeBackground.install(in: view)

        newTrackButton.target = self
        newTrackButton.action = #selector(newTrackTapped)
        newTrackButton.bezelStyle = .rounded

        switchExistingBranchButton.target = self
        switchExistingBranchButton.action = #selector(switchExistingBranchTapped)
        switchExistingBranchButton.bezelStyle = .rounded

        showArchivedButton.target = self
        showArchivedButton.action = #selector(showArchivedToggled)

        archivedCountLabel.font = .systemFont(ofSize: 11)
        archivedCountLabel.textColor = .tertiaryLabelColor

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.alphaValue = 0

        topControlsRow.orientation = .horizontal
        topControlsRow.alignment = .centerY
        topControlsRow.spacing = 12
        [newTrackButton, switchExistingBranchButton, showArchivedButton, archivedCountLabel, statusLabel].forEach(topControlsRow.addArrangedSubview)

        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 10
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerStack.addArrangedSubview(topControlsRow)
        view.addSubview(headerStack)

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 20
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

        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            headerStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            headerStack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
            scrollView.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 14),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            documentContainer.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentContainer.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor)
        ])
    }

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
        renderLedger()
        refreshGitSummariesIfNeeded()
    }

    private func refreshGitSummariesIfNeeded() {
        guard !isRefreshingGitSummaries, let store = trackStore, store.repoState != .notAGitRepo else { return }
        isRefreshingGitSummaries = true
        let tracks = store.tracks
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var results: [UUID: TrackStore.GitSummary] = [:]
            for track in tracks { results[track.id] = store.gitSummary(for: track) }
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

        // A plain folder with no `.git` yet (or one where it disappeared) can't do anything
        // Tracks-related — every git call would just fail. Show that plainly instead of letting
        // raw git stderr leak into the banner as if it were a branch name.
        let isRepo = trackStore?.repoState != .notAGitRepo
        newTrackButton.isEnabled = isRepo
        switchExistingBranchButton.isEnabled = isRepo
        showArchivedButton.isEnabled = isRepo
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
        let sections = groupedSections()
        if needsYou.isEmpty && sections.isEmpty {
            let empty = NSTextField(labelWithString: "No tracks yet — create one to get started.")
            empty.font = .systemFont(ofSize: 12.5)
            empty.textColor = .tertiaryLabelColor
            contentStack.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        } else {
            // Pinned above everything else, including Active — a blocked agent on a `.waiting`
            // track would otherwise sink into a group that reads as "nothing happening." Drawn
            // from activity, not `TrackStatus`, so the same track still appears again below in
            // its normal status group; this section exists purely to make sure it isn't missed.
            if !needsYou.isEmpty {
                let group = makeGroup(label: "Needs You", tracks: needsYou)
                contentStack.addArrangedSubview(group)
                group.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
            }
            for section in sections {
                let group = makeGroup(label: section.label, tracks: section.tracks)
                contentStack.addArrangedSubview(group)
                group.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
            }
        }

        updateArchivedCountLabel()
    }

    /// Grouped by status rather than one flat sorted list — the point of the redesign. Active is
    /// never empty-but-shown (there's either exactly one active track or none); Archived only
    /// appears at all once the checkbox reveals it.
    private func groupedSections() -> [(label: String, tracks: [Track])] {
        let all = trackStore?.tracks ?? []
        func tracks(for status: TrackStatus) -> [Track] {
            all.filter { $0.status == status }.sorted { $0.lastActiveAt > $1.lastActiveAt }
        }
        var sections: [(String, [Track])] = []
        for (label, status) in [("Active", TrackStatus.active), ("Waiting", .waiting), ("Review Ready", .reviewReady), ("Parked", .parked), ("Completed", .completed)] {
            let list = tracks(for: status)
            if !list.isEmpty { sections.append((label, list)) }
        }
        if showArchived {
            let archived = tracks(for: .archived)
            if !archived.isEmpty { sections.append(("Archived", archived)) }
        }
        return sections
    }

    /// The runner never writes `TrackStatus` — this is entirely a machine-computed, ephemeral
    /// view over `AgentActivity`, recomputed on every render rather than cached anywhere.
    private func activity(for track: Track) -> AgentActivity {
        runnerManager?.existingRunner(forTrackKey: track.branchName)?.activity ?? .none
    }

    private func needsYouTracks() -> [Track] {
        (trackStore?.tracks ?? []).filter { activity(for: $0) == .needsYou }.sorted { $0.lastActiveAt > $1.lastActiveAt }
    }

    private func makeGroup(label: String, tracks: [Track]) -> NSView {
        let groupStack = NSStackView()
        groupStack.orientation = .vertical
        groupStack.alignment = .leading
        groupStack.spacing = 7

        let labelField = NSTextField(labelWithString: label)
        labelField.font = .systemFont(ofSize: 12, weight: .semibold)
        labelField.textColor = .secondaryLabelColor
        groupStack.addArrangedSubview(labelField)

        let card = makeCard(tracks: tracks)
        groupStack.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: groupStack.widthAnchor).isActive = true

        return groupStack
    }

    /// The actual "card": one rounded, stroked container per status, holding its rows with
    /// hairline dividers between them — the inset-grouped-list pattern System Settings and
    /// Reminders use, not a table and not a stack of independently floating rows.
    private func makeCard(tracks: [Track]) -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.borderWidth = 1
        card.layer?.borderColor = TracksPalette.cardBorder.cgColor
        card.layer?.backgroundColor = TracksPalette.cardBackground.cgColor
        card.layer?.masksToBounds = true

        let rowsStack = NSStackView()
        rowsStack.orientation = .vertical
        rowsStack.spacing = 0
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        for (index, track) in tracks.enumerated() {
            let row = makeRow(for: track)
            rowsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
            if index < tracks.count - 1 {
                let hairline = NSBox()
                hairline.boxType = .custom
                hairline.borderType = .noBorder
                hairline.fillColor = TracksPalette.hairline
                hairline.translatesAutoresizingMaskIntoConstraints = false
                hairline.heightAnchor.constraint(equalToConstant: 1).isActive = true
                rowsStack.addArrangedSubview(hairline)
                hairline.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
            }
        }

        card.addSubview(rowsStack)
        NSLayoutConstraint.activate([
            rowsStack.topAnchor.constraint(equalTo: card.topAnchor),
            rowsStack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            rowsStack.bottomAnchor.constraint(equalTo: card.bottomAnchor)
        ])
        return card
    }

    private func makeRow(for track: Track) -> TrackRowView {
        var metaText = track.status == .active
            ? "active now"
            : Self.relativeDateFormatter.localizedString(for: track.lastActiveAt, relativeTo: Date())
        if let summary = gitSummaryCache[track.id] {
            let gitBits = gitSummaryText(summary)
            if !gitBits.isEmpty { metaText += " · \(gitBits)" }
        }
        let row = TrackRowView(
            intentText: track.intent,
            branchText: track.branchName,
            metaText: metaText,
            activity: activity(for: track),
            isActiveTrack: track.status == .active
        )
        row.menu = buildContextMenu(for: track)
        row.onDoubleClick = { [weak self] in self?.requestSwitch(to: track) }
        row.onPrimaryActionTapped = { [weak self] kind in
            guard let self else { return }
            switch kind {
            case .watch: self.requestSwitch(to: track)
            case .review: self.onReviewRequested?(track)
            case .markReviewReady:
                self.trackStore?.setStatus(.reviewReady, for: track)
                self.runnerManager?.existingRunner(forTrackKey: track.branchName)?.acknowledgeCompletion()
            }
        }
        row.onMenuButtonTapped = { [weak self] button in
            guard let self else { return }
            self.buildContextMenu(for: track).popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        }
        return row
    }

    /// Turns raw ahead/behind/dirty counts into the short fragment appended to a row's meta
    /// line — omits anything that's zero/nil so a clean, caught-up track just shows its
    /// relative-time text with nothing extra, same as before this existed.
    private func gitSummaryText(_ summary: TrackStore.GitSummary) -> String {
        var parts: [String] = []
        if summary.aheadCount > 0 { parts.append("\(summary.aheadCount) ahead") }
        if summary.behindCount > 0 { parts.append("\(summary.behindCount) behind") }
        if let uncommitted = summary.uncommittedCount, uncommitted > 0 {
            parts.append("\(uncommitted) uncommitted")
        }
        return parts.joined(separator: ", ")
    }

    /// Same container language as the status cards — a plain informational row, not an alert. No
    /// color fill; it just looks like one more inset group, because functionally that's what it is.
    /// Shared by all three "something needs your attention before the ledger makes sense" banners
    /// (untracked branch, detached HEAD, no git repo yet) so they read as one consistent affordance.
    private func makeInfoBannerCard(symbolName: String, text: String, buttonTitle: String, action: Selector) -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.borderWidth = 1
        card.layer?.borderColor = TracksPalette.cardBorder.cgColor
        card.layer?.backgroundColor = TracksPalette.cardBackground.cgColor

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
        label.font = .systemFont(ofSize: 12.5)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let button = NSButton(title: buttonTitle, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small

        let stack = NSStackView(views: [glyph, label, button])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
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
            text: "You're on \u{201C}\(branchName)\u{201D} — not a track yet.",
            buttonTitle: "Turn into a Track…",
            action: #selector(promoteBranchTapped)
        )
    }

    private func makeNotAGitRepoBanner() -> NSView {
        makeInfoBannerCard(
            symbolName: "exclamationmark.circle",
            text: "This project isn't a git repository yet — Tracks needs one to manage branches.",
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
    @objc func newTrackTapped() {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "New Track"
        alert.informativeText = "What are you working on?"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "Fix the save-conflict race"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let intent = field.stringValue
            // Creating a track moves HEAD immediately (it's checked out as part of creation, not
            // as a separate step), so unsaved Make edits need resolving first — same guard a
            // switch to an existing track goes through.
            self.onCreateTrackRequested? { [weak self] proceed in
                guard let self, proceed else { return }
                self.trackStore?.createTrack(intent: intent) { [weak self] result in
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
            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
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
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
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
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
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
            parts.append("couldn't cleanly restore this track's stashed changes — resolve the conflict, then the stash is still there if needed")
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
        let autoRunItem = menu.addItem(withTitle: "Auto-run Commands", action: #selector(toggleAutoRunCommands(_:)), keyEquivalent: "")
        autoRunItem.representedObject = track
        autoRunItem.state = track.autoRunCommands ? .on : .off
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

    /// Per-track opt-out of approval for `run_shell_command` — see `Track.autoRunCommands`.
    /// Everything else an agent proposes (edits) still always pauses for a human decision; this
    /// only ever affects commands, and only for this one track.
    @objc private func toggleAutoRunCommands(_ sender: NSMenuItem) {
        guard let track = sender.representedObject as? Track else { return }
        trackStore?.setAutoRunCommands(!track.autoRunCommands, for: track)
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
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
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
        alert.informativeText = "Frees the disk space this track's checkout uses. The \u{201C}\(track.branchName)\u{201D} branch and its history are untouched — switching back to this track re-creates the working copy."
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
            self.trackStore?.deleteTrack(track, alsoDeleteBranch: alsoDeleteBranch) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    self.onTrackDeleted?(track)
                case .failure(let error):
                    self.onTrackDeleted?(track)
                    self.showError(error, title: "Track deleted", window: window)
                }
            }
        }
    }
}

/// What the row's single primary button does — exactly the three states the plan calls for,
/// plus no button at all (the active track with nothing to report — you're already looking at
/// it, there's nothing to switch to or review yet).
private enum TrackRowPrimaryAction {
    case watch
    case review
    case markReviewReady

    var title: String {
        switch self {
        case .watch: return "Watch"
        case .review: return "Review"
        case .markReviewReady: return "Mark Review Ready"
        }
    }

    /// `.review`/`.markReviewReady` stay on screen always — an agent needing you or a finished
    /// run worth a look shouldn't be something you only discover by hovering every row. Plain
    /// `.watch` (nothing agent-related going on) keeps the original hover-only behavior.
    var alwaysVisible: Bool {
        switch self {
        case .watch: return false
        case .review, .markReviewReady: return true
        }
    }
}

/// One row inside a status card: intent (primary), branch chip + relative time + agent activity
/// (secondary), and a primary-action/kebab pair. The kebab always only appears on hover; the
/// primary button does too *unless* it's `.review`/`.markReviewReady`, per `alwaysVisible` above.
private final class TrackRowView: NSView {
    var onPrimaryActionTapped: ((TrackRowPrimaryAction) -> Void)?
    var onMenuButtonTapped: ((NSButton) -> Void)?
    var onDoubleClick: (() -> Void)?

    private let actionsStack = NSStackView()
    private let primaryButton = NSButton(title: "", target: nil, action: nil)
    private let menuButton = NSButton(title: "\u{22EF}", target: nil, action: nil)
    private var trackingArea: NSTrackingArea?
    private let primaryAction: TrackRowPrimaryAction?

    init(intentText: String, branchText: String, metaText: String, activity: AgentActivity, isActiveTrack: Bool) {
        switch activity {
        case .needsYou: primaryAction = .review
        case .doneUnread: primaryAction = .markReviewReady
        case .none, .working, .doneSeen: primaryAction = isActiveTrack ? nil : .watch
        }

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        let intentLabel = NSTextField(labelWithString: intentText)
        intentLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        intentLabel.textColor = .labelColor
        intentLabel.lineBreakMode = .byTruncatingTail

        let branchLabel = NSTextField(labelWithString: branchText)
        branchLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        branchLabel.textColor = .secondaryLabelColor

        let chip = NSView()
        chip.wantsLayer = true
        chip.layer?.backgroundColor = TracksPalette.chip.cgColor
        chip.layer?.cornerRadius = 4
        chip.translatesAutoresizingMaskIntoConstraints = false
        branchLabel.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(branchLabel)
        NSLayoutConstraint.activate([
            branchLabel.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 5),
            branchLabel.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -5),
            branchLabel.topAnchor.constraint(equalTo: chip.topAnchor, constant: 1),
            branchLabel.bottomAnchor.constraint(equalTo: chip.bottomAnchor, constant: -1)
        ])

        let sepLabel = NSTextField(labelWithString: "\u{00B7}")
        sepLabel.font = .systemFont(ofSize: 11.5)
        sepLabel.textColor = .tertiaryLabelColor

        let metaLabel = NSTextField(labelWithString: metaText)
        metaLabel.font = .systemFont(ofSize: 11.5)
        metaLabel.textColor = .secondaryLabelColor

        var metaRowViews: [NSView] = [chip, sepLabel, metaLabel]
        if let chipInfo = Self.agentChipInfo(for: activity) {
            let agentSep = NSTextField(labelWithString: "\u{00B7}")
            agentSep.font = .systemFont(ofSize: 11.5)
            agentSep.textColor = .tertiaryLabelColor
            let agentLabel = NSTextField(labelWithString: chipInfo.text)
            agentLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
            agentLabel.textColor = chipInfo.color
            metaRowViews.append(contentsOf: [agentSep, agentLabel])
        }
        let metaRow = NSStackView(views: metaRowViews)
        metaRow.orientation = .horizontal
        metaRow.alignment = .centerY
        metaRow.spacing = 6

        let mainStack = NSStackView(views: [intentLabel, metaRow])
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 2
        mainStack.translatesAutoresizingMaskIntoConstraints = false

        primaryButton.bezelStyle = .rounded
        primaryButton.controlSize = .small
        primaryButton.target = self
        primaryButton.action = #selector(handlePrimaryActionTapped)
        if let primaryAction {
            primaryButton.title = primaryAction.title
            if primaryAction == .review { primaryButton.keyEquivalent = "" } // no accidental Enter-triggered switch
        }

        menuButton.isBordered = false
        menuButton.font = .systemFont(ofSize: 13)
        menuButton.contentTintColor = .secondaryLabelColor
        menuButton.target = self
        menuButton.action = #selector(handleMenuTapped)

        actionsStack.orientation = .horizontal
        actionsStack.alignment = .centerY
        actionsStack.spacing = 6
        actionsStack.translatesAutoresizingMaskIntoConstraints = false
        actionsStack.alphaValue = (primaryAction?.alwaysVisible == true) ? 1 : 0
        if let primaryAction {
            actionsStack.addArrangedSubview(primaryButton)
            // The always-visible actions get their own visual weight (a filled/tinted bezel)
            // so a row worth acting on reads as such at a glance, not just as one more gray
            // button among the hover-only ones.
            primaryButton.contentTintColor = primaryAction.alwaysVisible ? Self.tintColor(for: activity) : nil
        }
        actionsStack.addArrangedSubview(menuButton)

        addSubview(mainStack)
        addSubview(actionsStack)
        NSLayoutConstraint.activate([
            mainStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            mainStack.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            mainStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
            mainStack.trailingAnchor.constraint(lessThanOrEqualTo: actionsStack.leadingAnchor, constant: -12),
            actionsStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            actionsStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 42)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = TracksPalette.rowHover.cgColor
        actionsStack.animator().alphaValue = 1
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = nil
        actionsStack.animator().alphaValue = (primaryAction?.alwaysVisible == true) ? 1 : 0
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        if event.clickCount == 2 { onDoubleClick?() }
    }

    /// Routes clicks that land on a purely-decorative descendant (the intent/branch/meta labels)
    /// back to this row, so double-click-to-switch works no matter where in the row you click —
    /// but leaves genuine control hits (the primary/kebab buttons) alone.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let result = super.hitTest(point) else { return nil }
        if result === self || result === primaryButton || result === menuButton { return result }
        return self
    }

    @objc private func handlePrimaryActionTapped() {
        guard let primaryAction else { return }
        onPrimaryActionTapped?(primaryAction)
    }
    @objc private func handleMenuTapped() { onMenuButtonTapped?(menuButton) }

    /// Short label + semantic color for the always-on activity indicator in the meta row — `nil`
    /// for `.none`, since a track with no agent history shouldn't show an empty chip.
    private static func agentChipInfo(for activity: AgentActivity) -> (text: String, color: NSColor)? {
        switch activity {
        case .none: return nil
        case .working: return ("Working", .systemBlue)
        case .needsYou: return ("Needs you", .systemOrange)
        case .doneUnread: return ("Done", .systemGreen)
        case .doneSeen: return ("Done", .secondaryLabelColor)
        }
    }

    private static func tintColor(for activity: AgentActivity) -> NSColor {
        switch activity {
        case .needsYou: return .systemOrange
        case .doneUnread: return .systemGreen
        case .none, .working, .doneSeen: return .controlAccentColor
        }
    }
}
