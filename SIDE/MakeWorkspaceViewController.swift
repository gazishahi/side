import AppKit

private struct OpenTab {
    let url: URL
    var content: String
    var dirty: Bool
}

final class MakeWorkspaceViewController: NSViewController, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate {
    let searchField = QuickOpenSearchField()
    private let editor = NSTextView()
    private let editorScroll = NSScrollView()
    private var gutter: LineNumberGutterView!
    private let tabBar = NSView()
    private let tabBarStack = NSStackView()
    private var tabBarHeightConstraint: NSLayoutConstraint!
    private let emptyState = NSStackView()
    private let quickOpenPanel = QuickOpenPanel()
    private let resultsTable = NSTableView()
    private var projectURL: URL?
    private var allFiles: [URL] = []
    private var matches: [URL] = []
    private var openTabs: [OpenTab] = []
    private var activeTabIndex: Int?
    private var tabChips: [TabChipView] = []
    private var dirty = false { didSet { onDirtyChanged?(dirty) } }
    var onProjectOpened: ((URL) -> Void)?
    var onFileOpened: ((URL?) -> Void)?
    var onDirtyChanged: ((Bool) -> Void)?
    private let lastProjectKey = "side.last-project-path"
    private let lastFileKey = "side.last-file-path"
    private var pendingSearchWorkItem: DispatchWorkItem?
    private static let editorBackground = NSColor(calibratedWhite: 0.098, alpha: 1)
    private static let editorFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    private static let editorTextColor = NSColor(calibratedWhite: 0.85, alpha: 1)

    override func loadView() { view = NSView() }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildView()
        buildMenu()
        configureQuickOpenKeys()
        DispatchQueue.main.async { [weak self] in self?.restoreLastSession() }
    }

    private func buildView() {
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        searchField.placeholderString = "Open file, symbol, or command"
        searchField.delegate = self

        tabBar.wantsLayer = true
        tabBar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
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
        tabBarHeightConstraint = tabBar.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: view.topAnchor), tabBar.leadingAnchor.constraint(equalTo: view.leadingAnchor), tabBar.trailingAnchor.constraint(equalTo: view.trailingAnchor), tabBarHeightConstraint,
            tabBarStack.leadingAnchor.constraint(equalTo: tabBar.leadingAnchor, constant: 10), tabBarStack.centerYAnchor.constraint(equalTo: tabBar.centerYAnchor), tabBarStack.trailingAnchor.constraint(lessThanOrEqualTo: tabBar.trailingAnchor, constant: -10),
            divider.leadingAnchor.constraint(equalTo: tabBar.leadingAnchor), divider.trailingAnchor.constraint(equalTo: tabBar.trailingAnchor), divider.bottomAnchor.constraint(equalTo: tabBar.bottomAnchor)
        ])

        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextCompletionEnabled = false
        editor.usesFindBar = true
        editor.font = Self.editorFont
        editor.textColor = Self.editorTextColor
        editor.backgroundColor = Self.editorBackground
        editor.insertionPointColor = .controlAccentColor
        editor.textContainerInset = NSSize(width: 16, height: 12)
        editor.delegate = self
        editor.isEditable = false
        editorScroll.documentView = editor
        editorScroll.hasVerticalScroller = true
        editorScroll.autohidesScrollers = true
        editorScroll.drawsBackground = true
        editorScroll.backgroundColor = Self.editorBackground
        editorScroll.isHidden = true
        editorScroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(editorScroll)

        gutter = LineNumberGutterView(textView: editor, scrollView: editorScroll)
        gutter.isHidden = true
        gutter.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(gutter)

        let headline = NSTextField(labelWithString: "Open a project")
        headline.font = .systemFont(ofSize: 25, weight: .medium)
        headline.alignment = .center
        let detail = NSTextField(wrappingLabelWithString: "Start with the code. SIDE will restore this workspace when you come back.")
        detail.font = .systemFont(ofSize: 14)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        detail.maximumNumberOfLines = 2
        let open = NSButton(title: "Open project…", target: self, action: #selector(openProject))
        open.bezelStyle = .rounded
        open.controlSize = .large
        emptyState.orientation = .vertical
        emptyState.alignment = .centerX
        emptyState.spacing = 13
        [headline, detail, open].forEach(emptyState.addArrangedSubview)
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyState)

        NSLayoutConstraint.activate([
            gutter.topAnchor.constraint(equalTo: tabBar.bottomAnchor), gutter.leadingAnchor.constraint(equalTo: view.leadingAnchor), gutter.bottomAnchor.constraint(equalTo: view.bottomAnchor), gutter.widthAnchor.constraint(equalToConstant: LineNumberGutterView.width),
            editorScroll.topAnchor.constraint(equalTo: tabBar.bottomAnchor), editorScroll.leadingAnchor.constraint(equalTo: gutter.trailingAnchor), editorScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor), editorScroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            emptyState.centerXAnchor.constraint(equalTo: view.centerXAnchor), emptyState.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -30), detail.widthAnchor.constraint(lessThanOrEqualToConstant: 460)
        ])
        configureQuickOpenPanel()
    }

    private func configureQuickOpenKeys() {
        searchField.onMove = { [weak self] direction in self?.moveSelection(direction) }
        searchField.onConfirm = { [weak self] in self?.confirmSearch() }
        searchField.onCancel = { [weak self] in self?.dismissQuickOpen() }
    }

    private let quickOpenRowHeight: CGFloat = 30
    private let quickOpenMaxVisibleRows = 8

    private func configureQuickOpenPanel() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("path"))
        resultsTable.addTableColumn(column)
        resultsTable.headerView = nil
        resultsTable.rowHeight = quickOpenRowHeight
        resultsTable.intercellSpacing = NSSize(width: 0, height: 0)
        resultsTable.backgroundColor = .clear
        resultsTable.selectionHighlightStyle = .regular
        resultsTable.dataSource = self
        resultsTable.delegate = self
        resultsTable.target = self
        resultsTable.doubleAction = #selector(openSelectedResult)

        let scroll = NSScrollView()
        scroll.documentView = resultsTable
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.state = .active
        effect.blendingMode = .withinWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 8
        effect.layer?.masksToBounds = true
        effect.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: effect.topAnchor, constant: 10), scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -10)
        ])
        quickOpenPanel.contentView = effect
    }

    private func showQuickOpenPanel() {
        guard let window = searchField.window else { return }
        let visibleRows = max(1, min(quickOpenMaxVisibleRows, matches.count))
        let height = CGFloat(visibleRows) * quickOpenRowHeight + 20
        let fieldFrameInWindow = searchField.convert(searchField.bounds, to: nil)
        let fieldFrameOnScreen = window.convertToScreen(fieldFrameInWindow)
        let width = max(fieldFrameOnScreen.width, 420)

        var x = fieldFrameOnScreen.minX
        let windowFrame = window.frame
        if x + width > windowFrame.maxX - 12 { x = windowFrame.maxX - width - 12 }
        if x < windowFrame.minX + 12 { x = windowFrame.minX + 12 }

        let panelFrame = NSRect(x: x, y: fieldFrameOnScreen.minY - height - 6, width: width, height: height)
        quickOpenPanel.setFrame(panelFrame, display: true)
        if quickOpenPanel.parent == nil {
            window.addChildWindow(quickOpenPanel, ordered: .above)
        }
        quickOpenPanel.orderFront(nil)
    }

    private func hideQuickOpenPanel() {
        guard quickOpenPanel.isVisible || quickOpenPanel.parent != nil else { return }
        searchField.window?.removeChildWindow(quickOpenPanel)
        quickOpenPanel.orderOut(nil)
    }

    @objc private func openProject() {
        let panel = NSOpenPanel()
        panel.message = "Choose a project to open in SIDE"
        panel.prompt = "Open project"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: view.window!) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.loadProject(at: url, restoring: false)
        }
    }

    private func loadProject(at url: URL, restoring: Bool) {
        projectURL = url
        searchField.placeholderString = "Indexing \(url.lastPathComponent)…"
        emptyState.isHidden = true
        UserDefaults.standard.set(url.path, forKey: lastProjectKey)
        onProjectOpened?(url)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let indexed = Self.indexFiles(at: url)
            DispatchQueue.main.async {
                guard let self, self.projectURL == url else { return }
                self.allFiles = indexed
                self.searchField.placeholderString = "Find a file in \(url.lastPathComponent)"
                if restoring, let saved = UserDefaults.standard.string(forKey: self.lastFileKey), let file = indexed.first(where: { $0.path == saved }) { self.open(file); return }
                if let file = indexed.first(where: { ["swift", "ts", "tsx", "js", "json", "md"].contains($0.pathExtension.lowercased()) }) { self.open(file) }
            }
        }
    }

    private static let maxIndexedFiles = 25000

    nonisolated private static func indexFiles(at root: URL) -> [URL] {
        let ignored: Set<String> = [
            ".git", ".build", "DerivedData", "node_modules", ".next", "Pods", "dist", "build",
            ".venv", "venv", "vendor", "Carthage", "target", "out", ".cache", "coverage",
            "__pycache__", ".tox", ".mypy_cache", ".pytest_cache"
        ]
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else { return [] }
        var indexed: [URL] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: keys)
            if values?.isDirectory == true && ignored.contains(url.lastPathComponent) { enumerator.skipDescendants(); continue }
            if values?.isRegularFile == true && !url.pathExtension.isEmpty { indexed.append(url) }
            if indexed.count >= maxIndexedFiles { break }
        }
        return indexed.sorted {
            let lhs = $0.path.replacingOccurrences(of: root.path + "/", with: "")
            let rhs = $1.path.replacingOccurrences(of: root.path + "/", with: "")
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }

    // MARK: - Tabs

    private func open(_ url: URL) {
        persistActiveTabEdits()
        if let existingIndex = openTabs.firstIndex(where: { $0.url == url }) {
            activeTabIndex = existingIndex
        } else {
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { return }
            openTabs.append(OpenTab(url: url, content: source, dirty: false))
            activeTabIndex = openTabs.count - 1
        }
        loadActiveTabIntoEditor()
        searchField.stringValue = ""
        UserDefaults.standard.set(url.path, forKey: lastFileKey)
        hideQuickOpenPanel()
        view.window?.makeFirstResponder(editor)
    }

    private func persistActiveTabEdits() {
        guard let index = activeTabIndex, openTabs.indices.contains(index) else { return }
        openTabs[index].content = editor.string
        openTabs[index].dirty = dirty
    }

    private func loadActiveTabIntoEditor() {
        guard let index = activeTabIndex, openTabs.indices.contains(index) else { return }
        let tab = openTabs[index]
        editor.string = tab.content
        if let storage = editor.textStorage { SyntaxHighlighter.apply(to: storage, url: tab.url, baseColor: Self.editorTextColor, font: Self.editorFont) }
        editor.isEditable = true
        editorScroll.isHidden = false
        gutter.isHidden = false
        gutter.invalidate()
        dirty = tab.dirty
        rebuildTabBar()
        onFileOpened?(tab.url)
    }

    @objc private func switchToTabShortcut(_ sender: NSMenuItem) {
        let index = sender.tag >= 0 ? sender.tag : openTabs.count - 1
        switchToTab(index)
    }

    private func switchToTab(_ index: Int) {
        guard openTabs.indices.contains(index), index != activeTabIndex else { return }
        persistActiveTabEdits()
        activeTabIndex = index
        loadActiveTabIntoEditor()
        UserDefaults.standard.set(openTabs[index].url.path, forKey: lastFileKey)
        view.window?.makeFirstResponder(editor)
    }

    @objc private func closeTabButton(_ sender: NSButton) { closeTab(at: sender.tag) }
    @objc private func closeTabFromMenu(_ sender: NSMenuItem) { closeTab(at: sender.tag) }
    @objc private func closeActiveTab() { guard let index = activeTabIndex else { return }; closeTab(at: index) }

    private func closeTab(at index: Int) {
        guard openTabs.indices.contains(index) else { return }
        openTabs.remove(at: index)
        if openTabs.isEmpty {
            activeTabIndex = nil
            editor.string = ""
            editor.isEditable = false
            editorScroll.isHidden = true
            gutter.isHidden = true
            dirty = false
            UserDefaults.standard.removeObject(forKey: lastFileKey)
            onFileOpened?(nil)
        } else {
            activeTabIndex = min(index, openTabs.count - 1)
            loadActiveTabIntoEditor()
        }
        rebuildTabBar()
    }

    private func handleTabDragging(_ chip: TabChipView, toWindowX x: CGFloat) {
        guard let draggedIndex = tabChips.firstIndex(where: { $0 === chip }) else { return }
        var dropIndex = draggedIndex
        for (i, sibling) in tabChips.enumerated() where sibling !== chip {
            let siblingMidXInWindow = sibling.convert(NSPoint(x: sibling.bounds.midX, y: 0), to: nil).x
            if x > siblingMidXInWindow { dropIndex = i }
        }
        guard dropIndex != draggedIndex else { return }

        let activeURL = activeTabIndex.flatMap { openTabs.indices.contains($0) ? openTabs[$0].url : nil }
        let movedTab = openTabs.remove(at: draggedIndex)
        openTabs.insert(movedTab, at: dropIndex)
        tabChips.remove(at: draggedIndex)
        tabChips.insert(chip, at: dropIndex)
        tabBarStack.removeArrangedSubview(chip)
        tabBarStack.insertArrangedSubview(chip, at: dropIndex)
        if let activeURL { activeTabIndex = openTabs.firstIndex(where: { $0.url == activeURL }) }
        reindexTabChips()
        tabBarStack.layoutSubtreeIfNeeded()
    }

    private func reindexTabChips() {
        for (i, chip) in tabChips.enumerated() {
            chip.index = i
            chip.isActive = (i == activeTabIndex)
            chip.closeButton?.tag = i
            chip.closeMenuItem?.tag = i
        }
    }

    private func rebuildTabBar() {
        tabBarStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        tabChips.removeAll()
        let showBar = openTabs.count > 1
        tabBar.isHidden = !showBar
        tabBarHeightConstraint.constant = showBar ? 30 : 0
        guard showBar else { return }
        for (index, tab) in openTabs.enumerated() {
            let chip = makeTabChip(index: index, tab: tab, isActive: index == activeTabIndex)
            tabBarStack.addArrangedSubview(chip)
            tabChips.append(chip)
        }
    }

    private func makeTabChip(index: Int, tab: OpenTab, isActive: Bool) -> TabChipView {
        let container = TabChipView()
        container.index = index
        container.isActive = isActive
        container.title = tab.dirty ? "\(tab.url.lastPathComponent) •" : tab.url.lastPathComponent
        container.toolTip = relativePath(tab.url)
        container.translatesAutoresizingMaskIntoConstraints = false
        container.heightAnchor.constraint(equalToConstant: 24).isActive = true
        container.onSelect = { [weak self] i in self?.switchToTab(i) }
        container.onDragging = { [weak self, weak container] windowX in
            guard let self, let container else { return }
            self.handleTabDragging(container, toWindowX: windowX)
        }

        let closeButton = TabCloseButton(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        closeButton.tag = index
        closeButton.target = self
        closeButton.action = #selector(closeTabButton(_:))
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.isHidden = true
        container.addSubview(closeButton)
        container.closeButton = closeButton
        NSLayoutConstraint.activate([
            closeButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -5), closeButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16), closeButton.heightAnchor.constraint(equalToConstant: 16)
        ])

        let menu = NSMenu()
        let closeItem = menu.addItem(withTitle: "Close Tab", action: #selector(closeTabFromMenu(_:)), keyEquivalent: "")
        closeItem.tag = index
        closeItem.target = self
        container.closeMenuItem = closeItem
        container.menu = menu

        return container
    }

    private func relativePath(_ url: URL) -> String {
        guard let projectURL else { return url.path }
        return url.path.replacingOccurrences(of: projectURL.path + "/", with: "")
    }

    // MARK: - Search

    func controlTextDidBeginEditing(_ obj: Notification) { scheduleRefreshMatches() }
    func controlTextDidChange(_ obj: Notification) { scheduleRefreshMatches() }

    private func scheduleRefreshMatches() {
        pendingSearchWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.refreshMatches(showingPalette: true) }
        pendingSearchWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: workItem)
    }

    private func refreshMatches(showingPalette: Bool) {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard projectURL != nil else { hideQuickOpenPanel(); return }
        matches = allFiles.filter { query.isEmpty || relativePath($0).localizedCaseInsensitiveContains(query) }.prefix(30).map { $0 }
        resultsTable.reloadData()
        if !matches.isEmpty { resultsTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        if !matches.isEmpty && showingPalette { showQuickOpenPanel() } else { hideQuickOpenPanel() }
    }
    @objc private func confirmSearch() {
        let selected = resultsTable.selectedRow
        if selected >= 0 && selected < matches.count { open(matches[selected]) }
        else if let first = matches.first { open(first) }
    }
    @objc private func openSelectedResult() { confirmSearch() }
    private func dismissQuickOpen() { hideQuickOpenPanel(); view.window?.makeFirstResponder(editor) }
    private func moveSelection(_ direction: Int) {
        guard !matches.isEmpty else { return }
        let next = max(0, min(matches.count - 1, resultsTable.selectedRow + direction))
        resultsTable.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        resultsTable.scrollRowToVisible(next)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { matches.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("result")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? NSTableCellView()
        cell.identifier = id
        let text = cell.textField ?? NSTextField(labelWithString: "")
        if cell.textField == nil {
            cell.textField = text
            text.translatesAutoresizingMaskIntoConstraints = false
            text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            text.lineBreakMode = .byTruncatingMiddle
            cell.addSubview(text)
            NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12), text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -12), text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        }
        text.stringValue = relativePath(matches[row])
        return cell
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === searchField else { return false }
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            confirmSearch()
            return true
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(-1)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            dismissQuickOpen()
            return true
        default:
            return false
        }
    }
    private var pendingHighlightWorkItem: DispatchWorkItem?
    func textDidChange(_ notification: Notification) {
        dirty = true
        if let index = activeTabIndex { openTabs[index].dirty = true }
        gutter.invalidate()
        scheduleHighlight()
    }

    private func scheduleHighlight() {
        pendingHighlightWorkItem?.cancel()
        guard let index = activeTabIndex else { return }
        let url = openTabs[index].url
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, let storage = self.editor.textStorage else { return }
            SyntaxHighlighter.apply(to: storage, url: url, baseColor: Self.editorTextColor, font: Self.editorFont)
        }
        pendingHighlightWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }

    private func buildMenu() {
        let main = NSMenu(title: "SIDE")
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")
        let openItem = fileMenu.addItem(withTitle: "Open Project…", action: #selector(openProject), keyEquivalent: "o"); openItem.target = self
        let saveItem = fileMenu.addItem(withTitle: "Save", action: #selector(save), keyEquivalent: "s"); saveItem.target = self
        let closeItem = fileMenu.addItem(withTitle: "Close Tab", action: #selector(closeActiveTab), keyEquivalent: "w"); closeItem.target = self
        fileItem.submenu = fileMenu

        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        let find = editMenu.addItem(withTitle: "Find…", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f")
        find.tag = NSTextFinder.Action.showFindInterface.rawValue
        let findReplace = editMenu.addItem(withTitle: "Find and Replace…", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f")
        findReplace.keyEquivalentModifierMask = [.command, .option]
        findReplace.tag = NSTextFinder.Action.showReplaceInterface.rawValue
        let findNext = editMenu.addItem(withTitle: "Find Next", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "g")
        findNext.tag = NSTextFinder.Action.nextMatch.rawValue
        let findPrevious = editMenu.addItem(withTitle: "Find Previous", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "g")
        findPrevious.keyEquivalentModifierMask = [.command, .shift]
        findPrevious.tag = NSTextFinder.Action.previousMatch.rawValue
        editItem.submenu = editMenu

        let navigateItem = NSMenuItem(title: "Navigate", action: nil, keyEquivalent: "")
        let navigateMenu = NSMenu(title: "Navigate")
        let quickOpen = navigateMenu.addItem(withTitle: "Quick Open", action: #selector(focusQuickOpen), keyEquivalent: "p"); quickOpen.target = self
        let goToLine = navigateMenu.addItem(withTitle: "Go to Line…", action: #selector(showGoToLine), keyEquivalent: "l"); goToLine.target = self
        navigateMenu.addItem(NSMenuItem.separator())
        for i in 1...8 {
            let item = navigateMenu.addItem(withTitle: "Switch to Tab \(i)", action: #selector(switchToTabShortcut(_:)), keyEquivalent: "\(i)")
            item.tag = i - 1
            item.target = self
        }
        let lastTab = navigateMenu.addItem(withTitle: "Switch to Last Tab", action: #selector(switchToTabShortcut(_:)), keyEquivalent: "9")
        lastTab.tag = -1
        lastTab.target = self
        navigateItem.submenu = navigateMenu
        main.addItem(fileItem); main.addItem(editItem); main.addItem(navigateItem); NSApp.mainMenu = main
    }
    @objc private func focusQuickOpen() { searchField.stringValue = ""; view.window?.makeFirstResponder(searchField); refreshMatches(showingPalette: true) }
    @objc private func showGoToLine() {
        guard let window = view.window, activeTabIndex != nil else { return }
        let alert = NSAlert()
        alert.messageText = "Go to Line"
        alert.informativeText = "Enter a line number to jump to."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.placeholderString = "Line number"
        alert.accessoryView = field
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, let line = Int(field.stringValue) else { return }
            self.scrollToLine(line)
        }
    }
    private func scrollToLine(_ line: Int) {
        let text = editor.string as NSString
        var currentLine = 1
        var index = 0
        while currentLine < max(1, line) && index < text.length {
            let lineRange = text.lineRange(for: NSRange(location: index, length: 0))
            index = NSMaxRange(lineRange)
            currentLine += 1
        }
        let targetRange = text.lineRange(for: NSRange(location: min(index, text.length), length: 0))
        editor.scrollRangeToVisible(targetRange)
        editor.setSelectedRange(targetRange)
        view.window?.makeFirstResponder(editor)
    }
    @objc private func save() {
        guard let index = activeTabIndex else { return }
        let tab = openTabs[index]
        try? editor.string.write(to: tab.url, atomically: true, encoding: .utf8)
        openTabs[index].content = editor.string
        openTabs[index].dirty = false
        dirty = false
        rebuildTabBar()
    }
    private func restoreLastSession() { guard let saved = UserDefaults.standard.string(forKey: lastProjectKey) else { return }; let url = URL(fileURLWithPath: saved); var isDirectory: ObjCBool = false; guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return }; loadProject(at: url, restoring: true) }
}

final class QuickOpenPanel: NSPanel {
    convenience init() {
        self.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class TabChipView: NSView {
    weak var closeButton: NSButton?
    weak var closeMenuItem: NSMenuItem?
    var index: Int = 0
    var onSelect: ((Int) -> Void)?
    var onDragging: ((CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?
    var title: String = "" { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var isActive: Bool = false { didSet { needsDisplay = true } }

    private static let textInset: CGFloat = 12
    private static let trailingReserve: CGFloat = 26
    private static let maxTextWidth: CGFloat = 200

    private var trackingArea: NSTrackingArea?
    private var dragOrigin: NSPoint?
    private var didDrag = false

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        let font = NSFont.systemFont(ofSize: 12, weight: isActive ? .semibold : .regular)
        let textWidth = min((title as NSString).size(withAttributes: [.font: font]).width, Self.maxTextWidth)
        return NSSize(width: textWidth + Self.textInset + Self.trailingReserve, height: 24)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { closeButton?.isHidden = false }
    override func mouseExited(with event: NSEvent) { closeButton?.isHidden = true }

    override func draw(_ dirtyRect: NSRect) {
        let background = isActive ? NSColor(calibratedWhite: 0.17, alpha: 1) : NSColor.clear
        background.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: isActive ? NSColor(calibratedWhite: 0.92, alpha: 1) : NSColor(calibratedWhite: 0.55, alpha: 1),
            .font: NSFont.systemFont(ofSize: 12, weight: isActive ? .semibold : .regular)
        ]
        let text = title as NSString
        let size = text.size(withAttributes: attributes)
        let maxWidth = max(0, bounds.width - Self.textInset - Self.trailingReserve)
        let drawRect = NSRect(x: Self.textInset, y: (bounds.height - size.height) / 2, width: min(size.width, maxWidth) + 1, height: size.height)
        text.draw(in: drawRect, withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {
        dragOrigin = event.locationInWindow
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragOrigin else { return }
        let dx = event.locationInWindow.x - dragOrigin.x
        if abs(dx) > 4 { didDrag = true }
        guard didDrag else { return }
        onDragging?(event.locationInWindow.x)
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragOrigin = nil }
        guard dragOrigin != nil else { return }
        if didDrag {
            onDragEnded?()
        } else {
            onSelect?(index)
        }
    }
}

final class TabCloseButton: NSButton {
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        isBordered = false
        imagePosition = .imageOnly
        let config = NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold)
        image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")?.withSymbolConfiguration(config)
        contentTintColor = NSColor(calibratedWhite: 0.62, alpha: 1)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.16).cgColor }
    override func mouseExited(with event: NSEvent) { layer?.backgroundColor = NSColor.clear.cgColor }
}

final class QuickOpenSearchField: NSSearchField {
    var onMove: ((Int) -> Void)?
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125: onMove?(1)
        case 126: onMove?(-1)
        case 36: onConfirm?()
        case 53: onCancel?()
        default: super.keyDown(with: event)
        }
    }
}
