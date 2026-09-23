import AppKit
import Heron
import UniformTypeIdentifiers

/// Make's file explorer: a transient glass overlay over the leading edge, never a permanent
/// sidebar (Direction 02 rules those out). Its own component so Make only hosts it.
///
/// Built to stay fast on any project: folders load their contents the first time they are
/// expanded (the old tree was built from the whole 25 000-file index before it could show a
/// row), rows are reused, icons are cached per file type, and file-system changes reload only
/// the folders they touched — keeping what's expanded and what's selected.
@MainActor
final class FileExplorer: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
    /// One file or folder. `children` is nil until the folder is first expanded.
    final class Node {
        let url: URL
        var name: String { url.lastPathComponent }
        let isDirectory: Bool
        weak var parent: Node?
        var children: [Node]?
        init(url: URL, isDirectory: Bool, parent: Node?) {
            self.url = url.standardizedFileURL
            self.isDirectory = isDirectory
            self.parent = parent
        }
    }

    enum GitMark { case modified, added, conflicted }

    /// Which edge the explorer slides in from. A preference — Settings › General, or the
    /// button in the explorer's own header.
    enum Side: String, CaseIterable {
        case left, right
        var title: String { self == .left ? "Left" : "Right" }
        static let didChangeNotification = Notification.Name("SideExplorerSideDidChange")
        private static let key = "SideExplorerSide"
        static var preferred: Side {
            get { UserDefaults.standard.string(forKey: key).flatMap(Side.init(rawValue:)) ?? .left }
            set {
                UserDefaults.standard.set(newValue.rawValue, forKey: key)
                NotificationCenter.default.post(name: didChangeNotification, object: nil)
            }
        }
    }

    // Host callbacks
    var onOpen: ((URL) -> Void)?
    var onMoved: ((URL, URL) -> Void)?
    var onTrashed: ((URL) -> Void)?
    var onFilesChanged: (() -> Void)?
    var currentFile: (() -> URL?)?
    var onHidden: (() -> Void)?

    private(set) var root: URL?
    private var rootNode: Node?
    /// Loaded folders by path — so a change event finds the one folder to reload.
    private var loadedDirectories: [String: Node] = [:]
    private var gitMarks: [String: GitMark] = [:]
    private var gitGeneration = 0
    private var pendingChanges: Set<String> = []
    private var pendingReload: DispatchWorkItem?
    private var iconCache: [String: NSImage] = [:]
    private weak var hostWindow: NSWindow?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var renaming: Node?

    private lazy var panel: FileExplorerPanel = {
        let panel = FileExplorerPanel()
        panel.contentView = surface
        return panel
    }()
    private let outline = ExplorerOutlineView()
    private let titleLabel = NSTextField(labelWithString: "")
    private lazy var surface: NSView = makeSurface()

    static let width: CGFloat = 300
    private static let rowHeight: CGFloat = 24

    var isVisible: Bool { panel.isVisible }

    // MARK: Root and loading

    func setRoot(_ url: URL?) {
        guard url?.standardizedFileURL != root?.standardizedFileURL else { return }
        root = url
        loadedDirectories = [:]
        gitMarks = [:]
        rootNode = url.map { Node(url: $0, isDirectory: true, parent: nil) }
        titleLabel.stringValue = url?.lastPathComponent ?? ""
        outline.reloadData()
    }

    private func children(of node: Node) -> [Node] {
        if let loaded = node.children { return loaded }
        let loaded = Self.listDirectory(node.url).map { Node(url: $0.url, isDirectory: $0.isDirectory, parent: node) }
        node.children = loaded
        loadedDirectories[node.url.path] = node
        return loaded
    }

    /// One directory, the same exclusions as Quick Open and the agent's file tools: hidden
    /// files and the generated/vendored folders nobody browses.
    nonisolated static func listDirectory(_ url: URL) -> [(url: URL, isDirectory: Bool)] {
        let keys: [URLResourceKey] = [.isDirectoryKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return urls.compactMap { url -> (URL, Bool)? in
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory && ProjectFileAccess.ignoredDirectories.contains(url.lastPathComponent) { return nil }
            return (url, isDirectory)
        }
        .sorted { a, b in
            if a.1 != b.1 { return a.1 }
            return a.0.lastPathComponent.localizedStandardCompare(b.0.lastPathComponent) == .orderedAscending
        }
    }

    // MARK: Showing

    func toggle(in window: NSWindow) {
        isVisible ? hide() : show(in: window)
    }

    /// Slides in from the leading edge, under the top row and above the floating bar.
    func show(in window: NSWindow) {
        guard rootNode != nil else { return }
        hostWindow = window
        let frame = window.frame
        let top = frame.maxY - ChromeHost.rowHeight - 8
        let bottom = frame.minY + ChromeHost.barGap + ChromeHost.barHeight + 12
        let side = Side.preferred
        let x = side == .left ? frame.minX + 10 : frame.maxX - Self.width - 10
        let target = NSRect(x: x, y: bottom, width: Self.width, height: max(200, top - bottom))
        panel.alphaValue = 0
        panel.setFrame(target.offsetBy(dx: side == .left ? -24 : 24, dy: 0), display: false)
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
        refreshGitStatus()
        revealCurrentFile()
        installDismissMonitors()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = DS.Motion.duration(0.24)
            context.timingFunction = DS.Motion.curve
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        } completionHandler: { [weak self] in
            guard let self else { return }
            self.panel.makeKey()
            self.panel.makeFirstResponder(self.outline)
        }
    }

    func hide() {
        removeDismissMonitors()
        guard panel.isVisible else { return }
        let end = panel.frame.offsetBy(dx: Side.preferred == .left ? -20 : 20, dy: 0)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = DS.Motion.duration(0.16)
            context.timingFunction = DS.Motion.curve
            panel.animator().setFrame(end, display: true)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self else { return }
            self.hostWindow?.removeChildWindow(self.panel)
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
        }
        onHidden?()
    }

    func tearDown() {
        removeDismissMonitors()
        if panel.parent != nil { hostWindow?.removeChildWindow(panel) }
        panel.orderOut(nil)
    }

    /// Expands down to the file open in the editor and selects it.
    private func revealCurrentFile() {
        guard let file = currentFile?()?.standardizedFileURL, let rootNode, file.path.hasPrefix(rootNode.url.path + "/") else { return }
        var node = rootNode
        let parts = file.path.dropFirst(rootNode.url.path.count + 1).split(separator: "/").map(String.init)
        for (index, part) in parts.enumerated() {
            guard let next = children(of: node).first(where: { $0.name == part }) else { return }
            if index < parts.count - 1 { outline.expandItem(next) }
            node = next
        }
        let row = outline.row(forItem: node)
        guard row >= 0 else { return }
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outline.scrollRowToVisible(row)
    }

    private func installDismissMonitors() {
        guard localMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.window !== self.panel, self.renaming == nil { self.hide() }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    private func removeDismissMonitors() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
    }

    // MARK: Surface

    private func makeSurface() -> NSView {
        outline.headerView = nil
        outline.style = .sourceList
        outline.selectionHighlightStyle = .sourceList
        outline.backgroundColor = .clear
        outline.rowHeight = Self.rowHeight
        outline.indentationPerLevel = 14
        outline.floatsGroupRows = false
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(openSelected)
        outline.onEscape = { [weak self] in self?.hide() }
        outline.onEnter = { [weak self] in self?.openSelected() }
        outline.onTrash = { [weak self] in self?.trashSelected() }
        outline.registerForDraggedTypes([.fileURL])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = DS.Text.body(.semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        let newFile = Self.headerButton("doc.badge.plus", "New File", #selector(newFileAtRoot), self)
        let newFolder = Self.headerButton("folder.badge.plus", "New Folder", #selector(newFolderAtRoot), self)
        // Two unambiguous glyphs and one overflow menu — the collapse and move-side glyphs read
        // as nothing in particular. Which side the explorer opens on lives in Settings.
        let more = NSButton(image: NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "More")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)) ?? NSImage(), target: self, action: #selector(showMoreMenu(_:)))
        more.isBordered = false
        more.contentTintColor = .secondaryLabelColor
        more.toolTip = "More"
        more.translatesAutoresizingMaskIntoConstraints = false
        more.widthAnchor.constraint(equalToConstant: 24).isActive = true
        let header = NSStackView(views: [titleLabel, NSView(), newFile, newFolder, more])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = DS.Spacing.xs
        header.setClippingResistancePriority(.defaultLow, for: .horizontal)
        header.translatesAutoresizingMaskIntoConstraints = false

        let body = NSView()
        body.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(header)
        body.addSubview(scroll)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: body.topAnchor, constant: 10),
            header.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -10),
            header.heightAnchor.constraint(equalToConstant: 26),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -8),
        ])

        // Behind-window material, not in-window glass: the explorer is its own child window, and
        // glass only refracts content inside the window it lives in.
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.maskImage = DS.roundedMask(radius: 16)
        effect.addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: effect.topAnchor), body.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: effect.trailingAnchor), body.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        effect.setAccessibilityElement(true)
        effect.setAccessibilityRole(.group)
        effect.setAccessibilityLabel("Files")
        return effect
    }

    @objc private func showMoreMenu(_ sender: NSButton) {
        let menu = NSMenu()
        for (title, action) in [("Collapse All Folders", #selector(collapseAll)), ("Reveal Project in Finder", #selector(revealRoot))] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    @objc private func revealRoot() {
        guard let root else { return }
        NSWorkspace.shared.activateFileViewerSelecting([root])
    }

    /// The side changed (here or in Settings): move without hiding, so nothing is lost.
    private func sideDidChange() {
        guard panel.isVisible, let window = hostWindow else { return }
        let frame = window.frame
        var target = panel.frame
        target.origin.x = Side.preferred == .left ? frame.minX + 10 : frame.maxX - Self.width - 10
        NSAnimationContext.runAnimationGroup { context in
            context.duration = DS.Motion.duration(0.24)
            context.timingFunction = DS.Motion.curve
            panel.animator().setFrame(target, display: true)
        }
    }

    override init() {
        super.init()
        NotificationCenter.default.addObserver(forName: Side.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sideDidChange() }
        }
    }

    private static func headerButton(_ symbol: String, _ label: String, _ action: Selector, _ target: AnyObject) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)) ?? NSImage(), target: target, action: action)
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = label
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        return button
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = (item as? Node) ?? rootNode else { return 0 }
        return children(of: node).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        let node = (item as? Node) ?? rootNode!
        return children(of: node)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? Node)?.isDirectory ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
        (item as? Node)?.name
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }
        let id = NSUserInterfaceItemIdentifier("explorerRow")
        let cell = outlineView.makeView(withIdentifier: id, owner: self) as? ExplorerCellView ?? ExplorerCellView()
        cell.identifier = id
        cell.configure(name: node.name, icon: icon(for: node), mark: mark(for: node))
        cell.textField?.delegate = self
        return cell
    }

    private func icon(for node: Node) -> NSImage {
        let key = node.isDirectory ? "/folder" : node.url.pathExtension.lowercased()
        if let cached = iconCache[key] { return cached }
        let type: UTType = node.isDirectory ? .folder : (UTType(filenameExtension: node.url.pathExtension) ?? .data)
        let image = NSWorkspace.shared.icon(for: type)
        image.size = NSSize(width: 16, height: 16)
        iconCache[key] = image
        return image
    }

    // MARK: Git status

    private func mark(for node: Node) -> GitMark? { gitMarks[node.url.path] }

    /// `git status` off the main thread; a file's mark also lands on every folder above it, so a
    /// collapsed folder still says something inside it changed.
    private func refreshGitStatus() {
        guard let root else { return }
        gitGeneration += 1
        let generation = gitGeneration
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let marks = Self.gitMarks(root: root)
            DispatchQueue.main.async {
                guard let self, self.gitGeneration == generation else { return }
                self.gitMarks = marks
                self.outline.reloadData(forRowIndexes: IndexSet(integersIn: 0..<self.outline.numberOfRows), columnIndexes: IndexSet(integer: 0))
            }
        }
    }

    nonisolated static func gitMarks(root: URL) -> [String: GitMark] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", root.path, "status", "--porcelain=v1", "-z", "--untracked-files=all"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()  // read before waiting
        process.waitUntilExit()
        return parseStatus(data, root: root)
    }

    /// Parses `git status --porcelain=v1 -z`. Renames carry their source as the next field.
    nonisolated static func parseStatus(_ data: Data, root: URL) -> [String: GitMark] {
        var marks: [String: GitMark] = [:]
        let rootPath = root.standardizedFileURL.path
        let fields = data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        var index = 0
        while index < fields.count {
            let entry = fields[index]
            index += 1
            guard entry.count > 3 else { continue }
            let code = String(entry.prefix(2))
            let path = String(entry.dropFirst(3))
            if code.first == "R" || code.first == "C" { index += 1 }
            let mark: GitMark
            if code.contains("U") || code == "AA" || code == "DD" { mark = .conflicted }
            else if code == "??" || code.contains("A") { mark = .added }
            else if code.contains("D") { continue }
            else { mark = .modified }
            var url = URL(fileURLWithPath: rootPath).appendingPathComponent(path).standardizedFileURL
            marks[url.path] = mark
            // Every folder above it, stopping at the root. Conflicts outrank the rest.
            while true {
                url = url.deletingLastPathComponent()
                guard url.path.count > rootPath.count else { break }
                // A folder takes its contents' mark: green when everything in it is new, amber
                // once the contents are mixed; a conflict anywhere inside wins.
                switch (marks[url.path], mark) {
                case (.conflicted?, _): break
                case (_, .conflicted): marks[url.path] = .conflicted
                case (nil, _): marks[url.path] = mark
                case (let existing?, _) where existing != mark: marks[url.path] = .modified
                default: break
                }
            }
        }
        return marks
    }

    // MARK: Changes on disk

    /// From the project watcher: reload only the folders these paths live in, keeping what's
    /// expanded and selected.
    func filesChanged(_ urls: [URL]) {
        guard rootNode != nil else { return }
        for url in urls { pendingChanges.insert(url.standardizedFileURL.deletingLastPathComponent().path) }
        pendingReload?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.applyPendingChanges() }
        pendingReload = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    private func applyPendingChanges() {
        let folders = pendingChanges
        pendingChanges = []
        for path in folders {
            guard let node = loadedDirectories[path] else { continue }  // never expanded: nothing to redo
            reload(node)
        }
        if panel.isVisible { refreshGitStatus() }
    }

    /// Re-reads one folder, reusing the nodes that are still there so expansion survives.
    private func reload(_ node: Node) {
        let existing = Dictionary((node.children ?? []).map { ($0.url.path, $0) }, uniquingKeysWith: { a, _ in a })
        let selected = outline.item(atRow: outline.selectedRow) as? Node
        node.children = Self.listDirectory(node.url).map { entry in
            existing[entry.url.standardizedFileURL.path] ?? Node(url: entry.url, isDirectory: entry.isDirectory, parent: node)
        }
        for gone in Set(existing.keys).subtracting(node.children!.map(\.url.path)) { loadedDirectories.removeValue(forKey: gone) }
        outline.reloadItem(node === rootNode ? nil : node, reloadChildren: true)
        if let selected {
            let row = outline.row(forItem: selected)
            if row >= 0 { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        }
    }

    // MARK: Actions

    private var selectedNode: Node? { outline.item(atRow: outline.selectedRow) as? Node }
    private var clickedNode: Node? { outline.clickedRow >= 0 ? outline.item(atRow: outline.clickedRow) as? Node : nil }
    private var actionNode: Node? { clickedNode ?? selectedNode }

    @objc private func openSelected() {
        guard let node = selectedNode else { return }
        if node.isDirectory {
            outline.isItemExpanded(node) ? outline.collapseItem(node) : outline.expandItem(node)
        } else {
            onOpen?(node.url)
            hide()
        }
    }

    @objc private func collapseAll() { outline.collapseItem(nil, collapseChildren: true) }
    @objc private func newFileAtRoot() { create(folder: false, in: rootNode) }
    @objc private func newFolderAtRoot() { create(folder: true, in: rootNode) }

    /// Finder's way: make "untitled", then rename it in place.
    private func create(folder: Bool, in parent: Node?) {
        guard let parent = parent ?? rootNode else { return }
        let base = folder ? "untitled folder" : "untitled"
        var url = parent.url.appendingPathComponent(base)
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = parent.url.appendingPathComponent("\(base) \(counter)")
            counter += 1
        }
        do {
            if folder { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false) }
            else if !FileManager.default.createFile(atPath: url.path, contents: Data()) { throw CocoaError(.fileWriteUnknown) }
        } catch {
            present(error, "Couldn't create \(folder ? "folder" : "file")")
            return
        }
        if parent !== rootNode { outline.expandItem(parent) }
        reload(parent)
        onFilesChanged?()
        if let node = parent.children?.first(where: { $0.url.path == url.standardizedFileURL.path }) { beginRename(node) }
    }

    private func beginRename(_ node: Node) {
        let row = outline.row(forItem: node)
        guard row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? ExplorerCellView, let field = cell.textField else { return }
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outline.scrollRowToVisible(row)
        renaming = node
        field.isEditable = true
        panel.makeFirstResponder(field)
        // Select the name without its extension, as Finder does.
        let name = node.name as NSString
        let stem = node.isDirectory || name.pathExtension.isEmpty ? name.length : name.length - name.pathExtension.count - 1
        field.currentEditor()?.selectedRange = NSRange(location: 0, length: stem)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let node = renaming else { return }
        renaming = nil
        field.isEditable = false
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        panel.makeFirstResponder(outline)
        guard !name.isEmpty, name != node.name, !name.contains("/") else { field.stringValue = node.name; return }
        move(node, to: node.url.deletingLastPathComponent().appendingPathComponent(name))
    }

    private func move(_ node: Node, to destination: URL) {
        let source = node.url
        do {
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            present(error, "Couldn't move \u{201C}\(node.name)\u{201D}")
            outline.reloadItem(node)
            return
        }
        onMoved?(source, destination)
        let destinationFolder = loadedDirectories[destination.deletingLastPathComponent().standardizedFileURL.path]
        if let from = node.parent { reload(from) }
        if let destinationFolder, destinationFolder !== node.parent { reload(destinationFolder) }
        onFilesChanged?()
        if let moved = loadedDirectories[destination.deletingLastPathComponent().standardizedFileURL.path]?.children?.first(where: { $0.url.path == destination.standardizedFileURL.path }) {
            let row = outline.row(forItem: moved)
            if row >= 0 { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        }
    }

    private func trashSelected() {
        guard let node = actionNode, let window = hostWindow else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Move \u{201C}\(node.name)\u{201D} to the Trash?"
        alert.informativeText = node.isDirectory ? "This folder and everything inside it will be moved to the Trash." : "This file will be moved to the Trash."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        renaming = node  // keep the panel open while the sheet is up
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.renaming = nil
            guard response == .alertFirstButtonReturn else { return }
            do {
                try FileManager.default.trashItem(at: node.url, resultingItemURL: nil)
            } catch {
                self.present(error, "Couldn't move \u{201C}\(node.name)\u{201D} to the Trash")
                return
            }
            self.onTrashed?(node.url)
            if let parent = node.parent { self.reload(parent) }
            self.onFilesChanged?()
        }
    }

    private func present(_ error: Error, _ message: String) {
        guard let window = hostWindow else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let node = clickedNode
        let folder = node.flatMap { $0.isDirectory ? $0 : $0.parent } ?? rootNode
        func add(_ title: String, _ action: @escaping () -> Void) {
            let item = ClosureMenuItem(title: title, action: action)
            menu.addItem(item)
        }
        if let node {
            add(node.isDirectory ? "Expand" : "Open") { [weak self] in
                guard let self else { return }
                if node.isDirectory { self.outline.expandItem(node) } else { self.onOpen?(node.url); self.hide() }
            }
            add("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
            add("Copy Path") { Self.copy(node.url.path) }
            if let root = rootNode {
                add("Copy Relative Path") { Self.copy(String(node.url.path.dropFirst(root.url.path.count + 1))) }
            }
            menu.addItem(.separator())
        }
        add("New File") { [weak self] in self?.create(folder: false, in: folder) }
        add("New Folder") { [weak self] in self?.create(folder: true, in: folder) }
        if let node {
            menu.addItem(.separator())
            add("Rename") { [weak self] in self?.beginRename(node) }
            add("Move to Trash") { [weak self] in
                guard let self else { return }
                let row = self.outline.row(forItem: node)
                if row >= 0 { self.outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
                self.trashSelected()
            }
        }
    }

    private static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    // MARK: Drag to move

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        (item as? Node)?.url as NSURL?
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard info.draggingSource as? NSOutlineView === outline else { return [] }
        // Drop onto a folder (or the root), never between rows: position within a folder is
        // alphabetical, not the user's.
        var target = (item as? Node) ?? rootNode
        if let node = target, !node.isDirectory { target = node.parent }
        guard let folder = target else { return [] }
        outlineView.setDropItem(folder === rootNode ? nil : folder, dropChildIndex: NSOutlineViewDropOnItemIndex)
        let sources = Self.draggedURLs(info)
        let valid = sources.allSatisfy { source in
            source.deletingLastPathComponent().standardizedFileURL != folder.url && !folder.url.path.hasPrefix(source.path + "/") && folder.url != source.standardizedFileURL
        }
        return valid && !sources.isEmpty ? .move : []
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let folder = (item as? Node) ?? rootNode else { return false }
        var moved = false
        for source in Self.draggedURLs(info) {
            let node = findNode(for: source)
            let destination = folder.url.appendingPathComponent(source.lastPathComponent)
            if let node { move(node, to: destination); moved = true }
        }
        if moved { reload(folder) }
        return moved
    }

    private static func draggedURLs(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []).map(\.standardizedFileURL)
    }

    private func findNode(for url: URL) -> Node? {
        loadedDirectories[url.deletingLastPathComponent().path]?.children?.first { $0.url.path == url.path }
    }
}

/// A menu item that runs a closure — the explorer's context menu is rebuilt per click.
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func run() { handler() }
}

/// Icon, name, and a git dot trailing when the file (or something inside the folder) changed.
private final class ExplorerCellView: NSTableCellView {
    private let dot = DS.StatusDot(state: .idle, diameter: 6)

    init() {
        super.init(frame: .zero)
        let icon = NSImageView()
        let text = NSTextField(labelWithString: "")
        text.font = DS.Text.body()
        text.lineBreakMode = .byTruncatingMiddle
        text.cell?.usesSingleLineMode = true
        text.isEditable = false
        text.focusRingType = .none
        for view in [icon, text] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        addSubview(dot)
        imageView = icon
        textField = text
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: dot.leadingAnchor, constant: -6),
            dot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(name: String, icon: NSImage, mark: FileExplorer.GitMark?) {
        textField?.stringValue = name
        textField?.isEditable = false
        imageView?.image = icon
        switch mark {
        case .added: dot.state = .verified
        case .modified: dot.state = .needsYou
        case .conflicted: dot.state = .failed
        case nil: break
        }
        dot.isHidden = mark == nil
        let spoken = mark.map { m -> String in
            switch m { case .added: return "new"; case .modified: return "modified"; case .conflicted: return "conflicted" }
        }
        setAccessibilityLabel(spoken.map { "\(name), \($0)" } ?? name)
    }
}
