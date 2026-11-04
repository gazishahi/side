import AppKit

/// One entry in a System Settings–style sidebar: a colored icon tile and a name, plus words a
/// search should also match ("key" finds Agents).
struct SidebarItem {
    let id: String
    let title: String
    let symbol: String
    let tint: NSColor
    var keywords: [String] = []
    /// What the pane is for, under its title card.
    var summary: String = ""

    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return true }
        return ([title] + keywords).contains { $0.lowercased().contains(query) }
    }
}

/// The sidebar Preferences and Library share: an optional search field, then the items as a
/// source list with icon tiles. Sits in an `NSSplitViewItem(sidebarWithViewController:)`, which
/// is what gives it the floating, full-height macOS sidebar.
@MainActor
final class SidebarListController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    var onSelect: ((SidebarItem) -> Void)?
    private let items: [SidebarItem]
    private var shown: [SidebarItem]
    private let table = NSTableView()
    private let search = NSSearchField()
    /// A search that matches nothing says so, as System Settings does, instead of an empty list.
    private let noResults = NSTextField(wrappingLabelWithString: "")
    private let showsSearch: Bool
    private(set) var selectedId: String?

    init(items: [SidebarItem], showsSearch: Bool) {
        self.items = items
        self.shown = items
        self.showsSearch = showsSearch
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let root = NSView()
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        table.style = .sourceList
        // Selection is `DS.SelectionRowView`'s capsule; the source-list highlight also tinted the
        // selected name with the accent.
        table.selectionHighlightStyle = .regular
        table.headerView = nil
        table.rowHeight = 32
        table.addTableColumn(NSTableColumn(identifier: .init("item")))
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityIdentifier("sidebar")
        scroll.documentView = table
        search.placeholderString = "Search"
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.isHidden = !showsSearch
        search.refusesFirstResponder = false
        noResults.font = DS.Text.body()
        noResults.textColor = .secondaryLabelColor
        noResults.alignment = .center
        noResults.isHidden = true
        noResults.setAccessibilityIdentifier("sidebar.noResults")
        for view in [search, scroll, noResults] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            // Below the traffic lights, which float over the sidebar.
            search.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: DS.Spacing.m),
            search.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: DS.Spacing.l),
            search.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -DS.Spacing.l),
            scroll.topAnchor.constraint(equalTo: showsSearch ? search.bottomAnchor : root.safeAreaLayoutGuide.topAnchor, constant: DS.Spacing.m),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            noResults.topAnchor.constraint(equalTo: scroll.topAnchor, constant: DS.Spacing.xl),
            noResults.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: DS.Spacing.l),
            noResults.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -DS.Spacing.l),
        ])
        view = root
    }

    /// The list, not the search field, holds focus when the window opens, as System Settings
    /// does: the selection shows filled, and typing still reaches search with ⌘F or a click.
    func focusList() {
        view.window?.makeFirstResponder(table)
    }

    func select(id: String) {
        loadViewIfNeeded()
        if !shown.contains(where: { $0.id == id }) {
            search.stringValue = ""
            shown = items
            table.reloadData()
            noResults.isHidden = true
        }
        guard let row = shown.firstIndex(where: { $0.id == id }) else { return }
        table.selectRowIndexes([row], byExtendingSelection: false)
        commit(row)
    }

    private func commit(_ row: Int) {
        guard shown.indices.contains(row), shown[row].id != selectedId else { return }
        selectedId = shown[row].id
        onSelect?(shown[row])
    }

    func controlTextDidChange(_ obj: Notification) {
        shown = items.filter { $0.matches(search.stringValue) }
        table.reloadData()
        let query = search.stringValue.trimmingCharacters(in: .whitespaces)
        noResults.stringValue = "No Results for \u{201C}\(query)\u{201D}"
        noResults.isHidden = !shown.isEmpty || query.isEmpty
        if let selectedId, let row = shown.firstIndex(where: { $0.id == selectedId }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        } else if !shown.isEmpty {
            table.selectRowIndexes([0], byExtendingSelection: false)
            commit(0)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    /// Selected as tabs and the palette are: the soft capsule, not the accent.
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { DS.SelectionRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = shown[row]
        let cell = NSTableCellView()
        let tile = IconTile(symbol: item.symbol, tint: item.tint, size: 22)
        let label = NSTextField(labelWithString: item.title)
        label.font = DS.Text.body()
        let stack = NSStackView(views: [tile, label])
        stack.spacing = DS.Spacing.m
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        // Not the cell's `textField`: the cell would recolor it for the selection (accent blue on
        // the capsule). The row says its name to VoiceOver itself.
        label.textColor = .labelColor
        cell.setAccessibilityLabel(item.title)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { commit(table.selectedRow) }
}

/// A white symbol on a colored rounded square: System Settings' icon.
final class IconTile: NSView {
    init(symbol: String, tint: NSColor, size: CGFloat) {
        super.init(frame: .zero)
        bindLayerBackground(tint)
        layer?.cornerRadius = size * 0.24
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false
        let image = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        image.symbolConfiguration = .init(pointSize: size * 0.56, weight: .medium)
        image.contentTintColor = .white
        image.translatesAutoresizingMaskIntoConstraints = false
        addSubview(image)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size),
            image.centerXAnchor.constraint(equalTo: centerXAnchor),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// Shows one child view controller at a time, filling the content side of a split view.
@MainActor
final class PaneHostController: NSViewController {
    private(set) var current: NSViewController?

    override func loadView() { view = NSView() }

    func show(_ pane: NSViewController) {
        guard pane !== current else { return }
        current?.view.removeFromSuperview()
        current?.removeFromParent()
        addChild(pane)
        pane.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pane.view)
        NSLayoutConstraint.activate([
            pane.view.topAnchor.constraint(equalTo: view.topAnchor),
            pane.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            pane.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pane.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        current = pane
    }
}

/// Preferences, laid out like System Settings: sidebar with search, a title card per pane.
@MainActor
final class SettingsSplitViewController: NSSplitViewController {
    enum Pane: String, CaseIterable {
        case general, notifications, agents, usage, appearance, languages, shortcuts, history
    }

    static let items: [SidebarItem] = [
        SidebarItem(id: Pane.general.rawValue, title: "General", symbol: "gearshape.fill", tint: .systemGray,
                    keywords: ["stages", "pin", "file explorer", "library"], summary: "Which stages the stage control shows, where the Editor's file explorer opens, and the Library."),
        SidebarItem(id: Pane.notifications.rawValue, title: "Notifications", symbol: "bell.badge.fill", tint: .systemRed,
                    keywords: ["sound", "alert", "banner", "glass", "funk", "tink", "needs you", "attention", "focus"], summary: "Notifications and sounds when an agent needs you, only for what happens while you're looking elsewhere."),
        SidebarItem(id: Pane.agents.rawValue, title: "Agents", symbol: "person.2.fill", tint: .systemIndigo,
                    keywords: ["claude code", "codex", "gemini", "pi", "opencode", "default", "sign in", "subscription", "api key", "key", "model", "acp"], summary: "The agent new tracks run on, and how each agent signs in: your subscription through its own sign-in, or an API key you give Side."),
        SidebarItem(id: Pane.usage.rawValue, title: "Usage", symbol: "chart.bar.fill", tint: .systemGreen,
                    keywords: ["tokens", "cost", "spend", "budget", "limit"], summary: "What agents have used and cost, by model and project, and a monthly budget."),
        SidebarItem(id: Pane.appearance.rawValue, title: "Appearance", symbol: "textformat.size", tint: .systemPurple,
                    keywords: ["theme", "dark", "light", "text size", "font", "editor", "terminal"], summary: "Light or dark, and text sizes for Side, the editor and the terminal."),
        SidebarItem(id: Pane.languages.rawValue, title: "Languages", symbol: "chevron.left.forwardslash.chevron.right", tint: .systemPink,
                    keywords: ["language server", "lsp", "completion", "sql", "yaml", "python", "typescript", "format on save", "install"],
                    summary: "Each language's server (completion, problems, go to definition): which one, installed or not, its settings, format on save, and languages of your own."),
        SidebarItem(id: Pane.shortcuts.rawValue, title: "Shortcuts", symbol: "keyboard.fill", tint: .systemTeal,
                    keywords: ["keyboard", "keys", "hotkey", "key binding", "rebind", "command"], summary: "Every keyboard shortcut in Side, by area. Click one and press new keys to change it."),
        SidebarItem(id: Pane.history.rawValue, title: "History", symbol: "clock.fill", tint: .systemOrange,
                    keywords: ["conversations", "retention", "delete", "privacy"], summary: "How long Agent conversations are kept, and deleting them."),
    ]

    private let sidebar = SidebarListController(items: SettingsSplitViewController.items, showsSearch: true)
    private let host = PaneHostController()
    private var panes: [Pane: NSViewController] = [:]
    private(set) var pane: Pane = .general

    override func viewDidLoad() {
        super.viewDidLoad()
        // Panes made earlier and not showing follow a text-size change too.
        TextScaleFollower.addDetachedViews { [weak self] in
            self?.panes.values.filter { $0.isViewLoaded && $0.view.window == nil }.map(\.view) ?? []
        }
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.canCollapse = false
        sidebarItem.minimumThickness = 210
        sidebarItem.maximumThickness = 210
        addSplitViewItem(sidebarItem)
        let content = NSSplitViewItem(viewController: host)
        content.minimumThickness = SettingsForm.contentWidth + SettingsForm.pageInset * 2
        addSplitViewItem(content)
        sidebar.onSelect = { [weak self] item in
            guard let pane = Pane(rawValue: item.id) else { return }
            self?.show(pane)
        }
        sidebar.select(id: Pane.general.rawValue)
    }

    func select(_ pane: Pane) {
        loadViewIfNeeded()
        sidebar.select(id: pane.rawValue)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        sidebar.focusList()
    }

    private func show(_ pane: Pane) {
        self.pane = pane
        let controller = panes[pane] ?? make(pane)
        panes[pane] = controller
        host.show(controller)
        view.window?.title = Self.items.first { $0.id == pane.rawValue }?.title ?? "Preferences"
    }

    private func make(_ pane: Pane) -> NSViewController {
        switch pane {
        case .general: GeneralPreferencesViewController()
        case .notifications: NotificationsPreferencesViewController()
        case .agents: AgentsPreferencesViewController()
        case .usage: UsageViewController()
        case .appearance: AppearanceViewController()
        case .languages: LanguagesViewController()
        case .shortcuts: ShortcutsViewController()
        case .history: HistoryViewController()
        }
    }

    /// The title card for a pane, from its sidebar item.
    static func hero(_ pane: Pane) -> NSView {
        guard let item = items.first(where: { $0.id == pane.rawValue }) else { return NSView() }
        return SettingsForm.hero(symbol: item.symbol, tint: item.tint, title: item.title, detail: item.summary)
    }
}
