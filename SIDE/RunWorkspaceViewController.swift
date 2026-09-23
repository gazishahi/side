import AppKit

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
    private var terminalBottom: NSLayoutConstraint?
    private var terminalTop: NSLayoutConstraint?
    /// The grid starts under the task/status row when it shows.
    private var terminalTopConstant: CGFloat { ChromeHost.rowHeight + 4 + (statusRowShows ? Self.taskRowHeight + 4 : 0) }
    private var statusRowShows: Bool { hasProject && displayedSession != nil }
    private var terminalBottomConstant: CGFloat { -(bottomObstruction > 0 ? bottomObstruction + DS.Spacing.s : terminalBottomInset) }
    private let container = NSView()
    private var tabChips: [TabChipView] = []

    var onActivityChanged: (() -> Void)?
    var onOpenFileRequested: ((URL, Int?) -> Void)?
    /// A task chip was clicked: the shell proposes it through the track's runner.
    var onRunTask: ((ProjectTask) -> Void)?
    /// The confirm strip's Run (true) or Cancel (false) for a proposed task.
    var onResolvePendingTask: ((Bool) -> Void)?

    /// What the task row shows (§4.3) — computed by the shell, which owns the runner and the
    /// project's task list; this view only draws it.
    struct TaskRowState: Equatable {
        var tasks: [ProjectTask] = []
        /// Offered when a verification task exists and the newest checkpoint is unverified.
        var verifyTask: ProjectTask?
        var runningTaskName: String?
        /// A proposed task waiting for Run / Cancel (Manual autonomy, or off the allowlist).
        var pendingCommand: String?
    }
    private var taskRowState = TaskRowState()
    private let taskRow = NSStackView()
    /// `cwd · last exit N · duration · running <task> in tab N` (§4.3), trailing the task row.
    private let statusLine = NSTextField(labelWithString: "")
    private static let taskRowHeight: CGFloat = 26
    /// A tab dragged out of the window: the shell opens a window that adopts the session.
    var onTearOutRequested: ((TerminalSession, NSPoint) -> Void)?

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
    }

    /// Something changed that this view didn't cause: an agent opened a session, a shell exited,
    /// output arrived in the background, another window took the terminal this one was showing.
    private func terminalsChanged(origin: ObjectIdentifier?) {
        onActivityChanged?()
        updateStatusLine()
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
        } else if displayedSession == nil, let index = activeSessionIndex, sessions.indices.contains(index), view.window != nil, container.subviews.isEmpty {
            showActiveSession()
        }
    }

    /// The session this view has in its container, if any.
    private var displayedSession: TerminalSession?

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
        } else {
            // No session for this track yet — don't eagerly create one (that's still
            // activateActiveSession()'s job for whenever the user actually visits Run), but don't
            // leave the previous track's terminal content sitting on screen either.
            clearContainer()
        }
    }

    private func showNoProjectState() {
        showPlaceholder("No project is open. Run gives each track its own terminals inside a project.")
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

    /// Lets go of the shown terminal without ending it — only its view leaves this window.
    private func detachDisplayedSession() {
        if let displayed = displayedSession, displayed.viewController.parent === self {
            displayed.viewController.view.removeFromSuperview()
            displayed.viewController.removeFromParent()
        }
        displayedSession = nil
        terminals?.markDisplayed(nil, by: self)
    }

    @objc func newSession() {
        createSession()
        sessions[activeSessionIndex ?? 0].viewController.activate()
    }

    @objc private func closeActiveTab() {
        guard let index = activeSessionIndex else { return }
        closeSession(at: index)
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
    private func restoreRememberedSessionsOrCreateOne() {
        let remembered = terminals?.rememberedDirectories(forTrackKey: trackKey) ?? []
        guard !remembered.isEmpty else { return createSession() }
        // Created, not started: a shell starts when its tab is first shown. Starting all of them
        // here made every background tab's first prompt count as unseen output, so reopening a
        // project with three remembered tabs lit Run's badge for nothing.
        for directory in remembered { createSession(inDirectory: directory, show: false) }
        activeSessionIndex = 0
        rebuildTabBar()
        showActiveSession()
    }

    private func createSession(replacing index: Int? = nil, inDirectory directory: String? = nil, show: Bool = true) {
        guard let terminals else { return }
        // A restored tab reopens where it was, not wherever the track currently points.
        let session = terminals.makeSession(forTrackKey: trackKey, inDirectory: directory)
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
        animateChipClosed(at: index) { [weak self] in
            guard let self, self.sessions.indices.contains(index) else { return }
            let wasActive = self.activeSessionIndex == index
            let next = TabSelection.indexAfterClosing(index, active: self.activeSessionIndex, countBefore: self.sessions.count)
            self.sessions[index].viewController.prepareForClose()
            self.sessions.remove(at: index)
            // The closed tab may have been the last one holding unseen output — without this
            // the stage's ● outlived every tab that caused it.
            self.onActivityChanged?()
            if self.sessions.isEmpty {
                // Run always has at least one session — no empty state to design for.
                self.createSession()
                return
            }
            self.activeSessionIndex = next
            self.rebuildTabBar()
            if wasActive { self.showActiveSession() }
        }
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

    private func switchToSession(_ index: Int) {
        guard sessions.indices.contains(index), index != activeSessionIndex else { return }
        activeSessionIndex = index
        rebuildTabBar()
        showActiveSession()
        clearUnseenOutput(at: index)
    }

    private func showActiveSession() {
        guard let index = activeSessionIndex, sessions.indices.contains(index) else { return }
        clearContainer()
        let session = sessions[index]
        let vc = session.viewController
        // Taken from another window if it was showing there; that window shows a placeholder.
        if vc.parent != nil { vc.view.removeFromSuperview(); vc.removeFromParent() }
        vc.onFileLinkRequested = { [weak self] link in self?.handleFileLink(link) ?? false }
        displayedSession = session
        terminals?.markDisplayed(session, by: self)
        addChild(vc)
        vc.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(vc.view)
        let bottom = vc.view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: terminalBottomConstant)
        terminalBottom = bottom
        let top = vc.view.topAnchor.constraint(equalTo: container.topAnchor, constant: terminalTopConstant)
        terminalTop = top
        NSLayoutConstraint.activate([
            top, vc.view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            vc.view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16), bottom
        ])
        vc.activate()
        updateStatusLine()
    }

    /// Reads the shown session's live cwd (OSC 7) and last command (OSC 133). A cwd outside the
    /// track's worktree is flagged, and agent commands there always ask (audit D-10).
    private func updateStatusLine() {
        guard isViewLoaded else { return }
        terminalTop?.constant = terminalTopConstant
        guard statusRowShows, let session = displayedSession, let terminals else { statusLine.stringValue = ""; return }
        let vc = session.viewController
        let worktree = terminals.workingDirectory(forTrackKey: trackKey).path
        let cwd = vc.currentDirectory ?? vc.workingDirectory ?? worktree
        let outside = !TerminalSessionManager.isInside(cwd, root: worktree)
        let base: [NSAttributedString.Key: Any] = [.font: DS.Text.code(11, weight: .regular), .foregroundColor: NSColor.tertiaryLabelColor]
        let text = NSMutableAttributedString(string: (cwd as NSString).abbreviatingWithTildeInPath,
                                             attributes: base.merging([.foregroundColor: outside ? DS.Color.statusNeedsYou : NSColor.secondaryLabelColor]) { $1 })
        var parts: [String] = []
        let status = vc.commandStatus
        if let code = status.lastExitCode { parts.append("last exit \(code)") }
        if let duration = status.lastDuration { parts.append(Self.durationText(duration)) }
        if let task = taskRowState.runningTaskName {
            let agentTab = terminals.agentSessionIndex(forTrackKey: trackKey)
            parts.append(agentTab.map { $0 != activeSessionIndex && sessions.count > 1 ? "running \(task) in tab \($0 + 1)" : "running \(task)" } ?? "running \(task)")
        }
        for part in parts { text.append(NSAttributedString(string: " \u{00B7} " + part, attributes: base)) }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingHead
        paragraph.alignment = .right
        text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
        statusLine.attributedStringValue = text
        statusLine.toolTip = outside ? "Outside this track's worktree \u{2014} agent commands in this terminal always ask first." : cwd
    }

    static func durationText(_ seconds: TimeInterval) -> String {
        if seconds < 10 { return String(format: "%.1f s", seconds) }
        if seconds < 60 { return "\(Int(seconds.rounded())) s" }
        let whole = Int(seconds.rounded())
        return "\(whole / 60) m \(whole % 60) s"
    }

    private func clearUnseenOutput(at index: Int) {
        guard sessions.indices.contains(index), sessions[index].hasUnseenOutput else { return }
        if tabChips.indices.contains(index) { tabChips[index].hasUnseenOutput = false }
        terminals?.clearUnseenOutput(sessions[index])
    }

    // MARK: - Tab bar

    private var lastKnownSessionCount = 0

    private func rebuildTabBar() {
        let previousCount = lastKnownSessionCount
        lastKnownSessionCount = sessions.count
        tabBarStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        tabChips.removeAll()
        // One terminal needs no tabs; the strip appears once there's a second.
        guard sessions.count > 1 else { tabBar.accessibleTabs = []; return }
        for (index, session) in sessions.enumerated() {
            let chip = TabChipView()
            chip.index = index
            chip.isActive = index == activeSessionIndex
            chip.title = session.label
            chip.isDead = !session.viewController.isAliveOrUnstarted
            chip.hasUnseenOutput = session.hasUnseenOutput
            chip.dragIcon = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
            chip.translatesAutoresizingMaskIntoConstraints = false
            chip.heightAnchor.constraint(equalToConstant: TabChipView.height).isActive = true
            chip.onSelect = { [weak self] i in self?.switchToSession(i) }
            chip.onDragging = { [weak self, weak chip] windowX in
                guard let self, let chip else { return }
                self.handleTabDragging(chip, toWindowX: windowX)
            }
            chip.onTearOut = { [weak self, weak chip] screenPoint in
                guard let self, let chip else { return }
                self.tearOutSession(at: chip.index, to: screenPoint)
            }

            let closeButton = TabCloseButton()
            closeButton.tag = index
            closeButton.target = self
            closeButton.action = #selector(closeSessionButton(_:))
            closeButton.translatesAutoresizingMaskIntoConstraints = false
            closeButton.isHidden = true
            chip.addSubview(closeButton)
            chip.closeButton = closeButton
            chip.updateCloseVisibility()
            NSLayoutConstraint.activate([
                closeButton.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -(5 + TabChipView.flare)), closeButton.centerYAnchor.constraint(equalTo: chip.centerYAnchor)
            ])

            // Items carry the session's id, not its index — the menu can outlive a reorder.
            let menu = NSMenu()
            func item(_ title: String, _ action: Selector) {
                let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
                item.target = self
                item.representedObject = session.id
            }
            item("Close", #selector(closeSessionFromMenu(_:)))
            item("Close Others", #selector(closeOtherSessionsFromMenu(_:)))
            menu.addItem(NSMenuItem.separator())
            item("Move to New Window", #selector(moveSessionToNewWindowFromMenu(_:)))
            chip.menu = menu

            tabBarStack.addArrangedSubview(chip)
            tabChips.append(chip)
        }
        tabBar.accessibilityGroupLabel = "Terminal sessions"
        tabBar.accessibleTabs = tabChips
        // Same arrival as Make's file tabs — a new session's chip animates in on live creation,
        // full rebuilds (track switches, reorders) lay out instantly.
        if sessions.count == previousCount + 1, let newest = activeSessionIndex.flatMap({ tabChips.indices.contains($0) ? tabChips[$0] : nil }) {
            tabBarStack.layoutSubtreeIfNeeded()
            DS.Motion.appear(newest, distance: 8)
        }
    }

    /// Mirrors Make's close animation: the chip shrinks and fades, siblings glide together,
    /// then the model removes the session.
    private func animateChipClosed(at index: Int, completion: @escaping () -> Void) {
        guard tabChips.indices.contains(index), sessions.count > 1 else { completion(); return }
        let chip = tabChips[index]
        let widthConstraint = chip.widthAnchor.constraint(equalToConstant: chip.frame.width)
        widthConstraint.isActive = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = DS.Motion.duration(0.14)
            context.timingFunction = DS.Motion.curve
            context.allowsImplicitAnimation = true
            chip.animator().alphaValue = 0
            widthConstraint.constant = 0
            tabBarStack.layoutSubtreeIfNeeded()
        } completionHandler: {
            completion()
        }
    }

    @objc private func closeSessionButton(_ sender: NSButton) { closeSession(at: sender.tag) }

    // MARK: - Tab context-menu actions (sender.representedObject is the session's UUID)

    private func sessionIndex(from sender: NSMenuItem) -> Int? {
        guard let id = sender.representedObject as? UUID else { return nil }
        return sessions.firstIndex { $0.id == id }
    }

    @objc private func closeSessionFromMenu(_ sender: NSMenuItem) {
        if let index = sessionIndex(from: sender) { closeSession(at: index) }
    }

    @objc private func closeOtherSessionsFromMenu(_ sender: NSMenuItem) {
        guard let index = sessionIndex(from: sender) else { return }
        let kept = sessions[index]
        for session in sessions where session !== kept { session.viewController.prepareForClose() }
        sessions = [kept]
        activeSessionIndex = 0
        onActivityChanged?()
        rebuildTabBar()
        showActiveSession()
    }

    @objc private func moveSessionToNewWindowFromMenu(_ sender: NSMenuItem) {
        if let index = sessionIndex(from: sender) { tearOutSession(at: index, to: NSEvent.mouseLocation) }
    }

    private func handleTabDragging(_ chip: TabChipView, toWindowX x: CGFloat) {
        guard let draggedIndex = tabChips.firstIndex(where: { $0 === chip }) else { return }
        // The drop index is "how many siblings sit left of the cursor" — counting, not the
        // sibling's own index. The old code assigned the *last passed sibling's index*, which
        // after a swap pointed one slot short, so the next mouse event swapped straight back:
        // the tab oscillated between two slots for as long as you dragged past the end.
        var dropIndex = 0
        for sibling in tabChips where sibling !== chip {
            let siblingMidXInWindow = sibling.convert(NSPoint(x: sibling.bounds.midX, y: 0), to: nil).x
            if x > siblingMidXInWindow { dropIndex += 1 }
        }
        guard dropIndex != draggedIndex else { return }

        let activeID = activeSessionIndex.flatMap { sessions.indices.contains($0) ? sessions[$0].id : nil }
        var reordered = sessions
        reordered.insert(reordered.remove(at: draggedIndex), at: dropIndex)
        sessions = reordered
        tabChips.remove(at: draggedIndex)
        tabChips.insert(chip, at: dropIndex)
        tabBarStack.removeArrangedSubview(chip)
        tabBarStack.insertArrangedSubview(chip, at: dropIndex)
        if let activeID { activeSessionIndex = sessions.firstIndex(where: { $0.id == activeID }) }
        reindexTabChips()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = DS.Motion.duration(0.16)
            context.timingFunction = DS.Motion.curve
            context.allowsImplicitAnimation = true
            tabBarStack.layoutSubtreeIfNeeded()
        }
    }

    private func reindexTabChips() {
        for (i, chip) in tabChips.enumerated() {
            chip.index = i
            chip.isActive = (i == activeSessionIndex)
            chip.closeButton?.tag = i
        }
    }

    // MARK: - Task row

    func setTaskRow(_ state: TaskRowState) {
        guard state != taskRowState || taskRow.arrangedSubviews.isEmpty else { return }
        taskRowState = state
        guard isViewLoaded else { return }
        taskRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let hasContent = !state.tasks.isEmpty || state.pendingCommand != nil
        taskRow.isHidden = !hasContent
        updateStatusLine()
        guard hasContent else { return }

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

        let label = NSTextField(labelWithString: "Tasks")
        label.font = DS.Text.caption()
        label.textColor = .tertiaryLabelColor
        taskRow.addArrangedSubview(label)
        taskRow.setCustomSpacing(DS.Spacing.m, after: label)
        for (index, task) in state.tasks.enumerated() {
            let chip = TaskChip(title: task.name, running: task.name == state.runningTaskName, isVerify: false)
            chip.toolTip = task.detail.isEmpty ? task.command : "\(task.detail) — \(task.command)"
            chip.tag = index
            chip.target = self
            chip.action = #selector(taskChipClicked(_:))
            chip.isEnabled = state.runningTaskName == nil
            taskRow.addArrangedSubview(chip)
        }
        if let verify = state.verifyTask {
            let chip = TaskChip(title: "Verify", running: verify.name == state.runningTaskName, isVerify: true)
            chip.toolTip = "Run \(verify.name) against the newest checkpoint — the result attaches to it"
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
        guard !link.contains("://") else { return false }
        let parts = link.split(separator: ":")
        guard let first = parts.first else { return false }
        let path = String(first)
        let candidateURL: URL
        if path.hasPrefix("/") {
            candidateURL = URL(fileURLWithPath: path)
        } else if let cwd = activeSessionIndex.flatMap({ sessions.indices.contains($0) ? sessions[$0].viewController.currentDirectory : nil }) {
            candidateURL = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: cwd)).standardizedFileURL
        } else {
            return false
        }
        guard FileManager.default.fileExists(atPath: candidateURL.path) else { return false }
        let line = parts.count > 1 ? Int(parts[1]) : nil
        onOpenFileRequested?(candidateURL, line)
        return true
    }
}

extension RunWorkspaceViewController: StageChromeProviding {
    var topRowContent: NSView? { loadViewIfNeeded(); return tabBar }

    var topRowBackground: NSColor { DS.Color.raised }

    /// The sheet is the whole window and the bar floats over it (2026-09-22); the grid stops
    /// above the bar so the prompt is never under it (2026-09-23) — see `bottomObstruction`.
    func setBottomObstruction(_ height: CGFloat) {
        bottomObstruction = height
        terminalBottom?.constant = terminalBottomConstant
    }

    func selectAdjacentTab(_ offset: Int) {
        guard !sessions.isEmpty else { return }
        let current = activeSessionIndex ?? 0
        let next = (current + offset + sessions.count) % sessions.count
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

