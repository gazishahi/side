import AppKit
import UserNotifications

/// One system notification per transition into "needs you" — no queueing or coalescing across
/// several tracks in quick succession; good enough for a first pass. Authorization is requested
/// lazily on first use and never blocks the notification attempt — if the user hasn't granted it
/// yet (or denies it), `add` just silently no-ops, which is the right degrade for something this
/// non-essential.
@MainActor
private enum AgentAttentionNotifier {
    private static var didRequestAuthorization = false

    static func notify(trackIntent: String) {
        let center = UNUserNotificationCenter.current()
        if !didRequestAuthorization {
            didRequestAuthorization = true
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        let content = UNMutableNotificationContent()
        content.title = "Needs your attention"
        content.body = trackIntent
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

private extension NSToolbarItem.Identifier {
    static let projectLabel = NSToolbarItem.Identifier("side.project-label")
    static let stageSwitcher = NSToolbarItem.Identifier("side.stage-switcher")
    static let quickOpen = NSToolbarItem.Identifier("side.quick-open")
    static let lspStatus = NSToolbarItem.Identifier("side.lsp-status")
}

final class ShellViewController: NSViewController, NSToolbarDelegate {
    // Think sits next to Make — those are the two stages a user bounces between most while
    // an agent works, so they get adjacent segments. Review sits right after Think (where its
    // checkpoints come from) and before Run (where its tests run) — the same order the
    // constitution's own stage table uses.
    enum Stage: String, CaseIterable { case make = "Make", think = "Think", review = "Review", run = "Run", tracks = "Tracks" }

    private let stageControl = NSSegmentedControl(labels: Stage.allCases.map(\.rawValue), trackingMode: .selectOne, target: nil, action: nil)
    private let projectLabel = NSTextField(labelWithString: "")
    private let container = NSView()
    private lazy var makeVC = MakeWorkspaceViewController()
    private lazy var thinkVC = ThinkWorkspaceViewController()
    private lazy var reviewVC = ReviewWorkspaceViewController()
    private lazy var runVC = RunWorkspaceViewController()
    private lazy var tracksVC = TracksWorkspaceViewController()
    private var current: Stage?
    /// Shared with every other window that has the same project open — see `ProjectContext`.
    private var projectContext: ProjectContext?
    private var trackStore: TrackStore? { projectContext?.trackStore }
    private var trackStoreObserverToken = UUID()
    private var runnerChangeObserverToken = UUID()
    /// Track ids that were `.needsYou` as of the last `runnerActivityChanged()` — diffed against
    /// the current set so a notification fires once per transition *into* needing attention, not
    /// once per debounced recompute while it stays that way.
    private var lastKnownNeedsYouTrackIDs: Set<UUID> = []
    /// The track this window's stages (Make/Run/Think) are actually showing — distinct from
    /// `trackStore?.activeTrack`, which can change out from under this window via another window
    /// switching tracks on the shared store. Only updated at the same three points Make/Run/Think
    /// themselves get reloaded, so it never claims a track this window hasn't actually switched
    /// to yet. Backs `WorkspaceBridgeHost` — an `AgentRunner` uses it to decide whether *this*
    /// window is the one to write an approved edit into.
    private var currentTrackKey: String?
    /// Where `currentTrackKey`'s stages actually operate — its own worktree if it has one, else
    /// `projectURL`. Threaded into Make/Run's `reloadForTrackSwitch` and used as the root for
    /// this window's own git-status/branch introspection (`refreshGitInfo`), so the title bar
    /// reflects the track actually being looked at rather than always the shared main tree.
    private var focusedRoot: URL?

    private var projectURL: URL?
    private var currentFileURL: URL?
    private var isDirty = false
    private var gitBranch: String?
    private var gitDirtyCount = 0

    override func loadView() { view = NSView() }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildLayout()
        makeVC.onProjectOpened = { [weak self] url in self?.projectOpened(url) }
        makeVC.onFileOpened = { [weak self] url in self?.fileOpened(url) }
        makeVC.onDirtyChanged = { [weak self] dirty in self?.isDirty = dirty; self?.applyWindowChrome() }
        makeVC.onTearOutRequested = { [weak self] url, screenPoint in
            guard let self, let projectURL = self.projectURL else { return }
            AppDelegate.shared?.openTrackInNewWindow(projectRoot: projectURL, trackKey: self.currentTrackKey, focusingFile: url, at: screenPoint)
        }
        runVC.onOpenFileRequested = { [weak self] url, line in
            guard let self else { return }
            self.show(.make)
            self.makeVC.revealFile(url, line: line)
        }
        runVC.onActivityChanged = { [weak self] in self?.updateStageLabels() }
        tracksVC.onSwitchRequested = { [weak self] track, completion in
            self?.switchToTrack(track, completion: completion)
        }
        tracksVC.onReviewRequested = { [weak self] track in
            guard let self else { return }
            guard track.status != .active else { self.show(.think); return }
            self.switchToTrack(track, landOn: .think, completion: { _ in })
        }
        tracksVC.onCreateTrackRequested = { [weak self] completion in
            self?.confirmCloseAllUnsaved(completion: completion)
        }
        tracksVC.onTrackCreated = { [weak self] track in
            self?.branchIsNowActive(track.branchName)
        }
        tracksVC.onBranchSwitched = { [weak self] branchName in
            self?.branchIsNowActive(branchName)
        }
        tracksVC.onTrackDeleted = { [weak self] track in
            guard let self else { return }
            self.makeVC.forgetLastFile(forTrackKey: track.branchName)
            self.runVC.discardSessions(forTrackKey: track.branchName)
            self.projectContext?.sessionStore.removeSession(forTrackKey: track.branchName)
            if let projectPath = self.projectContext?.projectRoot.path {
                UsageStore.shared.removeUsage(projectPath: projectPath, trackKey: track.branchName)
            }
            self.projectContext?.runnerManager.discardRunner(forTrackKey: track.branchName)
        }
        show(.make)
    }

    var hasUnsavedChanges: Bool { makeVC.hasUnsavedChanges }
    func confirmCloseAllUnsaved(completion: @escaping (Bool) -> Void) { makeVC.confirmCloseAllUnsaved(completion: completion) }
    func restoreLastSessionIfAvailable() { makeVC.restoreLastSessionIfAvailable() }

    /// Loads a project into this (freshly-created) window and, if given, switches straight to
    /// one specific track — the entry point for Tracks' "Open in New Window", which is meant to
    /// land on the requested track directly rather than whatever this project's globally-active
    /// track happens to be. `loadProject` runs `projectOpened` synchronously (see its own
    /// comment), so `trackStore` is already populated by the time this looks the track up.
    func openProject(at url: URL, focusingTrackKey: String?) {
        makeVC.loadProject(at: url)
        guard let focusingTrackKey, let store = trackStore,
              let track = store.tracks.first(where: { $0.branchName == focusingTrackKey }),
              track.status != .active
        else { return }
        switchToTrack(track, completion: { _ in })
    }

    func prepareForClose() {
        makeVC.prepareForClose()
        thinkVC.prepareForClose()
        runVC.prepareForClose()
        if let projectURL {
            trackStore?.removeChangeObserver(trackStoreObserverToken)
            projectContext?.runnerManager.removeChangeObserver(runnerChangeObserverToken)
            projectContext?.unregisterBridgeHost(self)
            ProjectContextRegistry.shared.release(projectRoot: projectURL)
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard let window = view.window, window.toolbar == nil else { return }
        let toolbar = NSToolbar(identifier: "side.shell.toolbar")
        toolbar.delegate = self
        toolbar.centeredItemIdentifier = .stageSwitcher
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact
        window.titleVisibility = .visible
        applyWindowChrome()
    }

    private func buildLayout() {
        view.wantsLayer = true
        ChromeBackground.install(in: view)

        stageControl.segmentStyle = .texturedRounded
        stageControl.selectedSegment = 0
        stageControl.target = self
        stageControl.action = #selector(stageChanged(_:))

        projectLabel.font = DS.Text.control(.medium)
        projectLabel.textColor = .secondaryLabelColor
        projectLabel.lineBreakMode = .byTruncatingMiddle

        container.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(container)

        NSLayoutConstraint.activate([
            // safeAreaLayoutGuide, not view.topAnchor: with .fullSizeContentView the content
            // view now extends up behind the title bar/toolbar (that's the point — it's what
            // lets our background color show through there), but actual Make/Run content still
            // needs to start below the toolbar controls, not underneath them.
            container.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    // MARK: - Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.projectLabel, .flexibleSpace, .stageSwitcher, .flexibleSpace, .lspStatus, .quickOpen] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.projectLabel, .stageSwitcher, .lspStatus, .quickOpen, .flexibleSpace] }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .projectLabel:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            projectLabel.translatesAutoresizingMaskIntoConstraints = false
            projectLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 200).isActive = true
            item.view = projectLabel
            item.label = "Project"
            // This is the item that's allowed to collapse into the overflow chevron at narrow
            // widths — but a collapsed custom-view item renders as a dead menu entry unless it's
            // given a real menu form. Make it do the one obviously-useful project-level thing.
            let menuForm = NSMenuItem(title: "Reveal Project in Finder", action: #selector(revealProjectInFinder), keyEquivalent: "")
            menuForm.target = self
            item.menuFormRepresentation = menuForm
            return item
        case .stageSwitcher:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = stageControl
            item.label = "Stage"
            // Never collapses into the overflow chevron — the stage switcher *is* the app's
            // navigation; a hidden one means a stranded user. Same for Quick Open below: a
            // collapsed toolbar search field renders as a dead button, so both stay visible and
            // the window's minimum size (AppDelegate) is what guarantees they fit.
            item.visibilityPriority = .high
            return item
        case .lspStatus:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            let button = makeVC.lspStatusButton
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 24).isActive = true
            item.view = button
            item.label = "Language Server"
            // 24pt wide and hidden most of the time — never worth collapsing into the overflow
            // chevron, where it would only ever appear as a dead "Language Server" entry.
            item.visibilityPriority = .high
            return item
        case .quickOpen:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            let field = makeVC.searchField
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 320).isActive = true
            item.view = field
            item.label = "Quick Open"
            item.visibilityPriority = .high
            return item
        default:
            return nil
        }
    }

    // MARK: - Stage switching

    @objc private func stageChanged(_ sender: NSSegmentedControl) {
        show(Stage.allCases[sender.selectedSegment])
    }

    /// Navigate-menu stage jumps (⌃1–⌃5), reached via the responder chain — the constitution
    /// promised "keyboard shortcuts … move between stages" from day one; this is finally them.
    @objc func jumpToStage(_ sender: NSMenuItem) {
        guard Stage.allCases.indices.contains(sender.tag) else { return }
        show(Stage.allCases[sender.tag])
    }

    /// Routed from the app delegate's File-menu items, which are app-level commands and must
    /// stay enabled regardless of what holds first responder.
    func presentOpenProject() { makeVC.openProjectFromMenuAction() }
    func presentNewProject() { makeVC.newProjectFromMenuAction() }

    @objc private func revealProjectInFinder() {
        guard let projectURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([projectURL])
    }

    /// A tab torn out of another window landing here — jump to Make and show that file.
    func revealFile(_ url: URL) {
        show(.make)
        makeVC.revealFile(url, line: nil)
    }

    private func show(_ stage: Stage) {
        guard current != stage else { return }
        current = stage
        stageControl.selectedSegment = Stage.allCases.firstIndex(of: stage) ?? 0

        for child in children {
            child.view.removeFromSuperview()
            child.removeFromParent()
        }

        let next: NSViewController
        switch stage {
        case .make: next = makeVC
        case .think: next = thinkVC
        case .review: next = reviewVC
        case .run: next = runVC
        case .tracks: next = tracksVC
        }
        addChild(next)
        next.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(next.view)
        NSLayoutConstraint.activate([
            next.view.topAnchor.constraint(equalTo: container.topAnchor),
            next.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            next.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            next.view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        if stage == .run {
            runVC.activateActiveSession()
        }
    }

    private func updateStageLabels() {
        let runIndex = Stage.allCases.firstIndex(of: .run) ?? 1
        stageControl.setLabel(runVC.hasBackgroundActivity ? "Run \u{25CF}" : "Run", forSegment: runIndex)

        // needsYou takes precedence over working — a track blocked on approval matters more
        // than one that's merely busy, and this is the one predicate every other "reach the
        // user" surface (dock badge, notification) also keys off, so a new blocking reason
        // showing up here is structurally guaranteed to show up everywhere else too.
        let tracksIndex = Stage.allCases.firstIndex(of: .tracks) ?? 3
        let label: String
        if !needsYouTrackIDs().isEmpty {
            label = "Tracks \u{25D1}" // ◑ — distinct from Run's solid dot, reads as "half-done/waiting"
        } else if hasWorkingTrack() {
            label = "Tracks \u{25CF}"
        } else {
            label = "Tracks"
        }
        stageControl.setLabel(label, forSegment: tracksIndex)
    }

    // MARK: - Agent activity (dock badge, notifications)

    private func needsYouTrackIDs() -> Set<UUID> {
        guard let trackStore, let runnerManager = projectContext?.runnerManager else { return [] }
        return Set(trackStore.tracks.filter { runnerManager.existingRunner(forTrackKey: $0.branchName)?.activity == .needsYou }.map(\.id))
    }

    private func hasWorkingTrack() -> Bool {
        guard let trackStore, let runnerManager = projectContext?.runnerManager else { return false }
        return trackStore.tracks.contains { runnerManager.existingRunner(forTrackKey: $0.branchName)?.activity == .working }
    }

    /// Read by `AppDelegate` to sum a dock badge across every open window — see
    /// `AppDelegate.refreshDockBadge()`. Two windows on the same project will double-count its
    /// tracks; an acceptable imprecision for a cosmetic badge, not worth deduplicating against
    /// the added complexity of exposing project identity to `AppDelegate`.
    var needsYouCount: Int { needsYouTrackIDs().count }

    /// Called after every debounced runner-manager change. Diffs against `lastKnownNeedsYouTrackIDs`
    /// so a notification fires once per transition *into* needing attention, not once per
    /// recompute while it stays that way, and refreshes the dock badge either way.
    private func runnerActivityChanged() {
        let currentNeedsYou = needsYouTrackIDs()
        let newlyNeedsYou = currentNeedsYou.subtracting(lastKnownNeedsYouTrackIDs)
        lastKnownNeedsYouTrackIDs = currentNeedsYou
        AppDelegate.shared?.refreshDockBadge()

        guard !newlyNeedsYou.isEmpty else { return }
        let tracks = (trackStore?.tracks ?? []).filter { newlyNeedsYou.contains($0.id) }
        for track in tracks {
            // Suppressed only when this window is both key (frontmost/focused) *and* already
            // showing the relevant thing — the Tracks stage surfaces every needs-you track in
            // its pinned section, so being on that stage at all counts as "already looking,"
            // regardless of which track it is; Think only counts for the one track it's
            // actually attached to. A non-key window (app backgrounded, another window
            // focused) is never "already looking," however visible its own stage happens to be.
            let alreadyLooking = view.window?.isKeyWindow == true
                && (current == .tracks || (current == .think && track.branchName == currentTrackKey))
            guard !alreadyLooking else { continue }
            AgentAttentionNotifier.notify(trackIntent: track.intent)
        }
    }

    // MARK: - Window chrome (title, subtitle, git info)

    /// A track's own linked worktree if it has one, else the shared project root — the same
    /// resolution `ProjectContext.workingDirectory(forTrackKey:)` does for Heron, just needed
    /// here too since Make/Run are pushed-to rather than pull-based.
    /// The cwd for a *new* Run session.
    ///
    /// The home-directory fallback is deliberate but was silently reachable with no project
    /// open at all — ⌃4 spawned a shell in the user's home directory with nothing saying so,
    /// which is a surprising place to find yourself typing `rm`. Run now refuses to open a
    /// session without a project (see `activateActiveSession`), so this fallback only covers
    /// the genuinely-odd case of a project whose directory vanished mid-session.
    private func workingDirectoryURL(for trackKey: String?) -> URL {
        projectContext?.workingDirectory(forTrackKey: trackKey ?? "") ?? projectURL ?? URL(fileURLWithPath: NSHomeDirectory())
    }

    private func projectOpened(_ url: URL) {
        // Opening a different project (or reopening after this window already had one) drops
        // this window's claim on whatever it held before — without this, the old project's
        // context would never hit zero refcount and would leak for the life of the app.
        if let previousURL = projectURL, let previousContext = projectContext {
            previousContext.trackStore.removeChangeObserver(trackStoreObserverToken)
            previousContext.runnerManager.removeChangeObserver(runnerChangeObserverToken)
            previousContext.unregisterBridgeHost(self)
            ProjectContextRegistry.shared.release(projectRoot: previousURL)
        }
        projectURL = url
        runVC.defaultWorkingDirectory = url.path
        let context = ProjectContextRegistry.shared.acquire(projectRoot: url)
        projectContext = context
        context.registerBridgeHost(self)
        let store = context.trackStore
        // TrackStore's init resolves activeTrack/untrackedBranch synchronously specifically so
        // this can be set before Make's own (already in-flight) project-open indexing reads it —
        // otherwise the very first file restore after opening a project on an active track's
        // branch would read the shared per-project bucket instead of that track's own memory.
        currentTrackKey = store.activeTrack?.branchName
        let workingDirectory = workingDirectoryURL(for: currentTrackKey)
        focusedRoot = workingDirectory
        // Only bother retargeting Make/Run's LSP/indexing/terminal-cwd machinery when the active
        // track actually has its own worktree — the common case (no active track yet, or one
        // that predates Phase C) needs nothing more than the plain track-key assignment Make's
        // own `loadProject` already set up.
        if workingDirectory == url {
            makeVC.currentTrackKey = currentTrackKey
            runVC.currentTrackKey = currentTrackKey
        } else {
            makeVC.reloadForTrackSwitch(trackKey: currentTrackKey, workingDirectory: workingDirectory)
            runVC.reloadForTrackSwitch(trackKey: currentTrackKey, workingDirectory: workingDirectory)
        }
        runVC.hasProject = true
        thinkVC.onRevealFileRequested = { [weak self] url in self?.revealFile(url) }
        thinkVC.onOpenReviewRequested = { [weak self] in self?.show(.review) }
        thinkVC.configure(runnerManager: context.runnerManager, trackStore: context.trackStore, projectPath: context.projectRoot.path, trackKey: currentTrackKey)
        reviewVC.configure(trackStore: store, sessionStore: context.sessionStore, canonicalRoot: url)
        reviewVC.reloadForTrackSwitch(trackKey: currentTrackKey, workingDirectory: workingDirectory)
        // Registered rather than assigned: `store` may already be shared with another window
        // (same project, two windows), and a plain single-assignment `onChange` would let this
        // window's registration silently replace that other window's.
        trackStoreObserverToken = store.addChangeObserver { [weak self] in
            guard let self else { return }
            self.tracksVC.refresh()
            // Deliberately does *not* reassign `makeVC.currentTrackKey` here — this fires on
            // *any* change to the shared store, including one driven by a different window on
            // the same project. `currentTrackKey` is this window's own authoritative field
            // (set only by `projectOpened`/`switchToTrack`/`branchIsNowActive`, all explicit
            // actions taken *in this window*); overwriting it with `store.activeTrack` here used
            // to silently snap every window back to whichever track was globally active,
            // defeating "Open Track in New Window" (and any other case of two windows
            // deliberately looking at two different tracks) the moment either one changed.
            self.applyWindowChrome()
        }
        // Same multicast reasoning as the TrackStore observer above — `context.runnerManager`
        // is shared across every window on this project, so this can't be a single-assignment
        // closure without the same clobbering bug A1 fixed for tracks.
        runnerChangeObserverToken = context.runnerManager.addChangeObserver { [weak self] in
            guard let self else { return }
            self.tracksVC.refresh()
            self.updateStageLabels()
            self.runnerActivityChanged()
        }
        tracksVC.configure(with: store, runnerManager: context.runnerManager)
        applyWindowChrome()
        refreshGitInfo(for: workingDirectory)
    }

    /// Switching to a track with its own worktree is instant bookkeeping — no checkout, so no
    /// unsaved-changes risk from *that* alone — but this still goes through the same
    /// unsaved-changes guard tab-closing uses, because Make's own tabs are about to be closed
    /// and reopened against the new track's files regardless of how the switch itself happened.
    private func switchToTrack(_ track: Track, landOn: Stage = .make, completion: @escaping (TrackSwitchOutcome?) -> Void) {
        confirmCloseAllUnsaved { [weak self] proceed in
            guard let self, proceed, let store = self.trackStore else { completion(nil); return }
            store.switchTo(track) { [weak self] result in
                guard let self else { completion(nil); return }
                switch result {
                case .success(let outcome):
                    // Read fresh from the store, not the `track` value captured above — `switchTo`
                    // may have just materialized a worktree and updated `workingDirectoryPath` on
                    // its own copy, which this closure's `track` snapshot predates.
                    let workingDirectory = self.workingDirectoryURL(for: track.branchName)
                    self.focusedRoot = workingDirectory
                    self.refreshGitInfo(for: workingDirectory)
                    self.currentTrackKey = track.branchName
                    self.makeVC.reloadForTrackSwitch(trackKey: track.branchName, workingDirectory: workingDirectory)
                    self.runVC.reloadForTrackSwitch(trackKey: track.branchName, workingDirectory: workingDirectory)
                    self.thinkVC.reloadForTrackSwitch(trackKey: track.branchName)
                    self.reviewVC.reloadForTrackSwitch(trackKey: track.branchName, workingDirectory: workingDirectory)
                    self.show(landOn)
                    completion(outcome)
                case .failure(let error):
                    if let window = self.view.window {
                        let alert = NSAlert()
                        alert.alertStyle = .warning
                        alert.messageText = "Couldn't switch tracks"
                        alert.informativeText = error.localizedDescription
                        alert.addButton(withTitle: "OK")
                        alert.beginSheetModal(for: window)
                    }
                    completion(nil)
                }
            }
        }
    }

    /// A brand-new track (or a newly-adopted existing branch — same shape, no `Track` object
    /// needed here since only the branch name matters) is checked out as part of creating/adopting
    /// it, not a separate step — so there's no second checkout to wait on here, just reflecting
    /// what already happened: refresh git info, reload Make/Run onto this branch's own remembered
    /// state, and land on Make so there's somewhere to actually start working.
    private func branchIsNowActive(_ branchName: String) {
        let workingDirectory = workingDirectoryURL(for: branchName)
        focusedRoot = workingDirectory
        refreshGitInfo(for: workingDirectory)
        currentTrackKey = branchName
        makeVC.reloadForTrackSwitch(trackKey: branchName, workingDirectory: workingDirectory)
        runVC.reloadForTrackSwitch(trackKey: branchName, workingDirectory: workingDirectory)
        thinkVC.reloadForTrackSwitch(trackKey: branchName)
        reviewVC.reloadForTrackSwitch(trackKey: branchName, workingDirectory: workingDirectory)
        show(.make)
    }

    /// `url` is non-nil for an actual file open — from anywhere reachable regardless of stage
    /// (the toolbar's Quick Open field, the file explorer), not just from Make itself. Without
    /// jumping to Make here, opening a file while looking at Run or Tracks would silently update
    /// this window's title/represented-file and nothing else, since there's no visible editor to
    /// show it in — same fix Run's own "open file from a terminal link" feature already needed
    /// and had to do by hand; this makes it automatic for every path instead of one at a time.
    /// `nil` means a close (e.g. the last tab), which shouldn't yank you onto Make from wherever
    /// you are.
    private func fileOpened(_ url: URL?) {
        currentFileURL = url
        isDirty = false
        applyWindowChrome()
        if url != nil { show(.make) }
    }

    private func applyWindowChrome() {
        projectLabel.stringValue = projectURL?.lastPathComponent ?? ""
        guard let window = view.window else { return }
        window.representedURL = currentFileURL
        let fileName = currentFileURL?.lastPathComponent
        window.title = (isDirty ? fileName.map { "\($0) — Edited" } : fileName) ?? projectURL?.lastPathComponent ?? "Side"

        var subtitleParts: [String] = []
        if let projectURL, let currentFileURL {
            subtitleParts.append(humanePath(for: currentFileURL, projectURL: projectURL))
        } else if let projectName = projectURL?.lastPathComponent {
            subtitleParts.append(projectName)
        }
        if let branch = gitBranch {
            // The branch slug is precise but not what the user actually typed — showing the
            // track's own intent alongside it reads as "what am I doing" rather than "which ref
            // am I on." Looked up by *this window's* `currentTrackKey`, not `trackStore
            // .activeTrack` — the latter is the single globally-active track, which isn't
            // necessarily what this specific window is showing (two windows can each be
            // watching a different track on the same project).
            let track = trackStore?.tracks.first { $0.branchName == currentTrackKey }
            let branchLabel = track.map { "\($0.intent) (\(branch))" } ?? branch
            subtitleParts.append(gitDirtyCount > 0 ? "\(branchLabel) · \(gitDirtyCount) changed" : branchLabel)
        }
        window.subtitle = subtitleParts.joined(separator: " — ")
    }

    /// A project-relative path for the subtitle, never an absolute one. The old naive
    /// projectURL-prefix strip silently failed for any file living in a track's *worktree*
    /// (whose root isn't the project folder), leaking the full
    /// `…/Application Support/Side/Worktrees/…` path into the window chrome. Tries the project
    /// root, then the worktrees root (skipping the per-track directory segment), then falls
    /// back to the file's last two path components — always something a person would say.
    private func humanePath(for fileURL: URL, projectURL: URL) -> String {
        let filePath = fileURL.path
        if filePath.hasPrefix(projectURL.path + "/") {
            return String(filePath.dropFirst(projectURL.path.count + 1))
        }
        if let worktreesRoot = cachedWorktreesRootPath,
           filePath.hasPrefix(worktreesRoot + "/") {
            let insideWorktrees = filePath.dropFirst(worktreesRoot.count + 1)
            if let slash = insideWorktrees.firstIndex(of: "/") {
                return String(insideWorktrees[insideWorktrees.index(after: slash)...])
            }
        }
        return fileURL.pathComponents.suffix(2).joined(separator: "/")
    }

    /// The project's worktrees root, resolved once per project on the git background queue —
    /// never synchronously in `applyWindowChrome`, which runs on the main thread on every title
    /// update. The original version shelled out to git from there on each call, and a tear-out
    /// (two windows both rebuilding chrome at once) turned that into a burst of main-thread
    /// `Process` spawns that crashed inside Foundation.
    private var cachedWorktreesRootPath: String?

    private func refreshGitInfo(for project: URL) {
        // The worktrees root must be derived from the canonical project, not `project` (which
        // is this window's focused root and may itself be a worktree).
        let canonicalProject = projectURL
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // `symbolic-ref`, not `rev-parse --abbrev-ref HEAD`: the latter's output is
            // inconsistent on a zero-commit repo (can print a bare "HEAD" the same way real
            // detached HEAD does). `nil` here just means detached, which the subtitle omits
            // rather than showing a misleading branch name for.
            let branch = Self.runGit(["symbolic-ref", "--quiet", "--short", "HEAD"], in: project.path)
            let status = Self.runGit(["status", "--porcelain"], in: project.path)
            let dirtyCount = status?.split(separator: "\n").count ?? 0
            let worktreesRoot = canonicalProject.flatMap { GitPaths.worktreesRootDirectory(for: $0)?.path }
            DispatchQueue.main.async {
                guard let self, self.focusedRoot == project else { return }
                self.gitBranch = (branch?.isEmpty == false) ? branch : nil
                self.gitDirtyCount = dirtyCount
                self.cachedWorktreesRootPath = worktreesRoot
                self.applyWindowChrome()
            }
        }
    }

    nonisolated private static func runGit(_ args: [String], in directory: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", directory] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        // Read before waiting — waiting first deadlocks once git fills the pipe buffer
        // (see GitPaths.runGit).
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - WorkspaceBridgeHost

/// Lets `AgentRunner`s reach into whichever window is actually showing the track they belong
/// to — see `ProjectContext.bridge(forTrackKey:)`. Deliberately not exposing `NSWindow` itself
/// to `ProjectContext`: it only ever needs a yes/no on "is this window key," not the window.
extension ShellViewController: WorkspaceBridgeHost {
    var bridgeTrackKey: String? { currentTrackKey }
    var isKeyWindow: Bool { view.window?.isKeyWindow == true }
    func liveBufferContent(for url: URL) -> String? { makeVC.unsavedContent(for: url) }
    func applyApprovedEdit(url: URL, newContent: String) -> Bool { makeVC.applyApprovedEdit(url: url, newContent: newContent) }
    // Approving an edit lands you in the file that changed — same reflex as Run's
    // open-file-from-terminal-link jump, just triggered from Think.
    func revealAfterApply(_ url: URL) {
        show(.make)
        makeVC.revealAfterApply(url)
    }
    func runShellCommand(_ command: String, trackKey: String, completion: @escaping (String) -> Void) {
        runVC.runAgentCommand(command, cwd: workingDirectoryURL(for: trackKey), trackKey: trackKey, completion: completion)
    }
    func interruptShellCommand(trackKey: String) {
        runVC.interruptAgentCommand(trackKey: trackKey)
    }
}
