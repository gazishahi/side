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

final class ShellViewController: NSViewController {
    // Think sits next to Make — those are the two stages a user bounces between most while
    // an agent works, so they get adjacent segments. Review sits right after Think (where its
    // checkpoints come from) and before Run (where its tests run) — the same order the
    // constitution's own stage table uses.
    enum Stage: String, CaseIterable { case make = "Make", think = "Think", review = "Review", run = "Run", tracks = "Tracks" }

    /// Direction 02 §3: no title bar, no toolbar. The navigation components are plain views;
    /// `chrome` decides where they go.
    private let stageControl = SlidingSegmentedControl(titles: StagePins.pinnable.map(\.rawValue), style: .overlay)
    private let trackPill = TrackPill()
    private let searchButton = NSButton()
    private lazy var chrome = ChromeHost(placement: ChromePlacement.current, pill: trackPill, stageControl: stageControl, searchButton: searchButton)
    private let container = NSView()
    /// The stages the control currently shows, in order — see `StagePins.visible`.
    private var visibleStages: [Stage] = StagePins.pinnable
    /// Unpinned stages that showed themselves for attention and have since been visited. They
    /// stay out of the control until their attention clears and comes back.
    private var dismissedAttention: Set<Stage> = []
    private var lastAttention: Set<Stage> = []
    private var paletteHost: NSView?
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
        LaunchSignposts.begin("shellViewDidLoad")
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
        // The one placement-specific hook outside the host: Think's composer and the bar are a
        // single stack, and the bar recedes while the composer holds text (§3.4).
        thinkVC.onComposerEngagedChanged = { [weak self] engaged in self?.chrome.setBarRecessed(engaged) }
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
            self.projectContext?.terminals.discardSessions(forTrackKey: track.branchName)
            self.projectContext?.sessionStore.removeSession(forTrackKey: track.branchName)
            if let projectPath = self.projectContext?.projectRoot.path {
                UsageStore.shared.removeUsage(projectPath: projectPath, trackKey: track.branchName)
            }
            self.projectContext?.runnerManager.discardRunner(forTrackKey: track.branchName)
        }
        show(.make)
        LaunchSignposts.end("shellViewDidLoad")
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
        LaunchSignposts.begin("shellViewDidAppear")
        // Normally already installed by `makeWindow` before the window was shown; this is the
        // fallback for a window that acquired this controller some other way.
        if let window = view.window, window.titleVisibility != .hidden { installChrome(in: window) }
        LaunchSignposts.end("shellViewDidAppear")
    }

    /// The seamless frame (Direction 02 §3.2): no title bar drawn, no toolbar, content to the
    /// top edge. Called from `AppDelegate.makeWindow` before the window is ordered front. The
    /// title is still set — Mission Control, the Window menu and VoiceOver read it.
    func installChrome(in window: NSWindow) {
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.toolbar = nil
        chrome.positionTrafficLights(in: window)
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    guard let self, let window else { return }
                    self.chrome.setFullScreen(window.styleMask.contains(.fullScreen))
                    self.chrome.positionTrafficLights(in: window)
                }
            }
        }
        applyWindowChrome()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if let window = view.window { chrome.positionTrafficLights(in: window) }
        chrome.adapt(toWidth: view.bounds.width)
        if let host = paletteHost, !host.isHidden { host.frame = chrome.paletteFrame(size: host.frame.size, in: view) }
    }

    private func buildLayout() {
        view.wantsLayer = true
        ChromeBackground.install(in: view)

        stageControl.onChange = { [weak self] index in
            guard let self, self.visibleStages.indices.contains(index) else { return }
            self.show(self.visibleStages[index])
        }
        stageControl.setAccessibilityLabel("Stage")
        stageControl.menu = pinsMenu()
        searchButton.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Search")
        searchButton.isBordered = false
        searchButton.contentTintColor = .secondaryLabelColor
        searchButton.target = self
        searchButton.action = #selector(showQuickOpen(_:))
        searchButton.toolTip = "Search (⌘P)"
        searchButton.setAccessibilityLabel("Search")
        searchButton.translatesAutoresizingMaskIntoConstraints = false
        searchButton.widthAnchor.constraint(equalToConstant: 28).isActive = true
        trackPill.snapshotProvider = { [weak self] in self?.trackPillSnapshot() ?? .empty }
        trackPill.onSelectRow = { [weak self] row in self?.selectTrackRow(row) }
        trackPill.onNewTrack = { [weak self] in
            self?.show(.tracks)
            self?.tracksVC.newTrackTapped()
        }
        trackPill.onOpenTracks = { [weak self] in self?.show(.tracks) }

        chrome.install(in: view, content: container)
        NotificationCenter.default.addObserver(forName: StagePins.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.stageControl.menu = self.pinsMenu()
                self.refreshStageControl()
            }
        }
        installPalette()
        refreshStageControl()
        trackPill.refresh()
    }

    // MARK: - Palette

    /// The palette's engine is Make's (files, symbols, text on the shared `ProjectTextSearch`);
    /// the shell hosts its surface so it opens from any stage, and `chrome` says where.
    private func installPalette() {
        makeVC.loadViewIfNeeded()
        guard let surface = makeVC.paletteSurface else { return }
        let host = NSView()
        host.isHidden = true
        host.translatesAutoresizingMaskIntoConstraints = true
        surface.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(surface)
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: host.topAnchor), surface.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            surface.leadingAnchor.constraint(equalTo: host.leadingAnchor), surface.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ])
        host.wantsLayer = true
        host.shadow = NSShadow()
        host.layer?.shadowOpacity = 0.18
        host.layer?.shadowRadius = 18
        host.layer?.shadowOffset = CGSize(width: 0, height: -4)
        view.addSubview(host, positioned: .above, relativeTo: nil)
        paletteHost = host
        makeVC.onPaletteShow = { [weak self, weak host] size in
            guard let self, let host else { return }
            host.frame = self.chrome.paletteFrame(size: size, in: self.view)
            host.isHidden = false
        }
        makeVC.onPaletteHide = { [weak host] in host?.isHidden = true }
        makeVC.onPaletteNavigated = { [weak self] in self?.show(.make) }
        makeVC.commandsProvider = { [weak self] in self?.paletteCommands() ?? [] }
    }

    /// Every stage — pinned or not — and every Navigate menu item, by name.
    private func paletteCommands() -> [PaletteCommand] {
        var commands = Stage.allCases.map { stage in
            PaletteCommand(title: "Go to \(stage.rawValue)", shortcut: stage == .tracks ? "⌘⌥0" : StagePins.pinnable.firstIndex(of: stage).map { "⌘⌥\($0 + 1)" }) { [weak self] in
                self?.show(stage)
            }
        }
        let navigate = NSApp.mainMenu?.items.first { $0.title == "Navigate" }?.submenu
        for item in navigate?.items ?? [] where !item.isSeparatorItem && item.action != nil && !item.title.hasPrefix("Go to ") {
            commands.append(PaletteCommand(title: item.title, shortcut: nil) { [weak item] in
                guard let item, let action = item.action else { return }
                NSApp.sendAction(action, to: item.target, from: item)
            })
        }
        commands.append(PaletteCommand(title: "New Track…", shortcut: "⇧⌘T") { [weak self] in self?.trackPill.onNewTrack?() })
        commands.append(PaletteCommand(title: "Switch Track…", shortcut: "⌃⌘T") { [weak self] in self?.trackPill.togglePopover() })
        return commands
    }

    @objc func showQuickOpen(_ sender: Any?) { makeVC.presentPalette(.files) }
    @objc func showCommandPalette(_ sender: Any?) { makeVC.presentPalette(.commands) }
    @objc func showFindInProject(_ sender: Any?) { makeVC.presentPalette(.text) }
    @objc func showGoToSymbol(_ sender: Any?) { makeVC.presentPalette(.symbols) }
    @objc func toggleTrackPopover(_ sender: Any?) { trackPill.togglePopover() }
    @objc func selectNextTab(_ sender: Any?) { adjacentTab(1) }
    @objc func selectPreviousTab(_ sender: Any?) { adjacentTab(-1) }

    /// ⌃Tab cycles the tabs in the current stage's top row.
    private func adjacentTab(_ offset: Int) {
        switch current {
        case .make: makeVC.selectAdjacentTab(offset)
        case .run: runVC.selectAdjacentTab(offset)
        default: break
        }
    }

    // MARK: - Pinning

    private func pinsMenu() -> NSMenu {
        let menu = NSMenu(title: "Pinned Stages")
        let pinned = StagePins.pinned
        for stage in StagePins.pinnable {
            let item = NSMenuItem(title: stage.rawValue, action: #selector(togglePinnedStage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = stage.rawValue
            item.state = pinned.contains(stage) ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc func togglePinnedStage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let stage = Stage(rawValue: raw) else { return }
        StagePins.toggle(stage)
    }

    /// Recomputes which stages the control shows and each one's dot.
    private func refreshStageControl() {
        let attention = stagesNeedingAttention()
        // A stage whose attention cleared can come back the next time it has something.
        dismissedAttention.formIntersection(attention)
        lastAttention = attention
        let stages = StagePins.visible(pinned: StagePins.pinned, attention: attention, dismissed: dismissedAttention, current: current)
        if stages != visibleStages || stageControl.segmentAccessibilityLabels.count != stages.count {
            visibleStages = stages
            stageControl.setSegments(stages.map(\.rawValue), symbols: stages.map(Self.stageSymbol), selected: current.flatMap { stages.firstIndex(of: $0) } ?? -1)
        } else if let current, let index = stages.firstIndex(of: current) {
            if index != stageControl.selectedIndex { stageControl.select(index, animated: true) }
        } else {
            stageControl.clearSelection()
        }
        for (index, stage) in stages.enumerated() {
            let badge = stageBadge(stage)
            stageControl.setBadge(badge?.state, spokenState: badge?.spoken, at: index)
        }
    }

    private static func stageSymbol(_ stage: Stage) -> String? {
        switch stage {
        case .make: return "chevron.left.forwardslash.chevron.right"
        case .think: return "bubble.left"
        case .review: return "checkmark.seal"
        case .run: return "terminal"
        case .tracks: return "square.stack"
        }
    }

    /// Unpinned stages with something that needs the user: Review has a review-ready or failed
    /// checkpoint; Run has a command awaiting approval.
    private func stagesNeedingAttention() -> Set<Stage> {
        var result: Set<Stage> = []
        if let badge = stageBadge(.review), badge.state == .needsYou || badge.state == .failed || badge.state == .verified { result.insert(.review) }
        if currentRunner?.hasCommandAwaitingApproval == true { result.insert(.run) }
        return result
    }

    private var currentRunner: AgentRunner? {
        projectContext?.runnerManager.existingRunner(forTrackKey: currentTrackKey ?? "")
    }

    /// A stage's 5 pt dot and what it says: needs-you wins over working.
    private func stageBadge(_ stage: Stage) -> (state: DS.StatusState, spoken: String)? {
        switch stage {
        case .think:
            switch currentRunner?.activity {
            case .needsYou: return (.needsYou, "needs you")
            case .failed: return (.failed, "the run failed")
            case .working: return (.working, "the agent is working")
            default: return nil
            }
        case .run:
            if currentRunner?.hasCommandAwaitingApproval == true { return (.needsYou, "a command is waiting for approval") }
            return runVC.hasBackgroundActivity ? (.working, "a terminal has new output") : nil
        case .review:
            guard let track = trackStore?.tracks.first(where: { $0.branchName == currentTrackKey }) else { return nil }
            let newest = projectContext?.sessionStore.checkpoints(forTrackKey: track.branchName).max { $0.createdAt < $1.createdAt }
            if newest?.verification?.passed == false { return (.failed, "verification failed") }
            if track.status == .reviewReady { return (.verified, "ready for review") }
            return nil
        case .make, .tracks:
            return nil
        }
    }

    // MARK: - Track pill

    private func trackPillSnapshot() -> TrackPill.Snapshot {
        guard let store = trackStore else { return .empty }
        let manager = projectContext?.runnerManager
        func state(_ track: Track) -> DS.StatusState {
            let activity = manager?.existingRunner(forTrackKey: track.branchName)?.activity ?? .none
            return DS.StatusState(track: track.status, activity: activity)
        }
        let currentTrack = store.tracks.first { $0.branchName == currentTrackKey }
        var snapshot = TrackPill.Snapshot(
            title: currentTrack.map { $0.intent.isEmpty ? $0.branchName : $0.intent } ?? "\(gitBranch ?? store.defaultBranchName()) · No track",
            state: currentTrack.map(state) ?? .idle,
            stateName: currentTrack.map { state($0).name } ?? "No track"
        )
        snapshot.projectName = projectURL?.lastPathComponent
        snapshot.branch = gitBranch.map { gitDirtyCount > 0 ? "\($0) · \(gitDirtyCount) changed" : $0 }
        if current == .make, let projectURL, let currentFileURL { snapshot.filePath = humanePath(for: currentFileURL, projectURL: projectURL) }
        for track in store.tracks where track.status != .archived {
            let rowState = state(track)
            let row = TrackPill.Row(key: track.branchName, title: track.intent.isEmpty ? track.branchName : track.intent, detail: track.branchName, state: rowState, isCurrent: track.branchName == currentTrackKey)
            if rowState == .needsYou || rowState == .failed {
                snapshot.needsYou.append(row)
                if !row.isCurrent { snapshot.othersNeedingYou += 1 }
            } else if track.status == .parked || track.status == .completed {
                snapshot.parked.append(row)
            } else {
                snapshot.active.append(row)
            }
        }
        // RFC R1 v1: every other open window's needs-you tracks, so "what needs me" is answerable
        // from any window.
        snapshot.otherProjects = (AppDelegate.shared?.shellViewControllers ?? [])
            .filter { $0 !== self && $0.projectURL != nil && $0.projectContext !== projectContext }
            .flatMap { $0.needsYouRowsForOtherWindows() }
        return snapshot
    }

    /// This window's needs-you tracks, as rows another window's pill can list.
    fileprivate func needsYouRowsForOtherWindows() -> [TrackPill.Row] {
        guard let store = trackStore, let manager = projectContext?.runnerManager, let window = view.window else { return [] }
        return store.tracks.compactMap { track in
            guard let activity = manager.existingRunner(forTrackKey: track.branchName)?.activity, activity.wantsAttention else { return nil }
            var row = TrackPill.Row(key: track.branchName, title: track.intent.isEmpty ? track.branchName : track.intent,
                                    detail: projectURL?.lastPathComponent ?? "", state: activity == .failed ? .failed : .needsYou)
            row.windowNumber = window.windowNumber
            return row
        }
    }

    private func selectTrackRow(_ row: TrackPill.Row) {
        if let number = row.windowNumber {
            guard let other = AppDelegate.shared?.shellViewControllers.first(where: { $0.view.window?.windowNumber == number }) else { return }
            other.view.window?.makeKeyAndOrderFront(nil)
            other.focusTrack(key: row.key)
            return
        }
        focusTrack(key: row.key)
    }

    /// Switches this window to a track without changing stage.
    func focusTrack(key: String) {
        guard key != currentTrackKey, let track = trackStore?.tracks.first(where: { $0.branchName == key }) else { return }
        switchToTrack(track, landOn: current ?? .make, completion: { _ in })
    }

    // MARK: - Stage switching

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
        // Visiting an unpinned stage that showed itself for attention is what dismisses it.
        if lastAttention.contains(stage) { dismissedAttention.insert(stage) }
        refreshStageControl()

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

        chrome.setStageContent((next as? StageChromeProviding)?.topRowContent)
        (next as? StageChromeProviding)?.setBottomObstruction(chrome.bottomObstruction)
        if stage == .run {
            runVC.activateActiveSession()
        }
        applyWindowChrome()
    }

    private func updateStageLabels() {
        refreshStageControl()
        trackPill.refresh()
    }

    // MARK: - Agent activity (dock badge, notifications)

    private func needsYouTrackIDs() -> Set<UUID> {
        guard let trackStore, let runnerManager = projectContext?.runnerManager else { return [] }
        return Set(trackStore.tracks.filter { runnerManager.existingRunner(forTrackKey: $0.branchName)?.activity.wantsAttention == true }.map(\.id))
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
        // The live-region equivalent: a VoiceOver user working in Make got no audible signal when
        // a track flipped to needs-you — the state rode entirely in a glyph on a segment they
        // weren't focused on. Announced once per transition, alongside the badge and the
        // notification, so every "reach the user" channel fires from the same predicate.
        if let window = view.window {
            let names = tracks.map { $0.intent.isEmpty ? $0.branchName : $0.intent }
            let announcement = names.count == 1
                ? "\(names[0]) needs your attention"
                : "\(names.count) tracks need your attention"
            NSAccessibility.post(
                element: window, notification: .announcementRequested,
                userInfo: [.announcement: announcement, .priority: NSAccessibilityPriorityLevel.high.rawValue]
            )
        }
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

    // MARK: - Window chrome (title, git info)

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
        LaunchSignposts.begin("acquireContext")
        let context = ProjectContextRegistry.shared.acquire(projectRoot: url)
        LaunchSignposts.end("acquireContext")
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
            runVC.reloadForTrackSwitch(trackKey: currentTrackKey)
        }
        runVC.attach(to: context.terminals)
        thinkVC.onRevealFileRequested = { [weak self] url in self?.revealFile(url) }
        thinkVC.onOpenReviewRequested = { [weak self] in self?.show(.review) }
        LaunchSignposts.begin("thinkConfigure")
        thinkVC.configure(runnerManager: context.runnerManager, trackStore: context.trackStore, projectPath: context.projectRoot.path, trackKey: currentTrackKey)
        LaunchSignposts.end("thinkConfigure")
        LaunchSignposts.begin("reviewConfigure")
        reviewVC.configure(trackStore: store, sessionStore: context.sessionStore, canonicalRoot: url)
        reviewVC.reloadForTrackSwitch(trackKey: currentTrackKey, workingDirectory: workingDirectory)
        LaunchSignposts.end("reviewConfigure")
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
                    self.runVC.reloadForTrackSwitch(trackKey: track.branchName)
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
        runVC.reloadForTrackSwitch(trackKey: branchName)
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

    /// Direction 02 §3.7: Make `file — track`, other stages `track`; never a path. Drawn nowhere,
    /// but Mission Control, the Window menu, ⌘` and VoiceOver read it.
    static func windowTitle(stage: Stage?, fileName: String?, track: String?, project: String?) -> String {
        let place = track ?? project ?? "Side"
        if stage == .make, let fileName { return "\(fileName) — \(place)" }
        return place
    }

    private func applyWindowChrome() {
        trackPill.refresh()
        guard let window = view.window else { return }
        window.representedURL = currentFileURL
        window.isDocumentEdited = isDirty
        let track = trackStore?.tracks.first { $0.branchName == currentTrackKey }
        window.title = Self.windowTitle(stage: current, fileName: currentFileURL?.lastPathComponent,
                                        track: track.map { $0.intent.isEmpty ? $0.branchName : $0.intent }, project: projectURL?.lastPathComponent)
    }

    /// A project-relative path for the pill's header, never an absolute one. The old naive
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
            // detached HEAD does). `nil` here just means detached, which the pill omits
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
        process.standardError = FileHandle.nullDevice
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
}
