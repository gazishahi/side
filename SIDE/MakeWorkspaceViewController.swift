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
            editorScroll.topAnchor.constraint(equalTo: tabBar.bottomAnchor), editorScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), editorScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor), editorScroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
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
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true
        effect.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: effect.topAnchor, constant: 6), scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -6)
        ])
        quickOpenPanel.contentView = effect
    }

    private func showQuickOpenPanel() {
        guard let window = searchField.window else { return }
        let visibleRows = max(1, min(quickOpenMaxVisibleRows, matches.count))
        let height = CGFloat(visibleRows) * quickOpenRowHeight + 12
        let fieldFrameInWindow = searchField.convert(searchField.bounds, to: nil)
        let fieldFrameOnScreen = window.convertToScreen(fieldFrameInWindow)
        let panelFrame = NSRect(x: fieldFrameOnScreen.minX, y: fieldFrameOnScreen.minY - height - 6, width: max(fieldFrameOnScreen.width, 420), height: height)
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
        let fullRange = NSRange(location: 0, length: (editor.string as NSString).length)
        editor.textStorage?.addAttributes([.foregroundColor: Self.editorTextColor, .font: Self.editorFont], range: fullRange)
        editor.isEditable = true
        editorScroll.isHidden = false
        dirty = tab.dirty
        rebuildTabBar()
        onFileOpened?(tab.url)
    }

    @objc private func selectTab(_ sender: NSButton) {
        let index = sender.tag
        guard openTabs.indices.contains(index), index != activeTabIndex else { return }
        persistActiveTabEdits()
        activeTabIndex = index
        loadActiveTabIntoEditor()
        UserDefaults.standard.set(openTabs[index].url.path, forKey: lastFileKey)
        view.window?.makeFirstResponder(editor)
    }

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
            dirty = false
            UserDefaults.standard.removeObject(forKey: lastFileKey)
            onFileOpened?(nil)
        } else {
            activeTabIndex = min(index, openTabs.count - 1)
            loadActiveTabIntoEditor()
        }
        rebuildTabBar()
    }

    private func rebuildTabBar() {
        tabBarStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let showBar = openTabs.count > 1
        tabBar.isHidden = !showBar
        tabBarHeightConstraint.constant = showBar ? 30 : 0
        guard showBar else { return }
        for (index, tab) in openTabs.enumerated() {
            tabBarStack.addArrangedSubview(makeTabChip(index: index, tab: tab, isActive: index == activeTabIndex))
        }
    }

    private func makeTabChip(index: Int, tab: OpenTab, isActive: Bool) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 6
        container.layer?.backgroundColor = isActive ? NSColor(calibratedWhite: 0.17, alpha: 1).cgColor : NSColor.clear.cgColor
        container.translatesAutoresizingMaskIntoConstraints = false
        container.heightAnchor.constraint(equalToConstant: 24).isActive = true

        let button = NSButton(title: "", target: self, action: #selector(selectTab(_:)))
        button.tag = index
        button.isBordered = false
        button.imagePosition = .noImage
        let title = tab.dirty ? "\(tab.url.lastPathComponent) •" : tab.url.lastPathComponent
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: isActive ? NSColor(calibratedWhite: 0.92, alpha: 1) : NSColor(calibratedWhite: 0.55, alpha: 1),
            .font: NSFont.systemFont(ofSize: 12, weight: isActive ? .semibold : .regular)
        ])
        button.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12), button.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            button.topAnchor.constraint(equalTo: container.topAnchor), button.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        let menu = NSMenu()
        let closeItem = menu.addItem(withTitle: "Close Tab", action: #selector(closeTabFromMenu(_:)), keyEquivalent: "")
        closeItem.tag = index
        closeItem.target = self
        button.menu = menu

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
    func textDidChange(_ notification: Notification) {
        dirty = true
        if let index = activeTabIndex { openTabs[index].dirty = true }
    }

    private func buildMenu() {
        let main = NSMenu(title: "SIDE")
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")
        let openItem = fileMenu.addItem(withTitle: "Open Project…", action: #selector(openProject), keyEquivalent: "o"); openItem.target = self
        let saveItem = fileMenu.addItem(withTitle: "Save", action: #selector(save), keyEquivalent: "s"); saveItem.target = self
        let closeItem = fileMenu.addItem(withTitle: "Close Tab", action: #selector(closeActiveTab), keyEquivalent: "w"); closeItem.target = self
        fileItem.submenu = fileMenu
        let navigateItem = NSMenuItem(title: "Navigate", action: nil, keyEquivalent: "")
        let navigateMenu = NSMenu(title: "Navigate")
        let quickOpen = navigateMenu.addItem(withTitle: "Quick Open", action: #selector(focusQuickOpen), keyEquivalent: "p"); quickOpen.target = self
        navigateItem.submenu = navigateMenu
        main.addItem(fileItem); main.addItem(navigateItem); NSApp.mainMenu = main
    }
    @objc private func focusQuickOpen() { searchField.stringValue = ""; view.window?.makeFirstResponder(searchField); refreshMatches(showingPalette: true) }
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
