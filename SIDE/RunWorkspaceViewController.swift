import AppKit

private struct RunSession {
    let id = UUID()
    var label: String
    var viewController: TerminalViewController
    var hasUnseenOutput = false
}

final class RunWorkspaceViewController: NSViewController {
    /// Keyed by track branch name (`""` for "no active track" — a project not using Tracks, or
    /// sitting on the default branch between tracks), same convention as Make's per-track file
    /// memory. Each track's shells keep running in the background when you switch away — unlike
    /// Make's tabs, which close outright, a live dev-server process is usually worth preserving
    /// across a quick trip to another track rather than killed and restarted.
    private var sessionsByTrackKey: [String: [RunSession]] = [:]
    private var activeSessionIndexByTrackKey: [String: Int] = [:]
    var currentTrackKey: String?

    private var sessions: [RunSession] {
        get { sessionsByTrackKey[currentTrackKey ?? ""] ?? [] }
        set { sessionsByTrackKey[currentTrackKey ?? ""] = newValue }
    }
    private var activeSessionIndex: Int? {
        get { activeSessionIndexByTrackKey[currentTrackKey ?? ""] }
        set { activeSessionIndexByTrackKey[currentTrackKey ?? ""] = newValue }
    }
    private let tabBar = TabStripView()
    private let tabBarStack = NSStackView()
    private var tabBarHeightConstraint: NSLayoutConstraint!
    private let container = NSView()
    private var tabChips: [TabChipView] = []

    /// Only used as the cwd for *new* sessions — existing sessions keep whatever directory
    /// they're actually in, the same way a new terminal in a real IDE defaults to the project
    /// root without moving already-open ones. Used for the "no active track" bucket, and as a
    /// fallback for any track that hasn't reported a working directory of its own yet.
    var defaultWorkingDirectory: String?
    /// Per-track terminal cwd — a track's own worktree, once it has one. Set by
    /// `ShellViewController` alongside every `reloadForTrackSwitch` call.
    private var workingDirectoryByTrackKey: [String: String] = [:]
    private var currentWorkingDirectory: String? {
        workingDirectoryByTrackKey[currentTrackKey ?? ""] ?? defaultWorkingDirectory
    }
    var onActivityChanged: (() -> Void)?
    var onOpenFileRequested: ((URL, Int?) -> Void)?

    /// Across every track, not just the current one — a track running in the background with
    /// unseen output should still light up the stage badge even while you're looking elsewhere.
    var hasBackgroundActivity: Bool { sessionsByTrackKey.values.contains { $0.contains { $0.hasUnseenOutput } } }

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
        tabBar.layer?.backgroundColor = DS.Color.tabStrip.cgColor
        tabBarStack.orientation = .horizontal
        tabBarStack.alignment = .bottom
        tabBarStack.spacing = DS.Spacing.xxs
        tabBarStack.translatesAutoresizingMaskIntoConstraints = false
        tabBar.addSubview(tabBarStack)

        let divider = NSBox()
        divider.boxType = .custom
        divider.borderType = .noBorder
        divider.fillColor = DS.Color.tabEdge
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

        view.addSubview(tabBar)
        // The terminal sheet: edge-to-edge on the sides and bottom, but with rounded top
        // corners and a breath of space under the tab strip — the terminal reads as a surface
        // sliding up under the tabs, not a floating card and not a flush slab touching chrome.
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.cornerRadius = DS.Radius.card
        container.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        container.layer?.backgroundColor = NSColor.black.cgColor
        container.clipsToBounds = true
        view.addSubview(container)

        tabBarHeightConstraint = tabBar.heightAnchor.constraint(equalToConstant: 30)
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: view.topAnchor), tabBar.leadingAnchor.constraint(equalTo: view.leadingAnchor), tabBar.trailingAnchor.constraint(equalTo: view.trailingAnchor), tabBarHeightConstraint,
            tabScroll.leadingAnchor.constraint(equalTo: tabBar.leadingAnchor, constant: 10), tabScroll.trailingAnchor.constraint(equalTo: tabBar.trailingAnchor, constant: -10), tabScroll.topAnchor.constraint(equalTo: tabBar.topAnchor), tabScroll.bottomAnchor.constraint(equalTo: tabBar.bottomAnchor),
            tabBarStack.leadingAnchor.constraint(equalTo: tabScroll.contentView.leadingAnchor), tabBarStack.topAnchor.constraint(equalTo: tabScroll.contentView.topAnchor), tabBarStack.heightAnchor.constraint(equalTo: tabScroll.heightAnchor),
            divider.leadingAnchor.constraint(equalTo: tabBar.leadingAnchor), divider.trailingAnchor.constraint(equalTo: tabBar.trailingAnchor), divider.bottomAnchor.constraint(equalTo: tabBar.bottomAnchor), divider.heightAnchor.constraint(equalToConstant: 1),
            container.topAnchor.constraint(equalTo: tabBar.bottomAnchor, constant: 10), container.leadingAnchor.constraint(equalTo: view.leadingAnchor), container.trailingAnchor.constraint(equalTo: view.trailingAnchor), container.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    /// Called every time the Run stage becomes visible — starts the first session lazily
    /// (mirrors the old single-terminal activate() behavior) or reattaches the active one.
    /// Always goes through `showActiveSession()` (not just `.activate()`) because the active
    /// track can have changed since Run was last shown, in which case `container` is still
    /// displaying a different track's terminal view.
    func activateActiveSession() {
        guard let index = activeSessionIndex, sessions.indices.contains(index) else {
            createSession()
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
    func reloadForTrackSwitch(trackKey: String?, workingDirectory: URL) {
        workingDirectoryByTrackKey[trackKey ?? ""] = workingDirectory.path
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

    /// Called when a track is deleted — its sessions have nowhere to belong anymore, so their
    /// shells are terminated and the bucket dropped instead of leaking background processes.
    func discardSessions(forTrackKey trackKey: String?) {
        let key = trackKey ?? ""
        for session in sessionsByTrackKey[key] ?? [] { session.viewController.prepareForClose() }
        sessionsByTrackKey.removeValue(forKey: key)
        activeSessionIndexByTrackKey.removeValue(forKey: key)
        workingDirectoryByTrackKey.removeValue(forKey: key)
        // If the discarded track happens to be the one currently on screen, its tab chips and
        // terminal view are now stale (pointing at killed sessions) — without this, they'd keep
        // showing until some unrelated action happened to trigger a rebuild.
        guard isViewLoaded, key == (currentTrackKey ?? "") else { return }
        rebuildTabBar()
        clearContainer()
    }

    private func clearContainer() {
        for child in children {
            child.view.removeFromSuperview()
            child.removeFromParent()
        }
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

    func prepareForClose() {
        for sessions in sessionsByTrackKey.values {
            for session in sessions { session.viewController.prepareForClose() }
        }
    }

    /// Types `command` into `trackKey`'s own Run session — creating one if it doesn't have one
    /// yet, using `cwd` as the new session's working directory — the real, visible terminal an
    /// agent's `run_shell_command` types into, never a hidden `Process`. Deliberately bypasses
    /// the `sessions`/`activeSessionIndex` computed properties (which are scoped to whichever
    /// track is *currently displayed*): the agent may be running against a track this window
    /// isn't even looking at, and creating its session here must not steal focus or disturb
    /// whatever tab bar is currently on screen for a different track.
    /// Cancellation path for an agent command — Ctrl-C into whichever session the agent is
    /// actually using for this track, which is not necessarily the one on screen.
    func interruptAgentCommand(trackKey: String) {
        guard let list = sessionsByTrackKey[trackKey] else { return }
        let index = activeSessionIndexByTrackKey[trackKey] ?? 0
        guard list.indices.contains(index) else { return }
        list[index].viewController.interruptAgentCommand()
    }

    func runAgentCommand(_ command: String, cwd: URL, trackKey: String, completion: @escaping (String) -> Void) {
        var list = sessionsByTrackKey[trackKey] ?? []
        let targetIndex: Int
        if let existing = activeSessionIndexByTrackKey[trackKey], list.indices.contains(existing) {
            targetIndex = existing
        } else if !list.isEmpty {
            targetIndex = 0
        } else {
            let vc = TerminalViewController()
            vc.workingDirectory = cwd.path
            wire(vc)
            // Forces loadView()/viewDidLoad() to run now rather than whenever (if ever) this
            // session's tab is actually displayed — viewDidLoad is where SideTerminalView's
            // onRawDataReceived gets wired, and runAgentCommand's sentinel scan depends on that
            // callback firing for every byte the process produces. Without this, a track whose
            // Run stage was never manually visited would create a session whose raw output goes
            // completely unobserved, and every agent command against it would silently fall
            // through to the 30s "still running" timeout no matter how fast it actually finished.
            vc.loadViewIfNeeded()
            list.append(RunSession(label: cwd.lastPathComponent, viewController: vc))
            sessionsByTrackKey[trackKey] = list
            targetIndex = 0
            activeSessionIndexByTrackKey[trackKey] = targetIndex
            // Only rebuild/redisplay if this track's tab bar happens to be the one currently
            // on screen — otherwise this would yank the visible session out from under
            // whatever the user is actually looking at right now.
            if isViewLoaded, trackKey == (currentTrackKey ?? "") {
                rebuildTabBar()
                showActiveSession()
            }
        }
        list[targetIndex].viewController.runAgentCommand(command, completion: completion)
    }

    // MARK: - Session lifecycle

    private func createSession(replacing index: Int? = nil) {
        let vc = TerminalViewController()
        vc.workingDirectory = currentWorkingDirectory
        wire(vc)
        let label = currentWorkingDirectory.map { ($0 as NSString).lastPathComponent } ?? "Terminal"
        let session = RunSession(label: label, viewController: vc)
        if let index, sessions.indices.contains(index) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }
        activeSessionIndex = index ?? (sessions.count - 1)
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
        let vc = sessions[index].viewController
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
        sessions[index].hasUnseenOutput = false
        if tabChips.indices.contains(index) { tabChips[index].hasUnseenOutput = false }
        onActivityChanged?()
    }

    private func wire(_ vc: TerminalViewController) {
        vc.onExitStatusChanged = { [weak self, weak vc] _, _ in
            guard let self, let vc else { return }
            self.refreshChip(for: vc)
        }
        vc.onOutputReceived = { [weak self, weak vc] in
            // Searches every track's bucket, not just `self.sessions` (the *currently displayed*
            // track) — a session belonging to a backgrounded track would otherwise never be
            // found here at all, so its unseen-output flag could never be set in the first
            // place, silently defeating the whole point of a cross-track activity badge.
            guard let self, let vc else { return }
            // A shell that's still settling (integration line echoing, first prompt painting)
            // is producing plumbing, not output anyone needs to come back for — spam-opening
            // tabs used to light the badge purely from the previous tabs' startup noise.
            guard vc.startupSettled else { return }
            for (key, var sessionList) in self.sessionsByTrackKey {
                guard let index = sessionList.firstIndex(where: { $0.viewController === vc }) else { continue }
                let isCurrentlyVisible = key == (self.currentTrackKey ?? "") && index == self.activeSessionIndexByTrackKey[key]
                guard !isCurrentlyVisible else { return }
                sessionList[index].hasUnseenOutput = true
                self.sessionsByTrackKey[key] = sessionList
                if key == (self.currentTrackKey ?? "") { self.refreshChip(for: vc) }
                self.onActivityChanged?()
                return
            }
        }
        vc.onFileLinkRequested = { [weak self] link in self?.handleFileLink(link) ?? false }
    }

    private func refreshChip(for vc: TerminalViewController) {
        guard let index = sessions.firstIndex(where: { $0.viewController === vc }), tabChips.indices.contains(index) else { return }
        tabChips[index].isDead = !sessions[index].viewController.isAlive
        tabChips[index].hasUnseenOutput = sessions[index].hasUnseenOutput
    }

    // MARK: - Tab bar

    private var lastKnownSessionCount = 0

    private func rebuildTabBar() {
        let previousCount = lastKnownSessionCount
        lastKnownSessionCount = sessions.count
        tabBarStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        tabChips.removeAll()
        let showBar = sessions.count > 1
        tabBar.isHidden = !showBar
        tabBarHeightConstraint.constant = showBar ? TabChipView.height : 0
        guard showBar else { return }
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
        guard tabChips.indices.contains(index), sessions.count > 2 else { completion(); return }
        let chip = tabChips[index]
        let widthConstraint = chip.widthAnchor.constraint(equalToConstant: chip.frame.width)
        widthConstraint.isActive = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
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
        let movedSession = sessions.remove(at: draggedIndex)
        sessions.insert(movedSession, at: dropIndex)
        tabChips.remove(at: draggedIndex)
        tabChips.insert(chip, at: dropIndex)
        tabBarStack.removeArrangedSubview(chip)
        tabBarStack.insertArrangedSubview(chip, at: dropIndex)
        if let activeID { activeSessionIndex = sessions.firstIndex(where: { $0.id == activeID }) }
        reindexTabChips()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
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
