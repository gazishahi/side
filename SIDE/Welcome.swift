import AppKit
import SQLite3
import SideAgents

/// When the welcome shows (SIDE_DESIGN_WELCOME.md): once, on a new install. Anyone who already
/// has a project in Side has found their way; they're marked as having seen it, and Help ›
/// Welcome to Side shows it to anyone again.
enum FirstRun {
    static let seenKey = "side.welcome-seen"

    static func shouldPresent(seen: Bool, hasRecentProjects: Bool) -> Bool {
        !seen && !hasRecentProjects
    }

    /// `-SideForceFirstRun YES`: show the welcome regardless, and never record it as seen — for
    /// checking it without touching a real first-run state.
    static var forced: Bool { UserDefaults.standard.bool(forKey: "SideForceFirstRun") }

    static var seen: Bool {
        get { HeronDefaults.store.bool(forKey: seenKey) }
        set { HeronDefaults.store.set(newValue, forKey: seenKey) }
    }

    static var hasRecentProjects: Bool {
        let recents = (HeronDefaults.store.array(forKey: "side.recent-projects") as? [String]) ?? []
        return !recents.isEmpty || HeronDefaults.store.string(forKey: "side.last-project-path") != nil
    }
}

/// Folders opened lately in the editors people come to Side from, read from their own records
/// (read only, never written): VS Code's and Cursor's `state.vscdb`, Zed's `db.sqlite`. Local
/// folders that still exist; remote ones and files are left out.
enum OtherEditorRecents {
    struct Folder: Equatable {
        let url: URL
        let source: String
    }

    nonisolated static func load(limit: Int = 5, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Folder] {
        let support = home.appendingPathComponent("Library/Application Support")
        let lists: [[Folder]] = [
            vscodeFamily(support.appendingPathComponent("Code/User/globalStorage/state.vscdb"), source: "VS Code"),
            zed(support.appendingPathComponent("Zed/db/0-stable/db.sqlite")),
            vscodeFamily(support.appendingPathComponent("Cursor/User/globalStorage/state.vscdb"), source: "Cursor"),
        ]
        // The most recent of each first, taking turns: one editor's long list doesn't crowd out
        // another's.
        var merged: [Folder] = []
        var seen = Set<String>()
        for index in 0..<(lists.map(\.count).max() ?? 0) {
            for list in lists where index < list.count {
                let folder = list[index]
                guard seen.insert(folder.url.standardizedFileURL.path).inserted else { continue }
                merged.append(folder)
            }
        }
        return Array(merged.prefix(limit))
    }

    nonisolated static func vscodeFamily(_ database: URL, source: String) -> [Folder] {
        guard let json = query(database, "SELECT value FROM ItemTable WHERE key = 'history.recentlyOpenedPathsList'").first,
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = object["entries"] as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            guard let uri = entry["folderUri"] as? String, uri.hasPrefix("file://"), let url = URL(string: uri) else { return nil }
            return existingFolder(url, source: source)
        }
    }

    nonisolated static func zed(_ database: URL) -> [Folder] {
        query(database, "SELECT paths FROM workspaces WHERE remote_connection_id IS NULL AND paths != '' ORDER BY timestamp DESC").compactMap { paths in
            // A workspace of several folders lists them a line each; its first stands for it.
            guard let first = paths.split(separator: "\n").first else { return nil }
            return existingFolder(URL(fileURLWithPath: String(first)), source: "Zed")
        }
    }

    private nonisolated static func existingFolder(_ url: URL, source: String) -> Folder? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return Folder(url: url, source: source)
    }

    /// The first column of each row. Opened immutable: nothing is locked or written, and an
    /// editor that has it open isn't disturbed.
    private nonisolated static func query(_ database: URL, _ sql: String) -> [String] {
        guard FileManager.default.fileExists(atPath: database.path) else { return [] }
        var connection: OpaquePointer?
        let uri = "file:\(database.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? database.path)?immutable=1"
        guard sqlite3_open_v2(uri, &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(connection)
            return []
        }
        defer { sqlite3_close(connection) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var rows: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) { rows.append(String(cString: text)) }
        }
        return rows
    }
}

// MARK: - The window

/// The welcome (SIDE_DESIGN_WELCOME.md): six pages in a window of its own. What Side is, its
/// five stages and three ideas shown at work, making it yours, the agents it found, and a
/// project to open. Every choice applies as it's made; closing at any point is fine.
@MainActor
final class WelcomeWindowController: NSWindowController, NSWindowDelegate {
    private static var shown: WelcomeWindowController?

    /// At launch: on a new install. A returning person is marked as having seen it.
    static func presentIfNeeded() {
        if FirstRun.forced { present(); return }
        guard !AppDelegate.isUITesting, NSClassFromString("XCTestCase") == nil else { return }
        guard FirstRun.shouldPresent(seen: FirstRun.seen, hasRecentProjects: FirstRun.hasRecentProjects) else {
            if !FirstRun.seen { FirstRun.seen = true }
            return
        }
        present()
    }

    /// Help › Welcome to Side, and the debug build's reset.
    static func present(from page: Int = 0) {
        if let shown {
            shown.window?.makeKeyAndOrderFront(nil)
            shown.content.go(to: page)
            return
        }
        let controller = WelcomeWindowController()
        shown = controller
        controller.content.go(to: page, animated: false)
        controller.window?.center()
        controller.window?.initialFirstResponder = controller.content.view
        controller.showWindow(nil)
        controller.window?.makeFirstResponder(controller.content.view)
        controller.content.didAppear()
    }

    static var isShownForTesting: Bool { shown != nil }
    static var pageForTesting: Int { shown?.content.page ?? -1 }
    static func goForTesting(_ page: Int) { shown?.content.go(to: page) }
    static func closeForTesting() { shown?.close() }

    let content = WelcomeViewController()

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Welcome to Side"
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.contentViewController = content
        window.setContentSize(NSSize(width: 900, height: 620))
        // One size: a page's content never stretches the window.
        window.contentMinSize = NSSize(width: 900, height: 620)
        window.contentMaxSize = NSSize(width: 900, height: 620)
        super.init(window: window)
        window.delegate = self
        content.onFinish = { [weak self] in self?.finish() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Seen, however it ends: finished, or closed part way.
    func windowWillClose(_ notification: Notification) {
        if !FirstRun.forced { FirstRun.seen = true }
        content.stopDemos()
        Self.shown = nil
    }

    /// The last page's button, or a project opened: the window fades out of the way.
    private func finish() {
        guard let window else { return }
        DS.Motion.fade(duration: DS.Motion.dismissDuration * 1.5, {
            window.animator().alphaValue = 0
        }, completion: { [weak self] in
            self?.close()
            window.alphaValue = 1
        })
    }
}

/// The welcome's pages and the bar under them: Back, the page dots, and the one primary button.
@MainActor
final class WelcomeViewController: NSViewController {
    var onFinish: (() -> Void)?
    private(set) var page = 0
    static let pageCount = 6

    private let pageHost = NSView()
    private var current: WelcomePage?
    private let backButton = NSButton(title: "Back", target: nil, action: nil)
    private let continueButton = NSButton(title: "Continue", target: nil, action: nil)
    private let dots = WelcomeDots(count: WelcomeViewController.pageCount)

    override func loadView() {
        let root = WelcomeRoot()
        root.onKey = { [weak self] code in self?.handleKey(code) ?? false }
        root.bindLayerBackground(DS.Color.canvas)
        view = root

        pageHost.translatesAutoresizingMaskIntoConstraints = false
        pageHost.wantsLayer = true
        root.addSubview(pageHost)

        backButton.isBordered = false
        backButton.target = self
        backButton.action = #selector(back)
        backButton.attributedTitle = NSAttributedString(string: "Back", attributes: [.font: DS.Text.body(.medium), .foregroundColor: NSColor.secondaryLabelColor])
        continueButton.bezelStyle = .push
        continueButton.controlSize = .large
        continueButton.bezelColor = DS.Color.accent
        continueButton.keyEquivalent = "\r"
        continueButton.target = self
        continueButton.action = #selector(advance)
        continueButton.font = DS.Text.body(.semibold)
        dots.onSelect = { [weak self] index in self?.go(to: index) }
        for control in [backButton, continueButton, dots] as [NSView] {
            control.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(control)
        }
        NSLayoutConstraint.activate([
            pageHost.topAnchor.constraint(equalTo: root.topAnchor),
            pageHost.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            pageHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            pageHost.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -76),
            dots.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            dots.centerYAnchor.constraint(equalTo: root.bottomAnchor, constant: -40),
            backButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 32),
            backButton.centerYAnchor.constraint(equalTo: dots.centerYAnchor),
            continueButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -32),
            continueButton.centerYAnchor.constraint(equalTo: dots.centerYAnchor),
            continueButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(appearanceChanged), name: DS.Appearance.didChangeNotification, object: nil)
    }

    func didAppear() { current?.didAppear() }

    @objc private func appearanceChanged() {
        continueButton.bezelColor = DS.Color.accent
    }

    // MARK: Paging

    @objc private func advance() {
        if page == Self.pageCount - 1 { onFinish?() } else { go(to: page + 1) }
    }

    @objc private func back() { go(to: page - 1) }

    /// ← and → page, Escape closes. From the root view, which is first responder: nothing else
    /// in the welcome takes key focus without Full Keyboard Access.
    private func handleKey(_ code: UInt16) -> Bool {
        switch code {
        case 123 where page > 0: go(to: page - 1)
        case 124 where page < Self.pageCount - 1: go(to: page + 1)
        case 53: view.window?.performClose(nil)
        default: return false
        }
        return true
    }

    func stopDemos() { current?.willDisappear() }

    /// To a page: the old one slides away and fades, the new one comes in from the side it's
    /// on, and its parts arrive one after another.
    func go(to index: Int, animated: Bool = true) {
        let target = max(0, min(Self.pageCount - 1, index))
        guard target != page || current == nil else { return }
        let forward = target >= page
        let old = current
        page = target
        let next = makePage(target)
        next.frame = pageHost.bounds
        next.autoresizingMask = [.width, .height]
        pageHost.addSubview(next)
        current = next
        refreshBar()

        old?.willDisappear()
        if let old {
            if animated, !DS.Motion.reduceMotion {
                slide(old.layer, from: 0, to: forward ? -60 : 60, fadingOut: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + DS.Motion.smooth.duration) { old.removeFromSuperview() }
            } else {
                old.removeFromSuperview()
            }
        }
        if animated {
            next.layoutSubtreeIfNeeded()
            if !DS.Motion.reduceMotion { slide(next.layer, from: forward ? 60 : -60, to: 0, fadingOut: false) }
            next.arrive()
            if view.window != nil { next.didAppear() }
        }
    }

    private func slide(_ layer: CALayer?, from: CGFloat, to: CGFloat, fadingOut: Bool) {
        guard let layer else { return }
        let move = DS.Motion.spring(DS.Motion.smooth, keyPath: "transform.translation.x")
        move.fromValue = from
        move.toValue = to
        move.fillMode = .forwards
        move.isRemovedOnCompletion = !fadingOut
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = fadingOut ? 1 : 0
        fade.toValue = fadingOut ? 0 : 1
        fade.duration = fadingOut ? DS.Motion.dismissDuration : DS.Motion.presentDuration
        fade.timingFunction = DS.Motion.fadeCurve
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = !fadingOut
        layer.add(move, forKey: "slide")
        layer.add(fade, forKey: "slideFade")
    }

    private func refreshBar() {
        dots.select(page)
        DS.Motion.fade { backButton.animator().alphaValue = page == 0 ? 0 : 1 }
        backButton.isEnabled = page > 0
        let titles = ["Get Started", "Continue", "Continue", "Continue", "Continue", "Start Using Side"]
        continueButton.title = titles[page]
        continueButton.font = DS.Text.body(.semibold)
    }

    private func makePage(_ index: Int) -> WelcomePage {
        switch index {
        case 0: return WelcomeHelloPage()
        case 1: return WelcomeStagesPage()
        case 2: return WelcomeIdeasPage()
        case 3: return WelcomeYoursPage()
        case 4: return WelcomeAgentsPage()
        default:
            let open = WelcomeOpenPage()
            open.onOpened = { [weak self] in self?.onFinish?() }
            return open
        }
    }
}

/// The welcome's root: it takes key focus so the arrows and Escape reach the pages.
private final class WelcomeRoot: NSView {
    var onKey: ((UInt16) -> Bool)?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if onKey?(event.keyCode) != true { super.keyDown(with: event) }
    }
}

/// The page dots: the current page a longer capsule, the way iOS's and macOS's setup show it.
/// A click on one goes to its page.
@MainActor
final class WelcomeDots: NSView {
    var onSelect: ((Int) -> Void)?
    private let count: Int
    private var marks: [CALayer] = []
    private var selected = 0
    private static let dot: CGFloat = 7, long: CGFloat = 20, gap: CGFloat = 7

    init(count: Int) {
        self.count = count
        super.init(frame: .zero)
        wantsLayer = true
        for _ in 0..<count {
            let mark = CALayer()
            mark.cornerRadius = Self.dot / 2
            layer?.addSublayer(mark)
            marks.append(mark)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.pageRole)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: CGFloat(count - 1) * (Self.dot + Self.gap) + Self.long, height: Self.dot)
    }

    func select(_ index: Int) {
        selected = index
        setAccessibilityValue("Page \(index + 1) of \(count)")
        place(animated: true)
    }

    override func layout() {
        super.layout()
        place(animated: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        place(animated: false)
    }

    private func place(animated: Bool) {
        var x: CGFloat = 0
        effectiveAppearance.performAsCurrentDrawingAppearance {
            for (index, mark) in marks.enumerated() {
                let width = index == selected ? Self.long : Self.dot
                let frame = CGRect(x: x, y: 0, width: width, height: Self.dot)
                let color = (index == selected ? NSColor.labelColor : NSColor.tertiaryLabelColor).cgColor
                if animated, !DS.Motion.reduceMotion {
                    let bounds = DS.Motion.spring(DS.Motion.snappy, keyPath: "bounds")
                    bounds.fromValue = NSValue(rect: mark.presentation()?.bounds ?? mark.bounds)
                    bounds.toValue = NSValue(rect: CGRect(origin: .zero, size: frame.size))
                    let position = DS.Motion.spring(DS.Motion.snappy, keyPath: "position")
                    position.fromValue = NSValue(point: mark.presentation()?.position ?? mark.position)
                    position.toValue = NSValue(point: CGPoint(x: frame.midX, y: frame.midY))
                    mark.add(bounds, forKey: "bounds")
                    mark.add(position, forKey: "position")
                }
                CATransaction.begin()
                CATransaction.setDisableActions(!animated)
                mark.frame = frame
                mark.backgroundColor = color
                CATransaction.commit()
                x += width + Self.gap
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        var edge: CGFloat = 0
        for index in 0..<count {
            let width = index == selected ? Self.long : Self.dot
            if x < edge + width + Self.gap / 2 { onSelect?(index); return }
            edge += width + Self.gap
        }
    }
}

// MARK: - Pages

/// A page: a title, a line under it, and its content; `arrive()` brings them in one after
/// another.
@MainActor
class WelcomePage: NSView {
    let stack = NSStackView()
    /// What arrives, in order, when the page is shown.
    var arrivals: [NSView] = []

    init(title: String, subtitle: String, titleSize: CGFloat = 36) {
        super.init(frame: .zero)
        wantsLayer = true
        let titleLabel = NSTextField(labelWithString: "")
        let titleFont = DS.Text.display(titleSize)
        titleLabel.attributedStringValue = NSAttributedString(string: title, attributes: [.font: titleFont, .kern: titleFont.pointSize * DS.Text.displayTracking, .foregroundColor: NSColor.labelColor])
        titleLabel.alignment = .center
        let subtitleLabel = NSTextField(wrappingLabelWithString: subtitle)
        subtitleLabel.font = DS.Text.custom(15)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.alignment = .center
        subtitleLabel.preferredMaxLayoutWidth = 560
        for label in [titleLabel, subtitleLabel] { TextScaleFollower.exempt(label) }
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = DS.Spacing.m
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(subtitleLabel)
        stack.setCustomSpacing(36, after: subtitleLabel)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 56),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 40),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -40),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            subtitleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
        ])
        arrivals = [titleLabel, subtitleLabel]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func addContent(_ view: NSView) {
        stack.addArrangedSubview(view)
        arrivals.append(view)
    }

    /// The parts rise in one after another, 70 ms apart.
    func arrive() {
        guard !DS.Motion.reduceMotion else { return }
        for (index, part) in arrivals.enumerated() {
            part.wantsLayer = true
            guard let layer = part.layer else { continue }
            let begin = CACurrentMediaTime() + 0.08 + Double(index) * 0.07
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = DS.Motion.presentDuration
            fade.timingFunction = DS.Motion.fadeCurve
            let rise = DS.Motion.spring(DS.Motion.smooth, keyPath: "transform.translation.y")
            rise.fromValue = -14
            rise.toValue = 0
            for animation in [fade, rise] as [CAAnimation] {
                animation.beginTime = begin
                animation.fillMode = .backwards
                layer.add(animation, forKey: "arrive.\(animation === fade ? "fade" : "rise")")
            }
        }
    }

    func didAppear() {}
    func willDisappear() {}
}

/// Page 1: the icon, the name, what Side is.
@MainActor
final class WelcomeHelloPage: WelcomePage {
    private let icon = NSImageView()

    init() {
        super.init(title: "Welcome to Side", subtitle: "The editor built around your agents, and the terminals they run in.", titleSize: 44)
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.wantsLayer = true
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 148), icon.heightAnchor.constraint(equalToConstant: 148)])
        stack.insertArrangedSubview(icon, at: 0)
        stack.setCustomSpacing(26, after: icon)
        arrivals.insert(icon, at: 0)
        // Centred in the page rather than hung from its top.
        for constraint in constraints where constraint.firstAttribute == .top && (constraint.firstItem as? NSView) === stack { constraint.isActive = false }
        stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 10).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The icon lands first, from a little smaller, with the smooth spring's overshoot.
    override func arrive() {
        super.arrive()
        guard !DS.Motion.reduceMotion, let layer = icon.layer else { return }
        let scale = DS.Motion.spring(DS.Motion.smooth, keyPath: "transform.scale")
        scale.fromValue = 0.82
        scale.toValue = 1
        scale.beginTime = CACurrentMediaTime() + 0.08
        scale.fillMode = .backwards
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: icon.frame.midX, y: icon.frame.midY)
        layer.add(scale, forKey: "arrive.scale")
    }
}

/// Page 2: the five stages, each played in a miniature Side. The list on the left goes through
/// them on its own, a bar under the current one filling as it plays; a click picks one.
@MainActor
final class WelcomeStagesPage: WelcomePage {
    private let showcase = WelcomeStageShowcase()
    private var rows: [WelcomeStageRow] = []
    private var timer: Timer?
    private static let dwell: TimeInterval = 5.5

    init() {
        super.init(title: "Five stages, one window", subtitle: "Everything a change needs, from the first line to the pull request.")
        let items: [(WelcomeStageShowcase.Stage, String, String, String)] = [
            (.editor, "Editor", "Your code, with language servers and your keymap.", "stage.make"),
            (.agent, "Agent", "Answers with plans, diagrams and tables.", "stage.think"),
            (.changes, "Changes", "The branch's changes, ready to commit.", "stage.review"),
            (.terminal, "Terminal", "Keeps running when Side quits. \(Shortcuts.display("view.terminalBeside")) puts it beside your code.", "stage.run"),
            (.branches, "Branches", "Every branch, with its agents and pull request.", "stage.tracks"),
        ]
        rows = items.map { item in
            let row = WelcomeStageRow(stage: item.0, title: item.1, detail: item.2, shortcut: Shortcuts.display(item.3))
            row.onClick = { [weak self] in self?.select(item.0, byHand: true) }
            return row
        }
        let list = NSStackView(views: rows)
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 2
        rows.forEach { $0.widthAnchor.constraint(equalToConstant: 300).isActive = true }
        let body = NSStackView(views: [list, showcase])
        body.orientation = .horizontal
        body.alignment = .centerY
        body.spacing = 36
        stack.setCustomSpacing(24, after: stack.arrangedSubviews[1])
        addContent(body)
        rows.first?.isCurrent = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didAppear() {
        showcase.play()
        select(.editor, byHand: false)
    }

    override func willDisappear() {
        timer?.invalidate()
        showcase.stop()
    }

    private func select(_ stage: WelcomeStageShowcase.Stage, byHand: Bool) {
        showcase.show(stage)
        for row in rows { row.isCurrent = row.stage == stage }
        rows[stage.rawValue].startProgress(Self.dwell)
        timer?.invalidate()
        // Under VoiceOver the list stays where it's put: moving on by itself is hard to follow.
        guard !Spoken.isEnabled() else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.dwell, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let next = WelcomeStageShowcase.Stage(rawValue: (stage.rawValue + 1) % WelcomeStageShowcase.Stage.allCases.count)!
                self.select(next, byHand: false)
            }
        }
    }
}

/// One stage in the list: its glyph, name and line, the shortcut, and the bar that fills while
/// it plays.
@MainActor
final class WelcomeStageRow: NSView {
    let stage: WelcomeStageShowcase.Stage
    var onClick: (() -> Void)?
    var isCurrent = false { didSet { refresh() } }
    private let glyph = NSImageView()
    private let titleLabel: NSTextField
    private let detailLabel: NSTextField
    private let progress = CALayer()
    private let track = CALayer()

    init(stage: WelcomeStageShowcase.Stage, title: String, detail: String, shortcut: String) {
        self.stage = stage
        titleLabel = NSTextField(labelWithString: title)
        detailLabel = NSTextField(wrappingLabelWithString: detail)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = DS.Radius.surface
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false
        glyph.image = DS.Glyph.image(named: DS.Glyph.name(stage.glyph), pointSize: 18)
        titleLabel.font = DS.Text.heading()
        detailLabel.font = DS.Text.body()
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.preferredMaxLayoutWidth = 236
        let key = NSTextField(labelWithString: shortcut)
        key.font = DS.Text.caption()
        key.textColor = .tertiaryLabelColor
        for view in [glyph, titleLabel, detailLabel, key] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        for label in [titleLabel, detailLabel, key] { TextScaleFollower.exempt(label) }
        layer?.addSublayer(track)
        layer?.addSublayer(progress)
        NSLayoutConstraint.activate([
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            glyph.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            glyph.widthAnchor.constraint(equalToConstant: 20),
            glyph.heightAnchor.constraint(equalToConstant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 12),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            key.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            key.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            detailLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -13),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(title): \(detail)")
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseUp(with event: NSEvent) { onClick?() }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let bar = CGRect(x: 46, y: 5, width: bounds.width - 60, height: 2)
        track.frame = bar
        track.cornerRadius = bar.height / 2
        progress.anchorPoint = CGPoint(x: 0, y: 0.5)
        progress.frame = bar
        progress.cornerRadius = bar.height / 2
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    /// The bar fills over the time this stage plays.
    func startProgress(_ duration: TimeInterval) {
        progress.removeAllAnimations()
        guard isCurrent else { return }
        let fill = CABasicAnimation(keyPath: "transform.scale.x")
        fill.fromValue = 0
        fill.toValue = 1
        fill.duration = duration
        fill.fillMode = .forwards
        fill.isRemovedOnCompletion = false
        progress.add(fill, forKey: "fill")
    }

    private func refresh() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = isCurrent ? DS.Color.raised.cgColor : nil
            progress.backgroundColor = DS.Color.accent.cgColor
            track.backgroundColor = DS.Color.hairline.cgColor
        }
        progress.isHidden = !isCurrent
        track.isHidden = !isCurrent
        setAccessibilitySelected(isCurrent)
        glyph.contentTintColor = isCurrent ? .labelColor : .secondaryLabelColor
        titleLabel.textColor = isCurrent ? .labelColor : .secondaryLabelColor
        detailLabel.isHidden = false
        DS.Motion.crossfade(self, duration: DS.Motion.glanceDuration)
    }
}

/// Page 3: the three things that set Side apart, each a small loop of it happening.
@MainActor
final class WelcomeIdeasPage: WelcomePage {
    private var demos: [WelcomeDemo] = []

    init() {
        super.init(title: "Side remembers your work", subtitle: "Three ideas you'll lean on every day.")
        let ideas: [(WelcomeDemo, String, String)] = [
            (WelcomeBranchesDemo(), "Every branch is a track", "Make a branch in Side or with git. It gets its own terminals, chats and changes."),
            (WelcomeKeepsRunningDemo(), "Terminals keep running", "Quit Side or update it: your terminals and agents carry on, and come back as you left them."),
            (WelcomeSharedChatDemo(), "One chat, two places", "Start Claude Code in Terminal, carry on the same chat in Agent, or the other way round."),
        ]
        demos = ideas.map(\.0)
        let cards = ideas.map { demo, title, detail in WelcomeCard(demo: demo, title: title, detail: detail) }
        let row = NSStackView(views: cards)
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 20
        // One height: the tallest card's.
        for card in cards.dropFirst() { card.heightAnchor.constraint(equalTo: cards[0].heightAnchor).isActive = true }
        stack.setCustomSpacing(30, after: stack.arrangedSubviews[1])
        stack.addArrangedSubview(row)
        arrivals.append(contentsOf: cards)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var active = false

    override func didAppear() {
        active = true
        for (index, demo) in demos.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25 + Double(index) * 0.35) { [weak self, weak demo] in
                // Not once the page has gone: it's still in the window while it slides out.
                guard let self, self.active, let demo, demo.window != nil else { return }
                demo.play()
            }
        }
    }

    override func willDisappear() {
        active = false
        demos.forEach { $0.stop() }
    }
}

/// A raised card: an illustration, a heading, a line or two.
@MainActor
final class WelcomeCard: NSView {
    init(demo: WelcomeDemo, title: String, detail: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        bindLayerBackground(DS.Color.raised)
        layer?.cornerRadius = DS.Radius.palette
        layer?.cornerCurve = .continuous
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = DS.Text.heading()
        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = DS.Text.body()
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.preferredMaxLayoutWidth = 220
        let stage = NSView()
        stage.bindLayerBackground(DS.Color.canvas.withAlphaComponent(0.6))
        stage.layer?.cornerRadius = DS.Radius.surface
        stage.layer?.cornerCurve = .continuous
        stage.translatesAutoresizingMaskIntoConstraints = false
        stage.addSubview(demo)
        for view in [stage, titleLabel, detailLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        for label in [titleLabel, detailLabel] { TextScaleFollower.exempt(label) }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 252),
            stage.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stage.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stage.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stage.heightAnchor.constraint(equalToConstant: 160),
            demo.centerXAnchor.constraint(equalTo: stage.centerXAnchor),
            demo.centerYAnchor.constraint(equalTo: stage.centerYAnchor),
            demo.widthAnchor.constraint(equalToConstant: demo.designSize.width),
            demo.heightAnchor.constraint(equalToConstant: demo.designSize.height),
            titleLabel.topAnchor.constraint(equalTo: stage.bottomAnchor, constant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            detailLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -18),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(title). \(detail)")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Page 4: the accent, the keymap and the editor theme, each applied as it's picked, with the
/// editor and a terminal beside them showing it.
@MainActor
final class WelcomeYoursPage: WelcomePage {
    private let preview = AppearancePreview()
    private var keymapCards: [WelcomeChoiceCard] = []
    private var themeCards: [WelcomeChoiceCard] = []
    private lazy var followSwitch = SettingsForm.toggle(DS.InterfaceTheme.followsEditorTheme, self, #selector(followChanged))

    /// The theme choices: Side's own, or a built-in pair (light, dark).
    private static let themes: [(name: String, light: String, dark: String)] = [
        ("Side", EditorThemes.sideID, EditorThemes.sideID),
        ("GitHub", "github-light", "github-dark"),
        ("One Dark", EditorThemes.sideID, "one-dark"),
    ]

    init() {
        super.init(title: "Make it yours", subtitle: "Each choice applies now. Change any of them later in Settings.")
        let form = NSStackView()
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = DS.Spacing.l

        form.addArrangedSubview(Self.sectionLabel("Accent"))
        form.addArrangedSubview(AccentSwatches())
        form.setCustomSpacing(22, after: form.arrangedSubviews.last!)

        form.addArrangedSubview(Self.sectionLabel("Keymap"))
        keymapCards = Shortcuts.Keymap.allCases.map { keymap in
            let detail = [("editor.moveLineUp", "Move line up"), ("navigate.jumpToDefinition", "Definition")].map { id, name in
                "\(Shortcuts.defaultChord(id, in: keymap)?.display ?? "—")  \(name)"
            }.joined(separator: "\n")
            let card = WelcomeChoiceCard(title: keymap.title, detail: detail)
            card.onClick = { [weak self] in
                Shortcuts.keymap = keymap
                self?.refreshChoices()
            }
            return card
        }
        form.addArrangedSubview(Self.row(keymapCards))
        form.setCustomSpacing(22, after: form.arrangedSubviews.last!)

        form.addArrangedSubview(Self.sectionLabel("Editor theme"))
        themeCards = Self.themes.map { theme in
            let card = WelcomeChoiceCard(title: theme.name, detail: nil, swatch: Self.swatch(for: theme))
            card.onClick = { [weak self] in
                EditorThemes.lightThemeID = theme.light
                EditorThemes.darkThemeID = theme.dark
                self?.refreshChoices()
            }
            return card
        }
        form.addArrangedSubview(Self.row(themeCards))
        let importButton = NSButton(title: "Import a VS Code Theme…", target: self, action: #selector(importTheme))
        importButton.isBordered = false
        importButton.attributedTitle = NSAttributedString(string: "Import a VS Code Theme…", attributes: [.font: DS.Text.body(.medium), .foregroundColor: DS.Color.accent])
        let follow = NSStackView(views: [followSwitch, Self.caption("Side's surfaces take the theme's colors")])
        follow.spacing = DS.Spacing.m
        form.addArrangedSubview(importButton)
        form.setCustomSpacing(DS.Spacing.s, after: importButton)
        form.addArrangedSubview(follow)

        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.widthAnchor.constraint(equalToConstant: 320).isActive = true
        let body = NSStackView(views: [form, preview])
        body.orientation = .horizontal
        body.alignment = .top
        body.spacing = 48
        stack.setCustomSpacing(28, after: stack.arrangedSubviews[1])
        addContent(body)
        refreshChoices()
        NotificationCenter.default.addObserver(self, selector: #selector(refreshChoices), name: EditorThemes.didChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshChoices), name: DS.Appearance.didChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = DS.Text.heading()
        TextScaleFollower.exempt(label)
        return label
    }

    private static func caption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = DS.Text.body()
        label.textColor = .secondaryLabelColor
        return label
    }

    private static func row(_ cards: [NSView]) -> NSStackView {
        let row = NSStackView(views: cards)
        row.orientation = .horizontal
        row.spacing = DS.Spacing.l
        return row
    }

    /// A theme as a few lines of its own code, on its own background, in the appearance it's for
    /// now.
    private static func swatch(for theme: (name: String, light: String, dark: String)) -> (Bool) -> (background: NSColor, runs: [NSColor]) {
        { dark in
            let id = dark ? theme.dark : theme.light
            if let picked = EditorThemes.all.first(where: { $0.id == id }) {
                let syntax = picked.syntaxTheme
                let runs = ["keyword", "function", "string", "type"].map { capture -> NSColor in
                    guard let rgba = syntax.color(for: capture) else { return picked.text.nsColor }
                    return NSColor(srgbRed: CGFloat(rgba.x), green: CGFloat(rgba.y), blue: CGFloat(rgba.z), alpha: 1)
                }
                return (picked.background.nsColor, runs)
            }
            let syntax = EditorThemes.syntax(dark: dark)
            let runs = ["keyword", "function", "string", "type"].map { capture -> NSColor in
                guard let rgba = syntax.color(for: capture) else { return .labelColor }
                return NSColor(srgbRed: CGFloat(rgba.x), green: CGFloat(rgba.y), blue: CGFloat(rgba.z), alpha: 1)
            }
            return (DS.Color.canvas, runs)
        }
    }

    @objc private func refreshChoices() {
        for (card, keymap) in zip(keymapCards, Shortcuts.Keymap.allCases) { card.isChosen = Shortcuts.keymap == keymap }
        for (card, theme) in zip(themeCards, Self.themes) {
            card.isChosen = EditorThemes.lightThemeID == theme.light && EditorThemes.darkThemeID == theme.dark
            card.needsDisplay = true
        }
        followSwitch.state = DS.InterfaceTheme.followsEditorTheme ? .on : .off
    }

    @objc private func followChanged() {
        DS.InterfaceTheme.followsEditorTheme = followSwitch.state == .on
    }

    @objc private func importTheme() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.message = "Choose a VS Code theme's .json"
        panel.allowedContentTypes = [.json]
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
            MainActor.assumeIsolated {
                guard let theme = try? EditorThemes.importVSCodeTheme(data, fallbackName: url.deletingPathExtension().lastPathComponent) else { return }
                if theme.isDark { EditorThemes.darkThemeID = theme.id } else { EditorThemes.lightThemeID = theme.id }
            }
        }
    }
}

/// A choice as a card: a title, a line or two, or a picture of it; a ring of the accent when
/// chosen.
@MainActor
final class WelcomeChoiceCard: NSView {
    var onClick: (() -> Void)?
    var isChosen = false { didSet { if isChosen != oldValue { needsDisplay = true; refreshAccessibility() } } }
    private let swatch: ((Bool) -> (background: NSColor, runs: [NSColor]))?
    private let title: String

    init(title: String, detail: String?, swatch: ((Bool) -> (background: NSColor, runs: [NSColor]))? = nil) {
        self.swatch = swatch
        self.title = title
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = DS.Text.body(.semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        TextScaleFollower.exempt(titleLabel)
        var constraints = [
            widthAnchor.constraint(equalToConstant: 128),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
        ]
        if let detail {
            let detailLabel = NSTextField(labelWithString: detail)
            detailLabel.font = DS.Text.caption()
            detailLabel.textColor = .secondaryLabelColor
            detailLabel.maximumNumberOfLines = 2
            detailLabel.translatesAutoresizingMaskIntoConstraints = false
            addSubview(detailLabel)
            TextScaleFollower.exempt(detailLabel)
            constraints += [
                titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
                detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
                detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
                detailLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            ]
        } else {
            constraints += [
                heightAnchor.constraint(equalToConstant: 84),
                titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            ]
        }
        NSLayoutConstraint.activate(constraints)
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override func mouseUp(with event: NSEvent) { onClick?() }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    private func refreshAccessibility() { setAccessibilityValue(isChosen ? 1 : 0) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: DS.Radius.surface, yRadius: DS.Radius.surface)
        DS.Color.raised.setFill()
        shape.fill()
        if let swatch {
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let look = swatch(dark)
            let picture = NSRect(x: 8, y: 8, width: bounds.width - 16, height: 46)
            look.background.setFill()
            NSBezierPath(roundedRect: picture, xRadius: DS.Radius.control, yRadius: DS.Radius.control).fill()
            let widths: [[CGFloat]] = [[18, 30, 22], [12, 26, 36], [24, 16]]
            for (line, runs) in widths.enumerated() {
                var x = picture.minX + 8
                for (index, width) in runs.enumerated() {
                    look.runs[(line + index) % look.runs.count].setFill()
                    NSBezierPath(roundedRect: NSRect(x: x, y: picture.minY + 9 + CGFloat(line) * 11, width: width, height: 4), xRadius: 2, yRadius: 2).fill()
                    x += width + 4
                }
            }
        }
        if isChosen {
            DS.Color.accent.setStroke()
            shape.lineWidth = 2
            shape.stroke()
        }
    }
}

/// Page 5: the agents Side found, ready, or how to install one. Side never installs anything.
@MainActor
final class WelcomeAgentsPage: WelcomePage {
    private let list = NSStackView()
    private let footnote = NSTextField(wrappingLabelWithString: "")

    init() {
        super.init(title: "Bring your agent", subtitle: "Side runs the agents you already use, signed in as you. It never installs anything on its own.")
        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.bindLayerBackground(DS.Color.raised)
        card.layer?.cornerRadius = DS.Radius.palette
        card.layer?.cornerCurve = .continuous
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0
        list.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(list)
        NSLayoutConstraint.activate([
            card.widthAnchor.constraint(equalToConstant: 600),
            list.topAnchor.constraint(equalTo: card.topAnchor, constant: 6),
            list.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -6),
            list.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: card.trailingAnchor),
        ])
        addContent(card)
        footnote.font = DS.Text.body()
        footnote.textColor = .secondaryLabelColor
        footnote.alignment = .center
        footnote.preferredMaxLayoutWidth = 560
        stack.setCustomSpacing(16, after: card)
        addContent(footnote)
        // What's known shows at once; a fresh look follows.
        fill(detecting: ACPAgent.builtIn.contains { AgentAvailability.isInstalled($0) == nil })
        AgentAvailability.refresh { [weak self] in self?.fill(detecting: false) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func fill(detecting: Bool) {
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let agents = ACPAgent.builtIn
        for (index, agent) in agents.enumerated() {
            let row = WelcomeAgentRow(agent: agent, installed: detecting ? nil : AgentAvailability.isInstalled(agent))
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            if !detecting { DS.Motion.appear(row, distance: 6) }
            if index < agents.count - 1 {
                let rule = NSView()
                rule.translatesAutoresizingMaskIntoConstraints = false
                rule.bindLayerBackground(DS.Color.hairline)
                list.addArrangedSubview(rule)
                NSLayoutConstraint.activate([rule.heightAnchor.constraint(equalToConstant: 1), rule.leadingAnchor.constraint(equalTo: list.leadingAnchor, constant: 56), rule.trailingAnchor.constraint(equalTo: list.trailingAnchor)])
            }
        }
        if detecting {
            footnote.stringValue = "Looking for the agents on this Mac…"
        } else if let agent = DefaultAgent.agent {
            footnote.stringValue = "New conversations use \(agent.displayName). Change it any time in Settings › Agents."
        } else {
            footnote.stringValue = "Install one in Terminal with its command, and Side finds it. Terminal works without one."
        }
    }
}

/// An agent: its mark, its name, and Ready or its install command with Copy.
@MainActor
final class WelcomeAgentRow: NSView {
    private let agent: ACPAgent

    init(agent: ACPAgent, installed: Bool?) {
        self.agent = agent
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let program = ["claude-code": "claude", "codex": "codex", "gemini": "gemini", "opencode": "opencode"][agent.id] ?? agent.binary
        let mark = NSImageView(image: ProgramMarks.image(forProgram: program))
        if !ProgramMarks.hasMark(program) { mark.contentTintColor = .secondaryLabelColor }
        mark.imageScaling = .scaleProportionallyUpOrDown
        let name = NSTextField(labelWithString: agent.displayName)
        name.font = DS.Text.body(.semibold)
        TextScaleFollower.exempt(name)
        let trailing: NSView
        switch installed {
        case nil:
            let looking = NSTextField(labelWithString: "Looking…")
            looking.font = DS.Text.body()
            looking.textColor = .tertiaryLabelColor
            trailing = looking
        case true?:
            trailing = DS.StatusLabel(state: .verified, text: "Ready")
        case false?:
            let command = NSTextField(labelWithString: agent.installHint)
            command.font = DS.Text.code(11, weight: .regular)
            command.textColor = .secondaryLabelColor
            command.lineBreakMode = .byTruncatingMiddle
            command.isSelectable = true
            command.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let copy = NSButton(image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy") ?? NSImage(), target: self, action: #selector(copyCommand))
            copy.isBordered = false
            copy.contentTintColor = .secondaryLabelColor
            copy.toolTip = "Copy the install command"
            let group = NSStackView(views: [command, copy])
            group.spacing = DS.Spacing.m
            trailing = group
        }
        for view in [mark, name, trailing] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 52),
            mark.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            mark.centerYAnchor.constraint(equalTo: centerYAnchor),
            mark.widthAnchor.constraint(equalToConstant: 22),
            mark.heightAnchor.constraint(equalToConstant: 22),
            name.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: 14),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailing.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 20),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailing.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func copyCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(agent.installHint, forType: .string)
    }
}

/// Page 6: a project to start in. A folder, a new one, or one of the folders lately open in
/// another editor.
@MainActor
final class WelcomeOpenPage: WelcomePage {
    var onOpened: (() -> Void)?
    private let recents = NSStackView()

    init() {
        super.init(title: "Open a project", subtitle: "Any folder with your code. Side finds its branches on its own.")
        let open = WelcomeTile(symbol: "folder", title: "Open Folder…")
        open.onClick = { [weak self] in self?.chooseFolder() }
        let create = WelcomeTile(symbol: "folder.badge.plus", title: "New Project…")
        create.onClick = { [weak self] in
            self?.onOpened?()
            DispatchQueue.main.asyncAfter(deadline: .now() + DS.Motion.dismissDuration * 1.6) { AppDelegate.shared?.newProjectFromMenu() }
        }
        let tiles = NSStackView(views: [open, create])
        tiles.spacing = 16
        addContent(tiles)
        recents.orientation = .vertical
        recents.alignment = .leading
        recents.spacing = 2
        stack.setCustomSpacing(30, after: tiles)
        addContent(recents)
        DispatchQueue.global(qos: .userInitiated).async {
            let found = OtherEditorRecents.load()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in self?.show(found) }
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func show(_ folders: [OtherEditorRecents.Folder]) {
        guard !folders.isEmpty else { return }
        let header = NSTextField(labelWithString: "Recently in your other editors")
        header.font = DS.Text.body(.semibold)
        header.textColor = .secondaryLabelColor
        recents.addArrangedSubview(header)
        recents.setCustomSpacing(DS.Spacing.m, after: header)
        for folder in folders {
            let row = WelcomeRecentRow(folder: folder)
            row.onClick = { [weak self] in self?.open(folder.url) }
            recents.addArrangedSubview(row)
            row.widthAnchor.constraint(equalToConstant: 520).isActive = true
        }
        DS.Motion.appear(recents, distance: 8)
    }

    private func chooseFolder() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.message = "Choose a project to open in Side"
        panel.prompt = "Open"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self?.open(url) }
        }
    }

    private func open(_ url: URL) {
        AppDelegate.shared?.revealProject(url) { $0.view.window?.makeKeyAndOrderFront(nil) }
        onOpened?()
    }
}

/// A large choice: a symbol over a title, raised, pressing in under the pointer.
@MainActor
final class WelcomeTile: NSView {
    var onClick: (() -> Void)?

    init(symbol: String, title: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        bindLayerBackground(DS.Color.raised)
        layer?.cornerRadius = DS.Radius.palette
        layer?.cornerCurve = .continuous
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 28, weight: .regular)
        icon.contentTintColor = DS.Color.accent
        let label = NSTextField(labelWithString: title)
        label.font = DS.Text.body(.semibold)
        TextScaleFollower.exempt(label)
        for view in [icon, label] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 200),
            heightAnchor.constraint(equalToConstant: 118),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -12),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 12),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        self.icon = icon
        NotificationCenter.default.addObserver(self, selector: #selector(accentChanged), name: DS.Appearance.didChangeNotification, object: nil)
    }

    private weak var icon: NSImageView?
    @objc private func accentChanged() { icon?.contentTintColor = DS.Color.accent }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseDown(with event: NSEvent) { DS.Motion.press(self, down: true, amount: 0.97) }
    override func mouseUp(with event: NSEvent) {
        DS.Motion.press(self, down: false)
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// A folder from another editor: its icon, name, where it is, and which editor had it.
@MainActor
final class WelcomeRecentRow: NSView {
    var onClick: (() -> Void)?
    private var tracking: NSTrackingArea?

    init(folder: OtherEditorRecents.Folder) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = DS.Radius.control
        let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: folder.url.path))
        let name = NSTextField(labelWithString: folder.url.lastPathComponent)
        name.font = DS.Text.body(.medium)
        let path = NSTextField(labelWithString: (folder.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
        path.font = DS.Text.caption()
        path.textColor = .tertiaryLabelColor
        path.lineBreakMode = .byTruncatingMiddle
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let source = NSTextField(labelWithString: folder.source)
        source.font = DS.Text.caption()
        source.textColor = .secondaryLabelColor
        for view in [icon, name, path, source] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 34),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            path.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 10),
            path.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
            source.leadingAnchor.constraint(greaterThanOrEqualTo: path.trailingAnchor, constant: 12),
            source.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            source.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Open \(folder.url.lastPathComponent), from \(folder.source)")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { bindLayerBackground(DS.Color.hoverCapsule) }
    override func mouseExited(with event: NSEvent) { unbindLayerBackground() }
    override func mouseUp(with event: NSEvent) { onClick?() }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
