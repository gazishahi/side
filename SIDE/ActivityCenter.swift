import AppKit
import Heron

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

        static func == (a: Item, b: Item) -> Bool {
            a.id == b.id && a.state == b.state && a.title == b.title && a.place == b.place
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
        // The window in front, if Side is: what it shows is in sight.
        let front = NSApp.isActive ? (NSApp.keyWindow?.contentViewController as? ShellViewController) : nil
        for context in ProjectContextRegistry.openContexts() {
            let project = context.projectRoot
            let projectName = project.lastPathComponent
            for session in context.terminals.everySession() {
                let vc = session.viewController
                // In sight: shown in the key window of an active Side. Anything else is out of sight.
                guard front?.isShowingTerminalSession(session.id) != true else { continue }
                let program = vc.runningProgramName
                let name = Self.programName(program)
                let place = "\(projectName) \u{00B7} \(session.title)"
                if vc.isProgramWorking {
                    next.append(Item(id: "term-\(session.id)", state: .working, title: name, place: place, program: program, target: .terminal(project: project, session: session.id)))
                } else if session.hasUnseenOutput, ProgramMarks.hasMark(program) {
                    next.append(Item(id: "term-\(session.id)", state: .finished, title: name, place: place, program: program, target: .terminal(project: project, session: session.id)))
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
        if case .downloading(let fraction) = Updates.shared.driver.stage {
            let percent = fraction.map { " \(Int(($0 * 100).rounded()))%" } ?? ""
            next.append(Item(id: "update", state: .working, title: "Side update", place: "Downloading\(percent)", program: nil, target: .update))
        }
        next.sort { ($0.state.rank, $0.title) < ($1.state.rank, $1.title) }
        guard next != items else { return }
        items = next
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    /// What a project has to say, if anything wants you there: its most pressing item that isn't
    /// just working (the project switcher's dots).
    func attention(forProject path: String) -> DS.StatusState? {
        let target = URL(fileURLWithPath: path).standardizedFileURL.path
        return items.first { item in
            guard item.state != .working else { return false }
            switch item.target {
            case .terminal(let project, _), .agent(let project, _): return project.standardizedFileURL.path == target
            case .update: return false
            }
        }?.state.status
    }

    /// The program as people call it: `claude` is Claude Code.
    static func programName(_ program: String?) -> String {
        guard let program else { return "Terminal" }
        let name = (program as NSString).lastPathComponent
        let known = ["claude": "Claude Code", "codex": "Codex", "opencode": "OpenCode", "gemini": "Gemini", "aider": "Aider", "goose": "Goose", "amp": "Amp"]
        return known[name.lowercased()] ?? name
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

    static func icon(for item: Item) -> NSImage {
        switch item.target {
        case .terminal: return ProgramMarks.image(forProgram: item.program)
        case .agent: return NSImage(systemSymbolName: ShellViewController.Stage.think.symbol, accessibilityDescription: nil) ?? NSImage()
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

    init(glass: Bool, height: CGFloat) {
        view = GlassPill(height: height, glass: glass)
        view.setShown(false, animated: false)
        view.onClick = { [weak self] in self?.togglePopover() }
        observer = NotificationCenter.default.addObserver(forName: ActivityCenter.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(animated: true) }
        }
        ActivityCenter.shared.start()
        refresh(animated: false)
    }

    /// "Claude Code finished", or "Claude Code finished · 2 more".
    static func summary(_ items: [ActivityCenter.Item]) -> String {
        guard let first = items.first else { return "" }
        let lead = first.state == .working ? "\(first.title) working" : "\(first.title) \(first.state.word.lowercased())"
        return items.count == 1 ? lead : "\(lead) \u{00B7} \(items.count - 1) more"
    }

    func refresh(animated: Bool) {
        let items = ActivityCenter.shared.items
        if let first = items.first {
            let mark: GlassPill.Mark = first.state == .working ? .ring(fraction: nil) : .dot(first.state.status)
            view.set(title: Self.summary(items), mark: mark)
            view.toolTip = items.map { "\($0.title) \u{2014} \($0.state.word), \($0.place)" }.joined(separator: "\n")
        }
        view.setShown(!items.isEmpty, animated: animated)
        if items.isEmpty { popover?.close() }
        (popover?.contentViewController as? ActivityListViewController)?.reload()
    }

    private func togglePopover() {
        if let popover, popover.isShown { popover.close(); return }
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
        for item in ActivityCenter.shared.items {
            let row = ActivityRow(item: item)
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

    init(item: ActivityCenter.Item) {
        self.item = item
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let icon = NSImageView(image: ActivityCenter.icon(for: item))
        icon.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        icon.contentTintColor = .secondaryLabelColor
        icon.imageScaling = .scaleProportionallyDown
        let title = NSTextField(labelWithString: item.title)
        title.font = DS.Text.body(.medium)
        let place = NSTextField(labelWithString: item.place)
        place.font = DS.Text.caption()
        place.textColor = .secondaryLabelColor
        place.lineBreakMode = .byTruncatingTail
        let words = NSStackView(views: [title, place])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = 1
        let state = DS.StatusLabel(state: item.state.status, text: item.state.word)
        let row = NSStackView(views: [icon, words, NSView(), state])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = DS.Spacing.m
        row.translatesAutoresizingMaskIntoConstraints = false
        words.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(row)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 18), icon.heightAnchor.constraint(equalToConstant: 18),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DS.Spacing.m),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DS.Spacing.m),
            row.topAnchor.constraint(equalTo: topAnchor, constant: DS.Spacing.s),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -DS.Spacing.s),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(item.title), \(item.state.word), \(item.place)")
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
