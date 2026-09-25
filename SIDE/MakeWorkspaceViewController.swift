import AlloyAppKit
import AppKit
import Heron

private enum TabKind { case text, image, csv }

/// A text's size and a hash of its bytes: enough to tell "back to what's saved" from an edit.
/// Hashes the UTF-8 bytes directly (`String.hashValue` normalizes first, ~8 ms on 3 MB).
struct ContentStamp: Equatable, Sendable {
    let count: Int
    let hash: Int
    init(_ text: String) {
        var text = text
        var hasher = Hasher()
        count = text.utf8.count
        text.withUTF8 { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
        hash = hasher.finalize()
    }
}

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
    let id = UUID()
    var url: URL
    let kind: TabKind
    let document: EditorDocument
    let undoManager: UndoManager
    var dirty: Bool
    var isUntitled: Bool
    var knownModificationDate: Date?
    /// How the file is stored — encoding, BOM, line ending — so a save writes the same shape back.
    var format: TextFileCodec.Format = .utf8
    /// Set when the file changed on disk while this tab had unsaved edits; cleared by Reload or
    /// Keep. A clean tab is simply reloaded instead.
    var hasExternalChange = false
    /// The content as last loaded or saved — so undoing back to it clears the unsaved state
    /// instead of leaving a file "edited" that matches disk.
    var savedStamp = ContentStamp("")
    var lastSelectedRange = NSRange(location: 0, length: 0)
    var csvRows: [[String]] = []
    var diagnostics: [LSPDiagnostic] = []
    var isPreviewingMarkdown = false
    var cachedImage: NSImage?
    var headCache: HeadContentCache = .notFetched
    var isSaving = false
}

private struct IndexedFile {
    let url: URL
    let relativePath: String
}

/// One row of the palette's `commands` mode: every stage and every Navigate item, by name.
struct PaletteCommand {
    let title: String
    let shortcut: String?
    let perform: () -> Void
}

/// Which list the palette is showing. `commands` is also reached by typing `>` in any mode.
enum PaletteMode { case files, symbols, text, commands }

final class MakeWorkspaceViewController: NSViewController, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    let searchField = QuickOpenSearchField()
    /// Make's editor: Alloy (SIDE_RFC_ALLOY.md), behind the `EditorEngine` seam.
    private(set) lazy var editor: EditorEngine = AlloyEditorEngine(appearance: Self.editorAppearance)
    private var editorScroll: NSScrollView { editor.scrollView }
    /// What Make lays out and hides: Alloy's editor view, which holds its scroll view.
    private var editorContainer: NSView { editor.containerView }
    private var gutter: NSView { editor.gutterView }
    private let tabBar = TabStripView()
    /// Shown when a project is open but nothing is — the charter's empty-state rule: one quiet
    /// sentence plus the action that fixes it.
    private let noFileLabel = NSTextField(labelWithString: "No file open. Press ⌘P to find one.")
    private let tabBarStack = NSStackView()
    private let emptyState = NSStackView()
    private let recentProjectsStack = NSStackView()
    private let openRecentMenu = NSMenu(title: "Open Recent")
    /// The three floating panels are created on first use, not at init.
    ///
    /// An NSPanel is a window-server object — creating one is a round trip to WindowServer plus
    /// a backing store — and all three were built inside `makeWindow`, before the first frame,
    /// for surfaces most launches never open. The views that go *inside* them are cheap and stay
    /// eager (`quickOpenSurface` etc.), so showing a panel the first time costs only the window.
    /// `prepareForClose` checks the storage directly so closing a window never creates a panel
    /// just to tear it down.
    /// The palette (Direction 02 §3.6): field and results in one surface, hosted by the window's
    /// chrome rather than a child window — so it can open from any stage, and opening it never
    /// takes key status from the window an agent's edit is being applied to.
    private(set) var paletteSurface: NSView!
    /// The chrome decides where the surface goes; Make only says how big it wants to be.
    var onPaletteShow: ((NSSize) -> Void)?
    var onPaletteHide: (() -> Void)?
    /// A result was chosen that lives in Make (a file, a symbol, a line) — the shell brings Make
    /// forward if the palette was opened from another stage.
    var onPaletteNavigated: (() -> Void)?
    var commandsProvider: (() -> [PaletteCommand])?
    private var paletteIsOpen = false
    private weak var paletteReturnResponder: NSResponder?
    private var commandMatches: [PaletteCommand] = []
    private let resultsTable = NSTableView()
    /// The file explorer (`FileExplorer`): its own component; Make only hosts it.
    private let explorer = FileExplorer()
    private let imageScroll = NSScrollView()
    private let imageView = NSImageView()
    private let csvScroll = NSScrollView()
    private let csvTable = NSTableView()
    private let markdownPreviewScroll = NSScrollView()
    private let markdownPreviewView = MarkdownPreviewTextView.make()
    /// What the preview shows now (tab, text, style), so switching back to an unchanged document
    /// neither renders nor lays it out again, and keeps its scroll position.
    private var markdownPreviewShown: (tab: UUID, stamp: ContentStamp, generation: Int)?
    private var markdownPreviewGeneration = 0
    private let markdownLinks = MarkdownPreviewLinks()
    private var completionPanelStorage: CompletionPanel?
    private var completionSurface: NSView?
    private var completionPanel: CompletionPanel {
        if let existing = completionPanelStorage { return existing }
        let panel = CompletionPanel()
        panel.contentView = completionSurface
        completionPanelStorage = panel
        return panel
    }
    private let completionTable = NSTableView()
    private var completionItems: [LSPCompletionItem] = []
    private var completionSelectedIndex = 0
    private var completionReplacementRange: NSRange?
    private var pendingCompletionWorkItem: DispatchWorkItem?
    private var completionGeneration = 0
    private var isAcceptingCompletion = false
    private var suppressNextSelectionDismiss = false
    private var quickOpenLocalMonitor: Any?
    private var quickOpenGlobalMonitor: Any?
    private var currentDiffHunks: [GitHunk] = []
    private var currentDiffHeadContent: String?
    /// Canonical identity — the repo root as originally opened. Used for window/recent-project
    /// identity and the per-track file-memory key, neither of which should change just because
    /// the active track happens to have its own worktree.
    private var projectURL: URL?
    /// Where files actually live for whatever's currently focused — the active track's own
    /// worktree if it has one, else `projectURL`. Everything that touches real files on disk
    /// (indexing, the file explorer, git diff/blame, the formatter, LSP) operates against this,
    /// not `projectURL`.
    private var focusedRoot: URL?
    private var projectWatcher: ProjectWatcher?
    private var pendingReindex: DispatchWorkItem?
    private var keyWindowObserver: NSObjectProtocol?
    private let externalChangeBanner = NSView()
    private let externalChangeLabel = NSTextField(labelWithString: "")
    private var lspManager: LSPManager?
    /// Trails Make's tab strip in the top row (Direction 02 §4.5).
    /// The active file's language server, trailing the tab strip: caption + dot (§4.5).
    let lspStatusButton = LSPStatusChip()
    private var lspInstallPopover: NSPopover?
    private var allFiles: [IndexedFile] = []
    private var matches: [URL] = []
    private typealias SearchMode = PaletteMode
    /// Find in Project results, one row per matching line.
    private var textMatches: [ProjectTextSearch.Match] = []
    private var textSearchTruncated = false
    private var searchMode: SearchMode = .files
    /// Typing `>` switches any mode to commands, the way every palette does.
    private var effectiveMode: SearchMode { searchField.stringValue.hasPrefix(">") ? .commands : searchMode }
    private var symbolMatches: [CodeSymbol] = []
    private var openTabs: [OpenTab] = []
    private var activeTabIndex: Int?
    private var tabChips: [TabChipView] = []
    private var dirty = false { didSet { onDirtyChanged?(dirty) } }
    var onProjectOpened: ((URL) -> Void)?
    var onFileOpened: ((URL?) -> Void)?
    var onDirtyChanged: ((Bool) -> Void)?
    /// A tab torn off the strip (drag-out or "Move to New Window") — the shell owns windows, so
    /// it decides what a new one on this project/track looks like. Point is in screen coords.
    var onTearOutRequested: ((URL, NSPoint) -> Void)?
    /// ⌘K on a selection (or a diagnostic): the shell sends it to the track's Think conversation.
    var onInstruct: ((InlineInstruct.Request) -> Void)?
    /// "Continue in Think" / "Open in Think" from an instruct surface.
    var onOpenThinkRequested: (() -> Void)?
    private var instructPopover: NSPopover?
    private var instructController: InstructPopoverController?
    private var instructCard: InstructProposalCard?
    /// Set on a window made by tearing a tab out: it opens with that one file, not the
    /// project's remembered tabs, and never writes its tabs back into that memory — a
    /// scratch window must not change what the main window restores next launch.
    var soleFile: URL?
    private let lastProjectKey = "side.last-project-path"
    private let lastFilesByProjectKey = "side.last-files-by-project"
    private let openTabsByProjectKey = "side.open-tabs-by-project"
    /// Suppresses per-open persistence while the remembered set is being reopened.
    private var isRestoringTabs = false
    private let recentProjectsKey = "side.recent-projects"
    private let maxRecentProjects = 8
    private var pendingSearchWorkItem: DispatchWorkItem?
    private var searchGeneration = 0
    private static let editorBackground = DS.Color.canvas
    /// At the editor text-size setting (Appearance), not the interface scale.
    private static var editorFont: NSFont { DS.Text.editor() }
    private static let editorTextColor = NSColor.labelColor
    static var editorAppearance: EditorAppearance {
        EditorAppearance(font: editorFont, textColor: editorTextColor, background: editorBackground)
    }

    override func loadView() { view = NSView() }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(self, selector: #selector(editorTextSizeChanged), name: DS.Text.CodeSize.didChangeNotification, object: nil)
        // Undo and redo can land the buffer back on what's saved; typing never can, so only
        // these two re-check (a hash of the buffer, never on every keystroke).
        for name in [Notification.Name.NSUndoManagerDidUndoChange, Notification.Name.NSUndoManagerDidRedoChange] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let managerID = (note.object as AnyObject?).map(ObjectIdentifier.init)
                MainActor.assumeIsolated { self?.undoStateChanged(managerID) }
            }
        }
        LaunchSignposts.begin("makeViewDidLoad")
        buildView()
        buildMenu()
        configureQuickOpenKeys()
        refreshRecentProjectsList()
        lspStatusButton.target = self
        lspStatusButton.action = #selector(showLSPStatusPopover)
        lspStatusButton.isHidden = true
        LaunchSignposts.end("makeViewDidLoad")
    }

    /// Recents are shared across windows via UserDefaults — refresh on every appearance so a
    /// newly-created window's empty state (or this one, if left idle on it) reflects projects
    /// opened elsewhere in the meantime.
    override func viewWillAppear() {
        super.viewWillAppear()
        LaunchSignposts.begin("makeViewWillAppear")
        refreshRecentProjectsList()
        LaunchSignposts.end("makeViewWillAppear")
    }

    /// The file explorer is a child *window* of the whole app window (so it can float above
    /// Make's own content), not a subview of this controller's own view — which means switching
    /// stages, which only swaps the container's child view controller, never touches it. Without
    /// this it kept floating on top of Run or Tracks after switching away, which made no sense:
    /// it's a Make-only affordance (browse → open into the editor), and there's no editor to open
    /// into while looking at another stage.
    override func viewWillDisappear() {
        super.viewWillDisappear()
        explorer.hide()
    }

    /// Opening a file (or dismissing quick-open) claims first responder as a side effect
    /// elsewhere in this file, but neither of those necessarily happens on every reappearance —
    /// switching to another stage and back with no tabs open, for instance, leaves the window's
    /// first responder wherever the *previous* stage left it (or the window itself), which is
    /// outside this controller's view hierarchy entirely. Without reclaiming it here, the
    /// responder chain never reaches MakeWorkspaceViewController while this stage is visible,
    /// silently disabling every Navigate-menu action (Toggle File Explorer included) — same gap
    /// Tracks already hit and fixed the same way.
    override func viewDidAppear() {
        super.viewDidAppear()
        LaunchSignposts.begin("makeViewDidAppear")
        if keyWindowObserver == nil, let window = view.window {
            configureExternalChangeBanner()
            keyWindowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reconcileAllTabsWithDisk() }
            }
        }
        if let index = activeTabIndex, openTabs.indices.contains(index), openTabs[index].kind == .text {
            editor.focus()
        }
        LaunchSignposts.end("makeViewDidAppear")
    }

    private func buildView() {
        view.wantsLayer = true
        ChromeBackground.install(in: view)

        searchField.placeholderString = "Open file, symbol, or command"
        searchField.delegate = self

        // The strip is the one surface allowed to be darker than the editor (DS.Color.canvas)
        // — that contrast, plus the hairline passing *behind* the chips, is what lets the active
        // tab (filled with the editor's own color, flush to the strip's bottom edge) read as
        // attached to the content below rather than floating in a bar.
        tabBar.wantsLayer = true
        // No fill and no seam line of its own: the strip sits in the window's top row, which
        // takes the editor's surface, so the tabs and the file below are one sheet.
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        // Not clipped: the glass track's shadow extends past the strip, and clipping it drew a
        // faint rectangle under the capsule. The tabs clip inside their own scroll view.
        tabBar.clipsToBounds = false
        let divider = NSBox()
        divider.boxType = .custom
        divider.borderType = .noBorder
        divider.fillColor = DS.Color.hairlineStrong
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.isHidden = true
        tabBar.addSubview(divider)
        tabBarStack.orientation = .horizontal
        tabBarStack.alignment = .centerY
        tabBarStack.spacing = DS.Spacing.xxs
        tabBarStack.translatesAutoresizingMaskIntoConstraints = false
        // The strip scrolls once chips outgrow the window — the old required trailing
        // constraint literally forced the *window* to widen with every opened tab.
        let tabScroll = TabStripScrollView()
        tabScroll.drawsBackground = false
        tabScroll.hasHorizontalScroller = false
        tabScroll.hasVerticalScroller = false
        tabScroll.verticalScrollElasticity = .none
        tabScroll.horizontalScrollElasticity = .allowed
        tabScroll.automaticallyAdjustsContentInsets = false
        tabScroll.translatesAutoresizingMaskIntoConstraints = false
        tabScroll.documentView = tabBarStack
        tabBar.addSubview(tabScroll)
        tabBar.installGlassTrack(behind: tabScroll, hugging: tabBarStack)
        // Hosted in the window's top row (Direction 02 §3.2) — see `topRowContent`.
        lspStatusButton.translatesAutoresizingMaskIntoConstraints = false
        tabBar.addSubview(lspStatusButton)
        noFileLabel.font = DS.Text.body()
        noFileLabel.textColor = .tertiaryLabelColor
        noFileLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(noFileLabel)
        NSLayoutConstraint.activate([
            noFileLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            noFileLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        NSLayoutConstraint.activate([
            tabScroll.leadingAnchor.constraint(equalTo: tabBar.leadingAnchor), tabScroll.trailingAnchor.constraint(equalTo: lspStatusButton.leadingAnchor, constant: -DS.Spacing.s), tabScroll.topAnchor.constraint(equalTo: tabBar.topAnchor), tabScroll.bottomAnchor.constraint(equalTo: tabBar.bottomAnchor),
            lspStatusButton.trailingAnchor.constraint(equalTo: tabBar.trailingAnchor), lspStatusButton.centerYAnchor.constraint(equalTo: tabBar.centerYAnchor),
            tabBarStack.leadingAnchor.constraint(equalTo: tabScroll.contentView.leadingAnchor), tabBarStack.topAnchor.constraint(equalTo: tabScroll.contentView.topAnchor), tabBarStack.heightAnchor.constraint(equalTo: tabScroll.heightAnchor),
            divider.leadingAnchor.constraint(equalTo: tabBar.leadingAnchor), divider.trailingAnchor.constraint(equalTo: tabBar.trailingAnchor), divider.bottomAnchor.constraint(equalTo: tabBar.bottomAnchor), divider.heightAnchor.constraint(equalToConstant: 1)
        ])

        editor.delegate = self
        editorContainer.isHidden = true
        editorContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(editorContainer)
        gutter.isHidden = true
        gutter.translatesAutoresizingMaskIntoConstraints = false
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

        markdownPreviewView.isEditable = false
        markdownPreviewView.isSelectable = true
        markdownPreviewView.drawsBackground = true
        markdownPreviewView.backgroundColor = Self.editorBackground
        markdownPreviewView.onAppearanceChange = { [weak self] in self?.restyleMarkdownPreview() }
        // For `textView(_:clickedOnLink:at:)` — in-document `#anchor` links scroll the preview
        // instead of being handed to the OS as if they were web URLs.
        markdownPreviewView.delegate = markdownLinks
        markdownPreviewScroll.documentView = markdownPreviewView
        markdownPreviewScroll.hasVerticalScroller = true
        markdownPreviewScroll.backgroundColor = Self.editorBackground
        markdownPreviewScroll.drawsBackground = true
        markdownPreviewScroll.isHidden = true
        markdownPreviewScroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(markdownPreviewScroll)

        let headline = NSTextField(labelWithString: "Open a project")
        headline.font = DS.Text.title(.medium)
        headline.alignment = .center
        let detail = NSTextField(wrappingLabelWithString: "Start with the code. Side will restore this workspace when you come back.")
        detail.font = DS.Text.body()
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        detail.maximumNumberOfLines = 2
        let open = NSButton(title: "Open Project…", target: self, action: #selector(openProject))
        open.bezelStyle = .rounded
        open.controlSize = .large
        let newProjectButton = NSButton(title: "New Project…", target: self, action: #selector(newProject))
        newProjectButton.bezelStyle = .rounded
        newProjectButton.controlSize = .large
        let buttonsRow = NSStackView(views: [newProjectButton, open])
        buttonsRow.orientation = .horizontal
        buttonsRow.spacing = DS.Spacing.l
        recentProjectsStack.orientation = .vertical
        recentProjectsStack.alignment = .centerX
        recentProjectsStack.spacing = DS.Spacing.xs
        emptyState.orientation = .vertical
        emptyState.alignment = .centerX
        emptyState.spacing = DS.Spacing.xl
        [headline, detail, buttonsRow, recentProjectsStack].forEach(emptyState.addArrangedSubview)
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyState)

        NSLayoutConstraint.activate([
            gutter.topAnchor.constraint(equalTo: view.topAnchor), gutter.leadingAnchor.constraint(equalTo: view.leadingAnchor), gutter.bottomAnchor.constraint(equalTo: view.bottomAnchor), gutter.widthAnchor.constraint(equalToConstant: AlloyGutterView.width),
            editorContainer.topAnchor.constraint(equalTo: view.topAnchor), editorContainer.leadingAnchor.constraint(equalTo: gutter.trailingAnchor), editorContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor), editorContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            imageScroll.topAnchor.constraint(equalTo: view.topAnchor), imageScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), imageScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor), imageScroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            csvScroll.topAnchor.constraint(equalTo: view.topAnchor), csvScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), csvScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor), csvScroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            markdownPreviewScroll.topAnchor.constraint(equalTo: view.topAnchor), markdownPreviewScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), markdownPreviewScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor), markdownPreviewScroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            emptyState.centerXAnchor.constraint(equalTo: view.centerXAnchor), emptyState.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -30), detail.widthAnchor.constraint(lessThanOrEqualToConstant: 460)
        ])
        LaunchSignposts.begin("makePanelSurfaces")
        configureQuickOpenPanel()
        configureExplorer()
        configureCompletionPanel()
        LaunchSignposts.end("makePanelSurfaces")
    }

    private func configureQuickOpenKeys() {
        searchField.onMove = { [weak self] direction in self?.moveSelection(direction) }
        searchField.onConfirm = { [weak self] in self?.confirmSearch() }
        searchField.onCancel = { [weak self] in self?.dismissQuickOpen() }
    }

    private let quickOpenRowHeight: CGFloat = 36
    private let quickOpenMaxVisibleRows = 8

    private let paletteDivider = NSBox()

    /// Spotlight's shape: one large borderless field, results below it on the same glass, a
    /// divider only when there are results, and a height that is exactly its rows.
    private func configureQuickOpenPanel() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("path"))
        resultsTable.addTableColumn(column)
        resultsTable.headerView = nil
        // `.plain`, explicitly: the default (inset) style pads every row beyond `rowHeight`,
        // which is what clipped a single result off the bottom of the surface.
        resultsTable.style = .plain
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

        let glyph = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 17, weight: .regular)) ?? NSImage())
        glyph.contentTintColor = .secondaryLabelColor
        glyph.translatesAutoresizingMaskIntoConstraints = false
        searchField.isBordered = false
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = DS.Text.custom(19)
        searchField.cell?.usesSingleLineMode = true
        searchField.cell?.lineBreakMode = .byTruncatingTail
        searchField.translatesAutoresizingMaskIntoConstraints = false
        paletteDivider.boxType = .custom
        paletteDivider.borderType = .noBorder
        paletteDivider.fillColor = DS.Color.hairline
        paletteDivider.translatesAutoresizingMaskIntoConstraints = false
        let body = NSView()
        body.translatesAutoresizingMaskIntoConstraints = false
        for view in [glyph, searchField, paletteDivider, scroll] as [NSView] { body.addSubview(view) }
        NSLayoutConstraint.activate([
            glyph.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 18),
            glyph.centerYAnchor.constraint(equalTo: body.topAnchor, constant: Self.paletteHeaderHeight / 2),
            searchField.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -18),
            searchField.centerYAnchor.constraint(equalTo: glyph.centerYAnchor),
            paletteDivider.topAnchor.constraint(equalTo: body.topAnchor, constant: Self.paletteHeaderHeight),
            paletteDivider.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            paletteDivider.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            paletteDivider.heightAnchor.constraint(equalToConstant: 1),
            scroll.topAnchor.constraint(equalTo: paletteDivider.bottomAnchor, constant: Self.paletteListPadding),
            scroll.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -Self.paletteListPadding),
        ])
        paletteSurface = Self.makeFloatingPanelSurface(embedding: body, cornerRadius: 16, padding: 0)
        paletteSurface.setAccessibilityElement(true)
        paletteSurface.setAccessibilityRole(.group)
        paletteSurface.setAccessibilityLabel("Palette")
    }

    private let completionRowHeight: CGFloat = 22
    private let completionMaxVisibleRows = 8

    private func configureCompletionPanel() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("completion"))
        completionTable.addTableColumn(column)
        completionTable.headerView = nil
        completionTable.rowHeight = completionRowHeight
        completionTable.intercellSpacing = NSSize(width: 0, height: 0)
        completionTable.backgroundColor = .clear
        completionTable.selectionHighlightStyle = .regular
        completionTable.dataSource = self
        completionTable.delegate = self

        let scroll = NSScrollView()
        scroll.documentView = completionTable
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        scroll.translatesAutoresizingMaskIntoConstraints = false

        completionSurface = Self.makeFloatingPanelSurface(embedding: scroll, cornerRadius: 6, padding: 6)
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

    private static let paletteWidth: CGFloat = 640
    private static let paletteHeaderHeight: CGFloat = 54
    private static let paletteListPadding: CGFloat = 6

    private func showQuickOpenPanel() {
        guard paletteIsOpen else { return }
        let rows = min(quickOpenMaxVisibleRows, resultCount)
        paletteDivider.isHidden = rows == 0
        let list = rows == 0 ? 0 : 1 + Self.paletteListPadding * 2 + CGFloat(rows) * quickOpenRowHeight
        let height = Self.paletteHeaderHeight + list
        onPaletteShow?(NSSize(width: Self.paletteWidth, height: height))
        installQuickOpenDismissMonitors()
    }

    private func hideQuickOpenPanel() {
        removeQuickOpenDismissMonitors()
        guard paletteIsOpen else { return }
        paletteIsOpen = false
        onPaletteHide?()
    }

    private func installQuickOpenDismissMonitors() {
        guard quickOpenLocalMonitor == nil else { return }
        quickOpenLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.dismissQuickOpenIfClickOutside(event)
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

    private func dismissQuickOpenIfClickOutside(_ event: NSEvent) {
        guard let surface = paletteSurface, let window = surface.window, event.window === window else { hideQuickOpenPanel(); return }
        let point = surface.convert(event.locationInWindow, from: nil)
        if surface.bounds.insetBy(dx: -2, dy: -2).contains(point) { return }
        hideQuickOpenPanel()
    }

    /// Opens the palette in `mode` from any stage. Escape puts focus back where it was.
    func presentPalette(_ mode: PaletteMode) {
        if mode == .symbols && activeTabIndex == nil { return }
        if mode == .text && projectURL == nil { return }
        let window = view.window ?? NSApp.keyWindow
        if !paletteIsOpen { paletteReturnResponder = window?.firstResponder }
        paletteIsOpen = true
        searchMode = mode == .commands ? .files : mode
        let project = projectURL?.lastPathComponent
        switch mode {
        case .files: searchField.placeholderString = project.map { "Find a file in \($0)   ·   > for commands" } ?? "Type > for commands"
        case .text: searchField.placeholderString = project.map { "Search text in \($0)" } ?? "Search text"
        case .symbols: searchField.placeholderString = "Go to symbol"
        case .commands: searchField.placeholderString = "Run a command"
        }
        searchField.stringValue = mode == .commands ? ">" : ""
        showQuickOpenPanel()
        searchField.window?.makeFirstResponder(searchField)
        (searchField.currentEditor() as? NSTextView)?.moveToEndOfDocument(nil)
        performSearch()
    }

    var isPaletteOpen: Bool { paletteIsOpen }

    // MARK: - File explorer


    @objc private func toggleFileExplorer() {
        guard let window = view.window else { return }
        explorer.toggle(in: window)
    }

    /// The explorer reports what it did to the files; Make keeps its tabs and index true to it.
    private func configureExplorer() {
        explorer.onOpen = { [weak self] url in self?.open(url) }
        explorer.currentFile = { [weak self] in
            guard let self, let index = self.activeTabIndex, self.openTabs.indices.contains(index) else { return nil }
            return self.openTabs[index].url
        }
        explorer.onFilesChanged = { [weak self] in self?.refreshFileTreeAndReindex() }
        explorer.onHidden = { [weak self] in
            guard let self, self.view.window != nil else { return }
            self.editor.focus()
        }
        // A moved file or folder keeps its tabs: every tab at or under the old path follows it.
        explorer.onMoved = { [weak self] from, to in
            guard let self else { return }
            let old = from.standardizedFileURL.path
            var changed = false
            for index in self.openTabs.indices {
                let path = self.openTabs[index].url.path
                if path == old || path.hasPrefix(old + "/") {
                    self.openTabs[index].url = URL(fileURLWithPath: to.standardizedFileURL.path + path.dropFirst(old.count))
                    changed = true
                }
            }
            guard changed else { return }
            self.rebuildTabBar()
            if let active = self.activeTabIndex { self.onFileOpened?(self.openTabs[active].url) }
        }
        explorer.onTrashed = { [weak self] url in
            guard let self else { return }
            let old = url.standardizedFileURL.path
            for index in self.openTabs.indices.reversed() where self.openTabs[index].url.path == old || self.openTabs[index].url.path.hasPrefix(old + "/") {
                self.closeTab(at: index)
            }
        }
    }










    // MARK: - File explorer context menu (new / rename / delete)

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === openRecentMenu {
            menu.removeAllItems()
            let recents = recentProjects()
            if recents.isEmpty {
                menu.addItem(withTitle: "No Recent Projects", action: nil, keyEquivalent: "").isEnabled = false
            } else {
                for url in recents {
                    let item = menu.addItem(withTitle: url.lastPathComponent, action: #selector(openRecentProjectMenuItem(_:)), keyEquivalent: "")
                    item.toolTip = url.path
                    item.representedObject = url
                    item.target = self
                }
            }
            return
        }
    }





    private func showFileOperationError(_ message: String, _ error: Error) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window, completionHandler: nil)
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
        guard let root = focusedRoot else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let indexed = Self.indexFiles(at: root)
            DispatchQueue.main.async {
                guard let self, self.focusedRoot == root else { return }
                self.allFiles = indexed
            }
        }
    }


    // MARK: - Per-project (and per-track) file memory & recent projects

    /// `nil` when there's no active track (a project not using Tracks, or sitting on the default
    /// branch between tracks) — falls back to one shared per-project bucket, same as before
    /// Tracks existed. Non-nil keys the memory to that track's branch specifically, so switching
    /// tracks doesn't dump you on whatever file the *last* track happened to have open.
    var currentTrackKey: String?

    private func compositeMemoryKey(for project: URL) -> String {
        "\(project.path)#\(currentTrackKey ?? "")"
    }

    private func rememberLastFile(_ fileURL: URL, forProject project: URL) {
        guard soleFile == nil else { return }
        var map = UserDefaults.standard.dictionary(forKey: lastFilesByProjectKey) as? [String: String] ?? [:]
        map[compositeMemoryKey(for: project)] = fileURL.path
        UserDefaults.standard.set(map, forKey: lastFilesByProjectKey)
    }

    private func lastFile(forProject project: URL) -> URL? {
        guard let map = UserDefaults.standard.dictionary(forKey: lastFilesByProjectKey) as? [String: String],
              let path = map[compositeMemoryKey(for: project)] else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Remembers the whole open tab *set*, in order, plus which one was active.
    ///
    /// The single-path memory above is kept as the fallback for a project last opened by an
    /// older build. Reopening a project used to restore exactly one file no matter how many had
    /// been open, because one path is all that was ever stored — not a regression, a feature
    /// that was never written.
    ///
    /// Untitled tabs are deliberately excluded: they have no path to restore from, and their
    /// content lives only in the buffer.
    private func rememberOpenTabs(forProject project: URL) {
        guard soleFile == nil else { return }
        var map = UserDefaults.standard.dictionary(forKey: openTabsByProjectKey) as? [String: [String]] ?? [:]
        let paths = openTabs.filter { !$0.isUntitled }.map(\.url.path)
        if paths.isEmpty {
            map.removeValue(forKey: compositeMemoryKey(for: project))
        } else {
            map[compositeMemoryKey(for: project)] = paths
        }
        UserDefaults.standard.set(map, forKey: openTabsByProjectKey)
    }

    private func rememberedOpenTabs(forProject project: URL) -> [URL] {
        guard let map = UserDefaults.standard.dictionary(forKey: openTabsByProjectKey) as? [String: [String]],
              let paths = map[compositeMemoryKey(for: project)] else { return [] }
        return paths.map { URL(fileURLWithPath: $0) }
    }

    /// Syncs the open tab for `url` to content the applier has *already written to disk*, and
    /// returns whether there was one.
    ///
    /// The tab is marked **clean**, not dirty: the bytes on disk and the bytes in the buffer are
    /// now identical, so claiming unsaved changes would be false — and it was actively harmful,
    /// because closing the tab then offered "Don't Save" on a change the user had already
    /// approved and that a checkpoint had already committed.
    func applyApprovedEdit(url: URL, newContent: String) -> Bool {
        guard let index = openTabs.firstIndex(where: { $0.url == url && $0.kind == .text }) else { return false }
        let tab = openTabs[index]
        tab.document.replaceAll(with: newContent)
        tab.document.highlight(url: tab.url, appearance: Self.editorAppearance)
        openTabs[index].dirty = false
        openTabs[index].savedStamp = ContentStamp(newContent)
        // The applier just wrote this file, so the stamp used for external-change detection has
        // to move with it — otherwise the next save or focus-in reports "changed on disk" about
        // Side's own write.
        openTabs[index].knownModificationDate = modificationDate(of: url)
        // The undo stack's registrations describe the *old* text, so replaying them after a
        // whole-buffer replacement would apply unrelated edits at meaningless offsets. Clearing
        // is the honest option: ⌘Z can't undo the agent's edit (Review's Undo does that), but it
        // also can't corrupt the file.
        tab.undoManager.removeAllActions()
        // HEAD content is unchanged by an edit, but the marks derived from it are stale.
        if activeTabIndex == index {
            dirty = false
            editor.invalidateGutter()
            refreshGitDiffMarks()
        }
        rebuildTabBar()
        return true
    }

    /// Opens `url` and reveals it, so approving an edit lands the user in the file that changed.
    func revealAfterApply(_ url: URL) {
        revealFile(url, line: nil)
    }

    /// Unsaved editor content for `url`, or nil if that file isn't open with pending edits.
    /// Heron's read tools consult this so an agent reasons about what's on screen rather than
    /// stale disk content. Only dirty tabs are reported — for a clean tab, disk is identical
    /// and reading the file directly avoids copying a whole buffer per call.
    func unsavedContent(for url: URL) -> String? {
        guard let tab = openTabs.first(where: { $0.url == url && $0.kind == .text && $0.dirty }) else { return nil }
        return tab.document.string
    }

    /// Called when a track is deleted — its remembered file has nowhere to belong anymore, so the
    /// entry is dropped rather than left as permanent dead weight in the defaults dictionary.
    func forgetLastFile(forTrackKey trackKey: String?) {
        guard let projectURL else { return }
        var map = UserDefaults.standard.dictionary(forKey: lastFilesByProjectKey) as? [String: String] ?? [:]
        map.removeValue(forKey: "\(projectURL.path)#\(trackKey ?? "")")
        UserDefaults.standard.set(map, forKey: lastFilesByProjectKey)
    }

    private func rememberRecentProject(_ project: URL) {
        var recents = UserDefaults.standard.stringArray(forKey: recentProjectsKey) ?? []
        recents.removeAll { $0 == project.path }
        recents.insert(project.path, at: 0)
        if recents.count > maxRecentProjects { recents.removeLast(recents.count - maxRecentProjects) }
        UserDefaults.standard.set(recents, forKey: recentProjectsKey)
    }

    private func recentProjects() -> [URL] {
        let recents = UserDefaults.standard.stringArray(forKey: recentProjectsKey) ?? []
        return recents.filter { $0 != projectURL?.path }.map { URL(fileURLWithPath: $0) }
    }

    private func refreshRecentProjectsList() {
        LaunchSignposts.begin("recents")
        recentProjectsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let recents = recentProjects()
        guard !recents.isEmpty else { return }
        let label = NSTextField(labelWithString: "Recent Projects")
        label.font = DS.Text.caption(.semibold)
        label.textColor = .tertiaryLabelColor
        recentProjectsStack.addArrangedSubview(label)
        recentProjectsStack.setCustomSpacing(DS.Spacing.m, after: label)

        // NSGridView (not per-row NSStackViews) so the name column and path column each
        // line up across rows instead of every row sizing independently to its own content.
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.rowSpacing = 4
        grid.columnSpacing = 10
        for url in recents {
            let nameButton = NSButton(title: url.lastPathComponent, target: self, action: #selector(openRecentProjectRow(_:)))
            nameButton.bezelStyle = .inline
            nameButton.isBordered = false
            nameButton.contentTintColor = .linkColor
            nameButton.toolTip = url.path
            nameButton.identifier = NSUserInterfaceItemIdentifier(url.path)

            let pathLabel = NSTextField(labelWithString: abbreviatedParentPath(of: url))
            pathLabel.font = DS.Text.caption()
            pathLabel.textColor = .tertiaryLabelColor
            pathLabel.lineBreakMode = .byTruncatingMiddle
            pathLabel.maximumNumberOfLines = 1
            pathLabel.alignment = .right
            pathLabel.toolTip = url.path
            pathLabel.translatesAutoresizingMaskIntoConstraints = false
            // Middle-truncated so both ends of the path stay legible (the identifying leaf
            // directories) rather than losing the tail to a fixed-width tail truncation. Fixed
            // (not max) width so right-alignment actually lines paths up flush on the right
            // instead of each just right-aligning within its own ragged content width.
            pathLabel.widthAnchor.constraint(equalToConstant: 320).isActive = true

            grid.addRow(with: [nameButton, pathLabel])
        }
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .trailing
        recentProjectsStack.addArrangedSubview(grid)
        LaunchSignposts.end("recents")
    }

    private func abbreviatedParentPath(of url: URL) -> String {
        let parent = url.deletingLastPathComponent().path
        let home = NSHomeDirectory()
        if parent == home { return "~" }
        if parent.hasPrefix(home + "/") { return "~" + parent.dropFirst(home.count) }
        return parent
    }

    @objc private func openRecentProjectRow(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        openRecentProject(at: URL(fileURLWithPath: path))
    }

    @objc private func openRecentProjectMenuItem(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        openRecentProject(at: url)
    }

    private func openRecentProject(at url: URL) {
        confirmAllUnsavedChanges { [weak self] proceed in
            guard let self, proceed else { return }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                if let window = self.view.window { self.showAlert(title: "Can't find this project", message: "\(url.lastPathComponent) no longer exists at \(url.path).", window: window) }
                return
            }
            self.closeAllTabsImmediately()
            self.loadProject(at: url)
        }
    }

    @objc func openProjectFromMenuAction() { openProject() }

    @objc private func openProject() {
        confirmAllUnsavedChanges { [weak self] proceed in
            guard let self, proceed, let window = self.view.window else { return }
            let panel = NSOpenPanel()
            panel.message = "Choose a project to open in Side"
            panel.prompt = "Open project"
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.beginSheetModal(for: window) { [weak self] response in
                guard let self, response == .OK, let url = panel.url else { return }
                self.closeAllTabsImmediately()
                self.loadProject(at: url)
            }
        }
    }

    /// Creates a brand-new project folder and `git init`s it, so it's never in the broken
    /// "opened a plain folder with no `.git`" state Tracks otherwise has to detect and recover
    /// from — new projects start correctly rather than needing a separate repair step.
    @objc func newProjectFromMenuAction() { newProject() }

    @objc private func newProject() {
        confirmAllUnsavedChanges { [weak self] proceed in
            guard let self, proceed, let window = self.view.window else { return }
            let panel = NSSavePanel()
            panel.message = "Name your new project"
            panel.prompt = "Create"
            panel.nameFieldStringValue = "New Project"
            panel.canCreateDirectories = true
            panel.beginSheetModal(for: window) { [weak self] response in
                guard let self, response == .OK, let url = panel.url else { return }
                do {
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                } catch {
                    self.showAlert(title: "Couldn't create project", message: error.localizedDescription, window: window)
                    return
                }
                let initResult = self.runGitInit(at: url)
                guard initResult.success else {
                    self.showAlert(title: "Couldn't initialize git", message: initResult.output, window: window)
                    return
                }
                self.closeAllTabsImmediately()
                self.loadProject(at: url)
            }
        }
    }

    private func runGitInit(at url: URL) -> (success: Bool, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "init"]
        process.currentDirectoryURL = url
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (false, error.localizedDescription)
        }
        // Read before waiting — waiting first deadlocks once the pipe buffer fills
        // (see GitPaths.runGit).
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (process.terminationStatus == 0, output)
    }

    /// Only ever reopens a file if this specific project has one remembered — no more
    /// guessing a "probably the main file" default by extension. A project with nothing
    /// remembered (first time opening it, or session storage cleared) just opens to an
    /// empty canvas; the file explorer/quick-open are one keystroke away regardless.
    /// Not private: `ShellViewController.openProject(at:focusingTrackKey:)` calls this directly
    /// to load a project into a freshly-created window — the same entry point "Open Project…"
    /// and session restore already go through, just invoked from outside this file.
    func loadProject(at url: URL) {
        projectURL = url
        LaunchSignposts.begin("retarget")
        retarget(to: url)
        LaunchSignposts.end("retarget")
        // A fresh project open starts at the shared per-project bucket; if this project has an
        // active track, ShellViewController sets the real key synchronously inside its
        // `onProjectOpened` callback below, before `reindexAndRestoreLastFile` reads it.
        currentTrackKey = nil
        emptyState.isHidden = true
        if !AppDelegate.isUITesting {
            UserDefaults.standard.set(url.path, forKey: lastProjectKey)
            rememberRecentProject(url)
        }
        LaunchSignposts.begin("projectOpened")
        onProjectOpened?(url)
        LaunchSignposts.end("projectOpened")
        LaunchSignposts.begin("reindexAndRestore")
        reindexAndRestoreLastFile()
        LaunchSignposts.end("reindexAndRestore")
    }

    /// Tears down and recreates `lspManager` pointed at `root`, and points every other
    /// file-touching operation (indexing, explorer, diff, formatter) at it too. Cheap to call —
    /// `LSPManager` only spawns servers lazily on first file open, so retargeting mid-session
    /// (a track switch landing on a different worktree) does no real work until a file is opened.
    private func retarget(to root: URL) {
        lspManager?.prepareForClose()
        let manager = LSPManager(projectRoot: root)
        manager.onDiagnostics = { [weak self] fileURL, diagnostics in
            self?.applyDiagnostics(diagnostics, to: fileURL)
            // Also published for Heron's read_diagnostics tool: an agent that can read the
            // errors its own edit just caused closes the loop inside one turn, instead of
            // waiting for the user to notice and paste them back.
            self?.publishDiagnosticsForAgent(diagnostics, fileURL: fileURL, root: root)
        }
        manager.onAvailabilityChanged = { [weak self] in self?.updateLSPIndicator() }
        lspManager = manager
        focusedRoot = root
        explorer.setRoot(root)
        searchField.placeholderString = "Indexing \(root.lastPathComponent)…"
        projectWatcher = ProjectWatcher(root: root) { [weak self] urls in self?.filesChangedOnDisk(urls) }
    }

    // MARK: - External changes (audit H8)

    /// Every FSEvents batch under the focused root lands here. Open tabs are checked against the
    /// stamp they were loaded or saved with; anything else means the file list may have changed.
    private func filesChangedOnDisk(_ urls: [URL]) {
        explorer.filesChanged(urls)
        let changed = Set(urls.map(\.path))
        for index in openTabs.indices where changed.contains(openTabs[index].url.path) {
            reconcileTabWithDisk(index)
        }
        scheduleReindex()
    }

    /// Clean tab: reload silently — the user asked for nothing and is now looking at the truth.
    /// Dirty tab: never overwrite their work; mark it and say so, and let them choose. A file
    /// that vanished is left alone: saving it is the moment to ask about recreating.
    private func reconcileTabWithDisk(_ index: Int) {
        guard openTabs.indices.contains(index) else { return }
        let tab = openTabs[index]
        guard tab.kind == .text, !tab.isUntitled, !tab.isSaving else { return }
        guard let onDisk = modificationDate(of: tab.url) else { return }
        if let known = tab.knownModificationDate, onDisk <= known { return }
        if tab.dirty {
            openTabs[index].hasExternalChange = true
            if activeTabIndex == index { showExternalChangeBanner(for: tab.url) }
        } else {
            reloadTabFromDisk(index)
        }
    }

    /// Replaces the buffer with the file's current bytes, keeping the caret where it was when
    /// that still makes sense. Shared by external-change reload and Revert to Saved.
    @discardableResult
    private func reloadTabFromDisk(_ index: Int) -> Bool {
        guard openTabs.indices.contains(index) else { return false }
        let tab = openTabs[index]
        guard let data = try? Data(contentsOf: tab.url), let decoded = TextFileCodec.decode(data) else { return false }
        let isActive = activeTabIndex == index
        let selection = isActive ? editor.selectedRange : tab.lastSelectedRange
        isLoadingTab = true
        tab.document.replaceAll(with: decoded.text)
        tab.document.highlight(url: tab.url, appearance: Self.editorAppearance)
        DispatchQueue.main.async { [weak self] in self?.isLoadingTab = false }
        tab.undoManager.removeAllActions()
        openTabs[index].format = decoded.format
        openTabs[index].savedStamp = ContentStamp(decoded.text)
        openTabs[index].dirty = false
        openTabs[index].hasExternalChange = false
        openTabs[index].knownModificationDate = modificationDate(of: tab.url)
        if isActive {
            dirty = false
            let clamped = NSRange(location: min(selection.location, tab.document.length), length: 0)
            editor.selectedRange = clamped
            externalChangeBanner.isHidden = true
            editor.invalidateGutter()
            refreshGitDiffMarks()
        }
        lspManager?.changed(url: tab.url, content: decoded.text)
        rebuildTabBar()
        return true
    }

    /// Focus-in sweep — the cheap backstop the audit asked for, in case a stream was lost.
    private func reconcileAllTabsWithDisk() {
        for index in openTabs.indices { reconcileTabWithDisk(index) }
    }

    private func scheduleReindex() {
        pendingReindex?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.refreshFileTreeAndReindex() }
        pendingReindex = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: item)
    }

    private func configureExternalChangeBanner() {
        externalChangeBanner.wantsLayer = true
        externalChangeBanner.bindLayerBackground(DS.Color.overlay)
        externalChangeBanner.translatesAutoresizingMaskIntoConstraints = false
        externalChangeBanner.isHidden = true
        externalChangeLabel.font = DS.Text.caption()
        externalChangeLabel.textColor = .secondaryLabelColor
        externalChangeLabel.lineBreakMode = .byTruncatingMiddle
        let reload = NSButton(title: "Reload", target: self, action: #selector(reloadExternallyChangedTab))
        let keep = NSButton(title: "Keep Mine", target: self, action: #selector(keepEditsOverExternalChange))
        for button in [reload, keep] { button.bezelStyle = .rounded; button.controlSize = .small; button.font = DS.Text.caption() }
        let row = NSStackView(views: [DS.StatusDot(state: .needsYou), externalChangeLabel, NSView(), reload, keep])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = DS.Spacing.s
        row.edgeInsets = NSEdgeInsets(top: 0, left: DS.Spacing.m, bottom: 0, right: DS.Spacing.m)
        row.translatesAutoresizingMaskIntoConstraints = false
        externalChangeBanner.addSubview(row)
        view.addSubview(externalChangeBanner)
        NSLayoutConstraint.activate([
            externalChangeBanner.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            externalChangeBanner.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            externalChangeBanner.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            externalChangeBanner.heightAnchor.constraint(equalToConstant: 28),
            row.leadingAnchor.constraint(equalTo: externalChangeBanner.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: externalChangeBanner.trailingAnchor),
            row.topAnchor.constraint(equalTo: externalChangeBanner.topAnchor),
            row.bottomAnchor.constraint(equalTo: externalChangeBanner.bottomAnchor),
        ])
    }

    private func showExternalChangeBanner(for url: URL) {
        externalChangeLabel.stringValue = "\(url.lastPathComponent) changed on disk while you have unsaved edits."
        externalChangeBanner.isHidden = false
        NSAccessibility.post(element: externalChangeBanner, notification: .announcementRequested, userInfo: [.announcement: externalChangeLabel.stringValue, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    @objc private func reloadExternallyChangedTab() {
        guard let index = activeTabIndex else { return }
        reloadTabFromDisk(index)
    }

    @objc private func keepEditsOverExternalChange() {
        guard let index = activeTabIndex else { return }
        openTabs[index].hasExternalChange = false
        externalChangeBanner.isHidden = true
    }

    private func publishDiagnosticsForAgent(_ diagnostics: [LSPDiagnostic], fileURL: URL, root: URL) {
        let rootPath = root.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else { return }
        let relative = String(filePath.dropFirst(rootPath.count + 1))
        // Hints and information are noise for an agent deciding whether its edit was sound.
        let entries = diagnostics.compactMap { diagnostic -> DiagnosticsSnapshot.Entry? in
            let severity: String
            switch diagnostic.severity {
            case .error: severity = "error"
            case .warning: severity = "warning"
            default: return nil
            }
            return DiagnosticsSnapshot.Entry(
                relativePath: relative,
                line: diagnostic.range.start.line + 1,  // LSP is 0-based; humans and the agent aren't
                severity: severity,
                message: diagnostic.message,
                source: diagnostic.source
            )
        }
        DiagnosticsSnapshot.shared.publish(entries, forFile: relative, projectRoot: root)
    }

    /// Re-scans the focused root's files and reopens whatever's remembered for
    /// `(projectURL, currentTrackKey)` (or reveals the file explorer if nothing is). Shared by
    /// opening a project for the first time and by switching tracks mid-session, since both need
    /// the file list refreshed — branches (or worktrees) can differ in which files even exist —
    /// before deciding what to reopen.
    private func reindexAndRestoreLastFile() {
        guard let root = focusedRoot, let memoryRoot = projectURL else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let indexed = Self.indexFiles(at: root)
            DispatchQueue.main.async {
                guard let self, self.focusedRoot == root else { return }
                self.allFiles = indexed
                self.searchField.placeholderString = "Find a file in \(root.lastPathComponent)"
                // Every remembered tab, in order, filtered against what the index actually
                // found — a branch switch or a deletion can legitimately remove a file, and a
                // missing one should be dropped silently rather than reported.
                if let sole = self.soleFile {
                    self.open(sole)
                    return
                }
                let indexedPaths = Set(indexed.map(\.url.path))
                let remembered = self.rememberedOpenTabs(forProject: memoryRoot)
                    .filter { indexedPaths.contains($0.path) }
                if !remembered.isEmpty {
                    // Opened in the remembered order, so the tab strip comes back arranged the
                    // way the user left it. Selection is applied afterwards by *switching* to
                    // the tab rather than opening it last — opening it last would restore the
                    // right selection at the cost of silently reordering their tabs.
                    self.isRestoringTabs = true
                    for url in remembered { self.open(url) }
                    self.isRestoringTabs = false
                    if let active = self.lastFile(forProject: memoryRoot),
                       let position = self.openTabs.firstIndex(where: { $0.url.path == active.path }) {
                        self.switchToTab(position)
                    }
                    // Written once, at the end: the per-open saves are suppressed above so a
                    // crash mid-restore can't persist a half-restored tab set over the real one.
                    self.rememberOpenTabs(forProject: memoryRoot)
                } else {
                    // No remembered file for this project/track — a fully blank canvas isn't a
                    // good first impression. Surface the file tree instead so there's immediately
                    // something to act on, rather than guessing which file to auto-open.
                    self.toggleFileExplorer()
                }
            }
        }
    }

    /// Called after a successful track switch. The previous track's open tabs hold in-memory
    /// content for a branch that's no longer checked out — reopening them as-is would show stale
    /// content instead of the new branch's version (or a file that doesn't exist on it at all) —
    /// so they're closed outright rather than left open, then the new track's own remembered file
    /// (if any) is restored.
    func reloadForTrackSwitch(trackKey: String?, workingDirectory: URL) {
        closeAllTabsImmediately()
        currentTrackKey = trackKey
        retarget(to: workingDirectory)
        reindexAndRestoreLastFile()
    }

    private static let maxIndexedFiles = 25000

    /// Walking/ignore rules live in ProjectFileAccess so Heron's read tools see exactly the
    /// same file set quick-open does.
    nonisolated private static func indexFiles(at root: URL) -> [IndexedFile] {
        ProjectFileAccess.scan(root: root).map { IndexedFile(url: $0.url, relativePath: $0.relativePath) }
    }

    // MARK: - Tabs

    /// Alloy's budgets are set on a 20 MB file (SIDE_RFC_ALLOY.md); past this, a file is a log to
    /// search, not text to edit.
    static let maxOpenableFileSize = 50_000_000
    private static let maxOpenableImageSize = 50_000_000
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "heic", "webp"]

    private func open(_ url: URL, completion: (() -> Void)? = nil) {
        // Captured now: `isRestoringTabs` is true only for the synchronous span of the restore
        // loop, and the work below finishes on a later main-queue turn.
        let deferLanguageServer = isRestoringTabs
        // Tab identity is raw URL equality everywhere downstream — canonicalize here, at the one
        // entry point, so the same file reached through two spellings of its path (a symlinked
        // segment, a lingering `..`) can't open as two duplicate tabs.
        let url = url.standardizedFileURL.resolvingSymlinksInPath()
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
                        self?.showAlert(title: "Image too large", message: "\(url.lastPathComponent) is \(size / 1_000_000) MB, over Side's current 50 MB limit.", window: window)
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
                    // Same append-time duplicate re-check as the text path below.
                    if let existingIndex = self.openTabs.firstIndex(where: { $0.url == url }) {
                        self.activeTabIndex = existingIndex
                        self.loadActiveTabIntoEditor()
                        self.finishOpenUI(url: url)
                        completion?()
                        return
                    }
                    var tab = OpenTab(url: url, kind: .image, document: self.editor.makeDocument(""), undoManager: Self.makeUndoManager(), dirty: false, isUntitled: false, knownModificationDate: nil)
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
                    self?.showAlert(title: "File too large", message: "\(url.lastPathComponent) is \(size / 1_000_000) MB, over the \(Self.maxOpenableFileSize / 1_000_000) MB Side opens in the editor.", window: window)
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
            guard let decoded = TextFileCodec.decode(data) else {
                DispatchQueue.main.async {
                    self?.showAlert(title: "Can't open this file", message: "\(url.lastPathComponent) doesn't appear to be a text file Side can edit.", window: window)
                    completion?()
                }
                return
            }
            let source = decoded.text
            let modDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let isCSV = ext == "csv"
            let rows = isCSV ? CSVParser.parse(source) : []
            // Whole-file work, here rather than on the main thread.
            let savedStamp = ContentStamp(source)
            DispatchQueue.main.async {
                guard let self else { completion?(); return }
                // Re-check now that we're back on main: two near-simultaneous opens of the same
                // file (e.g. two launch-time restore paths) both pass the synchronous duplicate
                // check up top, then both land here after their background loads — the second
                // must adopt the first's tab, not append a twin.
                if let existingIndex = self.openTabs.firstIndex(where: { $0.url == url }) {
                    self.activeTabIndex = existingIndex
                    self.loadActiveTabIntoEditor()
                    self.finishOpenUI(url: url)
                    completion?()
                    return
                }
                var tab = OpenTab(url: url, kind: isCSV ? .csv : .text, document: self.editor.makeDocument(source), undoManager: Self.makeUndoManager(), dirty: false, isUntitled: false, knownModificationDate: modDate)
                tab.csvRows = rows
                tab.format = decoded.format
                tab.savedStamp = savedStamp
                self.openTabs.append(tab)
                self.activeTabIndex = self.openTabs.count - 1
                self.loadActiveTabIntoEditor()
                self.finishOpenUI(url: url)
                if tab.kind == .text {
                    if deferLanguageServer {
                        self.deferLanguageServerOpen(url)
                    } else {
                        self.lspManager?.opened(url: url, content: source)
                    }
                }
                completion?()
            }
        }
    }

    /// Restored tabs announce themselves to the language server half a second late.
    ///
    /// Opening a `.ts` tab at launch resolved typescript-language-server through `$SHELL -lic`
    /// — a login shell sourcing the user's whole profile — during the very window the first
    /// frame was being built. Off-main, but it is a process spawn competing for the CPU at the
    /// one moment that decides whether launch reads as a half bounce or a full one. Nothing the
    /// user can see needs diagnostics in the first half second; the editor does.
    private var deferredLanguageServerOpens: [URL] = []
    private var deferredLanguageServerFlushScheduled = false

    private func deferLanguageServerOpen(_ url: URL) {
        deferredLanguageServerOpens.append(url)
        guard !deferredLanguageServerFlushScheduled else { return }
        deferredLanguageServerFlushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.deferredLanguageServerFlushScheduled = false
            let urls = self.deferredLanguageServerOpens
            self.deferredLanguageServerOpens.removeAll()
            for url in urls {
                guard let tab = self.openTabs.first(where: { $0.url == url }), tab.kind == .text else { continue }
                self.lspManager?.opened(url: url, content: tab.document.string)
            }
        }
    }

    private func finishOpenUI(url: URL) {
        if paletteIsOpen { searchField.stringValue = "" }
        if let projectURL { rememberLastFile(url, forProject: projectURL) }
        hideQuickOpenPanel()
        editor.focus()
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
        openTabs[index].lastSelectedRange = editor.selectedRange
    }

    private func loadActiveTabIntoEditor() {
        guard let index = activeTabIndex, openTabs.indices.contains(index) else { return }
        let tab = openTabs[index]
        hideCompletionPanel()
        if tab.hasExternalChange { showExternalChangeBanner(for: tab.url) } else { externalChangeBanner.isHidden = true }

        let showingMarkdownPreview = tab.kind == .text && tab.isPreviewingMarkdown
        editorContainer.isHidden = tab.kind != .text || showingMarkdownPreview
        gutter.isHidden = tab.kind != .text || showingMarkdownPreview
        imageScroll.isHidden = tab.kind != .image
        csvScroll.isHidden = tab.kind != .csv
        markdownPreviewScroll.isHidden = !showingMarkdownPreview

        switch tab.kind {
        case .text:
            // Guards against textDidChange firing (synchronously or via a same-turn queued
            // notification) as a side effect of this programmatic swap and spuriously marking
            // an untouched, freshly opened file as dirty. Cleared on the *next* runloop turn
            // rather than immediately, so it still covers a notification queued this turn.
            isLoadingTab = true
            tab.document.highlight(url: tab.url, appearance: Self.editorAppearance)
            editor.attach(tab.document, undoManager: tab.undoManager)
            DispatchQueue.main.async { [weak self] in self?.isLoadingTab = false }
            editor.isEditable = true
            let clampedLocation = min(tab.lastSelectedRange.location, tab.document.length)
            let restoredRange = NSRange(location: clampedLocation, length: 0)
            editor.selectedRange = restoredRange
            editor.scrollRangeToVisible(restoredRange)
            editor.invalidateGutter()
            refreshGitDiffMarks()
            renderDiagnosticsForActiveTab()
            if showingMarkdownPreview { renderMarkdownPreview(for: tab) }
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
        updateLSPIndicator()
        onFileOpened?(tab.url)
    }

    /// The editor text size changed in Appearance: every open text tab re-renders at it now,
    /// not only files opened afterwards.
    @objc private func editorTextSizeChanged() {
        for tab in openTabs where tab.kind == .text {
            tab.document.highlight(url: tab.url, appearance: Self.editorAppearance)
        }
        editor.appearance = Self.editorAppearance
        restyleMarkdownPreview()
    }

    /// The active file's language server as a caption and a dot: ready, starting (the working
    /// ring), stopped, or not installed — the last one clickable to install. Hidden for files
    /// with no server, and for a missing server the user can't install from here (sourcekit-lsp).
    private func updateLSPIndicator() {
        guard let index = activeTabIndex, openTabs.indices.contains(index), openTabs[index].kind == .text,
              let entry = LanguageServerRegistry.entry(forExtension: openTabs[index].url.pathExtension),
              let state = lspManager?.serverState(forExtension: openTabs[index].url.pathExtension), state != .none,
              state != .unavailable || entry.installFormula != nil else {
            lspStatusButton.isHidden = true
            return
        }
        let language = LSPStatusChip.languageName(entry.languageId)
        switch state {
        case .running: lspStatusButton.set(state: .verified, text: language, clickable: false, tip: "\(language) language server running")
        case .starting: lspStatusButton.set(state: .working, text: "\(language) \u{00B7} starting", clickable: false, tip: "Starting the \(language) language server")
        case .stopped: lspStatusButton.set(state: .failed, text: "\(language) \u{00B7} stopped", clickable: false, tip: "The \(language) language server stopped \u{2014} it restarts on the next edit")
        case .unavailable: lspStatusButton.set(state: .needsYou, text: "\(language) \u{00B7} not installed", clickable: true, tip: "\(language) language server not installed \u{2014} click to install")
        case .none: break
        }
        lspStatusButton.isHidden = false
    }

    @objc private func showLSPStatusPopover() {
        guard let index = activeTabIndex, openTabs.indices.contains(index),
              let entry = LanguageServerRegistry.entry(forExtension: openTabs[index].url.pathExtension) else { return }
        let tabURL = openTabs[index].url
        let content = LSPInstallPopoverViewController(entry: entry) { [weak self] in
            guard let self else { return }
            // Re-sends didOpen with the buffer's current in-memory content — this *is* the
            // activation, not just a cache clear, so there's nothing left for the user to do
            // (no need to actually close/reopen the tab) despite the file never having left
            // the editor.
            self.lspManager?.retryAfterInstall(binaryName: entry.binaryName)
            if let currentIndex = self.activeTabIndex, self.openTabs.indices.contains(currentIndex), self.openTabs[currentIndex].url == tabURL {
                self.lspManager?.opened(url: tabURL, content: self.openTabs[currentIndex].document.string)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in self?.lspInstallPopover?.close() }
        }
        let popover = NSPopover()
        popover.contentViewController = content
        popover.behavior = .transient
        lspInstallPopover = popover
        popover.show(relativeTo: lspStatusButton.bounds, of: lspStatusButton, preferredEdge: .maxY)
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

    // MARK: - Markdown preview

    @objc private func toggleMarkdownPreview() {
        guard let index = activeTabIndex, openTabs.indices.contains(index),
              openTabs[index].kind == .text, openTabs[index].url.pathExtension.lowercased() == "md" else { return }
        openTabs[index].isPreviewingMarkdown.toggle()
        loadActiveTabIntoEditor()
        // Focus goes to what's now showing. Hiding the focused editor left the window itself
        // focused, outside Make, so ⇧⌘V (resolved through the responder chain) did nothing
        // until a click.
        if openTabs[index].isPreviewingMarkdown {
            view.window?.makeFirstResponder(markdownPreviewView)
        } else {
            editor.focus()
        }
    }

    private func renderMarkdownPreview(for tab: OpenTab) {
        let text = tab.document.string
        let stamp = ContentStamp(text)
        if let shown = markdownPreviewShown, shown.tab == tab.id, shown.stamp == stamp, shown.generation == markdownPreviewGeneration { return }
        let dark = markdownPreviewView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let style = MarkdownPreview.Style.current(dark: dark)
        markdownPreviewView.columnWidth = style.columnWidth
        markdownPreviewView.textStorage?.setAttributedString(MarkdownPreview.render(text, style: style))
        markdownPreviewShown = (tab.id, stamp, markdownPreviewGeneration)
        // Code blocks in a language not built yet render plain; they color when it's ready.
        MarkdownPreview.prepareLanguages { [weak self] in self?.restyleMarkdownPreview() }
    }

    /// Fonts, sizes or light/dark changed: the preview renders again if it's showing.
    private func restyleMarkdownPreview() {
        markdownPreviewGeneration += 1
        guard let index = activeTabIndex, openTabs.indices.contains(index), openTabs[index].isPreviewingMarkdown else { return }
        renderMarkdownPreview(for: openTabs[index])
    }

    // MARK: - Diagnostics

    private func applyDiagnostics(_ diagnostics: [LSPDiagnostic], to url: URL) {
        guard let index = openTabs.firstIndex(where: { $0.url == url }) else { return }
        openTabs[index].diagnostics = diagnostics
        guard activeTabIndex == index else { return }
        renderDiagnosticsForActiveTab()
    }

    /// Clears/reapplies only the ranges diagnostics actually touched, not the whole document —
    /// this runs on every diagnostics update (i.e. roughly every debounced keystroke while a
    /// language server is attached), so on a large file a full-document attribute strip would
    /// force NSLayoutManager to invalidate layout well beyond what's visible on every edit.
    private func renderDiagnosticsForActiveTab() {
        guard let index = activeTabIndex, openTabs.indices.contains(index), openTabs[index].kind == .text else { return }
        let tab = openTabs[index]
        let ns = tab.document.text
        var lineSeverities: [Int: LSPDiagnosticSeverity] = [:]
        var marks: [(range: NSRange, color: NSColor)] = []
        for diagnostic in tab.diagnostics {
            let line = diagnostic.range.start.line + 1
            if let existing = lineSeverities[line] {
                if severityRank(diagnostic.severity) < severityRank(existing) { lineSeverities[line] = diagnostic.severity ?? existing }
            } else {
                lineSeverities[line] = diagnostic.severity ?? .information
            }
            guard let range = nsRange(for: diagnostic.range, in: ns), NSMaxRange(range) <= ns.length else { continue }
            let color: NSColor = diagnostic.severity == .error ? .systemRed : (diagnostic.severity == .warning ? .systemYellow : .systemGray)
            marks.append((range, color))
        }
        // The document clears only what it last underlined (a full strip would re-lay-out the
        // whole file on every keystroke).
        tab.document.setDecorations(.diagnostic, marks)
        editor.lineDiagnostics = lineSeverities
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
        guard let index = activeTabIndex else { return }
        performJumpToDefinition(at: editor.selectedRange.location, tabIndex: index)
    }

    private func performJumpToDefinition(at characterIndex: Int, tabIndex: Int) {
        guard openTabs.indices.contains(tabIndex), openTabs[tabIndex].kind == .text, let lspManager else { return }
        let tab = openTabs[tabIndex]
        let ns = tab.document.text
        let position = lspPosition(for: characterIndex, in: ns)
        lspManager.definition(url: tab.url, position: position) { [weak self] locations in
            guard let self, let target = locations.first, let targetURL = URL(string: target.uri) else { return }
            self.open(targetURL) { [weak self] in
                guard let self, let targetIndex = self.openTabs.firstIndex(where: { $0.url == targetURL }), self.openTabs[targetIndex].kind == .text else { return }
                let targetNS = self.openTabs[targetIndex].document.text
                guard let targetRange = self.nsRange(for: target.range, in: targetNS) else { return }
                self.editor.selectedRange = NSRange(location: targetRange.location, length: 0)
                self.editor.scrollRangeToVisible(targetRange)
                self.editor.focus()
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

    // MARK: - Inline instruct (§5.3)

    /// ⌘K: the selected lines — or the line under the caret when a diagnostic is there — become a
    /// pointer, and a small popover at the selection asks what to do with them.
    @objc func instructAtSelection() {
        guard let index = activeTabIndex, openTabs.indices.contains(index), openTabs[index].kind == .text,
              !openTabs[index].isUntitled else { NSSound.beep(); return }
        let tab = openTabs[index]
        let text = tab.document.text
        let selection = editor.selectedRange
        let startLine = text.substring(to: selection.location).components(separatedBy: "\n").count
        var endLine = text.substring(to: NSMaxRange(selection)).components(separatedBy: "\n").count
        // A selection ending just after a newline doesn't reach into the next line.
        if selection.length > 0, NSMaxRange(selection) > 0, text.character(at: NSMaxRange(selection) - 1) == 10 { endLine = max(startLine, endLine - 1) }
        let diagnostic = tab.diagnostics.first { $0.range.start.line + 1 == startLine }?.message
        guard selection.length > 0 || diagnostic != nil else { NSSound.beep(); return }
        let relative = relativePath(tab.url)
        let lines = startLine...max(startLine, endLine)
        dismissInstructSurfaces()

        let controller = InstructPopoverController(pointer: FileMention.pointer(relativePath: relative, lines: lines))
        controller.onSubmit = { [weak self] verb, instruction in
            self?.onInstruct?(InlineInstruct.Request(verb: verb, instruction: instruction, url: tab.url, relativePath: relative, lines: lines, diagnostic: diagnostic))
        }
        controller.onContinueInThink = { [weak self] in
            self?.dismissInstructSurfaces()
            self?.onOpenThinkRequested?()
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        instructPopover = popover
        instructController = controller
        popover.show(relativeTo: rect(forCharacterRange: selection.length > 0 ? selection : NSRange(location: selection.location, length: 0)), of: editor.textView, preferredEdge: .maxY)
    }

    /// Where a range sits in the editor's own coordinates — the popover's anchor.
    private func rect(forCharacterRange range: NSRange) -> NSRect { editor.rect(forCharacterRange: range) }

    func instructWaiting() { instructController?.showWaiting() }
    func instructAnswer(_ text: String) { instructController?.showAnswer(text) }
    func instructProblem(_ text: String) { instructController?.showProblem(text) }
    /// Change was sent: the popover's job is done; the proposal comes back as a card.
    func instructSent() {
        instructPopover?.close()
        instructPopover = nil
        instructController = nil
    }

    /// The proposal Think is showing, as a compact card beside its lines. Lives in the editor so
    /// it scrolls with the text.
    func showInstructProposal(id: UUID, url: URL, line: Int, added: Int, removed: Int,
                              apply: @escaping () -> Void, reject: @escaping () -> Void) {
        guard let index = activeTabIndex, openTabs.indices.contains(index), openTabs[index].url.standardizedFileURL == url.standardizedFileURL else { return }
        guard instructCard?.proposalId != id else { return }
        instructCard?.removeFromSuperview()
        let card = InstructProposalCard(proposalId: id, added: added, removed: removed)
        card.onApply = { [weak self] in apply(); self?.dismissInstructCard() }
        card.onReject = { [weak self] in reject(); self?.dismissInstructCard() }
        card.onOpenInThink = { [weak self] in self?.onOpenThinkRequested?() }
        let text = openTabs[index].document.text
        var location = 0
        for _ in 1..<max(1, line) {
            let next = text.range(of: "\n", range: NSRange(location: location, length: text.length - location))
            guard next.location != NSNotFound else { break }
            location = NSMaxRange(next)
        }
        let lineRect = rect(forCharacterRange: NSRange(location: min(location, text.length), length: 0))
        let size = card.fittingSize
        let width = max(size.width, 320)
        card.frame = NSRect(x: max(8, editor.visibleRect.maxX - width - 16), y: max(0, lineRect.minY - size.height - 4), width: width, height: size.height)
        card.autoresizingMask = [.minXMargin]
        editor.textView.addSubview(card)
        instructCard = card
    }

    func dismissInstructCard() {
        instructCard?.removeFromSuperview()
        instructCard = nil
    }

    /// Escape, a tab switch or a stage change: instruct surfaces never linger (§5 acceptance).
    func dismissInstructSurfaces() {
        instructPopover?.close()
        instructPopover = nil
        instructController = nil
        dismissInstructCard()
    }

    private func switchToTab(_ index: Int) {
        dismissInstructSurfaces()
        guard openTabs.indices.contains(index), index != activeTabIndex else { return }
        captureActiveTabSelection()
        activeTabIndex = index
        loadActiveTabIntoEditor()
        if let projectURL { rememberLastFile(openTabs[index].url, forProject: projectURL) }
        editor.focus()
    }

    @objc private func closeTabButton(_ sender: NSButton) { closeTab(at: sender.tag) }
    @objc private func closeTabFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let index = indexForTab(id: id) else { return }
        closeTab(at: index)
    }
    @objc private func closeActiveTab() { guard let index = activeTabIndex else { return }; closeTab(at: index) }

    /// Uses a stable tab id (not the raw index) beyond this point: closing this tab involves
    /// an async alert sheet, and another tab's own async save/formatter pipeline could shift
    /// array indices in the meantime, which would otherwise make a stale index silently
    /// resolve to the wrong tab.
    private func closeTab(at index: Int, completion: ((Bool) -> Void)? = nil) {
        guard openTabs.indices.contains(index) else { completion?(false); return }
        let tab = openTabs[index]
        let tabID = tab.id
        guard tab.dirty else {
            finishCloseTab(id: tabID)
            completion?(true)
            return
        }
        guard let window = view.window else { completion?(false); return }
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes you made to \u{201C}\(tab.isUntitled ? "Untitled" : tab.url.lastPathComponent)\u{201D}?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { completion?(false); return }
            switch response {
            case .alertFirstButtonReturn:
                self.performSave(tabID: tabID) { success in
                    if success { self.finishCloseTab(id: tabID) }
                    completion?(success)
                }
            case .alertSecondButtonReturn:
                self.finishCloseTab(id: tabID)
                completion?(true)
            default:
                completion?(false)
            }
        }
    }

    /// One at a time, front to back — a dirty tab in the batch gets its normal Save/Don't
    /// Save/Cancel sheet, and Cancel stops the whole batch (matching how every editor treats a
    /// bulk close as a sequence the user can bail out of).
    private func closeTabs(ids: [UUID]) {
        var remaining = ids
        guard let first = remaining.first else { return }
        remaining.removeFirst()
        guard let index = indexForTab(id: first) else { closeTabs(ids: remaining); return }
        closeTab(at: index) { [weak self] proceeded in
            if proceeded { self?.closeTabs(ids: remaining) }
        }
    }

    private func indexForTab(id: UUID) -> Int? { openTabs.firstIndex(where: { $0.id == id }) }

    private func finishCloseTab(id tabID: UUID) {
        guard let index = indexForTab(id: tabID) else { return }
        animateChipClosed(at: index) { [weak self] in
            guard let self, let index = self.indexForTab(id: tabID) else { return }
            let closedTab = self.openTabs[index]
            let wasActive = self.activeTabIndex == index
            if !wasActive { self.captureActiveTabSelection() }
            let next = TabSelection.indexAfterClosing(index, active: self.activeTabIndex, countBefore: self.openTabs.count)
            self.openTabs.remove(at: index)
            if closedTab.kind == .text { self.lspManager?.closed(url: closedTab.url) }
            if self.openTabs.isEmpty {
                self.closeAllTabsImmediately()
            } else {
                self.activeTabIndex = next
                // Only the tab you were on closing changes what the editor shows.
                if wasActive { self.loadActiveTabIntoEditor() }
                self.rebuildTabBar()
            }
        }
    }

    func closeAllTabsForTesting() { closeAllTabsImmediately() }

    private func closeAllTabsImmediately() {
        for tab in openTabs where tab.kind == .text { lspManager?.closed(url: tab.url) }
        openTabs.removeAll()
        activeTabIndex = nil
        isLoadingTab = true
        editor.attach(nil, undoManager: nil)
        DispatchQueue.main.async { [weak self] in self?.isLoadingTab = false }
        editor.isEditable = false
        editorContainer.isHidden = true
        gutter.isHidden = true
        editor.lineDiffMarks = [:]
        imageScroll.isHidden = true
        imageView.image = nil
        csvScroll.isHidden = true
        markdownPreviewScroll.isHidden = true
        dirty = false
        onFileOpened?(nil)
        rebuildTabBar()
        updateLSPIndicator()
    }

    /// Resolves every dirty tab (via Save/Don't Save/Cancel, one at a time) before allowing a
    /// caller to proceed with something that would otherwise discard them — closing the window,
    /// quitting, or switching projects.
    private func confirmAllUnsavedChanges(completion: @escaping (_ shouldProceed: Bool) -> Void) {
        let dirtyIDs = openTabs.filter { $0.dirty }.map { $0.id }
        guard !dirtyIDs.isEmpty, let window = view.window else { completion(true); return }

        func processNext(_ remaining: [UUID]) {
            var remaining = remaining
            guard let tabID = remaining.first else { completion(true); return }
            remaining.removeFirst()
            guard let index = self.indexForTab(id: tabID) else { processNext(remaining); return }
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
                    self.performSave(tabID: tabID) { success in
                        if success { processNext(remaining) } else { completion(false) }
                    }
                case .alertSecondButtonReturn:
                    processNext(remaining)
                default:
                    completion(false)
                }
            }
        }
        processNext(dirtyIDs)
    }

    var hasUnsavedChanges: Bool { openTabs.contains { $0.dirty } }
    func confirmCloseAllUnsaved(completion: @escaping (Bool) -> Void) { confirmAllUnsavedChanges(completion: completion) }

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
            context.duration = DS.Motion.duration(0.16)
            context.timingFunction = DS.Motion.curve
            context.allowsImplicitAnimation = true
            tabBarStack.layoutSubtreeIfNeeded()
        }
    }

    private func reindexTabChips() {
        for (i, chip) in tabChips.enumerated() {
            chip.index = i
            chip.isActive = (i == activeTabIndex)
            chip.closeButton?.tag = i
        }
    }

    private var lastKnownTabCount = 0

    /// Publishes the current chips as the tab bar's accessibility children. Required because the
    /// chips live inside the overflow `NSScrollView`, which otherwise hides them from the AX tree
    /// entirely — an audit found the chips absent despite `TabChipView`'s own AX overrides being
    /// correct, and adding the scroll view for tab overflow is what put them out of reach.
    private func publishTabAccessibility() {
        tabBar.accessibilityGroupLabel = "Editor tabs"
        tabBar.accessibleTabs = tabChips
    }

    /// UndoManager's default `levelsOfUndo` is 0, meaning *unlimited* — and every typing burst
    /// registers a group retaining the text it replaced, with nothing clearing the stack on
    /// save. Across a long session in many tabs that grows without bound. 200 levels is far
    /// more than anyone walks back by hand.
    private static func makeUndoManager() -> UndoManager {
        let manager = UndoManager()
        manager.levelsOfUndo = 200
        return manager
    }

    private func rebuildTabBar() {
        // The tab bar is rebuilt on every open, close, and reorder, which is exactly the set of
        // moments the remembered tab list should change — except during a restore, where the
        // intermediate states are not worth persisting over the complete set.
        if let projectURL, !isRestoringTabs { rememberOpenTabs(forProject: projectURL) }
        noFileLabel.isHidden = !openTabs.isEmpty || projectURL == nil
        let previousCount = lastKnownTabCount
        lastKnownTabCount = openTabs.count
        tabBarStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        tabChips.removeAll()
        // One file needs no tabs: a single tab is only a label with a close button that closes
        // the one thing you're looking at. The strip appears once there's a second.
        guard openTabs.count > 1 else { publishTabAccessibility(); return }
        for (index, tab) in openTabs.enumerated() {
            let chip = makeTabChip(index: index, tab: tab, isActive: index == activeTabIndex)
            tabBarStack.addArrangedSubview(chip)
            tabChips.append(chip)
        }
        publishTabAccessibility()
        // A freshly opened tab (always appended, always becomes active) arrives, not appears —
        // the standard entrance, scaled down for a 30pt element. Full rebuilds for any other
        // reason lay out instantly.
        if openTabs.count == previousCount + 1, let newest = tabChips.last {
            tabBarStack.layoutSubtreeIfNeeded()
            DS.Motion.appear(newest, distance: 8)
        }
    }

    /// The closing chip shrinks and fades out, its siblings gliding into the gap, before the
    /// model actually removes it — the counterpart to the arrival above.
    private func animateChipClosed(at index: Int, completion: @escaping () -> Void) {
        guard tabChips.indices.contains(index), openTabs.count > 2 else { completion(); return }
        let chip = tabChips[index]
        let width = chip.frame.width
        let widthConstraint = chip.widthAnchor.constraint(equalToConstant: width)
        widthConstraint.isActive = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = DS.Motion.duration(0.14)
            context.timingFunction = DS.Motion.curve
            context.allowsImplicitAnimation = true
            chip.animator().alphaValue = 0
            widthConstraint.constant = 0
            tabBarStack.layoutSubtreeIfNeeded()
        } completionHandler: {
            completion()
        }
    }

    private func makeTabChip(index: Int, tab: OpenTab, isActive: Bool) -> TabChipView {
        let container = TabChipView()
        container.index = index
        container.isActive = isActive
        container.title = tab.url.lastPathComponent
        container.isDirty = tab.dirty
        container.dragIcon = tab.isUntitled ? nil : NSWorkspace.shared.icon(forFile: tab.url.path)
        container.toolTip = tab.isUntitled ? "Unsaved" : relativePath(tab.url)
        container.translatesAutoresizingMaskIntoConstraints = false
        container.heightAnchor.constraint(equalToConstant: TabChipView.height).isActive = true
        container.onSelect = { [weak self] i in self?.switchToTab(i) }
        container.onDragging = { [weak self, weak container] windowX in
            guard let self, let container else { return }
            self.handleTabDragging(container, toWindowX: windowX)
        }
        container.onTearOut = { [weak self, weak container] screenPoint in
            guard let self, let container else { return }
            self.tearOutTab(at: container.index, to: screenPoint)
        }

        let closeButton = TabCloseButton()
        closeButton.tag = index
        closeButton.target = self
        closeButton.action = #selector(closeTabButton(_:))
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.isHidden = true
        container.addSubview(closeButton)
        container.closeButton = closeButton
        container.updateCloseVisibility()
        NSLayoutConstraint.activate([
            closeButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -(5 + TabChipView.flare)), closeButton.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])

        // Every item carries the tab's stable id, not its index — the menu can outlive several
        // reorders/closes between being built and being clicked.
        let menu = NSMenu()
        func item(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = tab.id
            return item
        }
        container.closeMenuItem = item("Close", #selector(closeTabFromMenu(_:)))
        item("Close Others", #selector(closeOtherTabsFromMenu(_:)))
        item("Close to the Right", #selector(closeTabsToRightFromMenu(_:)))
        item("Close Saved", #selector(closeSavedTabsFromMenu(_:)))
        item("Close All", #selector(closeAllTabsFromMenu(_:)))
        menu.addItem(NSMenuItem.separator())
        item("Copy Path", #selector(copyTabPathFromMenu(_:)))
        item("Copy Relative Path", #selector(copyTabRelativePathFromMenu(_:)))
        menu.addItem(NSMenuItem.separator())
        item("Reveal in Finder", #selector(revealTabInFinderFromMenu(_:)))
        menu.addItem(NSMenuItem.separator())
        item("Move to New Window", #selector(moveTabToNewWindowFromMenu(_:)))
        container.menu = menu

        return container
    }

    // MARK: - Tab context-menu actions (sender.representedObject is the tab's stable UUID)

    private func tabID(from sender: NSMenuItem) -> UUID? { sender.representedObject as? UUID }

    @objc private func closeOtherTabsFromMenu(_ sender: NSMenuItem) {
        guard let keep = tabID(from: sender) else { return }
        closeTabs(ids: openTabs.filter { $0.id != keep }.map(\.id))
    }

    @objc private func closeTabsToRightFromMenu(_ sender: NSMenuItem) {
        guard let id = tabID(from: sender), let index = indexForTab(id: id) else { return }
        closeTabs(ids: openTabs.suffix(from: index + 1).map(\.id))
    }

    @objc private func closeSavedTabsFromMenu(_ sender: NSMenuItem) {
        closeTabs(ids: openTabs.filter { !$0.dirty }.map(\.id))
    }

    @objc private func closeAllTabsFromMenu(_ sender: NSMenuItem) {
        closeTabs(ids: openTabs.map(\.id))
    }

    @objc private func copyTabPathFromMenu(_ sender: NSMenuItem) {
        guard let id = tabID(from: sender), let index = indexForTab(id: id) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(openTabs[index].url.path, forType: .string)
    }

    @objc private func copyTabRelativePathFromMenu(_ sender: NSMenuItem) {
        guard let id = tabID(from: sender), let index = indexForTab(id: id) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(relativePath(openTabs[index].url), forType: .string)
    }

    @objc private func revealTabInFinderFromMenu(_ sender: NSMenuItem) {
        guard let id = tabID(from: sender), let index = indexForTab(id: id) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([openTabs[index].url])
    }

    @objc private func moveTabToNewWindowFromMenu(_ sender: NSMenuItem) {
        guard let id = tabID(from: sender), let index = indexForTab(id: id) else { return }
        tearOutTab(at: index, to: NSEvent.mouseLocation)
    }

    /// The tear-out itself: close here (with the normal unsaved-changes sheet — a cancelled
    /// save cancels the move), then hand the file to a fresh window on the same project and
    /// track, positioned where the drop happened.
    private func tearOutTab(at index: Int, to screenPoint: NSPoint) {
        guard openTabs.indices.contains(index) else { return }
        let url = openTabs[index].url
        closeTab(at: index) { [weak self] proceeded in
            guard proceeded else { return }
            self?.onTearOutRequested?(url, screenPoint)
        }
    }

    private func relativePath(_ url: URL) -> String {
        guard let focusedRoot else { return url.path }
        return url.path.replacingOccurrences(of: focusedRoot.path + "/", with: "")
    }

    private var gitDiffGeneration = 0
    private func refreshGitDiffMarks() {
        guard let focusedRoot, let index = activeTabIndex, openTabs.indices.contains(index) else { return }
        let tab = openTabs[index]
        guard !tab.isUntitled, tab.kind == .text else {
            editor.lineDiffMarks = [:]
            currentDiffHunks = []
            currentDiffHeadContent = nil
            return
        }
        gitDiffGeneration += 1
        let generation = gitDiffGeneration
        let content = tab.document.string
        let relative = relativePath(tab.url)

        switch tab.headCache {
        case .fetched(let headContent):
            runDiff(headContent: headContent, content: content, projectRoot: focusedRoot, tabIndex: index, generation: generation)
        case .notFetched:
            // Re-found by *id*, not by the index captured at request time: closing a tab to the
            // left or dragging one while `git show` is in flight makes that index point at a
            // different file, and this cache is written once — so the wrong tab would show
            // fabricated diff marks permanently, and "Revert Change" would write another file's
            // lines into the buffer.
            let tabID = tab.id
            GitDiffComputer.fetchHeadContent(projectRoot: focusedRoot, relativePath: relative) { [weak self] headContent in
                guard let self, let current = self.indexForTab(id: tabID) else { return }
                self.openTabs[current].headCache = .fetched(headContent)
                guard self.gitDiffGeneration == generation, self.activeTabIndex == current else { return }
                self.runDiff(headContent: headContent, content: content, projectRoot: focusedRoot, tabIndex: current, generation: generation)
            }
        }
    }

    private func runDiff(headContent: String?, content: String, projectRoot: URL, tabIndex: Int, generation: Int) {
        GitDiffComputer.diff(headContent: headContent, currentContent: content, projectRoot: projectRoot) { [weak self] result in
            guard let self, self.gitDiffGeneration == generation, self.activeTabIndex == tabIndex else { return }
            self.editor.lineDiffMarks = result.marks
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
        guard editor.document === tab.document else { return }

        let originalLines = (currentDiffHeadContent ?? "").components(separatedBy: "\n")
        let replacementLines: [String]
        if hunk.oldCount > 0, hunk.oldStart - 1 + hunk.oldCount <= originalLines.count {
            replacementLines = Array(originalLines[(hunk.oldStart - 1)..<(hunk.oldStart - 1 + hunk.oldCount)])
        } else {
            replacementLines = []
        }
        let replacement = replacementLines.isEmpty ? "" : replacementLines.joined(separator: "\n") + "\n"

        let ns = tab.document.text
        let range: NSRange
        if hunk.newCount > 0 {
            range = lineSpanRange(in: ns, startLine: hunk.newStart, count: hunk.newCount)
        } else {
            let insertionPoint = lineSpanRange(in: ns, startLine: hunk.newStart, count: 0)
            range = NSRange(location: insertionPoint.location, length: 0)
        }

        editor.insertText(replacement, replacementRange: range)
        tab.document.highlight(url: tab.url, appearance: Self.editorAppearance)
        editor.invalidateGutter()
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
        if effectiveMode == .commands {
            performCommandSearch()
            return
        }
        if searchMode == .symbols {
            performSymbolSearch()
            return
        }
        if searchMode == .text {
            performTextSearch()
            return
        }
        guard projectURL != nil else { matches = []; applySearchResults(); return }
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

    /// Find in Project: the same search the agent's `search_files` runs, over the same live
    /// buffers, off the main thread with the same generation guard Quick Open uses so a stale
    /// result set can't land on top of a newer query.
    private func performTextSearch() {
        guard let root = focusedRoot else { textMatches = []; applySearchResults(); return }
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        searchGeneration += 1
        let generation = searchGeneration
        guard query.count >= 2 else {
            // One character matches nearly every line in the project; wait for a second.
            textMatches = []
            textSearchTruncated = false
            applySearchResults()
            return
        }
        // Snapshot the open buffers on main; the search runs elsewhere.
        let liveTexts: [URL: String] = Dictionary(uniqueKeysWithValues: openTabs.filter(\.dirty).map { ($0.url, $0.document.string) })
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var options = ProjectTextSearch.Options()
            options.limit = 200
            let results = (try? ProjectTextSearch.search(root: root, query: query, options: options, liveBuffer: { liveTexts[$0] }))
                ?? ProjectTextSearch.Results(matches: [], truncated: false)
            DispatchQueue.main.async {
                guard let self, self.searchGeneration == generation else { return }
                self.textMatches = results.matches
                self.textSearchTruncated = results.truncated
                self.applySearchResults()
            }
        }
    }

    private var resultCount: Int {
        switch effectiveMode {
        case .files: return matches.count
        case .symbols: return symbolMatches.count
        case .text: return textMatches.count
        case .commands: return commandMatches.count
        }
    }

    private func performCommandSearch() {
        let query = String(searchField.stringValue.dropFirst()).trimmingCharacters(in: .whitespaces)
        let all = commandsProvider?() ?? []
        commandMatches = query.isEmpty ? all : all.compactMap { command in
            FuzzyMatcher.score(query: query, candidate: command.title).map { (command, $0) }
        }.sorted { $0.1 > $1.1 }.map(\.0)
        applySearchResults()
    }

    private func performSymbolSearch() {
        guard let index = activeTabIndex, openTabs.indices.contains(index) else { symbolMatches = []; applySearchResults(); return }
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let tab = openTabs[index]
        let allSymbols = SymbolIndexer.symbols(in: tab.document.string, ext: tab.url.pathExtension.lowercased())
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
        let count = resultCount
        if count > 0 { resultsTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        // The palette stays open with no results — the field is part of it now.
        showQuickOpenPanel()
    }
    @objc private func confirmSearch() {
        let selected = resultsTable.selectedRow
        switch effectiveMode {
        case .commands:
            let command = (selected >= 0 && selected < commandMatches.count) ? commandMatches[selected] : commandMatches.first
            guard let command else { return }
            // Hidden without restoring focus — the command decides where focus goes.
            hideQuickOpenPanel()
            command.perform()
            return
        case .files:
            let url = (selected >= 0 && selected < matches.count) ? matches[selected] : matches.first
            guard let url else { return }
            onPaletteNavigated?()
            open(url)
        case .symbols:
            let symbol = (selected >= 0 && selected < symbolMatches.count) ? symbolMatches[selected] : symbolMatches.first
            guard let symbol else { return }
            hideQuickOpenPanel()
            onPaletteNavigated?()
            scrollToLine(symbol.line)
        case .text:
            let match = (selected >= 0 && selected < textMatches.count) ? textMatches[selected] : textMatches.first
            guard let match else { return }
            hideQuickOpenPanel()
            onPaletteNavigated?()
            revealFile(match.url, line: match.line)
        }
    }
    @objc private func openSelectedResult() { confirmSearch() }
    /// Escape: close and give focus back to whatever had it before the palette opened.
    private func dismissQuickOpen() {
        let target = paletteReturnResponder
        hideQuickOpenPanel()
        if let target, let window = searchField.window ?? view.window, (target as? NSView)?.window === window {
            window.makeFirstResponder(target)
        } else if view.window != nil {
            editor.focus()
        }
    }
    private func moveSelection(_ direction: Int) {
        let count = resultCount
        guard count > 0 else { return }
        let next = max(0, min(count - 1, resultsTable.selectedRow + direction))
        resultsTable.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        resultsTable.scrollRowToVisible(next)
    }
    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === resultsTable { return resultCount }
        if tableView === completionTable { return completionItems.count }
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
                text.font = DS.Text.body()
                text.lineBreakMode = .byTruncatingTail
                cell.addSubview(text)
                NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6), text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6), text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
            }
            text.stringValue = colIndex < rows[dataRow].count ? rows[dataRow][colIndex] : ""
            text.textColor = NSColor.labelColor
            return cell
        }

        if tableView === completionTable {
            guard row < completionItems.count else { return nil }
            let item = completionItems[row]
            let id = NSUserInterfaceItemIdentifier("completion")
            let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? NSTableCellView()
            cell.identifier = id
            let text = cell.textField ?? NSTextField(labelWithString: "")
            if cell.textField == nil {
                cell.textField = text
                text.translatesAutoresizingMaskIntoConstraints = false
                text.font = DS.Text.code(12, weight: .regular)
                text.lineBreakMode = .byTruncatingTail
                cell.addSubview(text)
                NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10), text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10), text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
            }
            if let detail = item.detail, !detail.isEmpty {
                let attributed = NSMutableAttributedString(string: item.label, attributes: [.foregroundColor: NSColor.labelColor])
                attributed.append(NSAttributedString(string: "  \(detail)", attributes: [.foregroundColor: NSColor.tertiaryLabelColor]))
                text.attributedStringValue = attributed
            } else {
                text.stringValue = item.label
                text.textColor = NSColor.labelColor
            }
            return cell
        }

        guard tableView === resultsTable else { return nil }
        let id = NSUserInterfaceItemIdentifier("paletteRow")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? PaletteCellView ?? PaletteCellView()
        cell.identifier = id
        switch effectiveMode {
        case .commands:
            let command = commandMatches[row]
            cell.configure(icon: Self.paletteSymbol("command"), title: command.title, detail: nil, trailing: command.shortcut)
        case .files:
            let url = matches[row]
            let relative = relativePath(url)
            let folder = (relative as NSString).deletingLastPathComponent
            cell.configure(icon: NSWorkspace.shared.icon(forFile: url.path), title: url.lastPathComponent, detail: folder.isEmpty ? nil : folder, trailing: nil)
        case .symbols:
            let symbol = symbolMatches[row]
            cell.configure(icon: Self.paletteSymbol("function"), title: symbol.name, detail: "\(symbol.kind)", trailing: "line \(symbol.line)")
        case .text:
            let match = textMatches[row]
            cell.configure(icon: NSWorkspace.shared.icon(forFile: match.url.path), title: match.text, detail: nil, trailing: "\(match.relativePath):\(match.line)")
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        tableView === resultsTable ? PaletteRowView() : nil
    }

    private static func paletteSymbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === searchField else { return false }
        // IME: Return and Escape belong to the input method while a composition is open.
        if textView.hasMarkedText() { return false }
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
    private var isLoadingTab = false
    private var pendingDiffWorkItem: DispatchWorkItem?
    private var pendingLSPWorkItem: DispatchWorkItem?
    private func undoStateChanged(_ managerID: ObjectIdentifier?) {
        guard let managerID, let index = openTabs.firstIndex(where: { ObjectIdentifier($0.undoManager) == managerID }), openTabs[index].kind == .text else { return }
        let text = openTabs[index].document.string
        let matchesSaved = ContentStamp(text) == openTabs[index].savedStamp
        guard openTabs[index].dirty == matchesSaved else { return }
        openTabs[index].dirty = !matchesSaved
        if activeTabIndex == index { dirty = !matchesSaved }
        rebuildTabBar()
    }

    func editorTextDidChange(_ engine: EditorEngine) {
        guard !isLoadingTab else { return }
        dirty = true
        if let index = activeTabIndex, !openTabs[index].dirty {
            openTabs[index].dirty = true
            rebuildTabBar()  // the tab's unsaved dot
        }
        editor.invalidateGutter()
        scheduleDiffRefresh()
        scheduleLSPDidChange()
        scheduleCompletionRequest()
        suppressNextSelectionDismiss = true
    }

    private func scheduleLSPDidChange() {
        pendingLSPWorkItem?.cancel()
        guard let index = activeTabIndex, openTabs.indices.contains(index), openTabs[index].kind == .text, lspManager != nil else { return }
        let url = openTabs[index].url
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, let currentIndex = self.activeTabIndex, self.openTabs.indices.contains(currentIndex), self.openTabs[currentIndex].url == url else { return }
            self.lspManager?.changed(url: url, content: self.openTabs[currentIndex].document.string)
        }
        pendingLSPWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
    }

    // MARK: - Autocomplete

    private static let identifierCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))

    private func scheduleCompletionRequest() {
        pendingCompletionWorkItem?.cancel()
        guard let index = activeTabIndex, openTabs.indices.contains(index), openTabs[index].kind == .text,
              lspManager != nil, LanguageServerRegistry.entry(forExtension: openTabs[index].url.pathExtension) != nil else {
            hideCompletionPanel()
            return
        }
        let tabID = openTabs[index].id
        let cursor = editor.selectedRange.location
        completionGeneration += 1
        let generation = completionGeneration
        let workItem = DispatchWorkItem { [weak self] in
            self?.performCompletionRequest(tabID: tabID, cursor: cursor, generation: generation)
        }
        pendingCompletionWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
    }

    private func performCompletionRequest(tabID: UUID, cursor: Int, generation: Int) {
        guard let index = indexForTab(id: tabID), openTabs[index].kind == .text, let lspManager else { return }
        let tab = openTabs[index]
        let ns = tab.document.text
        guard cursor <= ns.length else { return }
        var start = cursor
        while start > 0, let scalar = UnicodeScalar(UInt32(ns.character(at: start - 1))), Self.identifierCharacters.contains(scalar) {
            start -= 1
        }
        completionReplacementRange = NSRange(location: start, length: cursor - start)
        let position = lspPosition(for: cursor, in: ns)
        lspManager.completion(url: tab.url, content: ns as String, position: position) { [weak self] items in
            guard let self, self.completionGeneration == generation,
                  let currentIndex = self.indexForTab(id: tabID), self.activeTabIndex == currentIndex else { return }
            guard !items.isEmpty else { self.hideCompletionPanel(); return }
            self.completionItems = items
            self.completionSelectedIndex = 0
            self.completionTable.reloadData()
            self.completionTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            self.showCompletionPanel()
        }
    }

    private func screenRectForCaret() -> NSRect? {
        editor.screenRect(forCharacterRange: NSRange(location: editor.selectedRange.location, length: 0))
    }

    private func showCompletionPanel() {
        guard let window = view.window, let caretRect = screenRectForCaret() else { return }
        let visibleRows = max(1, min(completionMaxVisibleRows, completionItems.count))
        let height = CGFloat(visibleRows) * completionRowHeight + 12
        let width: CGFloat = 320
        var x = caretRect.minX
        let windowFrame = window.frame
        if x + width > windowFrame.maxX - 12 { x = windowFrame.maxX - width - 12 }
        if x < windowFrame.minX + 12 { x = windowFrame.minX + 12 }
        let panelFrame = NSRect(x: x, y: caretRect.minY - height - 4, width: width, height: height)
        completionPanel.setFrame(panelFrame, display: true)
        if completionPanel.parent == nil {
            window.addChildWindow(completionPanel, ordered: .above)
        }
        completionPanel.orderFront(nil)
    }

    private func hideCompletionPanel() {
        pendingCompletionWorkItem?.cancel()
        completionItems = []
        guard completionPanel.isVisible || completionPanel.parent != nil else { return }
        view.window?.removeChildWindow(completionPanel)
        completionPanel.orderOut(nil)
    }

    private func acceptSelectedCompletion() {
        guard completionItems.indices.contains(completionSelectedIndex), let range = completionReplacementRange else {
            hideCompletionPanel()
            return
        }
        let item = completionItems[completionSelectedIndex]
        let text = item.insertText ?? item.label
        isAcceptingCompletion = true
        editor.insertText(text, replacementRange: range)
        editor.selectedRange = NSRange(location: range.location + (text as NSString).length, length: 0)
        isAcceptingCompletion = false
        hideCompletionPanel()
    }

    private func moveCompletionSelection(_ delta: Int) {
        guard !completionItems.isEmpty else { return }
        completionSelectedIndex = max(0, min(completionItems.count - 1, completionSelectedIndex + delta))
        completionTable.selectRowIndexes(IndexSet(integer: completionSelectedIndex), byExtendingSelection: false)
        completionTable.scrollRowToVisible(completionSelectedIndex)
    }

    // MARK: - Bracket matching

    private static let bracketPairs: [Character: Character] = ["(": ")", "[": "]", "{": "}"]
    private static let bracketPairsReversed: [Character: Character] = [")": "(", "]": "[", "}": "{"]
    private static let bracketHighlightColor = DS.Color.scrimMedium

    func editorSelectionDidChange(_ engine: EditorEngine) {
        updateBracketHighlight()
        editor.setNeedsDisplay()
        // Typing itself moves the selection, which fires this same delegate method within the
        // same call chain as textDidChange (before its just-scheduled completion request ever
        // gets to run) — only treat this as a real "user navigated away" dismissal signal when
        // it wasn't just a consequence of an edit or of accepting a completion.
        guard !isAcceptingCompletion, !suppressNextSelectionDismiss else {
            suppressNextSelectionDismiss = false
            return
        }
        hideCompletionPanel()
    }

    private func updateBracketHighlight() {
        guard let index = activeTabIndex, openTabs.indices.contains(index), openTabs[index].kind == .text else { return }
        let document = openTabs[index].document
        let selection = editor.selectedRange
        var matchRanges: [NSRange] = []
        if selection.length == 0 {
            let ns = document.text
            let location = selection.location
            if location < ns.length, let ch = character(in: ns, at: location), let close = Self.bracketPairs[ch],
               let matchLoc = findMatchingBracket(open: ch, close: close, from: location, forward: true, in: ns) {
                matchRanges = [NSRange(location: location, length: 1), NSRange(location: matchLoc, length: 1)]
            } else if location > 0, let ch = character(in: ns, at: location - 1), let open = Self.bracketPairsReversed[ch],
                      let matchLoc = findMatchingBracket(open: open, close: ch, from: location - 1, forward: false, in: ns) {
                matchRanges = [NSRange(location: location - 1, length: 1), NSRange(location: matchLoc, length: 1)]
            }
        }
        document.setDecorations(.bracketMatch, matchRanges.map { ($0, Self.bracketHighlightColor) })
    }

    private func character(in ns: NSString, at index: Int) -> Character? {
        guard let scalar = UnicodeScalar(UInt32(ns.character(at: index))) else { return nil }
        return Character(scalar)
    }

    /// Capped so an unmatched bracket in a huge or minified file can't turn every cursor move
    /// into an unbounded document-length scan — beyond this distance we just skip the highlight
    /// rather than searching all the way to the end/start of the file.
    private static let maxBracketScanDistance = 50_000

    private func findMatchingBracket(open: Character, close: Character, from location: Int, forward: Bool, in ns: NSString) -> Int? {
        guard let openUnit = String(open).utf16.first, let closeUnit = String(close).utf16.first else { return nil }
        var depth = 0
        if forward {
            var i = location
            let limit = min(ns.length, location + Self.maxBracketScanDistance)
            while i < limit {
                let c = ns.character(at: i)
                if c == openUnit { depth += 1 } else if c == closeUnit {
                    depth -= 1
                    if depth == 0 { return i }
                }
                i += 1
            }
        } else {
            var i = location
            let limit = max(0, location - Self.maxBracketScanDistance)
            while i >= limit {
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

    func editor(_ engine: EditorEngine, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard let replacementString, replacementString.count == 1, let char = replacementString.first else { return true }

        if Self.autoCloseClosers.contains(char), affectedCharRange.length == 0 {
            let ns = engine.document?.text ?? ""
            if affectedCharRange.location < ns.length, ns.character(at: affectedCharRange.location) == char.utf16.first {
                engine.selectedRange = NSRange(location: affectedCharRange.location + 1, length: 0)
                return false
            }
        }

        if let closing = Self.autoClosePairs[char], affectedCharRange.length == 0 {
            engine.insertText("\(char)\(closing)", replacementRange: affectedCharRange)
            engine.selectedRange = NSRange(location: affectedCharRange.location + 1, length: 0)
            return false
        }

        return true
    }

    func editor(_ engine: EditorEngine, doCommandBy commandSelector: Selector) -> Bool {
        if instructCard != nil, commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            dismissInstructCard()
            return true
        }
        if completionPanel.isVisible {
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                moveCompletionSelection(-1)
                return true
            case #selector(NSResponder.moveDown(_:)):
                moveCompletionSelection(1)
                return true
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
                acceptSelectedCompletion()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                hideCompletionPanel()
                return true
            default:
                break
            }
        }
        guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
        let ns = engine.document?.text ?? ""
        let selectedRange = engine.selectedRange
        let lineRange = ns.lineRange(for: NSRange(location: selectedRange.location, length: 0))
        let currentLine = ns.substring(with: NSRange(location: lineRange.location, length: selectedRange.location - lineRange.location))
        let leadingWhitespace = currentLine.prefix(while: { $0 == " " || $0 == "\t" })
        var indent = String(leadingWhitespace)
        if let last = currentLine.trimmingCharacters(in: .whitespaces).last, "{[(".contains(last) {
            indent += "    "
        }
        engine.insertText("\n" + indent, replacementRange: selectedRange)
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


    // Menu items below deliberately leave `target` unset (nil): AppKit dispatches nil-target
    // actions through the responder chain of whichever window is currently key, which is what
    // lets the same static menu bar correctly address multiple open project windows. The one
    // exception is "New Window," which routes to AppDelegate explicitly since it isn't a
    // per-window action.
    private func buildMenu() {
        let main = NSMenu(title: "Side")

        // The very first item's own title is cosmetic — AppKit always displays the running
        // app's actual name (from Info.plist) for it regardless — but it has to exist for
        // AppKit to treat this as the application menu at all. Without it there was no About
        // panel, no Preferences shortcut, no Hide, and critically no Quit — Cmd+Q had nothing
        // bound to it.
        let appItem = NSMenuItem(title: "Side", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "Side")
        appMenu.addItem(withTitle: "About Side", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let updates = appMenu.addItem(withTitle: "Check for Updates\u{2026}", action: #selector(Updates.checkForUpdates(_:)), keyEquivalent: "")
        updates.target = Updates.shared
        appMenu.addItem(NSMenuItem.separator())
        let preferences = appMenu.addItem(withTitle: "Preferences…", action: #selector(AppDelegate.showPreferences), keyEquivalent: ",")
        preferences.target = NSApp.delegate as? AppDelegate
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Hide Side", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit Side", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")
        let newWindowItem = fileMenu.addItem(withTitle: "New Window", action: #selector(AppDelegate.newWindow), keyEquivalent: "n")
        newWindowItem.keyEquivalentModifierMask = [.command, .shift]
        newWindowItem.target = NSApp.delegate as? AppDelegate
        fileMenu.addItem(withTitle: "New File", action: #selector(newFile), keyEquivalent: "n")
        // Explicitly targeted at the app delegate rather than left nil-target: as
        // responder-chain actions these went *disabled* whenever no editor held first responder,
        // which stranded anyone in the no-file state — the exact "Open Project was disabled"
        // dogfood failure. Opening a project is an app-level command, not an editor one.
        let newProjectItem = fileMenu.addItem(withTitle: "New Project…", action: #selector(AppDelegate.newProjectFromMenu), keyEquivalent: "")
        newProjectItem.target = NSApp.delegate as? AppDelegate
        let openProjectItem = fileMenu.addItem(withTitle: "Open Project…", action: #selector(AppDelegate.openProjectFromMenu), keyEquivalent: "o")
        openProjectItem.target = NSApp.delegate as? AppDelegate
        openRecentMenu.delegate = self
        let openRecentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        openRecentItem.submenu = openRecentMenu
        fileMenu.addItem(openRecentItem)
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
        // Direction 02 §5.3 — a Make action, so it's live only while Make is on screen.
        editMenu.addItem(withTitle: "Instruct…", action: #selector(instructAtSelection), keyEquivalent: "k")
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

        // What the user actually toggles about the *presentation* of the workspace, as its own
        // top-level menu — a markdown preview toggle buried in File read as a file operation.
        let viewItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        let viewMenu = NSMenu(title: "View")
        // ⇧⌘V, not ⌘M — ⌘M is the system's Minimize, which this used to shadow.
        let markdownPreview = viewMenu.addItem(withTitle: "Toggle Markdown Preview", action: #selector(toggleMarkdownPreview), keyEquivalent: "v")
        markdownPreview.keyEquivalentModifierMask = [.command, .shift]
        let explorer = viewMenu.addItem(withTitle: "Toggle File Explorer", action: #selector(toggleFileExplorer), keyEquivalent: "e")
        explorer.keyEquivalentModifierMask = [.command, .shift]
        viewItem.submenu = viewMenu

        let navigateItem = NSMenuItem(title: "Navigate", action: nil, keyEquivalent: "")
        let navigateMenu = NSMenu(title: "Navigate")
        // Palette items target the shell, which is always in the responder chain — as Make
        // actions they were disabled on every other stage.
        navigateMenu.addItem(withTitle: "Quick Open", action: #selector(ShellViewController.showQuickOpen(_:)), keyEquivalent: "p")
        let commandPalette = navigateMenu.addItem(withTitle: "Command Palette", action: #selector(ShellViewController.showCommandPalette(_:)), keyEquivalent: "p")
        commandPalette.keyEquivalentModifierMask = [.command, .shift]
        navigateMenu.addItem(withTitle: "Go to Line…", action: #selector(showGoToLine), keyEquivalent: "l")
        let goToSymbol = navigateMenu.addItem(withTitle: "Go to Symbol…", action: #selector(ShellViewController.showGoToSymbol(_:)), keyEquivalent: "o")
        let findInProject = NSMenuItem(title: "Find in Project…", action: #selector(ShellViewController.showFindInProject(_:)), keyEquivalent: "f")
        findInProject.keyEquivalentModifierMask = [.command, .shift]
        navigateMenu.addItem(findInProject)
        goToSymbol.keyEquivalentModifierMask = [.command, .shift]
        let jumpToDef = navigateMenu.addItem(withTitle: "Jump to Definition", action: #selector(jumpToDefinition), keyEquivalent: "j")
        jumpToDef.keyEquivalentModifierMask = [.command, .control]
        navigateMenu.addItem(NSMenuItem.separator())
        // Stage navigation — ⌘⌥1–4 for the four working stages, ⌘⌥0 for Tracks (Direction 02
        // §3.8). Every stage has an item whether or not it is pinned: unpinning never removes a
        // way in. ⌘1–⌘8 stay with tabs.
        for (index, stage) in ShellViewController.Stage.allCases.enumerated() {
            let key = stage == .tracks ? "0" : "\(StagePins.pinnable.firstIndex(of: stage).map { $0 + 1 } ?? index + 1)"
            let item = navigateMenu.addItem(withTitle: "Go to \(stage.rawValue)", action: #selector(ShellViewController.jumpToStage(_:)), keyEquivalent: key)
            item.keyEquivalentModifierMask = [.command, .option]
            item.tag = index
        }
        navigateMenu.addItem(NSMenuItem.separator())
        // Eight sibling items at the top level was clutter; the shortcuts still work from the
        // submenu — a keyEquivalent doesn't care how deeply its item is nested.
        let tabsItem = NSMenuItem(title: "Tabs", action: nil, keyEquivalent: "")
        let tabsMenu = NSMenu(title: "Tabs")
        for i in 1...8 {
            let item = tabsMenu.addItem(withTitle: "Switch to Tab \(i)", action: #selector(switchToTabShortcut(_:)), keyEquivalent: "\(i)")
            item.tag = i - 1
        }
        let lastTab = tabsMenu.addItem(withTitle: "Switch to Last Tab", action: #selector(switchToTabShortcut(_:)), keyEquivalent: "9")
        lastTab.tag = -1
        tabsMenu.addItem(NSMenuItem.separator())
        let nextTab = tabsMenu.addItem(withTitle: "Next Tab", action: #selector(ShellViewController.selectNextTab(_:)), keyEquivalent: "\t")
        nextTab.keyEquivalentModifierMask = [.control]
        let previousTab = tabsMenu.addItem(withTitle: "Previous Tab", action: #selector(ShellViewController.selectPreviousTab(_:)), keyEquivalent: "\t")
        previousTab.keyEquivalentModifierMask = [.control, .shift]
        tabsItem.submenu = tabsMenu
        navigateMenu.addItem(tabsItem)
        navigateItem.submenu = navigateMenu

        // Targets nothing here — RunWorkspaceViewController implements these selectors and
        // picks them up via the responder chain while the Run stage is active, same pattern
        // as "New Window" targeting AppDelegate directly above.
        let runItem = NSMenuItem(title: "Run", action: nil, keyEquivalent: "")
        let runMenu = NSMenu(title: "Run")
        runMenu.addItem(withTitle: "New Terminal Tab", action: #selector(RunWorkspaceViewController.newSession), keyEquivalent: "t")
        runMenu.addItem(withTitle: "Stop", action: #selector(RunWorkspaceViewController.stopActiveSession), keyEquivalent: ".")
        let restart = runMenu.addItem(withTitle: "Restart Terminal", action: #selector(RunWorkspaceViewController.restartActiveSession), keyEquivalent: "r")
        restart.keyEquivalentModifierMask = [.command, .shift]
        runMenu.addItem(withTitle: "Rerun Last Command", action: #selector(RunWorkspaceViewController.rerunLastCommand), keyEquivalent: "")
        runItem.submenu = runMenu

        // Same responder-chain pattern as Run above — TracksWorkspaceViewController picks this up
        // while the Tracks stage is active.
        let trackItem = NSMenuItem(title: "Track", action: nil, keyEquivalent: "")
        let trackMenu = NSMenu(title: "Track")
        let newTrack = trackMenu.addItem(withTitle: "New Track…", action: #selector(TracksWorkspaceViewController.newTrackTapped), keyEquivalent: "t")
        newTrack.keyEquivalentModifierMask = [.command, .shift]
        let trackPopover = trackMenu.addItem(withTitle: "Switch Track…", action: #selector(ShellViewController.toggleTrackPopover(_:)), keyEquivalent: "t")
        trackPopover.keyEquivalentModifierMask = [.command, .control]
        let stagesItem = NSMenuItem(title: "Pinned Stages", action: nil, keyEquivalent: "")
        let stagesMenu = NSMenu(title: "Pinned Stages")
        for stage in StagePins.pinnable {
            let item = stagesMenu.addItem(withTitle: stage.rawValue, action: #selector(ShellViewController.togglePinnedStage(_:)), keyEquivalent: "")
            item.representedObject = stage.rawValue
        }
        stagesItem.submenu = stagesMenu
        viewMenu.addItem(NSMenuItem.separator())
        viewMenu.addItem(stagesItem)
        trackItem.submenu = trackMenu

        // Standard macOS Window menu — AppKit populates the list of open windows (with
        // checkmarks/ordering) into this automatically once assigned to NSApp.windowsMenu,
        // on top of whatever's added here explicitly.
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(NSMenuItem.separator())
        // Library is a window, not a stage (RFC R6): app-level, so it targets the delegate.
        let library = windowMenu.addItem(withTitle: "Library", action: #selector(AppDelegate.showLibrary), keyEquivalent: "l")
        library.keyEquivalentModifierMask = [.command, .shift]
        library.target = NSApp.delegate as? AppDelegate
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu

        main.addItem(appItem); main.addItem(fileItem); main.addItem(editItem); main.addItem(viewItem); main.addItem(navigateItem); main.addItem(runItem); main.addItem(trackItem); main.addItem(windowItem)
        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
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
        let text = editor.document?.text ?? ""
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
        editor.selectedRange = cursorRange
        editor.focus()
    }
    @objc private func save() {
        guard let index = activeTabIndex else { return }
        performSave(tabID: openTabs[index].id) { _ in }
    }

    @objc private func saveAs() {
        guard let index = activeTabIndex else { return }
        performSaveAs(tabID: openTabs[index].id) { _ in }
    }

    @objc private func newFile() {
        captureActiveTabSelection()
        Self.untitledCounter += 1
        let name = "Untitled-\(Self.untitledCounter)"
        let url = URL(string: "side-untitled:///\(name)")!
        openTabs.append(OpenTab(url: url, kind: .text, document: editor.makeDocument(""), undoManager: Self.makeUndoManager(), dirty: false, isUntitled: true, knownModificationDate: nil))
        activeTabIndex = openTabs.count - 1
        loadActiveTabIntoEditor()
        editor.focus()
    }

    private static var untitledCounter = 0

    /// Resolves the whole save pipeline for a tab: routes untitled tabs to Save As,
    /// checks for out-of-band disk changes, writes, runs a formatter if configured, and
    /// reports success so callers (close/quit prompts) know whether it's safe to proceed.
    private func performSave(tabID: UUID, completion: @escaping (Bool) -> Void) {
        guard let index = indexForTab(id: tabID) else { completion(false); return }
        let tab = openTabs[index]
        guard tab.kind == .text else { completion(false); return }
        // Without this, pressing Cmd+S twice in quick succession (faster than the write +
        // formatter-subprocess round trip) could launch two overlapping writes against the same
        // path, one of them racing the other's formatter reading the file back from disk. The
        // second call while one's already in flight is just ignored rather than raced.
        guard !tab.isSaving else { completion(false); return }
        openTabs[index].isSaving = true
        let finish: (Bool) -> Void = { [weak self] success in
            if let self, let index = self.indexForTab(id: tabID) { self.openTabs[index].isSaving = false }
            completion(success)
        }
        if tab.isUntitled {
            performSaveAs(tabID: tabID, completion: finish)
            return
        }
        writeTabToDisk(tabID: tabID, url: tab.url, completion: finish)
    }

    private func performSaveAs(tabID: UUID, completion: @escaping (Bool) -> Void) {
        guard let index = indexForTab(id: tabID), let window = view.window else { completion(false); return }
        let panel = NSSavePanel()
        let currentName = openTabs[index].url.lastPathComponent
        panel.nameFieldStringValue = openTabs[index].isUntitled ? "\(currentName).txt" : currentName
        if let focusedRoot { panel.directoryURL = focusedRoot }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let newURL = panel.url else { completion(false); return }
            guard let index = self.indexForTab(id: tabID) else { completion(false); return }
            self.openTabs[index].url = newURL
            self.openTabs[index].isUntitled = false
            self.writeTabToDiskForced(tabID: tabID, url: newURL) { success in
                if success {
                    if let index = self.indexForTab(id: tabID), self.activeTabIndex == index {
                        if let projectURL = self.projectURL { self.rememberLastFile(newURL, forProject: projectURL) }
                        self.onFileOpened?(newURL)
                        self.openTabs[index].document.highlight(url: newURL, appearance: Self.editorAppearance)
                        self.editor.invalidateGutter()
                    }
                    self.rebuildTabBar()
                }
                completion(success)
            }
        }
    }

    private func writeTabToDisk(tabID: UUID, url: URL, completion: @escaping (Bool) -> Void) {
        guard let index = indexForTab(id: tabID), let window = view.window else { completion(false); return }
        let tab = openTabs[index]
        let onDiskModDate = modificationDate(of: url)
        // `modificationDate(of:)` returning nil while we have a known prior date doesn't mean
        // "unchanged, nothing to check" — it means the file is *gone*. That case used to fall
        // through the `onDisk > known` comparison entirely (nil isn't `> known`) straight to a
        // forced write, silently resurrecting a file the user (or a branch switch, or a script)
        // had deleted, with no indication anything unusual had happened.
        if tab.knownModificationDate != nil, onDiskModDate == nil {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "\u{201C}\(url.lastPathComponent)\u{201D} was deleted"
            alert.informativeText = "This file no longer exists on disk. Saving will recreate it with the contents currently open in Side."
            alert.addButton(withTitle: "Recreate")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self else { completion(false); return }
                if response == .alertFirstButtonReturn {
                    self.writeTabToDiskForced(tabID: tabID, url: url, completion: completion)
                } else {
                    completion(false)
                }
            }
            return
        }
        if let known = tab.knownModificationDate, let onDisk = onDiskModDate, onDisk > known {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "\u{201C}\(url.lastPathComponent)\u{201D} has changed on disk"
            alert.informativeText = "This file was modified outside Side since you opened it. Overwriting will discard those external changes."
            alert.addButton(withTitle: "Overwrite")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self else { completion(false); return }
                if response == .alertFirstButtonReturn {
                    self.writeTabToDiskForced(tabID: tabID, url: url, completion: completion)
                } else {
                    completion(false)
                }
            }
            return
        }
        writeTabToDiskForced(tabID: tabID, url: url, completion: completion)
    }

    private func writeTabToDiskForced(tabID: UUID, url: URL, completion: @escaping (Bool) -> Void) {
        guard let index = indexForTab(id: tabID) else { completion(false); return }
        let content = openTabs[index].document.string
        let format = openTabs[index].format
        do {
            // The file's own encoding, BOM and line ending — bytes the user didn't touch stay
            // as they were. A character the encoding can't hold is a refusal, not a transcode.
            guard let data = TextFileCodec.encode(content, as: format) else {
                throw CocoaError(.fileWriteInapplicableStringEncoding, userInfo: [NSLocalizedDescriptionKey: "This file is \(format.encodingName), and the buffer now contains a character that encoding can't represent. Save As a new file to keep it as UTF-8."])
            }
            try data.write(to: url, options: .atomic)
            // The user's own save — a checkpoint being written right now mustn't claim it
            // as the agent's (`UserSaveLog`, audit F4).
            UserSaveLog.shared.record(url)
            openTabs[index].savedStamp = ContentStamp(content)
            openTabs[index].knownModificationDate = modificationDate(of: url)
            openTabs[index].hasExternalChange = false
            if activeTabIndex == index { externalChangeBanner.isHidden = true }
            runFormatterIfNeeded(tabID: tabID, url: url, contentAtSaveTime: content, completion: completion)
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

    private func runFormatterIfNeeded(tabID: UUID, url: URL, contentAtSaveTime: String, completion: @escaping (Bool) -> Void) {
        guard let focusedRoot, let formatter = Self.formatterCommand(for: url, projectRoot: focusedRoot) else {
            finishSave(tabID: tabID)
            completion(true)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: formatter.executable)
            process.arguments = formatter.args
            // The null device, not a `Pipe()` nobody reads: a formatter that wrote more than 64 KB
            // to either stream blocked on the full pipe while this blocked on waitUntilExit —
            // `isSaving` stayed true forever and every later ⌘S was silently ignored. (Audit H17.)
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
            let formattedContent = try? String(contentsOf: url, encoding: .utf8)
            DispatchQueue.main.async {
                guard let self, let index = self.indexForTab(id: tabID) else { completion(true); return }
                let tab = self.openTabs[index]
                // Only adopt the formatter's output if the buffer still holds what was sent to
                // it. The editor stays editable while the formatter runs on a background queue,
                // so anything typed during a ~1s prettier run was silently overwritten — with
                // no undo entry, since this replaces textStorage directly. Keeping the user's
                // keystrokes and skipping the reformat is the recoverable choice; the next save
                // formats again.
                let bufferUnchanged = tab.document.string == contentAtSaveTime
                if let formattedContent, bufferUnchanged, formattedContent != tab.document.string {
                    tab.document.replaceAll(with: formattedContent)
                    tab.document.highlight(url: url, appearance: Self.editorAppearance)
                    // The replacement invalidates every undo registration describing the old
                    // text, so replaying them would apply edits at meaningless offsets.
                    tab.undoManager.removeAllActions()
                    if self.activeTabIndex == index { self.editor.invalidateGutter() }
                }
                // Re-read even when content didn't change: some formatters touch the file
                // (rewriting it in place) without altering its bytes, which would otherwise
                // leave knownModificationDate pointing at the pre-formatter write and trigger
                // a false "changed on disk" prompt on the next save.
                self.openTabs[index].knownModificationDate = self.modificationDate(of: url)
                self.finishSave(tabID: tabID)
                if !bufferUnchanged {
                    // Typed during the formatter run: disk holds the content that was written,
                    // the buffer has moved past it, so the tab is genuinely still dirty and
                    // marking it clean would misreport unsaved work as saved.
                    self.openTabs[index].dirty = true
                    if self.activeTabIndex == index { self.dirty = true }
                    self.rebuildTabBar()
                }
                completion(true)
            }
        }
    }

    private func finishSave(tabID: UUID) {
        guard let index = indexForTab(id: tabID) else { return }
        openTabs[index].dirty = false
        if activeTabIndex == index { dirty = false }
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
            guard let self, response == .alertFirstButtonReturn, let current = self.indexForTab(id: tab.id) else { return }
            self.reloadTabFromDisk(current)
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

    /// Cached: this spawns a subprocess, and `formatterCommand` is consulted on every save —
    /// so an uncached `which` meant a process launch on the main thread per Cmd-S. A tool that
    /// appears or disappears mid-session is rare enough that a relaunch is a fine remedy.
    private static var whichCache: [String: String?] = [:]

    private static func which(_ tool: String) -> String? {
        if let cached = whichCache[tool] { return cached }
        let resolved = uncachedWhich(tool)
        whichCache[tool] = resolved
        return resolved
    }

    private static func uncachedWhich(_ tool: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", tool]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // Read before waiting — waiting first deadlocks once the pipe buffer fills
        // (see GitPaths.runGit).
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (path?.isEmpty == false) ? path : nil
    }
    func restoreLastSessionIfAvailable() { guard let saved = UserDefaults.standard.string(forKey: lastProjectKey) else { return }; let url = URL(fileURLWithPath: saved); var isDirectory: ObjCBool = false; guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return }; loadProject(at: url) }

    /// Entry point for cross-stage "open this file" requests (currently: clicking a
    /// file-path-shaped link in the Run stage's terminal output).
    func revealFile(_ url: URL, line: Int?) {
        open(url) { [weak self] in
            guard let self, let line, line > 0,
                  let index = self.openTabs.firstIndex(where: { $0.url == url }), self.openTabs[index].kind == .text else { return }
            let ns = self.openTabs[index].document.text
            guard let range = self.nsRange(for: LSPRange(start: LSPPosition(line: line - 1, character: 0), end: LSPPosition(line: line - 1, character: 0)), in: ns) else { return }
            self.editor.selectedRange = NSRange(location: range.location, length: 0)
            self.editor.scrollRangeToVisible(range)
            self.editor.focus()
        }
    }

    /// Detaches floating child windows and event monitors before the owning window closes.
    /// Child windows left attached to a parent that's being deallocated, and global event
    /// monitors whose closures outlive their view controller, are both plausible sources of
    /// undefined behavior on window teardown — this makes sure neither lingers.
    func prepareForClose() {
        removeQuickOpenDismissMonitors()
                hideQuickOpenPanel()
        explorer.tearDown()
        for panel in [completionPanelStorage].compactMap({ $0 as NSWindow? }) {
            if panel.parent != nil { view.window?.removeChildWindow(panel) }
            panel.orderOut(nil)
        }
        lspManager?.prepareForClose()
    }
}

/// The Markdown preview's links: in-document anchors scroll to their heading.
@MainActor
private final class MarkdownPreviewLinks: NSObject, NSTextViewDelegate {
    /// In-document markdown anchors (`[Contents](#setup)` etc.) — `MarkdownRenderer` renders
    /// these under its own scheme, and every rendered header carries its slug as a custom
    /// attribute, so resolving a click is just "find the first header run with this slug and
    /// scroll to it." Real web links return false and keep the default open-in-browser behavior.
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL, url.scheme == MarkdownRenderer.anchorScheme,
              let storage = textView.textStorage else { return false }
        let targetSlug = url.absoluteString.dropFirst(MarkdownRenderer.anchorScheme.count + 1)
        var found: NSRange?
        storage.enumerateAttribute(MarkdownRenderer.anchorSlugKey, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            if let slug = value as? String, slug == targetSlug {
                found = range
                stop.pointee = true
            }
        }
        if let found {
            textView.scrollRangeToVisible(found)
            textView.showFindIndicator(for: found)
        }
        // Consumed either way — a dangling anchor (no matching header) should be a no-op, not a
        // fallthrough into the OS trying to open our custom scheme.
        return true
    }
}

/// Unlike QuickOpenPanel, this must never take key status — the editor has to keep first
/// responder the whole time it's visible so arrow keys/Tab/Return/Escape keep landing in
/// NSTextViewDelegate for interception instead of needing the popup to handle input itself.
final class CompletionPanel: NSPanel {
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

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class TabChipView: NSView, NSDraggingSource {
    weak var closeButton: TabCloseButton?
    weak var closeMenuItem: NSMenuItem?
    var index: Int = 0
    var onSelect: ((Int) -> Void)?
    var onDragging: ((CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?
    /// Fired instead of `onDragEnded` when a drag ends far enough below/above the tab strip —
    /// the tear-out gesture. The point is in screen coordinates (where the new window should
    /// appear). Left nil by owners whose tabs can't become windows (Run's terminal sessions).
    var onTearOut: ((NSPoint) -> Void)?
    var title: String = "" { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var isActive: Bool = false { didSet { needsDisplay = true; updateCloseVisibility() } }
    /// Used by Run's terminal tabs (unused by Make's file tabs, which never set these) to show
    /// an exited-process state and an unseen-output dot without needing a separate chip type.
    var isDead: Bool = false { didSet { needsDisplay = true } }
    var hasUnseenOutput: Bool = false { didSet { needsDisplay = true } }

    private static let textInset: CGFloat = 12
    private static let trailingReserve: CGFloat = 26
    private static let maxTextWidth: CGFloat = 200
    /// A capsule inside the strip's 30 pt glass track.
    static let height: CGFloat = 24
    private static let minWidth: CGFloat = 96
    /// Horizontal margin reserved on each side for the active tab's bottom flares — the outward
    /// curves that let the tab pour into the content surface below instead of meeting it at a
    /// hard corner. Reserved on every chip (not just the active one) so activating a tab never
    /// changes its width and shuffles the whole row.
    static let flare: CGFloat = 4

    private var trackingArea: NSTrackingArea?
    private var dragOrigin: NSPoint?
    private var grabOffsetX: CGFloat = 0
    private var didDrag = false
    private var isTearArmed = false
    private static let tearThreshold: CGFloat = 36
    private var isHovered = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    /// In the title-bar region AppKit moves the window for any transparent view that doesn't
    /// say otherwise — which swallowed every tab drag once the tabs moved up there.
    override var mouseDownCanMoveWindow: Bool { false }

    /// Measured at the heavier weight whatever the state, so selecting a tab never changes its
    /// width — the whole strip used to shuffle by a few points on every click.
    override var intrinsicContentSize: NSSize {
        let font = DS.Text.body(.medium)
        let textWidth = min((title as NSString).size(withAttributes: [.font: font]).width, Self.maxTextWidth)
        return NSSize(width: max(Self.minWidth, textWidth + Self.textInset + Self.trailingReserve + Self.flare * 2), height: Self.height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        setWindowMovable(false)
        updateCloseVisibility()
    }
    override func mouseExited(with event: NSEvent) {
        isHovered = false
        if dragOrigin == nil { window?.isMovable = true }
        updateCloseVisibility()
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        // A chip removed while hovered (closed, strip rebuilt) must not leave the window stuck.
        if isHovered { window?.isMovable = true }
        super.viewWillMove(toWindow: newWindow)
    }

    /// Unsaved edits: a dot where the close button sits, until hover swaps it for the ×.
    var isDirty: Bool = false { didSet { needsDisplay = true; updateCloseVisibility() } }

    /// The active tab always offers its ×; others on hover. A dirty tab shows its dot there
    /// instead until hovered.
    func updateCloseVisibility() {
        closeButton?.isHidden = !(isHovered || (isActive && !isDirty))
    }

    /// Tabs live in the window's top row now, on the stage's own surface — so a tab is a pill
    /// on that surface, not a silhouette pouring into the content below (that shape drew a seam
    /// across the whole window once there was no title bar above it). The active tab takes the
    /// `overlay` tone and full-strength text; the rest recede.
    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > Self.flare * 2 + 16, bounds.height > 4 else { return }
        // A capsule on the strip's glass, drawn exactly like the stage control's selection:
        // the active tab is the soft selected capsule, the rest are the glass itself until
        // hovered. The glass track is what says "these are tabs".
        let body = bounds.insetBy(dx: Self.flare - 2, dy: 0)
        let pill = NSBezierPath(roundedRect: body, xRadius: body.height / 2, yRadius: body.height / 2)
        if isActive {
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.12)
            shadow.shadowBlurRadius = 2
            shadow.shadowOffset = NSSize(width: 0, height: -0.5)
            shadow.set()
            DS.Color.selectedCapsule.setFill()
            pill.fill()
            NSGraphicsContext.restoreGraphicsState()
        } else if isHovered {
            DS.Color.scrimSoft.setFill()
            pill.fill()
        }

        let dimmed = isDead ? 0.35 : 1.0
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: (isActive ? NSColor.labelColor : NSColor.secondaryLabelColor).withAlphaComponent(dimmed),
            .font: DS.Text.body(isActive ? .medium : .regular)
        ]
        let text = title as NSString
        let size = text.size(withAttributes: attributes)
        let textX = Self.flare + Self.textInset
        let maxWidth = max(0, bounds.width - textX - Self.trailingReserve - Self.flare)
        let drawRect = NSRect(x: textX, y: (bounds.height - size.height) / 2, width: min(size.width, maxWidth) + 1, height: size.height)
        text.draw(in: drawRect, withAttributes: attributes)

        if hasUnseenOutput {
            DS.Color.statusWorking.setFill()
            let dotSize: CGFloat = 5
            NSBezierPath(ovalIn: NSRect(x: Self.flare + 3, y: (bounds.height - dotSize) / 2, width: dotSize, height: dotSize)).fill()
        }
        if isDirty && !isHovered {
            NSColor.secondaryLabelColor.setFill()
            let dotSize: CGFloat = 7
            let x = bounds.width - Self.flare - 5 - 8 - dotSize / 2
            NSBezierPath(ovalIn: NSRect(x: x, y: (bounds.height - dotSize) / 2, width: dotSize, height: dotSize)).fill()
        }
    }

    /// In the title-bar strip the window server decides a press is a window drag before any
    /// view sees it, whatever the view says — so the window is unmovable only while the pointer
    /// is over a tab, and the drag is the tab's. Never left off: an unmovable window also
    /// refuses window managers and tiling.
    private func setWindowMovable(_ movable: Bool) {
        guard dragOrigin == nil || movable == false else { return }
        window?.isMovable = movable
    }

    override func mouseDown(with event: NSEvent) {
        window?.isMovable = false
        dragOrigin = event.locationInWindow
        grabOffsetX = event.locationInWindow.x - convert(NSPoint.zero, to: nil).x
        didDrag = false
    }

    /// While dragged, this chip's own frame changes must land instantly: the cursor-glue
    /// transform in `mouseDragged` is computed against the *final* frame, so letting the
    /// reorder's animation group also animate this chip's frame slid it off the cursor for
    /// 0.16s and the next mouse event yanked it back — a rubber-band "snapping" feel.
    /// Siblings still animate; only the held chip opts out.
    override func animation(forKey key: NSAnimatablePropertyKey) -> Any? {
        if didDrag, key == "frameOrigin" || key == "frame" || key == "frameSize" { return nil }
        return super.animation(forKey: key)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragOrigin else { return }
        let totalDX = event.locationInWindow.x - dragOrigin.x
        if abs(totalDX) > 4, !didDrag {
            didDrag = true
            // The pickup: lift the chip — shadow and a slight grow — so the drag reads as
            // physically holding something, not sliding a flat rectangle.
            wantsLayer = true
            layer?.zPosition = 10
            layer?.shadowColor = NSColor.black.cgColor
            layer?.shadowOpacity = 0.5
            layer?.shadowRadius = 6
            layer?.shadowOffset = CGSize(width: 0, height: -2)
        }
        guard didDrag else { return }

        // Pulled far enough off the strip, the gesture stops being a reorder and becomes a
        // tear-out — the chip follows the cursor vertically and fades to signal "this is about
        // to become its own window." Dragging back within range re-arms reordering.
        let dy = event.locationInWindow.y - dragOrigin.y
        isTearArmed = onTearOut != nil && abs(dy) > Self.tearThreshold
        // Pulled off the strip: from here it's a system drag, so an image of the tab follows the
        // cursor anywhere on screen — out of the window, over other apps — instead of the chip
        // stopping at the window's edge with nothing to show where the file is going.
        if isTearArmed && !isTearingOut {
            beginTearOut(with: event)
            return
        }

        if !isTearArmed {
            // Reorder the model/stack first (siblings animate into their new slots)...
            onDragging?(event.locationInWindow.x)
        }

        // ...then keep this chip glued to the cursor regardless of where that reorder
        // just placed it in the stack, by transforming relative to its *current* laid-out
        // position rather than the position at mouseDown.
        let naturalXInWindow = convert(NSPoint.zero, to: nil).x
        // Held inside the strip's glass track: a tab can't be dragged out of its container, over
        // the traffic lights or past the last tab.
        var desiredXInWindow = event.locationInWindow.x - grabOffsetX
        if !isTearArmed, let track = superview {
            let trackFrame = track.convert(track.bounds, to: nil).insetBy(dx: 3, dy: 0)
            desiredXInWindow = min(max(desiredXInWindow, trackFrame.minX), trackFrame.maxX - bounds.width)
        }
        // Flipped view: window +y is up, layer translation follows view coords (down-positive).
        let liftY = isTearArmed ? -dy : 0
        layer?.setAffineTransform(CGAffineTransform(translationX: desiredXInWindow - naturalXInWindow, y: liftY).scaledBy(x: 1.04, y: 1.04))
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragOrigin = nil
            if !isHovered { window?.isMovable = true }
        }
        guard dragOrigin != nil else { return }
        if didDrag {
            if isTearArmed {
                isTearArmed = false
                alphaValue = 1
                layer?.setAffineTransform(.identity)
                layer?.zPosition = 0
                layer?.shadowOpacity = 0
                onTearOut?(NSEvent.mouseLocation)
                return
            }
            // The set-down: glide into the slot instead of snapping.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = DS.Motion.duration(0.18)
                context.timingFunction = DS.Motion.curve
                context.allowsImplicitAnimation = true
                layer?.setAffineTransform(.identity)
            } completionHandler: { [weak self] in
                self?.layer?.zPosition = 0
                self?.layer?.shadowOpacity = 0
            }
            onDragEnded?()
        } else {
            onSelect?(index)
        }
    }

    // MARK: Tear-out

    private var isTearingOut = false
    static let tabPasteboardType = NSPasteboard.PasteboardType("com.shahi.side.tab")

    private func beginTearOut(with event: NSEvent) {
        isTearingOut = true
        layer?.setAffineTransform(.identity)
        layer?.zPosition = 0
        layer?.shadowOpacity = 0
        alphaValue = 0.35  // the tab's slot stays, ghosted, until the drop decides
        // A private type, never a file URL: dropping a tab on Finder must not move the file.
        let item = NSPasteboardItem()
        item.setString(title, forType: Self.tabPasteboardType)
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        let image = Self.dragImage(title: title, icon: dragIcon)
        let origin = convert(event.locationInWindow, from: nil)
        dragItem.setDraggingFrame(NSRect(x: origin.x - image.size.width / 2, y: origin.y - image.size.height / 2, width: image.size.width, height: image.size.height), contents: image)
        let session = beginDraggingSession(with: [dragItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    /// Set by the owner — the file's own icon, or Run's terminal glyph — for the drag image.
    var dragIcon: NSImage?

    /// The tab as it would look alone: a capsule with the file's icon and name.
    static func dragImage(title: String, icon: NSImage?) -> NSImage {
        let font = DS.Text.body(.medium)
        let textSize = (title as NSString).size(withAttributes: [.font: font])
        let size = NSSize(width: ceil(textSize.width) + (icon == nil ? 28 : 50), height: 30)
        return NSImage(size: size, flipped: false) { rect in
            let capsule = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: rect.height / 2, yRadius: rect.height / 2)
            NSColor.windowBackgroundColor.withAlphaComponent(0.96).setFill()
            capsule.fill()
            NSColor.separatorColor.setStroke()
            capsule.stroke()
            var x: CGFloat = 14
            if let icon {
                // A symbol (Run's terminal glyph) is a template: tint it, or it draws black in dark.
                let glyph = icon.isTemplate ? NSImage(size: icon.size, flipped: false) { r in
                    icon.draw(in: r); NSColor.labelColor.set(); r.fill(using: .sourceAtop); return true
                } : icon
                glyph.draw(in: NSRect(x: x, y: (rect.height - 16) / 2, width: 16, height: 16))
                x += 22
            }
            (title as NSString).draw(at: NSPoint(x: x, y: (rect.height - textSize.height) / 2), withAttributes: [.font: font, .foregroundColor: NSColor.labelColor])
            return true
        }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .move
    }

    /// Released outside the window: the tab becomes its own window there. Back inside: it
    /// returns to its slot.
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isTearingOut = false
        isTearArmed = false
        didDrag = false
        dragOrigin = nil
        alphaValue = 1
        if !isHovered { window?.isMovable = true }
        guard let window, !window.frame.contains(screenPoint) else { return }
        onTearOut?(screenPoint)
    }

    // Hand-drawn view — invisible to accessibility without saying what it is ourselves.
    // A tab is a radio button inside its strip's tab group, and must announce whether it's the
    // selected one.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .radioButton }
    override func accessibilityLabel() -> String? { title }
    override func accessibilityValue() -> Any? { isActive ? 1 : 0 }
    override func accessibilityPerformPress() -> Bool {
        onSelect?(index)
        return true
    }
}

final class TabCloseButton: CircularIconButton {
    init() {
        super.init(diameter: 16)
        setSymbol("xmark", pointSize: 9, weight: .bold, color: NSColor.secondaryLabelColor, accessibilityLabel: "Close Tab")
        // Stronger than the selected tab it sits on: in dark mode the old hover (white 16 %) sat
        // on an active tab of white 18 % and disappeared.
        hoverBackgroundColor = DS.Color.tabCloseHover
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

final class QuickOpenSearchField: NSTextField {
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

extension MakeWorkspaceViewController: EditorEngineDelegate {
    func editor(_ engine: EditorEngine, definitionRequestedAt characterIndex: Int) {
        guard let tabIndex = activeTabIndex else { return }
        performJumpToDefinition(at: characterIndex, tabIndex: tabIndex)
    }

    func editor(_ engine: EditorEngine, clickedDiffMark mark: GitDiffMark, line: Int, event: NSEvent) {
        showDiffMenu(line: line, mark: mark, event: event)
    }

    func editor(_ engine: EditorEngine, clickedDiagnostic severity: LSPDiagnosticSeverity, line: Int, event: NSEvent) {
        showDiagnosticMenu(line: line, severity: severity, event: event)
    }
}

extension MakeWorkspaceViewController: StageChromeProviding {
    var scrollViewUnderTopRow: NSScrollView? { loadViewIfNeeded(); return editorScroll }
    /// The file tabs (with the language-server indicator trailing) live in the window's top row.
    var topRowContent: NSView? { loadViewIfNeeded(); return tabBar }

    func setBottomObstruction(_ height: CGFloat) {
        loadViewIfNeeded()
        // The editor scrolls beneath whatever covers the bottom, far enough that the last line
        // (and the caret on it — scroll-to-visible honours content insets) clears it.
        let inset = height > 0 ? height + DS.Spacing.l : 0
        for scroll in [editorScroll, markdownPreviewScroll, imageScroll, csvScroll] {
            scroll.automaticallyAdjustsContentInsets = false
            scroll.contentInsets = NSEdgeInsets(top: ChromeHost.rowHeight, left: 0, bottom: inset, right: 0)
        }
    }

    func setTopObstruction(_ height: CGFloat) {
        loadViewIfNeeded()
        for scroll in [editorScroll, markdownPreviewScroll, imageScroll, csvScroll] {
            scroll.automaticallyAdjustsContentInsets = false
            scroll.contentInsets.top = height
        }
    }

    /// ⌃Tab / ⌃⇧Tab.
    func selectAdjacentTab(_ offset: Int) {
        guard !openTabs.isEmpty else { return }
        let current = activeTabIndex ?? 0
        switchToTab((current + offset + openTabs.count) % openTabs.count)
    }
}

/// A palette result: icon, the name in the system font, where it lives dimmed beside it, and a
/// trailing detail (a shortcut, a line) right-aligned — the Spotlight row.
private final class PaletteCellView: NSTableCellView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let trailing = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        icon.imageScaling = .scaleProportionallyUpOrDown
        title.font = DS.Text.body()
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        detail.font = DS.Text.caption()
        detail.lineBreakMode = .byTruncatingHead
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        trailing.font = DS.Text.caption()
        trailing.alignment = .right
        trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
        for view in [icon, title, detail, trailing] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        imageView = icon
        textField = title
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18), icon.heightAnchor.constraint(equalToConstant: 18),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 8),
            detail.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            trailing.leadingAnchor.constraint(greaterThanOrEqualTo: detail.trailingAnchor, constant: 12),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            trailing.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
        ])
        applyColors()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(icon image: NSImage?, title text: String, detail detailText: String?, trailing trailingText: String?) {
        icon.image = image
        icon.contentTintColor = .secondaryLabelColor
        title.stringValue = text
        detail.stringValue = detailText ?? ""
        trailing.stringValue = trailingText ?? ""
        setAccessibilityLabel([text, detailText, trailingText].compactMap { $0 }.joined(separator: ", "))
    }

    override var backgroundStyle: NSView.BackgroundStyle { didSet { applyColors() } }

    /// On the accent selection everything turns white, the way a system list does.
    private func applyColors() {
        let selected = backgroundStyle == .emphasized
        title.textColor = selected ? .white : .labelColor
        detail.textColor = selected ? NSColor.white.withAlphaComponent(0.75) : .tertiaryLabelColor
        trailing.textColor = selected ? NSColor.white.withAlphaComponent(0.75) : .tertiaryLabelColor
        icon.contentTintColor = selected ? .white : .secondaryLabelColor
    }
}

/// The accent-filled rounded selection a system list draws, inset from the palette's edges.
/// Always emphasized: focus stays in the field while the list is what's being chosen from.
private final class PaletteRowView: NSTableRowView {
    override var isEmphasized: Bool { get { true } set {} }
    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 1), xRadius: 8, yRadius: 8).fill()
    }
}

/// Make's language-server indicator: `DS.StatusDot` + a caption, as status is everywhere else
/// (§2.4). Only the not-installed state is a button — the rest just say what's true.
final class LSPStatusChip: NSButton {
    private let dot = DS.StatusDot(state: .idle)
    private var clickable = false

    init() {
        super.init(frame: .zero)
        isBordered = false
        title = ""
        dot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func set(state: DS.StatusState, text: String, clickable: Bool, tip: String) {
        dot.state = state
        self.clickable = clickable
        attributedTitle = NSAttributedString(string: text, attributes: [
            .font: DS.Text.caption(clickable ? .medium : .regular),
            .foregroundColor: clickable ? NSColor.labelColor : NSColor.secondaryLabelColor,
        ])
        toolTip = tip
        setAccessibilityLabel(tip)
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        let size = attributedTitle.size()
        return NSSize(width: ceil(size.width) + 18, height: 22)
    }
    override func draw(_ dirtyRect: NSRect) {
        let size = attributedTitle.size()
        attributedTitle.draw(at: NSPoint(x: 16, y: (bounds.height - size.height) / 2))
    }
    override func mouseDown(with event: NSEvent) { if clickable { super.mouseDown(with: event) } }
    override func accessibilityPerformPress() -> Bool { clickable ? super.accessibilityPerformPress() : false }

    static func languageName(_ languageId: String) -> String {
        switch languageId {
        case "typescript", "typescriptreact": return "TypeScript"
        case "javascript", "javascriptreact": return "JavaScript"
        case "python": return "Python"
        case "swift": return "Swift"
        case "rust": return "Rust"
        case "go": return "Go"
        default: return languageId.prefix(1).uppercased() + languageId.dropFirst()
        }
    }
}

