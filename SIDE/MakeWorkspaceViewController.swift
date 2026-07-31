import AppKit

private struct OpenTab {
    let url: URL
    let textStorage: NSTextStorage
    let undoManager: UndoManager
    var dirty: Bool
}

private struct IndexedFile {
    let url: URL
    let relativePath: String
}

final class MakeWorkspaceViewController: NSViewController, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let searchField = QuickOpenSearchField()
    private let editor = EditorTextView()
    private let editorScroll = NSScrollView()
    private var gutter: LineNumberGutterView!
    private let tabBar = NSView()
    private let tabBarStack = NSStackView()
    private var tabBarHeightConstraint: NSLayoutConstraint!
    private let emptyState = NSStackView()
    private let quickOpenPanel = QuickOpenPanel()
    private let resultsTable = NSTableView()
    private let fileExplorerPanel = FileExplorerPanel()
    private let fileExplorerOutline = ExplorerOutlineView()
    private var fileTreeRoots: [FileTreeNode] = []
    private var quickOpenLocalMonitor: Any?
    private var quickOpenGlobalMonitor: Any?
    private var fileExplorerLocalMonitor: Any?
    private var fileExplorerGlobalMonitor: Any?
    private var projectURL: URL?
    private var allFiles: [IndexedFile] = []
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
    private var searchGeneration = 0
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
        editor.isIncrementalSearchingEnabled = true
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
        configureFileExplorerPanel()
    }

    private func configureQuickOpenKeys() {
        searchField.onMove = { [weak self] direction in self?.moveSelection(direction) }
        searchField.onConfirm = { [weak self] in self?.confirmSearch() }
        searchField.onCancel = { [weak self] in self?.dismissQuickOpen() }
    }

    private let quickOpenRowHeight: CGFloat = 34
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
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
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
            scroll.topAnchor.constraint(equalTo: effect.topAnchor, constant: 14), scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -14)
        ])
        quickOpenPanel.contentView = effect
    }

    private func showQuickOpenPanel() {
        guard let window = searchField.window else { return }
        let visibleRows = max(1, min(quickOpenMaxVisibleRows, matches.count))
        let height = CGFloat(visibleRows) * quickOpenRowHeight + 28
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
        installQuickOpenDismissMonitors()
    }

    private func hideQuickOpenPanel() {
        removeQuickOpenDismissMonitors()
        guard quickOpenPanel.isVisible || quickOpenPanel.parent != nil else { return }
        searchField.window?.removeChildWindow(quickOpenPanel)
        quickOpenPanel.orderOut(nil)
    }

    private func installQuickOpenDismissMonitors() {
        guard quickOpenLocalMonitor == nil else { return }
        quickOpenLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.dismissQuickOpenIfClickOutside()
            return event
        }
        quickOpenGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hideQuickOpenPanel()
        }
    }

    private func removeQuickOpenDismissMonitors() {
        if let m = quickOpenLocalMonitor { NSEvent.removeMonitor(m); quickOpenLocalMonitor = nil }
        if let m = quickOpenGlobalMonitor { NSEvent.removeMonitor(m); quickOpenGlobalMonitor = nil }
    }

    private func dismissQuickOpenIfClickOutside() {
        let point = NSEvent.mouseLocation
        if quickOpenPanel.frame.insetBy(dx: -2, dy: -2).contains(point) { return }
        if let window = searchField.window {
            let searchFieldFrame = window.convertToScreen(searchField.convert(searchField.bounds, to: nil))
            if searchFieldFrame.insetBy(dx: -4, dy: -4).contains(point) { return }
        }
        hideQuickOpenPanel()
    }

    // MARK: - File explorer

    private func configureFileExplorerPanel() {
        fileExplorerOutline.headerView = nil
        fileExplorerOutline.backgroundColor = .clear
        fileExplorerOutline.dataSource = self
        fileExplorerOutline.delegate = self
        fileExplorerOutline.indentationPerLevel = 14
        fileExplorerOutline.doubleAction = #selector(openSelectedTreeItem)
        fileExplorerOutline.target = self
        fileExplorerOutline.onEscape = { [weak self] in self?.hideFileExplorer() }
        fileExplorerOutline.onEnter = { [weak self] in self?.openSelectedTreeItem() }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.width = 260
        fileExplorerOutline.addTableColumn(column)
        fileExplorerOutline.outlineTableColumn = column

        let scroll = NSScrollView()
        scroll.documentView = fileExplorerOutline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.state = .active
        effect.blendingMode = .withinWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true
        effect.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: effect.topAnchor, constant: 10), scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -4), scroll.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -10)
        ])
        fileExplorerPanel.contentView = effect
    }

    @objc private func toggleFileExplorer() {
        if fileExplorerPanel.isVisible {
            hideFileExplorer()
            return
        }
        guard let window = view.window, let root = projectURL else { return }
        let files = allFiles
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let tree = Self.buildFileTree(from: files, root: root)
            DispatchQueue.main.async {
                guard let self, self.projectURL == root else { return }
                self.fileTreeRoots = tree
                self.fileExplorerOutline.reloadData()
                self.showFileExplorer(in: window)
            }
        }
    }

    private static let fileExplorerWidth: CGFloat = 280
    private static let fileExplorerTopMargin: CGFloat = 90
    private static let fileExplorerBottomMargin: CGFloat = 20
    private static let fileExplorerTrailingMargin: CGFloat = 14

    private func showFileExplorer(in window: NSWindow) {
        let windowFrame = window.frame
        let width = Self.fileExplorerWidth
        let height = windowFrame.height - Self.fileExplorerTopMargin - Self.fileExplorerBottomMargin
        let targetX = windowFrame.maxX - width - Self.fileExplorerTrailingMargin
        let y = windowFrame.minY + Self.fileExplorerBottomMargin
        let startFrame = NSRect(x: windowFrame.maxX, y: y, width: width, height: height)
        let targetFrame = NSRect(x: targetX, y: y, width: width, height: height)

        fileExplorerPanel.setFrame(startFrame, display: false)
        if fileExplorerPanel.parent == nil { window.addChildWindow(fileExplorerPanel, ordered: .above) }
        fileExplorerPanel.orderFront(nil)
        installFileExplorerDismissMonitors()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            fileExplorerPanel.animator().setFrame(targetFrame, display: true)
        } completionHandler: { [weak self] in
            guard let self else { return }
            self.fileExplorerPanel.makeKey()
            self.fileExplorerPanel.makeFirstResponder(self.fileExplorerOutline)
        }
    }

    private func installFileExplorerDismissMonitors() {
        guard fileExplorerLocalMonitor == nil else { return }
        fileExplorerLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.dismissFileExplorerIfClickOutside()
            return event
        }
        fileExplorerGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hideFileExplorer()
        }
    }

    private func removeFileExplorerDismissMonitors() {
        if let m = fileExplorerLocalMonitor { NSEvent.removeMonitor(m); fileExplorerLocalMonitor = nil }
        if let m = fileExplorerGlobalMonitor { NSEvent.removeMonitor(m); fileExplorerGlobalMonitor = nil }
    }

    private func dismissFileExplorerIfClickOutside() {
        let point = NSEvent.mouseLocation
        if fileExplorerPanel.frame.insetBy(dx: -2, dy: -2).contains(point) { return }
        hideFileExplorer()
    }

    private func hideFileExplorer() {
        removeFileExplorerDismissMonitors()
        guard let window = view.window, fileExplorerPanel.isVisible else { return }
        var endFrame = fileExplorerPanel.frame
        endFrame.origin.x = window.frame.maxX
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            fileExplorerPanel.animator().setFrame(endFrame, display: true)
        } completionHandler: { [weak self] in
            guard let self else { return }
            self.view.window?.removeChildWindow(self.fileExplorerPanel)
            self.fileExplorerPanel.orderOut(nil)
        }
        view.window?.makeFirstResponder(editor)
    }

    nonisolated private static func buildFileTree(from files: [IndexedFile], root: URL) -> [FileTreeNode] {
        var roots: [FileTreeNode] = []
        var directoryLookup: [String: FileTreeNode] = [:]

        for file in files {
            let components = file.relativePath.components(separatedBy: "/")
            var parentNode: FileTreeNode?
            var accumulatedPath = ""
            for (i, component) in components.enumerated() {
                accumulatedPath = accumulatedPath.isEmpty ? component : accumulatedPath + "/" + component
                let isLast = i == components.count - 1
                if isLast {
                    let fileNode = FileTreeNode(name: component, url: file.url, isDirectory: false)
                    if let parentNode { parentNode.children.append(fileNode) } else { roots.append(fileNode) }
                } else if let existing = directoryLookup[accumulatedPath] {
                    parentNode = existing
                } else {
                    let dirNode = FileTreeNode(name: component, url: root.appendingPathComponent(accumulatedPath), isDirectory: true)
                    if let parentNode { parentNode.children.append(dirNode) } else { roots.append(dirNode) }
                    directoryLookup[accumulatedPath] = dirNode
                    parentNode = dirNode
                }
            }
        }

        func sortRecursively(_ nodes: [FileTreeNode]) -> [FileTreeNode] {
            let sorted = nodes.sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            for node in sorted where node.isDirectory { node.children = sortRecursively(node.children) }
            return sorted
        }
        return sortRecursively(roots)
    }

    @objc private func openSelectedTreeItem() {
        let row = fileExplorerOutline.selectedRow
        guard row >= 0, let node = fileExplorerOutline.item(atRow: row) as? FileTreeNode else { return }
        if node.isDirectory {
            if fileExplorerOutline.isItemExpanded(node) { fileExplorerOutline.collapseItem(node) } else { fileExplorerOutline.expandItem(node) }
        } else {
            open(node.url)
            hideFileExplorer()
        }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let node = item as? FileTreeNode { return node.children.count }
        return fileTreeRoots.count
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let node = item as? FileTreeNode { return node.children[index] }
        return fileTreeRoots[index]
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileTreeNode)?.isDirectory ?? false
    }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileTreeNode else { return nil }
        let id = NSUserInterfaceItemIdentifier("treeCell")
        let cell = outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? NSTableCellView()
        cell.identifier = id
        let text = cell.textField ?? NSTextField(labelWithString: "")
        let icon = cell.imageView ?? NSImageView()
        if cell.textField == nil {
            cell.textField = text
            cell.imageView = icon
            text.translatesAutoresizingMaskIntoConstraints = false
            icon.translatesAutoresizingMaskIntoConstraints = false
            text.font = .systemFont(ofSize: 12)
            text.lineBreakMode = .byTruncatingMiddle
            cell.addSubview(icon)
            cell.addSubview(text)
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2), icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor), icon.widthAnchor.constraint(equalToConstant: 14), icon.heightAnchor.constraint(equalToConstant: 14),
                text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6), text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4), text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        text.stringValue = node.name
        text.textColor = node.isDirectory ? NSColor(calibratedWhite: 0.75, alpha: 1) : NSColor(calibratedWhite: 0.85, alpha: 1)
        let symbolName = node.isDirectory ? "folder.fill" : "doc.text"
        icon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        icon.contentTintColor = node.isDirectory ? NSColor(calibratedRed: 0.55, green: 0.75, blue: 0.98, alpha: 1) : NSColor(calibratedWhite: 0.55, alpha: 1)
        return cell
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
                if restoring, let saved = UserDefaults.standard.string(forKey: self.lastFileKey), let file = indexed.first(where: { $0.url.path == saved }) { self.open(file.url); return }
                if let file = indexed.first(where: { ["swift", "ts", "tsx", "js", "json", "md"].contains($0.url.pathExtension.lowercased()) }) { self.open(file.url) }
            }
        }
    }

    private static let maxIndexedFiles = 25000

    nonisolated private static func indexFiles(at root: URL) -> [IndexedFile] {
        let ignored: Set<String> = [
            ".git", ".build", "DerivedData", "node_modules", ".next", "Pods", "dist", "build",
            ".venv", "venv", "vendor", "Carthage", "target", "out", ".cache", "coverage",
            "__pycache__", ".tox", ".mypy_cache", ".pytest_cache"
        ]
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else { return [] }
        let rootPrefix = root.path + "/"
        var indexed: [IndexedFile] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: keys)
            if values?.isDirectory == true && ignored.contains(url.lastPathComponent) { enumerator.skipDescendants(); continue }
            if values?.isRegularFile == true && !url.pathExtension.isEmpty {
                indexed.append(IndexedFile(url: url, relativePath: url.path.replacingOccurrences(of: rootPrefix, with: "")))
            }
            if indexed.count >= maxIndexedFiles { break }
        }
        return indexed.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    // MARK: - Tabs

    private func open(_ url: URL) {
        if let existingIndex = openTabs.firstIndex(where: { $0.url == url }) {
            activeTabIndex = existingIndex
        } else {
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { return }
            openTabs.append(OpenTab(url: url, textStorage: NSTextStorage(string: source), undoManager: UndoManager(), dirty: false))
            activeTabIndex = openTabs.count - 1
        }
        loadActiveTabIntoEditor()
        searchField.stringValue = ""
        UserDefaults.standard.set(url.path, forKey: lastFileKey)
        hideQuickOpenPanel()
        view.window?.makeFirstResponder(editor)
    }

    private func loadActiveTabIntoEditor() {
        guard let index = activeTabIndex, openTabs.indices.contains(index) else { return }
        let tab = openTabs[index]
        editor.layoutManager?.replaceTextStorage(tab.textStorage)
        editor.tabUndoManager = tab.undoManager
        SyntaxHighlighter.apply(to: tab.textStorage, url: tab.url, baseColor: Self.editorTextColor, font: Self.editorFont)
        editor.isEditable = true
        editorScroll.isHidden = false
        gutter.isHidden = false
        gutter.invalidate()
        dirty = tab.dirty
        rebuildTabBar()
        onFileOpened?(tab.url)
        refreshGitDiffMarks()
    }

    @objc private func switchToTabShortcut(_ sender: NSMenuItem) {
        let index = sender.tag >= 0 ? sender.tag : openTabs.count - 1
        switchToTab(index)
    }

    private func switchToTab(_ index: Int) {
        guard openTabs.indices.contains(index), index != activeTabIndex else { return }
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
            editor.layoutManager?.replaceTextStorage(NSTextStorage())
            editor.tabUndoManager = nil
            editor.isEditable = false
            editorScroll.isHidden = true
            gutter.isHidden = true
            gutter.lineDiffMarks = [:]
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

    private var gitDiffGeneration = 0
    private func refreshGitDiffMarks() {
        guard let projectURL, let index = activeTabIndex, openTabs.indices.contains(index) else { return }
        let tab = openTabs[index]
        gitDiffGeneration += 1
        let generation = gitDiffGeneration
        let content = tab.textStorage.string
        let relative = relativePath(tab.url)
        GitDiffComputer.compute(projectRoot: projectURL, relativePath: relative, currentContent: content) { [weak self] marks in
            guard let self, self.gitDiffGeneration == generation, self.activeTabIndex == index else { return }
            self.gutter.lineDiffMarks = marks
        }
    }

    // MARK: - Search

    func controlTextDidBeginEditing(_ obj: Notification) { scheduleRefreshMatches() }
    func controlTextDidChange(_ obj: Notification) { scheduleRefreshMatches() }

    private func scheduleRefreshMatches() {
        pendingSearchWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.performSearch() }
        pendingSearchWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: workItem)
    }

    private func performSearch() {
        guard projectURL != nil else { hideQuickOpenPanel(); return }
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        searchGeneration += 1
        let generation = searchGeneration
        let entries = allFiles

        guard !query.isEmpty else {
            matches = entries.prefix(30).map { $0.url }
            applySearchResults()
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let scored = entries.compactMap { entry -> (URL, Int)? in
                FuzzyMatcher.score(query: query, candidate: entry.relativePath).map { (entry.url, $0) }
            }
            let ranked = scored.sorted { $0.1 > $1.1 }.prefix(30).map { $0.0 }
            DispatchQueue.main.async {
                guard let self, self.searchGeneration == generation else { return }
                self.matches = Array(ranked)
                self.applySearchResults()
            }
        }
    }

    private func applySearchResults() {
        resultsTable.reloadData()
        if !matches.isEmpty { resultsTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        if !matches.isEmpty { showQuickOpenPanel() } else { hideQuickOpenPanel() }
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
    private var pendingDiffWorkItem: DispatchWorkItem?
    func textDidChange(_ notification: Notification) {
        dirty = true
        if let index = activeTabIndex { openTabs[index].dirty = true }
        gutter.invalidate()
        scheduleHighlight()
        scheduleDiffRefresh()
    }

    private static let autoClosePairs: [Character: Character] = ["(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'"]
    private static let autoCloseClosers: Set<Character> = [")", "]", "}", "\"", "'"]

    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard textView === editor, let replacementString, replacementString.count == 1, let char = replacementString.first else { return true }

        if Self.autoCloseClosers.contains(char), affectedCharRange.length == 0 {
            let ns = textView.string as NSString
            if affectedCharRange.location < ns.length, ns.character(at: affectedCharRange.location) == char.utf16.first {
                textView.setSelectedRange(NSRange(location: affectedCharRange.location + 1, length: 0))
                return false
            }
        }

        if let closing = Self.autoClosePairs[char], affectedCharRange.length == 0 {
            textView.insertText("\(char)\(closing)", replacementRange: affectedCharRange)
            textView.setSelectedRange(NSRange(location: affectedCharRange.location + 1, length: 0))
            return false
        }

        return true
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard textView === editor, commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
        let ns = textView.string as NSString
        let selectedRange = textView.selectedRange()
        let lineRange = ns.lineRange(for: NSRange(location: selectedRange.location, length: 0))
        let currentLine = ns.substring(with: NSRange(location: lineRange.location, length: selectedRange.location - lineRange.location))
        let leadingWhitespace = currentLine.prefix(while: { $0 == " " || $0 == "\t" })
        var indent = String(leadingWhitespace)
        if let last = currentLine.trimmingCharacters(in: .whitespaces).last, "{[(".contains(last) {
            indent += "    "
        }
        textView.insertText("\n" + indent, replacementRange: selectedRange)
        return true
    }

    private func scheduleDiffRefresh() {
        pendingDiffWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.refreshGitDiffMarks() }
        pendingDiffWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: workItem)
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
        let explorer = navigateMenu.addItem(withTitle: "Toggle File Explorer", action: #selector(toggleFileExplorer), keyEquivalent: "e")
        explorer.keyEquivalentModifierMask = [.command, .shift]
        explorer.target = self
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
    @objc private func focusQuickOpen() { searchField.stringValue = ""; view.window?.makeFirstResponder(searchField); performSearch() }
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
        let lineStart = min(index, text.length)
        let cursorRange = NSRange(location: lineStart, length: 0)
        editor.scrollRangeToVisible(text.lineRange(for: cursorRange))
        editor.setSelectedRange(cursorRange)
        view.window?.makeFirstResponder(editor)
    }
    @objc private func save() {
        guard let index = activeTabIndex else { return }
        let tab = openTabs[index]
        try? tab.textStorage.string.write(to: tab.url, atomically: true, encoding: .utf8)
        openTabs[index].dirty = false
        dirty = false
        rebuildTabBar()
        refreshGitDiffMarks()
    }
    private func restoreLastSession() { guard let saved = UserDefaults.standard.string(forKey: lastProjectKey) else { return }; let url = URL(fileURLWithPath: saved); var isDirectory: ObjCBool = false; guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return }; loadProject(at: url, restoring: true) }
}

final class EditorTextView: NSTextView {
    var tabUndoManager: UndoManager?
    override var undoManager: UndoManager? { tabUndoManager }
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
    private var grabOffsetX: CGFloat = 0
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
        grabOffsetX = event.locationInWindow.x - convert(NSPoint.zero, to: nil).x
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragOrigin else { return }
        let totalDX = event.locationInWindow.x - dragOrigin.x
        if abs(totalDX) > 4 { didDrag = true }
        guard didDrag else { return }

        // Reorder the model/stack first (siblings animate into their new slots)...
        onDragging?(event.locationInWindow.x)

        // ...then keep this chip glued to the cursor regardless of where that reorder
        // just placed it in the stack, by transforming relative to its *current* laid-out
        // position rather than the position at mouseDown.
        wantsLayer = true
        layer?.zPosition = 10
        let naturalXInWindow = convert(NSPoint.zero, to: nil).x
        let desiredXInWindow = event.locationInWindow.x - grabOffsetX
        layer?.setAffineTransform(CGAffineTransform(translationX: desiredXInWindow - naturalXInWindow, y: 0))
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragOrigin = nil }
        guard dragOrigin != nil else { return }
        if didDrag {
            layer?.setAffineTransform(.identity)
            layer?.zPosition = 0
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
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
        layer?.cornerRadius = frameRect.width / 2
        layer?.masksToBounds = true
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

    override func mouseEntered(with event: NSEvent) {
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
        layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.16).cgColor
    }
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
