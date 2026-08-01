import AppKit

private struct RunSession {
    let id = UUID()
    var label: String
    var viewController: TerminalViewController
    var hasUnseenOutput = false
}

final class RunWorkspaceViewController: NSViewController {
    private var sessions: [RunSession] = []
    private var activeSessionIndex: Int?
    private let tabBar = NSView()
    private let tabBarStack = NSStackView()
    private var tabBarHeightConstraint: NSLayoutConstraint!
    private let container = NSView()
    private var tabChips: [TabChipView] = []

    /// Only used as the cwd for *new* sessions — existing sessions keep whatever directory
    /// they're actually in, the same way a new terminal in a real IDE defaults to the project
    /// root without moving already-open ones.
    var defaultWorkingDirectory: String?
    var onActivityChanged: (() -> Void)?
    var onOpenFileRequested: ((URL, Int?) -> Void)?

    var hasBackgroundActivity: Bool { sessions.contains { $0.hasUnseenOutput } }

    override func loadView() { view = NSView() }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildView()
    }

    private func buildView() {
        view.wantsLayer = true
        ChromeBackground.install(in: view)

        tabBar.wantsLayer = true
        ChromeBackground.install(in: tabBar)
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.clipsToBounds = true
        tabBarStack.orientation = .horizontal
        tabBarStack.alignment = .centerY
        tabBarStack.spacing = 4
        tabBarStack.translatesAutoresizingMaskIntoConstraints = false
        tabBar.addSubview(tabBarStack)

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        tabBar.addSubview(divider)

        view.addSubview(tabBar)
        container.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(container)

        tabBarHeightConstraint = tabBar.heightAnchor.constraint(equalToConstant: 30)
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: view.topAnchor), tabBar.leadingAnchor.constraint(equalTo: view.leadingAnchor), tabBar.trailingAnchor.constraint(equalTo: view.trailingAnchor), tabBarHeightConstraint,
            tabBarStack.leadingAnchor.constraint(equalTo: tabBar.leadingAnchor, constant: 10), tabBarStack.centerYAnchor.constraint(equalTo: tabBar.centerYAnchor), tabBarStack.trailingAnchor.constraint(lessThanOrEqualTo: tabBar.trailingAnchor, constant: -10),
            divider.leadingAnchor.constraint(equalTo: tabBar.leadingAnchor), divider.trailingAnchor.constraint(equalTo: tabBar.trailingAnchor), divider.bottomAnchor.constraint(equalTo: tabBar.bottomAnchor),
            container.topAnchor.constraint(equalTo: tabBar.bottomAnchor), container.leadingAnchor.constraint(equalTo: view.leadingAnchor), container.trailingAnchor.constraint(equalTo: view.trailingAnchor), container.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    /// Called every time the Run stage becomes visible — starts the first session lazily
    /// (mirrors the old single-terminal activate() behavior) or just refocuses.
    func activateActiveSession() {
        guard let index = activeSessionIndex, sessions.indices.contains(index) else {
            createSession()
            return
        }
        sessions[index].viewController.activate()
        clearUnseenOutput(at: index)
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
        for session in sessions { session.viewController.prepareForClose() }
    }

    // MARK: - Session lifecycle

    private func createSession(replacing index: Int? = nil) {
        let vc = TerminalViewController()
        vc.workingDirectory = defaultWorkingDirectory
        wire(vc)
        let label = defaultWorkingDirectory.map { ($0 as NSString).lastPathComponent } ?? "Terminal"
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
        sessions[index].viewController.prepareForClose()
        sessions.remove(at: index)
        if sessions.isEmpty {
            // Run always has at least one session — no empty state to design for.
            createSession()
            return
        }
        activeSessionIndex = min(index, sessions.count - 1)
        rebuildTabBar()
        showActiveSession()
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
        for child in children {
            child.view.removeFromSuperview()
            child.removeFromParent()
        }
        let vc = sessions[index].viewController
        addChild(vc)
        vc.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(vc.view)
        NSLayoutConstraint.activate([
            vc.view.topAnchor.constraint(equalTo: container.topAnchor), vc.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            vc.view.trailingAnchor.constraint(equalTo: container.trailingAnchor), vc.view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
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
            guard let self, let vc, let index = self.sessions.firstIndex(where: { $0.viewController === vc }) else { return }
            guard index != self.activeSessionIndex else { return }
            self.sessions[index].hasUnseenOutput = true
            self.refreshChip(for: vc)
            self.onActivityChanged?()
        }
        vc.onFileLinkRequested = { [weak self] link in self?.handleFileLink(link) ?? false }
    }

    private func refreshChip(for vc: TerminalViewController) {
        guard let index = sessions.firstIndex(where: { $0.viewController === vc }), tabChips.indices.contains(index) else { return }
        tabChips[index].isDead = !sessions[index].viewController.isAlive
        tabChips[index].hasUnseenOutput = sessions[index].hasUnseenOutput
    }

    // MARK: - Tab bar

    private func rebuildTabBar() {
        tabBarStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        tabChips.removeAll()
        let showBar = sessions.count > 1
        tabBar.isHidden = !showBar
        tabBarHeightConstraint.constant = showBar ? 30 : 0
        guard showBar else { return }
        for (index, session) in sessions.enumerated() {
            let chip = TabChipView()
            chip.index = index
            chip.isActive = index == activeSessionIndex
            chip.title = session.label
            chip.isDead = !session.viewController.isAlive
            chip.hasUnseenOutput = session.hasUnseenOutput
            chip.translatesAutoresizingMaskIntoConstraints = false
            chip.heightAnchor.constraint(equalToConstant: 24).isActive = true
            chip.onSelect = { [weak self] i in self?.switchToSession(i) }
            chip.onDragging = { [weak self, weak chip] windowX in
                guard let self, let chip else { return }
                self.handleTabDragging(chip, toWindowX: windowX)
            }

            let closeButton = TabCloseButton(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
            closeButton.tag = index
            closeButton.target = self
            closeButton.action = #selector(closeSessionButton(_:))
            closeButton.translatesAutoresizingMaskIntoConstraints = false
            closeButton.isHidden = true
            chip.addSubview(closeButton)
            chip.closeButton = closeButton
            NSLayoutConstraint.activate([
                closeButton.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -5), closeButton.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
                closeButton.widthAnchor.constraint(equalToConstant: 16), closeButton.heightAnchor.constraint(equalToConstant: 16)
            ])

            tabBarStack.addArrangedSubview(chip)
            tabChips.append(chip)
        }
    }

    @objc private func closeSessionButton(_ sender: NSButton) { closeSession(at: sender.tag) }

    private func handleTabDragging(_ chip: TabChipView, toWindowX x: CGFloat) {
        guard let draggedIndex = tabChips.firstIndex(where: { $0 === chip }) else { return }
        var dropIndex = draggedIndex
        for (i, sibling) in tabChips.enumerated() where sibling !== chip {
            let siblingMidXInWindow = sibling.convert(NSPoint(x: sibling.bounds.midX, y: 0), to: nil).x
            if x > siblingMidXInWindow { dropIndex = i }
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
