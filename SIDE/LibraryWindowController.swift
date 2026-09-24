import AppKit
import Heron

/// Library (`SIDE_RFC_LIBRARY.md`): what shapes an agent's behavior, in one window (⇧⌘L). Not a
/// stage: it follows the frontmost project window and edits nothing silently. Files open in
/// Make; anything that changes what an agent receives says so where it's changed.
@MainActor
final class LibraryWindowController: NSWindowController, NSWindowDelegate {
    static let shared = LibraryWindowController()

    /// The project window Library is showing. Weak: closing that window leaves Library on the
    /// next one that comes forward.
    private(set) weak var shell: ShellViewController?
    private let content = LibraryViewController()

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Library"
        // Seamless like the main window: the sidebar runs to the top under the traffic lights.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = DS.Color.canvas
        window.minSize = NSSize(width: 680, height: 420)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("SideLibrary")
        super.init(window: window)
        window.contentViewController = content
        window.delegate = self
        content.onReveal = { [weak self] url in self?.reveal(url) }
        content.prompts.onStartTrack = { [weak self] prompt in
            guard let shell = self?.shell else { return }
            shell.view.window?.makeKeyAndOrderFront(nil)
            shell.startTrack(from: prompt)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(mainWindowChanged(_:)), name: NSWindow.didBecomeMainNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Opens Library on a section, for the given project window (or the frontmost one).
    func show(for shell: ShellViewController?, section: LibraryViewController.Section? = nil) {
        if let shell = shell ?? Self.frontmostShell() { retarget(shell) }
        if let section { content.select(section) }
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private static func frontmostShell() -> ShellViewController? {
        (NSApp.mainWindow?.contentViewController as? ShellViewController)
            ?? NSApp.orderedWindows.lazy.compactMap { $0.contentViewController as? ShellViewController }.first
    }

    private func retarget(_ shell: ShellViewController) {
        self.shell = shell
        let target = shell.libraryTarget
        window?.title = target.map { "Library \u{00B7} \($0.projectName)" } ?? "Library"
        content.target = target
    }

    @objc private func mainWindowChanged(_ notification: Notification) {
        guard window?.isVisible == true,
              let shell = (notification.object as? NSWindow)?.contentViewController as? ShellViewController else { return }
        retarget(shell)
    }

    /// Coming back to Library re-reads the disk: a file edited in Make, a track switched.
    func windowDidBecomeKey(_ notification: Notification) {
        if let shell { retarget(shell) } else if let shell = Self.frontmostShell() { retarget(shell) }
    }

    private func reveal(_ url: URL) {
        guard let shell else { return }
        shell.view.window?.makeKeyAndOrderFront(nil)
        shell.revealFile(url)
    }
}

/// The project and working copy Library describes: the frontmost window's track, since that's
/// the copy its agent reads.
struct LibraryTarget {
    let projectName: String
    let projectRoot: URL
    let workingRoot: URL
    /// Side's records for the project, for Storage.
    var stateDirectory: URL? = nil
    weak var trackStore: TrackStore? = nil
}

/// Sidebar of sections, one pane each.
@MainActor
final class LibraryViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    enum Section: Int, CaseIterable {
        case instructions, prompts, mcpServers, skills, storage
        var title: String {
            switch self {
            case .instructions: "Instructions"
            case .prompts: "Prompts"
            case .mcpServers: "MCP Servers"
            case .skills: "Skills"
            case .storage: "Storage"
            }
        }
        var symbol: String {
            switch self {
            case .instructions: "text.book.closed"
            case .prompts: "text.bubble"
            case .mcpServers: "puzzlepiece.extension"
            case .skills: "wand.and.stars"
            case .storage: "internaldrive"
            }
        }
    }

    var target: LibraryTarget? {
        didSet {
            instructions.target = target
            prompts.target = target
            mcpServers.target = target
            skills.target = target
            storage.target = target
        }
    }
    var onReveal: ((URL) -> Void)? {
        didSet {
            instructions.onReveal = onReveal
            skills.onReveal = onReveal
        }
    }

    private let sidebar = NSTableView()
    private let paneHost = NSView()
    let instructions = InstructionsPaneViewController()
    let prompts = PromptsPaneViewController()
    let mcpServers = MCPServersPaneViewController()
    let skills = SkillsPaneViewController()
    let storage = StoragePaneViewController()
    private(set) var section: Section = .instructions

    override func loadView() {
        let root = NSView()
        let sidebarScroll = NSScrollView()
        sidebarScroll.drawsBackground = false
        sidebarScroll.translatesAutoresizingMaskIntoConstraints = false
        sidebar.style = .sourceList
        sidebar.headerView = nil
        sidebar.rowHeight = 30
        sidebar.addTableColumn(NSTableColumn(identifier: .init("section")))
        sidebar.dataSource = self
        sidebar.delegate = self
        sidebar.setAccessibilityIdentifier("library.sections")
        sidebarScroll.documentView = sidebar
        let effect = NSVisualEffectView()
        effect.material = .sidebar
        effect.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(sidebarScroll)
        root.addSubview(effect)
        paneHost.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(paneHost)
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(divider)
        NSLayoutConstraint.activate([
            effect.topAnchor.constraint(equalTo: root.topAnchor),
            effect.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            effect.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            effect.widthAnchor.constraint(equalToConstant: 180),
            sidebarScroll.topAnchor.constraint(equalTo: effect.topAnchor, constant: 44),
            sidebarScroll.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            sidebarScroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            sidebarScroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            divider.topAnchor.constraint(equalTo: root.topAnchor),
            divider.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: effect.trailingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            paneHost.topAnchor.constraint(equalTo: root.topAnchor),
            paneHost.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            paneHost.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            paneHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(instructions)
        addChild(prompts)
        addChild(mcpServers)
        addChild(skills)
        addChild(storage)
        sidebar.reloadData()
        select(.instructions)
    }

    func select(_ section: Section) {
        loadViewIfNeeded()
        self.section = section
        if sidebar.selectedRow != section.rawValue {
            sidebar.selectRowIndexes([section.rawValue], byExtendingSelection: false)
        }
        let pane: NSView
        switch section {
        case .instructions: pane = instructions.view
        case .prompts: pane = prompts.view
        case .mcpServers: pane = mcpServers.view
        case .skills: pane = skills.view
        case .storage: pane = storage.view
        }
        guard pane.superview !== paneHost else { return }
        paneHost.subviews.forEach { $0.removeFromSuperview() }
        pane.translatesAutoresizingMaskIntoConstraints = false
        paneHost.addSubview(pane)
        NSLayoutConstraint.activate([
            pane.topAnchor.constraint(equalTo: paneHost.topAnchor),
            pane.bottomAnchor.constraint(equalTo: paneHost.bottomAnchor),
            pane.leadingAnchor.constraint(equalTo: paneHost.leadingAnchor),
            pane.trailingAnchor.constraint(equalTo: paneHost.trailingAnchor),
        ])
    }

    func numberOfRows(in tableView: NSTableView) -> Int { Section.allCases.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let section = Section.allCases[row]
        let cell = NSTableCellView()
        let image = NSImageView(image: NSImage(systemSymbolName: section.symbol, accessibilityDescription: nil) ?? NSImage())
        let label = NSTextField(labelWithString: section.title)
        label.font = DS.Text.body()
        let stack = NSStackView(views: [image, label])
        stack.spacing = DS.Spacing.s
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        cell.textField = label
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: DS.Spacing.xs),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let section = Section(rawValue: sidebar.selectedRow) else { return }
        select(section)
    }
}

// MARK: - Instructions

/// Every instruction file for the working copy and the user, with who reads it. Heron's file
/// can be acknowledged here, after reading it; it's the same acknowledgement Think asks for.
@MainActor
final class InstructionsPaneViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var target: LibraryTarget? { didSet { reload() } }
    var onReveal: ((URL) -> Void)?

    private(set) var files: [InstructionFile] = []
    private let table = NSTableView()
    private let preview = NSTextView()
    private let primaryButton = NSButton(title: "Open in Make", target: nil, action: nil)
    private let acknowledgeButton = NSButton(title: "Use for Heron", target: nil, action: nil)
    private let stateLabel = NSTextField(wrappingLabelWithString: "")

    override func loadView() {
        let root = NSView()
        let heading = NSTextField(labelWithString: "Instructions")
        heading.font = DS.Text.title(.bold)
        let note = NSTextField(wrappingLabelWithString: "Standing instructions agents read before they work. Heron uses the first of its files that exists, once you've read and accepted it. Outside agents read their own files directly, whether or not you've accepted them here.")
        note.font = DS.Text.caption()
        note.textColor = .secondaryLabelColor

        let tableScroll = NSScrollView()
        tableScroll.hasVerticalScroller = true
        tableScroll.borderType = .noBorder
        table.headerView = nil
        table.rowHeight = 38
        table.style = .inset
        table.addTableColumn(NSTableColumn(identifier: .init("file")))
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityIdentifier("library.instructions")
        tableScroll.documentView = table
        table.backgroundColor = .clear
        LibraryStyle.card(tableScroll)

        let previewScroll = NSScrollView()
        previewScroll.hasVerticalScroller = true
        previewScroll.borderType = .noBorder
        preview.isEditable = false
        preview.isRichText = false
        preview.font = DS.Text.code(12)
        preview.textContainerInset = NSSize(width: DS.Spacing.m, height: DS.Spacing.m)
        preview.autoresizingMask = [.width]
        preview.drawsBackground = false
        previewScroll.documentView = preview
        LibraryStyle.card(previewScroll)

        stateLabel.font = DS.Text.caption()
        stateLabel.textColor = .secondaryLabelColor
        primaryButton.target = self
        primaryButton.action = #selector(primaryTapped)
        primaryButton.bezelStyle = .rounded
        acknowledgeButton.target = self
        acknowledgeButton.action = #selector(acknowledgeTapped)
        acknowledgeButton.bezelStyle = .rounded
        let buttons = NSStackView(views: [stateLabel, NSView(), acknowledgeButton, primaryButton])
        buttons.spacing = DS.Spacing.m

        for view in [heading, note, tableScroll, previewScroll, buttons] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        let inset = DS.Spacing.section
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: root.topAnchor, constant: inset + 18),
            heading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
            note.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: DS.Spacing.s),
            note.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            note.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -inset),
            tableScroll.topAnchor.constraint(equalTo: note.bottomAnchor, constant: DS.Spacing.xl),
            tableScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
            tableScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -inset),
            tableScroll.heightAnchor.constraint(equalTo: root.heightAnchor, multiplier: 0.42),
            previewScroll.topAnchor.constraint(equalTo: tableScroll.bottomAnchor, constant: DS.Spacing.m),
            previewScroll.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            previewScroll.trailingAnchor.constraint(equalTo: note.trailingAnchor),
            buttons.topAnchor.constraint(equalTo: previewScroll.bottomAnchor, constant: DS.Spacing.m),
            buttons.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: note.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -inset),
        ])
        view = root
    }

    func reload() {
        loadViewIfNeeded()
        let selected = selectedFile?.url
        files = target.map { InstructionFiles.discover(workingRoot: $0.workingRoot) } ?? []
        table.reloadData()
        let row = files.firstIndex { $0.url == selected } ?? files.firstIndex { $0.exists } ?? (files.isEmpty ? -1 : 0)
        if row >= 0 { table.selectRowIndexes([row], byExtendingSelection: false) }
        refreshDetail()
    }

    private var selectedFile: InstructionFile? {
        files.indices.contains(table.selectedRow) ? files[table.selectedRow] : nil
    }

    static func stateText(_ file: InstructionFile) -> String {
        guard file.exists else { return "Not present" }
        switch file.heron {
        case .inUse(acknowledged: true): return "Heron uses this"
        case .inUse(acknowledged: false): return "Heron will ask before using this"
        case .shadowed(let winner): return "Heron uses \(winner) instead"
        case .candidate, nil: return file.scope == .user ? "Your own, for every project" : "In this project"
        }
    }

    private func refreshDetail() {
        guard let file = selectedFile else {
            preview.string = ""
            stateLabel.stringValue = target == nil ? "Open a project to see its instructions." : ""
            primaryButton.isHidden = true
            acknowledgeButton.isHidden = true
            return
        }
        preview.string = file.exists ? ((try? String(contentsOf: file.url, encoding: .utf8)) ?? "This file couldn't be read.") : ""
        stateLabel.stringValue = Self.stateText(file)
        primaryButton.isHidden = false
        primaryButton.title = file.exists ? "Open in Make" : "Create"
        acknowledgeButton.isHidden = file.heron != .inUse(acknowledged: false)
    }

    @objc private func primaryTapped() {
        guard let file = selectedFile else { return }
        if !file.exists {
            try? FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let text = file.heron != nil ? ProjectRules.template : "# Agent instructions\n"
            guard (try? text.write(to: file.url, atomically: true, encoding: .utf8)) != nil else { return }
            // Written by the user, here, on purpose, as Think's /rules does.
            if file.heron != nil { ProjectRules.acknowledge(url: file.url, contents: text.trimmingCharacters(in: .whitespacesAndNewlines)) }
            reload()
        }
        onReveal?(file.url)
    }

    @objc private func acknowledgeTapped() {
        guard let file = selectedFile, let text = try? String(contentsOf: file.url, encoding: .utf8) else { return }
        ProjectRules.acknowledge(url: file.url, contents: text.trimmingCharacters(in: .whitespacesAndNewlines))
        reload()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { files.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let file = files[row]
        let readers = InstructionFiles.readerNames(file).joined(separator: ", ")
        return LibraryListCell(title: file.displayPath, detail: readers.isEmpty ? Self.stateText(file) : "Read by \(readers)", dimmed: !file.exists)
    }

    func tableViewSelectionDidChange(_ notification: Notification) { refreshDetail() }
}

// MARK: - Prompts

/// Saved prompts: the user's own and the project's. `/name` in Think inserts one; it never sends
/// by itself (L2).
@MainActor
final class PromptsPaneViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    var target: LibraryTarget? { didSet { reload() } }
    var onStartTrack: ((SavedPrompt) -> Void)?

    private(set) var prompts: [SavedPrompt] = []
    let templateCheckbox = NSButton(checkboxWithTitle: "Template: Start Track creates a track named by the title and sends this", target: nil, action: nil)
    private let startTrackButton = NSButton(title: "Start Track", target: nil, action: nil)
    private let table = NSTableView()
    let titleField = NSTextField()
    let scopePopup = NSPopUpButton()
    let bodyView = NSTextView()
    private let hint = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete", target: nil, action: nil)
    /// The prompt being edited; nil while writing a new one.
    private var editing: SavedPrompt?

    override func loadView() {
        let root = NSView()
        let heading = NSTextField(labelWithString: "Prompts")
        heading.font = DS.Text.title(.bold)
        let note = NSTextField(wrappingLabelWithString: "Prompts you'd otherwise retype. Type /name in Think to put one in the composer. It never sends by itself.")
        note.font = DS.Text.caption()
        note.textColor = .secondaryLabelColor

        let tableScroll = NSScrollView()
        tableScroll.hasVerticalScroller = true
        table.headerView = nil
        table.rowHeight = 38
        table.style = .inset
        table.addTableColumn(NSTableColumn(identifier: .init("prompt")))
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityIdentifier("library.prompts")
        tableScroll.documentView = table
        table.backgroundColor = .clear
        LibraryStyle.card(tableScroll)
        let newButton = NSButton(title: "New Prompt", target: self, action: #selector(newPrompt))
        newButton.bezelStyle = .rounded

        titleField.placeholderString = "Title, e.g. Review for concurrency bugs"
        titleField.delegate = self
        titleField.setAccessibilityIdentifier("library.prompt.title")
        scopePopup.addItems(withTitles: ["Mine, in every project", "This project, shared in the repo"])
        let bodyScroll = NSScrollView()
        bodyScroll.hasVerticalScroller = true
        bodyScroll.borderType = .noBorder
        LibraryStyle.card(bodyScroll)
        bodyView.isRichText = false
        bodyView.allowsUndo = true
        bodyView.font = DS.Text.body()
        bodyView.textContainerInset = NSSize(width: DS.Spacing.s, height: DS.Spacing.s)
        bodyView.autoresizingMask = [.width]
        bodyView.isAutomaticQuoteSubstitutionEnabled = false
        bodyScroll.documentView = bodyView
        hint.font = DS.Text.caption()
        hint.textColor = .secondaryLabelColor
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "s"
        saveButton.keyEquivalentModifierMask = [.command]
        deleteButton.target = self
        deleteButton.action = #selector(deletePrompt)
        deleteButton.bezelStyle = .rounded
        deleteButton.hasDestructiveAction = true
        startTrackButton.target = self
        startTrackButton.action = #selector(startTrack)
        startTrackButton.bezelStyle = .rounded
        templateCheckbox.font = DS.Text.caption()
        let buttons = NSStackView(views: [hint, NSView(), startTrackButton, deleteButton, saveButton])
        buttons.spacing = DS.Spacing.m

        for view in [heading, note, tableScroll, newButton, titleField, scopePopup, bodyScroll, templateCheckbox, buttons] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        let inset = DS.Spacing.section
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: root.topAnchor, constant: inset + 18),
            heading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
            note.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: DS.Spacing.s),
            note.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            note.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -inset),

            tableScroll.topAnchor.constraint(equalTo: note.bottomAnchor, constant: DS.Spacing.xl),
            tableScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
            tableScroll.widthAnchor.constraint(equalToConstant: 220),
            newButton.topAnchor.constraint(equalTo: tableScroll.bottomAnchor, constant: DS.Spacing.m),
            newButton.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            newButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -inset),

            titleField.topAnchor.constraint(equalTo: tableScroll.topAnchor),
            titleField.leadingAnchor.constraint(equalTo: tableScroll.trailingAnchor, constant: DS.Spacing.l),
            titleField.trailingAnchor.constraint(equalTo: note.trailingAnchor),
            scopePopup.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: DS.Spacing.m),
            scopePopup.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            bodyScroll.topAnchor.constraint(equalTo: scopePopup.bottomAnchor, constant: DS.Spacing.m),
            bodyScroll.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            bodyScroll.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),
            templateCheckbox.topAnchor.constraint(equalTo: bodyScroll.bottomAnchor, constant: DS.Spacing.m),
            templateCheckbox.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            templateCheckbox.trailingAnchor.constraint(lessThanOrEqualTo: titleField.trailingAnchor),
            buttons.topAnchor.constraint(equalTo: templateCheckbox.bottomAnchor, constant: DS.Spacing.m),
            buttons.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -inset),
        ])
        view = root
    }

    func reload() {
        loadViewIfNeeded()
        prompts = PromptLibrary.all(projectRoot: target?.workingRoot)
        table.reloadData()
        // By name and scope: the saved URL and the listed one can spell the same file
        // differently (/var and /private/var).
        if let editing, let row = prompts.firstIndex(where: { $0.name == editing.name && $0.scope == editing.scope }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
            show(prompts[row])
        } else if editing == nil, let first = prompts.first {
            table.selectRowIndexes([0], byExtendingSelection: false)
            show(first)
        } else {
            show(nil)
        }
        scopePopup.item(at: 1)?.isEnabled = target != nil
    }

    private func show(_ prompt: SavedPrompt?) {
        editing = prompt
        titleField.stringValue = prompt?.title ?? ""
        bodyView.string = prompt?.body ?? ""
        scopePopup.selectItem(at: prompt?.scope == .project ? 1 : 0)
        templateCheckbox.state = prompt?.startsTrack == true ? .on : .off
        deleteButton.isHidden = prompt == nil
        // Only a saved template: what starts is what's on disk, not an unsaved edit.
        startTrackButton.isHidden = prompt?.startsTrack != true || target?.trackStore == nil
        refreshHint()
    }

    /// The slash name the title will save as, and whether a built-in command already has it.
    private func refreshHint() {
        let name = PromptLibrary.slug(titleField.stringValue)
        if name.isEmpty { hint.stringValue = "Give it a title to name it." }
        else if ThinkWorkspaceViewController.builtInSlashNames.contains(name) { hint.stringValue = "/\(name) is a built-in command. Choose another title." }
        else { hint.stringValue = "Insert with /\(name)" }
        saveButton.isEnabled = !name.isEmpty && !ThinkWorkspaceViewController.builtInSlashNames.contains(name)
    }

    func controlTextDidChange(_ obj: Notification) { refreshHint() }

    @objc private func newPrompt() {
        table.deselectAll(nil)
        show(nil)
        view.window?.makeFirstResponder(titleField)
    }

    @objc func save() {
        let scope: SavedPrompt.Scope = scopePopup.indexOfSelectedItem == 1 ? .project : .user
        do {
            editing = try PromptLibrary.save(title: titleField.stringValue, body: bodyView.string, scope: scope,
                                             projectRoot: target?.workingRoot, startsTrack: templateCheckbox.state == .on, replacing: editing)
            reload()
        } catch {
            NSSound.beep()
        }
    }

    @objc func startTrack() {
        guard let editing, editing.startsTrack else { return }
        onStartTrack?(editing)
    }

    @objc private func deletePrompt() {
        guard let editing else { return }
        let alert = NSAlert()
        alert.messageText = "Delete \u{201C}\(editing.title)\u{201D}?"
        alert.informativeText = editing.scope == .project
            ? "It's removed from this project's .side/prompts folder. Commit the change to remove it for everyone."
            : "It's removed from your prompts in every project."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try? PromptLibrary.delete(editing)
        self.editing = nil
        reload()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { prompts.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let prompt = prompts[row]
        let kind = prompt.startsTrack ? " \u{00B7} Template" : ""
        return LibraryListCell(title: prompt.title, detail: "/\(prompt.name) \u{00B7} \(prompt.scope == .project ? "This project" : "Mine")\(kind)", dimmed: false)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard prompts.indices.contains(table.selectedRow) else { return }
        show(prompts[table.selectedRow])
    }
}

// MARK: - MCP servers

/// The user's own MCP servers (L1): switched on per project, handed to outside agents with each
/// conversation. Environment values go to the Keychain and are never shown again.
@MainActor
final class MCPServersPaneViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var target: LibraryTarget? { didSet { reload() } }

    /// Stands in for a stored value in the environment field; saving it keeps the value.
    static let hiddenValue = "\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}"

    private(set) var servers: [MCPServerConfig] = []
    private let table = NSTableView()
    let nameField = NSTextField()
    let commandField = NSTextField()
    let argumentsField = NSTextField()
    let environmentView = NSTextView()
    let enabledCheckbox = NSButton(checkboxWithTitle: "Use in this project", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete", target: nil, action: nil)
    private var editing: MCPServerConfig?
    private let emptyLabel = NSTextField(wrappingLabelWithString: "No servers yet. Fill in the form to add one.")

    override func loadView() {
        let root = NSView()
        let heading = NSTextField(labelWithString: "MCP Servers")
        heading.font = DS.Text.title(.bold)
        let note = NSTextField(wrappingLabelWithString: "Your own tools for agents. Outside agents start the servers you switch on for a project, alongside Side's own tools and whatever their own settings add. Heron can't use MCP servers yet. Idle agents restart to pick up a change.")
        note.font = DS.Text.caption()
        note.textColor = .secondaryLabelColor

        let tableScroll = NSScrollView()
        tableScroll.hasVerticalScroller = true
        table.headerView = nil
        table.rowHeight = 38
        table.style = .inset
        table.addTableColumn(NSTableColumn(identifier: .init("server")))
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityIdentifier("library.mcpServers")
        tableScroll.documentView = table
        table.backgroundColor = .clear
        LibraryStyle.card(tableScroll)
        let newButton = NSButton(title: "New Server", target: self, action: #selector(newServer))
        newButton.bezelStyle = .rounded

        nameField.placeholderString = "Name, e.g. postgres"
        commandField.placeholderString = "Command, e.g. npx"
        argumentsField.placeholderString = "Arguments, e.g. -y @modelcontextprotocol/server-postgres"
        let environmentLabel = NSTextField(labelWithString: "Environment, one NAME=value per line. Kept in your Keychain.")
        environmentLabel.font = DS.Text.caption()
        environmentLabel.textColor = .secondaryLabelColor
        let environmentScroll = NSScrollView()
        environmentScroll.hasVerticalScroller = true
        environmentScroll.borderType = .noBorder
        LibraryStyle.card(environmentScroll)
        environmentView.isRichText = false
        environmentView.font = DS.Text.code(12)
        environmentView.autoresizingMask = [.width]
        environmentView.isAutomaticQuoteSubstitutionEnabled = false
        environmentView.textContainerInset = NSSize(width: DS.Spacing.xs, height: DS.Spacing.xs)
        environmentScroll.documentView = environmentView
        enabledCheckbox.target = self
        enabledCheckbox.action = #selector(toggleEnabled)
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.bezelStyle = .rounded
        deleteButton.target = self
        deleteButton.action = #selector(deleteServer)
        deleteButton.bezelStyle = .rounded
        deleteButton.hasDestructiveAction = true
        let buttons = NSStackView(views: [enabledCheckbox, NSView(), deleteButton, saveButton])
        buttons.spacing = DS.Spacing.m

        let form = NSStackView(views: [nameField, commandField, argumentsField, environmentLabel, environmentScroll])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = DS.Spacing.m
        for field in [nameField, commandField, argumentsField, environmentScroll] as [NSView] {
            field.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true
        }
        environmentScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true

        emptyLabel.font = DS.Text.caption()
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        for view in [heading, note, tableScroll, newButton, form, buttons, emptyLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        let inset = DS.Spacing.section
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: root.topAnchor, constant: inset + 18),
            heading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
            note.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: DS.Spacing.s),
            note.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            note.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -inset),
            tableScroll.topAnchor.constraint(equalTo: note.bottomAnchor, constant: DS.Spacing.xl),
            tableScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
            tableScroll.widthAnchor.constraint(equalToConstant: 220),
            newButton.topAnchor.constraint(equalTo: tableScroll.bottomAnchor, constant: DS.Spacing.m),
            newButton.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            newButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -inset),
            emptyLabel.centerYAnchor.constraint(equalTo: tableScroll.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: tableScroll.leadingAnchor, constant: DS.Spacing.xl),
            emptyLabel.trailingAnchor.constraint(equalTo: tableScroll.trailingAnchor, constant: -DS.Spacing.xl),
            form.topAnchor.constraint(equalTo: tableScroll.topAnchor),
            form.leadingAnchor.constraint(equalTo: tableScroll.trailingAnchor, constant: DS.Spacing.l),
            form.trailingAnchor.constraint(equalTo: note.trailingAnchor),
            buttons.topAnchor.constraint(equalTo: form.bottomAnchor, constant: DS.Spacing.m),
            buttons.leadingAnchor.constraint(equalTo: form.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: form.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -inset),
        ])
        view = root
    }

    func reload() {
        loadViewIfNeeded()
        servers = MCPServerStore.all
        table.reloadData()
        emptyLabel.isHidden = !servers.isEmpty
        if let editing, let row = servers.firstIndex(where: { $0.id == editing.id }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
            show(servers[row])
        } else if let first = servers.first {
            table.selectRowIndexes([0], byExtendingSelection: false)
            show(first)
        } else {
            show(nil)
        }
    }

    private func show(_ server: MCPServerConfig?) {
        editing = server
        nameField.stringValue = server?.name ?? ""
        commandField.stringValue = server?.command ?? ""
        argumentsField.stringValue = server?.arguments.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ") ?? ""
        environmentView.string = server?.environmentNames.map { "\($0)=\(Self.hiddenValue)" }.joined(separator: "\n") ?? ""
        enabledCheckbox.title = target.map { "Use in \($0.projectName)" } ?? "Use in this project"
        enabledCheckbox.isEnabled = target != nil
        enabledCheckbox.state = server.flatMap { s in target.map { s.isEnabled(forProject: $0.projectRoot.path) } } == true ? .on : .off
        deleteButton.isHidden = server == nil
    }

    /// NAME=value lines; a hidden value keeps what's stored.
    static func parseEnvironment(_ text: String, stored: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.components(separatedBy: "\n") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let name = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: equals)...])
            guard !name.isEmpty else { continue }
            result[name] = value == hiddenValue ? (stored[name] ?? "") : value
        }
        return result
    }

    @objc private func newServer() {
        table.deselectAll(nil)
        show(nil)
        view.window?.makeFirstResponder(nameField)
    }

    @objc func save() {
        let command = commandField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty else { return NSSound.beep() }
        var server = editing ?? MCPServerStore.newServer(name: "", command: "", arguments: [])
        server.name = nameField.stringValue
        server.command = command
        server.arguments = MCPServerStore.splitArguments(argumentsField.stringValue)
        let isNew = editing == nil
        let environment = Self.parseEnvironment(environmentView.string, stored: editing.map { MCPServerStore.environment(for: $0.id) } ?? [:])
        editing = MCPServerStore.save(server, environment: environment)
        // A server made from this project's Library is for this project.
        if isNew, let editing, let target { MCPServerStore.setEnabled(true, id: editing.id, projectPath: target.projectRoot.path) }
        reload()
    }

    @objc func toggleEnabled() {
        guard let editing, let target else { return }
        MCPServerStore.setEnabled(enabledCheckbox.state == .on, id: editing.id, projectPath: target.projectRoot.path)
        reload()
    }

    @objc private func deleteServer() {
        guard let editing else { return }
        let alert = NSAlert()
        alert.messageText = "Delete \u{201C}\(editing.name)\u{201D}?"
        alert.informativeText = "It's removed from every project, with its environment values."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        MCPServerStore.remove(id: editing.id)
        self.editing = nil
        reload()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { servers.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let server = servers[row]
        let on = target.map { server.isEnabled(forProject: $0.projectRoot.path) } ?? false
        return LibraryListCell(title: server.name, detail: "\(server.command) \u{00B7} \(on ? "On here" : "Off here")", dimmed: !on)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard servers.indices.contains(table.selectedRow) else { return }
        show(servers[table.selectedRow])
    }
}

// MARK: - Skills

/// Skills on disk and the agents that load them. Read-only: Heron doesn't use skills yet (L3).
@MainActor
final class SkillsPaneViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var target: LibraryTarget? { didSet { reload() } }
    var onReveal: ((URL) -> Void)?

    private(set) var skills: [SkillEntry] = []
    private let table = NSTableView()
    private let descriptionLabel = NSTextField(wrappingLabelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let preview = NSTextView()
    private let openButton = NSButton(title: "Open in Make", target: nil, action: nil)
    private let emptyLabel = NSTextField(wrappingLabelWithString: "No skills found. Claude Code looks in ~/.claude/skills and this project's .claude/skills; Codex and others in .agents/skills.")

    override func loadView() {
        let root = NSView()
        let heading = NSTextField(labelWithString: "Skills")
        heading.font = DS.Text.title(.bold)
        let note = NSTextField(wrappingLabelWithString: "Instructions and scripts an agent loads when a task calls for them. Outside agents find these on their own. Heron doesn't use skills yet.")
        note.font = DS.Text.caption()
        note.textColor = .secondaryLabelColor

        let tableScroll = NSScrollView()
        tableScroll.hasVerticalScroller = true
        table.headerView = nil
        table.rowHeight = 38
        table.style = .inset
        table.addTableColumn(NSTableColumn(identifier: .init("skill")))
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityIdentifier("library.skills")
        tableScroll.documentView = table
        table.backgroundColor = .clear
        LibraryStyle.card(tableScroll)

        descriptionLabel.font = DS.Text.body()
        pathLabel.font = DS.Text.caption()
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        let previewScroll = NSScrollView()
        previewScroll.hasVerticalScroller = true
        preview.isEditable = false
        preview.isRichText = false
        preview.font = DS.Text.code(12)
        preview.drawsBackground = false
        preview.autoresizingMask = [.width]
        preview.textContainerInset = NSSize(width: DS.Spacing.m, height: DS.Spacing.m)
        previewScroll.documentView = preview
        LibraryStyle.card(previewScroll)
        openButton.target = self
        openButton.action = #selector(openTapped)
        openButton.bezelStyle = .rounded
        emptyLabel.font = DS.Text.caption()
        emptyLabel.textColor = .secondaryLabelColor

        for view in [heading, note, tableScroll, descriptionLabel, pathLabel, previewScroll, openButton, emptyLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        let inset = DS.Spacing.section
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: root.topAnchor, constant: inset + 18),
            heading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
            note.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: DS.Spacing.s),
            note.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            note.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -inset),
            tableScroll.topAnchor.constraint(equalTo: note.bottomAnchor, constant: DS.Spacing.xl),
            tableScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
            tableScroll.widthAnchor.constraint(equalToConstant: 240),
            tableScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -inset),
            emptyLabel.topAnchor.constraint(equalTo: tableScroll.topAnchor, constant: DS.Spacing.m),
            emptyLabel.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            emptyLabel.trailingAnchor.constraint(equalTo: note.trailingAnchor),
            descriptionLabel.topAnchor.constraint(equalTo: tableScroll.topAnchor),
            descriptionLabel.leadingAnchor.constraint(equalTo: tableScroll.trailingAnchor, constant: DS.Spacing.l),
            descriptionLabel.trailingAnchor.constraint(equalTo: note.trailingAnchor),
            pathLabel.topAnchor.constraint(equalTo: descriptionLabel.bottomAnchor, constant: DS.Spacing.xs),
            pathLabel.leadingAnchor.constraint(equalTo: descriptionLabel.leadingAnchor),
            pathLabel.trailingAnchor.constraint(equalTo: descriptionLabel.trailingAnchor),
            previewScroll.topAnchor.constraint(equalTo: pathLabel.bottomAnchor, constant: DS.Spacing.m),
            previewScroll.leadingAnchor.constraint(equalTo: descriptionLabel.leadingAnchor),
            previewScroll.trailingAnchor.constraint(equalTo: descriptionLabel.trailingAnchor),
            openButton.topAnchor.constraint(equalTo: previewScroll.bottomAnchor, constant: DS.Spacing.m),
            openButton.trailingAnchor.constraint(equalTo: descriptionLabel.trailingAnchor),
            openButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -inset),
        ])
        view = root
    }

    func reload() {
        loadViewIfNeeded()
        let selected = selectedSkill?.url
        skills = target.map { SkillCatalog.discover(workingRoot: $0.workingRoot) } ?? []
        table.reloadData()
        if let row = skills.firstIndex(where: { $0.url == selected }) ?? (skills.isEmpty ? nil : 0) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        }
        refreshDetail()
    }

    private var selectedSkill: SkillEntry? { skills.indices.contains(table.selectedRow) ? skills[table.selectedRow] : nil }

    private func refreshDetail() {
        let skill = selectedSkill
        emptyLabel.isHidden = !skills.isEmpty
        for view in [descriptionLabel, pathLabel, preview.enclosingScrollView, openButton] as [NSView?] { view?.isHidden = skill == nil }
        guard let skill else { return }
        descriptionLabel.stringValue = skill.description.isEmpty ? "No description." : skill.description
        let linked = skill.alsoIn.isEmpty ? "" : " \u{00B7} Also linked from \(skill.alsoIn.joined(separator: ", "))"
        pathLabel.stringValue = "\(skill.location)/\(skill.url.deletingLastPathComponent().lastPathComponent) \u{00B7} Loaded by \(skill.readers.joined(separator: ", "))\(linked)"
        pathLabel.toolTip = pathLabel.stringValue
        preview.string = (try? String(contentsOf: skill.url, encoding: .utf8)) ?? ""
    }

    @objc private func openTapped() {
        guard let skill = selectedSkill else { return }
        onReveal?(skill.url)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { skills.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let skill = skills[row]
        let agents = skill.readers.filter { !$0.hasPrefix("other agents") }.joined(separator: ", ")
        return LibraryListCell(title: skill.name, detail: "\(agents) \u{00B7} \(skill.scope == .project ? "This project" : "Yours")", dimmed: false)
    }

    func tableViewSelectionDidChange(_ notification: Notification) { refreshDetail() }
}

// MARK: - Storage

/// What Side keeps on disk for a project, and the one thing worth trimming by hand: working
/// copies of archived tracks. Their branches and checkpoints stay; Resume makes a new copy.
@MainActor
final class StoragePaneViewController: NSViewController {
    var target: LibraryTarget? { didSet { reload() } }

    /// Measured sizes, in bytes, keyed by row.
    struct Usage: Equatable {
        var conversations: Int64 = 0
        var outsideRecords: Int64 = 0
        var workingCopies: Int64 = 0
        var workingCopyCount = 0
        var archivedCopies: Int64 = 0
    }

    private(set) var usage = Usage()
    private let conversationsValue = NSTextField(labelWithString: "")
    private let outsideValue = NSTextField(labelWithString: "")
    private let copiesValue = NSTextField(labelWithString: "")
    private let archivedValue = NSTextField(wrappingLabelWithString: "")
    let removeButton = NSButton(title: "Remove Working Copies\u{2026}", target: nil, action: nil)
    let retentionPopup = NSPopUpButton()
    private var measureGeneration = 0

    override func loadView() {
        let root = NSView()
        let heading = NSTextField(labelWithString: "Storage")
        heading.font = DS.Text.title(.bold)
        let note = NSTextField(wrappingLabelWithString: "What Side keeps on this Mac for this project. Checkpoints are git commits in the repository and aren't counted here.")
        note.font = DS.Text.caption()
        note.textColor = .secondaryLabelColor

        for option in HistoryRetention.allCases { retentionPopup.addItem(withTitle: option.displayName) }
        retentionPopup.target = self
        retentionPopup.action = #selector(retentionChanged)
        removeButton.target = self
        removeButton.action = #selector(removeArchivedCopies)
        removeButton.bezelStyle = .rounded
        archivedValue.font = DS.Text.caption()
        archivedValue.textColor = .secondaryLabelColor

        for value in [conversationsValue, outsideValue, copiesValue] {
            value.textColor = .secondaryLabelColor
            value.font = NSFont.monospacedDigitSystemFont(ofSize: DS.Text.body().pointSize, weight: .regular)
        }
        archivedValue.preferredMaxLayoutWidth = 360
        archivedValue.font = DS.Text.caption()
        let archivedTitle = NSTextField(labelWithString: "Working copies of archived tracks")
        archivedTitle.font = DS.Text.body()
        let archivedText = NSStackView(views: [archivedTitle, archivedValue])
        archivedText.orientation = .vertical
        archivedText.alignment = .leading
        archivedText.spacing = 2
        archivedText.setHuggingPriority(.defaultLow, for: .horizontal)
        let archivedLine = NSStackView(views: [archivedText, removeButton])
        archivedLine.orientation = .horizontal
        archivedLine.alignment = .centerY
        archivedLine.spacing = DS.Spacing.xl
        removeButton.setContentHuggingPriority(.required, for: .horizontal)

        let sections = NSStackView(views: [
            SettingsForm.section("On this Mac", [
                SettingsForm.row("Heron conversations", conversationsValue),
                SettingsForm.row("Outside-agent records", outsideValue),
                SettingsForm.row("Track working copies", copiesValue),
            ]),
            SettingsForm.section("History", footer: "The same setting as Preferences \u{203A} History.", [
                SettingsForm.row("Keep conversations", retentionPopup),
            ]),
            SettingsForm.section("Archived tracks", [SettingsForm.content(archivedLine)]),
        ])
        sections.orientation = .vertical
        sections.alignment = .leading
        sections.spacing = DS.Spacing.section
        for view in [heading, note, sections] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        let inset = DS.Spacing.section
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: root.topAnchor, constant: inset + 18),
            heading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
            note.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: DS.Spacing.s),
            note.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            note.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -inset),
            sections.topAnchor.constraint(equalTo: note.bottomAnchor, constant: DS.Spacing.xl),
            sections.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            sections.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -inset),
        ])
        for section in sections.arrangedSubviews { section.widthAnchor.constraint(equalTo: sections.widthAnchor).isActive = true }
        view = root
    }

    private static func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.textColor = .secondaryLabelColor
        return label
    }

    /// Archived tracks that still have a working copy on disk.
    var archivedWithCopies: [Track] {
        (target?.trackStore?.tracks ?? []).filter { $0.status == .archived && $0.workingDirectoryPath != nil }
    }

    func reload() {
        loadViewIfNeeded()
        retentionPopup.selectItem(at: HistoryRetention.allCases.firstIndex(of: .current) ?? 0)
        let archived = archivedWithCopies
        let archivedPaths = archived.compactMap(\.workingDirectoryPath)
        let copyPaths = (target?.trackStore?.tracks ?? []).compactMap(\.workingDirectoryPath)
        let think = target?.stateDirectory?.appendingPathComponent("think")
        let root = target?.projectRoot.standardizedFileURL.path
        renderArchived(archived)
        measureGeneration += 1
        let generation = measureGeneration
        [conversationsValue, outsideValue, copiesValue].forEach { $0.stringValue = "Measuring\u{2026}" }
        DispatchQueue.global(qos: .utility).async {
            var usage = Usage()
            if let think {
                usage.conversations = Self.size(of: think) - Self.size(of: think.appendingPathComponent("outside"))
                usage.outsideRecords = Self.size(of: think.appendingPathComponent("outside"))
            }
            // A track without a worktree works in the project itself, which isn't Side's to count.
            let separate = copyPaths.filter { URL(fileURLWithPath: $0).standardizedFileURL.path != root }
            usage.workingCopyCount = separate.count
            usage.workingCopies = separate.reduce(0) { $0 + Self.size(of: URL(fileURLWithPath: $1)) }
            usage.archivedCopies = archivedPaths.reduce(0) { $0 + Self.size(of: URL(fileURLWithPath: $1)) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard generation == self.measureGeneration else { return }
                    self.usage = usage
                    self.render()
                }
            }
        }
    }

    private func render() {
        conversationsValue.stringValue = Self.format(usage.conversations)
        outsideValue.stringValue = Self.format(usage.outsideRecords)
        copiesValue.stringValue = usage.workingCopyCount == 0 ? "None" : "\(Self.format(usage.workingCopies)) in \(usage.workingCopyCount)"
        renderArchived(archivedWithCopies)
    }

    private func renderArchived(_ archived: [Track]) {
        removeButton.isEnabled = !archived.isEmpty
        if archived.isEmpty {
            archivedValue.stringValue = "No archived track has a working copy."
        } else {
            let size = usage.archivedCopies > 0 ? " (\(Self.format(usage.archivedCopies)))" : ""
            archivedValue.stringValue = "\(archived.count) archived \(archived.count == 1 ? "track has" : "tracks have") a working copy\(size). Removing one keeps its branch and checkpoints; Resume makes a new copy."
        }
    }

    static func format(_ bytes: Int64) -> String {
        bytes == 0 ? "Nothing yet" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    nonisolated static func size(of url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    @objc private func retentionChanged() {
        HistoryRetention.current = HistoryRetention.allCases[max(0, retentionPopup.indexOfSelectedItem)]
    }

    @objc private func removeArchivedCopies() {
        let archived = archivedWithCopies
        guard !archived.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(archived.count) working \(archived.count == 1 ? "copy" : "copies")?"
        alert.informativeText = archived.prefix(8).map { "\u{2022} \($0.intent)" }.joined(separator: "\n")
            + (archived.count > 8 ? "\n\u{2022} and \(archived.count - 8) more" : "")
            + "\n\nBranches and checkpoints stay. A copy with uncommitted changes is kept."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        removeCopies(archived) { [weak self] kept in
            guard let self else { return }
            self.reload()
            if !kept.isEmpty {
                let note = NSAlert()
                note.messageText = "\(kept.count) working \(kept.count == 1 ? "copy was" : "copies were") kept"
                note.informativeText = "They have uncommitted changes: " + kept.joined(separator: ", ")
                note.runModal()
            }
        }
    }

    /// Removes each copy in turn; `completion` gets the intents of the ones git refused (dirty).
    func removeCopies(_ tracks: [Track], completion: @escaping ([String]) -> Void) {
        guard let store = target?.trackStore else { return completion([]) }
        removeNext(RemovalBox(remaining: tracks, completion: completion), store: store)
    }

    private func removeNext(_ box: RemovalBox, store: TrackStore) {
        guard !box.remaining.isEmpty else { return box.completion(box.kept) }
        let track = box.remaining.removeFirst()
        store.removeWorkingCopy(for: track) { [weak self] result in
            let failed = if case .failure = result { true } else { false }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if failed { box.kept.append(track.intent) }
                    guard let self else { return box.completion(box.kept) }
                    self.removeNext(box, store: store)
                }
            }
        }
    }
}

/// The state of a run of removals, carried across git's background completions.
private final class RemovalBox: @unchecked Sendable {
    var remaining: [Track]
    var kept: [String] = []
    let completion: ([String]) -> Void
    init(remaining: [Track], completion: @escaping ([String]) -> Void) {
        self.remaining = remaining
        self.completion = completion
    }
}

/// Library's surfaces, in the grouped-form language Preferences uses.
@MainActor
enum LibraryStyle {
    /// A rounded, raised card around a list or a text area.
    static func card(_ scroll: NSScrollView) {
        // Drawn by the scroll view itself: a table repaints its scroll view's background over
        // any layer color, so a layer background alone never showed behind a list.
        scroll.drawsBackground = true
        scroll.backgroundColor = DS.Color.raised
        scroll.contentView.drawsBackground = true
        scroll.contentView.backgroundColor = DS.Color.raised
        scroll.layer?.cornerRadius = DS.Radius.surface
        scroll.layer?.cornerCurve = .continuous
        scroll.layer?.masksToBounds = true
        (scroll.documentView as? NSTextView)?.drawsBackground = false
    }
}

/// Two lines: a name and what it is.
private final class LibraryListCell: NSTableCellView {
    init(title: String, detail: String, dimmed: Bool) {
        super.init(frame: .zero)
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = DS.Text.body(.medium)
        titleLabel.textColor = dimmed ? .tertiaryLabelColor : .labelColor
        titleLabel.lineBreakMode = .byTruncatingMiddle
        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = DS.Text.caption()
        detailLabel.textColor = dimmed ? .tertiaryLabelColor : .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [titleLabel, detailLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        textField = titleLabel
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DS.Spacing.xs),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -DS.Spacing.xs),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityLabel("\(title), \(detail)")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
