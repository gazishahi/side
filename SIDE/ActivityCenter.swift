import AppKit
import SideAgents

/// The activity pill (prototype, 2026-11-04): "a glorified notification center" (the owner).
/// Whatever is happening, or wants you, somewhere you aren't looking, in any project and any
/// stage, gathered in one place you can jump from. It's in the bar only while there's something:
/// an agent working in a Terminal tab you're not on, one that finished there, an Agent turn on
/// another track, an update downloading.
@MainActor
final class ActivityCenter {
    static let shared = ActivityCenter()
    static let didChangeNotification = Notification.Name("SideActivityCenterDidChange")

    struct Item: Equatable {
        enum State: Equatable {
            case working
            case needsYou
            case finished
            case failed

            var word: String {
                switch self {
                case .working: return "Working"
                case .needsYou: return "Needs you"
                case .finished: return "Finished"
                case .failed: return "Failed"
                }
            }

            /// Needs-you first, then failures, then what finished, then what's working.
            var rank: Int {
                switch self {
                case .needsYou: return 0
                case .failed: return 1
                case .finished: return 2
                case .working: return 3
                }
            }

            var status: DS.StatusState {
                switch self {
                case .working: return .working
                case .needsYou: return .needsYou
                case .finished: return .verified
                case .failed: return .failed
                }
            }
        }

        enum Target: Equatable {
            case terminal(project: URL, session: UUID)
            case agent(project: URL, trackKey: String)
            case update
        }

        let id: String
        let state: State
        /// What it is: "Claude Code", "Agent on fix-login", "Side 0.5.0".
        let title: String
        /// Where: "audit-project · Refactor the parser".
        let place: String
        let program: String?
        let target: Target
        /// The program's own word for its state, when it reported one (OSC 7501): "Needs
        /// permission", "Has a question". Nil: the state's.
        var word: String? = nil
        /// The program's own line on what it wants or is doing ("Run swift test?"); untrusted text,
        /// shown plain. Empty when it said none.
        var reason: String = ""

        var stateWord: String { word ?? state.word }

        static func == (a: Item, b: Item) -> Bool {
            a.id == b.id && a.state == b.state && a.title == b.title && a.place == b.place && a.word == b.word && a.reason == b.reason
        }
    }

    private(set) var items: [Item] = []
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    private init() {}

    /// Starts gathering: on every terminal or agent change, and once a second for what has no
    /// notification of its own (a title spinner turning, a download's progress).
    func start() {
        guard timer == nil else { return }
        let names: [Notification.Name] = [TerminalSessionManager.didChangeNotification, UpdateDriver.didChangeNotification,
                                          NSApplication.didBecomeActiveNotification, NSWindow.didBecomeKeyNotification]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    func refresh() {
        var next: [Item] = []
        // The project window in front, if Side is: what it shows is in sight. Not the key window:
        // with Settings, the switcher or a popover key, the tab you were looking at counted as
        // out of sight, and the pill came and went with them (the owner, 2026-11-05).
        let front = NSApp.isActive ? ShellViewController.frontmost : nil
        for context in ProjectContextRegistry.openContexts() {
            let project = context.projectRoot
            let projectName = project.lastPathComponent
            let sessions = context.terminals.everySession()
            // Named as their tabs are: two Claude Codes are "Claude Code" and "Claude Code 2".
            let tabTitles = RunWorkspaceViewController.distinctTitles(sessions.map(\.title))
            for (session, tabTitle) in zip(sessions, tabTitles) {
                let vc = session.viewController
                // In sight: shown in the key window of an active Side. Anything else is out of sight.
                guard front?.isShowingTerminalSession(session.id) != true else { continue }
                // What's running is asked only of a terminal with something to report: it can read
                // the keeper's record from disk, and this runs every second.
                guard vc.isProgramWorking || vc.lastBellAt != nil || vc.turnFinishedAt != nil || !vc.programStatus.records.isEmpty else { continue }
                let program = vc.runningProgramName
                let name = Self.programName(program)
                let place = "\(projectName) \u{00B7} \(tabTitle)"
                // What the program says of itself (OSC 7501) comes first, with its reason.
                let reading = SessionRegistry.state(records: vc.programStatus, working: vc.isProgramWorking, news: vc.news, program: program)
                if reading.reported {
                    let reported: Item.State?
                    switch reading.state {
                    case .working: reported = .working
                    case .needsYou: reported = .needsYou
                    case .done: reported = .finished
                    case .failed: reported = .failed
                    case .idle: reported = nil
                    }
                    if let reported {
                        var item = Item(id: "term-\(session.id)", state: reported, title: name, place: place, program: program, target: .terminal(project: project, session: session.id))
                        if case .needsYou(.some) = reading.state { item.word = reading.state.word }
                        item.reason = reading.message
                        next.append(item)
                    }
                    continue
                }
                let state: Item.State?
                switch vc.news {
                // It rang the bell and nobody has looked since: it wants you.
                case .needsYou: state = .needsYou
                case .finished: state = .finished
                // Output alone isn't a finished turn: an idle Claude Code redraws (a resize, a
                // reattach, its own updates), and that read as "finished" with nothing done (the
                // owner, 2026-11-05). Only a turn seen ending (`turnFinishedAt`) is.
                case nil: state = vc.isProgramWorking ? .working : nil
                }
                if let state {
                    next.append(Item(id: "term-\(session.id)", state: state, title: name, place: place, program: program, target: .terminal(project: project, session: session.id)))
                }
            }
            for track in context.trackStore.tracks {
                guard let runner = context.runnerManager.existingRunner(forTrackKey: track.branchName) else { continue }
                let state: Item.State?
                switch runner.activity {
                case .working: state = .working
                case .needsYou: state = .needsYou
                case .failed: state = .failed
                case .doneUnread: state = .finished
                default: state = nil
                }
                guard let state else { continue }
                next.append(Item(id: "agent-\(project.path)-\(track.branchName)", state: state, title: "Agent", place: "\(projectName) \u{00B7} \(track.intent)",
                                 program: nil, target: .agent(project: project, trackKey: track.branchName)))
            }
        }
        // An update downloading isn't listed: its own pill, beside this one, says so already.
        next.sort { ($0.state.rank, $0.title) < ($1.state.rank, $1.title) }
        guard next != items else { return }
        items = next
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    /// What a project has to say, if anything wants you there: its most pressing item that isn't
    /// just working (the project switcher's dots).
    func attention(forProject path: String) -> DS.StatusState? { attentionItem(forProject: path)?.state.status }

    /// What a project is doing that most wants saying, working included (the switcher's cards).
    func mostPressingItem(forProject path: String) -> Item? {
        let target = URL(fileURLWithPath: path).standardizedFileURL.path
        return items.first { item in
            switch item.target {
            case .terminal(let project, _), .agent(let project, _): return project.standardizedFileURL.path == target
            case .update: return false
            }
        }
    }

    /// The item behind `attention`, for its own word ("Finished", not the status's generic name).
    func attentionItem(forProject path: String) -> Item? {
        let target = URL(fileURLWithPath: path).standardizedFileURL.path
        return items.first { item in
            guard item.state != .working else { return false }
            switch item.target {
            case .terminal(let project, _), .agent(let project, _): return project.standardizedFileURL.path == target
            case .update: return false
            }
        }
    }

    /// The program as people call it: `claude` is Claude Code.
    static func programName(_ program: String?) -> String {
        program.map(ProgramMarks.displayName) ?? "Terminal"
    }

    /// Goes to the item: the window with its project (opening it if none has it), the stage, the tab.
    func go(to item: Item) {
        guard let delegate = AppDelegate.shared else { return }
        switch item.target {
        case .terminal(let project, let session):
            delegate.revealProject(project) { $0.revealTerminalSession(session) }
        case .agent(let project, let trackKey):
            delegate.revealProject(project) { $0.revealAgent(trackKey: trackKey) }
        case .update:
            break
        }
        refresh()
    }

    /// The project an item happens in; nil for one that's Side's own (an update).
    static func project(of item: Item) -> URL? {
        switch item.target {
        case .terminal(let project, _), .agent(let project, _): return project.standardizedFileURL
        case .update: return nil
        }
    }

    /// The projects the pill shows marks for: each once, most pressing first, at most `limit`,
    /// leaving out the window's own (you know where you are).
    static func projects(of items: [Item], except current: URL?, limit: Int = 3) -> [URL] {
        let here = current?.standardizedFileURL.path
        var seen: Set<String> = []
        var projects: [URL] = []
        for item in items {
            guard let project = project(of: item), project.path != here, seen.insert(project.path).inserted else { continue }
            projects.append(project)
            if projects.count == limit { break }
        }
        return projects
    }

    static func icon(for item: Item) -> NSImage {
        switch item.target {
        case .terminal: return ProgramMarks.image(forProgram: item.program)
        case .agent: return DS.Glyph.image(named: ShellViewController.Stage.think.symbol) ?? NSImage()
        case .update: return NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil) ?? NSImage()
        }
    }
}

/// The pill itself, beside search: the most pressing item in a few words, and its state's mark.
/// Clicking opens the list.
@MainActor
final class ActivityPill {
    let view: GlassPill
    private var popover: NSPopover?
    private var observer: NSObjectProtocol?
    /// The window's project: activity there needs no mark (the owner, 2026-11-07).
    var currentProject: (() -> URL?)?
    /// Where the activity is: the projects' marks, overlapping, before the state's mark.
    private let projectMarks = NSImageView()
    private var shownProjects: [URL] = []

    init(glass: Bool, height: CGFloat) {
        view = GlassPill(height: height, glass: glass)
        projectMarks.translatesAutoresizingMaskIntoConstraints = false
        projectMarks.imageScaling = .scaleNone
        projectMarks.isHidden = true
        view.row.insertArrangedSubview(projectMarks, at: 0)
        view.setShown(false, animated: false)
        view.onClick = { [weak self] in self?.togglePopover() }
        observer = NotificationCenter.default.addObserver(forName: ActivityCenter.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(animated: true) }
        }
        ActivityCenter.shared.start()
        SessionRegistry.shared.start()
        refresh(animated: false)
    }

    /// "Claude Code finished": the most pressing item. The rest are counted beside it ("+2").
    static func summary(_ items: [ActivityCenter.Item]) -> String {
        guard let first = items.first else { return "" }
        return first.state == .working ? "\(first.title) working" : "\(first.title) \(first.stateWord.lowercased())"
    }

    func refresh(animated: Bool) {
        let items = ActivityCenter.shared.items
        if let first = items.first {
            let mark: GlassPill.Mark = first.state == .working ? .ring(fraction: nil) : .dot(first.state.status)
            view.set(title: Self.summary(items), mark: mark)
            view.setCount(items.count - 1)
            // As wide as its longest state, so "working" turning "finished" doesn't resize it.
            let states: [ActivityCenter.Item.State] = [.working, .needsYou, .finished, .failed]
            view.reserveWidth(for: states.map { Self.summary([ActivityCenter.Item(id: "", state: $0, title: first.title, place: "", program: nil, target: .update)]) }
                .max { GlassPill.measure($0) < GlassPill.measure($1) })
            view.toolTip = items.map { "\($0.title) \u{2014} \($0.stateWord), \($0.place)" + ($0.reason.isEmpty ? "" : ": \($0.reason)") }.joined(separator: "\n")
        }
        setProjects(ActivityCenter.projects(of: items, except: currentProject?()))
        view.setShown(!items.isEmpty, animated: animated)
        if items.isEmpty { popover?.close() }
        (popover?.contentViewController as? ActivityListViewController)?.reload()
    }

    private func togglePopover() {
        if let popover, popover.isShown { popover.close(); return }
        // One thing to say: a click goes there. A list is for choosing among several.
        let items = ActivityCenter.shared.items
        if items.count == 1, let only = items.first {
            ActivityCenter.shared.go(to: only)
            return
        }
        let content = ActivityListViewController()
        content.onPick = { [weak self] item in
            self?.popover?.close()
            ActivityCenter.shared.go(to: item)
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = content
        self.popover = popover
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
    }

    private func setProjects(_ projects: [URL]) {
        guard projects != shownProjects else { return }
        shownProjects = projects
        // Marks coming, going or changing: the pill crossfades and springs to its new width.
        if view.window != nil, !view.isHidden { DS.Motion.crossfade(view.row) }
        let marks = projects.map { Self.projectMark($0) }
        projectMarks.image = marks.isEmpty ? nil : Self.stacked(marks)
        if view.window != nil, !view.isHidden, projectMarks.isHidden != marks.isEmpty {
            DS.Motion.animate(DS.Motion.snappy) {
                projectMarks.isHidden = marks.isEmpty
                view.superview?.layoutSubtreeIfNeeded()
            }
        } else {
            projectMarks.isHidden = marks.isEmpty
        }
        let names = projects.map(\.lastPathComponent)
        projectMarks.setAccessibilityLabel(names.isEmpty ? nil : "In \(ListFormatter.localizedString(byJoining: names))")
    }

    static let markSize: CGFloat = 18

    /// A project's mark: its logo, else its symbol on a tile. Looked up, never made: a project
    /// shows in the activity only once it's open, so it has a space.
    static func projectMark(_ project: URL, size: CGFloat = markSize) -> NSImage {
        let space = ProjectSpaces.shared.spaces.first { $0.url.standardizedFileURL.path == project.standardizedFileURL.path }
        let logo = space?.logoPath.flatMap { ProjectLogo.chosen(URL(fileURLWithPath: $0), size: size) } ?? ProjectLogo.image(for: project, size: size)
        return logo ?? tile(symbol: space?.symbol ?? "folder.fill", color: space?.color ?? .systemGray, size: size)
    }

    /// The list's mark for an item: its project's, with what's running there (Claude Code's
    /// mark, the Agent's) on a small disc at the corner. Side's own items keep their icon.
    static func listMark(for item: ActivityCenter.Item, size: CGFloat = 22) -> NSImage {
        let program = ActivityCenter.icon(for: item)
        guard let project = ActivityCenter.project(of: item) else { return program }
        let base = projectMark(project, size: size)
        let badge = size * 0.55
        return NSImage(size: NSSize(width: size + 3, height: size + 3), flipped: false) { _ in
            base.draw(in: NSRect(x: 0, y: 3, width: size, height: size))
            let disc = NSRect(x: size + 3 - badge, y: 0, width: badge, height: badge)
            DS.Color.raised.setFill()
            NSBezierPath(ovalIn: disc).fill()
            let glyph = disc.insetBy(dx: badge * 0.17, dy: badge * 0.17)
            if program.isTemplate {
                // A symbol: drawn in the secondary color, as the row's icon was.
                let tinted = NSImage(size: glyph.size, flipped: false) { rect in
                    program.draw(in: rect)
                    NSColor.secondaryLabelColor.set()
                    rect.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: glyph)
            } else {
                program.draw(in: glyph)
            }
            return true
        }
    }

    /// A project with no logo: its symbol on a tile of its color, the shape a logo has, so marks
    /// overlap the same way whatever they are. Bare, two symbols ran into each other.
    static func tile(symbol: String, color: NSColor, size: CGFloat = markSize) -> NSImage {
        let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size * 0.5, weight: .semibold).applying(.init(paletteColors: [color])))
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            // Opaque, so a card behind doesn't show through it: the surface, then the tint.
            let tile = NSBezierPath(roundedRect: rect, xRadius: size * 0.225, yRadius: size * 0.225)
            DS.Color.raised.setFill()
            tile.fill()
            color.withAlphaComponent(0.2).setFill()
            tile.fill()
            if let glyph {
                let fit = glyph.size
                glyph.draw(in: NSRect(x: (size - fit.width) / 2, y: (size - fit.height) / 2, width: fit.width, height: fit.height))
            }
            return true
        }
    }
    /// How far each card behind shows past the one in front of it.
    static let markPeek: CGFloat = 6

    /// The marks as a deck (after Rex's, 2026-11-07): the most pressing in front at full size,
    /// each one behind it smaller and peeking out on the trailing side, with a soft shadow
    /// between them for depth.
    static func stacked(_ marks: [NSImage]) -> NSImage {
        let size = markSize, peek = markPeek, margin: CGFloat = 2
        let count = marks.count
        let canvas = NSSize(width: size + peek * CGFloat(max(count - 1, 0)) + 2 * margin, height: size + 2 * margin)
        return NSImage(size: canvas, flipped: false) { _ in
            for (index, mark) in marks.enumerated().reversed() {
                let side = size * (1 - 0.12 * CGFloat(index))
                let rect = NSRect(x: margin + size + peek * CGFloat(index) - side, y: margin + (size - side) / 2, width: side, height: side)
                NSGraphicsContext.saveGraphicsState()
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
                shadow.shadowBlurRadius = 2.5
                shadow.shadowOffset = NSSize(width: 1, height: -0.5)
                shadow.set()
                // Further back, a little fainter: the eye reads it as behind.
                mark.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1 - 0.12 * CGFloat(index))
                NSGraphicsContext.restoreGraphicsState()
            }
            return true
        }
    }

    var projectsForTesting: [String] { shownProjects.map(\.lastPathComponent) }

    var popoverForTesting: NSPopover? { popover }
    func clickForTesting() { togglePopover() }
}

/// The list the pill opens: each item with its program's mark, what it is, where, and its state.
/// A row goes there.
@MainActor
final class ActivityListViewController: NSViewController {
    var onPick: ((ActivityCenter.Item) -> Void)?
    private let stack = NSStackView()

    override func loadView() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DS.Spacing.xxs
        stack.edgeInsets = NSEdgeInsets(top: DS.Spacing.m, left: DS.Spacing.s, bottom: DS.Spacing.m, right: DS.Spacing.s)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor), stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            root.widthAnchor.constraint(equalToConstant: 340),
        ])
        view = root
        reload()
    }

    func reload() {
        guard isViewLoaded else { return }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let items = ActivityCenter.shared.items
        // One column for the states, as wide as the widest, so every dot lines up.
        let stateWidth = items.map { DS.StatusLabel(state: $0.state.status, text: $0.stateWord).fittingSize.width }.max() ?? 0
        for item in items {
            let row = ActivityRow(item: item, stateWidth: stateWidth)
            row.onPick = { [weak self] in self?.onPick?(item) }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -DS.Spacing.s * 2).isActive = true
        }
    }
}

/// One item: mark, title over place, state on the trailing edge; the selected capsule on hover.
@MainActor
private final class ActivityRow: NSView {
    var onPick: (() -> Void)?
    private let item: ActivityCenter.Item
    private var hovered = false { didSet { needsDisplay = true } }

    init(item: ActivityCenter.Item, stateWidth: CGFloat) {
        self.item = item
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        // Where it is, with what's running there on its corner (the owner, 2026-11-07).
        let icon = NSImageView(image: ActivityPill.listMark(for: item))
        icon.imageScaling = .scaleProportionallyDown
        let title = NSTextField(labelWithString: item.title)
        title.font = DS.Text.body(.medium)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.toolTip = item.title
        let place = NSTextField(labelWithString: item.place)
        place.font = DS.Text.caption()
        place.textColor = .secondaryLabelColor
        place.lineBreakMode = .byTruncatingTail
        place.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // What it's waiting for, in its own words, under where it is.
        let reason = NSTextField(labelWithString: item.reason)
        reason.font = DS.Text.caption()
        reason.textColor = .labelColor
        reason.lineBreakMode = .byTruncatingTail
        reason.isHidden = item.reason.isEmpty
        reason.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let words = NSStackView(views: [title, place, reason])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = 1
        // The state never gives way to a long title: it's what the row is for.
        let state = DS.StatusLabel(state: item.state.status, text: item.stateWord)
        state.setContentCompressionResistancePriority(.required, for: .horizontal)
        state.label.setContentCompressionResistancePriority(.required, for: .horizontal)
        state.widthAnchor.constraint(equalToConstant: ceil(stateWidth)).isActive = true
        let row = NSStackView(views: [icon, words, NSView(), state])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = DS.Spacing.m
        row.translatesAutoresizingMaskIntoConstraints = false
        words.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(row)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 25), icon.heightAnchor.constraint(equalToConstant: 25),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DS.Spacing.m),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DS.Spacing.m),
            row.topAnchor.constraint(equalTo: topAnchor, constant: DS.Spacing.s),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -DS.Spacing.s),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(item.title), \(item.stateWord), \(item.place)" + (item.reason.isEmpty ? "" : ", \(item.reason)"))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { onPick?() } }
    override func accessibilityPerformPress() -> Bool { onPick?(); return true }

    override func draw(_ dirtyRect: NSRect) {
        guard hovered else { return }
        DS.Color.selectedCapsule.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: DS.Radius.control + 2, yRadius: DS.Radius.control + 2).fill()
    }
}
