import AppKit

/// One Terminal session beside Editor or Changes: the window's companion
/// (`SIDE_DESIGN_SESSIONS_2026-11-06.md`, session 1, agreed 2026-11-07). One task owns the
/// canvas: a stage, and at most this one pane beside it, on the same track.
///
/// The session leaves Terminal's tab row while it's here, as a tab torn out into a window of its
/// own does (`TerminalSessionManager.hold`), and goes back to it, still running, when the
/// companion closes. The shell owns the layout: where it docks, its width, and Follow.
@MainActor
final class TerminalCompanionViewController: NSViewController {
    let session: TerminalSession
    private let terminals: TerminalSessionManager
    let trackKey: String
    private let holder = UUID()

    /// The header's ×: the session goes back to Terminal's tabs.
    var onReturn: (() -> Void)?
    /// Follow switched in the header.
    var onFollowChanged: ((Bool) -> Void)?
    /// The leading edge dragged: the width it asks for, from the width it had when the drag began.
    var onResize: ((CGFloat) -> Void)?
    var onResizeEnded: (() -> Void)?
    /// A path in the terminal's output was clicked.
    var onFileLinkRequested: ((String) -> Bool)?
    /// The session left the project's terminals under it (its track deleted, the project closed).
    var onEnded: (() -> Void)?

    private let header = NSView()
    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let dot = DS.StatusDot(state: .idle)
    private let followToggle = DS.CapsuleToggle()
    private let returnButton = DS.CircleButton(symbol: "xmark", diameter: 22, label: "Back to Terminal Tabs")
    private let body = NSView()
    private let handle = CompanionResizeHandle()
    private var terminalBottom: NSLayoutConstraint?
    private var bottomObstruction: CGFloat = 0
    private var observer: NSObjectProtocol?

    static let headerHeight: CGFloat = ChromeHost.rowHeight
    private static let inset: CGFloat = 12

    init(session: TerminalSession, terminals: TerminalSessionManager, trackKey: String) {
        self.session = session
        self.terminals = terminals
        self.trackKey = trackKey
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() { view = NSView() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.wantsLayer = true
        // The terminal's own sheet, as on the Terminal stage.
        view.bindLayerBackground(DS.Color.raised)
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.group)
        view.setAccessibilityLabel("Terminal beside the stage")

        let separator = NSView()
        separator.wantsLayer = true
        separator.bindLayerBackground(.separatorColor)
        separator.translatesAutoresizingMaskIntoConstraints = false

        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.contentTintColor = .secondaryLabelColor
        icon.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        titleLabel.font = DS.Text.body(.medium)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        followToggle.title = "Follow"
        followToggle.font = DS.Text.caption(.medium)
        followToggle.state = .on
        followToggle.applyState()
        followToggle.toolTip = "Show the file this session changes in the Editor. A click or a keystroke in the Editor turns it off."
        followToggle.target = self
        followToggle.action = #selector(followToggled)
        returnButton.target = self
        returnButton.action = #selector(returnTapped)

        let row = NSStackView(views: [icon, titleLabel, dot, NSView(), followToggle, returnButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = DS.Spacing.m
        row.setCustomSpacing(DS.Spacing.s, after: icon)
        row.setClippingResistancePriority(.defaultLow, for: .horizontal)
        row.translatesAutoresizingMaskIntoConstraints = false
        header.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(row)
        body.translatesAutoresizingMaskIntoConstraints = false
        handle.translatesAutoresizingMaskIntoConstraints = false
        handle.onDrag = { [weak self] offset in self?.onResize?(offset) }
        handle.onEnd = { [weak self] in self?.onResizeEnded?() }
        for subview in [header, body, separator, handle] { view.addSubview(subview) }

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: Self.headerHeight),
            row.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: Self.inset + DS.Spacing.xs),
            row.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -DS.Spacing.m),
            row.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            body.topAnchor.constraint(equalTo: header.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            separator.topAnchor.constraint(equalTo: view.topAnchor),
            separator.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),
            handle.topAnchor.constraint(equalTo: view.topAnchor),
            handle.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            handle.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: -CompanionResizeHandle.width / 2),
            handle.widthAnchor.constraint(equalToConstant: CompanionResizeHandle.width),
        ])

        observer = NotificationCenter.default.addObserver(forName: TerminalSessionManager.didChangeNotification, object: terminals, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.terminalsChanged() }
        }
        // Out of Terminal's tabs first: its view lets go of the terminal before this one takes it.
        terminals.hold(session, holder: holder, origin: self)
        mount()
        refresh()
    }

    private func mount() {
        let vc = session.viewController
        if vc.parent != nil, vc.parent !== self { vc.view.removeFromSuperview(); vc.removeFromParent() }
        addChild(vc)
        vc.view.isHidden = false
        vc.view.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(vc.view)
        let bottom = vc.view.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: terminalBottomConstant)
        terminalBottom = bottom
        NSLayoutConstraint.activate([
            vc.view.topAnchor.constraint(equalTo: body.topAnchor, constant: DS.Spacing.xs),
            vc.view.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: Self.inset),
            vc.view.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -Self.inset),
            bottom,
        ])
        vc.onFileLinkRequested = { [weak self] link in self?.onFileLinkRequested?(link) ?? false }
        terminals.markDisplayed(session, by: self)
        terminals.clearUnseenOutput(session)
        vc.activate()
    }

    /// The session goes back to Terminal's tabs, still running, as the tab Terminal shows.
    func returnSession() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        let vc = session.viewController
        terminals.markDisplayed(nil, by: self)
        if vc.parent === self { vc.view.removeFromSuperview(); vc.removeFromParent() }
        vc.onFileLinkRequested = nil
        terminals.release(holder: holder)
        terminals.select(session)
    }

    private var terminalBottomConstant: CGFloat { -(bottomObstruction > 0 ? bottomObstruction + DS.Spacing.s : Self.inset) }

    /// What the floating bar covers at the bottom: the grid ends above it, as on Terminal.
    func setBottomObstruction(_ height: CGFloat) {
        bottomObstruction = height
        terminalBottom?.constant = terminalBottomConstant
    }

    /// Docked, it's a pane of the window; floating (a window too narrow for both), a sheet over
    /// the stage's trailing edge.
    func setFloating(_ floating: Bool) {
        view.layer?.cornerRadius = floating ? DS.Radius.surface : 0
        view.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        view.shadow = floating ? NSShadow() : nil
        view.layer?.shadowOpacity = floating ? 0.18 : 0
        view.layer?.shadowRadius = 18
        view.layer?.shadowOffset = CGSize(width: -4, height: 0)
    }

    var follows: Bool { followToggle.state == .on }

    func setFollows(_ on: Bool) {
        guard follows != on else { return }
        followToggle.state = on ? .on : .off
        followToggle.applyState()
        followToggle.setAccessibilityValue(on ? "on" : "off")
    }

    /// Whether the person is typing into the companion's terminal.
    var terminalHasFocus: Bool {
        guard let responder = view.window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: session.viewController.view)
    }

    func focusTerminal() { view.window?.makeFirstResponder(session.viewController.terminalView) }

    @objc private func followToggled() {
        followToggle.setAccessibilityValue(follows ? "on" : "off")
        onFollowChanged?(follows)
    }

    @objc private func returnTapped() { onReturn?() }

    private func terminalsChanged() {
        guard terminals.sessions(holder: holder).contains(where: { $0 === session }) else {
            onEnded?()
            return
        }
        refresh()
    }

    private func refresh() {
        let vc = session.viewController
        titleLabel.stringValue = session.title
        icon.image = ProgramMarks.image(forProgram: vc.runningProgramName)
        let state: DS.StatusState
        if vc.isProgramWorking { state = .working }
        else if case .needsYou? = vc.news { state = .needsYou }
        else if case .finished? = vc.news { state = .verified }
        else { state = .idle }
        dot.state = state
        dot.isHidden = state == .idle
        dot.setAccessibilityLabel(state.name)
        let directory = (vc.currentDirectory ?? vc.workingDirectory).map { ($0 as NSString).abbreviatingWithTildeInPath }
        titleLabel.toolTip = [session.title, directory].compactMap { $0 }.joined(separator: "\n")
    }

    var stateForTesting: String {
        "title=\(session.title) follow=\(follows ? "on" : "off") dot=\(dot.isHidden ? "none" : dot.state.name)"
    }
}

/// The companion's leading edge: drag to change its width.
private final class CompanionResizeHandle: NSView {
    static let width: CGFloat = 8
    var onDrag: ((CGFloat) -> Void)?
    var onEnd: (() -> Void)?
    private var start: CGFloat = 0

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }

    override func mouseDown(with event: NSEvent) { start = event.locationInWindow.x }

    /// Leftward is wider: the companion grows into the stage.
    override func mouseDragged(with event: NSEvent) { onDrag?(start - event.locationInWindow.x) }

    override func mouseUp(with event: NSEvent) { onEnd?() }
}
