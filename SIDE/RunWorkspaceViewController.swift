import AppKit

final class RunWorkspaceViewController: NSViewController {
    /// The project's terminals (RFC R2). Run is a view onto them: it attaches to a track's
    /// sessions and shows one, but never owns a PTY — closing the window leaves a running
    /// command running for as long as the project is open anywhere. Nil means no project.
    private var terminals: TerminalSessionManager?
    private var terminalsObserver: NSObjectProtocol?
    var currentTrackKey: String?
    private var trackKey: String { currentTrackKey ?? "" }

    private var sessions: [TerminalSession] {
        get { terminals?.sessions(forTrackKey: trackKey) ?? [] }
        set { terminals?.setSessions(newValue, forTrackKey: trackKey, origin: self) }
    }
    private var activeSessionIndex: Int? {
        get { terminals?.activeIndex(forTrackKey: trackKey) }
        set { terminals?.setActiveIndex(newValue, forTrackKey: trackKey) }
    }
    private let tabBar = TabStripView()
    private let tabBarStack = NSStackView()
    private var containerBottom: NSLayoutConstraint!
    private let container = NSView()
    private var tabChips: [TabChipView] = []

    var onActivityChanged: (() -> Void)?
    var onOpenFileRequested: ((URL, Int?) -> Void)?

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
        guard isViewLoaded, origin != ObjectIdentifier(self) else { return }
        rebuildTabBar()
        if let displayed = displayedSession, !sessions.contains(where: { $0 === displayed }) {
            // Discarded under us (the track was deleted, or the project torn down).
            clearContainer()
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
    }

    private func buildView() {
        view.wantsLayer = true
        ChromeBackground.install(in: view)

        tabBar.wantsLayer = true
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.clipsToBounds = true
        tabBar.bindLayerBackground(DS.Color.canvas)
        tabBarStack.orientation = .horizontal
        tabBarStack.alignment = .bottom
        tabBarStack.spacing = DS.Spacing.xxs
        tabBarStack.translatesAutoresizingMaskIntoConstraints = false
        tabBar.addSubview(tabBarStack)

        let divider = NSBox()
        divider.boxType = .custom
        divider.borderType = .noBorder
        divider.fillColor = DS.Color.hairlineStrong
        divider.translatesAutoresizingMaskIntoConstraints = false
        // Behind the chips, so the active tab's fill covers it and attaches to the content.
        tabBar.addSubview(divider, positioned: .below, relativeTo: tabBarStack)

        // Same scrolling strip as Make — the strip scrolls, the window never widens.
        let tabScroll = NSScrollView()
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

        // The tab strip is hosted in the window's top row (Direction 02 §3.2) — `topRowContent`.
        // The terminal sheet: edge-to-edge on the sides and bottom, but with rounded top
        // corners and a breath of space under the tab strip — the terminal reads as a surface
        // sliding up under the tabs, not a floating card and not a flush slab touching chrome.
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.cornerRadius = DS.Radius.surface
        container.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        container.bindLayerBackground(DS.Color.raised)
        container.clipsToBounds = true
        view.addSubview(container)

        containerBottom = container.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        NSLayoutConstraint.activate([
            tabScroll.leadingAnchor.constraint(equalTo: tabBar.leadingAnchor), tabScroll.trailingAnchor.constraint(equalTo: tabBar.trailingAnchor), tabScroll.topAnchor.constraint(equalTo: tabBar.topAnchor), tabScroll.bottomAnchor.constraint(equalTo: tabBar.bottomAnchor),
            tabBarStack.leadingAnchor.constraint(equalTo: tabScroll.contentView.leadingAnchor), tabBarStack.topAnchor.constraint(equalTo: tabScroll.contentView.topAnchor), tabBarStack.heightAnchor.constraint(equalTo: tabScroll.heightAnchor),
            divider.leadingAnchor.constraint(equalTo: tabBar.leadingAnchor), divider.trailingAnchor.constraint(equalTo: tabBar.trailingAnchor), divider.bottomAnchor.constraint(equalTo: tabBar.bottomAnchor), divider.heightAnchor.constraint(equalToConstant: 1),
            // Attached to the tab row above it: the active tab and the terminal are one surface.
            container.topAnchor.constraint(equalTo: view.topAnchor), container.leadingAnchor.constraint(equalTo: view.leadingAnchor), container.trailingAnchor.constraint(equalTo: view.trailingAnchor), containerBottom
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
            self.activeSessionIndex = min(index, self.sessions.count - 1)
            self.rebuildTabBar()
            self.showActiveSession()
        }
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
        NSLayoutConstraint.activate([
            vc.view.topAnchor.constraint(equalTo: container.topAnchor, constant: 8), vc.view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            vc.view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10), vc.view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8)
        ])
        vc.activate()
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
        // Shown for a single session too: with no title bar, the tab is the terminal's name.
        guard !sessions.isEmpty else { return }
        for (index, session) in sessions.enumerated() {
            let chip = TabChipView()
            chip.index = index
            chip.isActive = index == activeSessionIndex
            chip.title = session.label
            chip.isDead = !session.viewController.isAlive
            chip.hasUnseenOutput = session.hasUnseenOutput
            chip.translatesAutoresizingMaskIntoConstraints = false
            chip.heightAnchor.constraint(equalToConstant: TabChipView.height).isActive = true
            chip.onSelect = { [weak self] i in self?.switchToSession(i) }
            chip.onDragging = { [weak self, weak chip] windowX in
                guard let self, let chip else { return }
                self.handleTabDragging(chip, toWindowX: windowX)
            }

            let closeButton = TabCloseButton()
            closeButton.tag = index
            closeButton.target = self
            closeButton.action = #selector(closeSessionButton(_:))
            closeButton.translatesAutoresizingMaskIntoConstraints = false
            closeButton.isHidden = true
            chip.addSubview(closeButton)
            chip.closeButton = closeButton
            NSLayoutConstraint.activate([
                closeButton.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -(5 + TabChipView.flare)), closeButton.centerYAnchor.constraint(equalTo: chip.centerYAnchor)
            ])

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

    /// A hard inset: the terminal is shortened, never scrolled under, so the prompt line is
    /// never beneath anything drawn over the bottom of the window.
    func setBottomObstruction(_ height: CGFloat) {
        loadViewIfNeeded()
        containerBottom.constant = height > 0 ? -(height + DS.Spacing.l) : 0
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
