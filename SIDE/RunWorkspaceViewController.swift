import AppKit
import SideSessionsKit
import SideAgents

final class RunWorkspaceViewController: NSViewController {
    /// The project's terminals (RFC R2). Run is a view onto them: it attaches to a track's
    /// sessions and shows one, but never owns a PTY — closing the window leaves a running
    /// command running for as long as the project is open anywhere. Nil means no project.
    private var terminals: TerminalSessionManager?
    private var terminalsObserver: NSObjectProtocol?
    var currentTrackKey: String?
    private var trackKey: String { currentTrackKey ?? "" }

    /// Set in a window a terminal was torn out into: this view shows only the terminals it
    /// holds, and hands them back to the track when the window closes.
    private var holder: UUID?

    private var sessions: [TerminalSession] {
        get { terminals?.sessions(forTrackKey: trackKey, holder: holder) ?? [] }
        set { terminals?.setSessions(newValue, forTrackKey: trackKey, holder: holder, origin: self) }
    }
    private var activeSessionIndex: Int? {
        get { terminals?.activeIndex(forTrackKey: trackKey, holder: holder) }
        set { terminals?.setActiveIndex(newValue, forTrackKey: trackKey, holder: holder) }
    }
    private let tabBar = TabStripView()
    private let tabBarStack = NSStackView()
    private let terminalBottomInset: CGFloat = 12
    /// What the floating bar covers at the bottom. The terminal's grid ends above it: a grid
    /// has no scrolling-under — its last rows are where you type, so anything the bar covered
    /// was the prompt itself (owner, 2026-09-23). The sheet's own tone still runs to the edge
    /// under the bar, so the window keeps its full-bleed look without a footer seam.
    private var bottomObstruction: CGFloat = 0
    /// The grid starts under the task/status row when it shows.
    private var terminalTopConstant: CGFloat { ChromeHost.rowHeight + 4 + (statusRowShows ? Self.taskRowHeight + 4 : 0) }
    private var statusRowShows: Bool { hasProject && displayedSession != nil }
    private var terminalBottomConstant: CGFloat { -(bottomObstruction > 0 ? bottomObstruction + DS.Spacing.s : terminalBottomInset) }
    private let container = NSView()

    var onActivityChanged: (() -> Void)?
    var onOpenFileRequested: ((URL, Int?) -> Void)?
    /// A task chip was clicked: the shell proposes it through the track's runner.
    var onRunTask: ((ProjectTask) -> Void)?
    /// The confirm strip's Run (true) or Cancel (false) for a proposed task.
    var onResolvePendingTask: ((Bool) -> Void)?
    /// A command the user typed finished: (command, exit code, the screen's last lines). The
    /// shell decides whether to offer it as the newest checkpoint's verification (§5.2).
    var onUserCommandFinished: ((String, Int, String) -> Void)?
    /// The attach offer's Attach (true) or Dismiss (false).
    var onResolveAttachOffer: ((Bool) -> Void)?

    /// What the task row shows (§4.3) — computed by the shell, which owns the runner and the
    /// project's task list; this view only draws it.
    struct TaskRowState: Equatable {
        var tasks: [ProjectTask] = []
        /// Offered when a verification task exists and the newest checkpoint is unverified.
        var verifyTask: ProjectTask?
        var runningTaskName: String?
        /// A proposed task waiting for Run / Cancel (Manual autonomy, or off the allowlist).
        var pendingCommand: String?
        /// A typed command's result the user can attach to the newest, unverified checkpoint.
        var attachOffer: AttachOffer?
    }
    struct AttachOffer: Equatable {
        var command: String
        var exitCode: Int
    }
    private var taskRowState = TaskRowState()
    private let taskRow = NSStackView()
    /// `cwd · last exit N · duration · running <task> in tab N` (§4.3), trailing the task row.
    private let statusLine = NSTextField(labelWithString: "")
    private static let taskRowHeight: CGFloat = 26
    /// A tab dragged out of the window: the shell opens a window that adopts the session.
    var onTearOutRequested: ((TerminalSession, NSPoint) -> Void)?
    /// The tab's Show Beside Editor: the shell makes it the window's companion.
    var onShowBesideRequested: ((TerminalSession) -> Void)?
    /// The tab's Open in Agent: its Claude Code chat, by session id
    /// (SIDE_RFC_SHARED_CLAUDE_SESSIONS.md).
    var onOpenInAgentRequested: ((String) -> Void)?

    /// A new tab on this track that runs `command` once its shell is ready, shown.
    func openSession(command: String) {
        guard hasProject else { return }
        loadViewIfNeeded()
        createSession()
        guard let index = activeSessionIndex, sessions.indices.contains(index) else { return }
        sessions[index].viewController.runWhenReady(command)
        sessions[index].viewController.activate()
    }

    /// The session the companion takes when none is named (View › Show Terminal Beside): the
    /// tab Terminal shows, its remembered tabs restored first as a visit to Terminal would.
    func sessionForCompanion() -> TerminalSession? {
        guard hasProject else { return nil }
        loadViewIfNeeded()
        if activeSessionIndex.map({ !sessions.indices.contains($0) }) ?? true { restoreRememberedSessionsOrCreateOne() }
        guard let index = activeSessionIndex, sessions.indices.contains(index) else { return nil }
        return sessions[index]
    }

    /// Across every track, not just the current one — a track running in the background with
    /// unseen output should still light up the stage badge even while you're looking elsewhere.
    var hasBackgroundActivity: Bool { terminals?.hasUnseenOutput ?? false }

    /// Points this view at a project's terminals. Run — reachable via ⌃4 at any time — can't
    /// spawn a shell before this, so nothing starts in the user's home directory by accident.
    func attach(to manager: TerminalSessionManager) {
        guard manager !== terminals else { return }
        detachDisplayedSession()
        terminals = manager
        if let terminalsObserver { NotificationCenter.default.removeObserver(terminalsObserver) }
        terminalsObserver = NotificationCenter.default.addObserver(forName: TerminalSessionManager.didChangeNotification, object: manager, queue: .main) { [weak self] note in
            let origin = note.userInfo?[TerminalSessionManager.originKey] as? ObjectIdentifier
            MainActor.assumeIsolated { self?.terminalsChanged(origin: origin) }
        }
        guard isViewLoaded else { return }
        rebuildTabBar()
        clearContainer()
        // A project opened while Run is on screen: show (or start) its terminal now. Only a
        // visit to Run did that before, so the new project's Run stayed blank until then.
        if view.window != nil, !view.isHiddenOrHasHiddenAncestor { activateActiveSession() }
    }

    /// Something changed that this view didn't cause: an agent opened a session, a shell exited,
    /// output arrived in the background, another window took the terminal this one was showing.
    private func terminalsChanged(origin: ObjectIdentifier?) {
        onActivityChanged?()
        updateStatusLine()
        reportUserCommandIfFinished()
        guard isViewLoaded, origin != ObjectIdentifier(self) else { return }
        rebuildTabBar()
        if let displayed = displayedSession, !sessions.contains(where: { $0 === displayed }) {
            // Discarded under us (the track was deleted, the project torn down), or torn out
            // into its own window — then the neighbour takes its place, as on a close.
            clearContainer()
            if let index = activeSessionIndex, sessions.indices.contains(index), view.window != nil { showActiveSession() }
        } else if let displayed = displayedSession, displayed.viewController.parent !== self {
            clearContainer()
            showPlaceholder("This terminal is showing in another window. Select its tab to bring it here.")
        } else if displayedSession == nil, let index = activeSessionIndex, sessions.indices.contains(index), view.window != nil, container.subviews.isEmpty,
                  terminals?.isDisplayed(sessions[index], elsewhereThan: self) != true {
            // Never taken from another window on a change notice: only selecting the tab does that.
            showActiveSession()
        }
    }

    /// The session this view has in its container, if any.
    private var displayedSession: TerminalSession? { didSet { if displayedSession !== oldValue { checkForDuplicateConversation() } } }

    // MARK: One conversation, two tabs

    /// The tab on screen holds a Claude Code conversation another of Side's terminals holds too
    /// (`ClaudeConversations`): said in the task row, with the way to the other or to end it.
    private var duplicate: ClaudeConversations.Duplicate?
    private var dismissedDuplicates: Set<String> = []
    private var duplicateTimer: Timer?

    override func viewDidAppear() {
        super.viewDidAppear()
        duplicateTimer?.invalidate()
        // Every few seconds, only while Run shows: a resume picks its conversation after it starts.
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.checkForDuplicateConversation() } }
        RunLoop.main.add(timer, forMode: .common)
        duplicateTimer = timer
        checkForDuplicateConversation()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        duplicateTimer?.invalidate()
        duplicateTimer = nil
    }

    func checkForDuplicateConversation() {
        var found: ClaudeConversations.Duplicate?
        if SessionKeepers.isEnabled, let id = displayedSession?.viewController.keeperID {
            found = ClaudeConversations.duplicate(ofKeeper: id)
            if let candidate = found, dismissedDuplicates.contains(candidate.conversation + candidate.otherKeeperID) { found = nil }
        }
        guard found != duplicate else { return }
        duplicate = found
        renderTaskRow()
    }

    /// Where the other copy is: a tab's name, or nil when no tab shows it.
    private func tabShowing(keeperID: String) -> TerminalSession? {
        ProjectContextRegistry.shared.everyTerminalSession.first { $0.viewController.keeperID == keeperID }
    }

    @objc private func goToDuplicate() {
        guard let duplicate else { return }
        AppDelegate.shared?.revealTerminal(keeperID: duplicate.otherKeeperID)
    }

    @objc private func endDuplicate() {
        guard let duplicate else { return }
        SessionKeepers.endSession(duplicate.otherKeeperID)
        self.duplicate = nil
        renderTaskRow()
    }

    @objc private func dismissDuplicate() {
        guard let duplicate else { return }
        dismissedDuplicates.insert(duplicate.conversation + duplicate.otherKeeperID)
        self.duplicate = nil
        renderTaskRow()
    }
    func endDuplicateForTesting() { endDuplicate() }
    var duplicateNoticeForTesting: String? { duplicate.map { tabShowing(keeperID: $0.otherKeeperID) == nil ? "background \($0.otherKeeperID)" : "tab \($0.otherKeeperID)" } }

    /// A task chip: the task's command typed into the terminal on screen and run, as if typed
    /// there; its exit then gets Run's usual offer to record it on the checkpoint. Refused while a
    /// program holds the terminal: two commands in one shell would corrupt both.
    func runTask(_ command: String) -> Bool {
        guard let controller = displayedSession?.viewController, controller.runningProgramName == nil else { return false }
        controller.terminalView.send(txt: command + "\r")
        return true
    }

    /// UI testing: the terminal on screen's background, "r g b" in 0–255.
    var terminalBackgroundForTesting: String {
        guard let color = displayedSession?.viewController.terminalView.nativeBackgroundColor.usingColorSpace(.sRGB) else { return "-" }
        let rgb = [color.redComponent, color.greenComponent, color.blueComponent].map { String(Int(($0 * 255).rounded())) }.joined(separator: " ")
        return rgb + " reports=\(displayedSession?.viewController.terminalView.reportsColorSchemeForTesting == true)"
    }

    /// UI testing: characters typed into the terminal on screen, one per `interval`.
    func typeForTesting(_ text: String, interval: TimeInterval = 0.1) {
        guard let terminal = displayedSession?.viewController.terminalView else { return }
        for (index, character) in text.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + interval * Double(index)) {
                terminal.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
            }
        }
    }

    override func loadView() { view = NSView() }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildView()
        // The shell may have set the task row before Run was ever shown.
        setTaskRow(taskRowState)
    }

    private func buildView() {
        view.wantsLayer = true
        ChromeBackground.install(in: view)

        tabBar.wantsLayer = true
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        // Not clipped: the glass track's shadow extends past the strip, and clipping it drew a
        // faint rectangle under the capsule. The tabs clip inside their own scroll view.
        tabBar.clipsToBounds = false
        // Transparent: the top row takes the terminal's tone, so tabs sit on the same sheet.
        tabBarStack.orientation = .horizontal
        tabBarStack.alignment = .centerY
        tabBarStack.spacing = DS.Spacing.xxs
        tabBarStack.translatesAutoresizingMaskIntoConstraints = false
        tabBar.addSubview(tabBarStack)

        let divider = NSBox()
        divider.boxType = .custom
        divider.borderType = .noBorder
        divider.fillColor = DS.Color.hairlineStrong
        divider.translatesAutoresizingMaskIntoConstraints = false
        // Behind the chips, so the active tab's fill covers it and attaches to the content.
        divider.isHidden = true
        tabBar.addSubview(divider, positioned: .below, relativeTo: tabBarStack)

        // Same scrolling strip as Make — the strip scrolls, the window never widens.
        let tabScroll = TabStripScrollView()
        tabScroll.drawsBackground = false
        tabScroll.hasHorizontalScroller = false
        tabScroll.hasVerticalScroller = false
        tabScroll.verticalScrollElasticity = .none
        tabScroll.horizontalScrollElasticity = .allowed
        tabScroll.automaticallyAdjustsContentInsets = false
        tabScroll.translatesAutoresizingMaskIntoConstraints = false
        tabBarStack.removeFromSuperview()
        tabScroll.documentView = tabBarStack
        tabBar.addSubview(tabScroll)
        tabBar.installGlassTrack(behind: tabScroll, hugging: tabBarStack)

        // The tab strip is hosted in the window's top row (Direction 02 §3.2) — `topRowContent`.
        // The terminal sheet: edge-to-edge on the sides and bottom, but with rounded top
        // corners and a breath of space under the tab strip — the terminal reads as a surface
        // sliding up under the tabs, not a floating card and not a flush slab touching chrome.
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        // Full bleed: the terminal is the whole window — edge to edge, under the top row's tone
        // and under the floating bar. Only the text keeps clear of the bar (terminalBottom).
        container.bindLayerBackground(DS.Color.raised)
        container.clipsToBounds = true
        view.addSubview(container)

        taskRow.orientation = .horizontal
        taskRow.alignment = .centerY
        taskRow.spacing = DS.Spacing.s
        taskRow.translatesAutoresizingMaskIntoConstraints = false
        taskRow.isHidden = true
        taskRow.setAccessibilityElement(true)
        taskRow.setAccessibilityRole(.group)
        taskRow.setAccessibilityLabel("Tasks")
        view.addSubview(taskRow)
        // One line; a long path gives way from its start so the exit and duration stay readable.
        statusLine.usesSingleLineMode = true
        statusLine.maximumNumberOfLines = 1
        statusLine.cell?.lineBreakMode = .byTruncatingHead
        statusLine.alignment = .right
        statusLine.translatesAutoresizingMaskIntoConstraints = false
        statusLine.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.addSubview(statusLine)

        view.wantsLayer = true
        view.bindLayerBackground(DS.Color.raised)
        NSLayoutConstraint.activate([
            tabScroll.leadingAnchor.constraint(equalTo: tabBar.leadingAnchor), tabScroll.trailingAnchor.constraint(equalTo: tabBar.trailingAnchor), tabScroll.topAnchor.constraint(equalTo: tabBar.topAnchor), tabScroll.bottomAnchor.constraint(equalTo: tabBar.bottomAnchor),
            tabBarStack.leadingAnchor.constraint(equalTo: tabScroll.contentView.leadingAnchor), tabBarStack.topAnchor.constraint(equalTo: tabScroll.contentView.topAnchor), tabBarStack.heightAnchor.constraint(equalTo: tabScroll.heightAnchor),
            divider.leadingAnchor.constraint(equalTo: tabBar.leadingAnchor), divider.trailingAnchor.constraint(equalTo: tabBar.trailingAnchor), divider.bottomAnchor.constraint(equalTo: tabBar.bottomAnchor), divider.heightAnchor.constraint(equalToConstant: 1),
            // Attached to the tab row above it: the active tab and the terminal are one surface.
            container.topAnchor.constraint(equalTo: view.topAnchor), container.leadingAnchor.constraint(equalTo: view.leadingAnchor), container.trailingAnchor.constraint(equalTo: view.trailingAnchor), container.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            taskRow.topAnchor.constraint(equalTo: view.topAnchor, constant: ChromeHost.rowHeight + 2),
            taskRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            taskRow.heightAnchor.constraint(equalToConstant: Self.taskRowHeight),
            statusLine.centerYAnchor.constraint(equalTo: taskRow.centerYAnchor),
            statusLine.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            statusLine.leadingAnchor.constraint(greaterThanOrEqualTo: taskRow.trailingAnchor, constant: DS.Spacing.xl),
        ])
    }

    /// Called every time the Run stage becomes visible — starts the first session lazily
    /// (mirrors the old single-terminal activate() behavior) or reattaches the active one.
    /// Always goes through `showActiveSession()` (not just `.activate()`) because the active
    /// track can have changed since Run was last shown, in which case `container` is still
    /// displaying a different track's terminal view.
    /// Set true by the shell once a project is open. Defaults to false so that Run — reachable
    /// via ⌃4 at any time — can't spawn a shell in the user's home directory before then.
    var hasProject: Bool { terminals != nil }

    func activateActiveSession() {
        guard hasProject else {
            clearContainer()
            showNoProjectState()
            return
        }
        guard let index = activeSessionIndex, sessions.indices.contains(index) else {
            restoreRememberedSessionsOrCreateOne()
            return
        }
        showActiveSession()
        clearUnseenOutput(at: index)
    }

    /// Switches which track's terminal sessions are current. Doesn't eagerly spawn a shell for
    /// the new track — if the user never opens Run for it, there's no reason to have started one
    /// — `activateActiveSession()` (already called whenever Run becomes visible) creates one
    /// lazily on first visit, same as it always has. Guarded on `isViewLoaded` (not just checking
    /// `view` directly, which would force a load) since this can be called — e.g. right after
    /// creating a track — before the user has ever visited Run for this project at all.
    func reloadForTrackSwitch(trackKey: String?) {
        currentTrackKey = trackKey
        guard isViewLoaded else { return }
        rebuildTabBar()
        if let index = activeSessionIndex, sessions.indices.contains(index) {
            showActiveSession()
        } else if view.window != nil, !view.isHiddenOrHasHiddenAncestor {
            // On screen: the track's terminals now, as a visit would. Switching tracks with
            // Terminal in front left it blank, with no tab, until another stage and back (found
            // on screen, 2026-11-07).
            clearContainer()
            activateActiveSession()
        } else {
            // No session for this track yet — don't eagerly create one (that's still
            // activateActiveSession()'s job for whenever the user actually visits Run), but don't
            // leave the previous track's terminal content sitting on screen either.
            clearContainer()
        }
    }

    /// Set by the shell, which performs empty-state actions (§6).
    var onEmptyStateAction: ((EmptyStateAction) -> Void)?

    private func showNoProjectState() {
        let state = DS.EmptyState()
        state.symbol = ShellViewController.Stage.run.symbol
        state.configure("Open a project to run its terminals.", action: "Open Project…", handler: { [weak self] in self?.onEmptyStateAction?(.openProject) })
        container.addSubview(state)
        NSLayoutConstraint.activate([
            state.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            state.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            state.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
    }

    private func showPlaceholder(_ text: String) {
        let label = NSTextField(labelWithString: text)
        label.font = DS.Text.body()
        label.textColor = .tertiaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
    }

    private func clearContainer() {
        detachDisplayedSession()
        // Placeholders are plain subviews, not children — they used to survive into the next
        // session and sit underneath its terminal.
        container.subviews.forEach { $0.removeFromSuperview() }
    }

    /// Lets go of the terminals without ending them — only their views leave this window.
    private func detachDisplayedSession() {
        for key in Array(mounted.keys) { unmount(key) }
        displayedSession = nil
        terminals?.markDisplayed(nil, by: self)
    }

    /// The terminals this view has shown, kept in the container with the inactive ones hidden:
    /// a view taken out of the window loses what it drew, and every tab switch showed a blank
    /// terminal until it drew again (the owner, 2026-10-29).
    private var mounted: [ObjectIdentifier: (session: TerminalSession, top: NSLayoutConstraint, bottom: NSLayoutConstraint)] = [:]

    private func unmount(_ key: ObjectIdentifier) {
        guard let entry = mounted.removeValue(forKey: key) else { return }
        let vc = entry.session.viewController
        if vc.parent === self {
            vc.view.removeFromSuperview()
            vc.removeFromParent()
        }
    }

    @objc func newSession() {
        guard !Shortcuts.isKeyRepeat else { return }
        createSession()
        sessions[activeSessionIndex ?? 0].viewController.activate()
    }

    func closeActiveTabForTesting() { closeActiveTab() }
    var tabStripForTesting: TabStrip { tabStrip }
    var sessionTitlesForTesting: [String] { sessions.map(\.title) }

    @objc private func closeActiveTab() {
        guard !Shortcuts.isKeyRepeat, let index = activeSessionIndex else { return }
        requestClose(at: index)
    }

    /// Closing a tab ends what runs in it, so with something running it asks first (Settings →
    /// General → Run, or "Don't ask again", turn that off).
    private func requestClose(at index: Int) {
        guard sessions.indices.contains(index) else { return }
        let session = sessions[index]
        guard SessionKeepers.confirmsClosingRunning, let program = session.viewController.runningProgramName, let window = view.window else {
            return closeSession(at: index)
        }
        confirmClosing(message: "Close this terminal?", detail: "\(ProgramMarks.displayName(program)) is still running in it. Closing the tab ends it.", in: window) { [weak self] in
            guard let self, let current = self.sessions.firstIndex(where: { $0 === session }) else { return }
            self.closeSession(at: current)
        }
    }

    private func confirmClosing(message: String, detail: String, in window: NSWindow, then close: @escaping () -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don\u{2019}t ask again"
        alert.beginSheetModal(for: window) { response in
            if alert.suppressionButton?.state == .on { SessionKeepers.confirmsClosingRunning = false }
            if response == .alertFirstButtonReturn { close() }
        }
    }

    @objc func stopActiveSession() {
        guard let index = activeSessionIndex, sessions.indices.contains(index) else { return }
        sessions[index].viewController.stopProcess()
    }

    @objc func restartActiveSession() {
        guard let index = activeSessionIndex, sessions.indices.contains(index) else { return }
        sessions[index].viewController.prepareForClose()
        createSession(replacing: index)
        sessions[index].viewController.activate()
    }

    @objc func rerunLastCommand() {
        guard let index = activeSessionIndex, sessions.indices.contains(index),
              let command = sessions[index].viewController.lastSubmittedCommand else { return }
        let vc = sessions[index].viewController
        vc.activate()
        vc.terminalView.send(source: vc.terminalView, data: ArraySlice(Array((command + "\r").utf8)))
    }

    /// The window is closing. Terminals belong to the project, so they keep running — this
    /// window only gives its view back.
    func prepareForClose() {
        detachDisplayedSession()
        if let holder { terminals?.release(holder: holder) }
        if let terminalsObserver { NotificationCenter.default.removeObserver(terminalsObserver) }
        terminalsObserver = nil
    }

    // MARK: - Session lifecycle

    /// Re-creates the tab *shape* a track was left in — how many terminals, and each one's
    /// working directory — or one fresh terminal if there is nothing remembered.
    ///
    /// Deliberately "shape", not "state". A terminal is a live PTY with a shell and whatever it
    /// was running; those die with the process and cannot be restored, so promising to restore
    /// a session would be a lie. What *is* restorable is the arrangement, which is what was
    /// actually lost: reopening a project dropped every Run tab because nothing recorded that
    /// they had existed at all.
    ///
    /// With session keepers (SIDE_RFC_SESSION_RESTORE.md) the state comes back too: a remembered
    /// tab whose keeper still runs reattaches to its shell, and a live session the list doesn't
    /// know about (Side ended before it could remember) comes back as a tab of its own.
    private func restoreRememberedSessionsOrCreateOne() {
        let remembered = terminals?.rememberedDirectories(forTrackKey: trackKey) ?? []
        let keeperIDs = terminals?.rememberedKeeperIDs(forTrackKey: trackKey) ?? []
        let project = terminals?.projectRoot.path ?? ""
        let live = SessionKeepers.isEnabled ? SessionKeepers.liveRecords(project: project, track: trackKey) : []
        let liveIDs = Set(live.map(\.id))
        // Sessions whose keeper is gone without the session ending: a restart, or a crash.
        let ended = SessionKeepers.isEnabled ? SessionKeepers.endedRecords(project: project, track: trackKey) : []
        let endedByID = Dictionary(ended.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // A remembered tab whose shell another view already holds (the companion, a torn-out
        // window) isn't reattached here: a second tab on one keeper took it from the first.
        let attached = Set(terminals?.everySession().compactMap { $0.viewController.keeperID } ?? [])
        let orphans = (live + ended).filter { record in !keeperIDs.contains { $0 == record.id } && !attached.contains(record.id) }
        let restorable = remembered.indices.filter { index in !(keeperIDs.indices.contains(index) && keeperIDs[index].map(attached.contains) == true) }
        guard !restorable.isEmpty || !orphans.isEmpty else { return createSession() }
        // Created, not started: a shell starts when its tab is first shown. Starting all of them
        // here made every background tab's first prompt count as unseen output, so reopening a
        // project with three remembered tabs lit Run's badge for nothing. A live session is the
        // exception: it's already running, so it reattaches now and keeps its tab current.
        let names = terminals?.rememberedNames(forTrackKey: trackKey) ?? []
        for (index, directory) in remembered.enumerated() where restorable.contains(index) {
            let id = keeperIDs.indices.contains(index) ? keeperIDs[index] : nil
            let recovering = id.flatMap { endedByID[$0] }
            createSession(inDirectory: recovering.map(Self.recoveryDirectory) ?? directory, keeperID: id, show: false)
            if names.indices.contains(index) { sessions.last?.customName = names[index] }
            if let recovering { prepareRecovery(recovering) }
            if let id, liveIDs.contains(id) { sessions.last?.viewController.loadViewIfNeeded(); sessions.last?.viewController.start() }
        }
        for record in orphans {
            let isLive = liveIDs.contains(record.id)
            createSession(inDirectory: isLive ? record.directory : Self.recoveryDirectory(record), keeperID: record.id, show: false)
            if isLive {
                sessions.last?.viewController.loadViewIfNeeded()
                sessions.last?.viewController.start()
            } else {
                prepareRecovery(record)
            }
        }
        activeSessionIndex = 0
        rebuildTabBar()
        showActiveSession()
    }

    /// Where a recovered shell starts: the directory it last reported, if it's still there.
    private static func recoveryDirectory(_ record: SessionRecord) -> String {
        var isDirectory: ObjCBool = false
        if !record.pwd.isEmpty, FileManager.default.fileExists(atPath: record.pwd, isDirectory: &isDirectory), isDirectory.boolValue { return record.pwd }
        return record.directory
    }

    /// The tab just created recovers `record` when it starts (on first show, as any tab does):
    /// the old screen, Claude resumed or the program run again or offered, its last name.
    private func prepareRecovery(_ record: SessionRecord) {
        guard let session = sessions.last else { return }
        session.viewController.recovering = record
        session.restoredTitle = TerminalViewController.cleanProgramTitle(record.title)
    }

    private func createSession(replacing index: Int? = nil, inDirectory directory: String? = nil, keeperID: String? = nil, show: Bool = true) {
        guard let terminals else { return }
        // A restored tab reopens where it was, not wherever the track currently points.
        let session = terminals.makeSession(forTrackKey: trackKey, inDirectory: directory, keeperID: keeperID)
        if let index, sessions.indices.contains(index) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }
        activeSessionIndex = index ?? (sessions.count - 1)
        guard show else { return }
        rebuildTabBar()
        showActiveSession()
    }

    private func closeSession(at index: Int) {
        guard sessions.indices.contains(index) else { return }
        let after = TabSelection.indexAfterClosing(index, active: activeSessionIndex, countBefore: sessions.count)
        let wasActive = activeSessionIndex == index
        // The strip and the list change together, now: the strip animates the chip out on its
        // own. Waiting for its animation to drop the session let a second close, made meanwhile,
        // remove the wrong one (2026-11-04).
        tabStrip.animateClose(at: index, activeAfter: after)
        sessions[index].viewController.prepareForClose()
        sessions.remove(at: index)
        // The closed tab may have been the last one holding unseen output — without this
        // the stage's ● outlived every tab that caused it.
        onActivityChanged?()
        if sessions.isEmpty {
            // Run always has at least one session — no empty state to design for.
            createSession()
            return
        }
        activeSessionIndex = after
        rebuildTabBar()
        if wasActive { showActiveSession() }
    }

    /// This window was opened for a terminal torn out of another: take it, still running.
    func adoptTornOutSession(_ session: TerminalSession, trackKey: String) {
        guard let terminals else { return }
        let holder = UUID()
        self.holder = holder
        terminals.hold(session, forTrackKey: trackKey, holder: holder, origin: self)
    }

    private func tearOutSession(at index: Int, to screenPoint: NSPoint) {
        guard sessions.indices.contains(index) else { return }
        onTearOutRequested?(sessions[index], screenPoint)
    }

    /// Shows the tab whose shell lives in keeper `id`, if this view has it. For a notification's
    /// side://run link.
    var displayedSessionID: UUID? { displayedSession?.id }

    /// Shows the tab for a session by its own id (the activity pill's rows).
    @discardableResult
    func showSession(id: UUID) -> Bool {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return false }
        if index != activeSessionIndex { switchToSession(index) }
        sessions[index].viewController.activate()
        return true
    }

    func listsSession(keeperID id: String) -> Bool { sessions.contains { $0.viewController.keeperID == id } }

    @discardableResult
    func showSession(keeperID id: String) -> Bool {
        guard let index = sessions.firstIndex(where: { $0.viewController.keeperID == id }) else { return false }
        if index != activeSessionIndex { switchToSession(index) }
        sessions[index].viewController.activate()
        return true
    }

    private func switchToSession(_ index: Int) {
        guard sessions.indices.contains(index), index != activeSessionIndex else { return }
        activeSessionIndex = index
        rebuildTabBar()
        showActiveSession()
        clearUnseenOutput(at: index)
    }

    private func showActiveSession() {
        guard let index = activeSessionIndex, sessions.indices.contains(index) else { return }
        let session = sessions[index]
        let vc = session.viewController
        // Terminals of closed tabs, or taken by another window, are let go; placeholders go.
        for (key, entry) in mounted where !sessions.contains(where: { $0 === entry.session }) || entry.session.viewController.parent !== self {
            unmount(key)
        }
        let kept = Set(mounted.values.map { ObjectIdentifier($0.session.viewController.view) })
        for subview in container.subviews where !kept.contains(ObjectIdentifier(subview)) { subview.removeFromSuperview() }
        // Taken from another window if it was showing there; that window shows a placeholder.
        if vc.parent != nil, vc.parent !== self { vc.view.removeFromSuperview(); vc.removeFromParent() }
        vc.onFileLinkRequested = { [weak self] link in self?.handleFileLink(link) ?? false }
        vc.onRerunOfferChanged = { [weak self, weak session] in
            guard let self, self.displayedSession === session else { return }
            self.renderTaskRow()
        }
        displayedSession = session
        let key = ObjectIdentifier(vc)
        if mounted[key] == nil {
            addChild(vc)
            vc.view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(vc.view)
            let bottom = vc.view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: terminalBottomConstant)
            let top = vc.view.topAnchor.constraint(equalTo: container.topAnchor, constant: terminalTopConstant)
            NSLayoutConstraint.activate([
                top, vc.view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
                vc.view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16), bottom
            ])
            mounted[key] = (session, top, bottom)
        }
        // Said only once the terminal is this view's child: the post reaches other windows on
        // this project synchronously, and one that saw it half-moved (no parent yet) let go of
        // it, which made this one let go too, and the two traded it until the stack ran out.
        terminals?.markDisplayed(session, by: self)
        for (other, entry) in mounted { entry.session.viewController.view.isHidden = other != key }
        vc.activate()
        renderTaskRow()
        reportUserCommandIfFinished()
    }

    /// Reads the shown session's live cwd (OSC 7) and last command (OSC 133). A cwd outside the
    /// track's worktree is flagged, and agent commands there always ask (audit D-10).
    private func updateStatusLine() {
        guard isViewLoaded else { return }
        for entry in mounted.values { entry.top.constant = terminalTopConstant }
        guard statusRowShows, let session = displayedSession, let terminals else { statusLine.stringValue = ""; return }
        let vc = session.viewController
        let worktree = terminals.workingDirectory(forTrackKey: trackKey).path
        let cwd = vc.currentDirectory ?? vc.workingDirectory ?? worktree
        let outside = !TerminalSessionManager.isInside(cwd, root: worktree)
        let base: [NSAttributedString.Key: Any] = [.font: DS.Text.code(11, weight: .regular), .foregroundColor: NSColor.tertiaryLabelColor]
        // Only what's worth reading (the audit: it was a debug readout). The folder only when the
        // shell has left the project's root, relative to it while inside; the last command only
        // when it failed or took a while.
        let text = NSMutableAttributedString(string: Self.statusPath(cwd, root: worktree),
                                             attributes: base.merging([.foregroundColor: outside ? DS.Color.statusNeedsYou : NSColor.secondaryLabelColor]) { $1 })
        var parts: [String] = []
        let status = vc.commandStatus
        if let code = status.lastExitCode, code != 0 { parts.append("exit \(code)") }
        if let duration = status.lastDuration, duration >= 10 || status.lastExitCode.map({ $0 != 0 }) == true { parts.append(Self.durationText(duration)) }
        if let task = taskRowState.runningTaskName {
            let agentTab = terminals.agentSessionIndex(forTrackKey: trackKey)
            parts.append(agentTab.map { $0 != activeSessionIndex && sessions.count > 1 ? "running \(task) in tab \($0 + 1)" : "running \(task)" } ?? "running \(task)")
        }
        for part in parts { text.append(NSAttributedString(string: (text.length == 0 ? "" : " \u{00B7} ") + part, attributes: base)) }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingHead
        paragraph.alignment = .right
        text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
        statusLine.attributedStringValue = text
        statusLine.toolTip = outside ? "Outside this track's worktree \u{2014} agent commands in this terminal always ask first." : cwd
    }

    /// The status row's folder: nothing at the project's root, the rest of the path inside it,
    /// and the whole path (with ~) outside it.
    static func statusPath(_ path: String, root: String) -> String {
        let clean = (path as NSString).standardizingPath, base = (root as NSString).standardizingPath
        if clean == base { return "" }
        if clean.hasPrefix(base + "/") { return String(clean.dropFirst(base.count + 1)) }
        return (clean as NSString).abbreviatingWithTildeInPath
    }

    static func durationText(_ seconds: TimeInterval) -> String {
        if seconds < 10 { return String(format: "%.1f s", seconds) }
        if seconds < 60 { return "\(Int(seconds.rounded())) s" }
        let whole = Int(seconds.rounded())
        return "\(whole / 60) m \(whole % 60) s"
    }

    private func clearUnseenOutput(at index: Int) {
        guard sessions.indices.contains(index), sessions[index].hasUnseenOutput else { return }
        if tabStrip.chips.indices.contains(index) { tabStrip.chips[index].hasUnseenOutput = false }
        terminals?.clearUnseenOutput(sessions[index])
    }

    // MARK: - Tab bar

    /// The terminal tabs: the shared strip (Direction 03 §4). Run's can be renamed.
    private lazy var tabStrip: TabStrip = {
        let strip = TabStrip(bar: tabBar, stack: tabBarStack, accessibilityLabel: "Terminal sessions")
        strip.onSelect = { [weak self] index in self?.switchToSession(index) }
        strip.onClose = { [weak self] index in self?.requestClose(at: index) }
        strip.onMove = { [weak self] from, to in self?.moveSession(from: from, to: to) }
        strip.onTearOut = { [weak self] index, screenPoint in self?.tearOutSession(at: index, to: screenPoint) }
        strip.onRename = { [weak self] index, name in self?.renameSession(at: index, to: name) }
        return strip
    }()

    /// Tabs that would read the same are numbered as Terminal.app numbers them: "audit-project",
    /// "audit-project 2" (the audit: two tabs both named for the project).
    static func distinctTitles(_ titles: [String]) -> [String] {
        var seen: [String: Int] = [:]
        return titles.map { title in
            seen[title, default: 0] += 1
            return seen[title]! == 1 ? title : "\(title) \(seen[title]!)"
        }
    }

    private func rebuildTabBar() {
        let titles = Self.distinctTitles(sessions.map(\.title))
        let items = zip(sessions, titles).map { session, title -> TabStrip.Item in
            var item = TabStrip.Item(id: session.id, title: title)
            item.isDead = !session.viewController.isAliveOrUnstarted
            item.hasUnseenOutput = session.hasUnseenOutput
            item.isWorking = session.viewController.isProgramWorking
            switch session.viewController.news {
            case .finished?: item.news = .verified
            case .needsYou?: item.news = .needsYou
            case nil: item.news = nil
            }
            // The whole name (a long one is cut off at the chip's width), and where it's working.
            let vc = session.viewController
            let directory = (vc.currentDirectory ?? vc.workingDirectory).map { ($0 as NSString).abbreviatingWithTildeInPath }
            item.toolTip = [session.title, directory].compactMap { $0 }.joined(separator: "\n")
            // What's running in it: Claude Code's tab shows Claude's mark, nvim's a pencil.
            item.icon = ProgramMarks.image(forProgram: vc.runningProgramName)
            // Its terminal as it stands, for the card the tab becomes when dragged out.
            let terminalView = session.viewController.terminalView
            item.preview = { [weak terminalView] in
                guard let terminalView, terminalView.bounds.width > 0, terminalView.bounds.height > 0,
                      let rep = terminalView.bitmapImageRepForCachingDisplay(in: terminalView.bounds) else { return nil }
                terminalView.cacheDisplay(in: terminalView.bounds, to: rep)
                let image = NSImage(size: terminalView.bounds.size)
                image.addRepresentation(rep)
                return image
            }
            item.menu = sessionMenu(for: session.id)
            return item
        }
        tabStrip.reload(items, active: activeSessionIndex)
    }

    /// Items carry the session's id, not its index: the menu can outlive a reorder.
    private func sessionMenu(for id: UUID) -> NSMenu {
        let menu = NSMenu()
        func item(_ title: String, _ action: Selector) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = id
        }
        item("Rename\u{2026}", #selector(renameSessionFromMenu(_:)))
        menu.addItem(NSMenuItem.separator())
        item("Close", #selector(closeSessionFromMenu(_:)))
        item("Close Others", #selector(closeOtherSessionsFromMenu(_:)))
        menu.addItem(NSMenuItem.separator())
        item("Show Beside Editor", #selector(showBesideFromMenu(_:)))
        item("Open in Agent", #selector(openInAgentFromMenu(_:)))
        item("Move to New Window", #selector(moveSessionToNewWindowFromMenu(_:)))
        menu.addItem(NSMenuItem.separator())
        let all = menu.addItem(withTitle: "Running Terminals\u{2026}", action: #selector(AppDelegate.showRunningTerminals), keyEquivalent: "")
        all.target = NSApp.delegate as? AppDelegate
        return menu
    }

    /// A tab dragged to a new place: the sessions follow the strip, the shown one with them.
    private func moveSession(from: Int, to: Int) {
        guard sessions.indices.contains(from), sessions.indices.contains(to) else { return }
        let activeID = activeSessionIndex.flatMap { sessions.indices.contains($0) ? sessions[$0].id : nil }
        var reordered = sessions
        reordered.insert(reordered.remove(at: from), at: to)
        sessions = reordered
        if let activeID { activeSessionIndex = sessions.firstIndex(where: { $0.id == activeID }) }
    }

    /// A name of the person's own, or nil to go back to the automatic one (the folder).
    private func renameSession(at index: Int, to name: String?) {
        guard sessions.indices.contains(index) else { return }
        terminals?.rename(sessions[index], to: name)
        rebuildTabBar()
    }

    @objc private func renameSessionFromMenu(_ sender: NSMenuItem) {
        guard let index = sessionIndex(from: sender), tabStrip.chips.indices.contains(index) else { return }
        tabStrip.chips[index].beginRename()
    }



    // MARK: - Tab context-menu actions (sender.representedObject is the session's UUID)

    fileprivate func sessionIndex(from sender: NSMenuItem) -> Int? {
        guard let id = sender.representedObject as? UUID else { return nil }
        return sessions.firstIndex { $0.id == id }
    }

    /// The Claude Code chat a tab is running, when it's running one Side knows the id of.
    fileprivate func claudeChat(at index: Int) -> String? {
        let vc = sessions[index].viewController
        guard vc.runningProgramName == "claude" else { return nil }
        return vc.recoveredAgentSession
    }

    @objc fileprivate func openInAgentFromMenu(_ sender: NSMenuItem) {
        guard let index = sessionIndex(from: sender), let id = claudeChat(at: index) else { return }
        onOpenInAgentRequested?(id)
    }

    func openInAgentForTesting() {
        guard let index = activeSessionIndex, sessions.indices.contains(index), let id = claudeChat(at: index) else { return }
        onOpenInAgentRequested?(id)
    }

    @objc private func closeSessionFromMenu(_ sender: NSMenuItem) {
        if let index = sessionIndex(from: sender) { requestClose(at: index) }
    }

    @objc private func closeOtherSessionsFromMenu(_ sender: NSMenuItem) {
        guard let index = sessionIndex(from: sender) else { return }
        let kept = sessions[index]
        let running = sessions.filter { $0 !== kept }.compactMap { $0.viewController.runningProgramName.map(ProgramMarks.displayName) }
        if SessionKeepers.confirmsClosingRunning, !running.isEmpty, let window = view.window {
            let what = running.count == 1 ? "\(running[0]) is" : "\(running.count) programs are"
            confirmClosing(message: "Close the other terminals?", detail: "\(what) still running in them. Closing the tabs ends them.", in: window) { [weak self, weak kept] in
                guard let self, let kept, let current = self.sessions.firstIndex(where: { $0 === kept }) else { return }
                self.closeOthers(keeping: current)
            }
            return
        }
        closeOthers(keeping: index)
    }

    private func closeOthers(keeping index: Int) {
        let kept = sessions[index]
        for session in sessions where session !== kept { session.viewController.prepareForClose() }
        sessions = [kept]
        activeSessionIndex = 0
        onActivityChanged?()
        rebuildTabBar()
        showActiveSession()
    }

    @objc private func showBesideFromMenu(_ sender: NSMenuItem) {
        if let index = sessionIndex(from: sender) { onShowBesideRequested?(sessions[index]) }
    }

    @objc private func moveSessionToNewWindowFromMenu(_ sender: NSMenuItem) {
        if let index = sessionIndex(from: sender) { tearOutSession(at: index, to: NSEvent.mouseLocation) }
    }

    // MARK: - Task row

    func setTaskRow(_ state: TaskRowState) {
        guard state != taskRowState || taskRow.arrangedSubviews.isEmpty else { return }
        taskRowState = state
        renderTaskRow()
    }

    private func renderTaskRow() {
        let state = taskRowState
        guard isViewLoaded else { return }
        taskRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let rerun = displayedSession?.viewController.rerunOffer
        let hasContent = !state.tasks.isEmpty || state.pendingCommand != nil || state.attachOffer != nil || rerun != nil || duplicate != nil
        taskRow.isHidden = !hasContent
        updateStatusLine()
        guard hasContent else { return }

        if let duplicate, state.pendingCommand == nil {
            // Both copies answer and write the same transcript: say so, and offer the way out.
            let other = tabShowing(keeperID: duplicate.otherKeeperID)
            let line = NSTextField(labelWithString: "")
            let text = NSMutableAttributedString(string: "This Claude Code conversation is also ", attributes: [.font: DS.Text.caption(), .foregroundColor: NSColor.secondaryLabelColor])
            if let other {
                text.append(NSAttributedString(string: "open in ", attributes: [.font: DS.Text.caption(), .foregroundColor: NSColor.secondaryLabelColor]))
                text.append(NSAttributedString(string: "\u{201C}\(other.title)\u{201D}", attributes: [.font: DS.Text.caption(.medium), .foregroundColor: NSColor.labelColor]))
            } else {
                text.append(NSAttributedString(string: "running in the background, in a terminal no tab shows", attributes: [.font: DS.Text.caption(), .foregroundColor: NSColor.secondaryLabelColor]))
            }
            line.attributedStringValue = text
            line.lineBreakMode = .byTruncatingTail
            taskRow.addArrangedSubview(line)
            if other != nil {
                taskRow.addArrangedSubview(Self.textAction("Go There", emphasized: true, target: self, action: #selector(goToDuplicate)))
            } else {
                taskRow.addArrangedSubview(Self.textAction("End That One", emphasized: true, target: self, action: #selector(endDuplicate)))
            }
            taskRow.addArrangedSubview(Self.textAction("Dismiss", emphasized: false, target: self, action: #selector(dismissDuplicate)))
            return
        }

        if let rerun, state.pendingCommand == nil {
            // After a restart (SIDE_RFC_SESSION_RESTORE.md): what this tab was running, which
            // isn't safe to start again unasked.
            let line = NSTextField(labelWithString: "")
            let text = NSMutableAttributedString(string: rerun, attributes: [.font: DS.Text.code(11.5, weight: .medium), .foregroundColor: NSColor.labelColor])
            text.append(NSAttributedString(string: " was running before the restart", attributes: [.font: DS.Text.caption(), .foregroundColor: NSColor.secondaryLabelColor]))
            line.attributedStringValue = text
            line.lineBreakMode = .byTruncatingMiddle
            taskRow.addArrangedSubview(line)
            taskRow.addArrangedSubview(Self.textAction("Run Again", emphasized: true, target: self, action: #selector(runAgainOffered)))
            taskRow.addArrangedSubview(Self.textAction("Dismiss", emphasized: false, target: self, action: #selector(dismissRunAgain)))
            return
        }

        if let pending = state.pendingCommand {
            // The same approval the agent's commands get, asked where the click happened.
            let question = NSTextField(labelWithString: "")
            let text = NSMutableAttributedString(string: "Run ", attributes: [.font: DS.Text.caption(), .foregroundColor: NSColor.secondaryLabelColor])
            text.append(NSAttributedString(string: pending, attributes: [.font: DS.Text.code(11.5, weight: .medium), .foregroundColor: NSColor.labelColor]))
            text.append(NSAttributedString(string: " in this terminal?", attributes: [.font: DS.Text.caption(), .foregroundColor: NSColor.secondaryLabelColor]))
            question.attributedStringValue = text
            question.lineBreakMode = .byTruncatingMiddle
            taskRow.addArrangedSubview(question)
            taskRow.addArrangedSubview(Self.textAction("Run", emphasized: true, target: self, action: #selector(confirmPendingTask)))
            taskRow.addArrangedSubview(Self.textAction("Cancel", emphasized: false, target: self, action: #selector(cancelPendingTask)))
            return
        }

        if let offer = state.attachOffer {
            // The manual verification path (§5.2): a result the user got by hand becomes the
            // newest checkpoint's evidence only when they say so.
            let line = NSTextField(labelWithString: "")
            let text = NSMutableAttributedString(string: offer.command, attributes: [.font: DS.Text.code(11.5, weight: .medium), .foregroundColor: NSColor.labelColor])
            text.append(NSAttributedString(string: offer.exitCode == 0 ? " passed" : " exited \(offer.exitCode)", attributes: [
                .font: DS.Text.caption(), .foregroundColor: offer.exitCode == 0 ? DS.Color.statusVerified : DS.Color.statusFailed,
            ]))
            line.attributedStringValue = text
            line.lineBreakMode = .byTruncatingMiddle
            taskRow.addArrangedSubview(line)
            taskRow.addArrangedSubview(Self.textAction("Attach to checkpoint", emphasized: true, target: self, action: #selector(attachOffered)))
            taskRow.addArrangedSubview(Self.textAction("Dismiss", emphasized: false, target: self, action: #selector(dismissOffered)))
            return
        }

        let label = NSTextField(labelWithString: "Tasks")
        label.font = DS.Text.caption()
        label.textColor = .tertiaryLabelColor
        taskRow.addArrangedSubview(label)
        taskRow.setCustomSpacing(DS.Spacing.m, after: label)
        for (index, task) in state.tasks.enumerated() {
            let chip = TaskChip(title: task.name, running: task.name == state.runningTaskName, isVerify: false)
            chip.toolTip = task.detail.isEmpty ? task.command : "\(task.detail) · \(task.command)"
            chip.tag = index
            chip.target = self
            chip.action = #selector(taskChipClicked(_:))
            chip.isEnabled = state.runningTaskName == nil
            taskRow.addArrangedSubview(chip)
        }
        if let verify = state.verifyTask {
            let chip = TaskChip(title: "Verify", running: verify.name == state.runningTaskName, isVerify: true)
            chip.toolTip = "Run \(verify.name) against the newest checkpoint. The result attaches to it"
            chip.tag = -1
            chip.target = self
            chip.action = #selector(taskChipClicked(_:))
            chip.isEnabled = state.runningTaskName == nil
            taskRow.addArrangedSubview(chip)
        }
    }

    @objc private func taskChipClicked(_ sender: NSButton) {
        let task = sender.tag < 0 ? taskRowState.verifyTask : (taskRowState.tasks.indices.contains(sender.tag) ? taskRowState.tasks[sender.tag] : nil)
        guard let task else { return }
        // The task runs in the terminal on screen; bring it forward if it's elsewhere.
        onRunTask?(task)
    }

    @objc private func attachOffered() { onResolveAttachOffer?(true) }
    @objc private func runAgainOffered() { displayedSession?.viewController.runOfferedCommand() }
    @objc private func dismissRunAgain() { displayedSession?.viewController.dismissRerunOffer() }
    @objc private func dismissOffered() { onResolveAttachOffer?(false) }

    /// A typed command in the shown terminal just finished — report it once. The first look at
    /// a session only records where it stands: a result already on screen isn't news.
    private func reportUserCommandIfFinished() {
        guard let session = displayedSession else { return }
        let vc = session.viewController
        let status = vc.commandStatus
        let previous = reportedFinishCount[session.id]
        reportedFinishCount[session.id] = status.finishedCount
        guard let previous, status.finishedCount > previous, taskRowState.runningTaskName == nil,
              let code = status.lastExitCode, !status.lastCommandWasAgent, let command = vc.lastSubmittedCommand else { return }
        onUserCommandFinished?(command, code, vc.terminalView.visibleText())
    }
    private var reportedFinishCount: [UUID: Int] = [:]

    @objc private func confirmPendingTask() { onResolvePendingTask?(true) }
    @objc private func cancelPendingTask() { onResolvePendingTask?(false) }

    private static func textAction(_ title: String, emphasized: Bool, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.isBordered = false
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: DS.Text.caption(emphasized ? .semibold : .regular),
            .foregroundColor: emphasized ? NSColor.labelColor : NSColor.secondaryLabelColor,
        ])
        return button
    }

    // MARK: - File links

    /// Recognizes bare file paths and `path:line[:col]` shapes (common in compiler/test
    /// output) and asks the workspace to open them in Make; anything else (real URLs) falls
    /// through to the default NSWorkspace handling.
    private func handleFileLink(_ link: String) -> Bool {
        let cwd = activeSessionIndex.flatMap { sessions.indices.contains($0) ? sessions[$0].viewController.currentDirectory : nil }
        guard let (url, line) = Self.fileLink(link, cwd: cwd) else { return false }
        onOpenFileRequested?(url, line)
        return true
    }

    /// A clicked link that names a file on disk: the file, and its line when it says one.
    static func fileLink(_ link: String, cwd: String?) -> (URL, Int?)? {
        guard !link.contains("://") else { return nil }
        let parts = link.split(separator: ":")
        guard let first = parts.first else { return nil }
        let path = String(first)
        let candidateURL: URL
        if path.hasPrefix("/") {
            candidateURL = URL(fileURLWithPath: path)
        } else if let cwd {
            candidateURL = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: cwd)).standardizedFileURL
        } else {
            return nil
        }
        guard FileManager.default.fileExists(atPath: candidateURL.path) else { return nil }
        return (candidateURL, parts.count > 1 ? Int(parts[1]) : nil)
    }
}

extension RunWorkspaceViewController: StageChromeProviding {
    var topRowContent: NSView? { loadViewIfNeeded(); return tabBar }

    var topRowBackground: NSColor { DS.Color.raised }

    /// The sheet is the whole window and the bar floats over it (2026-09-22); the grid stops
    /// above the bar so the prompt is never under it (2026-09-23) — see `bottomObstruction`.
    func setBottomObstruction(_ height: CGFloat) {
        bottomObstruction = height
        for entry in mounted.values { entry.bottom.constant = terminalBottomConstant }
    }

    func selectAdjacentTab(_ offset: Int) {
        guard !sessions.isEmpty else { return }
        let current = activeSessionIndex ?? 0
        selectTab(at: (current + offset + sessions.count) % sessions.count)
    }

    /// ⌘1–8 and ⌘9: a tab by its place, -1 the last.
    func selectTab(number index: Int) {
        guard !sessions.isEmpty else { return }
        let target = index < 0 ? sessions.count - 1 : index
        guard sessions.indices.contains(target), target != activeSessionIndex else { return }
        selectTab(at: target)
    }

    private func selectTab(at next: Int) {
        activeSessionIndex = next
        rebuildTabBar()
        showActiveSession()
        clearUnseenOutput(at: next)
    }
}

/// One task: its name in code type on `overlay` (the terminal sheet is `raised`), radius 6. The
/// running one leads with the working ring — the only animated indicator in the app.
private final class TaskChip: NSButton {
    init(title: String, running: Bool, isVerify: Bool) {
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = DS.Radius.control
        bindLayerBackground(DS.Color.overlay)
        let font = isVerify ? DS.Text.caption(.semibold) : DS.Text.code(11.5, weight: .regular)
        attributedTitle = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: running ? NSColor.labelColor : NSColor.secondaryLabelColor])
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 22).isActive = true
        setAccessibilityLabel(running ? "\(title), running" : title)
        if running {
            let ring = DS.StatusDot(state: .working)
            ring.translatesAutoresizingMaskIntoConstraints = false
            addSubview(ring)
            NSLayoutConstraint.activate([
                ring.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                ring.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }
        leadingInset = running ? 22 : 9
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var leadingInset: CGFloat = 9
    override var intrinsicContentSize: NSSize {
        let size = attributedTitle.size()
        return NSSize(width: ceil(size.width) + leadingInset + 9, height: 22)
    }
    override func draw(_ dirtyRect: NSRect) {
        let size = attributedTitle.size()
        attributedTitle.draw(at: NSPoint(x: leadingInset, y: (bounds.height - size.height) / 2))
    }
}

extension RunWorkspaceViewController: NSMenuItemValidation {
    /// Open in Agent shows only on a tab running a Claude Code chat Side knows the id of.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(openInAgentFromMenu(_:)) else { return true }
        let eligible = sessionIndex(from: menuItem).map { claudeChat(at: $0) != nil } ?? false
        menuItem.isHidden = !eligible
        return eligible
    }
}
