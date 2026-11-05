import AlloyCore
import AlloyAppKit
import AppKit
import SideAgents

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

/// A file on disk as Side last read or wrote it: modification date, size and inode. Any
/// difference is someone else's change. A newer date alone missed a replacement carrying an
/// older one (`mv`, `cp -p`, `rsync -a`, `unzip`), and the next save overwrote it unasked
/// (2026-09-30 audit, EDT-8).
struct DiskStamp: Equatable {
    let modified: Date
    let size: UInt64
    let inode: UInt64

    init?(of url: URL) {
        // The file a symlink points at, which is what a save writes.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path),
              let modified = attributes[.modificationDate] as? Date else { return nil }
        self.modified = modified
        size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    }
}

private struct OpenTab {
    let id = UUID()
    var url: URL
    let kind: TabKind
    let document: EditorDocument
    let undoManager: UndoManager
    var dirty: Bool
    var isUntitled: Bool
    /// The file as last read or written; any difference on disk is someone else's change.
    var knownDiskStamp: DiskStamp?
    /// How the file is stored — encoding, BOM, line ending — so a save writes the same shape back.
    var format: TextFileCodec.Format = .utf8
    /// Set when the file changed on disk while this tab had unsaved edits; cleared by Reload or
    /// Keep. A clean tab is simply reloaded instead.
    var hasExternalChange = false
    /// The content as last loaded or saved — so undoing back to it clears the unsaved state
    /// instead of leaving a file "edited" that matches disk.
    var savedStamp = ContentStamp("")
    var lastSelectedRange = NSRange(location: 0, length: 0)
    /// A spreadsheet's sheets (CSV and TSV have one; a workbook its own).
    var sheets: [Sheet] = []
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
enum PaletteMode { case files, symbols, text, commands, find, problems, references, choices }

/// A row of the palette's choices mode: something to pick (a launch configuration, a process).
struct PaletteChoice {
    let symbol: String
    let title: String
    let detail: String?
    let trailing: String?
    /// Shown dimmed, and picking it explains why instead of choosing.
    var unavailable: String? = nil
}

final class MakeWorkspaceViewController: NSViewController, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    let searchField = QuickOpenSearchField()
    /// Make's editor: Alloy (SIDE_RFC_ALLOY.md), behind the `EditorEngine` seam.
    private(set) lazy var editor: EditorEngine = AlloyEditorEngine(appearance: Self.editorAppearance)
    private var editorScroll: NSScrollView { editor.scrollView }
    /// What Make lays out and hides: Alloy's editor view, which holds its scroll view.
    private var editorContainer: NSView { editor.containerView }
    private var gutter: NSView { editor.gutterView }
    /// The document drawn small beside the text (View → Show Minimap), remembered.
    private var minimap: AlloyMinimapView { (editor as! AlloyEditorEngine).view.minimap }
    private var minimapWidth: NSLayoutConstraint?
    private var minimapBottom: NSLayoutConstraint?
    static let minimapKey = "SideMinimapShown"
    /// Where Make keeps its view preferences: the person's, except under tests and UI testing,
    /// which share the app's domain and mustn't change what the person chose.
    nonisolated(unsafe) static var preferences: UserDefaults = HeronDefaults.store
    private var minimapShown: Bool {
        get { EditorPreferences.minimapShown }
        set { EditorPreferences.minimapShown = newValue }
    }

    @objc func toggleMinimap(_ sender: Any?) { minimapShown.toggle() }

    /// Settings or the View menu changed an editor preference: every window follows.
    @objc private func editorPreferencesChanged() {
        applyMinimapVisibility()
        if isWriting { applyWriterAids() }
        (editor as? AlloyEditorEngine)?.view.isFoldingEnabled = EditorPreferences.foldingEnabled
    }

    private func applyMinimapVisibility() {
        let show = minimapShown && !editorContainer.isHidden && !isWriting
        minimap.isHidden = !show
        minimapWidth?.constant = show ? AlloyMinimapView.width : 0
        if show { minimap.needsDisplay = true }
    }
    private let tabBar = TabStripView()
    /// Make's backdrop (ChromeBackground), the editor theme's background when one is chosen.
    private var chromeFill: NSView?
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

    // Find in this file (SIDE_RFC_FIND_REVIEW_TRACKS.md, F1): a mode of the palette.
    private var find = InFileFind(query: "", options: .init())
    private var findMatches: [NSRange] = []
    private var findTruncated = false
    private var findCurrent: Int?
    private var findShowsReplace = false
    /// The text the matches were found in, and the tab: a step or a replace uses these.
    private var findText: NSString = ""
    /// Find in a sheet: each cell is a line of `findText`, in the order shown.
    private var findSheetCells: [CellRef] = []
    private var findSheetLineStarts: [Int] = []
    /// The list: one row per line with matches (the index of its first match, and the line,
    /// one-based), and each match's row, counted once per search.
    private var findRows: [(firstMatch: Int, line: Int)] = []
    private var findRowOfMatch: [Int] = []
    private let findAccessory = NSStackView()
    private let findCountLabel = NSTextField(labelWithString: "")
    private let findCaseButton = DS.CapsuleToggle()
    private let findWordButton = DS.CapsuleToggle()
    private let findRegexButton = DS.CapsuleToggle()
    private let findReplaceToggle = DS.CapsuleToggle()
    private let replaceRow = NSStackView()
    let replaceField = NSTextField()
    private var replaceRowHeight: NSLayoutConstraint?
    private static let replaceRowHeightValue: CGFloat = 46
    /// Rows listed at most (every match is still marked in the editor and stepped through).
    private static let findListLimit = 1_000
    /// The editor's bottom inset before Find raised it above the palette.
    private var insetBeforeFind: CGFloat?
    private weak var insetScroll: NSScrollView?
    private let resultsTable = NSTableView()
    /// The file explorer (`FileExplorer`): its own component; Make only hosts it.
    private let explorer = FileExplorer()
    /// Breakpoints, sessions, the debug bar and inspector (SIDE_RFC_DEBUGGER.md).
    private(set) lazy var debugger = MakeDebugger(host: self)
    /// The editor's edges, moved in while the debug inspector is beside it.
    private var gutterLeading: NSLayoutConstraint?
    private var gutterWidth: NSLayoutConstraint?
    /// What covers the editor's top (the window's top row), and the debug bar below it.
    private var topObstruction = ChromeHost.rowHeight
    private var bottomObstruction: CGFloat = 0
    private var debugTopInset: CGFloat = 0
    private var minimapTrailing: NSLayoutConstraint?
    private let imageScroll = NSScrollView()
    private let imageView = FocusableImageView()
    /// CSV, TSV and Excel files (CSVParser.swift).
    private let sheetView = SheetView()
    private var csvScroll: NSScrollView { sheetView.scrollView }
    private let markdownPreviewScroll = NSScrollView()
    private let markdownPreviewView = MarkdownPreviewTextView.make()
    /// What the preview shows now (tab, text, style), so switching back to an unchanged document
    /// neither renders nor lays it out again, and keeps its scroll position.
    private var markdownPreviewShown: (tab: UUID, stamp: ContentStamp, generation: Int)?
    private var markdownPreviewGeneration = 0
    private let markdownLinks = MarkdownPreviewLinks()
    private let completionPopup = CompletionPopup()
    /// The word being completed and the list for it (SIDE_RFC_IDE_ESSENTIALS.md, L2).
    private var completionSession: CompletionSession?
    private var completionTabID: UUID?
    /// The request whose answer the session is waiting for, and the documentation being fetched.
    private var completionToken: LSPRequestToken?
    private var resolveToken: LSPRequestToken?
    /// Rows of the session's list whose `resolve` came back (their edits are complete).
    private var resolvedCompletions: Set<Int> = []
    /// Return or Tab pressed while the selected item's `resolve` (which carries auto-imports) was
    /// still out: accepted when it arrives, or after a short wait regardless.
    private var acceptAfterResolve: (row: Int, replacing: Bool)?
    /// What was just typed, from `shouldChangeTextIn`: a list opens on typing, not on deleting.
    private var lastTypedText: String?
    /// Signature help above the caret while a call's arguments are typed (L2).
    private let signatureCard = InfoCard()
    private var signatureToken: LSPRequestToken?
    private var signatureHelp: LSPSignatureHelp?
    /// Hover (Quick Help): the word under a resting pointer, and its card (L3).
    private let hoverCard = InfoCard()
    private var hoverTimer: DispatchWorkItem?
    private var hoverToken: LSPRequestToken?
    private var hoverRange: NSRange?
    /// The symbol under the pointer while ⌘ is held: underlined, a click away from its definition.
    private var linkRange: NSRange?
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
    private let externalChangeBanner: NSView = { let banner = NSView(); banner.isHidden = true; return banner }()
    /// Asks to trust a project whose own code would run (SEC-11); `trustBannerHeight` is 0 while hidden.
    private let trustBanner: NSView = { let banner = NSView(); banner.isHidden = true; return banner }()
    private let trustLabel = NSTextField(labelWithString: "")
    private var trustBannerHeight: NSLayoutConstraint?
    /// The banners hang from the top row's height, not from the tab bar: the tab bar is handed to
    /// the window's top row (`topRowContent`), and moving it out of this view dropped every
    /// constraint to it, so the banner lost its position and fell behind the bottom bar.
    private var trustBannerTop: NSLayoutConstraint?
    /// Projects whose banner was put away this session ("Not Now").
    private var trustDeferred: Set<String> = []
    private let externalChangeLabel = NSTextField(labelWithString: "")
    private var lspManager: LSPManager?
    /// Trails Make's tab strip in the top row (Direction 02 §4.5).
    /// The active file's language server, trailing the tab strip: caption + dot (§4.5).
    let lspStatusButton = LSPStatusChip()
    /// Where the caret is, "Ln 12, Col 5" (and how much is selected); click for Go to Line.
    let caretPositionButton = NSButton(title: "", target: nil, action: nil)
    /// Errors and warnings across the project, "✕ 2  ⚠ 5"; click for Show Problems.
    let problemsButton = NSButton(title: "", target: nil, action: nil)
    private var lspInstallPopover: NSPopover?
    private var allFiles: [IndexedFile] = []
    private var matches: [URL] = []
    private typealias SearchMode = PaletteMode
    /// Find in Project results, one row per matching line.
    private var textMatches: [ProjectTextSearch.Match] = []
    private var textSearchTruncated = false
    private var searchMode: SearchMode = .files
    /// Typing `>` switches any mode to commands, the way every palette does.
    private var effectiveMode: SearchMode {
        [.find, .problems, .references, .choices].contains(searchMode) || !searchField.stringValue.hasPrefix(">") ? searchMode : .commands
    }
    /// Every problem the servers report, across the project (Show Problems, ⇧⌘M).
    private var allDiagnostics: [URL: [LSPDiagnostic]] = [:]
    /// What the language servers last said per file, and what the last LaTeX build did: a
    /// file's problems are both.
    private var serverDiagnostics: [URL: [LSPDiagnostic]] = [:]
    private var buildDiagnostics: [URL: [LSPDiagnostic]] = [:]
    private lazy var latex: LaTeXSession = makeLaTeXSession()
    /// Writer mode (see its section).
    private(set) var isWriting = false
    private let wordCountLabel = NSTextField(labelWithString: "")
    /// The count sits on its own capsule, so text scrolling under it doesn't cover it.
    private let wordCountPill = NSBox()
    private var wordCountWork: DispatchWorkItem?
    /// The zoom, said for a moment in the word count's pill: Writer mode hides the bar's own.
    private var zoomNote: String?
    private var zoomNoteWork: DispatchWorkItem?
    private var problemRows: [(url: URL, diagnostic: LSPDiagnostic)] = []
    /// The uses Find References found, with each line's text, and the rows the query keeps.
    private var referenceResults: [(location: LSPLocation, url: URL, line: Int, text: String)] = []
    private var referenceRows: [(location: LSPLocation, url: URL, line: Int, text: String)] = []
    private var referenceSymbol = ""
    /// The choices mode: what's offered, the rows the query keeps, and who's asking.
    private var choices: [PaletteChoice] = []
    private var choiceRows: [Int] = []
    private var choicePrompt = ""
    private var onChoice: ((Int) -> Void)?
    /// Rename's field, over the symbol.
    private var renameField: RenameField?
    private var symbolMatches: [OutlineSymbol] = []
    /// The active file's outline, for Go to Symbol (⇧⌘O).
    private var outlineSymbols: [OutlineSymbol] = []
    private var outlineGeneration = 0
    private var openTabs: [OpenTab] = []
    private var activeTabIndex: Int?
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
    /// Under the editor and what stands in for it (an image, a sheet, a preview, no file): the
    /// editor theme's background, or Side's canvas.
    private static var editorBackground: NSColor { EditorThemes.current(dark: DS.Appearance.isDark)?.background.nsColor ?? DS.Color.canvas }
    /// At the editor text-size setting (Appearance), not the interface scale.
    private static var editorFont: NSFont { DS.Text.editor() }
    private static let editorTextColor = NSColor.labelColor
    static var editorAppearance: EditorAppearance {
        EditorAppearance(font: editorFont, textColor: editorTextColor, background: editorBackground)
    }

    override func loadView() { view = NSView() }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(self, selector: #selector(projectTrustChanged(_:)), name: ProjectTrust.didChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(editorTextSizeChanged), name: DS.Text.CodeSize.didChangeNotification, object: nil)
        // Undo and redo can land the buffer back on what's saved; typing never can, so only
        // these two re-check (a hash of the buffer, never on every keystroke).
        NotificationCenter.default.addObserver(self, selector: #selector(languageSettingsChanged), name: LanguageSettings.didChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(matchChromeToEditorTheme), name: EditorThemes.didChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(matchChromeToEditorTheme), name: DS.Appearance.didChangeNotification, object: nil)
        DispatchQueue.main.async { [weak self] in self?.matchChromeToEditorTheme() }
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
            configureTrustBanner()
            configureExternalChangeBanner()
            keyWindowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.reconcileAllTabsWithDisk()
                    // Another of Side's windows in front brings its own kind of file's shortcuts.
                    self?.updateShortcutContext()
                }
            }
        }
        if let index = activeTabIndex, openTabs.indices.contains(index), openTabs[index].kind == .text {
            editor.focus()
        }
        LaunchSignposts.end("makeViewDidAppear")
    }

    private func buildView() {
        view.wantsLayer = true
        chromeFill = ChromeBackground.install(in: view)

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
        caretPositionButton.isBordered = false
        caretPositionButton.target = self
        caretPositionButton.action = #selector(showGoToLine)
        caretPositionButton.toolTip = "Go to Line\u{2026}"
        caretPositionButton.translatesAutoresizingMaskIntoConstraints = false
        caretPositionButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        caretPositionButton.isHidden = true
        tabBar.addSubview(caretPositionButton)
        problemsButton.isBordered = false
        problemsButton.target = self
        problemsButton.action = #selector(showProblems(_:))
        problemsButton.toolTip = "Show Problems"
        problemsButton.translatesAutoresizingMaskIntoConstraints = false
        problemsButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        problemsButton.isHidden = true
        tabBar.addSubview(problemsButton)
        noFileLabel.font = DS.Text.body()
        noFileLabel.textColor = .tertiaryLabelColor
        noFileLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(noFileLabel)
        NSLayoutConstraint.activate([
            noFileLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            noFileLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        NSLayoutConstraint.activate([
            tabScroll.leadingAnchor.constraint(equalTo: tabBar.leadingAnchor), tabScroll.trailingAnchor.constraint(equalTo: problemsButton.leadingAnchor, constant: -DS.Spacing.s),
            problemsButton.trailingAnchor.constraint(equalTo: caretPositionButton.leadingAnchor, constant: -DS.Spacing.m), problemsButton.centerYAnchor.constraint(equalTo: tabBar.centerYAnchor),
            caretPositionButton.trailingAnchor.constraint(equalTo: lspStatusButton.leadingAnchor, constant: -DS.Spacing.m), caretPositionButton.centerYAnchor.constraint(equalTo: tabBar.centerYAnchor), tabScroll.topAnchor.constraint(equalTo: tabBar.topAnchor), tabScroll.bottomAnchor.constraint(equalTo: tabBar.bottomAnchor),
            lspStatusButton.trailingAnchor.constraint(equalTo: tabBar.trailingAnchor), lspStatusButton.centerYAnchor.constraint(equalTo: tabBar.centerYAnchor),
            tabBarStack.leadingAnchor.constraint(equalTo: tabScroll.contentView.leadingAnchor), tabBarStack.topAnchor.constraint(equalTo: tabScroll.contentView.topAnchor), tabBarStack.heightAnchor.constraint(equalTo: tabScroll.heightAnchor),
            divider.leadingAnchor.constraint(equalTo: tabBar.leadingAnchor), divider.trailingAnchor.constraint(equalTo: tabBar.trailingAnchor), divider.bottomAnchor.constraint(equalTo: tabBar.bottomAnchor), divider.heightAnchor.constraint(equalToConstant: 1)
        ])

        editor.delegate = self
        editorContainer.isHidden = true
        editorContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(editorContainer)
        minimap.translatesAutoresizingMaskIntoConstraints = false
        minimap.backgroundColor = Self.editorBackground
        view.addSubview(minimap)
        let width = minimap.widthAnchor.constraint(equalToConstant: 0)
        let bottom = minimap.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        NSLayoutConstraint.activate([width, bottom])
        minimapWidth = width
        minimapBottom = bottom
        minimap.isHidden = true
        (editor as? AlloyEditorEngine)?.view.isFoldingEnabled = EditorPreferences.foldingEnabled
        NotificationCenter.default.addObserver(self, selector: #selector(editorPreferencesChanged), name: EditorPreferences.didChangeNotification, object: nil)
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

        csvScroll.backgroundColor = Self.editorBackground
        csvScroll.drawsBackground = true
        sheetView.isHidden = true
        sheetView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sheetView)

        markdownPreviewView.isEditable = false
        markdownPreviewView.isSelectable = true
        markdownPreviewView.drawsBackground = true
        markdownPreviewView.backgroundColor = Self.editorBackground
        markdownPreviewView.onAppearanceChange = { [weak self] in self?.restyleMarkdownPreview() }
        // For `textView(_:clickedOnLink:at:)` — in-document `#anchor` links scroll the preview
        // instead of being handed to the OS as if they were web URLs.
        markdownPreviewView.delegate = markdownLinks
        markdownLinks.onPictureLoaded = { [weak self] in self?.restyleMarkdownPreview() }
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
        gutterLeading = gutter.leadingAnchor.constraint(equalTo: view.leadingAnchor)
        gutterWidth = gutter.widthAnchor.constraint(equalToConstant: AlloyGutterView.width)
        minimapTrailing = minimap.trailingAnchor.constraint(equalTo: view.trailingAnchor)

        NSLayoutConstraint.activate([
            gutter.topAnchor.constraint(equalTo: view.topAnchor), gutterLeading!, gutter.bottomAnchor.constraint(equalTo: view.bottomAnchor), gutterWidth!,
            editorContainer.topAnchor.constraint(equalTo: view.topAnchor), editorContainer.leadingAnchor.constraint(equalTo: gutter.trailingAnchor), editorContainer.trailingAnchor.constraint(equalTo: minimap.leadingAnchor), editorContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            // Clear of the top row and the bar: it's a map of the document, not text to read under glass.
            minimap.topAnchor.constraint(equalTo: view.topAnchor, constant: ChromeHost.rowHeight), minimapTrailing!,
            imageScroll.topAnchor.constraint(equalTo: view.topAnchor), imageScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), imageScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor), imageScroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sheetView.topAnchor.constraint(equalTo: view.topAnchor), sheetView.leadingAnchor.constraint(equalTo: view.leadingAnchor), sheetView.trailingAnchor.constraint(equalTo: view.trailingAnchor), sheetView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            markdownPreviewScroll.topAnchor.constraint(equalTo: view.topAnchor), markdownPreviewScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), markdownPreviewScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor), markdownPreviewScroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            emptyState.centerXAnchor.constraint(equalTo: view.centerXAnchor), emptyState.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -30), detail.widthAnchor.constraint(lessThanOrEqualToConstant: 460)
        ])
        LaunchSignposts.begin("makePanelSurfaces")
        configureQuickOpenPanel()
        configureExplorer()
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
        configureFindControls()
        for view in [glyph, searchField, findAccessory, replaceRow, paletteDivider, scroll] as [NSView] { body.addSubview(view) }
        let replaceHeight = replaceRow.heightAnchor.constraint(equalToConstant: 0)
        replaceRowHeight = replaceHeight
        NSLayoutConstraint.activate([
            glyph.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 18),
            glyph.centerYAnchor.constraint(equalTo: body.topAnchor, constant: Self.paletteHeaderHeight / 2),
            searchField.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: findAccessory.leadingAnchor, constant: -10),
            searchField.centerYAnchor.constraint(equalTo: glyph.centerYAnchor),
            findAccessory.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -14),
            findAccessory.centerYAnchor.constraint(equalTo: glyph.centerYAnchor),
            replaceRow.topAnchor.constraint(equalTo: body.topAnchor, constant: Self.paletteHeaderHeight),
            replaceRow.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 18),
            replaceRow.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -14),
            replaceHeight,
            paletteDivider.topAnchor.constraint(equalTo: replaceRow.bottomAnchor),
            paletteDivider.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            paletteDivider.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            paletteDivider.heightAnchor.constraint(equalToConstant: 1),
            scroll.topAnchor.constraint(equalTo: paletteDivider.bottomAnchor, constant: Self.paletteListPadding),
            scroll.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -Self.paletteListPadding),
        ])
        paletteSurface = Self.makeFloatingPanelSurface(embedding: body, cornerRadius: DS.Radius.palette, padding: 0)
        paletteSurface.setAccessibilityElement(true)
        paletteSurface.setAccessibilityRole(.group)
        paletteSurface.setAccessibilityLabel("Palette")
    }

    static func makeFloatingPanelSurface(embedding content: NSView, cornerRadius: CGFloat, padding: CGFloat) -> NSView {
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
        // Find keeps the editor in view: fewer rows.
        let rows = min(searchMode == .find ? 5 : quickOpenMaxVisibleRows, resultCount)
        paletteDivider.isHidden = rows == 0
        let list = rows == 0 ? 0 : 1 + Self.paletteListPadding * 2 + CGFloat(rows) * quickOpenRowHeight
        let replace = searchMode == .find && findShowsReplace ? Self.replaceRowHeightValue : 0
        let height = Self.paletteHeaderHeight + replace + list
        if searchMode == .find { raiseEditorAbovePalette(height) }
        onPaletteShow?(NSSize(width: Self.paletteWidth, height: height))
        installQuickOpenDismissMonitors()
    }

    func dismissPaletteForTesting() { hideQuickOpenPanel() }

    private func hideQuickOpenPanel() {
        removeQuickOpenDismissMonitors()
        guard paletteIsOpen else { return }
        paletteIsOpen = false
        if searchMode == .find { endFind() }
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
        if mode == .find && (activeTabIndex == nil || openTabs[activeTabIndex!].kind == .image) { return }
        if !paletteIsOpen { paletteReturnResponder = window?.firstResponder }
        endHover()
        hideSignatureHelp()
        endCompletion()
        if paletteIsOpen, searchMode == .find, mode != .find { endFind() }
        paletteIsOpen = true
        searchMode = mode == .commands ? .files : mode
        findAccessory.isHidden = mode != .find
        if mode != .find { setReplaceRowShown(false) }
        let project = projectURL?.lastPathComponent
        switch mode {
        case .files: searchField.placeholderString = project.map { "Find a file in \($0)   ·   > for commands" } ?? "Type > for commands"
        case .text: searchField.placeholderString = project.map { "Search text in \($0)" } ?? "Search text"
        case .symbols: searchField.placeholderString = "Go to symbol"
        case .commands: searchField.placeholderString = "Run a command"
        case .find: searchField.placeholderString = activeTabIndex.map { "Find in \(openTabs[$0].url.lastPathComponent)" } ?? "Find"
        case .problems: searchField.placeholderString = problemsSummary
        case .references: searchField.placeholderString = "References to \(referenceSymbol) \u{00B7} \(referenceResults.count)"
        case .choices: searchField.placeholderString = choicePrompt
        }
        searchField.stringValue = mode == .commands ? ">" : (mode == .find ? find.query : "")
        if mode == .symbols { outlineSymbols = []; loadOutline() }
        showQuickOpenPanel()
        searchField.window?.makeFirstResponder(searchField)
        (searchField.currentEditor() as? NSTextView)?.moveToEndOfDocument(nil)
        performSearch()
    }

    var isPaletteOpen: Bool { paletteIsOpen }

    // MARK: - Find in this file

    private func configureFindControls() {
        findCountLabel.font = DS.Text.caption()
        findCountLabel.textColor = .secondaryLabelColor
        findCountLabel.alignment = .right
        for (button, title, tip) in [(findCaseButton, "Aa", "Match Case"), (findWordButton, "W", "Whole Words"), (findRegexButton, ".*", "Regular Expression")] {
            button.title = title
            button.font = DS.Text.code(12, weight: .medium)
            button.toolTip = tip
            button.setAccessibilityLabel(tip)
            button.target = self
            button.action = #selector(findOptionChanged)
        }
        findReplaceToggle.image = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: "Replace")
        findReplaceToggle.toolTip = "Replace (⌥⌘F)"
        findReplaceToggle.target = self
        findReplaceToggle.action = #selector(toggleReplaceRow)
        for view in [findCountLabel, findCaseButton, findWordButton, findRegexButton, findReplaceToggle] { findAccessory.addArrangedSubview(view) }
        findAccessory.orientation = .horizontal
        findAccessory.spacing = 4
        findAccessory.setCustomSpacing(10, after: findCountLabel)
        findAccessory.isHidden = true
        findAccessory.translatesAutoresizingMaskIntoConstraints = false
        findAccessory.setContentHuggingPriority(.required, for: .horizontal)

        replaceField.placeholderString = "Replace with"
        replaceField.isBordered = false
        replaceField.isBezeled = false
        replaceField.drawsBackground = false
        replaceField.focusRingType = .none
        replaceField.font = DS.Text.custom(15)
        replaceField.delegate = self
        replaceField.setAccessibilityLabel("Replace with")
        let one = NSButton(title: "Replace", target: self, action: #selector(replaceCurrent))
        let all = NSButton(title: "All", target: self, action: #selector(replaceAll))
        // Actions, not options: a quiet capsule, never the stock square bezel.
        for button in [one, all] {
            button.isBordered = false
            button.font = DS.Text.body()
            button.wantsLayer = true
            button.layer?.cornerRadius = DS.Radius.control
            button.bindLayerBackground(DS.Color.scrimSoft)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        }
        all.toolTip = "Replace All (⌥Return)"
        replaceRow.orientation = .horizontal
        replaceRow.spacing = 6
        replaceRow.alignment = .centerY
        for view in [replaceField, one, all] as [NSView] { replaceRow.addArrangedSubview(view) }
        replaceField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        replaceRow.isHidden = true
        replaceRow.translatesAutoresizingMaskIntoConstraints = false
    }

    /// ⌘F, or ⌥⌘F with the replace row: find in the file on screen, starting from the
    /// selection when it's a short piece of one line.
    func presentFind(replace: Bool) {
        guard let index = activeTabIndex, openTabs[index].kind != .image else { return }
        if let selected = selectedEditorText(), let query = InFileFind.query(fromSelection: selected) { find.query = query }
        presentPalette(.find)
        // A preview or a sheet finds but doesn't replace: neither is edited here.
        let readOnly = findingInPreview || findingInSheet
        let replace = replace && !readOnly
        findReplaceToggle.isHidden = readOnly
        setReplaceRowShown((replace || findShowsReplace) && !readOnly)
        if replace { searchField.window?.makeFirstResponder(find.query.isEmpty ? searchField : replaceField) }
    }

    /// ⌘G / ⇧⌘G: the next or previous match, with the palette open or not.
    func findNext(forward: Bool) {
        guard !find.query.isEmpty, let index = activeTabIndex, openTabs[index].kind != .image else { presentFind(replace: false); return }
        if !(paletteIsOpen && searchMode == .find) { performFindSearch(select: false) }
        findStep(forward: forward)
        if !(paletteIsOpen && searchMode == .find) { clearFindMarks() }
    }

    /// ⌘E: the selection becomes what ⌘G looks for.
    func useSelectionForFind() {
        guard let selected = selectedEditorText(), !selected.isEmpty else { return }
        find.query = String(selected.prefix(200))
        if paletteIsOpen, searchMode == .find { searchField.stringValue = find.query; performFindSearch() }
    }

    /// Find runs over the Markdown preview's text while the preview is what's showing.
    private var findingInPreview: Bool {
        guard let index = activeTabIndex, openTabs.indices.contains(index) else { return false }
        return openTabs[index].kind == .text && openTabs[index].isPreviewingMarkdown
    }

    /// Find runs over a sheet's cells while a sheet is what's showing.
    private var findingInSheet: Bool {
        guard let index = activeTabIndex, openTabs.indices.contains(index) else { return false }
        return openTabs[index].kind == .csv
    }

    /// The sheet cell a match is in.
    private func findSheetCell(forMatch match: Int) -> CellRef? {
        guard findMatches.indices.contains(match) else { return nil }
        let location = findMatches[match].location
        var low = 0, high = findSheetLineStarts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if findSheetLineStarts[middle] <= location { low = middle } else { high = middle - 1 }
        }
        return findSheetCells.indices.contains(low) ? findSheetCells[low] : nil
    }

    /// Where Find starts and what it selects: the editor's selection, the preview's, or in a
    /// sheet the active cell (the current match itself when that's the cell it's in).
    private var findSelection: NSRange {
        get {
            if findingInSheet {
                guard let active = sheetView.anchor, !sheetView.header.isEmpty else { return NSRange(location: 0, length: 0) }
                if let current = findCurrent, findSheetCell(forMatch: current) == active { return findMatches[current] }
                let line = active.row * sheetView.header.count + active.column
                return NSRange(location: findSheetLineStarts.indices.contains(line) ? findSheetLineStarts[line] : 0, length: 0)
            }
            return findingInPreview ? markdownPreviewView.selectedRange() : editor.selectedRange
        }
        set {
            if findingInSheet { return }
            if findingInPreview { markdownPreviewView.setSelectedRange(newValue) } else { editor.selectedRange = newValue }
        }
    }

    private func selectedEditorText() -> String? {
        if findingInSheet { return nil }
        if findingInPreview {
            let range = markdownPreviewView.selectedRange()
            let text = markdownPreviewView.string as NSString
            return range.length > 0 && NSMaxRange(range) <= text.length ? text.substring(with: range) : nil
        }
        let range = editor.selectedRange
        guard range.length > 0, let text = editor.document?.text, NSMaxRange(range) <= text.length else { return nil }
        return text.substring(with: range)
    }

    @objc private func findOptionChanged() {
        find.options.caseSensitive = findCaseButton.state == .on
        find.options.wholeWord = findWordButton.state == .on
        find.options.regularExpression = findRegexButton.state == .on
        performFindSearch()
        searchField.window?.makeFirstResponder(searchField)
    }

    @objc private func toggleReplaceRow() {
        setReplaceRowShown(!findShowsReplace)
        if findShowsReplace { searchField.window?.makeFirstResponder(replaceField) }
    }

    private func setReplaceRowShown(_ shown: Bool) {
        findShowsReplace = shown
        findReplaceToggle.state = shown ? .on : .off
        replaceRow.isHidden = !shown
        replaceRowHeight?.constant = shown ? Self.replaceRowHeightValue : 0
        if paletteIsOpen { showQuickOpenPanel() }
    }

    /// Every match, marked in the editor and listed; the one at or after the caret is current.
    private func performFindSearch(select: Bool = true) {
        guard let index = activeTabIndex, openTabs.indices.contains(index), openTabs[index].kind != .image else { return }
        if paletteIsOpen, searchMode == .find { find.query = searchField.stringValue }
        findCaseButton.state = find.options.caseSensitive ? .on : .off
        findWordButton.state = find.options.wholeWord ? .on : .off
        findRegexButton.state = find.options.regularExpression ? .on : .off
        if findingInSheet {
            // One line per cell; a cell's own line breaks become spaces so a match stays in it.
            let cells = sheetView.findableCells()
            findSheetCells = cells.map(\.cell)
            findSheetLineStarts = []
            findSheetLineStarts.reserveCapacity(cells.count)
            let text = NSMutableString()
            for (offset, cell) in cells.enumerated() {
                if offset > 0 { text.append("\n") }
                findSheetLineStarts.append(text.length)
                text.append(cell.text.replacingOccurrences(of: "\n", with: " "))
            }
            findText = text
        } else {
            findText = findingInPreview ? (markdownPreviewView.string as NSString) : (openTabs[index].document.string as NSString)
        }
        let result = find.matches(in: findText)
        findMatches = result.ranges
        if findingInSheet {
            // Cells are lines here; a match that crosses a line break would span two cells.
            let text = findText
            findMatches = findMatches.filter { text.rangeOfCharacter(from: .newlines, options: [], range: $0).location == NSNotFound }
        }
        findTruncated = result.truncated
        let lines = Self.lineNumbers(of: findMatches[...], in: findText)
        findRows = []
        findRowOfMatch = []
        for (index, line) in lines.enumerated() {
            if findRows.last?.line != line { findRows.append((index, line)) }
            findRowOfMatch.append(findRows.count - 1)
        }
        findCurrent = InFileFind.index(of: findMatches, from: findSelection.location, forward: true)
        markFindMatches()
        updateFindCount()
        guard paletteIsOpen, searchMode == .find else { return }
        resultsTable.reloadData()
        // Sized (and the editor raised above it) before revealing, so the match lands above it.
        showQuickOpenPanel()
        if let current = findCurrent, select {
            selectFindRow(forMatch: current)
            revealFindMatch(current)
        }
    }

    private func updateFindCount() {
        if let error = find.expressionError() {
            findCountLabel.stringValue = error
        } else if find.query.isEmpty {
            findCountLabel.stringValue = ""
        } else if findMatches.isEmpty {
            findCountLabel.stringValue = "No matches"
        } else {
            let total = findTruncated ? "\(InFileFind.matchLimit.formatted())+" : findMatches.count.formatted()
            findCountLabel.stringValue = findCurrent.map { "\(($0 + 1).formatted()) of \(total)" } ?? total
        }
    }

    private func markFindMatches() {
        if findingInSheet {
            sheetView.setFindMarks(Set(findMatches.indices.compactMap(findSheetCell(forMatch:))), current: findCurrent.flatMap(findSheetCell(forMatch:)))
            return
        }
        let all = NSColor.controlAccentColor.withAlphaComponent(0.2)
        if findingInPreview, let layout = markdownPreviewView.layoutManager {
            let whole = NSRange(location: 0, length: (markdownPreviewView.string as NSString).length)
            layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: whole)
            for range in findMatches where NSMaxRange(range) <= whole.length { layout.addTemporaryAttribute(.backgroundColor, value: all, forCharacterRange: range) }
            if let current = findCurrent, findMatches.indices.contains(current), NSMaxRange(findMatches[current]) <= whole.length {
                layout.addTemporaryAttribute(.backgroundColor, value: NSColor.findHighlightColor.withAlphaComponent(0.7), forCharacterRange: findMatches[current])
            }
            return
        }
        guard let document = editor.document else { return }
        document.setDecorations(.findMatch, findMatches.map { ($0, all) })
        let current = findCurrent.flatMap { findMatches.indices.contains($0) ? findMatches[$0] : nil }
        document.setDecorations(.findCurrent, current.map { [($0, NSColor.findHighlightColor.withAlphaComponent(0.7))] } ?? [])
    }

    /// Stepping: only the current match's mark moves; the rest stay as they are (re-marking all
    /// of them was most of a step's cost in a file with thousands).
    private func markCurrentFindMatch(previous: Int?) {
        if findingInSheet { markFindMatches(); return }
        let current = findCurrent.flatMap { findMatches.indices.contains($0) ? findMatches[$0] : nil }
        let currentColor = NSColor.findHighlightColor.withAlphaComponent(0.7)
        if findingInPreview, let layout = markdownPreviewView.layoutManager {
            let length = (markdownPreviewView.string as NSString).length
            if let previous, findMatches.indices.contains(previous), NSMaxRange(findMatches[previous]) <= length {
                layout.addTemporaryAttribute(.backgroundColor, value: NSColor.controlAccentColor.withAlphaComponent(0.2), forCharacterRange: findMatches[previous])
            }
            if let current, NSMaxRange(current) <= length { layout.addTemporaryAttribute(.backgroundColor, value: currentColor, forCharacterRange: current) }
            return
        }
        editor.document?.setDecorations(.findCurrent, current.map { [($0, currentColor)] } ?? [])
    }

    private func clearFindMarks() {
        sheetView.setFindMarks([], current: nil)
        if let layout = markdownPreviewView.layoutManager {
            layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: (markdownPreviewView.string as NSString).length))
        }
        editor.document?.setDecorations(.findMatch, [])
        editor.document?.setDecorations(.findCurrent, [])
    }

    private func findStep(forward: Bool) {
        guard !findMatches.isEmpty else { return }
        let from: Int
        let selection = findSelection
        if let current = findCurrent, selection == findMatches[current] {
            from = forward ? NSMaxRange(findMatches[current]) : findMatches[current].location
        } else {
            from = selection.location
        }
        guard let next = InFileFind.index(of: findMatches, from: from, forward: forward) else { return }
        showFindMatch(next)
        selectFindRow(forMatch: next)
    }

    private func showFindMatch(_ index: Int) {
        guard findMatches.indices.contains(index) else { return }
        let previous = findCurrent
        findCurrent = index
        markCurrentFindMatch(previous: previous)
        updateFindCount()
        revealFindMatch(index)
    }

    private func revealFindMatch(_ index: Int) {
        if findingInSheet {
            if let cell = findSheetCell(forMatch: index) { sheetView.select(cell) }
            return
        }
        let range = findMatches[index]
        if findingInPreview {
            guard NSMaxRange(range) <= (markdownPreviewView.string as NSString).length else { return }
            markdownPreviewView.setSelectedRange(range)
            markdownPreviewView.scrollRangeToVisible(range)
            return
        }
        editor.selectedRange = range
        editor.scrollRangeToVisible(range)
    }

    /// A listed line: its number (one-based) and its text, trimmed.
    private func findLine(at row: Int) -> (Int, String) {
        let range = findMatches[findRows[row].firstMatch]
        let line = findText.lineRange(for: NSRange(location: range.location, length: 0))
        let text = findText.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
        return (findRows[row].line, String(text.prefix(200)))
    }

    /// Selects the row of a match's line in the list.
    private func selectFindRow(forMatch index: Int) {
        guard paletteIsOpen, searchMode == .find, findRowOfMatch.indices.contains(index) else { return }
        let row = findRowOfMatch[index]
        guard row < resultCount else { return }
        resultsTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        resultsTable.scrollRowToVisible(row)
    }

    /// Line numbers for sorted ranges, in one pass over the text up to the last of them.
    static func lineNumbers(of ranges: ArraySlice<NSRange>, in text: NSString) -> [Int] {
        var numbers: [Int] = []
        numbers.reserveCapacity(ranges.count)
        var line = 1, position = 0
        var buffer = [unichar](repeating: 0, count: 4096)
        for range in ranges {
            while position < range.location {
                let count = min(buffer.count, range.location - position)
                text.getCharacters(&buffer, range: NSRange(location: position, length: count))
                for i in 0..<count where buffer[i] == 10 { line += 1 }
                position += count
            }
            numbers.append(line)
        }
        return numbers
    }

    private func replaceFieldCommand(_ selector: Selector, textView: NSTextView) -> Bool {
        if textView.hasMarkedText() { return false }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.option) == true { replaceAll() } else { replaceCurrent() }
            return true
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            replaceAll()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            dismissQuickOpen()
            return true
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            searchField.window?.makeFirstResponder(searchField)
            return true
        default:
            return false
        }
    }

    /// Replaces the match Find is on and moves to the next.
    @objc private func replaceCurrent() {
        guard !findingInPreview else { return }
        guard let current = findCurrent, findMatches.indices.contains(current) else { findStep(forward: true); return }
        let range = findMatches[current]
        let replacement = find.replacement(for: range, in: findText, template: replaceField.stringValue)
        editor.applyEdits([(range, replacement)])
        editor.selectedRange = NSRange(location: range.location + (replacement as NSString).length, length: 0)
        performFindSearch(select: false)
        findStep(forward: true)
    }

    /// Every match, one undo step.
    @objc private func replaceAll() {
        guard !findingInPreview else { return }
        let edits = find.replaceAllEdits(in: findText, template: replaceField.stringValue)
        guard !edits.isEmpty else { return }
        editor.applyEdits(edits)
        performFindSearch(select: false)
        findCountLabel.stringValue = "Replaced \(edits.count.formatted())"
    }

    /// While Find is open, the editor scrolls as if its bottom were the palette's top, so the
    /// match it's on is never under it.
    private func raiseEditorAbovePalette(_ paletteHeight: CGFloat) {
        let scroll = findingInSheet ? csvScroll : findingInPreview ? markdownPreviewScroll : editorScroll
        if insetBeforeFind == nil || insetScroll !== scroll {
            restoreFindInset()
            insetBeforeFind = scroll.contentInsets.bottom
            insetScroll = scroll
        }
        // The palette sits above whatever already covered the bottom (the stage bar).
        scroll.contentInsets.bottom = (insetBeforeFind ?? 0) + paletteHeight + DS.Spacing.l
    }

    private func restoreFindInset() {
        if let inset = insetBeforeFind { (insetScroll ?? editorScroll).contentInsets.bottom = inset }
        insetBeforeFind = nil
        insetScroll = nil
    }

    private func endFind() {
        clearFindMarks()
        restoreFindInset()
        findReplaceToggle.isHidden = false
        findAccessory.isHidden = true
        setReplaceRowShown(false)
    }

    // MARK: - File explorer


    @objc func toggleFileExplorer() {
        guard let window = view.window else { return }
        explorer.toggle(in: window)
    }

    func showFileExplorer() {
        guard let window = view.window, !explorer.isShown else { return }
        explorer.show(in: window)
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
        var map = HeronDefaults.store.dictionary(forKey: lastFilesByProjectKey) as? [String: String] ?? [:]
        map[compositeMemoryKey(for: project)] = fileURL.path
        HeronDefaults.store.set(map, forKey: lastFilesByProjectKey)
    }

    private func lastFile(forProject project: URL) -> URL? {
        guard let map = HeronDefaults.store.dictionary(forKey: lastFilesByProjectKey) as? [String: String],
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
        guard soleFile == nil, !tabMemorySuspended else { return }
        var map = HeronDefaults.store.dictionary(forKey: openTabsByProjectKey) as? [String: [String]] ?? [:]
        let paths = openTabs.filter { !$0.isUntitled }.map(\.url.path)
        if paths.isEmpty {
            map.removeValue(forKey: compositeMemoryKey(for: project))
        } else {
            map[compositeMemoryKey(for: project)] = paths
        }
        HeronDefaults.store.set(map, forKey: openTabsByProjectKey)
    }

    private func rememberedOpenTabs(forProject project: URL) -> [URL] {
        guard let map = HeronDefaults.store.dictionary(forKey: openTabsByProjectKey) as? [String: [String]],
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
        openTabs[index].knownDiskStamp = diskStamp(of: url)
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
        var map = HeronDefaults.store.dictionary(forKey: lastFilesByProjectKey) as? [String: String] ?? [:]
        map.removeValue(forKey: "\(projectURL.path)#\(trackKey ?? "")")
        HeronDefaults.store.set(map, forKey: lastFilesByProjectKey)
    }

    private func rememberRecentProject(_ project: URL) {
        var recents = HeronDefaults.store.stringArray(forKey: recentProjectsKey) ?? []
        recents.removeAll { $0 == project.path }
        recents.insert(project.path, at: 0)
        if recents.count > maxRecentProjects { recents.removeLast(recents.count - maxRecentProjects) }
        HeronDefaults.store.set(recents, forKey: recentProjectsKey)
    }

    private func recentProjects() -> [URL] {
        let recents = HeronDefaults.store.stringArray(forKey: recentProjectsKey) ?? []
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
    /// Where a project's sheets go: the Editor's window, or the window it belongs to while
    /// another stage is shown and it's out of it. Asked from the switcher in Terminal, Open
    /// Project did nothing (the owner, 2026-11-05).
    private var sheetWindow: NSWindow? { view.window ?? NSApp.mainWindow }
    /// Set by the shell: moves the window to another project, keeping this one open.
    var onSwitchProject: ((URL) -> Void)?

    @objc private func openProject() {
        confirmAllUnsavedChanges { [weak self] proceed in
            guard let self, proceed, let window = self.sheetWindow else { return }
            let panel = NSOpenPanel()
            panel.message = "Choose a project to open in Side"
            panel.prompt = "Open project"
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.beginSheetModal(for: window) { [weak self] response in
                guard let self, response == .OK, let url = panel.url else { return }
                // With a project open, opening another is a switch: the one left stays open in
                // the background (project switching), its terminals and agents still going.
                if self.projectURL != nil, let switchProject = self.onSwitchProject {
                    switchProject(url)
                    return
                }
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
            guard let self, proceed, let window = self.sheetWindow else { return }
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
                // Off the main thread, with its first commit, so a track can branch from it
                // (2026-09-30 audit, H10: New Project then New Track failed).
                DispatchQueue.global(qos: .userInitiated).async {
                    let initResult = GitPaths.runGit(["init"], cwd: url.path)
                    let commit = initResult.success
                        ? TrackStore.makeInitialCommit(cwd: url.path, runGit: { GitPaths.runGit($0, cwd: $1) }) : initResult
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        guard initResult.success, commit.success else {
                            self.showAlert(title: "Couldn't initialize git", message: initResult.success ? commit.output : initResult.output, window: window)
                            return
                        }
                        self.closeAllTabsImmediately()
                        self.loadProject(at: url)
                    }
                }
            }
        }
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
            HeronDefaults.store.set(url.path, forKey: lastProjectKey)
            rememberRecentProject(url)
        }
        LaunchSignposts.begin("projectOpened")
        onProjectOpened?(url)
        LaunchSignposts.end("projectOpened")
        LaunchSignposts.begin("reindexAndRestore")
        reindexAndRestoreLastFile()
        LaunchSignposts.end("reindexAndRestore")
        // After the last session's tabs are back: unsaved work from a session that ended
        // without saving it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.offerRecovery(for: url) }
    }

    /// Tears down and recreates `lspManager` pointed at `root`, and points every other
    /// file-touching operation (indexing, explorer, diff, formatter) at it too. Cheap to call —
    /// `LSPManager` only spawns servers lazily on first file open, so retargeting mid-session
    /// (a track switch landing on a different worktree) does no real work until a file is opened.
    private func retarget(to root: URL) {
        lspManager = makeLanguageServers(root: root)
        focusedRoot = root
        explorer.setRoot(root)
        debugger.projectChanged(root)
        searchField.placeholderString = "Indexing \(root.lastPathComponent)…"
        projectWatcher = ProjectWatcher(root: root) { [weak self] urls in self?.filesChangedOnDisk(urls) }
    }

    /// A dark editor theme in light appearance (or the other way round): Make's own chrome over
    /// the editor (the tab strip, Ln/Col, the language chip) takes the theme's appearance, so its
    /// labels stay legible on the theme's background.
    @objc private func matchChromeToEditorTheme() {
        let appearance = EditorThemes.chromeAppearance()
        view.appearance = appearance
        topRowContent?.appearance = appearance
        // With no file open (or a banner over the editor) Side's canvas showed, in the system's
        // appearance, under labels in the theme's.
        chromeFill?.bindLayerBackground(Self.editorBackground)
        // Layer colors bound to tokens resolve in the view's appearance, which just changed.
        DS.LayerBindings.reapplyAll()
        minimap.backgroundColor = Self.editorBackground
        imageScroll.backgroundColor = Self.editorBackground
        csvScroll.backgroundColor = Self.editorBackground
        markdownPreviewView.backgroundColor = Self.editorBackground
        markdownPreviewScroll.backgroundColor = Self.editorBackground
    }

    /// Settings → Languages changed: the servers start again as now chosen, and every open
    /// file is announced to its (possibly new) server.
    @objc private func languageSettingsChanged() {
        guard let root = focusedRoot else { return }
        lspManager = makeLanguageServers(root: root)
        for tab in openTabs where tab.kind == .text && !tab.isUntitled { announceToLanguageServer(tab.url) }
        updateLSPIndicator()
    }

    private func makeLanguageServers(root: URL) -> LSPManager {
        refreshTrustBanner(root)
        lspManager?.prepareForClose()
        let manager = LSPManager(projectRoot: root)
        manager.onDiagnostics = { [weak self] fileURL, diagnostics in
            guard let self else { return }
            self.serverDiagnostics[fileURL] = diagnostics
            let diagnostics = diagnostics + (self.buildDiagnostics[fileURL] ?? [])
            self.applyDiagnostics(diagnostics, to: fileURL)
            self.recordProblems(diagnostics, for: fileURL)
            // Also published for agents' read_diagnostics (Side's MCP server): an agent that can read the
            // errors its own edit just caused closes the loop inside one turn, instead of
            // waiting for the user to notice and paste them back.
            self.publishDiagnosticsForAgent(diagnostics, fileURL: fileURL, root: root)
        }
        manager.onAvailabilityChanged = { [weak self] in self?.updateLSPIndicator() }
        manager.onApplyEdit = { [weak self] edit in self?.applyWorkspaceEdit(edit) ?? false }
        return manager
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
        guard !tab.isUntitled, !tab.isSaving else { return }
        guard let onDisk = diskStamp(of: tab.url) else { return }
        if let known = tab.knownDiskStamp, onDisk == known { return }
        if tab.kind != .text {
            reloadReadOnlyTab(url: tab.url)
            return
        }
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
        openTabs[index].knownDiskStamp = diskStamp(of: tab.url)
        if isActive {
            dirty = false
            let clamped = NSRange(location: min(selection.location, tab.document.length), length: 0)
            editor.selectedRange = clamped
            externalChangeBanner.isHidden = true
            applyTopInsets()
            editor.invalidateGutter()
            refreshGitDiffMarks()
        }
        rebuildTabBar()
        return true
    }

    /// A sheet or an image can't be edited here, so a change on disk always reloads it; the
    /// sheet keeps its place (the sheet shown, the sort, the scroll). A read that fails, say a
    /// file caught mid-write, leaves what's shown and the stamp alone, so the next event retries.
    private func reloadReadOnlyTab(url: URL) {
        let isImage = Self.imageExtensions.contains(url.pathExtension.lowercased())
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let stamp = DiskStamp(of: url)
            let image = isImage ? NSImage(contentsOf: url) : nil
            let sheets = isImage ? nil : Self.readSheets(url)
            DispatchQueue.main.async {
                guard let self, let index = self.openTabs.firstIndex(where: { $0.url == url }) else { return }
                if isImage {
                    guard let image else { return }
                    self.openTabs[index].cachedImage = image
                } else {
                    guard let sheets else { return }
                    self.openTabs[index].sheets = sheets
                }
                self.openTabs[index].knownDiskStamp = stamp
                guard self.activeTabIndex == index else { return }
                if isImage {
                    self.imageView.image = image
                    self.imageView.frame = NSRect(origin: .zero, size: image?.size ?? .zero)
                } else if let sheets, self.sheetView.sheets != sheets {
                    self.sheetView.reload(sheets)
                }
            }
        }
    }

    /// A sheet file's sheets: an Excel workbook's, or one from delimited text.
    nonisolated static func readSheets(_ url: URL) -> [Sheet]? {
        let ext = url.pathExtension.lowercased()
        if ext == "xlsx" {
            guard let sheets = try? XLSXReader.read(url), !sheets.isEmpty else { return nil }
            return sheets
        }
        guard let data = try? Data(contentsOf: url), let text = TextFileCodec.decode(data)?.text else { return nil }
        let rows = CSVParser.parse(text, delimiter: CSVParser.delimiter(forExtension: ext, text: text))
        return [Sheet(name: url.deletingPathExtension().lastPathComponent, rows: rows)]
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

    private func configureTrustBanner() {
        trustBanner.wantsLayer = true
        trustBanner.bindLayerBackground(DS.Color.overlay)
        trustBanner.translatesAutoresizingMaskIntoConstraints = false
        trustLabel.font = DS.Text.caption()
        trustLabel.textColor = .secondaryLabelColor
        trustLabel.lineBreakMode = .byTruncatingTail
        let trust = NSButton(title: "Trust Project", target: self, action: #selector(trustProject))
        let later = NSButton(title: "Not Now", target: self, action: #selector(deferTrust))
        for button in [trust, later] { button.bezelStyle = .rounded; button.controlSize = .small; button.font = DS.Text.caption() }
        let shield = NSImageView(image: NSImage(systemSymbolName: "checkmark.shield", accessibilityDescription: nil) ?? NSImage())
        shield.contentTintColor = .secondaryLabelColor
        let row = NSStackView(views: [shield, trustLabel, NSView(), trust, later])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = DS.Spacing.s
        row.edgeInsets = NSEdgeInsets(top: 0, left: DS.Spacing.m, bottom: 0, right: DS.Spacing.m)
        row.translatesAutoresizingMaskIntoConstraints = false
        trustBanner.addSubview(row)
        view.addSubview(trustBanner)
        let height = trustBanner.heightAnchor.constraint(equalToConstant: 0)
        trustBannerHeight = height
        let top = trustBanner.topAnchor.constraint(equalTo: view.topAnchor, constant: topObstruction)
        trustBannerTop = top
        NSLayoutConstraint.activate([
            top,
            trustBanner.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            trustBanner.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            height,
            row.leadingAnchor.constraint(equalTo: trustBanner.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trustBanner.trailingAnchor),
            row.topAnchor.constraint(equalTo: trustBanner.topAnchor),
            row.bottomAnchor.constraint(equalTo: trustBanner.bottomAnchor),
        ])
        // A project loaded before this ran has its answer already.
        if let root = focusedRoot { refreshTrustBanner(root) }
    }

    /// Shown while the project isn't trusted and something of its own would run.
    private func refreshTrustBanner(_ root: URL) {
        let code = ProjectTrust.projectCode(in: root)
        let show = !code.isEmpty && !ProjectTrust.isTrusted(root) && !trustDeferred.contains(ProjectTrust.projectKey(root))
        if show {
            let list = code.count > 1 ? code.dropLast().joined(separator: ", ") + " and " + code.last! : code[0]
            trustLabel.stringValue = "Side isn\u{2019}t running this project\u{2019}s own code (\(list)) until you trust it."
            trustLabel.toolTip = "Opening and saving files in a project can run code it contains. Until you trust it, Side uses the global TypeScript, formats only with a global Prettier and a plain config, and turns off Rust build scripts and macros."
        }
        let wasHidden = trustBanner.isHidden
        trustBanner.isHidden = !show
        trustBannerHeight?.constant = show ? 28 : 0
        applyTopInsets()
        if show, wasHidden { Spoken.announce(trustLabel.stringValue) }
    }

    @objc private func trustProject() {
        guard let root = focusedRoot else { return }
        ProjectTrust.trust(root)
    }

    @objc private func deferTrust() {
        guard let root = focusedRoot else { return }
        trustDeferred.insert(ProjectTrust.projectKey(root))
        refreshTrustBanner(root)
    }

    /// Trusted (here or in another window): the servers start again, with the project's own tools.
    @objc private func projectTrustChanged(_ note: Notification) {
        guard let root = focusedRoot, note.userInfo?["project"] as? String == ProjectTrust.projectKey(root) else { return }
        refreshTrustBanner(root)
        languageSettingsChanged()
    }

    var trustBannerTextForTesting: String? { trustBanner.isHidden ? nil : trustLabel.stringValue }
    /// The banner's distance from the top of Make's view, and the editor's top inset.
    var trustBannerLayoutForTesting: (top: CGFloat, editorInset: CGFloat, detail: String) {
        view.layoutSubtreeIfNeeded()
        let frame = trustBanner.frame
        let top = view.isFlipped ? frame.minY : view.bounds.maxY - frame.maxY
        return (top, editorScroll.contentInsets.top, "view \(view.frame), flipped \(view.isFlipped), banner \(frame)")
    }

    private func configureExternalChangeBanner() {
        externalChangeBanner.wantsLayer = true
        externalChangeBanner.bindLayerBackground(DS.Color.overlay)
        externalChangeBanner.translatesAutoresizingMaskIntoConstraints = false
        externalChangeBanner.isHidden = true
        applyTopInsets()
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
            externalChangeBanner.topAnchor.constraint(equalTo: trustBanner.bottomAnchor),
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
        applyTopInsets()
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
        applyTopInsets()
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
                self.tabMemorySuspended = false
                self.allFiles = indexed
                self.searchField.placeholderString = "Find a file in \(root.lastPathComponent)"
                // Every remembered tab, in order, filtered against what the index actually
                // found — a branch switch or a deletion can legitimately remove a file, and a
                // missing one should be dropped silently rather than reported.
                if let sole = self.soleFile {
                    self.open(sole)
                    return
                }
                // Compared resolved: the index can name a file by another spelling of the same
                // path (/tmp and /private/tmp), and the tab was dropped as missing.
                let indexedPaths = Set(indexed.map { $0.url.resolvingSymlinksInPath().path })
                let remembered = self.rememberedOpenTabs(forProject: memoryRoot)
                    .filter { indexedPaths.contains($0.resolvingSymlinksInPath().path) }
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
                let stamp = DiskStamp(of: url)
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
                    var tab = OpenTab(url: url, kind: .image, document: self.editor.makeDocument(""), undoManager: Self.makeUndoManager(), dirty: false, isUntitled: false, knownDiskStamp: stamp)
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

        // An Excel workbook: its sheets' values, read-only, in the sheet view.
        if ext == "xlsx" {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let stamp = DiskStamp(of: url)
                let sheets = Self.readSheets(url)
                DispatchQueue.main.async {
                    guard let self else { completion?(); return }
                    guard let sheets, !sheets.isEmpty else {
                        self.showAlert(title: "Couldn't open workbook", message: "\(url.lastPathComponent) couldn't be read as an Excel workbook.", window: window)
                        completion?()
                        return
                    }
                    if let existingIndex = self.openTabs.firstIndex(where: { $0.url == url }) {
                        self.activeTabIndex = existingIndex
                        self.loadActiveTabIntoEditor()
                        self.finishOpenUI(url: url)
                        completion?()
                        return
                    }
                    var tab = OpenTab(url: url, kind: .csv, document: self.editor.makeDocument(""), undoManager: Self.makeUndoManager(), dirty: false, isUntitled: false, knownDiskStamp: stamp)
                    tab.sheets = sheets
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
            // Before the read: a change made during it then still reads as a change.
            let stamp = DiskStamp(of: url)
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
            let isCSV = ["csv", "tsv", "tab"].contains(ext)
            let rows = isCSV ? CSVParser.parse(source, delimiter: CSVParser.delimiter(forExtension: ext, text: source)) : []
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
                var tab = OpenTab(url: url, kind: isCSV ? .csv : .text, document: self.editor.makeDocument(source), undoManager: Self.makeUndoManager(), dirty: false, isUntitled: false, knownDiskStamp: stamp)
                tab.sheets = isCSV ? [Sheet(name: url.deletingPathExtension().lastPathComponent, rows: rows)] : []
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
                        self.announceToLanguageServer(url)
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

    /// Tells the file's server it's open, and sends it every edit from then on: an edit reaches
    /// the manager as it happens (nothing copied), and goes out a moment later as just the edit.
    private func announceToLanguageServer(_ url: URL) {
        guard let tab = openTabs.first(where: { $0.url == url && $0.kind == .text }) else { return }
        let document = tab.document
        document.onEdits = { [weak self, weak document] edits in
            guard let self, let document, let tab = self.openTabs.first(where: { $0.document === document }) else { return }
            self.lspManager?.edited(url: tab.url, edits: edits, text: document.rope)
            self.debugger.edited(url: tab.url, edits: edits, text: document.rope)
        }
        lspManager?.opened(url: url, text: document.rope)
    }
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
                self.announceToLanguageServer(url)
            }
        }
    }

    private func finishOpenUI(url: URL) {
        if paletteIsOpen { searchField.stringValue = "" }
        if let projectURL { rememberLastFile(url, forProject: projectURL) }
        hideQuickOpenPanel()
        focusShownContent()
    }

    /// Focus on what the active tab shows: the editor, the Markdown preview, the image or the
    /// table. Focusing the editor while it was hidden left focus on the window, and ⌘W and the
    /// other menu commands stopped reaching Make (2026-10-23, the owner: images wouldn't close).
    private func focusShownContent() {
        guard let index = activeTabIndex, openTabs.indices.contains(index) else { return editor.focus() }
        switch openTabs[index].kind {
        case .text where openTabs[index].isPreviewingMarkdown: view.window?.makeFirstResponder(markdownPreviewView)
        case .text: editor.focus()
        case .image: view.window?.makeFirstResponder(imageView)
        case .csv: view.window?.makeFirstResponder(sheetView.table)
        }
    }

    private func showAlert(title: String, message: String, window: NSWindow, style: NSAlert.Style = .warning) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    private func diskStamp(of url: URL) -> DiskStamp? { DiskStamp(of: url) }

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
        endCompletion()
        if tab.kind == .text {
            editor.setLanguage(lineComment: LineComments.token(forExtension: tab.url.languageExtension),
                               indentUnit: Self.indentUnit(in: tab.document.text, near: NSRange(location: 0, length: 0)))
        }
        hideSignatureHelp()
        endHover()
        debugger.refreshEditor()
        DispatchQueue.main.async { [weak self] in self?.updateCaretPosition() }
        if tab.hasExternalChange { showExternalChangeBanner(for: tab.url) } else { externalChangeBanner.isHidden = true }
        applyTopInsets()

        let showingMarkdownPreview = tab.kind == .text && tab.isPreviewingMarkdown
        editorContainer.isHidden = tab.kind != .text || showingMarkdownPreview
        applyMinimapVisibility()
        gutter.isHidden = tab.kind != .text || showingMarkdownPreview
        imageScroll.isHidden = tab.kind != .image
        sheetView.isHidden = tab.kind != .csv
        if markdownPreviewScroll.isHidden == showingMarkdownPreview {
            markdownPreviewScroll.isHidden = !showingMarkdownPreview
            onScrollUnderTopRowChange?()
        }

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
            applyLiveMarkdown()
        case .image:
            editor.isEditable = false
            imageView.image = tab.cachedImage
            if let size = tab.cachedImage?.size { imageView.frame = NSRect(origin: .zero, size: size) }
            view.window?.makeFirstResponder(imageView)  // see focusShownContent
        case .csv:
            editor.isEditable = false
            if sheetView.sheets != tab.sheets { sheetView.show(tab.sheets) }
            view.window?.makeFirstResponder(sheetView.table)
        }

        dirty = tab.dirty
        rebuildTabBar()
        updateLSPIndicator()
        updateShortcutContext()
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
        if isWriting { applyWriterAids() }
    }

    /// The active file's language server as a caption and a dot: ready, starting (the working
    /// ring), stopped, or not installed — the last one clickable to install. Hidden for files
    /// with no server, and for a missing server the user can't install from here (sourcekit-lsp).
    /// "Ln 12, Col 5", one-based, columns in characters with a tab counted to the next stop;
    /// with a selection, how many characters it holds; with several carets, how many.
    private func updateCaretPosition() {
        guard let index = activeTabIndex, openTabs.indices.contains(index), openTabs[index].kind == .text,
              !openTabs[index].isPreviewingMarkdown else { caretPositionButton.isHidden = true; return }
        let document = openTabs[index].document
        let selection = editor.selectedRange
        let rope = document.rope
        let caret = min(NSMaxRange(selection), rope.utf16Count)
        let position = rope.position(of: caret)
        let lineStart = caret - position.column
        let prefix = (document.text as NSString).substring(with: NSRange(location: lineStart, length: position.column))
        var column = 0
        for character in prefix { column = character == "\t" ? (column / 4 + 1) * 4 : column + 1 }
        var text = "Ln \(position.line + 1), Col \(column + 1)"
        if selection.length > 0 { text += " (\(selection.length) selected)" }
        caretPositionButton.attributedTitle = NSAttributedString(string: text, attributes: [.font: DS.Text.caption(), .foregroundColor: NSColor.secondaryLabelColor])
        caretPositionButton.setAccessibilityLabel("Line \(position.line + 1), column \(column + 1). Go to Line")
        caretPositionButton.isHidden = false
    }

    private func updateLSPIndicator() {
        guard let index = activeTabIndex, openTabs.indices.contains(index), openTabs[index].kind == .text,
              let entry = LanguageServerRegistry.entry(forExtension: openTabs[index].url.languageExtension),
              let state = lspManager?.serverState(forExtension: openTabs[index].url.languageExtension), state != .none,
              state != .unavailable || (entry.install != nil && entry.asksToInstall) else {
            lspStatusButton.isHidden = true
            return
        }
        let language = LanguageSettings.preset(forExtension: openTabs[index].url.languageExtension)?.name.components(separatedBy: " and ").first
            ?? LSPStatusChip.languageName(entry.languageId)
        switch state {
        case .running: lspStatusButton.set(state: .verified, text: language, clickable: false, tip: "\(language) language server running")
        case .starting: lspStatusButton.set(state: .working, text: "\(language) \u{00B7} starting", clickable: false, tip: "Starting the \(language) language server")
        case .stopped: lspStatusButton.set(state: .failed, text: "\(language) \u{00B7} stopped", clickable: false, tip: "The \(language) language server stopped \u{2014} it restarts on the next edit")
        case .failed: lspStatusButton.set(state: .failed, text: "\(language) \u{00B7} didn't start", clickable: false,
                                          tip: "\(entry.binaryName) exited as it started. Try it in Terminal, or choose another server in Settings \u{2192} Languages.")
        case .unavailable: lspStatusButton.set(state: .needsYou, text: "\(language) \u{00B7} not installed", clickable: true, tip: "\(language) language server not installed \u{2014} click to install")
        case .none: break
        }
        lspStatusButton.isHidden = false
    }

    @objc private func showLSPStatusPopover() {
        guard let index = activeTabIndex, openTabs.indices.contains(index),
              let entry = LanguageServerRegistry.entry(forExtension: openTabs[index].url.languageExtension) else { return }
        let tabURL = openTabs[index].url
        let content = LSPInstallPopoverViewController(entry: entry) { [weak self] in
            guard let self else { return }
            // Re-sends didOpen with the buffer's current in-memory content — this *is* the
            // activation, not just a cache clear, so there's nothing left for the user to do
            // (no need to actually close/reopen the tab) despite the file never having left
            // the editor.
            self.lspManager?.retryAfterInstall(binaryName: entry.binaryName)
            if let currentIndex = self.activeTabIndex, self.openTabs.indices.contains(currentIndex), self.openTabs[currentIndex].url == tabURL {
                self.announceToLanguageServer(tabURL)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in self?.lspInstallPopover?.close() }
        }
        let popover = NSPopover()
        popover.contentViewController = content
        popover.behavior = .transient
        lspInstallPopover = popover
        popover.show(relativeTo: lspStatusButton.bounds, of: lspStatusButton, preferredEdge: .maxY)
    }

    // MARK: - Markdown preview

    func toggleMarkdownPreviewForTesting() { toggleMarkdownPreview() }
    var markdownPreviewForTesting: NSTextView { markdownPreviewView }
    var findReplaceShownForTesting: Bool { findShowsReplace && !findReplaceToggle.isHidden }

    /// What scrolls under the top row changed (the preview came or went): the shell re-watches.
    var onScrollUnderTopRowChange: (() -> Void)?

    @objc private func toggleMarkdownPreview() {
        guard let index = activeTabIndex, openTabs.indices.contains(index),
              openTabs[index].kind == .text, openTabs[index].url.pathExtension.lowercased() == "md" else { return }
        openTabs[index].isPreviewingMarkdown.toggle()
        DS.Motion.crossfade(view, duration: DS.Motion.glanceDuration)
        loadActiveTabIntoEditor()
        // Find follows to what's showing: the preview's text or the file's.
        if paletteIsOpen, searchMode == .find {
            clearFindMarks()
            findReplaceToggle.isHidden = findingInPreview
            if findingInPreview { setReplaceRowShown(false) }
            performFindSearch()
        }
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
        markdownPreviewView.textStorage?.setAttributedString(MarkdownPreview.render(text, style: style, folder: tab.isUntitled ? nil : tab.url.deletingLastPathComponent()))
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

    @objc private func jumpToDefinition() {
        guard let index = activeTabIndex else { return }
        performJumpToDefinition(at: editor.selectedRange.location, tabIndex: index)
    }

    private func performJumpToDefinition(at characterIndex: Int, tabIndex: Int) {
        guard openTabs.indices.contains(tabIndex), openTabs[tabIndex].kind == .text, let lspManager else { return }
        let tab = openTabs[tabIndex]
        let point = tab.document.rope.position(of: characterIndex)
        let position = LSPPosition(line: point.line, character: point.column)
        lspManager.definition(url: tab.url, position: position) { [weak self] locations in
            guard let self, !locations.isEmpty else { NSSound.beep(); return }
            guard locations.count > 1 else { return self.goTo(locations[0]) }
            // Several (an overload, a declaration and its implementation): pick one.
            let menu = NSMenu()
            for location in locations.prefix(20) {
                guard let url = URL(string: location.uri) else { continue }
                let folder = url.deletingLastPathComponent().pathComponents.suffix(2).joined(separator: "/")
                let item = NSMenuItem(title: "\(url.lastPathComponent):\(location.range.start.line + 1)", action: #selector(self.goToDefinitionItem(_:)), keyEquivalent: "")
                let title = NSMutableAttributedString(string: item.title, attributes: [.font: DS.Text.code(12, weight: .regular)])
                title.append(NSAttributedString(string: "  \(folder)", attributes: [.font: DS.Text.caption(), .foregroundColor: NSColor.secondaryLabelColor]))
                item.attributedTitle = title
                item.toolTip = url.path
                item.target = self
                item.representedObject = [location.uri, location.range.start.line, location.range.start.character, location.range.end.line, location.range.end.character] as [Any]
                menu.addItem(item)
            }
            let caret = self.editor.rect(forCharacterRange: NSRange(location: characterIndex, length: 0))
            menu.popUp(positioning: nil, at: NSPoint(x: caret.minX, y: caret.maxY + 2), in: self.editor.textView)
        }
    }

    @objc private func goToDefinitionItem(_ sender: NSMenuItem) {
        guard let parts = sender.representedObject as? [Any], parts.count == 5, let uri = parts[0] as? String,
              let values = Array(parts.dropFirst()) as? [Int] else { return }
        goTo(LSPLocation(uri: uri, range: LSPRange(start: LSPPosition(line: values[0], character: values[1]), end: LSPPosition(line: values[2], character: values[3]))))
    }

    private func goTo(_ target: LSPLocation) {
        guard let targetURL = URL(string: target.uri) else { return }
        open(targetURL) { [weak self] in
            // A server's path can run through symlinks (pnpm's and deno's node_modules) that the
            // tab's own URL doesn't.
            let resolved = targetURL.resolvingSymlinksInPath().standardizedFileURL
            guard let self, let targetIndex = self.openTabs.firstIndex(where: { $0.url == targetURL || $0.url.resolvingSymlinksInPath().standardizedFileURL == resolved }),
                  self.openTabs[targetIndex].kind == .text else { return }
            let targetNS = self.openTabs[targetIndex].document.text
            guard let targetRange = self.nsRange(for: target.range, in: targetNS) else { return }
            self.editor.selectedRange = NSRange(location: targetRange.location, length: 0)
            self.editor.centerRange(targetRange)
            self.editor.focus()
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
        // And the server's fixes for them, if it has any.
        let tab = openTabs[index]
        guard let lspManager, lspManager.capabilities(forExtension: tab.url.languageExtension)?.codeActions == true else {
            return NSMenu.popUpContextMenu(menu, with: event, for: gutter)
        }
        let range = LSPRange(start: onLine.map(\.range.start).min { ($0.line, $0.character) < ($1.line, $1.character) }!,
                             end: onLine.map(\.range.end).max { ($0.line, $0.character) < ($1.line, $1.character) }!)
        let asked = openTextSnapshots()
        lspManager.codeActions(url: tab.url, range: range, diagnostics: onLine) { [weak self] actions in
            MainActor.assumeIsolated {
                guard let self else { return }
                let fixes = (actions ?? []).filter { $0.disabledReason == nil && ($0.isQuickFix || $0.kind == nil) }
                if !fixes.isEmpty { menu.addItem(.separator()) }
                for action in fixes.prefix(12) { menu.addItem(self.codeActionItem(action, url: tab.url, asked: asked)) }
                NSMenu.popUpContextMenu(menu, with: event, for: self.gutter)
            }
        }
    }

    /// ⌘1–8 and ⌘9: a tab by its place, -1 the last.
    func selectTab(number: Int) {
        switchToTab(number >= 0 ? number : openTabs.count - 1)
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

    @objc private func closeTabFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let index = indexForTab(id: id) else { return }
        closeTab(at: index)
    }
    @objc private func closeActiveTab() { guard !Shortcuts.isKeyRepeat, let index = activeTabIndex else { return }; closeTab(at: index) }

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
        let after = TabSelection.indexAfterClosing(index, active: activeTabIndex, countBefore: openTabs.count)
        // The strip and the tabs change together (the strip animates the chip out on its own),
        // as Terminal's do: see `RunWorkspaceViewController.closeSession`.
        tabStrip.animateClose(at: index, activeAfter: after)
        let closedTab = openTabs[index]
        let wasActive = activeTabIndex == index
        if !wasActive { captureActiveTabSelection() }
        openTabs.remove(at: index)
        if closedTab.kind == .text { lspManager?.closed(url: closedTab.url) }
        if openTabs.isEmpty {
            closeAllTabsImmediately()
        } else {
            activeTabIndex = after
            // Only the tab you were on closing changes what the editor shows.
            if wasActive { loadActiveTabIntoEditor() }
            rebuildTabBar()
        }
    }

    func closeAllTabsForTesting() { closeAllTabsImmediately() }

    /// The window is moving to another project (project switching): this one's tabs are put away,
    /// not forgotten (they're remembered as they change), so the next project's come back
    /// instead. They followed the window across projects at first (2026-11-04).
    func putAwayTabsForProjectSwitch() {
        // Held off until the next project's tabs are back (`reindexAndRestoreLastFile`): closing
        // these wrote an empty list over this project's, and the next one's empty start over its.
        tabMemorySuspended = true
        closeAllTabsImmediately()
    }
    private var tabMemorySuspended = false

    private func closeAllTabsImmediately() {
        for tab in openTabs where tab.kind == .text { lspManager?.closed(url: tab.url) }
        openTabs.removeAll()
        activeTabIndex = nil
        isLoadingTab = true
        editor.attach(nil, undoManager: nil)
        DispatchQueue.main.async { [weak self] in self?.isLoadingTab = false }
        editor.isEditable = false
        editorContainer.isHidden = true
        applyMinimapVisibility()
        gutter.isHidden = true
        Shortcuts.activeContext = nil
        editor.lineDiffMarks = [:]
        imageScroll.isHidden = true
        imageView.image = nil
        sheetView.isHidden = true
        if !markdownPreviewScroll.isHidden {
            markdownPreviewScroll.isHidden = true
            onScrollUnderTopRowChange?()
        }
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

    /// UndoManager's default `levelsOfUndo` is 0, meaning *unlimited* — and every typing burst
    /// registers a group retaining the text it replaced, with nothing clearing the stack on
    /// save. Across a long session in many tabs that grows without bound. 200 levels is far
    /// more than anyone walks back by hand.
    private static func makeUndoManager() -> UndoManager {
        let manager = UndoManager()
        manager.levelsOfUndo = 200
        return manager
    }

    /// For tabs with the same file name, the folder that tells them apart.
    private var tabDetails: [UUID: String] = [:]

    /// The shortest run of parent folders that tells each same-named file from the others
    /// (`index.ts` in `api/` and `web/` read "api" and "web"; in `src/api` and `lib/api`,
    /// "src/api" and "lib/api"). Empty for a name that's alone. (2026-10-23, the owner: two
    /// tabs called index.ts looked the same.)
    static func disambiguatingFolders(for urls: [URL]) -> [String] {
        var result = Array(repeating: "", count: urls.count)
        let byName = Dictionary(grouping: urls.indices, by: { urls[$0].lastPathComponent })
        for indices in byName.values where indices.count > 1 {
            let parents = indices.map { Array(urls[$0].deletingLastPathComponent().pathComponents.reversed()) }
            let deepest = parents.map(\.count).max() ?? 0
            var depth = 1
            while depth < deepest {
                let suffixes = parents.map { $0.prefix(depth).reversed().joined(separator: "/") }
                if Set(suffixes).count == suffixes.count { break }
                depth += 1
            }
            for (position, index) in indices.enumerated() {
                result[index] = parents[position].prefix(depth).reversed().joined(separator: "/")
            }
        }
        return result
    }

    /// The file tabs: the shared strip (Direction 03 §4), told what Make has open.
    private lazy var tabStrip: TabStrip = {
        let strip = TabStrip(bar: tabBar, stack: tabBarStack, accessibilityLabel: "Editor tabs")
        strip.onSelect = { [weak self] index in self?.switchToTab(index) }
        strip.onClose = { [weak self] index in self?.closeTab(at: index) }
        strip.onMove = { [weak self] from, to in self?.moveTab(from: from, to: to) }
        // The order is remembered once a drag sets the tab down (it waited for the next rebuild).
        strip.onMoveEnded = { [weak self] in
            guard let self, let projectURL = self.projectURL else { return }
            self.rememberOpenTabs(forProject: projectURL)
        }
        strip.onTearOut = { [weak self] index, screenPoint in self?.tearOutTab(at: index, to: screenPoint) }
        return strip
    }()

    var tabStripForTesting: TabStrip { tabStrip }
    var openTabTitlesForTesting: [String] { openTabs.map { $0.url.lastPathComponent } }

    /// A tab dragged to a new place: the model follows the strip, the active file with it.
    private func moveTab(from: Int, to: Int) {
        guard openTabs.indices.contains(from), openTabs.indices.contains(to) else { return }
        let activeID = activeTabIndex.flatMap { openTabs.indices.contains($0) ? openTabs[$0].id : nil }
        openTabs.insert(openTabs.remove(at: from), at: to)
        if let activeID { activeTabIndex = openTabs.firstIndex(where: { $0.id == activeID }) }
    }

    private func rebuildTabBar() {
        let named = openTabs.filter { !$0.isUntitled }
        let details = Self.disambiguatingFolders(for: named.map(\.url))
        tabDetails = Dictionary(uniqueKeysWithValues: zip(named.map(\.id), details))
        // Whatever changed a tab's unsaved state (an edit, a save, a close) is followed by the
        // recovery copies catching up.
        scheduleRecoverySync()
        updateCaretPosition()
        // Every open, close and reorder comes through here, which is the set of moments the
        // remembered tab list should change, except mid-restore, whose in-between states aren't
        // worth keeping over the whole set.
        if let projectURL, !isRestoringTabs { rememberOpenTabs(forProject: projectURL) }
        noFileLabel.isHidden = !openTabs.isEmpty || projectURL == nil
        // A file open with no project (from Finder, a link): "Open a project" sat over it and
        // took the clicks meant for the text.
        if !openTabs.isEmpty { emptyState.isHidden = true }
        tabStrip.reload(openTabs.map(tabItem), active: activeTabIndex)
    }

    private func tabItem(_ tab: OpenTab) -> TabStrip.Item {
        let id = tab.id
        var item = TabStrip.Item(id: id, title: tab.url.lastPathComponent)
        item.detail = tabDetails[id] ?? ""
        item.toolTip = tab.isUntitled ? "Unsaved" : relativePath(tab.url)
        item.icon = tab.isUntitled ? nil : FileIcon.image(for: tab.url, isDirectory: false)
        item.isDirty = tab.dirty
        item.preview = { [weak self] in
            guard let self, let index = self.indexForTab(id: id) else { return nil }
            return self.tabPreviewContent(index)
        }
        item.menu = tabMenu(for: id)
        return item
    }

    /// Every item carries the tab's stable id, not its index: the menu can outlive reorders and
    /// closes between being built and being clicked.
    private func tabMenu(for id: UUID) -> NSMenu {
        let menu = NSMenu()
        func item(_ title: String, _ action: Selector) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = id
        }
        item("Close", #selector(closeTabFromMenu(_:)))
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
        return menu
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
        let root = focusedRoot.path + "/"
        if url.path.hasPrefix(root) { return String(url.path.dropFirst(root.count)) }
        // A server's path can name the project through a symlink (/tmp for /private/tmp).
        let resolvedRoot = focusedRoot.resolvingSymlinksInPath().path + "/", resolved = url.resolvingSymlinksInPath().path
        if resolved.hasPrefix(resolvedRoot) { return String(resolved.dropFirst(resolvedRoot.count)) }
        return url.path
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
    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSTextField) === replaceField { return }
        scheduleRefreshMatches()
    }

    private func scheduleRefreshMatches() {
        pendingSearchWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.performSearch() }
        pendingSearchWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: workItem)
    }

    private func performSearch() {
        if searchMode == .find {
            performFindSearch()
            return
        }
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
        if searchMode == .problems || searchMode == .references {
            filterLanguageResults()
            return
        }
        if searchMode == .choices {
            let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
            choiceRows = query.isEmpty ? Array(choices.indices) : choices.indices.compactMap { index in
                let choice = choices[index]
                let text = [choice.title, choice.detail ?? "", choice.trailing ?? ""].joined(separator: " ")
                return FuzzyMatcher.score(query: query, candidate: text).map { (index, $0) }
            }.sorted { $0.1 > $1.1 }.map(\.0)
            applySearchResults()
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
        case .find: return min(findRows.count, Self.findListLimit)
        case .problems: return problemRows.count
        case .references: return referenceRows.count
        case .choices: return choiceRows.count
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

    /// Go to Symbol: the file's outline, in order and nested, until something's typed; then the
    /// symbols that match, best first, with what they're in.
    private func performSymbolSearch() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            symbolMatches = outlineSymbols
        } else {
            symbolMatches = outlineSymbols.compactMap { symbol in
                FuzzyMatcher.score(query: query, candidate: symbol.name).map { (symbol, $0) }
            }.sorted { $0.1 > $1.1 }.prefix(60).map { $0.0 }
        }
        applySearchResults()
    }

    /// The active file's outline: from its server if it has document symbols, else from the
    /// syntax tree (off the main thread). The palette refreshes when it arrives.
    private func loadOutline() {
        guard let index = activeTabIndex, openTabs.indices.contains(index), openTabs[index].kind == .text else { outlineSymbols = []; return }
        let tab = openTabs[index]
        outlineGeneration += 1
        let generation = outlineGeneration
        guard let lspManager, lspManager.capabilities(forExtension: tab.url.languageExtension)?.documentSymbols == true else {
            return loadTreeOutline(tab, generation: generation)
        }
        lspManager.documentSymbols(url: tab.url) { [weak self] symbols in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let symbols, !symbols.isEmpty else { return self.loadTreeOutline(tab, generation: generation) }
                self.deliverOutline(Outline.from(symbols, rope: tab.document.rope), generation: generation, file: tab.url.lastPathComponent)
            }
        }
    }

    private func loadTreeOutline(_ tab: OpenTab, generation: Int) {
        let file = tab.url.lastPathComponent
        guard let source = tab.document.syntaxSymbols else { return deliverOutline([], generation: generation, file: file) }
        let rope = tab.document.rope
        Task.detached(priority: .userInitiated) { [weak self] in
            let outline = Outline.from(source.symbols(), rope: rope)
            await self?.deliverOutline(outline, generation: generation, file: file)
        }
    }

    private func deliverOutline(_ symbols: [OutlineSymbol], generation: Int, file: String) {
        guard outlineGeneration == generation else { return }
        outlineSymbols = symbols
        guard paletteIsOpen, searchMode == .symbols else { return }
        searchField.placeholderString = symbols.isEmpty ? "No symbols in \(file)" : "Go to symbol in \(file)"
        performSymbolSearch()
    }

    private func applySearchResults() {
        resultsTable.reloadData()
        let count = resultCount
        if count > 0 { resultsTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        // The palette stays open with no results — the field is part of it now.
        showQuickOpenPanel()
        announceResults()
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
            editor.selectedRange = symbol.nameRange
            editor.centerRange(symbol.nameRange)
            editor.focus()
        case .text:
            let match = (selected >= 0 && selected < textMatches.count) ? textMatches[selected] : textMatches.first
            guard let match else { return }
            hideQuickOpenPanel()
            onPaletteNavigated?()
            revealFile(match.url, line: match.line)
        case .find:
            // Return steps to the next match (⇧Return the previous); the palette stays.
            findStep(forward: !(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false))
        case .problems:
            let row = (selected >= 0 && selected < problemRows.count) ? problemRows[selected] : problemRows.first
            guard let row else { return }
            hideQuickOpenPanel()
            onPaletteNavigated?()
            goTo(LSPLocation(uri: row.url.absoluteString, range: row.diagnostic.range))
        case .references:
            let row = (selected >= 0 && selected < referenceRows.count) ? referenceRows[selected] : referenceRows.first
            guard let row else { return }
            hideQuickOpenPanel()
            onPaletteNavigated?()
            goTo(row.location)
        case .choices:
            guard let index = (selected >= 0 && selected < choiceRows.count) ? choiceRows[selected] : choiceRows.first else { return }
            let chosen = onChoice
            onChoice = nil
            hideQuickOpenPanel()
            chosen?(index)
        }
    }
    @objc private func openSelectedResult() { confirmSearch() }
    /// Escape: close and give focus back to whatever had it before the palette opened.
    @objc private func dismissQuickOpen() {
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
        if searchMode == .find, findRows.indices.contains(next) { showFindMatch(findRows[next].firstMatch) }
        announceResult(next)
    }

    /// How many results, and the first, once typing pauses: every keystroke refilters, and
    /// speaking each would talk over the typing.
    private func announceResults() {
        announceResultsWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.paletteIsOpen else { return }
            let count = self.resultCount
            guard count > 0, let cell = self.resultsTable.view(atColumn: 0, row: 0, makeIfNecessary: true) else {
                return Spoken.announce("No results")
            }
            Spoken.announce("\(count) result\(count == 1 ? "" : "s"). \(cell.accessibilityLabel() ?? "")")
        }
        announceResultsWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
    private var announceResultsWork: DispatchWorkItem?

    /// The palette row, as VoiceOver would read it if it had focus (the field keeps it).
    private func announceResult(_ row: Int) {
        guard resultCount > 0, let cell = resultsTable.view(atColumn: 0, row: row, makeIfNecessary: true) else { return }
        Spoken.row(cell.accessibilityLabel() ?? "", at: row, of: resultCount)
    }
    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === resultsTable { return resultCount }
        return 0
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard tableView === resultsTable else { return nil }
        let id = NSUserInterfaceItemIdentifier("paletteRow")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? PaletteCellView ?? PaletteCellView()
        cell.identifier = id
        switch effectiveMode {
        case .commands:
            let command = commandMatches[row]
            cell.configure(icon: Self.paletteSymbol(Self.commandSymbol(command.title)), title: command.title, detail: nil, trailing: command.shortcut)
        case .files:
            let url = matches[row]
            let relative = relativePath(url)
            let folder = (relative as NSString).deletingLastPathComponent
            cell.configure(icon: FileIcon.image(for: url, isDirectory: false), title: url.lastPathComponent, detail: folder.isEmpty ? nil : folder, trailing: nil)
        case .symbols:
            let symbol = symbolMatches[row]
            let outline = searchField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
            let indent = outline ? String(repeating: "    ", count: min(symbol.depth, 6)) : ""
            cell.configure(icon: Outline.icon(symbol.kind), title: indent + symbol.name,
                           detail: outline ? symbol.detail : (symbol.container ?? symbol.detail), trailing: "line \(symbol.line + 1)")
            cell.tintIcon(Outline.color(symbol.kind))
        case .text:
            let match = textMatches[row]
            cell.configure(icon: FileIcon.image(for: match.url, isDirectory: false), title: match.text, detail: nil, trailing: "\(match.relativePath):\(match.line)")
        case .find:
            let (line, text) = findLine(at: row)
            let place = findingInSheet ? findSheetCell(forMatch: findRows[row].firstMatch).map(sheetView.name(of:)) ?? "" : "line \(line)"
            cell.configure(icon: Self.paletteSymbol("text.magnifyingglass"), title: text, detail: nil, trailing: place)
        case .problems:
            let problem = problemRows[row]
            cell.configure(icon: Self.problemSymbol(problem.diagnostic.severity), title: problem.diagnostic.message,
                           detail: problem.diagnostic.source, trailing: "\(problem.url.lastPathComponent):\(problem.diagnostic.range.start.line + 1)")
            cell.toolTip = relativePath(problem.url)
            cell.tintIcon(Self.problemColor(problem.diagnostic.severity))
        case .references:
            let reference = referenceRows[row]
            cell.configure(icon: FileIcon.image(for: reference.url, isDirectory: false), title: reference.text, detail: nil,
                           trailing: "\(reference.url.lastPathComponent):\(reference.line + 1)")
            cell.toolTip = relativePath(reference.url)
        case .choices:
            let choice = choices[choiceRows[row]]
            cell.configure(icon: Self.paletteSymbol(choice.symbol), title: choice.title, detail: choice.unavailable ?? choice.detail, trailing: choice.trailing)
            cell.toolTip = choice.unavailable
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        tableView === resultsTable ? DS.SelectionRowView() : nil
    }

    /// Each command its own symbol (the audit: every row had the same ⌘): a stage's command takes
    /// the stage's, the rest what they do. ⌘ only for what has no better sign.
    static func commandSymbol(_ title: String) -> String {
        if title.hasPrefix("Go to "), let stage = ShellViewController.Stage.allCases.first(where: { "Go to \($0.title)" == title }) { return stage.symbol }
        let byTitle: [String: String] = [
            "Quick Open": "doc.text.magnifyingglass", "Command Palette": "command", "Find in Project…": "text.magnifyingglass",
            "Go to Line…": "arrow.right.to.line", "Go to Symbol…": "number", "Jump to Definition": "arrow.turn.down.right",
            "Find References": "link", "Show Problems": "exclamationmark.triangle", "Back": "chevron.backward", "Forward": "chevron.forward",
            "New Track…": "plus", "Switch Track…": "arrow.triangle.branch",
        ]
        return byTitle[title] ?? "command"
    }

    private static func paletteSymbol(_ name: String) -> NSImage? {
        guard !name.hasPrefix(DS.Glyph.prefix) else { return DS.Glyph.image(named: name, pointSize: 17) }
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if control === replaceField { return replaceFieldCommand(commandSelector, textView: textView) }
        guard control === searchField else { return false }
        // IME: Return and Escape belong to the input method while a composition is open.
        if textView.hasMarkedText() { return false }
        // Tab carries the query between This File and the project.
        if commandSelector == #selector(NSResponder.insertTab(_:)) || commandSelector == #selector(NSResponder.insertBacktab(_:)) {
            if searchMode == .find, projectURL != nil {
                let query = searchField.stringValue
                presentPalette(.text)
                searchField.stringValue = query
                performSearch()
                return true
            }
            if searchMode == .text, activeTabIndex != nil {
                find.query = searchField.stringValue
                presentPalette(.find)
                return true
            }
        }
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
    private func undoStateChanged(_ managerID: ObjectIdentifier?) {
        guard let managerID, let index = openTabs.firstIndex(where: { ObjectIdentifier($0.undoManager) == managerID }), openTabs[index].kind == .text else { return }
        compareWithSaved(index)
    }

    /// Clean again when the text is what's on disk, however it got back there: an undo, or a
    /// line typed and deleted by hand.
    private func compareWithSaved(_ index: Int) {
        let matchesSaved = ContentStamp(openTabs[index].document.string) == openTabs[index].savedStamp
        guard openTabs[index].dirty == matchesSaved else { return }
        openTabs[index].dirty = !matchesSaved
        if activeTabIndex == index { dirty = !matchesSaved }
        rebuildTabBar()
    }

    /// An edit that leaves the file its saved length might have put it back: checked once
    /// typing pauses. The length is free to read; the text is hashed only then.
    private var savedComparison: DispatchWorkItem?
    /// The pending write of unsaved buffers' recovery copies (see `syncRecovery`).
    fileprivate var recoverySync: DispatchWorkItem?
    /// The recovery copies this window wrote: another window on the same project keeps its own.
    fileprivate var recoveryNames: Set<String> = []
    private func scheduleComparisonWithSaved(_ index: Int) {
        savedComparison?.cancel()
        guard openTabs[index].document.rope.utf8Count == openTabs[index].savedStamp.count else { return }
        let tabID = openTabs[index].id
        let work = DispatchWorkItem { [weak self] in
            guard let self, let index = self.indexForTab(id: tabID) else { return }
            self.compareWithSaved(index)
        }
        savedComparison = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func editorTextDidChange(_ engine: EditorEngine) {
        guard !isLoadingTab else { return }
        if isWriting { scheduleWordCount() }
        scheduleRecoverySync()
        dirty = true
        if let index = activeTabIndex, !openTabs[index].dirty {
            openTabs[index].dirty = true
            rebuildTabBar()  // the tab's unsaved dot
        }
        if let index = activeTabIndex, openTabs[index].kind == .text, !openTabs[index].isUntitled { scheduleComparisonWithSaved(index) }
        editor.invalidateGutter()
        if paletteIsOpen, searchMode == .find { scheduleRefreshMatches() }
        scheduleDiffRefresh()
        let typed = lastTypedText
        updateCompletion()
        updateSignatureHelp(typed: typed)
        endHover()
        suppressNextSelectionDismiss = true
    }

    // MARK: - Autocomplete (SIDE_RFC_IDE_ESSENTIALS.md, L2)

    /// After each edit: filter the list that's up, or ask for one when a word starts or a
    /// server's trigger character is typed. A server is asked once per word; typing on filters
    /// what it sent, here, unless it said the list was incomplete.
    private func updateCompletion(explicit: Bool = false) {
        let typed = lastTypedText
        lastTypedText = nil
        guard !isAcceptingCompletion else { return }
        guard let index = activeTabIndex, openTabs.indices.contains(index), openTabs[index].kind == .text,
              !openTabs[index].isPreviewingMarkdown, editor.selectedRange.length == 0 else { return endCompletion() }
        let tab = openTabs[index]
        let text = tab.document.text
        let caret = editor.selectedRange.location
        let start = CompletionText.wordStart(in: text, caret: caret)
        let query = text.substring(with: NSRange(location: start, length: caret - start))

        if !explicit, var session = completionSession, completionTabID == tab.id, session.wordStart == start {
            if session.hasReply, session.list.isIncomplete, typed != nil {
                requestCompletion(tab: tab, wordStart: start, caret: caret, context: CompletionContext(triggerKind: 3), keeping: session)
            }
            session.filter(query)
            completionSession = session
            presentCompletions()
            return
        }

        let ext = tab.url.languageExtension
        let triggers = lspManager?.completionTriggers(forExtension: ext) ?? []
        let trigger = triggers.first { !$0.isEmpty && caret >= ($0 as NSString).length
            && text.substring(with: NSRange(location: caret - ($0 as NSString).length, length: ($0 as NSString).length)) == $0 }
        let startsWord = caret - start == 1 && !CompletionText.isDigit(text.character(at: start))
        guard explicit || (typed != nil && (trigger != nil || startsWord)) else { return endCompletion() }
        let context = trigger != nil && start == caret
            ? CompletionContext(triggerKind: 2, triggerCharacter: trigger)
            : CompletionContext(triggerKind: 1)
        requestCompletion(tab: tab, wordStart: start, caret: caret, context: context, keeping: nil)
    }

    /// Asks the file's server, or, where there's none, gathers the words of the open files.
    private func requestCompletion(tab: OpenTab, wordStart: Int, caret: Int, context: CompletionContext, keeping previous: CompletionSession?) {
        if let completionToken { lspManager?.cancel(completionToken, url: tab.url) }
        var session = CompletionSession(wordStart: wordStart, requestCaret: caret)
        // Re-asking about an incomplete list: the old one stays up (filtered) until the new one's in.
        if let previous { session.receive(previous.list, query: previous.query) }
        completionSession = session
        completionTabID = tab.id
        resolvedCompletions = []
        let ext = tab.url.languageExtension
        let tabID = tab.id
        guard let lspManager, LanguageServerRegistry.entry(forExtension: ext) != nil, !lspManager.isUnavailable(forExtension: ext) else {
            return completeFromBufferWords(tabID: tabID, ext: ext)
        }
        let rope = tab.document.rope
        let position = rope.position(of: caret)
        let token = LSPRequestToken()
        lspManager.completion(url: tab.url, position: LSPPosition(line: position.line, character: position.column), context: context, token: token) { [weak self] list in
            guard let self, self.completionToken === token else { return }
            self.completionToken = nil
            guard let list, !list.items.isEmpty || list.isIncomplete else { return self.completeFromBufferWords(tabID: tabID, ext: ext) }
            self.receiveCompletions(list, tabID: tabID)
        }
        completionToken = token
    }

    /// Where no server answers: the words in the open files, most used first.
    private func completeFromBufferWords(tabID: UUID, ext: String) {
        guard !["md", "markdown", "txt", ""].contains(ext.lowercased()) else { return endCompletion() }
        let token = LSPRequestToken()
        completionToken = token
        let current = openTabs.first { $0.id == tabID }?.document.rope
        let others = openTabs.filter { $0.id != tabID && $0.kind == .text }.prefix(12).map { $0.document.rope }
        let ropes = [current].compactMap { $0 } + others
        Task.detached(priority: .userInitiated) {
            let words = CompletionText.bufferWords(ropes, excluding: "")
            let items = words.prefix(4000).map { LSPCompletionItem(label: $0, kind: 1) }
            await MainActor.run { [weak self] in
                guard let self, self.completionToken === token else { return }
                self.completionToken = nil
                self.receiveCompletions(LSPCompletionList(items: items, isIncomplete: false), tabID: tabID)
            }
        }
    }

    private func receiveCompletions(_ list: LSPCompletionList, tabID: UUID) {
        guard var session = completionSession, completionTabID == tabID, let index = indexForTab(id: tabID), activeTabIndex == index else { return }
        let caret = editor.selectedRange.location
        guard caret >= session.wordStart else { return endCompletion() }
        let text = openTabs[index].document.text
        session.receive(list, query: text.substring(with: NSRange(location: session.wordStart, length: caret - session.wordStart)))
        completionSession = session
        resolvedCompletions = []
        presentCompletions()
    }

    /// Shows the session's list as it's filtered now; hides it when nothing matches, or when the
    /// only match is what's already typed.
    private func presentCompletions() {
        guard let session = completionSession, session.hasReply else { return }
        let items = Array(session.shownItems.prefix(500))
        guard let window = view.window, let caretRect = screenRectForCaret(), !items.isEmpty,
              !(items.count == 1 && (items[0].insertText ?? items[0].label) == session.query) else {
            completionPopup.hide()
        signatureCard.detach()
        hoverCard.detach()
            return
        }
        completionPopup.onSelect = { [weak self] row in self?.resolveCompletion(row: row) }
        completionPopup.onAccept = { [weak self] in self?.acceptSelectedCompletion(replacing: false) }
        completionPopup.show(items, selected: session.initialSelection, caret: caretRect, in: window)
        resolveCompletion(row: completionPopup.selectedIndex)
    }

    /// The selected item's documentation and, for some servers, its auto-import edits.
    private func resolveCompletion(row: Int) {
        guard let session = completionSession, session.shown.indices.contains(row), let tabID = completionTabID,
              let index = indexForTab(id: tabID), let lspManager else { return }
        let listIndex = session.shown[row]
        guard !resolvedCompletions.contains(listIndex) else { return }
        if let resolveToken { lspManager.cancel(resolveToken, url: openTabs[index].url) }
        let item = session.list.items[listIndex]
        resolveToken = lspManager.resolve(item, url: openTabs[index].url) { [weak self] resolved in
            guard let self, var session = self.completionSession, self.completionTabID == tabID,
                  session.list.items.indices.contains(listIndex), session.list.items[listIndex].label == item.label else { return }
            self.resolvedCompletions.insert(listIndex)
            if let resolved {
                session.update(resolved, at: listIndex)
                self.completionSession = session
                if let shownRow = session.shown.firstIndex(of: listIndex) { self.completionPopup.update(resolved, at: shownRow) }
            }
            if let pending = self.acceptAfterResolve, session.shown.indices.contains(pending.row), session.shown[pending.row] == listIndex {
                self.acceptAfterResolve = nil
                self.acceptSelectedCompletion(replacing: pending.replacing)
            }
        }
    }

    private func screenRectForCaret() -> NSRect? {
        editor.screenRect(forCharacterRange: NSRange(location: editor.selectedRange.location, length: 0))
    }

    private func endCompletion() {
        if let completionToken, let tabID = completionTabID, let index = indexForTab(id: tabID) { lspManager?.cancel(completionToken, url: openTabs[index].url) }
        if let resolveToken, let tabID = completionTabID, let index = indexForTab(id: tabID) { lspManager?.cancel(resolveToken, url: openTabs[index].url) }
        completionToken = nil
        resolveToken = nil
        completionSession = nil
        acceptAfterResolve = nil
        completionPopup.hide()
    }

    /// Return inserts the item (a server's insert range); Tab replaces the rest of the word too.
    /// The item's own edit, its auto-imports and all, is one undo step.
    private func acceptSelectedCompletion(replacing: Bool) {
        let row = completionPopup.selectedIndex
        guard let session = completionSession, session.shown.indices.contains(row), let tabID = completionTabID,
              let index = indexForTab(id: tabID), activeTabIndex == index else { return endCompletion() }
        let listIndex = session.shown[row]
        // A resolve still out may carry the item's import: wait for it, briefly.
        if resolveToken != nil, !resolvedCompletions.contains(listIndex), acceptAfterResolve == nil, lspManager != nil {
            acceptAfterResolve = (row, replacing)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, let pending = self.acceptAfterResolve, pending.row == row else { return }
                self.resolvedCompletions.insert(listIndex)
                self.acceptAfterResolve = nil
                self.acceptSelectedCompletion(replacing: pending.replacing)
            }
            return
        }
        let item = session.list.items[listIndex]
        let rope = openTabs[index].document.rope
        let caret = editor.selectedRange.location
        guard let edits = CompletionEdits.edits(for: item, session: session, caret: caret, text: rope, replacing: replacing) else { return endCompletion() }
        isAcceptingCompletion = true
        editor.insertSnippet(edits.snippet, replacing: edits.all[0].range, alsoApplying: edits.extras)
        isAcceptingCompletion = false
        endCompletion()
    }

    @objc func showCompletions(_ sender: Any?) {
        updateCompletion(explicit: true)
    }

    // MARK: - Problems, references, rename, quick fixes (SIDE_RFC_IDE_ESSENTIALS.md, L3)

    /// Tests and budgets: problems as a server would report them.
    func recordProblemsForTesting(_ diagnostics: [LSPDiagnostic], for url: URL) { recordProblems(diagnostics, for: url) }
    var problemRowCountForTesting: Int { problemRows.count }

    private func recordProblems(_ diagnostics: [LSPDiagnostic], for url: URL) {
        allDiagnostics[url] = diagnostics.isEmpty ? nil : diagnostics
        sortedProblems = nil
        updateProblemsButton()
        if paletteIsOpen, searchMode == .problems {
            rebuildProblemRows()
            searchField.placeholderString = problemsSummary
        }
    }

    private var problemCounts: (errors: Int, warnings: Int, others: Int) {
        var counts = (0, 0, 0)
        for diagnostics in allDiagnostics.values {
            for diagnostic in diagnostics {
                switch diagnostic.severity {
                case .error: counts.0 += 1
                case .warning: counts.1 += 1
                default: counts.2 += 1
                }
            }
        }
        return counts
    }

    private var problemsSummary: String {
        let (errors, warnings, others) = problemCounts
        guard errors + warnings + others > 0 else { return "No problems" }
        var parts: [String] = []
        if errors > 0 { parts.append(errors == 1 ? "1 error" : "\(errors) errors") }
        if warnings > 0 { parts.append(warnings == 1 ? "1 warning" : "\(warnings) warnings") }
        if others > 0 { parts.append(others == 1 ? "1 note" : "\(others) notes") }
        return "Problems: " + parts.joined(separator: ", ")
    }

    /// The top row's count of errors and warnings; click to see them.
    private func updateProblemsButton() {
        let (errors, warnings, _) = problemCounts
        guard errors + warnings > 0 else { problemsButton.isHidden = true; return }
        let text = NSMutableAttributedString()
        let font = DS.Text.caption()
        if errors > 0 {
            text.append(NSAttributedString(string: "\u{2715} \(errors)", attributes: [.font: font, .foregroundColor: NSColor.systemRed]))
        }
        if warnings > 0 {
            if text.length > 0 { text.append(NSAttributedString(string: "  ")) }
            text.append(NSAttributedString(string: "\u{26A0}\u{FE0E} \(warnings)", attributes: [.font: font, .foregroundColor: NSColor.systemOrange]))
        }
        problemsButton.attributedTitle = text
        // The whole project's, as VS Code counts them: said so, since it shows on every file
        // (the visual audit read it as the open file's).
        problemsButton.toolTip = "\(problemsSummary) in this project \u{2014} Show Problems"
        problemsButton.setAccessibilityLabel("\(problemsSummary) in this project. Show Problems")
        problemsButton.isHidden = false
    }

    /// Every problem in order (errors first, then by file and line), with each file's relative
    /// path, sorted once when the problems change rather than each time the list opens or filters.
    private var sortedProblems: [(url: URL, path: String, diagnostic: LSPDiagnostic)]?

    private func rebuildProblemRows() {
        if sortedProblems == nil {
            func rank(_ severity: LSPDiagnosticSeverity?) -> Int { severity.map { $0.rawValue } ?? 3 }
            sortedProblems = allDiagnostics.flatMap { url, diagnostics in
                let path = relativePath(url)
                return diagnostics.map { (url: url, path: path, diagnostic: $0) }
            }.sorted { a, b in
                let ra = rank(a.diagnostic.severity), rb = rank(b.diagnostic.severity)
                if ra != rb { return ra < rb }
                if a.path != b.path { return a.path < b.path }
                return a.diagnostic.range.start.line < b.diagnostic.range.start.line
            }
        }
        let all = sortedProblems ?? []
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        let rows = query.isEmpty ? all : all.filter { row in
            row.diagnostic.message.localizedCaseInsensitiveContains(query) || row.path.localizedCaseInsensitiveContains(query)
        }
        problemRows = rows.map { (url: $0.url, diagnostic: $0.diagnostic) }
    }

    /// Problems and references filter what's already there as you type.
    private func filterLanguageResults() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        if searchMode == .problems {
            rebuildProblemRows()
        } else {
            referenceRows = query.isEmpty ? referenceResults : referenceResults.filter {
                $0.text.localizedCaseInsensitiveContains(query) || relativePath($0.url).localizedCaseInsensitiveContains(query)
            }
        }
        applySearchResults()
    }

    @objc func showProblems(_ sender: Any?) { presentPalette(.problems) }

    /// The palette as a picker: one of these, or nothing (Escape).
    func choose(_ prompt: String, from list: [PaletteChoice], completion: @escaping (Int) -> Void) {
        choices = list
        choicePrompt = prompt
        onChoice = completion
        presentPalette(.choices)
    }

    static func problemSymbol(_ severity: LSPDiagnosticSeverity?) -> NSImage? {
        let name: String
        switch severity {
        case .error: name = "xmark.octagon.fill"
        case .warning: name = "exclamationmark.triangle.fill"
        default: name = "info.circle.fill"
        }
        return paletteSymbol(name)
    }

    static func problemColor(_ severity: LSPDiagnosticSeverity?) -> NSColor {
        switch severity {
        case .error: return .systemRed
        case .warning: return .systemOrange
        default: return .secondaryLabelColor
        }
    }

    /// Find References: every use of the symbol at the caret, listed in the palette.
    @objc func findReferences(_ sender: Any?) {
        guard let index = activeTabIndex, openTabs[index].kind == .text, let lspManager,
              lspManager.capabilities(forExtension: openTabs[index].url.languageExtension)?.findsReferences == true,
              let word = hoverWordRange(at: editor.selectedRange.location) ?? hoverWordRange(at: max(0, editor.selectedRange.location - 1)) else { return NSSound.beep() }
        let tab = openTabs[index]
        referenceSymbol = (tab.document.text as NSString).substring(with: word)
        let point = tab.document.rope.position(of: word.location)
        lspManager.references(url: tab.url, position: LSPPosition(line: point.line, character: point.column)) { [weak self] locations in
            guard let self else { return }
            guard let locations, !locations.isEmpty else { return NSSound.beep() }
            self.referenceResults = self.referenceLines(locations)
            self.referenceRows = self.referenceResults
            self.presentPalette(.references)
        }
    }

    /// Each location with its line's text: from the open buffer, or read once per file from disk.
    private func referenceLines(_ locations: [LSPLocation]) -> [(location: LSPLocation, url: URL, line: Int, text: String)] {
        var texts: [URL: NSString] = [:]
        return locations.compactMap { location in
            guard let url = URL(string: location.uri) else { return nil }
            let text: NSString
            if let cached = texts[url] { text = cached }
            else {
                let resolved = url.resolvingSymlinksInPath().standardizedFileURL
                let open = openTabs.first { $0.kind == .text && ($0.url == url || $0.url.resolvingSymlinksInPath().standardizedFileURL == resolved) }
                text = open?.document.text ?? ((try? String(contentsOf: url, encoding: .utf8)) as NSString? ?? "")
                texts[url] = text
            }
            var line = ""
            var lineNumber = 0
            text.enumerateLines { string, stop in
                if lineNumber == location.range.start.line { line = string; stop.pointee = true }
                lineNumber += 1
            }
            return (location, url, location.range.start.line, line.trimmingCharacters(in: .whitespaces))
        }
    }

    // Rename.

    /// Rename Symbol: a field over the name, and on Return every use renamed by the server,
    /// across files (a change to more than one file is shown first). One undo step per file.
    @objc func renameSymbol(_ sender: Any?) {
        guard let index = activeTabIndex, openTabs[index].kind == .text, let lspManager,
              lspManager.capabilities(forExtension: openTabs[index].url.languageExtension)?.renames == true,
              let word = hoverWordRange(at: editor.selectedRange.location) ?? hoverWordRange(at: max(0, editor.selectedRange.location - 1)) else { return NSSound.beep() }
        let tab = openTabs[index]
        let point = tab.document.rope.position(of: word.location)
        let position = LSPPosition(line: point.line, character: point.column)
        lspManager.prepareRename(url: tab.url, position: position) { [weak self] result in
            guard let self, let index = self.activeTabIndex, self.openTabs[index].id == tab.id else { return }
            guard case .success(let range) = result else { return NSSound.beep() }
            let rope = self.openTabs[index].document.rope
            let nameRange = range.map { r -> NSRange in
                let a = rope.offset(line: r.start.line, column: r.start.character), b = rope.offset(line: r.end.line, column: r.end.character)
                return NSRange(location: a, length: max(0, b - a))
            } ?? word
            let name = (self.openTabs[index].document.text as NSString).substring(with: nameRange)
            guard let window = self.view.window, let anchor = self.editor.screenRect(forCharacterRange: nameRange) else { return }
            let field = RenameField(name: name)
            field.onCommit = { [weak self] newName in
                self?.renameField = nil
                guard let self, newName != name, !newName.isEmpty else { return }
                self.performRename(url: tab.url, position: position, to: newName)
            }
            field.onCancel = { [weak self] in self?.renameField = nil; self?.editor.focus() }
            self.renameField = field
            field.show(over: anchor, in: window, font: Self.editorAppearance.font)
        }
    }

    private func performRename(url: URL, position: LSPPosition, to newName: String) {
        let asked = openTextSnapshots()
        lspManager?.rename(url: url, position: position, to: newName) { [weak self] edit in
            guard let self else { return }
            guard let edit, edit.editCount > 0 else { return NSSound.beep() }
            guard edit.files.count > 1, let window = self.view.window else {
                _ = self.applyWorkspaceEdit(edit, computedOn: asked)
                self.editor.focus()
                return
            }
            let alert = NSAlert()
            alert.messageText = "Rename to \u{201C}\(newName)\u{201D}?"
            let lines = edit.files.prefix(12).map { file -> String in
                let path = URL(string: file.uri).map { self.relativePath($0) } ?? file.uri
                return "\(path)  \u{00B7}  \(file.edits.count)"
            }
            alert.informativeText = "\(edit.editCount) changes in \(edit.files.count) files:\n\n" + lines.joined(separator: "\n")
                + (edit.files.count > 12 ? "\n\u{2026}and \(edit.files.count - 12) more" : "")
                + "\n\nOpen files are changed in their tabs (unsaved, one undo each); the rest are saved."
            alert.addButton(withTitle: "Rename")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                _ = self?.applyWorkspaceEdit(edit, computedOn: asked)
                self?.editor.focus()
            }
        }
    }

    /// Each open file's text as it is now: what a rename or quick fix asked about.
    private func openTextSnapshots() -> [URL: Rope] {
        Dictionary(openTabs.filter { $0.kind == .text }.map { ($0.url, $0.document.rope) }, uniquingKeysWith: { first, _ in first })
    }

    /// A server's edits, applied: in an open tab as one undo step (left unsaved, as typing
    /// would), in a file that isn't open by rewriting it. Overlapping edits are refused.
    ///
    /// Refused whole if an open file changed since the edit was worked out: its text differs
    /// from `computedOn` (what it was when the rename or fix was asked for), or the server
    /// names a version it no longer has. Applied at the old offsets, the edit landed in the
    /// wrong places, mangling what was typed meanwhile (2026-09-30 audit, EDT-6).
    @discardableResult
    func applyWorkspaceEdit(_ edit: LSPWorkspaceEdit, computedOn asked: [URL: Rope] = [:]) -> Bool {
        let changed = edit.files.compactMap { file -> URL? in
            guard let url = URL(string: file.uri), url.isFileURL,
                  let tab = openTabs.first(where: { $0.kind == .text && ($0.url == url || $0.url.resolvingSymlinksInPath().standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL) }) else { return nil }
            if let before = asked[tab.url], before != tab.document.rope { return tab.url }
            if let version = edit.versions[file.uri], lspManager?.isAtVersion(version, url: tab.url) == false { return tab.url }
            return nil
        }
        guard changed.isEmpty else {
            NSSound.beep()
            if let window = view.window {
                let alert = NSAlert()
                alert.messageText = "Nothing was changed"
                let names = changed.map(\.lastPathComponent).joined(separator: ", ")
                alert.informativeText = "\(names) changed while the language server was working out the edit, so its positions no longer match. Try again."
                alert.beginSheetModal(for: window)
            }
            return false
        }
        var applied = false
        for file in edit.files {
            guard let url = URL(string: file.uri), url.isFileURL else { continue }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            if let index = openTabs.firstIndex(where: { $0.kind == .text && ($0.url == url || $0.url.resolvingSymlinksInPath().standardizedFileURL == resolved) }) {
                let rope = openTabs[index].document.rope
                guard let ranges = Self.nonOverlapping(file.edits, in: rope) else { continue }
                if activeTabIndex == index { editor.applyEdits(ranges) } else { openTabs[index].document.applyEdits(ranges) }
                if !openTabs[index].dirty {
                    openTabs[index].dirty = true
                    if activeTabIndex == index { dirty = true }
                }
                applied = true
            } else {
                guard let data = try? Data(contentsOf: url), let decoded = TextFileCodec.decode(data) else { continue }
                var rope = Rope(decoded.text)
                guard let ranges = Self.nonOverlapping(file.edits, in: rope) else { continue }
                for range in ranges.reversed() { rope.replace(range.range.location..<NSMaxRange(range.range), with: range.text) }
                guard let out = TextFileCodec.encode(rope.string, as: decoded.format), (try? out.write(to: url, options: .atomic)) != nil else { continue }
                UserSaveLog.shared.record(url)
                applied = true
            }
        }
        rebuildTabBar()
        editor.invalidateGutter()
        return applied
    }

    /// Edits as ranges in `rope`, sorted; nil if any two overlap (a server's bug: applying some
    /// and not others would leave the file half changed).
    static func nonOverlapping(_ edits: [LSPTextEdit], in rope: Rope) -> [(range: NSRange, text: String)]? {
        let ranges = edits.map { edit -> (range: NSRange, text: String) in
            let a = rope.offset(line: edit.range.start.line, column: edit.range.start.character)
            let b = rope.offset(line: edit.range.end.line, column: edit.range.end.character)
            return (NSRange(location: a, length: max(0, b - a)), edit.newText)
        }.sorted { $0.range.location < $1.range.location }
        for (a, b) in zip(ranges, ranges.dropFirst()) where NSMaxRange(a.range) > b.range.location { return nil }
        return ranges
    }

    // Quick fixes.

    /// Quick Fix: the server's fixes and refactorings at the caret (or the selection), in a menu
    /// under it; its preferred fix first.
    @objc func showQuickFixes(_ sender: Any?) {
        guard let index = activeTabIndex, openTabs[index].kind == .text, let lspManager,
              lspManager.capabilities(forExtension: openTabs[index].url.languageExtension)?.codeActions == true else { return NSSound.beep() }
        let tab = openTabs[index]
        let selection = editor.selectedRange
        let rope = tab.document.rope
        let start = rope.position(of: selection.location), end = rope.position(of: NSMaxRange(selection))
        let range = LSPRange(start: LSPPosition(line: start.line, character: start.column), end: LSPPosition(line: end.line, character: end.column))
        let problems = diagnostics(overlapping: NSRange(location: selection.location, length: max(1, selection.length)), in: tab)
        let asked = openTextSnapshots()
        lspManager.codeActions(url: tab.url, range: range, diagnostics: problems) { [weak self] actions in
            MainActor.assumeIsolated { self?.showQuickFixMenu(actions, url: tab.url, at: selection, asked: asked) }
        }
    }

    private func showQuickFixMenu(_ actions: [LSPCodeAction]?, url: URL, at selection: NSRange, asked: [URL: Rope]) {
        // What the server says doesn't apply here isn't offered (it lists every refactoring,
        // most of them disabled).
        let actions = (actions ?? []).filter { $0.disabledReason == nil }
        guard !actions.isEmpty else { NSSound.beep(); return }
        let sorted = actions.enumerated().sorted { a, b in
            if a.element.isPreferred != b.element.isPreferred { return a.element.isPreferred }
            if a.element.isQuickFix != b.element.isQuickFix { return a.element.isQuickFix }
            return a.offset < b.offset
        }.map(\.element)
        let menu = NSMenu()
        var lastWasFix = sorted.first?.isQuickFix ?? false
        for action in sorted.prefix(24) {
            if lastWasFix != action.isQuickFix { menu.addItem(.separator()); lastWasFix = action.isQuickFix }
            menu.addItem(codeActionItem(action, url: url, asked: asked))
        }
        let caret = editor.rect(forCharacterRange: NSRange(location: selection.location, length: 0))
        menu.popUp(positioning: menu.items.first, at: NSPoint(x: caret.minX, y: caret.maxY + 2), in: editor.textView)
    }

    /// `asked`: the open files' text when the actions were asked for; a fix is refused if they've
    /// changed since (EDT-6).
    private func codeActionItem(_ action: LSPCodeAction, url: URL, asked: [URL: Rope]) -> NSMenuItem {
        let item = NSMenuItem(title: action.title, action: #selector(performCodeActionItem(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = CodeActionBox(action: action, url: url, asked: asked)
        if let reason = action.disabledReason { item.isEnabled = false; item.toolTip = reason }
        if action.isPreferred { item.attributedTitle = NSAttributedString(string: action.title, attributes: [.font: DS.Text.body().withTraits(.boldFontMask)]) }
        return item
    }

    @objc private func performCodeActionItem(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? CodeActionBox else { return }
        perform(box.action, url: box.url, resolved: false, asked: box.asked)
    }

    /// An action's edit applied, then its command run (which may send more edits back). One
    /// with neither is resolved first, for a server that fills them in on request.
    private func perform(_ action: LSPCodeAction, url: URL, resolved: Bool, asked: [URL: Rope]) {
        guard let lspManager else { return }
        if action.edit == nil, action.command == nil || !resolved,
           !resolved, lspManager.capabilities(forExtension: url.languageExtension)?.resolvesCodeActions == true {
            lspManager.resolve(action, url: url) { [weak self] resolvedAction in
                self?.perform(resolvedAction ?? action, url: url, resolved: true, asked: asked)
            }
            return
        }
        if let edit = action.edit, !applyWorkspaceEdit(edit, computedOn: asked), !edit.files.isEmpty { return }
        if let command = action.command {
            lspManager.execute(command: command.name, arguments: command.arguments, url: url) { _ in }
        }
        editor.focus()
    }

    // MARK: - Signature help (SIDE_RFC_IDE_ESSENTIALS.md, L2)

    /// After an edit: a server's trigger character (`(`, `,`) asks; while the card is up, every
    /// edit asks again, so it follows the argument being typed and goes when the call closes.
    private func updateSignatureHelp(typed: String?) {
        guard let index = activeTabIndex, openTabs[index].kind == .text, editor.selectedRange.length == 0, let lspManager,
              let triggers = lspManager.signatureTriggers(forExtension: openTabs[index].url.languageExtension) else { return hideSignatureHelp() }
        let last = typed.flatMap { $0.last.map(String.init) }
        var context: LSPValue
        if let last, triggers.triggers.contains(last) {
            context = ["triggerKind": 2, "triggerCharacter": .string(last), "isRetrigger": .bool(signatureHelp != nil)]
        } else if signatureHelp != nil {
            if let last, triggers.retriggers.contains(last) {
                context = ["triggerKind": 2, "triggerCharacter": .string(last), "isRetrigger": true]
            } else {
                context = ["triggerKind": 3, "isRetrigger": true]
            }
        } else {
            return
        }
        if case .object(var fields) = context, let current = signatureHelp {
            fields["activeSignatureHelp"] = ["activeSignature": .int(current.activeSignature), "activeParameter": .int(current.activeParameter),
                                             "signatures": .array(current.signatures.map { ["label": .string($0.label)] })]
            context = .object(fields)
        }
        requestSignatureHelp(tab: openTabs[index], context: context)
    }

    private func requestSignatureHelp(tab: OpenTab, context: LSPValue) {
        guard let lspManager else { return }
        if let signatureToken { lspManager.cancel(signatureToken, url: tab.url) }
        let point = tab.document.rope.position(of: editor.selectedRange.location)
        let tabID = tab.id
        signatureToken = lspManager.signatureHelp(url: tab.url, position: LSPPosition(line: point.line, character: point.column), context: context) { [weak self] help in
            guard let self, let index = self.activeTabIndex, self.openTabs[index].id == tabID else { return }
            self.signatureToken = nil
            guard let help else { return self.hideSignatureHelp() }
            self.signatureHelp = help
            guard let window = self.view.window, let caret = self.screenRectForCaret() else { return }
            MainActor.assumeIsolated { self.signatureCard.show(Self.render(help), near: caret, in: window, preferAbove: true) }
        }
    }

    private func hideSignatureHelp() {
        if let signatureToken, let index = activeTabIndex, openTabs.indices.contains(index) { lspManager?.cancel(signatureToken, url: openTabs[index].url) }
        signatureToken = nil
        signatureHelp = nil
        signatureCard.hide()
    }

    /// The signature with the parameter being typed in bold, then that parameter's own
    /// documentation (or the signature's).
    static func render(_ help: LSPSignatureHelp) -> NSAttributedString {
        let signature = help.current
        let code = DS.Text.code(12, weight: .regular), bold = DS.Text.code(12, weight: .bold)
        let text = NSMutableAttributedString()
        if help.signatures.count > 1 {
            text.append(NSAttributedString(string: "\(help.activeSignature + 1)/\(help.signatures.count)  ", attributes: [.font: DS.Text.caption(), .foregroundColor: NSColor.tertiaryLabelColor]))
        }
        let label = NSMutableAttributedString(string: signature.label, attributes: [.font: code, .foregroundColor: NSColor.secondaryLabelColor])
        let active = help.currentParameter
        if signature.parameters.indices.contains(active), let range = signature.parameters[active].range,
           range.lowerBound >= 0, range.upperBound <= (signature.label as NSString).length {
            label.addAttributes([.font: bold, .foregroundColor: NSColor.labelColor], range: NSRange(location: range.lowerBound, length: range.count))
        }
        text.append(label)
        let doc = signature.parameters.indices.contains(active) ? (signature.parameters[active].documentation ?? signature.documentation) : signature.documentation
        if let doc, !doc.isEmpty {
            text.append(NSAttributedString(string: "\n"))
            text.append(MarkdownLite.attributed(doc, size: 11.5, color: .secondaryLabelColor))
        }
        return text
    }

    // MARK: - Hover and ⌘-click (SIDE_RFC_IDE_ESSENTIALS.md, L3)

    /// The pointer rested on a word: after half a second, its type and docs (and any problem
    /// there). ⌘ held underlines it: a click goes to its definition.
    func editor(_ engine: EditorEngine, pointerAt characterIndex: Int?, modifiers: NSEvent.ModifierFlags) {
        updateLinkUnderline(at: characterIndex, modifiers: modifiers)
        guard let characterIndex, view.window?.isKeyWindow == true, !completionPopup.isVisible else { return endHover() }
        if let hoverRange, NSLocationInRange(characterIndex, hoverRange) { return }
        endHover()
        guard let range = hoverWordRange(at: characterIndex) else { return }
        hoverRange = range
        let work = DispatchWorkItem { [weak self] in self?.showHover(for: range) }
        hoverTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func editorPointerExited(_ engine: EditorEngine) {
        endHover()
        clearLinkUnderline()
    }

    func editor(_ engine: EditorEngine, commandClickedAt characterIndex: Int) -> Bool {
        guard let index = activeTabIndex, openTabs[index].kind == .text, lspManager != nil,
              LanguageServerRegistry.entry(forExtension: openTabs[index].url.languageExtension) != nil else { return false }
        clearLinkUnderline()
        endHover()
        editor.selectedRange = NSRange(location: characterIndex, length: 0)
        performJumpToDefinition(at: characterIndex, tabIndex: index)
        return true
    }

    /// Quick Help for the symbol at the caret, now.
    @objc func showQuickHelp(_ sender: Any?) {
        guard let range = hoverWordRange(at: editor.selectedRange.location) ?? hoverWordRange(at: max(0, editor.selectedRange.location - 1)) else { return NSSound.beep() }
        endHover()
        hoverRange = range
        showHover(for: range, atCaret: true)
    }

    /// The identifier around a character, or the character itself (a problem can sit on `;`).
    private func hoverWordRange(at characterIndex: Int) -> NSRange? {
        guard let index = activeTabIndex, openTabs[index].kind == .text else { return nil }
        let text = openTabs[index].document.text
        guard characterIndex < text.length else { return nil }
        let unit = text.character(at: characterIndex)
        guard unit != 0x0A, unit != 0x20, unit != 0x09 else { return nil }
        guard CompletionText.isWordUnit(unit) else { return NSRange(location: characterIndex, length: 1) }
        var start = characterIndex, end = characterIndex + 1
        while start > 0, CompletionText.isWordUnit(text.character(at: start - 1)) { start -= 1 }
        while end < text.length, CompletionText.isWordUnit(text.character(at: end)) { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    private func showHover(for range: NSRange, atCaret: Bool = false) {
        hoverTimer = nil
        guard let index = activeTabIndex, openTabs[index].kind == .text else { return }
        let tab = openTabs[index]
        let problems = diagnostics(overlapping: range, in: tab)
        let present: (String?) -> Void = { [weak self] markdown in
            guard let self, self.hoverRange == range, let window = self.view.window,
                  let anchor = self.editor.screenRect(forCharacterRange: range) else { return }
            let content = Self.hoverContent(problems: problems, markdown: markdown)
            guard content.length > 0 else { return self.hoverCard.hide() }
            self.hoverCard.show(content, near: anchor, in: window, preferAbove: true)
        }
        if !problems.isEmpty { present(nil) }
        // Paused in the debugger: the expression's value, as Xcode's data tips show it; the
        // language server's hover when there's none.
        if debugger.isStopped, let expression = debugExpressionRange(around: range, in: tab.document.text) {
            let text = tab.document.text.substring(with: expression)
            Task { [weak self] in
                guard let self else { return }
                if let value = await self.debugger.hoverValue(text) {
                    guard self.hoverRange == range, let window = self.view.window, let anchor = self.editor.screenRect(forCharacterRange: range) else { return }
                    let content = NSMutableAttributedString(attributedString: Self.hoverContent(problems: problems, markdown: nil))
                    if content.length > 0 { content.append(NSAttributedString(string: "\n\n")) }
                    content.append(NSAttributedString(string: text + " = ", attributes: [.font: DS.Text.code(12), .foregroundColor: NSColor.secondaryLabelColor]))
                    content.append(NSAttributedString(string: value, attributes: [.font: DS.Text.code(12, weight: .medium), .foregroundColor: NSColor.labelColor]))
                    self.hoverCard.show(content, near: anchor, in: window, preferAbove: true)
                } else {
                    self.showLanguageServerHover(for: range, tab: tab, problems: problems, atCaret: atCaret, present: present)
                }
            }
            return
        }
        showLanguageServerHover(for: range, tab: tab, problems: problems, atCaret: atCaret, present: present)
    }

    /// A word under the pointer with what it's a member of (`point.x`, `self.items`), for the
    /// debugger to evaluate; nil if it isn't an identifier.
    private func debugExpressionRange(around word: NSRange, in text: NSString) -> NSRange? {
        guard word.length > 0, CompletionText.isWordUnit(text.character(at: word.location)) else { return nil }
        var start = word.location
        // Back through `name.` pairs.
        while start >= 2, text.character(at: start - 1) == 0x2E, CompletionText.isWordUnit(text.character(at: start - 2)) {
            var s = start - 2
            while s > 0, CompletionText.isWordUnit(text.character(at: s - 1)) { s -= 1 }
            start = s
        }
        let first = text.character(at: start)
        guard !(0x30...0x39).contains(first) else { return nil }   // a number, not a name
        return NSRange(location: start, length: NSMaxRange(word) - start)
    }

    private func showLanguageServerHover(for range: NSRange, tab: OpenTab, problems: [LSPDiagnostic], atCaret: Bool, present: @escaping (String?) -> Void) {
        guard let lspManager, lspManager.hovers(forExtension: tab.url.languageExtension) else {
            if problems.isEmpty, atCaret { NSSound.beep() }
            return
        }
        let point = tab.document.rope.position(of: range.location)
        hoverToken = lspManager.hover(url: tab.url, position: LSPPosition(line: point.line, character: point.column)) { [weak self] hover in
            self?.hoverToken = nil
            if hover == nil, problems.isEmpty { return }
            present(hover?.markdown)
        }
    }

    /// Problems whose range touches the word.
    private func diagnostics(overlapping range: NSRange, in tab: OpenTab) -> [LSPDiagnostic] {
        let rope = tab.document.rope
        let line = rope.position(of: range.location).line
        return tab.diagnostics.filter { diagnostic in
            guard diagnostic.range.start.line <= line, diagnostic.range.end.line >= line else { return false }
            let a = rope.offset(line: diagnostic.range.start.line, column: diagnostic.range.start.character)
            let b = rope.offset(line: diagnostic.range.end.line, column: diagnostic.range.end.character)
            return a < NSMaxRange(range) && (b > range.location || (a == b && a == range.location))
        }
    }

    static func hoverContent(problems: [LSPDiagnostic], markdown: String?) -> NSAttributedString {
        let text = NSMutableAttributedString()
        for problem in problems {
            if text.length > 0 { text.append(NSAttributedString(string: "\n")) }
            let color: NSColor = problem.severity == .error ? .systemRed : (problem.severity == .warning ? .systemOrange : .secondaryLabelColor)
            text.append(NSAttributedString(string: "\u{25CF} ", attributes: [.font: DS.Text.caption(), .foregroundColor: color]))
            text.append(NSAttributedString(string: problem.message, attributes: [.font: DS.Text.body(), .foregroundColor: NSColor.labelColor]))
            if let source = problem.source {
                text.append(NSAttributedString(string: "  \(source)", attributes: [.font: DS.Text.caption(), .foregroundColor: NSColor.tertiaryLabelColor]))
            }
        }
        if let markdown, !markdown.isEmpty {
            if text.length > 0 { text.append(NSAttributedString(string: "\n\n")) }
            text.append(MarkdownLite.attributed(markdown))
        }
        return text
    }

    private func endHover() {
        hoverTimer?.cancel()
        hoverTimer = nil
        if let hoverToken, let index = activeTabIndex, openTabs.indices.contains(index) { lspManager?.cancel(hoverToken, url: openTabs[index].url) }
        hoverToken = nil
        hoverRange = nil
        hoverCard.hide()
    }

    private func updateLinkUnderline(at characterIndex: Int?, modifiers: NSEvent.ModifierFlags) {
        guard modifiers.intersection([.command, .option, .shift, .control]) == .command, let characterIndex,
              let index = activeTabIndex, openTabs[index].kind == .text,
              LanguageServerRegistry.entry(forExtension: openTabs[index].url.languageExtension) != nil,
              let range = hoverWordRange(at: characterIndex), range.length > 1 || CompletionText.isWordUnit(openTabs[index].document.text.character(at: range.location)) else {
            return clearLinkUnderline()
        }
        guard range != linkRange else { return }
        linkRange = range
        openTabs[index].document.setDecorations(.link, [(range, .linkColor)])
    }

    private func clearLinkUnderline() {
        guard linkRange != nil else { return }
        linkRange = nil
        if let index = activeTabIndex, openTabs.indices.contains(index), openTabs[index].kind == .text {
            openTabs[index].document.setDecorations(.link, [])
        }
    }

    // MARK: - Bracket matching

    private static let bracketPairs: [Character: Character] = ["(": ")", "[": "]", "{": "}"]
    private static let bracketPairsReversed: [Character: Character] = [")": "(", "]": "[", "}": "{"]
    private static let bracketHighlightColor = DS.Color.scrimMedium

    func editorSelectionDidChange(_ engine: EditorEngine) {
        if isWriting { followCaretWhileWriting() }
        updateBracketHighlight()
        updateCaretPosition()
        editor.setNeedsDisplay()
        // Typing itself moves the selection, which fires this same delegate method within the
        // same call chain as textDidChange (before its just-scheduled completion request ever
        // gets to run) — only treat this as a real "user navigated away" dismissal signal when
        // it wasn't just a consequence of an edit or of accepting a completion.
        guard !isAcceptingCompletion, !suppressNextSelectionDismiss else {
            suppressNextSelectionDismiss = false
            return
        }
        endCompletion()
        hideSignatureHelp()
        endHover()
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
        lastTypedText = replacementString?.isEmpty == false ? replacementString : nil
        guard let replacementString, replacementString.count == 1, let char = replacementString.first else { return true }

        if Self.autoCloseClosers.contains(char), affectedCharRange.length == 0 {
            let ns = engine.document?.text ?? ""
            if affectedCharRange.location < ns.length, ns.character(at: affectedCharRange.location) == char.utf16.first {
                // Stepping over the closer is typing it: lists and cards follow, not dismiss.
                suppressNextSelectionDismiss = true
                engine.selectedRange = NSRange(location: affectedCharRange.location + 1, length: 0)
                updateSignatureHelp(typed: String(char))
                return false
            }
        }

        if affectedCharRange.length == 0, let outdent = Self.outdentedCloser(char, in: engine.document?.text ?? "", at: affectedCharRange.location) {
            engine.insertText(outdent.text, replacementRange: outdent.range)
            return false
        }

        if let closing = Self.autoClosePairs[char], affectedCharRange.length == 0 {
            engine.insertText("\(char)\(closing)", replacementRange: affectedCharRange)
            suppressNextSelectionDismiss = true
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
        if completionPopup.isVisible {
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                completionPopup.moveSelection(-1)
                return true
            case #selector(NSResponder.moveDown(_:)):
                completionPopup.moveSelection(1)
                return true
            case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)):
                completionPopup.moveSelection(-CompletionPopup.maxVisibleRows)
                return true
            case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)):
                completionPopup.moveSelection(CompletionPopup.maxVisibleRows)
                return true
            case #selector(NSResponder.insertNewline(_:)):
                acceptSelectedCompletion(replacing: false)
                return true
            case #selector(NSResponder.insertTab(_:)):
                acceptSelectedCompletion(replacing: true)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                endCompletion()
                return true
            default:
                break
            }
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)), signatureCard.isVisible || hoverCard.isVisible {
            hideSignatureHelp()
            endHover()
            return true
        }
        if commandSelector == #selector(NSResponder.complete(_:)) {
            updateCompletion(explicit: true)
            return true
        }
        guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
        let ns = engine.document?.text ?? ""
        let selectedRange = engine.selectedRange
        guard let newline = Self.newline(in: ns, replacing: selectedRange) else { return false }
        engine.insertText(newline.text, replacementRange: selectedRange)
        engine.selectedRange = NSRange(location: selectedRange.location + newline.caret, length: 0)
        return true
    }

    /// Return: the line's indent, one level more after an opening bracket, and between a pair
    /// (`{|}`) the closer on a line of its own at the outer indent, the caret on the one between.
    static func newline(in ns: NSString, replacing selection: NSRange) -> (text: String, caret: Int)? {
        let lineRange = ns.lineRange(for: NSRange(location: selection.location, length: 0))
        let before = ns.substring(with: NSRange(location: lineRange.location, length: selection.location - lineRange.location))
        let indent = String(before.prefix(while: { $0 == " " || $0 == "\t" }))
        let unit = indentUnit(in: ns, near: lineRange)
        guard let last = before.trimmingCharacters(in: .whitespaces).last, let closer = bracketPairs[last] else {
            let text = "\n" + indent
            return (text, (text as NSString).length)
        }
        let after = NSMaxRange(selection)
        var next = after
        while next < NSMaxRange(lineRange), let scalar = UnicodeScalar(ns.character(at: next)), scalar == " " || scalar == "\t" { next += 1 }
        if next < ns.length, let scalar = UnicodeScalar(ns.character(at: next)), Character(scalar) == closer {
            let opened = "\n" + indent + unit
            return (opened + "\n" + indent, (opened as NSString).length)
        }
        let text = "\n" + indent + unit
        return (text, (text as NSString).length)
    }

    /// One level of indentation as the file writes it: a tab if the lines around use tabs,
    /// else four spaces, or two where that's what the file indents by.
    static func indentUnit(in ns: NSString, near lineRange: NSRange) -> String {
        let start = max(0, lineRange.location - 4000), end = min(ns.length, NSMaxRange(lineRange) + 4000)
        var tabs = 0, twos = 0, fours = 0
        ns.enumerateSubstrings(in: NSRange(location: start, length: end - start), options: [.byLines, .substringNotRequired]) { _, range, _, _ in
            guard range.length > 0 else { return }
            if ns.character(at: range.location) == 0x09 { tabs += 1; return }
            var spaces = 0
            while spaces < range.length, ns.character(at: range.location + spaces) == 0x20 { spaces += 1 }
            guard spaces > 0, spaces < range.length else { return }
            if spaces % 4 == 0 { fours += 1 } else if spaces % 2 == 0 { twos += 1 }
        }
        if tabs > fours + twos { return "\t" }
        return twos > fours ? "  " : "    "
    }

    /// A closer typed on a line with nothing else on it goes to its opener's indent.
    static func outdentedCloser(_ closer: Character, in ns: NSString, at location: Int) -> (range: NSRange, text: String)? {
        guard let open = bracketPairsReversed[closer] else { return nil }
        let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
        let before = ns.substring(with: NSRange(location: lineRange.location, length: location - lineRange.location))
        guard !before.isEmpty, before.allSatisfy({ $0 == " " || $0 == "\t" }) else { return nil }
        guard let openUnit = String(open).utf16.first, let closeUnit = String(closer).utf16.first else { return nil }
        var depth = 0, i = location - 1
        let limit = max(0, location - maxBracketScanDistance)
        while i >= limit {
            let c = ns.character(at: i)
            if c == closeUnit { depth += 1 } else if c == openUnit {
                if depth == 0 { break }
                depth -= 1
            }
            i -= 1
        }
        guard i >= limit, i >= 0 else { return nil }
        let openerLine = ns.lineRange(for: NSRange(location: i, length: 0))
        let openerIndent = String(ns.substring(with: openerLine).prefix(while: { $0 == " " || $0 == "\t" }))
        guard openerIndent != before else { return nil }
        return (NSRange(location: lineRange.location, length: location - lineRange.location), openerIndent + String(closer))
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
        let about = appMenu.addItem(withTitle: "About Side", action: #selector(AppDelegate.showAboutPanel(_:)), keyEquivalent: "")
        about.target = AppDelegate.shared
        let updates = appMenu.addItem(withTitle: "Check for Updates\u{2026}", action: #selector(Updates.checkForUpdates(_:)), keyEquivalent: "")
        updates.target = Updates.shared
        appMenu.addItem(NSMenuItem.separator())
        let preferences = appMenu.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showPreferences), keyEquivalent: "")
        Shortcuts.bind(preferences, "app.preferences")
        preferences.target = NSApp.delegate as? AppDelegate
        appMenu.addItem(NSMenuItem.separator())
        Shortcuts.bind(appMenu.addItem(withTitle: "Hide Side", action: #selector(NSApplication.hide(_:)), keyEquivalent: ""), "app.hide")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "")
        Shortcuts.bind(hideOthers, "app.hideOthers")
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        Shortcuts.bind(appMenu.addItem(withTitle: "Quit Side", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""), "app.quit")
        appItem.submenu = appMenu

        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")
        let newWindowItem = fileMenu.addItem(withTitle: "New Window", action: #selector(AppDelegate.newWindow), keyEquivalent: "")
        Shortcuts.bind(newWindowItem, "file.newWindow")
        newWindowItem.target = NSApp.delegate as? AppDelegate
        Shortcuts.bind(fileMenu.addItem(withTitle: "New File", action: #selector(newFile), keyEquivalent: ""), "file.newFile")
        // Explicitly targeted at the app delegate rather than left nil-target: as
        // responder-chain actions these went *disabled* whenever no editor held first responder,
        // which stranded anyone in the no-file state — the exact "Open Project was disabled"
        // dogfood failure. Opening a project is an app-level command, not an editor one.
        let newProjectItem = fileMenu.addItem(withTitle: "New Project…", action: #selector(AppDelegate.newProjectFromMenu), keyEquivalent: "")
        Shortcuts.bind(newProjectItem, "file.newProject")
        newProjectItem.target = NSApp.delegate as? AppDelegate
        let openProjectItem = fileMenu.addItem(withTitle: "Open Project…", action: #selector(AppDelegate.openProjectFromMenu), keyEquivalent: "")
        Shortcuts.bind(openProjectItem, "file.openProject")
        openProjectItem.target = NSApp.delegate as? AppDelegate
        openRecentMenu.delegate = self
        let openRecentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        openRecentItem.submenu = openRecentMenu
        fileMenu.addItem(openRecentItem)
        fileMenu.addItem(NSMenuItem.separator())
        Shortcuts.bind(fileMenu.addItem(withTitle: "Save", action: #selector(save), keyEquivalent: ""), "file.save")
        let saveAsItem = fileMenu.addItem(withTitle: "Save As…", action: #selector(saveAs), keyEquivalent: "")
        Shortcuts.bind(saveAsItem, "file.saveAs")
        Shortcuts.bind(fileMenu.addItem(withTitle: "Revert to Saved", action: #selector(revertToSaved), keyEquivalent: ""), "file.revert")
        fileMenu.addItem(NSMenuItem.separator())
        Shortcuts.bind(fileMenu.addItem(withTitle: "Close Tab", action: #selector(closeActiveTab), keyEquivalent: ""), "file.closeTab")
        fileMenu.addItem(NSMenuItem.separator())
        Shortcuts.bind(fileMenu.addItem(withTitle: "Build LaTeX Document", action: #selector(buildLaTeX(_:)), keyEquivalent: ""), "file.buildLaTeX")
        Shortcuts.bind(fileMenu.addItem(withTitle: "Show in PDF", action: #selector(showInPDF(_:)), keyEquivalent: ""), "file.showInPDF")
        fileItem.submenu = fileMenu

        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        // Replacing NSApp.mainMenu wholesale means we lose the standard Edit items AppKit
        // normally provides for free — without these, Cmd+A/C/X/V had nothing claiming their
        // key equivalents, so they never reached the text view's built-in key bindings.
        Shortcuts.bind(editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: ""), "edit.undo")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "")
        Shortcuts.bind(redo, "edit.redo")
        editMenu.addItem(NSMenuItem.separator())
        Shortcuts.bind(editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: ""), "edit.cut")
        Shortcuts.bind(editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: ""), "edit.copy")
        Shortcuts.bind(editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: ""), "edit.paste")
        Shortcuts.bind(editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: ""), "edit.selectAll")
        editMenu.addItem(NSMenuItem.separator())
        // Direction 02 §5.3 — a Make action, so it's live only while Make is on screen.
        Shortcuts.bind(editMenu.addItem(withTitle: "Instruct…", action: #selector(instructAtSelection), keyEquivalent: ""), "edit.instruct")
        editMenu.addItem(NSMenuItem.separator())
        // Find is a mode of the palette (SIDE_RFC_FIND_REVIEW_TRACKS.md, F1); the items target
        // the shell, which is in the responder chain whether the editor or the palette has focus.
        Shortcuts.bind(editMenu.addItem(withTitle: "Find…", action: #selector(ShellViewController.showFind(_:)), keyEquivalent: ""), "find.find")
        let findReplace = editMenu.addItem(withTitle: "Find and Replace…", action: #selector(ShellViewController.showFindAndReplace(_:)), keyEquivalent: "")
        Shortcuts.bind(findReplace, "find.replace")
        Shortcuts.bind(editMenu.addItem(withTitle: "Find Next", action: #selector(ShellViewController.findNext(_:)), keyEquivalent: ""), "find.next")
        let findPrevious = editMenu.addItem(withTitle: "Find Previous", action: #selector(ShellViewController.findPrevious(_:)), keyEquivalent: "")
        Shortcuts.bind(findPrevious, "find.previous")
        Shortcuts.bind(editMenu.addItem(withTitle: "Use Selection for Find", action: #selector(ShellViewController.useSelectionForFind(_:)), keyEquivalent: ""), "find.useSelection")
        editMenu.addItem(NSMenuItem.separator())
        Shortcuts.bind(editMenu.addItem(withTitle: "Show Completions", action: #selector(showCompletions(_:)), keyEquivalent: ""), "editor.complete")
        Shortcuts.bind(editMenu.addItem(withTitle: "Format Document", action: #selector(formatDocument(_:)), keyEquivalent: ""), "editor.format")
        Shortcuts.bind(editMenu.addItem(withTitle: "Show Quick Help", action: #selector(showQuickHelp(_:)), keyEquivalent: ""), "editor.quickHelp")
        editMenu.addItem(NSMenuItem.separator())
        Shortcuts.bind(editMenu.addItem(withTitle: "Rename Symbol\u{2026}", action: #selector(renameSymbol(_:)), keyEquivalent: ""), "editor.rename")
        Shortcuts.bind(editMenu.addItem(withTitle: "Quick Fix\u{2026}", action: #selector(showQuickFixes(_:)), keyEquivalent: ""), "editor.quickFix")
        editItem.submenu = editMenu

        // What the user actually toggles about the *presentation* of the workspace, as its own
        // top-level menu — a markdown preview toggle buried in File read as a file operation.
        let viewItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        let viewMenu = NSMenu(title: "View")
        // ⇧⌘V, not ⌘M — ⌘M is the system's Minimize, which this used to shadow.
        let markdownPreview = viewMenu.addItem(withTitle: "Toggle Markdown Preview", action: #selector(toggleMarkdownPreview), keyEquivalent: "")
        Shortcuts.bind(markdownPreview, "view.markdownPreview")
        // The app's, not Make's: Make is in the responder chain only while it has focus, and the
        // explorer is a panel of its own, so with focus there, in the top row or in another stage
        // the shortcut did nothing (2026-10-29).
        let explorer = viewMenu.addItem(withTitle: "Toggle File Explorer", action: #selector(AppDelegate.toggleFileExplorer(_:)), keyEquivalent: "")
        explorer.target = AppDelegate.shared
        Shortcuts.bind(explorer, "view.fileExplorer")
        // Folding lives in the editor (Alloy), which is in the responder chain while it has focus.
        let foldingItem = NSMenuItem(title: "Code Folding", action: nil, keyEquivalent: "")
        let foldingMenu = NSMenu(title: "Code Folding")
        for (title, selector, id) in [("Fold", #selector(AlloyEditorView.foldAtCaret(_:)), "editor.fold"),
                                      ("Unfold", #selector(AlloyEditorView.unfoldAtCaret(_:)), "editor.unfold"),
                                      ("Fold All", #selector(AlloyEditorView.foldAll(_:)), "editor.foldAll"),
                                      ("Unfold All", #selector(AlloyEditorView.unfoldAll(_:)), "editor.unfoldAll")] {
            Shortcuts.bind(foldingMenu.addItem(withTitle: title, action: selector, keyEquivalent: ""), id)
        }
        foldingItem.submenu = foldingMenu
        viewMenu.addItem(foldingItem)
        Shortcuts.bind(viewMenu.addItem(withTitle: "Show Minimap", action: #selector(toggleMinimap(_:)), keyEquivalent: ""), "view.minimap")
        viewMenu.addItem(NSMenuItem.separator())
        Shortcuts.bind(viewMenu.addItem(withTitle: "Live Markdown", action: #selector(toggleLiveMarkdown(_:)), keyEquivalent: ""), "view.liveMarkdown")
        // The shell's: it hides its own chrome as well as Make's.
        Shortcuts.bind(viewMenu.addItem(withTitle: "Writer Mode", action: #selector(ShellViewController.toggleWriterMode(_:)), keyEquivalent: ""), "view.writerMode")
        // The shell's: the stage in front decides what grows (Make's text, Run's terminal).
        viewMenu.addItem(NSMenuItem.separator())
        Shortcuts.bind(viewMenu.addItem(withTitle: "Zoom In", action: #selector(ShellViewController.zoomIn(_:)), keyEquivalent: ""), "view.zoomIn")
        Shortcuts.bind(viewMenu.addItem(withTitle: "Zoom Out", action: #selector(ShellViewController.zoomOut(_:)), keyEquivalent: ""), "view.zoomOut")
        Shortcuts.bind(viewMenu.addItem(withTitle: "Actual Size", action: #selector(ShellViewController.actualSize(_:)), keyEquivalent: ""), "view.actualSize")
        viewItem.submenu = viewMenu

        // Markdown's formatting (its shortcuts are live in Markdown files only).
        let formatItem = NSMenuItem(title: "Format", action: nil, keyEquivalent: "")
        let formatMenu = NSMenu(title: "Format")
        Shortcuts.bind(formatMenu.addItem(withTitle: "Bold", action: #selector(formatBold(_:)), keyEquivalent: ""), "format.bold")
        Shortcuts.bind(formatMenu.addItem(withTitle: "Italic", action: #selector(formatItalic(_:)), keyEquivalent: ""), "format.italic")
        Shortcuts.bind(formatMenu.addItem(withTitle: "Link\u{2026}", action: #selector(formatLink(_:)), keyEquivalent: ""), "format.link")
        formatItem.submenu = formatMenu

        // The editing commands a keymap binds (Alloy's, reached through the responder chain).
        let editorItem = NSMenuItem(title: "Editor", action: nil, keyEquivalent: "")
        let editorMenu = NSMenu(title: "Editor")
        let groups: [[(String, Selector, String)]] = [
            [("Toggle Comment", #selector(AlloyTextView.toggleLineComment(_:)), "editor.toggleComment")],
            [("Move Line Up", #selector(AlloyTextView.moveLinesUp(_:)), "editor.moveLineUp"),
             ("Move Line Down", #selector(AlloyTextView.moveLinesDown(_:)), "editor.moveLineDown"),
             ("Duplicate Line", #selector(AlloyTextView.duplicateLines(_:)), "editor.duplicateLine"),
             ("Delete Line", #selector(AlloyTextView.deleteLines(_:)), "editor.deleteLine"),
             ("Join Lines", #selector(AlloyTextView.joinLines(_:)), "editor.joinLines")],
            [("Indent", #selector(AlloyTextView.indentLines(_:)), "editor.indent"),
             ("Outdent", #selector(AlloyTextView.outdentLines(_:)), "editor.outdent")],
            [("Select Next Occurrence", #selector(AlloyTextView.selectNextOccurrence(_:)), "editor.selectNextOccurrence"),
             ("Select All Occurrences", #selector(AlloyTextView.selectAllOccurrences(_:)), "editor.selectAllOccurrences"),
             ("Expand Selection", #selector(AlloyTextView.expandSelection(_:)), "editor.expandSelection"),
             ("Shrink Selection", #selector(AlloyTextView.shrinkSelection(_:)), "editor.shrinkSelection"),
             ("Go to Matching Bracket", #selector(AlloyTextView.goToMatchingBracket(_:)), "editor.matchingBracket")],
        ]
        for (index, group) in groups.enumerated() {
            if index > 0 { editorMenu.addItem(.separator()) }
            for (title, selector, id) in group { Shortcuts.bind(editorMenu.addItem(withTitle: title, action: selector, keyEquivalent: ""), id) }
        }
        editorItem.submenu = editorMenu

        let navigateItem = NSMenuItem(title: "Navigate", action: nil, keyEquivalent: "")
        let navigateMenu = NSMenu(title: "Navigate")
        // Palette items target the shell, which is always in the responder chain — as Make
        // actions they were disabled on every other stage.
        Shortcuts.bind(navigateMenu.addItem(withTitle: "Quick Open", action: #selector(ShellViewController.showQuickOpen(_:)), keyEquivalent: ""), "navigate.quickOpen")
        let commandPalette = navigateMenu.addItem(withTitle: "Command Palette", action: #selector(ShellViewController.showCommandPalette(_:)), keyEquivalent: "")
        Shortcuts.bind(commandPalette, "navigate.commandPalette")
        Shortcuts.bind(navigateMenu.addItem(withTitle: "Go to Line…", action: #selector(showGoToLine), keyEquivalent: ""), "navigate.goToLine")
        let goToSymbol = navigateMenu.addItem(withTitle: "Go to Symbol…", action: #selector(ShellViewController.showGoToSymbol(_:)), keyEquivalent: "")
        Shortcuts.bind(goToSymbol, "navigate.goToSymbol")
        let findInProject = NSMenuItem(title: "Find in Project…", action: #selector(ShellViewController.showFindInProject(_:)), keyEquivalent: "")
        Shortcuts.bind(findInProject, "find.inProject")
        navigateMenu.addItem(findInProject)
        let jumpToDef = navigateMenu.addItem(withTitle: "Jump to Definition", action: #selector(jumpToDefinition), keyEquivalent: "")
        Shortcuts.bind(jumpToDef, "navigate.jumpToDefinition")
        Shortcuts.bind(navigateMenu.addItem(withTitle: "Find References", action: #selector(findReferences(_:)), keyEquivalent: ""), "editor.references")
        Shortcuts.bind(navigateMenu.addItem(withTitle: "Show Problems", action: #selector(showProblems(_:)), keyEquivalent: ""), "editor.problems")
        navigateMenu.addItem(NSMenuItem.separator())
        // Stage navigation — ⌘⌥1–4 for the four working stages, ⌘⌥0 for Tracks (Direction 02
        // §3.8). Every stage has an item whether or not it is pinned: unpinning never removes a
        // way in. ⌘1–⌘8 stay with tabs.
        for (index, stage) in ShellViewController.Stage.allCases.enumerated() {
            let item = navigateMenu.addItem(withTitle: "Go to \(stage.title)", action: #selector(ShellViewController.jumpToStage(_:)), keyEquivalent: "")
            Shortcuts.bind(item, "stage.\(stage)")
            item.tag = index
        }
        navigateMenu.addItem(NSMenuItem.separator())
        // Eight sibling items at the top level was clutter; the shortcuts still work from the
        // submenu — a keyEquivalent doesn't care how deeply its item is nested.
        let tabsItem = NSMenuItem(title: "Tabs", action: nil, keyEquivalent: "")
        let tabsMenu = NSMenu(title: "Tabs")
        for i in 1...8 {
            let item = tabsMenu.addItem(withTitle: "Switch to Tab \(i)", action: #selector(ShellViewController.switchToTabShortcut(_:)), keyEquivalent: "")
            Shortcuts.bind(item, "tabs.\(i)")
            item.tag = i - 1
        }
        let lastTab = tabsMenu.addItem(withTitle: "Switch to Last Tab", action: #selector(ShellViewController.switchToTabShortcut(_:)), keyEquivalent: "")
        Shortcuts.bind(lastTab, "tabs.last")
        lastTab.tag = -1
        tabsMenu.addItem(NSMenuItem.separator())
        let nextTab = tabsMenu.addItem(withTitle: "Next Tab", action: #selector(ShellViewController.selectNextTab(_:)), keyEquivalent: "")
        Shortcuts.bind(nextTab, "tabs.next")
        let previousTab = tabsMenu.addItem(withTitle: "Previous Tab", action: #selector(ShellViewController.selectPreviousTab(_:)), keyEquivalent: "")
        Shortcuts.bind(previousTab, "tabs.previous")
        tabsItem.submenu = tabsMenu
        navigateMenu.addItem(tabsItem)
        navigateItem.submenu = navigateMenu

        // Targets nothing here — RunWorkspaceViewController implements these selectors and
        // picks them up via the responder chain while the Run stage is active, same pattern
        // as "New Window" targeting AppDelegate directly above.
        let runItem = NSMenuItem(title: "Terminal", action: nil, keyEquivalent: "")
        let runMenu = NSMenu(title: "Terminal")
        Shortcuts.bind(runMenu.addItem(withTitle: "New Terminal Tab", action: #selector(RunWorkspaceViewController.newSession), keyEquivalent: ""), "run.newTerminal")
        Shortcuts.bind(runMenu.addItem(withTitle: "Stop", action: #selector(RunWorkspaceViewController.stopActiveSession), keyEquivalent: ""), "run.stop")
        let restart = runMenu.addItem(withTitle: "Restart Terminal", action: #selector(RunWorkspaceViewController.restartActiveSession), keyEquivalent: "")
        Shortcuts.bind(restart, "run.restart")
        Shortcuts.bind(runMenu.addItem(withTitle: "Rerun Last Command", action: #selector(RunWorkspaceViewController.rerunLastCommand), keyEquivalent: ""), "run.rerun")
        runItem.submenu = runMenu

        // Make's own (SIDE_RFC_DEBUGGER.md): live while Make is on screen.
        let debugItem = NSMenuItem(title: "Debug", action: nil, keyEquivalent: "")
        let debugMenu = NSMenu(title: "Debug")
        for (index, group) in [[("Start Debugging", #selector(startDebugging(_:)), "debug.start"),
                                ("Pause or Continue", #selector(pauseOrContinueDebugging(_:)), "debug.pauseContinue"),
                                ("Stop Debugging", #selector(stopDebugging(_:)), "debug.stop")],
                               [("Step Over", #selector(debugStepOver(_:)), "debug.stepOver"),
                                ("Step Into", #selector(debugStepIn(_:)), "debug.stepIn"),
                                ("Step Out", #selector(debugStepOut(_:)), "debug.stepOut")],
                               [("Choose What to Debug\u{2026}", #selector(chooseWhatToDebug(_:)), "debug.choose"),
                                ("Attach to Process\u{2026}", #selector(attachToProcess(_:)), "debug.attach")],
                               [("Toggle Breakpoint", #selector(toggleBreakpoint(_:)), "debug.toggleBreakpoint")]].enumerated() {
            if index > 0 { debugMenu.addItem(.separator()) }
            for (title, selector, id) in group { Shortcuts.bind(debugMenu.addItem(withTitle: title, action: selector, keyEquivalent: ""), id) }
        }
        debugItem.submenu = debugMenu

        // Same responder-chain pattern as Run above — TracksWorkspaceViewController picks this up
        // while the Tracks stage is active.
        let trackItem = NSMenuItem(title: "Track", action: nil, keyEquivalent: "")
        let trackMenu = NSMenu(title: "Track")
        let newTrack = trackMenu.addItem(withTitle: "New Track…", action: #selector(TracksWorkspaceViewController.newTrackTapped), keyEquivalent: "")
        Shortcuts.bind(newTrack, "track.new")
        let trackPopover = trackMenu.addItem(withTitle: "Switch Track…", action: #selector(ShellViewController.toggleTrackPopover(_:)), keyEquivalent: "")
        Shortcuts.bind(trackPopover, "track.switch")
        let stagesItem = NSMenuItem(title: "Pinned Stages", action: nil, keyEquivalent: "")
        let stagesMenu = NSMenu(title: "Pinned Stages")
        for stage in StagePins.pinnable {
            let item = stagesMenu.addItem(withTitle: stage.title, action: #selector(ShellViewController.togglePinnedStage(_:)), keyEquivalent: "")
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
        Shortcuts.bind(windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: ""), "window.minimize")
        Shortcuts.bind(windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""), "window.zoom")
        windowMenu.addItem(NSMenuItem.separator())
        // Library is a window, not a stage (RFC R6): app-level, so it targets the delegate.
        let library = windowMenu.addItem(withTitle: "Library", action: #selector(AppDelegate.showLibrary), keyEquivalent: "")
        Shortcuts.bind(library, "window.library")
        library.target = NSApp.delegate as? AppDelegate
        // Every terminal running in a keeper, across projects (SIDE_RFC_SESSION_RESTORE.md).
        let terminals = windowMenu.addItem(withTitle: "Running Terminals", action: #selector(AppDelegate.showRunningTerminals), keyEquivalent: "")
        Shortcuts.bind(terminals, "window.runningTerminals")
        // Project switching in one window (prototype): ⌃1–9, and next and previous.
        let projectsItem = NSMenuItem(title: "Projects", action: nil, keyEquivalent: "")
        let projectsMenu = NSMenu(title: "Projects")
        Shortcuts.bind(projectsMenu.addItem(withTitle: "Switch Project\u{2026}", action: #selector(ShellViewController.showProjectSwitcher(_:)), keyEquivalent: ""), "project.switcher")
        Shortcuts.bind(projectsMenu.addItem(withTitle: "Next Project", action: #selector(ShellViewController.switchToNextProject(_:)), keyEquivalent: ""), "project.next")
        Shortcuts.bind(projectsMenu.addItem(withTitle: "Previous Project", action: #selector(ShellViewController.switchToPreviousProject(_:)), keyEquivalent: ""), "project.previous")
        projectsMenu.addItem(NSMenuItem.separator())
        for number in 1...9 {
            let item = projectsMenu.addItem(withTitle: "Switch to Project \(number)", action: #selector(ShellViewController.switchToProjectNumber(_:)), keyEquivalent: "")
            Shortcuts.bind(item, "project.\(number)")
            item.tag = number - 1
        }
        projectsItem.submenu = projectsMenu
        terminals.menu?.addItem(projectsItem)
        terminals.target = NSApp.delegate as? AppDelegate
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu

        main.addItem(appItem); main.addItem(fileItem); main.addItem(editItem); main.addItem(formatItem); main.addItem(viewItem); main.addItem(editorItem); main.addItem(navigateItem); main.addItem(runItem); main.addItem(debugItem); main.addItem(trackItem); main.addItem(windowItem)
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
        let url = openTabs[index].url
        performSave(tabID: openTabs[index].id) { [weak self] saved in
            // A LaTeX document with its preview open builds again.
            guard saved, let self, let index = self.openTabs.firstIndex(where: { $0.url == url }) else { return }
            self.latex.sourceSaved(url, text: self.openTabs[index].document.string)
        }
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
        openTabs.append(OpenTab(url: url, kind: .text, document: editor.makeDocument(""), undoManager: Self.makeUndoManager(), dirty: false, isUntitled: true, knownDiskStamp: nil))
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
            guard let before = self.indexForTab(id: tabID).map({ self.openTabs[$0] }) else { completion(false); return }
            self.writeTabToDiskForced(tabID: tabID, url: newURL, asNewFile: true) { success in
                if success {
                    self.followSaveAs(from: before.url, wasUntitled: before.isUntitled, to: newURL)
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

    /// The language server knew the document by its old name, or (untitled) not at all, and
    /// edits reached it and the breakpoints only under a name it had open: so the saved file got
    /// no diagnostics or completion, and its breakpoints stayed put while lines moved
    /// (2026-09-30 audit, EDT-7). The old name is closed and the new one opened.
    private func followSaveAs(from oldURL: URL, wasUntitled: Bool, to newURL: URL) {
        guard wasUntitled || oldURL != newURL else { return }
        if !wasUntitled { lspManager?.closed(url: oldURL) }
        announceToLanguageServer(newURL)
    }

    private func writeTabToDisk(tabID: UUID, url: URL, completion: @escaping (Bool) -> Void) {
        guard let index = indexForTab(id: tabID), let window = view.window else { completion(false); return }
        let tab = openTabs[index]
        let onDiskModDate = diskStamp(of: url)
        // `diskStamp(of:)` returning nil while we have a known prior date doesn't mean
        // "unchanged, nothing to check" — it means the file is *gone*. That case used to fall
        // through the `onDisk > known` comparison entirely (nil isn't `> known`) straight to a
        // forced write, silently resurrecting a file the user (or a branch switch, or a script)
        // had deleted, with no indication anything unusual had happened.
        if tab.knownDiskStamp != nil, onDiskModDate == nil {
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
        if let known = tab.knownDiskStamp, let onDisk = onDiskModDate, onDisk != known {
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

    /// What Save As writes `content` as: the tab's own format, or UTF-8 with its line ending
    /// when the old encoding can't hold the text.
    static func saveAsFormat(for content: String, current: TextFileCodec.Format) -> TextFileCodec.Format {
        TextFileCodec.encode(content, as: current) != nil ? current : TextFileCodec.Format(encoding: .utf8, byteOrderMark: false, lineEnding: current.lineEnding)
    }

    /// `asNewFile`: Save As. The tab moves to `url` only once the write succeeded (it moved
    /// first, so a failed Save As left it naming a file that didn't exist), and text the old
    /// encoding can't hold is written as UTF-8, which the refusal below tells people to do
    /// (2026-09-30 audit, H14: Save As kept the old encoding and refused the same way).
    private func writeTabToDiskForced(tabID: UUID, url: URL, asNewFile: Bool = false, completion: @escaping (Bool) -> Void) {
        guard let index = indexForTab(id: tabID) else { completion(false); return }
        let content = openTabs[index].document.string
        let format = asNewFile ? Self.saveAsFormat(for: content, current: openTabs[index].format) : openTabs[index].format
        do {
            // The file's own encoding, BOM and line ending — bytes the user didn't touch stay
            // as they were. A character the encoding can't hold is a refusal, not a transcode.
            guard let data = TextFileCodec.encode(content, as: format) else {
                throw CocoaError(.fileWriteInapplicableStringEncoding, userInfo: [NSLocalizedDescriptionKey: "This file is \(format.encodingName), and the buffer now contains a character that encoding can't represent. Save As a new file to keep it as UTF-8."])
            }
            try data.write(to: url, options: .atomic)
            if asNewFile {
                openTabs[index].url = url
                openTabs[index].isUntitled = false
                openTabs[index].format = format
            }
            // The user's own save — a checkpoint being written right now mustn't claim it
            // as the agent's (`UserSaveLog`, audit F4).
            UserSaveLog.shared.record(url)
            lspManager?.saved(url: url)
            openTabs[index].savedStamp = ContentStamp(content)
            openTabs[index].knownDiskStamp = diskStamp(of: url)
            openTabs[index].hasExternalChange = false
            if activeTabIndex == index { externalChangeBanner.isHidden = true }
            applyTopInsets()
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
        // Settings → Languages: off, on (the project's formatter, else the language server's),
        // or as before (the project's formatter when it has one).
        let setting = LanguageSettings.shared.formatOnSave(forExtension: url.languageExtension)
        guard setting != false, let focusedRoot, let formatter = Self.formatterCommand(for: url, projectRoot: focusedRoot) else {
            if setting == true, let index = indexForTab(id: tabID), activeTabIndex == index,
               let lspManager, lspManager.formats(forExtension: url.languageExtension) {
                formatWithLanguageServer(tabID: tabID, original: contentAtSaveTime, then: { [weak self] in self?.saveAfterFormatting(tabID: tabID) })
            }
            finishSave(tabID: tabID)
            completion(true)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = Process()
            process.environment = SpawnEnvironment.current()
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
                // leave knownDiskStamp pointing at the pre-formatter write and trigger
                // a false "changed on disk" prompt on the next save.
                self.openTabs[index].knownDiskStamp = self.diskStamp(of: url)
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

    /// The project's formatter reading the buffer from stdin and writing the result to stdout,
    /// for Format Document (the saved file isn't touched).
    static func stdinFormatterCommand(for url: URL, projectRoot: URL) -> (executable: String, args: [String])? {
        switch url.pathExtension.lowercased() {
        case "js", "jsx", "ts", "tsx", "json", "md", "css", "scss", "html", "yaml", "yml":
            // The project's own Prettier, or a config that's code, only for a trusted project
            // (2026-09-30 audit, SEC-11: saving a file ran the repository's code).
            let trusted = ProjectTrust.isTrusted(projectRoot)
            let local = projectRoot.appendingPathComponent("node_modules/.bin/prettier").path
            if trusted, FileManager.default.isExecutableFile(atPath: local) { return (local, ["--stdin-filepath", url.path]) }
            if !trusted, ProjectTrust.hasCodePrettierConfig(projectRoot) { return nil }
            if let global = which("prettier") { return (global, ["--stdin-filepath", url.path]) }
            return nil
        case "swift":
            if let global = which("swift-format") { return (global, ["format", "--assume-filename", url.path, "-"]) }
            return nil
        default:
            return nil
        }
    }

    /// Format Document: the project's formatter (prettier, swift-format), or else the file's
    /// language server. Applied as one undo step, and only if nothing was typed meanwhile.
    @objc func formatDocument(_ sender: Any?) {
        guard let index = activeTabIndex, openTabs[index].kind == .text else { return NSSound.beep() }
        let tab = openTabs[index]
        // With a selection: just those lines, if the server formats ranges or prettier can.
        if editor.selectedRange.length > 0, formatSelection(tab) { return }
        let original = tab.document.string
        let tabID = tab.id
        if let root = focusedRoot, !tab.isUntitled, let formatter = Self.stdinFormatterCommand(for: tab.url, projectRoot: root) {
            let directory = tab.url.deletingLastPathComponent()
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let formatted = Self.runFormatter(formatter, input: original, directory: directory)
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let formatted { self.applyFormatted(formatted, tabID: tabID, original: original) }
                    else { self.formatWithLanguageServer(tabID: tabID, original: original) }
                }
            }
            return
        }
        formatWithLanguageServer(tabID: tabID, original: original)
    }

    /// Formats the selected lines; false if nothing here can format just part of a file.
    private func formatSelection(_ tab: OpenTab) -> Bool {
        let selection = editor.selectedRange
        let rope = tab.document.rope
        // Whole lines, as formatters work.
        let firstLine = rope.line(containing: selection.location), lastLine = rope.line(containing: max(selection.location, NSMaxRange(selection) - 1))
        let start = rope.offset(ofLine: firstLine), end = rope.range(ofLine: lastLine).upperBound
        let original = tab.document.string
        let tabID = tab.id
        if let lspManager, lspManager.capabilities(forExtension: tab.url.languageExtension)?.formatsRanges == true {
            let unit = Self.indentUnit(in: tab.document.text, near: NSRange(location: start, length: 0))
            let range = LSPRange(start: LSPPosition(line: firstLine, character: 0), end: LSPPosition(line: lastLine, character: end - rope.offset(ofLine: lastLine)))
            lspManager.formatRange(url: tab.url, range: range, tabSize: unit == "\t" ? 4 : unit.count, insertSpaces: unit != "\t") { [weak self] edits in
                MainActor.assumeIsolated {
                    guard let self, let edits, let index = self.indexForTab(id: tabID), self.activeTabIndex == index,
                          self.openTabs[index].document.string == original,
                          let ranges = Self.nonOverlapping(edits, in: self.openTabs[index].document.rope) else { return }
                    self.editor.applyEdits(ranges)
                }
            }
            return true
        }
        // prettier formats a range of the file it's given (JavaScript string offsets: UTF-16).
        guard let root = focusedRoot, !tab.isUntitled, let formatter = Self.stdinFormatterCommand(for: tab.url, projectRoot: root),
              formatter.executable.hasSuffix("prettier") else { return false }
        let ranged = (formatter.executable, formatter.args + ["--range-start", "\(start)", "--range-end", "\(end)"])
        let directory = tab.url.deletingLastPathComponent()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let formatted = Self.runFormatter(ranged, input: original, directory: directory)
            DispatchQueue.main.async {
                guard let self, let formatted else { return NSSound.beep() }
                self.applyFormatted(formatted, tabID: tabID, original: original)
            }
        }
        return true
    }

    /// Formatted by the server on save: written again, so what's on disk is what's shown.
    private func saveAfterFormatting(tabID: UUID) {
        guard let index = indexForTab(id: tabID), openTabs[index].dirty else { return }
        let url = openTabs[index].url
        let content = openTabs[index].document.string
        guard let data = TextFileCodec.encode(content, as: openTabs[index].format), (try? data.write(to: url, options: .atomic)) != nil else { return }
        UserSaveLog.shared.record(url)
        openTabs[index].savedStamp = ContentStamp(content)
        openTabs[index].knownDiskStamp = diskStamp(of: url)
        openTabs[index].dirty = false
        if activeTabIndex == index { dirty = false }
        rebuildTabBar()
    }

    private func formatWithLanguageServer(tabID: UUID, original: String, then: (() -> Void)? = nil) {
        guard let index = indexForTab(id: tabID), let lspManager, lspManager.formats(forExtension: openTabs[index].url.languageExtension) else { return NSSound.beep() }
        let tab = openTabs[index]
        let unit = Self.indentUnit(in: tab.document.text, near: NSRange(location: 0, length: 0))
        lspManager.format(url: tab.url, tabSize: unit == "\t" ? 4 : unit.count, insertSpaces: unit != "\t") { [weak self] edits in
            guard let self, let edits, let index = self.indexForTab(id: tabID), self.activeTabIndex == index,
                  self.openTabs[index].document.string == original else { return }
            // Overlapping edits are a server's bug, and applying them trapped in the text buffer,
            // ending Side with the user's unsaved work (2026-09-30 audit, EDT-5).
            guard let ranges = Self.nonOverlapping(edits, in: self.openTabs[index].document.rope) else { return NSSound.beep() }
            let caret = self.editor.selectedRange.location
            self.editor.applyEdits(ranges)
            self.editor.selectedRange = NSRange(location: min(caret, self.openTabs[index].document.length), length: 0)
            then?()
        }
    }

    /// The formatter's output, or nil if it failed (a syntax error, a missing config).
    nonisolated static func runFormatter(_ formatter: (executable: String, args: [String]), input: String, directory: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: formatter.executable)
        process.arguments = formatter.args
        process.currentDirectoryURL = directory
        // The login shell's PATH: a formatter is often a `#!/usr/bin/env node` script, and an app
        // opened from the Dock has launchd's PATH, with no Homebrew or nvm node on it.
        process.environment = LanguageServerRegistry.environmentForSpawning()
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // Written on its own thread: a formatter that answers as it reads would otherwise fill
        // its output pipe while this still writes, and both would wait forever.
        let data = Data(input.utf8)
        DispatchQueue.global().async {
            // A formatter can exit without reading a large file; that must fail the format, not
            // end Side (2026-09-30 audit, H1).
            PipeWriting.write(data, to: stdin.fileHandleForWriting)
            try? stdin.fileHandleForWriting.close()
        }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !output.isEmpty else { return nil }
        return String(data: output, encoding: .utf8)
    }

    /// The formatted text as the one edit that differs (so the rest keeps its layout, folds
    /// and colors), undoable.
    private func applyFormatted(_ formatted: String, tabID: UUID, original: String) {
        guard let index = indexForTab(id: tabID), activeTabIndex == index, openTabs[index].document.string == original, formatted != original else { return }
        let old = original as NSString, new = formatted as NSString
        var prefix = 0
        let shortest = min(old.length, new.length)
        while prefix < shortest, old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < shortest - prefix, old.character(at: old.length - 1 - suffix) == new.character(at: new.length - 1 - suffix) { suffix += 1 }
        let range = NSRange(location: prefix, length: old.length - prefix - suffix)
        let replacement = new.substring(with: NSRange(location: prefix, length: new.length - prefix - suffix))
        let caret = editor.selectedRange.location
        editor.applyEdits([(range, replacement)])
        // The caret stays on its line where it can: before the change, it doesn't move.
        let moved = caret <= prefix ? caret : min(new.length, caret + new.length - old.length)
        editor.selectedRange = NSRange(location: max(0, moved), length: 0)
    }

    private static func formatterCommand(for url: URL, projectRoot: URL) -> (executable: String, args: [String])? {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "js", "jsx", "ts", "tsx", "json", "md", "css", "html", "yaml", "yml":
            // The project's own Prettier, or a config that's code, only for a trusted project
            // (2026-09-30 audit, SEC-11: saving a file ran the repository's code).
            let trusted = ProjectTrust.isTrusted(projectRoot)
            let local = projectRoot.appendingPathComponent("node_modules/.bin/prettier").path
            if trusted, FileManager.default.isExecutableFile(atPath: local) { return (local, ["--write", url.path]) }
            if !trusted, ProjectTrust.hasCodePrettierConfig(projectRoot) { return nil }
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
        process.environment = SpawnEnvironment.current()
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
    func restoreLastSessionIfAvailable() { guard let saved = HeronDefaults.store.string(forKey: lastProjectKey) else { return }; let url = URL(fileURLWithPath: saved); var isDirectory: ObjCBool = false; guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return }; loadProject(at: url) }

    /// Entry point for cross-stage "open this file" requests (currently: clicking a
    /// file-path-shaped link in the Run stage's terminal output).
    func revealFile(_ url: URL, line: Int?) {
        open(url) { [weak self] in
            guard let self, let line, line > 0,
                  let index = self.openTabs.firstIndex(where: { $0.url == url }), self.openTabs[index].kind == .text else { return }
            let ns = self.openTabs[index].document.text
            guard let range = self.nsRange(for: LSPRange(start: LSPPosition(line: line - 1, character: 0), end: LSPPosition(line: line - 1, character: 0)), in: ns) else { return }
            self.editor.selectedRange = NSRange(location: range.location, length: 0)
            self.editor.centerRange(range)
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
        completionPopup.hide()
        debugger.stop()
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
    /// A remote picture the person asked for arrived: the preview renders again with it.
    var onPictureLoaded: (() -> Void)?

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let url = link as? URL, url.scheme == MarkdownPreview.loadImageScheme,
           let address = URL(string: String(url.absoluteString.dropFirst(MarkdownPreview.loadImageScheme.count + 1))) {
            URLSession.shared.dataTask(with: address) { [weak self] data, _, _ in
                let image = data.flatMap(NSImage.init(data:))
                DispatchQueue.main.async {
                    guard let image else { NSSound.beep(); return }
                    MarkdownPreview.remoteImages[address] = image
                    self?.onPictureLoaded?()
                }
            }.resume()
            return true
        }
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

    func editor(_ engine: EditorEngine, clickedLineNumber line: Int, event: NSEvent) {
        debugger.lineNumberClicked(line, event: event)
    }
}

// MARK: - Debugging (SIDE_RFC_DEBUGGER.md)

extension MakeWorkspaceViewController: MakeDebuggerHost {
    var debugProjectRoot: URL? { focusedRoot }
    var debugHostView: NSView { view }

    var debugCurrentFile: URL? {
        guard let index = activeTabIndex, openTabs.indices.contains(index), openTabs[index].kind == .text, !openTabs[index].isUntitled else { return nil }
        return openTabs[index].url
    }

    func debugReveal(_ url: URL, line: Int) {
        // The adapter's paths are real ones (/private/tmp); the project's may not be (/tmp).
        let real = realPath(url.path)
        var target = url
        if let tab = openTabs.first(where: { realPath($0.url.path) == real }) {
            target = tab.url
        } else if let root = focusedRoot?.path, case let realRoot = realPath(root), real.hasPrefix(realRoot + "/") {
            target = URL(fileURLWithPath: root + real.dropFirst(realRoot.count))
        }
        let show = { [weak self] (center: Bool) in
            guard let self, self.debugCurrentFile?.standardizedFileURL == target.standardizedFileURL, let document = self.editor.document else { return }
            let rope = document.rope
            guard line < rope.lineCount else { return }
            let range = NSRange(location: rope.offset(ofLine: line), length: 0)
            self.editor.selectedRange = range
            // Arriving in a file centers the line; a step within one only scrolls if it must.
            center ? self.editor.centerRange(range) : self.editor.scrollRangeToVisible(range)
        }
        if debugCurrentFile?.standardizedFileURL == target.standardizedFileURL { return show(false) }
        open(target) { show(true) }
    }

    func debugSetInsets(inspector width: CGFloat, leading: Bool, bar height: CGFloat) {
        gutterLeading?.constant = leading ? width : 0
        minimapTrailing?.constant = leading ? 0 : -width
        guard height != debugTopInset else { return }
        // The text moves down by the bar, so nothing starts hidden under it.
        var origin = editorScroll.contentView.bounds.origin
        origin.y -= height - debugTopInset
        debugTopInset = height
        applyTopInsets()
        editorScroll.contentView.scroll(to: editorScroll.contentView.constrainBoundsRect(NSRect(origin: origin, size: editorScroll.contentView.bounds.size)).origin)
        editorScroll.reflectScrolledClipView(editorScroll.contentView)
    }

    func debugChoose(_ prompt: String, from choices: [PaletteChoice], completion: @escaping (Int) -> Void) {
        choose(prompt, from: choices, completion: completion)
    }

    @objc func startDebugging(_ sender: Any?) { debugger.start() }
    @objc func chooseWhatToDebug(_ sender: Any?) { debugger.chooseAndStart() }
    @objc func attachToProcess(_ sender: Any?) { debugger.attachToProcess() }
    @objc func pauseOrContinueDebugging(_ sender: Any?) { debugger.pauseOrContinue() }
    @objc func stopDebugging(_ sender: Any?) { debugger.stop() }
    @objc func debugStepOver(_ sender: Any?) { debugger.stepOver() }
    @objc func debugStepIn(_ sender: Any?) { debugger.stepIn() }
    @objc func debugStepOut(_ sender: Any?) { debugger.stepOut() }
    @objc func toggleBreakpoint(_ sender: Any?) { debugger.toggleBreakpointAtCaret() }
}

extension MakeWorkspaceViewController: StageChromeProviding {
    /// The preview while it's showing: it scrolls under the top row just as the editor does.
    var scrollViewUnderTopRow: NSScrollView? { loadViewIfNeeded(); return markdownPreviewScroll.isHidden ? editorScroll : markdownPreviewScroll }
    /// The file tabs (with the language-server indicator trailing) live in the window's top row.
    var topRowContent: NSView? { loadViewIfNeeded(); return tabBar }
    /// The editor theme's background, so the tabs sit on the file's own color.
    var topRowBackground: NSColor { Self.editorBackground }
    var topRowAppearance: NSAppearance? { EditorThemes.chromeAppearance() }

    func setBottomObstruction(_ height: CGFloat) {
        loadViewIfNeeded()
        bottomObstruction = height
        // The editor scrolls beneath whatever covers the bottom, far enough that the last line
        // (and the caret on it — scroll-to-visible honours content insets) clears it.
        let inset = height > 0 ? height + DS.Spacing.l : 0
        minimapBottom?.constant = -inset
        sheetView.setBottomInset(height)
        for scroll in [editorScroll, markdownPreviewScroll, imageScroll] {
            scroll.automaticallyAdjustsContentInsets = false
            scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: inset, right: 0)
        }
        applyTopInsets()
    }

    // MARK: - Writer mode

    /// Writer mode (View → Writer Mode; the shell hides its own chrome): the text alone, in a
    /// centered column, no gutter, minimap or explorer, with the aids Settings turns on.
    private var alloyView: AlloyEditorView? { (editor as? AlloyEditorEngine)?.view }

    func setWriterMode(_ on: Bool) {
        loadViewIfNeeded()
        guard on != isWriting else { return }
        isWriting = on
        if on { explorer.hide() }
        gutterWidth?.constant = on ? 0 : AlloyGutterView.width
        gutter.alphaValue = on ? 0 : 1
        applyMinimapVisibility()
        if wordCountPill.superview == nil {
            wordCountLabel.font = DS.Text.caption()
            wordCountLabel.textColor = .secondaryLabelColor
            wordCountLabel.alignment = .center
            wordCountLabel.translatesAutoresizingMaskIntoConstraints = false
            wordCountPill.boxType = .custom
            wordCountPill.fillColor = DS.Color.overlay
            wordCountPill.borderWidth = 0
            wordCountPill.cornerRadius = DS.Radius.capsule(height: 24)
            wordCountPill.contentViewMargins = .zero
            wordCountPill.translatesAutoresizingMaskIntoConstraints = false
            wordCountPill.addSubview(wordCountLabel)
            view.addSubview(wordCountPill)
            NSLayoutConstraint.activate([
                wordCountPill.heightAnchor.constraint(equalToConstant: 24),
                wordCountLabel.centerYAnchor.constraint(equalTo: wordCountPill.centerYAnchor),
                wordCountLabel.leadingAnchor.constraint(equalTo: wordCountPill.leadingAnchor, constant: DS.Spacing.m),
                wordCountLabel.trailingAnchor.constraint(equalTo: wordCountPill.trailingAnchor, constant: -DS.Spacing.m),
                wordCountPill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                wordCountPill.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -DS.Spacing.m),
            ])
        }
        alloyView?.highlightsCurrentLine = !on
        applyLiveMarkdown()
        if !on {
            alloyView?.readingColumnWidth = nil
            alloyView?.focusedLines = nil
            alloyView?.documentPadding = nil
            zoomNoteWork?.cancel()
            zoomNote = nil
            wordCountPill.isHidden = true
        }
        applyWriterAids()
        view.window?.makeFirstResponder(editor.textView)
    }

    /// The column, and each aid as Settings has it.
    private func applyWriterAids() {
        guard isWriting else { applyTopInsets(); return }
        // About 72 characters of whichever font the text is in (Live Markdown's reading font
        // is narrower than code's).
        let prose = (editor as? AlloyEditorEngine)?.isProse == true
        let font = prose ? DS.Text.Fonts.font(.reading, size: AlloyEditorEngine.proseSize) : DS.Text.editor()
        let digit = ("0" as NSString).size(withAttributes: [.font: font]).width
        alloyView?.readingColumnWidth = min(760, (digit * 72).rounded())
        if !WriterPreferences.isOn(.dimOthers) { alloyView?.focusedLines = nil }
        applyWriterInsets()
        followCaretWhileWriting()
        updateWordCount()
    }

    /// With typewriter scrolling the text can scroll until its first or last line is mid-screen;
    /// without it, a margin above and below. Both are padding in the document rather than scroll
    /// insets, so the scroller spans the window and its knob is the document's (insets this big
    /// drew a stub of a scroller in the middle band: "the scrollbar looks weird", the owner).
    private func applyWriterInsets() {
        guard isWriting else { return }
        let height = editorScroll.contentView.bounds.height
        let lineHeight = alloyView?.documentLayout.lineHeight ?? 20
        editorScroll.automaticallyAdjustsContentInsets = false
        editorScroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        alloyView?.documentPadding = WriterPreferences.isOn(.typewriter) ? max(DS.Spacing.xxl, (height * 0.45 - lineHeight / 2).rounded()) : DS.Spacing.xxl
    }

    /// The caret's line held at the same height (typewriter), and its paragraph alone at full
    /// strength (focus).
    private func followCaretWhileWriting() {
        guard isWriting, let view = alloyView, let document = editor.document else { return }
        let caret = min(NSMaxRange(editor.selectedRange), document.rope.utf16Count)
        if WriterPreferences.isOn(.typewriter) {
            applyWriterInsets()
            let height = editorScroll.contentView.bounds.height
            view.scrollY = view.rect(forCharacterRange: caret..<caret).minY - (height * 0.45 - view.documentLayout.lineHeight / 2).rounded()
        }
        if WriterPreferences.isOn(.dimOthers) {
            view.focusedLines = Self.paragraphLines(around: document.rope.position(of: caret).line, in: document.text)
        }
        if editor.selectedRange.length > 0 || wordCountLabel.stringValue.isEmpty { updateWordCount() }
    }

    /// The lines of the paragraph a line is in: up to the blank lines around it.
    static func paragraphLines(around line: Int, in text: NSString) -> ClosedRange<Int> {
        var lines: [NSRange] = []
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: [.byLines, .substringNotRequired]) { _, range, _, _ in lines.append(range) }
        guard lines.indices.contains(line) else { return line...line }
        func blank(_ index: Int) -> Bool { text.substring(with: lines[index]).trimmingCharacters(in: .whitespaces).isEmpty }
        if blank(line) { return line...line }
        var first = line, last = line
        while first > 0, !blank(first - 1) { first -= 1 }
        while last + 1 < lines.count, !blank(last + 1) { last += 1 }
        return first...last
    }

    private func scheduleWordCount() {
        wordCountWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.updateWordCount() }
        wordCountWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// "1,204 words · 5 min read", or the selection's count of the whole, and the zoom just after
    /// ⌘= ⌘− ⌘0. With the count off, the pill comes only for the zoom.
    private func updateWordCount() {
        guard isWriting else { return }
        var parts: [String] = []
        if WriterPreferences.isOn(.wordCount), let document = editor.document {
            let text = document.text
            let total = Self.wordCount(text, in: NSRange(location: 0, length: text.length))
            let selection = editor.selectedRange
            if selection.length > 0, NSMaxRange(selection) <= text.length {
                parts.append("\(Self.wordCount(text, in: selection).formatted()) of \(total.formatted()) words")
            } else {
                let minutes = max(1, Int((Double(total) / 230).rounded()))
                parts.append("\(total.formatted()) word\(total == 1 ? "" : "s") \u{00B7} \(minutes) min read")
            }
        }
        if let zoomNote { parts.append(zoomNote) }
        wordCountLabel.stringValue = parts.joined(separator: " \u{00B7} ")
        wordCountPill.isHidden = parts.isEmpty
    }

    /// Writer mode's answer to the zoom pill: the size as a share of the default, in the pill
    /// already at the bottom, for as long as the zoom pill would stay.
    func showZoomWhileWriting(_ size: CGFloat, for duration: TimeInterval = ZoomPill.lingering) {
        guard isWriting else { return }
        zoomNote = "Zoom \(Int((size / DS.Text.CodeSize.standard * 100).rounded()))%"
        updateWordCount()
        zoomNoteWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.zoomNote = nil
            self?.updateWordCount()
        }
        zoomNoteWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    static func wordCount(_ text: NSString, in range: NSRange) -> Int {
        var count = 0
        text.enumerateSubstrings(in: range, options: [.byWords, .substringNotRequired]) { _, _, _, _ in count += 1 }
        return count
    }

    /// Something Esc should close before it leaves Writer mode: completions, an Instruct popover.
    var hasTransientSurface: Bool { completionSession != nil || instructPopover?.isShown == true }

        var wordCountForTesting: String? { wordCountPill.isHidden ? nil : wordCountLabel.stringValue }

    // MARK: - Live Markdown

    static let liveMarkdownKey = "SideLiveMarkdownFiles"

    static func isMarkdown(_ url: URL) -> Bool { ["md", "markdown", "mdx"].contains(url.pathExtension.lowercased()) }

    /// Markdown set as prose (docs/SIDE_RFC_LIVE_MARKDOWN.md): the files switched to Live, and
    /// every Markdown file in Writer Mode.
    private func isLive(_ url: URL) -> Bool {
        guard Self.isMarkdown(url) else { return false }
        return isWriting || (Self.preferences.stringArray(forKey: Self.liveMarkdownKey) ?? []).contains(url.path)
    }

    /// View → Live Markdown: this file between source and Live, remembered.
    @objc func toggleLiveMarkdown(_ sender: Any?) {
        guard let index = activeTabIndex, Self.isMarkdown(openTabs[index].url) else { return }
        let path = openTabs[index].url.path
        var live = Self.preferences.stringArray(forKey: Self.liveMarkdownKey) ?? []
        if let found = live.firstIndex(of: path) { live.remove(at: found) } else { live.append(path) }
        Self.preferences.set(Array(live.suffix(500)), forKey: Self.liveMarkdownKey)
        applyLiveMarkdown()
    }

    /// Which kind of file is in front, for shortcuts that belong to one (⌘B: Bold in Markdown,
    /// Build in LaTeX; ⌘K: Link in Markdown, Instruct elsewhere).
    private func updateShortcutContext() {
        guard let index = activeTabIndex, openTabs.indices.contains(index), openTabs[index].kind == .text else { Shortcuts.activeContext = nil; return }
        let url = openTabs[index].url
        Shortcuts.activeContext = Self.isMarkdown(url) ? .markdown : LaTeXSession.isSource(url) ? .latex : nil
    }

    // MARK: - Markdown formatting

    /// A Markdown file being edited as text (source or Live; not the preview).
    private var activeMarkdownSource: Bool {
        guard let index = activeTabIndex, openTabs.indices.contains(index), openTabs[index].kind == .text,
              !openTabs[index].isPreviewingMarkdown, editor.isEditable else { return false }
        return Self.isMarkdown(openTabs[index].url)
    }

    @objc func formatBold(_ sender: Any?) { toggleMarkdownWrap("**") }
    @objc func formatItalic(_ sender: Any?) { toggleMarkdownWrap("*") }

    /// Wraps the selection in a mark, or unwraps it when it's already wrapped (the marks just
    /// outside it, or at its ends). Nothing selected: the word under the caret, or an empty pair
    /// with the caret between.
    func toggleMarkdownWrap(_ mark: String) {
        guard activeMarkdownSource, let document = editor.document else { return }
        let text = document.text
        var range = editor.selectedRange
        let markLength = (mark as NSString).length
        if range.length == 0 {
            let word = Self.wordRange(at: range.location, in: text)
            if word.length > 0 { range = word }
        }
        func marked(_ location: Int) -> Bool {
            guard location >= 0, location + markLength <= text.length, text.substring(with: NSRange(location: location, length: markLength)) == mark else { return false }
            // `*` isn't italic's when it's half of a bold's `**` (unless the text is both, `***`).
            if mark == "*" {
                // The whole run of stars it's in: an odd one (`*`, `***`) has an italic's mark.
                var start = location, end = location + 1
                while start > 0, text.character(at: start - 1) == 0x2A { start -= 1 }
                while end < text.length, text.character(at: end) == 0x2A { end += 1 }
                return (end - start) % 2 == 1
            }
            return true
        }
        if range.length >= markLength * 2, marked(range.location), marked(NSMaxRange(range) - markLength) {
            // The selection includes its marks: take them off.
            let inner = text.substring(with: NSRange(location: range.location + markLength, length: range.length - markLength * 2))
            editor.applyEdits([(range: range, text: inner)])
            editor.selectedRange = NSRange(location: range.location, length: (inner as NSString).length)
        } else if marked(range.location - markLength), marked(NSMaxRange(range)) {
            // The marks sit just outside it.
            let outer = NSRange(location: range.location - markLength, length: range.length + markLength * 2)
            editor.applyEdits([(range: outer, text: text.substring(with: range))])
            editor.selectedRange = NSRange(location: outer.location, length: range.length)
        } else {
            editor.applyEdits([(range: range, text: mark + text.substring(with: range) + mark)])
            editor.selectedRange = NSRange(location: range.location + markLength, length: range.length)
        }
    }

    /// ⌘K: the selection as a link's text with "url" selected to type over; a selected address
    /// as the link's target with the caret in its text; nothing selected, a link to fill in.
    @objc func formatLink(_ sender: Any?) {
        guard activeMarkdownSource, let document = editor.document else { return }
        let range = editor.selectedRange
        let selected = document.text.substring(with: range)
        if let url = URL(string: selected.trimmingCharacters(in: .whitespaces)), let scheme = url.scheme, ["http", "https", "mailto"].contains(scheme.lowercased()) {
            editor.applyEdits([(range: range, text: "[](\(selected))")])
            editor.selectedRange = NSRange(location: range.location + 1, length: 0)
        } else {
            let label = selected.isEmpty ? "text" : selected
            editor.applyEdits([(range: range, text: "[\(label)](url)")])
            let labelLength = (label as NSString).length
            editor.selectedRange = selected.isEmpty ? NSRange(location: range.location + 1, length: labelLength)
                                                    : NSRange(location: range.location + labelLength + 3, length: 3)
        }
    }

    /// The word around a location (letters, digits, apostrophes), or nothing.
    static func wordRange(at location: Int, in text: NSString) -> NSRange {
        func isWord(_ i: Int) -> Bool {
            guard i >= 0, i < text.length, let scalar = UnicodeScalar(text.character(at: i)) else { return false }
            return CharacterSet.alphanumerics.contains(scalar) || scalar == "'"
        }
        var start = location, end = location
        while isWord(start - 1) { start -= 1 }
        while isWord(end) { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    private func applyLiveMarkdown() {
        updateShortcutContext()
        guard let engine = editor as? AlloyEditorEngine else { return }
        guard let index = activeTabIndex, openTabs.indices.contains(index), openTabs[index].kind == .text else { engine.isProse = false; return }
        engine.isProse = isLive(openTabs[index].url)
    }

    // MARK: - LaTeX

    /// The LaTeX source on screen.
    private var activeLaTeXSource: URL? {
        guard let index = activeTabIndex, openTabs.indices.contains(index), openTabs[index].kind == .text, !openTabs[index].isUntitled,
              LaTeXSession.isSource(openTabs[index].url) else { return nil }
        return openTabs[index].url
    }

    /// ⌘B: build the document this source belongs to; the PDF opens beside the editor.
    @objc func buildLaTeX(_ sender: Any?) {
        guard let url = activeLaTeXSource, let index = activeTabIndex else { NSSound.beep(); return }
        latex.build(source: url, text: openTabs[index].document.string)
    }

    /// ⌥⌘B: where the caret's line is in the PDF.
    @objc func showInPDF(_ sender: Any?) {
        guard let url = activeLaTeXSource, let index = activeTabIndex else { NSSound.beep(); return }
        let document = openTabs[index].document
        let caret = min(editor.selectedRange.location, document.rope.utf16Count)
        let position = document.rope.position(of: caret)
        latex.showInPDF(source: url, text: document.string, line: position.line + 1, column: position.column)
    }

    private func makeLaTeXSession() -> LaTeXSession {
        let session = LaTeXSession()
        // Every unsaved LaTeX file (and its bibliography and packages) is saved first: the
        // build reads them from disk.
        session.saveSources = { [weak self] proceed in
            guard let self else { return }
            let kinds: Set<String> = ["tex", "ltx", "bib", "sty", "cls"]
            let pending = self.openTabs.filter { $0.dirty && !$0.isUntitled && kinds.contains($0.url.pathExtension.lowercased()) }.map(\.id)
            // One after another, then the build.
            var step: () -> Void = proceed
            for id in pending.reversed() {
                let after = step
                step = { [weak self] in self?.performSave(tabID: id) { _ in after() } }
            }
            step()
        }
        session.reportProblems = { [weak self] byFile in
            guard let self else { return }
            for (url, diagnostics) in byFile {
                self.buildDiagnostics[url] = diagnostics.isEmpty ? nil : diagnostics
                let all = (self.serverDiagnostics[url] ?? []) + diagnostics
                self.applyDiagnostics(all, to: url)
                self.recordProblems(all, for: url)
            }
        }
        session.revealSource = { [weak self] url, line in self?.revealFile(url, line: line) }
        session.projectRoot = { [weak self] in self?.focusedRoot }
        session.window = { [weak self] in self?.view.window }
        return session
    }

    var latexForTesting: LaTeXSession { latex }
    func problemsForTesting(_ url: URL) -> [LSPDiagnostic] { allDiagnostics[url] ?? [] }

    // MARK: - A tab's preview

    /// What a tab shows, for the small window a tab turns into when dragged out of its window.
    /// The tab on screen: the stage as it is, between the top row and the bottom bar, with its
    /// editor drawn again (Metal can't be read back from a view). Another tab: its image, its
    /// sheet, or its text's first lines, at the stage's size.
    func tabPreviewContent(_ index: Int) -> NSImage? {
        guard openTabs.indices.contains(index), view.bounds.width > 0, view.bounds.height > topObstruction + bottomObstruction + 40 else { return nil }
        let tab = openTabs[index]
        let height = view.bounds.height - topObstruction - bottomObstruction
        let stage = NSRect(x: 0, y: view.isFlipped ? topObstruction : bottomObstruction, width: view.bounds.width, height: height)
        if index == activeTabIndex {
            guard let rep = view.bitmapImageRepForCachingDisplay(in: stage) else { return nil }
            view.cacheDisplay(in: stage, to: rep)
            let base = NSImage(size: stage.size)
            base.addRepresentation(rep)
            guard tab.kind == .text, !tab.isPreviewingMarkdown, let alloy = editor as? AlloyEditorEngine, let text = alloy.view.snapshot() else { return base }
            let clip = alloy.view.scrollView.contentView
            let frame = clip.convert(clip.bounds, to: view)
            let flipped = view.isFlipped
            return Self.rendered(stage.size, appearance: view.effectiveAppearance) {
                base.draw(in: NSRect(origin: .zero, size: stage.size))
                let y = flipped ? stage.maxY - frame.maxY : frame.minY - stage.minY
                text.draw(in: NSRect(x: frame.minX - stage.minX, y: y, width: frame.width, height: frame.height))
            }
        }
        switch tab.kind {
        case .image:
            return tab.cachedImage
        case .csv:
            let sheet = SheetView(frame: NSRect(origin: .zero, size: stage.size))
            sheet.appearance = view.effectiveAppearance
            sheet.scrollView.backgroundColor = Self.editorBackground
            sheet.show(tab.sheets)
            sheet.layoutSubtreeIfNeeded()
            guard let rep = sheet.bitmapImageRepForCachingDisplay(in: sheet.bounds) else { return nil }
            view.effectiveAppearance.performAsCurrentDrawingAppearance { sheet.cacheDisplay(in: sheet.bounds, to: rep) }
            let image = NSImage(size: stage.size)
            image.addRepresentation(rep)
            return image
        case .text:
            var lines: [Substring] = []
            tab.document.string.enumerateLines { line, stop in
                lines.append(Substring(line.prefix(200)))
                if lines.count >= 80 { stop = true }
            }
            let text = lines.joined(separator: "\n")
            let attributes: [NSAttributedString.Key: Any] = [.font: DS.Text.editor(), .foregroundColor: NSColor.labelColor]
            return Self.rendered(stage.size, appearance: view.effectiveAppearance) {
                Self.editorBackground.setFill()
                NSRect(origin: .zero, size: stage.size).fill()
                (text as NSString).draw(with: NSRect(x: 64, y: 16, width: stage.width - 80, height: stage.height - 32),
                                        options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
            }
        }
    }

    /// An image drawn now, at 2x, in the given appearance (the drawing it holds is done once).
    static func rendered(_ size: NSSize, appearance: NSAppearance, _ draw: () -> Void) -> NSImage {
        let image = NSImage(size: size)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return image }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        appearance.performAsCurrentDrawingAppearance(draw)
        NSGraphicsContext.restoreGraphicsState()
        image.addRepresentation(rep)
        return image
    }

    func setTopObstruction(_ height: CGFloat) {
        loadViewIfNeeded()
        topObstruction = height
        trustBannerTop?.constant = height
        applyTopInsets()
    }

    /// Content starts below the top row and whichever banners are showing (trust, a change on
    /// disk), so neither covers the file's first lines; the debugger's bar adds to the editor's.
    func applyTopInsets() {
        let banners = (trustBanner.isHidden ? 0 : trustBannerHeight?.constant ?? 0) + (externalChangeBanner.isHidden ? 0 : 28)
        for scroll in [editorScroll, markdownPreviewScroll, imageScroll, csvScroll] {
            scroll.automaticallyAdjustsContentInsets = false
            scroll.contentInsets.top = topObstruction + banners + (scroll === editorScroll ? debugTopInset : 0)
        }
        if isWriting { applyWriterInsets() }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // The window resized: typewriter scrolling keeps its line mid-screen.
        if isWriting { applyWriterInsets() }
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
        iconTint = nil
        icon.image = image
        icon.contentTintColor = .secondaryLabelColor
        title.stringValue = text
        detail.stringValue = detailText ?? ""
        trailing.stringValue = trailingText ?? ""
        setAccessibilityLabel([text, detailText, trailingText].compactMap { $0 }.joined(separator: ", "))
    }

    /// The icon in a color that says something (a problem's severity); nil for the usual.
    private var iconTint: NSColor?
    func tintIcon(_ color: NSColor?) {
        iconTint = color
        applyColors()
    }

    override var backgroundStyle: NSView.BackgroundStyle { didSet { applyColors() } }

    /// On the accent selection everything turns white, the way a system list does.
    private func applyColors() {
        let selected = backgroundStyle == .emphasized
        title.textColor = selected ? .white : .labelColor
        detail.textColor = selected ? NSColor.white.withAlphaComponent(0.75) : .tertiaryLabelColor
        trailing.textColor = selected ? NSColor.white.withAlphaComponent(0.75) : .tertiaryLabelColor
        icon.contentTintColor = selected ? .white : (iconTint ?? .secondaryLabelColor)
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


extension MakeWorkspaceViewController: NSMenuItemValidation {
    /// Show Minimap carries a checkmark; everything else is as the responder chain decides.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleMinimap(_:)):
            item.state = EditorPreferences.minimapShown ? .on : .off
        case #selector(startDebugging(_:)):
            return focusedRoot != nil && !(debugger.isActive && !debugger.isStopped)
        case #selector(chooseWhatToDebug(_:)), #selector(attachToProcess(_:)):
            return focusedRoot != nil && !debugger.isActive
        case #selector(pauseOrContinueDebugging(_:)), #selector(stopDebugging(_:)):
            return debugger.isActive
        case #selector(debugStepOver(_:)), #selector(debugStepIn(_:)), #selector(debugStepOut(_:)):
            return debugger.isStopped
        case #selector(toggleBreakpoint(_:)):
            return debugCurrentFile != nil
        case #selector(buildLaTeX(_:)), #selector(showInPDF(_:)):
            return activeLaTeXSource != nil
        case #selector(formatBold(_:)), #selector(formatItalic(_:)), #selector(formatLink(_:)):
            return activeMarkdownSource
        case #selector(toggleLiveMarkdown(_:)):
            let url = activeTabIndex.map { openTabs[$0].url }
            item.state = url.map(isLive) == true ? .on : .off
            return url.map(Self.isMarkdown) == true && !isWriting
        default:
            break
        }
        return true
    }
}

/// Make's editor preferences, from Settings → General and the View menu.
enum EditorPreferences {
    static let didChangeNotification = Notification.Name("SideEditorPreferencesDidChange")

    static var minimapShown: Bool {
        get { MakeWorkspaceViewController.preferences.bool(forKey: MakeWorkspaceViewController.minimapKey) }
        set {
            MakeWorkspaceViewController.preferences.set(newValue, forKey: MakeWorkspaceViewController.minimapKey)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    /// On unless turned off.
    static var foldingEnabled: Bool {
        get { !MakeWorkspaceViewController.preferences.bool(forKey: "SideCodeFoldingOff") }
        set {
            MakeWorkspaceViewController.preferences.set(!newValue, forKey: "SideCodeFoldingOff")
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }
}

/// Writer mode's aids (Settings → General → Writer Mode), each a toggle: the word count, the
/// typing line held in place, and the other paragraphs dimmed are on until turned off; full
/// screen on entering is off until turned on (2026-10-23, the owner).
enum WriterPreferences {
    enum Aid: String, CaseIterable {
        case wordCount, typewriter, dimOthers, fullScreen

        var title: String {
            switch self {
            case .wordCount: return "Word count"
            case .typewriter: return "Typewriter scrolling"
            case .dimOthers: return "Dim other paragraphs"
            case .fullScreen: return "Full screen on enter"
            }
        }

        var detail: String {
            switch self {
            case .wordCount: return "Words and reading time at the bottom, for the document or the selection."
            case .typewriter: return "The line you're typing stays at the same height on screen."
            case .dimOthers: return "Everything but the paragraph you're in fades back."
            case .fullScreen: return "Entering Writer Mode also takes the window full screen."
            }
        }

        fileprivate var key: String { "SideWriter.\(rawValue)" }
        fileprivate var standard: Bool { self != .fullScreen }
    }

    static func isOn(_ aid: Aid) -> Bool {
        MakeWorkspaceViewController.preferences.object(forKey: aid.key) as? Bool ?? aid.standard
    }

    static func set(_ aid: Aid, _ on: Bool) {
        MakeWorkspaceViewController.preferences.set(on, forKey: aid.key)
        NotificationCenter.default.post(name: EditorPreferences.didChangeNotification, object: nil)
    }
}

/// A code action and its file, carried by a menu item.
final class CodeActionBox: NSObject {
    let action: LSPCodeAction
    let url: URL
    let asked: [URL: Rope]
    init(action: LSPCodeAction, url: URL, asked: [URL: Rope]) {
        self.action = action
        self.url = url
        self.asked = asked
    }
}

private extension NSFont {
    func withTraits(_ traits: NSFontTraitMask) -> NSFont { NSFontManager.shared.convert(self, toHaveTrait: traits) }
}

// MARK: - Recovering unsaved work (as Neovim's swap files do)

/// A tab's unsaved text, kept outside the project while it's unsaved, so a crash or a forced
/// quit doesn't lose it (2026-09-30 audit, H14: there was no recovery at all, and a crash lost
/// every unsaved buffer). Written two seconds after the last change, removed once the tab is
/// saved or closed; offered back when the project next opens, if it differs from the file.
private struct RecoveryCopy: Codable {
    var path: String
    var isUntitled: Bool
    var savedAt: Date
    var text: String
}

extension MakeWorkspaceViewController {
    fileprivate static let recoveryQueue = DispatchQueue(label: "side.make.recovery", qos: .utility)

    /// `~/Library/Application Support/Side/Recovery/<project>/`, one file per unsaved tab.
    static func recoveryDirectory(for project: URL) -> URL {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in project.standardizedFileURL.path.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Side/Recovery/\(String(hash, radix: 16))", isDirectory: true)
    }

    static func recoveryFileName(for path: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in path.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return String(hash, radix: 16) + ".json"
    }

    fileprivate func scheduleRecoverySync() {
        guard projectURL != nil, !AppDelegate.isUITesting else { return }
        recoverySync?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.syncRecovery() }
        recoverySync = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    /// One copy for every text tab with unsaved changes, and none for anything else.
    func syncRecovery() {
        guard let projectURL else { return }
        let copies = openTabs.filter { $0.dirty && $0.kind == .text }.map {
            RecoveryCopy(path: $0.isUntitled ? $0.url.absoluteString : $0.url.path, isUntitled: $0.isUntitled, savedAt: Date(), text: $0.document.string)
        }
        let directory = Self.recoveryDirectory(for: projectURL)
        let wanted = Dictionary(copies.map { (Self.recoveryFileName(for: $0.path), $0) }, uniquingKeysWith: { $1 })
        let stale = recoveryNames.subtracting(wanted.keys)
        recoveryNames = Set(wanted.keys)
        Self.recoveryQueue.async {
            for name in stale { try? FileManager.default.removeItem(at: directory.appendingPathComponent(name)) }
            guard !wanted.isEmpty else { return }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            for (name, copy) in wanted {
                guard let data = try? encoder.encode(copy) else { continue }
                try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
            }
        }
    }

    /// Copies whose text isn't what's on disk (a copy written just before a save, then left by a
    /// crash, matches and is dropped).
    static func recoverableCopies(for project: URL) -> [(url: URL, isUntitled: Bool, text: String)] {
        let directory = recoveryDirectory(for: project)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { name -> (URL, Bool, String)? in
            let file = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: file), let copy = try? decoder.decode(RecoveryCopy.self, from: data) else {
                try? FileManager.default.removeItem(at: file)
                return nil
            }
            if copy.isUntitled {
                guard !copy.text.isEmpty, let url = URL(string: copy.path) else { return nil }
                return (url, true, copy.text)
            }
            let url = URL(fileURLWithPath: copy.path)
            let onDisk = (try? Data(contentsOf: url)).flatMap { TextFileCodec.decode($0)?.text }
            guard onDisk != copy.text else {
                try? FileManager.default.removeItem(at: file)
                return nil
            }
            return (url, false, copy.text)
        }
    }

    func openForTesting(_ url: URL, completion: @escaping () -> Void) { open(url, completion: completion) }
    /// An unsaved edit to the active tab, as typing would leave it.
    func editActiveTabForTesting(_ text: String) {
        guard let index = activeTabIndex else { return }
        openTabs[index].document.replaceAll(with: text)
        openTabs[index].dirty = true
        dirty = true
        rebuildTabBar()
    }
    var activeTabForTesting: (text: String, dirty: Bool)? { activeTabIndex.map { (openTabs[$0].document.string, openTabs[$0].dirty) } }
    static func flushRecoveryForTesting() { recoveryQueue.sync {} }
    /// Save As to `url`, past the save panel.
    func saveActiveTabAsForTesting(_ url: URL, completion: @escaping (Bool) -> Void) {
        guard let index = activeTabIndex else { return completion(false) }
        let before = openTabs[index]
        writeTabToDiskForced(tabID: before.id, url: url, asNewFile: true) { [weak self] success in
            if success { self?.followSaveAs(from: before.url, wasUntitled: before.isUntitled, to: url) }
            completion(success)
        }
    }
    func newUntitledForTesting() { newFile() }
    /// Whether the language server has `url` open, and at which version (nil: not open).
    func languageServerVersionForTesting(_ url: URL) -> Int? { lspManager?.versionForTesting(url) }
    var activeTabURLForTesting: URL? { activeTabIndex.map { openTabs[$0].url } }
    var openTabURLsForTesting: [URL] { openTabs.map(\.url) }
    func closeTabForTesting(named name: String) {
        if let index = openTabs.firstIndex(where: { $0.url.lastPathComponent == name }) { closeTab(at: index) }
    }
    var sheetViewForTesting: SheetView { sheetView }
    /// As a batch of file events naming every open tab would.
    func reconcileWithDiskForTesting() { for index in openTabs.indices { reconcileTabWithDisk(index) } }
    var activeTabHasExternalChangeForTesting: Bool { activeTabIndex.map { openTabs[$0].hasExternalChange } ?? false }
    func restoreRecoveredForTesting() {
        guard let projectURL else { return }
        for copy in Self.recoverableCopies(for: projectURL) { restore(copy) }
    }

    fileprivate func offerRecovery(for project: URL) {
        guard projectURL == project, !AppDelegate.isUITesting else { return }
        let copies = Self.recoverableCopies(for: project)
        guard !copies.isEmpty, let window = view.window else { return }
        let names = copies.map { $0.isUntitled ? $0.url.lastPathComponent : $0.url.lastPathComponent }
        let alert = NSAlert()
        alert.messageText = copies.count == 1 ? "Restore unsaved changes to \(names[0])?" : "Restore unsaved changes to \(copies.count) files?"
        alert.informativeText = "Side ended before \(copies.count == 1 ? "this file was" : "these were") saved: \(names.prefix(6).joined(separator: ", "))\(names.count > 6 ? " and \(names.count - 6) more" : ""). Restoring opens \(copies.count == 1 ? "it" : "them") with those changes, unsaved, for you to look over. The files on disk aren't touched either way."
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Discard")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .alertFirstButtonReturn else {
                // Only what was offered: another window's copies are its own.
                for copy in copies {
                    let path = copy.isUntitled ? copy.url.absoluteString : copy.url.path
                    try? FileManager.default.removeItem(at: Self.recoveryDirectory(for: project).appendingPathComponent(Self.recoveryFileName(for: path)))
                }
                return
            }
            for copy in copies { self.restore(copy) }
        }
    }

    private func restore(_ copy: (url: URL, isUntitled: Bool, text: String)) {
        func apply(_ index: Int) {
            openTabs[index].document.replaceAll(with: copy.text)
            openTabs[index].dirty = true
            if activeTabIndex == index {
                dirty = true
                loadActiveTabIntoEditor()
            }
            rebuildTabBar()
        }
        if copy.isUntitled {
            newFile()
            if let index = activeTabIndex { apply(index) }
        } else {
            open(copy.url) { [weak self] in
                guard let self, let index = self.openTabs.firstIndex(where: { $0.url == copy.url }) else { return }
                apply(index)
            }
        }
    }
}

/// An image tab's view, able to hold keyboard focus so ⌘W and the other menu commands reach Make.
final class FocusableImageView: NSImageView {
    override var acceptsFirstResponder: Bool { true }
}
