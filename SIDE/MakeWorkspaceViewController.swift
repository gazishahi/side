import AppKit

private enum TabKind { case text, image, csv }

private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let container = documentView else { return rect }
        let containerFrame = container.frame
        if containerFrame.width < rect.width {
            rect.origin.x = (containerFrame.width - rect.width) / 2
        }
        if containerFrame.height < rect.height {
            rect.origin.y = (containerFrame.height - rect.height) / 2
        }
        return rect
    }
}

private enum HeadContentCache {
    case notFetched
    case fetched(String?)
}

private struct OpenTab {
    var url: URL
    let kind: TabKind
    let textStorage: NSTextStorage
    let undoManager: UndoManager
    var dirty: Bool
    var isUntitled: Bool
    var knownModificationDate: Date?
    var lastSelectedRange = NSRange(location: 0, length: 0)
    var csvRows: [[String]] = []
    var diagnostics: [LSPDiagnostic] = []
    var cachedImage: NSImage?
    var headCache: HeadContentCache = .notFetched
}

private struct IndexedFile {
    let url: URL
    let relativePath: String
}

final class MakeWorkspaceViewController: NSViewController, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
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
    private let imageScroll = NSScrollView()
    private let imageView = NSImageView()
    private let csvScroll = NSScrollView()
    private let csvTable = NSTableView()
    private var quickOpenLocalMonitor: Any?
    private var quickOpenGlobalMonitor: Any?
    private var fileExplorerLocalMonitor: Any?
    private var fileExplorerGlobalMonitor: Any?
    private var currentDiffHunks: [GitHunk] = []
    private var currentDiffHeadContent: String?
    private var projectURL: URL?
    private var lspManager: LSPManager?
    private var allFiles: [IndexedFile] = []
    private var matches: [URL] = []
    private enum SearchMode { case files, symbols }
    private var searchMode: SearchMode = .files
    private var symbolMatches: [CodeSymbol] = []
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
        editor.allowsUndo = true
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
        gutter.onMarkClicked = { [weak self] line, mark, event in self?.showDiffMenu(line: line, mark: mark, event: event) }
        gutter.onDiagnosticClicked = { [weak self] line, severity, event in self?.showDiagnosticMenu(line: line, severity: severity, event: event) }
        view.addSubview(gutter)

        imageScroll.hasVerticalScroller = true
        imageScroll.hasHorizontalScroller = true
        imageScroll.allowsMagnification = true
        imageScroll.minMagnification = 0.1
        imageScroll.maxMagnification = 8
        imageScroll.backgroundColor = Self.editorBackground
        imageScroll.drawsBackground = true
        imageScroll.isHidden = true
        imageScroll.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        let centeringClip = CenteringClipView()
        centeringClip.drawsBackground = false
        imageScroll.contentView = centeringClip
        imageScroll.documentView = imageView
        view.addSubview(imageScroll)

        csvTable.headerView = NSTableHeaderView()
        csvTable.usesAlternatingRowBackgroundColors = true
        csvTable.rowHeight = 22
        csvTable.dataSource = self
        csvTable.delegate = self
        csvScroll.documentView = csvTable
        csvScroll.hasVerticalScroller = true
        csvScroll.hasHorizontalScroller = true
        csvScroll.backgroundColor = Self.editorBackground
        csvScroll.drawsBackground = true
        csvScroll.isHidden = true
        csvScroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(csvScroll)

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
            imageScroll.topAnchor.constraint(equalTo: tabBar.bottomAnchor), imageScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), imageScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor), imageScroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            csvScroll.topAnchor.constraint(equalTo: tabBar.bottomAnchor), csvScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), csvScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor), csvScroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
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

        quickOpenPanel.contentView = Self.makeFloatingPanelSurface(embedding: scroll, cornerRadius: 8, padding: 14)
    }

    /// Wraps `content` in Liquid Glass on macOS 26+, falling back to the older vibrancy
    /// material on earlier systems (deployment target stays 15.0, so both paths ship).
    private static func makeFloatingPanelSurface(embedding content: NSView, cornerRadius: CGFloat, padding: CGFloat) -> NSView {
        let padded = NSView()
        padded.translatesAutoresizingMaskIntoConstraints = false
        padded.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: padded.topAnchor, constant: padding), content.leadingAnchor.constraint(equalTo: padded.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: padded.trailingAnchor), content.bottomAnchor.constraint(equalTo: padded.bottomAnchor, constant: -padding)
        ])

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.contentView = padded
            glass.cornerRadius = cornerRadius
            glass.style = .regular
            return glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .popover
            effect.state = .active
            effect.blendingMode = .withinWindow
            effect.wantsLayer = true
            effect.layer?.cornerRadius = cornerRadius
            effect.layer?.masksToBounds = true
            effect.addSubview(padded)
            NSLayoutConstraint.activate([
                padded.topAnchor.constraint(equalTo: effect.topAnchor), padded.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
                padded.trailingAnchor.constraint(equalTo: effect.trailingAnchor), padded.bottomAnchor.constraint(equalTo: effect.bottomAnchor)
            ])
            return effect
        }
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
        let contextMenu = NSMenu()
        contextMenu.delegate = self
        fileExplorerOutline.menu = contextMenu

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

        let padded = NSView()
        padded.translatesAutoresizingMaskIntoConstraints = false
        padded.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: padded.topAnchor, constant: 10), scroll.leadingAnchor.constraint(equalTo: padded.leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: padded.trailingAnchor, constant: -4), scroll.bottomAnchor.constraint(equalTo: padded.bottomAnchor, constant: -10)
        ])

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.contentView = padded
            glass.cornerRadius = 10
            glass.style = .regular
            fileExplorerPanel.contentView = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .popover
            effect.state = .active
            effect.blendingMode = .withinWindow
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 10
            effect.layer?.masksToBounds = true
            effect.addSubview(padded)
            NSLayoutConstraint.activate([
                padded.topAnchor.constraint(equalTo: effect.topAnchor), padded.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
                padded.trailingAnchor.constraint(equalTo: effect.trailingAnchor), padded.bottomAnchor.constraint(equalTo: effect.bottomAnchor)
            ])
            fileExplorerPanel.contentView = effect
        }
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
        // Short travel distance reads as a reveal; sliding the full window width reads as "thrown in."
        let startFrame = NSRect(x: targetX + 28, y: y, width: width, height: height)
        let targetFrame = NSRect(x: targetX, y: y, width: width, height: height)

        fileExplorerPanel.alphaValue = 0
        fileExplorerPanel.setFrame(startFrame, display: false)
        if fileExplorerPanel.parent == nil { window.addChildWindow(fileExplorerPanel, ordered: .above) }
        fileExplorerPanel.orderFront(nil)
        installFileExplorerDismissMonitors()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.32
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            fileExplorerPanel.animator().setFrame(targetFrame, display: true)
            fileExplorerPanel.animator().alphaValue = 1
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
        guard fileExplorerPanel.isVisible else { return }
        var endFrame = fileExplorerPanel.frame
        endFrame.origin.x += 24
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)
            fileExplorerPanel.animator().setFrame(endFrame, display: true)
            fileExplorerPanel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self else { return }
            self.view.window?.removeChildWindow(self.fileExplorerPanel)
            self.fileExplorerPanel.orderOut(nil)
            self.fileExplorerPanel.alphaValue = 1
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

    // MARK: - File explorer context menu (new / rename / delete)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = fileExplorerOutline.clickedRow
        let clickedNode = row >= 0 ? fileExplorerOutline.item(atRow: row) as? FileTreeNode : nil
        guard let root = projectURL else { return }

        let folderForNewItems: FileTreeNode
        if let clickedNode, clickedNode.isDirectory {
            folderForNewItems = clickedNode
        } else {
            folderForNewItems = FileTreeNode(name: root.lastPathComponent, url: root, isDirectory: true)
        }
        let newFile = menu.addItem(withTitle: "New File…", action: #selector(newFileInFolder(_:)), keyEquivalent: "")
        newFile.representedObject = folderForNewItems
        let newFolder = menu.addItem(withTitle: "New Folder…", action: #selector(newFolderInFolder(_:)), keyEquivalent: "")
        newFolder.representedObject = folderForNewItems

        if let clickedNode {
            menu.addItem(NSMenuItem.separator())
            let rename = menu.addItem(withTitle: "Rename…", action: #selector(renameTreeItem(_:)), keyEquivalent: "")
            rename.representedObject = clickedNode
            let delete = menu.addItem(withTitle: "Move to Trash", action: #selector(deleteTreeItem(_:)), keyEquivalent: "")
            delete.representedObject = clickedNode
        }
        menu.items.forEach { $0.target = self }
    }

    @objc private func newFileInFolder(_ sender: NSMenuItem) {
        guard let folder = sender.representedObject as? FileTreeNode else { return }
        promptForName(title: "New File", placeholder: "filename.txt") { [weak self] name in
            guard let self, let name, !name.isEmpty else { return }
            let newURL = folder.url.appendingPathComponent(name)
            guard let window = self.view.window else { return }
            guard !FileManager.default.fileExists(atPath: newURL.path) else {
                self.showAlert(title: "File already exists", message: "\(name) already exists in \(folder.name).", window: window)
                return
            }
            guard FileManager.default.createFile(atPath: newURL.path, contents: Data()) else {
                self.showAlert(title: "Couldn't create file", message: newURL.lastPathComponent, window: window)
                return
            }
            self.refreshFileTreeAndReindex()
            self.open(newURL)
        }
    }

    @objc private func newFolderInFolder(_ sender: NSMenuItem) {
        guard let folder = sender.representedObject as? FileTreeNode else { return }
        promptForName(title: "New Folder", placeholder: "folder name") { [weak self] name in
            guard let self, let name, !name.isEmpty else { return }
            let newURL = folder.url.appendingPathComponent(name)
            do {
                try FileManager.default.createDirectory(at: newURL, withIntermediateDirectories: true)
                self.refreshFileTreeAndReindex()
            } catch {
                guard let window = self.view.window else { return }
                self.showAlert(title: "Couldn't create folder", message: error.localizedDescription, window: window)
            }
        }
    }

    @objc private func renameTreeItem(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? FileTreeNode else { return }
        promptForName(title: "Rename", placeholder: node.name, initialValue: node.name) { [weak self] name in
            guard let self, let name, !name.isEmpty, name != node.name else { return }
            let newURL = node.url.deletingLastPathComponent().appendingPathComponent(name)
            do {
                try FileManager.default.moveItem(at: node.url, to: newURL)
                if let idx = self.openTabs.firstIndex(where: { $0.url == node.url }) {
                    self.openTabs[idx].url = newURL
                    self.rebuildTabBar()
                    if self.activeTabIndex == idx { self.onFileOpened?(newURL) }
                }
                self.refreshFileTreeAndReindex()
            } catch {
                guard let window = self.view.window else { return }
                self.showAlert(title: "Couldn't rename", message: error.localizedDescription, window: window)
            }
        }
    }

    @objc private func deleteTreeItem(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? FileTreeNode, let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Move \u{201C}\(node.name)\u{201D} to the Trash?"
        alert.informativeText = node.isDirectory ? "This folder and everything inside it will be moved to the Trash." : "This file will be moved to the Trash."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            try? FileManager.default.trashItem(at: node.url, resultingItemURL: nil)
            if let idx = self.openTabs.firstIndex(where: { $0.url == node.url }) {
                self.closeTab(at: idx)
            }
            self.refreshFileTreeAndReindex()
        }
    }

    private func promptForName(title: String, placeholder: String, initialValue: String = "", completion: @escaping (String?) -> Void) {
        guard let window = view.window else { completion(nil); return }
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = placeholder
        field.stringValue = initialValue
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            completion(response == .alertFirstButtonReturn ? field.stringValue.trimmingCharacters(in: .whitespaces) : nil)
        }
    }

    private func refreshFileTreeAndReindex() {
        guard let root = projectURL else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let indexed = Self.indexFiles(at: root)
            let tree = Self.buildFileTree(from: indexed, root: root)
            DispatchQueue.main.async {
                guard let self, self.projectURL == root else { return }
                self.allFiles = indexed
                self.fileTreeRoots = tree
                self.fileExplorerOutline.reloadData()
            }
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
        confirmAllUnsavedChanges { [weak self] proceed in
            guard let self, proceed, let window = self.view.window else { return }
            let panel = NSOpenPanel()
            panel.message = "Choose a project to open in SIDE"
            panel.prompt = "Open project"
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.beginSheetModal(for: window) { [weak self] response in
                guard let self, response == .OK, let url = panel.url else { return }
                self.closeAllTabsImmediately()
                self.loadProject(at: url, restoring: false)
            }
        }
    }

    private func loadProject(at url: URL, restoring: Bool) {
        lspManager?.prepareForClose()
        let manager = LSPManager(projectRoot: url)
        manager.onDiagnostics = { [weak self] fileURL, diagnostics in
            self?.applyDiagnostics(diagnostics, to: fileURL)
        }
        lspManager = manager
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

    private static let maxOpenableFileSize = 10_000_000
    private static let maxOpenableImageSize = 50_000_000
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "heic", "webp"]

    private func open(_ url: URL, completion: (() -> Void)? = nil) {
        captureActiveTabSelection()
        if let existingIndex = openTabs.firstIndex(where: { $0.url == url }) {
            activeTabIndex = existingIndex
            loadActiveTabIntoEditor()
            finishOpenUI(url: url)
            completion?()
            return
        }
        guard let window = view.window else { completion?(); return }
        let ext = url.pathExtension.lowercased()

        if Self.imageExtensions.contains(ext) {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                if size > Self.maxOpenableImageSize {
                    DispatchQueue.main.async {
                        self?.showAlert(title: "Image too large", message: "\(url.lastPathComponent) is \(size / 1_000_000) MB, over SIDE's current 50 MB limit.", window: window)
                        completion?()
                    }
                    return
                }
                guard let image = NSImage(contentsOf: url) else {
                    DispatchQueue.main.async {
                        self?.showAlert(title: "Couldn't open image", message: "\(url.lastPathComponent) couldn't be read as an image.", window: window)
                        completion?()
                    }
                    return
                }
                DispatchQueue.main.async {
                    guard let self else { completion?(); return }
                    var tab = OpenTab(url: url, kind: .image, textStorage: NSTextStorage(), undoManager: UndoManager(), dirty: false, isUntitled: false, knownModificationDate: nil)
                    tab.cachedImage = image
                    self.openTabs.append(tab)
                    self.activeTabIndex = self.openTabs.count - 1
                    self.loadActiveTabIntoEditor()
                    self.finishOpenUI(url: url)
                    completion?()
                }
            }
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            if size > Self.maxOpenableFileSize {
                DispatchQueue.main.async {
                    self?.showAlert(title: "File too large", message: "\(url.lastPathComponent) is \(size / 1_000_000) MB, over SIDE's current 10 MB limit for opening in the editor.", window: window)
                    completion?()
                }
                return
            }
            guard let data = try? Data(contentsOf: url) else {
                DispatchQueue.main.async {
                    self?.showAlert(title: "Couldn't open file", message: "\(url.lastPathComponent) couldn't be read.", window: window)
                    completion?()
                }
                return
            }
            guard let source = String(data: data, encoding: .utf8) else {
                DispatchQueue.main.async {
                    self?.showAlert(title: "Can't open this file", message: "\(url.lastPathComponent) doesn't appear to be a text file SIDE can edit.", window: window)
                    completion?()
                }
                return
            }
            let modDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let isCSV = ext == "csv"
            let rows = isCSV ? CSVParser.parse(source) : []
            DispatchQueue.main.async {
                guard let self else { completion?(); return }
                var tab = OpenTab(url: url, kind: isCSV ? .csv : .text, textStorage: NSTextStorage(string: source), undoManager: UndoManager(), dirty: false, isUntitled: false, knownModificationDate: modDate)
                tab.csvRows = rows
                self.openTabs.append(tab)
                self.activeTabIndex = self.openTabs.count - 1
                self.loadActiveTabIntoEditor()
                self.finishOpenUI(url: url)
                if tab.kind == .text { self.lspManager?.opened(url: url, content: source) }
                completion?()
            }
        }
    }

    private func finishOpenUI(url: URL) {
        searchField.stringValue = ""
        UserDefaults.standard.set(url.path, forKey: lastFileKey)
        hideQuickOpenPanel()
        view.window?.makeFirstResponder(editor)
    }

    private func showAlert(title: String, message: String, window: NSWindow, style: NSAlert.Style = .warning) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    private func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// Snapshots the outgoing tab's cursor position so switching back to it later restores
    /// where the user was, instead of leaving the editor's stale selection/typing attributes
    /// from whatever tab was previously loaded.
    private func captureActiveTabSelection() {
        guard let index = activeTabIndex, openTabs.indices.contains(index) else { return }
        openTabs[index].lastSelectedRange = editor.selectedRange()
    }

    private func loadActiveTabIntoEditor() {
        guard let index = activeTabIndex, openTabs.indices.contains(index) else { return }
        let tab = openTabs[index]

        editorScroll.isHidden = tab.kind != .text
        gutter.isHidden = tab.kind != .text
        imageScroll.isHidden = tab.kind != .image
        csvScroll.isHidden = tab.kind != .csv

        switch tab.kind {
        case .text:
            // Guards against textDidChange firing (synchronously or via a same-turn queued
            // notification) as a side effect of this programmatic swap and spuriously marking
            // an untouched, freshly opened file as dirty. Cleared on the *next* runloop turn
            // rather than immediately, so it still covers a notification queued this turn.
            isLoadingTab = true
            editor.layoutManager?.replaceTextStorage(tab.textStorage)
            DispatchQueue.main.async { [weak self] in self?.isLoadingTab = false }
            editor.tabUndoManager = tab.undoManager
            SyntaxHighlighter.apply(to: tab.textStorage, url: tab.url, baseColor: Self.editorTextColor, font: Self.editorFont)
            // Replacing the text storage can leave typingAttributes pointing at whatever the
            // previous (or default system) font/color was, especially for a brand-new empty
            // document with no existing attribute run to inherit from — explicitly reset it so
            // freshly typed characters are never invisible against the editor background.
            editor.typingAttributes = [.foregroundColor: Self.editorTextColor, .font: Self.editorFont]
            editor.isEditable = true
            let clampedLocation = min(tab.lastSelectedRange.location, tab.textStorage.length)
            let restoredRange = NSRange(location: clampedLocation, length: 0)
            editor.setSelectedRange(restoredRange)
            editor.scrollRangeToVisible(restoredRange)
            gutter.invalidate()
            refreshGitDiffMarks()
            renderDiagnosticsForActiveTab()
        case .image:
            editor.isEditable = false
            imageView.image = tab.cachedImage
            if let size = tab.cachedImage?.size { imageView.frame = NSRect(origin: .zero, size: size) }
        case .csv:
            editor.isEditable = false
            rebuildCSVColumns(for: tab)
            csvTable.reloadData()
        }

        dirty = tab.dirty
        rebuildTabBar()
        onFileOpened?(tab.url)
    }

    private func rebuildCSVColumns(for tab: OpenTab) {
        csvTable.tableColumns.forEach { csvTable.removeTableColumn($0) }
        guard let columnCount = tab.csvRows.first?.count else { return }
        let header = tab.csvRows.first ?? []
        for i in 0..<columnCount {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("csv-\(i)"))
            column.title = i < header.count ? header[i] : "Column \(i + 1)"
            column.width = 140
            csvTable.addTableColumn(column)
        }
    }

    // MARK: - Diagnostics

    private func applyDiagnostics(_ diagnostics: [LSPDiagnostic], to url: URL) {
        guard let index = openTabs.firstIndex(where: { $0.url == url }) else { return }
        openTabs[index].diagnostics = diagnostics
        guard activeTabIndex == index else { return }
        renderDiagnosticsForActiveTab()
    }

    private func renderDiagnosticsForActiveTab() {
        guard let index = activeTabIndex, openTabs.indices.contains(index), openTabs[index].kind == .text else { return }
        let tab = openTabs[index]
        let fullRange = NSRange(location: 0, length: tab.textStorage.length)
        tab.textStorage.removeAttribute(.underlineStyle, range: fullRange)
        tab.textStorage.removeAttribute(.underlineColor, range: fullRange)
        let ns = tab.textStorage.string as NSString
        var lineSeverities: [Int: LSPDiagnosticSeverity] = [:]
        for diagnostic in tab.diagnostics {
            let line = diagnostic.range.start.line + 1
            if let existing = lineSeverities[line] {
                if severityRank(diagnostic.severity) < severityRank(existing) { lineSeverities[line] = diagnostic.severity ?? existing }
            } else {
                lineSeverities[line] = diagnostic.severity ?? .information
            }
            guard let range = nsRange(for: diagnostic.range, in: ns), NSMaxRange(range) <= ns.length else { continue }
            let color: NSColor = diagnostic.severity == .error ? .systemRed : (diagnostic.severity == .warning ? .systemYellow : .systemGray)
            tab.textStorage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue, range: range)
            tab.textStorage.addAttribute(.underlineColor, value: color, range: range)
        }
        gutter.lineDiagnostics = lineSeverities
    }

    private func severityRank(_ severity: LSPDiagnosticSeverity?) -> Int { severity?.rawValue ?? 5 }

    /// LSP positions are zero-based (line, UTF-16 character) pairs; NSTextStorage indexes by
    /// UTF-16 code unit too, so this only has to walk line breaks to find each line's start.
    private func nsRange(for range: LSPRange, in ns: NSString) -> NSRange? {
        guard let start = utf16Location(line: range.start.line, character: range.start.character, in: ns),
              let end = utf16Location(line: range.end.line, character: range.end.character, in: ns),
              end >= start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    private func utf16Location(line: Int, character: Int, in ns: NSString) -> Int? {
        guard line >= 0, character >= 0 else { return nil }
        var currentLine = 0
        var index = 0
        let length = ns.length
        while currentLine < line {
            guard index < length else { return nil }
            index = NSMaxRange(ns.lineRange(for: NSRange(location: index, length: 0)))
            currentLine += 1
        }
        guard index <= length else { return nil }
        let lineRange = ns.lineRange(for: NSRange(location: min(index, max(length - 1, 0)), length: 0))
        let hasTrailingNewline = lineRange.length > 0 && ns.character(at: NSMaxRange(lineRange) - 1) == 10
        let lineContentLength = hasTrailingNewline ? lineRange.length - 1 : lineRange.length
        return index + min(character, lineContentLength)
    }

    /// Inverse of utf16Location(line:character:in:) — converts a flat UTF-16 offset back to
    /// the zero-based (line, character) pair LSP positions use.
    private func lspPosition(for characterIndex: Int, in ns: NSString) -> LSPPosition {
        var line = 0
        var index = 0
        while index < characterIndex, index < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: index, length: 0))
            if NSMaxRange(lineRange) > characterIndex { break }
            index = NSMaxRange(lineRange)
            line += 1
        }
        return LSPPosition(line: line, character: characterIndex - index)
    }

    @objc private func jumpToDefinition() {
        guard let index = activeTabIndex, openTabs.indices.contains(index), openTabs[index].kind == .text, let lspManager else { return }
        let tab = openTabs[index]
        let ns = tab.textStorage.string as NSString
        let position = lspPosition(for: editor.selectedRange().location, in: ns)
        lspManager.definition(url: tab.url, position: position) { [weak self] locations in
            guard let self, let target = locations.first, let targetURL = URL(string: target.uri) else { return }
            self.open(targetURL) { [weak self] in
                guard let self, let targetIndex = self.openTabs.firstIndex(where: { $0.url == targetURL }), self.openTabs[targetIndex].kind == .text else { return }
                let targetNS = self.openTabs[targetIndex].textStorage.string as NSString
                guard let targetRange = self.nsRange(for: target.range, in: targetNS) else { return }
                self.editor.setSelectedRange(NSRange(location: targetRange.location, length: 0))
                self.editor.scrollRangeToVisible(targetRange)
                self.view.window?.makeFirstResponder(self.editor)
            }
        }
    }

    private func showDiagnosticMenu(line: Int, severity: LSPDiagnosticSeverity, event: NSEvent) {
        guard let index = activeTabIndex, openTabs.indices.contains(index) else { return }
        let onLine = openTabs[index].diagnostics.filter { $0.range.start.line + 1 == line }
        guard !onLine.isEmpty else { return }
        let menu = NSMenu()
        for diagnostic in onLine {
            let item = menu.addItem(withTitle: diagnostic.message, action: nil, keyEquivalent: "")
            item.isEnabled = false
        }
        NSMenu.popUpContextMenu(menu, with: event, for: gutter)
    }

    @objc private func switchToTabShortcut(_ sender: NSMenuItem) {
        let index = sender.tag >= 0 ? sender.tag : openTabs.count - 1
        switchToTab(index)
    }

    private func switchToTab(_ index: Int) {
        guard openTabs.indices.contains(index), index != activeTabIndex else { return }
        captureActiveTabSelection()
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
        let tab = openTabs[index]
        guard tab.dirty else { finishCloseTab(at: index); return }
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes you made to \u{201C}\(tab.isUntitled ? "Untitled" : tab.url.lastPathComponent)\u{201D}?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                self.performSave(tabIndex: index) { success in if success { self.finishCloseTab(at: index) } }
            case .alertSecondButtonReturn:
                self.finishCloseTab(at: index)
            default:
                break
            }
        }
    }

    private func finishCloseTab(at index: Int) {
        guard openTabs.indices.contains(index) else { return }
        let closedTab = openTabs[index]
        openTabs.remove(at: index)
        if closedTab.kind == .text { lspManager?.closed(url: closedTab.url) }
        if openTabs.isEmpty {
            closeAllTabsImmediately()
        } else {
            activeTabIndex = min(index, openTabs.count - 1)
            loadActiveTabIntoEditor()
            rebuildTabBar()
        }
    }

    private func closeAllTabsImmediately() {
        for tab in openTabs where tab.kind == .text { lspManager?.closed(url: tab.url) }
        openTabs.removeAll()
        activeTabIndex = nil
        isLoadingTab = true
        editor.layoutManager?.replaceTextStorage(NSTextStorage())
        DispatchQueue.main.async { [weak self] in self?.isLoadingTab = false }
        editor.tabUndoManager = nil
        editor.isEditable = false
        editorScroll.isHidden = true
        gutter.isHidden = true
        gutter.lineDiffMarks = [:]
        imageScroll.isHidden = true
        imageView.image = nil
        csvScroll.isHidden = true
        dirty = false
        UserDefaults.standard.removeObject(forKey: lastFileKey)
        onFileOpened?(nil)
        rebuildTabBar()
    }

    /// Resolves every dirty tab (via Save/Don't Save/Cancel, one at a time) before allowing a
    /// caller to proceed with something that would otherwise discard them — closing the window,
    /// quitting, or switching projects.
    private func confirmAllUnsavedChanges(completion: @escaping (_ shouldProceed: Bool) -> Void) {
        let dirtyIndices = openTabs.indices.filter { openTabs[$0].dirty }
        guard !dirtyIndices.isEmpty, let window = view.window else { completion(true); return }

        func processNext(_ remaining: [Int]) {
            var remaining = remaining
            guard let index = remaining.first else { completion(true); return }
            remaining.removeFirst()
            guard openTabs.indices.contains(index) else { processNext(remaining); return }
            let tab = openTabs[index]
            let alert = NSAlert()
            alert.messageText = "Do you want to save the changes you made to \u{201C}\(tab.isUntitled ? "Untitled" : tab.url.lastPathComponent)\u{201D}?"
            alert.informativeText = "Your changes will be lost if you don't save them."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Don't Save")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self else { completion(false); return }
                switch response {
                case .alertFirstButtonReturn:
                    self.performSave(tabIndex: index) { success in
                        if success { processNext(remaining) } else { completion(false) }
                    }
                case .alertSecondButtonReturn:
                    processNext(remaining)
                default:
                    completion(false)
                }
            }
        }
        processNext(dirtyIndices)
    }

    var hasUnsavedChanges: Bool { openTabs.contains { $0.dirty } }
    func confirmCloseAllUnsaved(completion: @escaping (Bool) -> Void) { confirmAllUnsavedChanges(completion: completion) }

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
        container.toolTip = tab.isUntitled ? "Unsaved" : relativePath(tab.url)
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
        guard !tab.isUntitled, tab.kind == .text else {
            gutter.lineDiffMarks = [:]
            currentDiffHunks = []
            currentDiffHeadContent = nil
            return
        }
        gitDiffGeneration += 1
        let generation = gitDiffGeneration
        let content = tab.textStorage.string
        let relative = relativePath(tab.url)

        switch tab.headCache {
        case .fetched(let headContent):
            runDiff(headContent: headContent, content: content, projectRoot: projectURL, tabIndex: index, generation: generation)
        case .notFetched:
            GitDiffComputer.fetchHeadContent(projectRoot: projectURL, relativePath: relative) { [weak self] headContent in
                guard let self, self.openTabs.indices.contains(index) else { return }
                self.openTabs[index].headCache = .fetched(headContent)
                guard self.gitDiffGeneration == generation, self.activeTabIndex == index else { return }
                self.runDiff(headContent: headContent, content: content, projectRoot: projectURL, tabIndex: index, generation: generation)
            }
        }
    }

    private func runDiff(headContent: String?, content: String, projectRoot: URL, tabIndex: Int, generation: Int) {
        GitDiffComputer.diff(headContent: headContent, currentContent: content, projectRoot: projectRoot) { [weak self] result in
            guard let self, self.gitDiffGeneration == generation, self.activeTabIndex == tabIndex else { return }
            self.gutter.lineDiffMarks = result.marks
            self.currentDiffHunks = result.hunks
            self.currentDiffHeadContent = result.headContent
        }
    }

    private func hunk(containingLine line: Int, mark: GitDiffMark) -> GitHunk? {
        currentDiffHunks.first { hunk in
            if mark == .removedBefore { return hunk.newCount == 0 && max(hunk.newStart, 1) == line }
            return line >= hunk.newStart && line < hunk.newStart + hunk.newCount
        }
    }

    private func showDiffMenu(line: Int, mark: GitDiffMark, event: NSEvent) {
        guard let hunk = hunk(containingLine: line, mark: mark) else { return }
        let menu = NSMenu()
        let item = menu.addItem(withTitle: "Revert Change", action: #selector(revertHunkAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = hunk
        NSMenu.popUpContextMenu(menu, with: event, for: gutter)
    }

    @objc private func revertHunkAction(_ sender: NSMenuItem) {
        guard let hunk = sender.representedObject as? GitHunk else { return }
        revertHunk(hunk)
    }

    private func revertHunk(_ hunk: GitHunk) {
        guard let index = activeTabIndex, openTabs.indices.contains(index) else { return }
        let tab = openTabs[index]
        guard editor.textStorage === tab.textStorage else { return }

        let originalLines = (currentDiffHeadContent ?? "").components(separatedBy: "\n")
        let replacementLines: [String]
        if hunk.oldCount > 0, hunk.oldStart - 1 + hunk.oldCount <= originalLines.count {
            replacementLines = Array(originalLines[(hunk.oldStart - 1)..<(hunk.oldStart - 1 + hunk.oldCount)])
        } else {
            replacementLines = []
        }
        let replacement = replacementLines.isEmpty ? "" : replacementLines.joined(separator: "\n") + "\n"

        let ns = tab.textStorage.string as NSString
        let range: NSRange
        if hunk.newCount > 0 {
            range = lineSpanRange(in: ns, startLine: hunk.newStart, count: hunk.newCount)
        } else {
            let insertionPoint = lineSpanRange(in: ns, startLine: hunk.newStart, count: 0)
            range = NSRange(location: insertionPoint.location, length: 0)
        }

        editor.insertText(replacement, replacementRange: range)
        SyntaxHighlighter.apply(to: tab.textStorage, url: tab.url, baseColor: Self.editorTextColor, font: Self.editorFont)
        gutter.invalidate()
        refreshGitDiffMarks()
    }

    private func lineSpanRange(in text: NSString, startLine: Int, count: Int) -> NSRange {
        var index = 0
        var currentLine = 1
        while currentLine < max(1, startLine) && index < text.length {
            let lineRange = text.lineRange(for: NSRange(location: index, length: 0))
            index = NSMaxRange(lineRange)
            currentLine += 1
        }
        let start = min(index, text.length)
        guard count > 0 else { return NSRange(location: start, length: 0) }
        var end = start
        for _ in 0..<count {
            guard end < text.length else { break }
            let lineRange = text.lineRange(for: NSRange(location: end, length: 0))
            end = NSMaxRange(lineRange)
        }
        return NSRange(location: start, length: end - start)
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
        if searchMode == .symbols {
            performSymbolSearch()
            return
        }
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

    private func performSymbolSearch() {
        guard let index = activeTabIndex, openTabs.indices.contains(index) else { hideQuickOpenPanel(); return }
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let tab = openTabs[index]
        let allSymbols = SymbolIndexer.symbols(in: tab.textStorage.string, ext: tab.url.pathExtension.lowercased())
        if query.isEmpty {
            symbolMatches = Array(allSymbols.prefix(30))
        } else {
            symbolMatches = allSymbols.compactMap { symbol in
                FuzzyMatcher.score(query: query, candidate: symbol.name).map { (symbol, $0) }
            }.sorted { $0.1 > $1.1 }.prefix(30).map { $0.0 }
        }
        applySearchResults()
    }

    private func applySearchResults() {
        resultsTable.reloadData()
        let count = searchMode == .symbols ? symbolMatches.count : matches.count
        if count > 0 { resultsTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        if count > 0 { showQuickOpenPanel() } else { hideQuickOpenPanel() }
    }
    @objc private func confirmSearch() {
        let selected = resultsTable.selectedRow
        switch searchMode {
        case .files:
            if selected >= 0 && selected < matches.count { open(matches[selected]) }
            else if let first = matches.first { open(first) }
        case .symbols:
            let symbol = (selected >= 0 && selected < symbolMatches.count) ? symbolMatches[selected] : symbolMatches.first
            guard let symbol else { return }
            hideQuickOpenPanel()
            scrollToLine(symbol.line)
        }
    }
    @objc private func openSelectedResult() { confirmSearch() }
    private func dismissQuickOpen() { hideQuickOpenPanel(); view.window?.makeFirstResponder(editor) }
    private func moveSelection(_ direction: Int) {
        let count = searchMode == .symbols ? symbolMatches.count : matches.count
        guard count > 0 else { return }
        let next = max(0, min(count - 1, resultsTable.selectedRow + direction))
        resultsTable.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        resultsTable.scrollRowToVisible(next)
    }
    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === resultsTable { return searchMode == .symbols ? symbolMatches.count : matches.count }
        if tableView === csvTable {
            guard let index = activeTabIndex, openTabs.indices.contains(index) else { return 0 }
            return max(0, openTabs[index].csvRows.count - 1)
        }
        return 0
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === csvTable {
            guard let index = activeTabIndex, openTabs.indices.contains(index), let tableColumn else { return nil }
            let rows = openTabs[index].csvRows
            let dataRow = row + 1
            guard dataRow < rows.count, let colIndex = tableView.tableColumns.firstIndex(of: tableColumn) else { return nil }
            let id = NSUserInterfaceItemIdentifier("csvCell")
            let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? NSTableCellView()
            cell.identifier = id
            let text = cell.textField ?? NSTextField(labelWithString: "")
            if cell.textField == nil {
                cell.textField = text
                text.translatesAutoresizingMaskIntoConstraints = false
                text.font = .systemFont(ofSize: 12)
                text.lineBreakMode = .byTruncatingTail
                cell.addSubview(text)
                NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6), text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6), text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
            }
            text.stringValue = colIndex < rows[dataRow].count ? rows[dataRow][colIndex] : ""
            text.textColor = NSColor(calibratedWhite: 0.85, alpha: 1)
            return cell
        }

        guard tableView === resultsTable else { return nil }
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
        switch searchMode {
        case .files:
            text.stringValue = relativePath(matches[row])
        case .symbols:
            let symbol = symbolMatches[row]
            text.stringValue = "\(symbol.name)  —  \(symbol.kind) · line \(symbol.line)"
        }
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
    private var highlightGeneration = 0
    private var isLoadingTab = false
    private var pendingDiffWorkItem: DispatchWorkItem?
    private var pendingLSPWorkItem: DispatchWorkItem?
    func textDidChange(_ notification: Notification) {
        guard !isLoadingTab else { return }
        dirty = true
        if let index = activeTabIndex { openTabs[index].dirty = true }
        gutter.invalidate()
        scheduleHighlight()
        scheduleDiffRefresh()
        scheduleLSPDidChange()
    }

    private func scheduleLSPDidChange() {
        pendingLSPWorkItem?.cancel()
        guard let index = activeTabIndex, openTabs.indices.contains(index), openTabs[index].kind == .text, lspManager != nil else { return }
        let url = openTabs[index].url
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, let currentIndex = self.activeTabIndex, self.openTabs.indices.contains(currentIndex), self.openTabs[currentIndex].url == url else { return }
            self.lspManager?.changed(url: url, content: self.openTabs[currentIndex].textStorage.string)
        }
        pendingLSPWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
    }

    // MARK: - Bracket matching

    private var bracketHighlightRanges: [NSRange] = []
    private static let bracketPairs: [Character: Character] = ["(": ")", "[": "]", "{": "}"]
    private static let bracketPairsReversed: [Character: Character] = [")": "(", "]": "[", "}": "{"]
    private static let bracketHighlightColor = NSColor(calibratedWhite: 1.0, alpha: 0.15)

    func textViewDidChangeSelection(_ notification: Notification) {
        updateBracketHighlight()
    }

    private func updateBracketHighlight() {
        guard let index = activeTabIndex, openTabs.indices.contains(index), openTabs[index].kind == .text else { return }
        let textStorage = openTabs[index].textStorage
        for range in bracketHighlightRanges where NSMaxRange(range) <= textStorage.length {
            textStorage.removeAttribute(.backgroundColor, range: range)
        }
        bracketHighlightRanges = []

        let selection = editor.selectedRange()
        guard selection.length == 0 else { return }
        let ns = textStorage.string as NSString
        let location = selection.location
        var matchRanges: [NSRange] = []

        if location < ns.length, let ch = character(in: ns, at: location), let close = Self.bracketPairs[ch],
           let matchLoc = findMatchingBracket(open: ch, close: close, from: location, forward: true, in: ns) {
            matchRanges = [NSRange(location: location, length: 1), NSRange(location: matchLoc, length: 1)]
        } else if location > 0, let ch = character(in: ns, at: location - 1), let open = Self.bracketPairsReversed[ch],
                  let matchLoc = findMatchingBracket(open: open, close: ch, from: location - 1, forward: false, in: ns) {
            matchRanges = [NSRange(location: location - 1, length: 1), NSRange(location: matchLoc, length: 1)]
        }

        guard !matchRanges.isEmpty else { return }
        for range in matchRanges {
            textStorage.addAttribute(.backgroundColor, value: Self.bracketHighlightColor, range: range)
        }
        bracketHighlightRanges = matchRanges
    }

    private func character(in ns: NSString, at index: Int) -> Character? {
        guard let scalar = UnicodeScalar(UInt32(ns.character(at: index))) else { return nil }
        return Character(scalar)
    }

    private func findMatchingBracket(open: Character, close: Character, from location: Int, forward: Bool, in ns: NSString) -> Int? {
        guard let openUnit = String(open).utf16.first, let closeUnit = String(close).utf16.first else { return nil }
        var depth = 0
        if forward {
            var i = location
            while i < ns.length {
                let c = ns.character(at: i)
                if c == openUnit { depth += 1 } else if c == closeUnit {
                    depth -= 1
                    if depth == 0 { return i }
                }
                i += 1
            }
        } else {
            var i = location
            while i >= 0 {
                let c = ns.character(at: i)
                if c == closeUnit { depth += 1 } else if c == openUnit {
                    depth -= 1
                    if depth == 0 { return i }
                }
                i -= 1
            }
        }
        return nil
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
        // Was 0.6s when every refresh spawned two git subprocesses; now that HEAD content is
        // cached per-tab (one subprocess only on first computation), a shorter debounce still
        // stays cheap and the gutter updates noticeably faster.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }

    private func scheduleHighlight() {
        pendingHighlightWorkItem?.cancel()
        guard let index = activeTabIndex, openTabs[index].kind == .text else { return }
        let tab = openTabs[index]
        let url = tab.url
        highlightGeneration += 1
        let generation = highlightGeneration
        let workItem = DispatchWorkItem { [weak self] in
            let text = tab.textStorage.string
            DispatchQueue.global(qos: .userInitiated).async {
                let runs = SyntaxHighlighter.computeRuns(text: text, url: url)
                DispatchQueue.main.async {
                    guard let self, self.highlightGeneration == generation, self.activeTabIndex == index else { return }
                    SyntaxHighlighter.applyRuns(runs, to: tab.textStorage, baseColor: Self.editorTextColor, font: Self.editorFont)
                    self.gutter.invalidate()
                }
            }
        }
        pendingHighlightWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
    }

    // Menu items below deliberately leave `target` unset (nil): AppKit dispatches nil-target
    // actions through the responder chain of whichever window is currently key, which is what
    // lets the same static menu bar correctly address multiple open project windows. The one
    // exception is "New Window," which routes to AppDelegate explicitly since it isn't a
    // per-window action.
    private func buildMenu() {
        let main = NSMenu(title: "SIDE")
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")
        let newWindowItem = fileMenu.addItem(withTitle: "New Window", action: #selector(AppDelegate.newWindow), keyEquivalent: "n")
        newWindowItem.keyEquivalentModifierMask = [.command, .shift]
        newWindowItem.target = NSApp.delegate as? AppDelegate
        fileMenu.addItem(withTitle: "New File", action: #selector(newFile), keyEquivalent: "n")
        fileMenu.addItem(withTitle: "Open Project…", action: #selector(openProject), keyEquivalent: "o")
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "Save", action: #selector(save), keyEquivalent: "s")
        let saveAsItem = fileMenu.addItem(withTitle: "Save As…", action: #selector(saveAs), keyEquivalent: "s")
        saveAsItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(withTitle: "Revert to Saved", action: #selector(revertToSaved), keyEquivalent: "")
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "Close Tab", action: #selector(closeActiveTab), keyEquivalent: "w")
        fileItem.submenu = fileMenu

        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        // Replacing NSApp.mainMenu wholesale means we lose the standard Edit items AppKit
        // normally provides for free — without these, Cmd+A/C/X/V had nothing claiming their
        // key equivalents, so they never reached the text view's built-in key bindings.
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(NSMenuItem.separator())
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
        navigateMenu.addItem(withTitle: "Quick Open", action: #selector(focusQuickOpen), keyEquivalent: "p")
        navigateMenu.addItem(withTitle: "Go to Line…", action: #selector(showGoToLine), keyEquivalent: "l")
        let goToSymbol = navigateMenu.addItem(withTitle: "Go to Symbol…", action: #selector(focusSymbolSearch), keyEquivalent: "o")
        goToSymbol.keyEquivalentModifierMask = [.command, .shift]
        let explorer = navigateMenu.addItem(withTitle: "Toggle File Explorer", action: #selector(toggleFileExplorer), keyEquivalent: "e")
        explorer.keyEquivalentModifierMask = [.command, .shift]
        let jumpToDef = navigateMenu.addItem(withTitle: "Jump to Definition", action: #selector(jumpToDefinition), keyEquivalent: "j")
        jumpToDef.keyEquivalentModifierMask = [.command, .control]
        navigateMenu.addItem(NSMenuItem.separator())
        for i in 1...8 {
            let item = navigateMenu.addItem(withTitle: "Switch to Tab \(i)", action: #selector(switchToTabShortcut(_:)), keyEquivalent: "\(i)")
            item.tag = i - 1
        }
        let lastTab = navigateMenu.addItem(withTitle: "Switch to Last Tab", action: #selector(switchToTabShortcut(_:)), keyEquivalent: "9")
        lastTab.tag = -1
        navigateItem.submenu = navigateMenu
        main.addItem(fileItem); main.addItem(editItem); main.addItem(navigateItem); NSApp.mainMenu = main
    }
    @objc private func focusQuickOpen() {
        searchMode = .files
        searchField.placeholderString = projectURL.map { "Find a file in \($0.lastPathComponent)" } ?? "Open file, symbol, or command"
        searchField.stringValue = ""
        view.window?.makeFirstResponder(searchField)
        performSearch()
    }
    @objc private func focusSymbolSearch() {
        guard activeTabIndex != nil else { return }
        searchMode = .symbols
        searchField.placeholderString = "Go to symbol"
        searchField.stringValue = ""
        view.window?.makeFirstResponder(searchField)
        performSearch()
    }
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
        performSave(tabIndex: index) { _ in }
    }

    @objc private func saveAs() {
        guard let index = activeTabIndex else { return }
        performSaveAs(tabIndex: index) { _ in }
    }

    @objc private func newFile() {
        captureActiveTabSelection()
        Self.untitledCounter += 1
        let name = "Untitled-\(Self.untitledCounter)"
        let url = URL(string: "side-untitled:///\(name)")!
        openTabs.append(OpenTab(url: url, kind: .text, textStorage: NSTextStorage(string: ""), undoManager: UndoManager(), dirty: false, isUntitled: true, knownModificationDate: nil))
        activeTabIndex = openTabs.count - 1
        loadActiveTabIntoEditor()
        view.window?.makeFirstResponder(editor)
    }

    private static var untitledCounter = 0

    /// Resolves the whole save pipeline for a tab: routes untitled tabs to Save As,
    /// checks for out-of-band disk changes, writes, runs a formatter if configured, and
    /// reports success so callers (close/quit prompts) know whether it's safe to proceed.
    private func performSave(tabIndex: Int, completion: @escaping (Bool) -> Void) {
        guard openTabs.indices.contains(tabIndex) else { completion(false); return }
        let tab = openTabs[tabIndex]
        guard tab.kind == .text else { completion(false); return }
        if tab.isUntitled {
            performSaveAs(tabIndex: tabIndex, completion: completion)
            return
        }
        writeTabToDisk(tabIndex: tabIndex, url: tab.url, completion: completion)
    }

    private func performSaveAs(tabIndex: Int, completion: @escaping (Bool) -> Void) {
        guard openTabs.indices.contains(tabIndex), let window = view.window else { completion(false); return }
        let panel = NSSavePanel()
        let currentName = openTabs[tabIndex].url.lastPathComponent
        panel.nameFieldStringValue = openTabs[tabIndex].isUntitled ? "\(currentName).txt" : currentName
        if let projectURL { panel.directoryURL = projectURL }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let newURL = panel.url else { completion(false); return }
            guard self.openTabs.indices.contains(tabIndex) else { completion(false); return }
            self.openTabs[tabIndex].url = newURL
            self.openTabs[tabIndex].isUntitled = false
            self.writeTabToDiskForced(tabIndex: tabIndex, url: newURL) { success in
                if success {
                    if self.activeTabIndex == tabIndex {
                        UserDefaults.standard.set(newURL.path, forKey: self.lastFileKey)
                        self.onFileOpened?(newURL)
                        SyntaxHighlighter.apply(to: self.openTabs[tabIndex].textStorage, url: newURL, baseColor: Self.editorTextColor, font: Self.editorFont)
                        self.gutter.invalidate()
                    }
                    self.rebuildTabBar()
                }
                completion(success)
            }
        }
    }

    private func writeTabToDisk(tabIndex: Int, url: URL, completion: @escaping (Bool) -> Void) {
        guard openTabs.indices.contains(tabIndex), let window = view.window else { completion(false); return }
        let tab = openTabs[tabIndex]
        if let known = tab.knownModificationDate, let onDisk = modificationDate(of: url), onDisk > known {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "\u{201C}\(url.lastPathComponent)\u{201D} has changed on disk"
            alert.informativeText = "This file was modified outside SIDE since you opened it. Overwriting will discard those external changes."
            alert.addButton(withTitle: "Overwrite")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self else { completion(false); return }
                if response == .alertFirstButtonReturn {
                    self.writeTabToDiskForced(tabIndex: tabIndex, url: url, completion: completion)
                } else {
                    completion(false)
                }
            }
            return
        }
        writeTabToDiskForced(tabIndex: tabIndex, url: url, completion: completion)
    }

    private func writeTabToDiskForced(tabIndex: Int, url: URL, completion: @escaping (Bool) -> Void) {
        guard openTabs.indices.contains(tabIndex) else { completion(false); return }
        let content = openTabs[tabIndex].textStorage.string
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            openTabs[tabIndex].knownModificationDate = modificationDate(of: url)
            runFormatterIfNeeded(tabIndex: tabIndex, url: url, completion: completion)
        } catch {
            guard let window = view.window else { completion(false); return }
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Couldn't save \u{201C}\(url.lastPathComponent)\u{201D}"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.beginSheetModal(for: window) { _ in completion(false) }
        }
    }

    private func runFormatterIfNeeded(tabIndex: Int, url: URL, completion: @escaping (Bool) -> Void) {
        guard let projectURL, let formatter = Self.formatterCommand(for: url, projectRoot: projectURL) else {
            finishSave(tabIndex: tabIndex)
            completion(true)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: formatter.executable)
            process.arguments = formatter.args
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try? process.run()
            process.waitUntilExit()
            let formattedContent = try? String(contentsOf: url, encoding: .utf8)
            DispatchQueue.main.async {
                guard let self, self.openTabs.indices.contains(tabIndex) else { completion(true); return }
                let tab = self.openTabs[tabIndex]
                if let formattedContent, formattedContent != tab.textStorage.string {
                    let fullRange = NSRange(location: 0, length: tab.textStorage.length)
                    tab.textStorage.replaceCharacters(in: fullRange, with: formattedContent)
                    SyntaxHighlighter.apply(to: tab.textStorage, url: url, baseColor: Self.editorTextColor, font: Self.editorFont)
                    if self.activeTabIndex == tabIndex { self.gutter.invalidate() }
                }
                // Re-read even when content didn't change: some formatters touch the file
                // (rewriting it in place) without altering its bytes, which would otherwise
                // leave knownModificationDate pointing at the pre-formatter write and trigger
                // a false "changed on disk" prompt on the next save.
                self.openTabs[tabIndex].knownModificationDate = self.modificationDate(of: url)
                self.finishSave(tabIndex: tabIndex)
                completion(true)
            }
        }
    }

    private func finishSave(tabIndex: Int) {
        guard openTabs.indices.contains(tabIndex) else { return }
        openTabs[tabIndex].dirty = false
        if activeTabIndex == tabIndex { dirty = false }
        rebuildTabBar()
        refreshGitDiffMarks()
    }

    @objc private func revertToSaved() {
        guard let index = activeTabIndex, openTabs.indices.contains(index), !openTabs[index].isUntitled, openTabs[index].kind == .text, let window = view.window else { return }
        let tab = openTabs[index]
        guard tab.dirty else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Revert \u{201C}\(tab.url.lastPathComponent)\u{201D} to the version on disk?"
        alert.informativeText = "Your unsaved changes will be lost."
        alert.addButton(withTitle: "Revert")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            guard let source = try? String(contentsOf: tab.url, encoding: .utf8) else { return }
            let fullRange = NSRange(location: 0, length: tab.textStorage.length)
            tab.textStorage.replaceCharacters(in: fullRange, with: source)
            SyntaxHighlighter.apply(to: tab.textStorage, url: tab.url, baseColor: Self.editorTextColor, font: Self.editorFont)
            self.openTabs[index].dirty = false
            self.openTabs[index].knownModificationDate = self.modificationDate(of: tab.url)
            if self.activeTabIndex == index { self.dirty = false; self.gutter.invalidate() }
            self.rebuildTabBar()
            self.refreshGitDiffMarks()
        }
    }

    private static func formatterCommand(for url: URL, projectRoot: URL) -> (executable: String, args: [String])? {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "js", "jsx", "ts", "tsx", "json", "md", "css", "html", "yaml", "yml":
            let local = projectRoot.appendingPathComponent("node_modules/.bin/prettier").path
            if FileManager.default.isExecutableFile(atPath: local) { return (local, ["--write", url.path]) }
            if let global = which("prettier") { return (global, ["--write", url.path]) }
            return nil
        case "swift":
            if let global = which("swift-format") { return (global, ["-i", url.path]) }
            return nil
        default:
            return nil
        }
    }

    private static func which(_ tool: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", tool]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (path?.isEmpty == false) ? path : nil
    }
    func restoreLastSessionIfAvailable() { guard let saved = UserDefaults.standard.string(forKey: lastProjectKey) else { return }; let url = URL(fileURLWithPath: saved); var isDirectory: ObjCBool = false; guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return }; loadProject(at: url, restoring: true) }

    /// Detaches floating child windows and event monitors before the owning window closes.
    /// Child windows left attached to a parent that's being deallocated, and global event
    /// monitors whose closures outlive their view controller, are both plausible sources of
    /// undefined behavior on window teardown — this makes sure neither lingers.
    func prepareForClose() {
        removeQuickOpenDismissMonitors()
        removeFileExplorerDismissMonitors()
        if quickOpenPanel.parent != nil { view.window?.removeChildWindow(quickOpenPanel) }
        quickOpenPanel.orderOut(nil)
        if fileExplorerPanel.parent != nil { view.window?.removeChildWindow(fileExplorerPanel) }
        fileExplorerPanel.orderOut(nil)
        lspManager?.prepareForClose()
    }
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
