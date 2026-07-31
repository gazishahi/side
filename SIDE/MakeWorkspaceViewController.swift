import AppKit

private extension NSToolbarItem.Identifier {
    static let quickOpen = NSToolbarItem.Identifier("side.quick-open")
}

final class MakeWorkspaceViewController: NSViewController, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate {
    private let searchField = QuickOpenSearchField()
    private let projectLabel = NSTextField(labelWithString: "No project open")
    private let fileLabel = NSTextField(labelWithString: "")
    private let editor = NSTextView()
    private let editorScroll = NSScrollView()
    private let fileHeader = NSView()
    private let emptyState = NSStackView()
    private let quickOpenPanel = QuickOpenPanel()
    private let resultsTable = NSTableView()
    private var projectURL: URL?
    private var allFiles: [URL] = []
    private var matches: [URL] = []
    private var currentFile: URL?
    private var dirty = false { didSet { updateTitle() } }
    var onProjectOpened: ((URL) -> Void)?
    private let lastProjectKey = "side.last-project-path"
    private let lastFileKey = "side.last-file-path"
    private lazy var toolbarCoordinator = WorkspaceToolbarCoordinator(searchField: searchField)

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
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(confirmSearch)
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextCompletionEnabled = false
        editor.usesFindBar = true
        editor.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        editor.textColor = .labelColor
        editor.backgroundColor = .textBackgroundColor
        editor.insertionPointColor = .controlAccentColor
        editor.textContainerInset = NSSize(width: 34, height: 28)
        editor.delegate = self
        editor.isEditable = false
        editorScroll.documentView = editor
        editorScroll.hasVerticalScroller = true
        editorScroll.autohidesScrollers = true
        editorScroll.drawsBackground = true
        editorScroll.backgroundColor = .textBackgroundColor
        editorScroll.isHidden = true
        editorScroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(editorScroll)

        fileHeader.wantsLayer = true
        fileHeader.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        fileHeader.isHidden = true
        fileHeader.translatesAutoresizingMaskIntoConstraints = false
        fileLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        fileLabel.textColor = .secondaryLabelColor
        fileLabel.lineBreakMode = .byTruncatingHead
        fileLabel.translatesAutoresizingMaskIntoConstraints = false
        fileHeader.addSubview(fileLabel)
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        fileHeader.addSubview(divider)
        view.addSubview(fileHeader)
        NSLayoutConstraint.activate([
            fileHeader.topAnchor.constraint(equalTo: view.topAnchor), fileHeader.leadingAnchor.constraint(equalTo: view.leadingAnchor), fileHeader.trailingAnchor.constraint(equalTo: view.trailingAnchor), fileHeader.heightAnchor.constraint(equalToConstant: 28),
            fileLabel.leadingAnchor.constraint(equalTo: fileHeader.leadingAnchor, constant: 14), fileLabel.trailingAnchor.constraint(lessThanOrEqualTo: fileHeader.trailingAnchor, constant: -14), fileLabel.centerYAnchor.constraint(equalTo: fileHeader.centerYAnchor),
            divider.leadingAnchor.constraint(equalTo: fileHeader.leadingAnchor), divider.trailingAnchor.constraint(equalTo: fileHeader.trailingAnchor), divider.bottomAnchor.constraint(equalTo: fileHeader.bottomAnchor)
        ])

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
            editorScroll.topAnchor.constraint(equalTo: fileHeader.bottomAnchor), editorScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), editorScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor), editorScroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            emptyState.centerXAnchor.constraint(equalTo: view.centerXAnchor), emptyState.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -30), detail.widthAnchor.constraint(lessThanOrEqualToConstant: 460)
        ])
        configureQuickOpenPanel()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard let window = view.window, window.toolbar == nil else { return }
        let toolbar = NSToolbar(identifier: "side.workspace.toolbar")
        toolbar.delegate = toolbarCoordinator
        toolbar.centeredItemIdentifier = .quickOpen
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
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
        projectLabel.stringValue = url.lastPathComponent
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

    nonisolated private static func indexFiles(at root: URL) -> [URL] {
        let ignored: Set<String> = [".git", ".build", "DerivedData", "node_modules", ".next", "Pods", "dist", "build"]
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else { return [] }
        var indexed: [URL] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: keys)
            if values?.isDirectory == true && ignored.contains(url.lastPathComponent) { enumerator.skipDescendants(); continue }
            if values?.isRegularFile == true && !url.pathExtension.isEmpty { indexed.append(url) }
        }
        return indexed.sorted {
            let lhs = $0.path.replacingOccurrences(of: root.path + "/", with: "")
            let rhs = $1.path.replacingOccurrences(of: root.path + "/", with: "")
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }

    private func open(_ url: URL) {
        guard let source = try? String(contentsOf: url, encoding: .utf8) else { return }
        currentFile = url
        editor.string = source
        editor.isEditable = true
        editorScroll.isHidden = false
        fileHeader.isHidden = false
        fileLabel.stringValue = relativePath(url)
        searchField.stringValue = ""
        dirty = false
        UserDefaults.standard.set(url.path, forKey: lastFileKey)
        hideQuickOpenPanel()
        view.window?.makeFirstResponder(editor)
    }

    private func relativePath(_ url: URL) -> String {
        guard let projectURL else { return url.path }
        return url.path.replacingOccurrences(of: projectURL.path + "/", with: "")
    }

    func controlTextDidBeginEditing(_ obj: Notification) { refreshMatches(showingPalette: true) }
    func controlTextDidChange(_ obj: Notification) { refreshMatches(showingPalette: true) }
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
    func textDidChange(_ notification: Notification) { dirty = true }

    private func buildMenu() {
        let main = NSMenu(title: "SIDE")
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")
        let openItem = fileMenu.addItem(withTitle: "Open Project…", action: #selector(openProject), keyEquivalent: "o"); openItem.target = self
        let saveItem = fileMenu.addItem(withTitle: "Save", action: #selector(save), keyEquivalent: "s"); saveItem.target = self
        fileItem.submenu = fileMenu
        let navigateItem = NSMenuItem(title: "Navigate", action: nil, keyEquivalent: "")
        let navigateMenu = NSMenu(title: "Navigate")
        let quickOpen = navigateMenu.addItem(withTitle: "Quick Open", action: #selector(focusQuickOpen), keyEquivalent: "p"); quickOpen.target = self
        navigateItem.submenu = navigateMenu
        main.addItem(fileItem); main.addItem(navigateItem); NSApp.mainMenu = main
    }
    @objc private func focusQuickOpen() { searchField.stringValue = ""; view.window?.makeFirstResponder(searchField); refreshMatches(showingPalette: true) }
    @objc private func save() { guard let currentFile else { return }; try? editor.string.write(to: currentFile, atomically: true, encoding: .utf8); dirty = false }
    private func restoreLastSession() { guard let saved = UserDefaults.standard.string(forKey: lastProjectKey) else { return }; let url = URL(fileURLWithPath: saved); var isDirectory: ObjCBool = false; guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return }; loadProject(at: url, restoring: true) }
    private func updateTitle() { view.window?.title = dirty ? "Side — \(currentFile?.lastPathComponent ?? "") •" : "Side" }
}

private final class WorkspaceToolbarCoordinator: NSObject, NSToolbarDelegate {
    private let searchField: NSSearchField
    init(searchField: NSSearchField) { self.searchField = searchField }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.quickOpen] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard itemIdentifier == .quickOpen else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.widthAnchor.constraint(equalToConstant: 410).isActive = true
        item.view = searchField
        item.label = "Quick Open"
        return item
    }
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

private final class QuickOpenSearchField: NSSearchField {
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
