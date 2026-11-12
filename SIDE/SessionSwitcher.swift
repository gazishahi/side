import AppKit

/// The session switcher (SIDE_RFC_SESSIONS.md, "Supervision, without a sidebar"): every session
/// in one panel, on demand (⌃⌘S), the way ⌃⌘P is every project. What needs you first, then what's
/// working, then the rest; type to find one by title, program, branch or project; Return goes to
/// it. Built as the project switcher is: the same panel, field, sliding selection and hints, out
/// of the stage bar.
@MainActor
final class SessionSwitcherOverlay: NSView, NSTextFieldDelegate {
    var onPick: ((SessionRegistry.Session) -> Void)?
    var onClose: (() -> Void)?
    /// Where the panel goes for a size: above the stage bar, centred (the shell's chrome).
    var placePanel: ((NSSize) -> NSRect)?

    static let width: CGFloat = 600
    static let headerHeight: CGFloat = 54
    static let footerHeight: CGFloat = 40
    static let rowHeight: CGFloat = 52

    /// What grows out of the bar: the surface and its shadow.
    let panelHost = NSView()
    private let field = NSTextField()
    private let content = NSStackView()
    private let document = SwitcherDocument()
    private let scroll = NSScrollView()
    private let selection = DS.Fill(DS.Color.selectedCapsule, cornerRadius: DS.Radius.surface)
    private var scrollHeight: NSLayoutConstraint?
    private var shown: [SessionRegistry.Session] = []
    private var rows: [SessionSwitcherRow] = []
    private(set) var selectedIndex = 0
    private var observer: NSObjectProtocol?
    private let openedAtPointer = NSEvent.mouseLocation

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
        reload()
        observer = NotificationCenter.default.addObserver(forName: SessionRegistry.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit { observer.map(NotificationCenter.default.removeObserver) }

    // MARK: Building

    private func build() {
        panelHost.wantsLayer = true
        if DS.Surfaces.needsShadow {
            panelHost.shadow = NSShadow()
            panelHost.layer?.shadowOpacity = 0.18
            panelHost.layer?.shadowRadius = 18
            panelHost.layer?.shadowOffset = CGSize(width: 0, height: -4)
        }
        addSubview(panelHost)

        let magnifier = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil) ?? NSImage())
        magnifier.symbolConfiguration = .init(pointSize: 14, weight: .medium)
        magnifier.contentTintColor = .secondaryLabelColor
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = DS.Text.custom(16)
        field.placeholderString = "Switch to a session"
        field.delegate = self
        field.setAccessibilityLabel("Find a session")
        let header = NSView()
        for view in [magnifier, field] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false; header.addSubview(view) }

        let divider = NSBox()
        divider.boxType = .custom
        divider.borderWidth = 0
        divider.fillColor = DS.Color.hairline

        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 2
        content.translatesAutoresizingMaskIntoConstraints = false
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(selection)
        document.addSubview(content)
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)

        let hint = NSTextField(labelWithString: "")
        hint.attributedStringValue = ProjectSwitcherOverlay.hints([("\u{21A9}", "Go"), ("esc", "Close")])
        let footer = NSStackView(views: [hint, NSView()])
        if let offer = hooksOffer() { footer.addArrangedSubview(offer) }
        footer.alignment = .centerY
        footer.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 14)

        let body = NSView()
        for view in [header, divider, scroll, footer] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false; body.addSubview(view) }
        let surface = DS.makeFloatingSurface(embedding: body)
        surface.frame = panelHost.bounds
        surface.autoresizingMask = [.width, .height]
        panelHost.addSubview(surface)

        let height = scroll.heightAnchor.constraint(equalToConstant: Self.rowHeight)
        scrollHeight = height
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: body.topAnchor), header.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: body.trailingAnchor), header.heightAnchor.constraint(equalToConstant: Self.headerHeight),
            magnifier.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 18), magnifier.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            field.leadingAnchor.constraint(equalTo: magnifier.trailingAnchor, constant: 10), field.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16),
            field.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            divider.topAnchor.constraint(equalTo: header.bottomAnchor), divider.heightAnchor.constraint(equalToConstant: 1),
            divider.leadingAnchor.constraint(equalTo: body.leadingAnchor), divider.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: divider.bottomAnchor), scroll.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -6), height,
            footer.topAnchor.constraint(equalTo: scroll.bottomAnchor), footer.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: body.trailingAnchor), footer.heightAnchor.constraint(equalToConstant: Self.footerHeight),
            footer.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            content.topAnchor.constraint(equalTo: document.topAnchor), content.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor), content.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
    }

    // MARK: Contents

    /// The three groups a session falls in: what to do now, what's under way, the rest.
    enum Group: Int, CaseIterable {
        case needsYou, working, other
        var title: String { ["Needs you", "Working", "Everything else"][rawValue] }
        static func of(_ state: SessionRegistry.State) -> Group {
            switch state {
            case .needsYou, .failed: return .needsYou
            case .working: return .working
            case .done, .idle: return .other
            }
        }
    }

    /// Plain shells at their prompt aren't sessions anyone switches to: the rest are.
    static func listed(_ sessions: [SessionRegistry.Session], query: String) -> [SessionRegistry.Session] {
        let worthListing = sessions.filter { $0.program != nil || $0.state != .idle || $0.reportsItself }
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let matching = needle.isEmpty ? worthListing : worthListing.filter { session in
            [session.title, session.program.map(ProgramMarks.displayName) ?? "", session.checkout?.branch ?? "", session.project?.lastPathComponent ?? "", session.message]
                .contains { $0.lowercased().contains(needle) }
        }
        return matching.sorted { (Group.of($0.state).rawValue, $0.state.rank, $0.title) < (Group.of($1.state).rawValue, $1.state.rank, $1.title) }
    }

    private func reload() {
        let selectedID = shown.indices.contains(selectedIndex) ? shown[selectedIndex].id : nil
        shown = Self.listed(SessionRegistry.shared.sessions, query: field.stringValue)
        content.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var lastGroup: Group?
        rows = []
        for (index, session) in shown.enumerated() {
            let group = Group.of(session.state)
            if group != lastGroup {
                lastGroup = group
                content.addArrangedSubview(ProjectSwitcherOverlay.heading(group.title))
            }
            let row = SessionSwitcherRow(session: session)
            row.onPick = { [weak self] in self?.pick(index) }
            row.onHover = { [weak self] in
                guard let self, NSEvent.mouseLocation != self.openedAtPointer else { return }
                self.select(index)
            }
            content.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
            rows.append(row)
        }
        if shown.isEmpty {
            let query = field.stringValue
            let none = NSTextField(labelWithString: query.isEmpty ? "Nothing running. Agents and programs in your terminals show here." : "No session matches \u{201C}\(query)\u{201D}.")
            none.font = DS.Text.body()
            none.textColor = .secondaryLabelColor
            let row = NSStackView(views: [none])
            row.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
            content.addArrangedSubview(row)
        }
        selectedIndex = selectedID.flatMap { id in shown.firstIndex { $0.id == id } } ?? 0
        needsLayout = true
        layoutSubtreeIfNeeded()
        applySelection(animated: false)
    }

    override func layout() {
        super.layout()
        placePanelHost()
        if selection.layer?.animationKeys()?.isEmpty ?? true { applySelection(animated: false, reveal: false) }
    }

    private func placePanelHost() {
        guard bounds.height > 0 else { return }
        let width = min(Self.width, bounds.width - 24)
        content.layoutSubtreeIfNeeded()
        let fitting = content.fittingSize.height + 12
        let chrome = Self.headerHeight + 1 + Self.footerHeight
        let room = max(Self.rowHeight * 2, bounds.height * 0.6 - chrome)
        let listHeight = min(max(fitting, Self.rowHeight), room)
        if scrollHeight?.constant != listHeight { scrollHeight?.constant = listHeight }
        let size = NSSize(width: width, height: chrome + listHeight)
        let frame = placePanel?(size) ?? NSRect(x: bounds.midX - width / 2, y: 80, width: width, height: size.height)
        if panelHost.frame != frame, panelHost.layer?.animationKeys()?.isEmpty ?? true { panelHost.frame = frame }
    }

    /// One capsule that slides to the selected session.
    private func applySelection(animated: Bool, reveal: Bool = true) {
        guard rows.indices.contains(selectedIndex) else { selection.isHidden = true; return }
        let row = rows[selectedIndex]
        document.layoutSubtreeIfNeeded()
        let target = row.convert(row.bounds, to: document)
        selection.isHidden = false
        if animated, !selection.frame.isEmpty {
            DS.Motion.animate(DS.Motion.snappy, { selection.animator().frame = target })
        } else if selection.frame != target {
            selection.frame = target
        }
        if reveal { row.scrollToVisible(row.bounds) }
    }

    private func select(_ index: Int) {
        guard rows.indices.contains(index), index != selectedIndex else { return }
        selectedIndex = index
        applySelection(animated: true)
    }

    private func move(_ delta: Int) {
        guard !rows.isEmpty else { return }
        select(min(max(selectedIndex + delta, 0), rows.count - 1))
    }

    private func pick(_ index: Int) {
        guard shown.indices.contains(index) else { return }
        let session = shown[index]
        // A session in another terminal can't be gone to from here.
        guard case .terminal = session.source else { NSSound.beep(); return }
        onClose?()
        onPick?(session)
    }

    func controlTextDidChange(_ obj: Notification) { reload() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertTab(_:)): move(1); return true
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.insertBacktab(_:)): move(-1); return true
        case #selector(NSResponder.insertNewline(_:)): pick(selectedIndex); return true
        case #selector(NSResponder.cancelOperation(_:)): onClose?(); return true
        default: return false
        }
    }

    func focus() { window?.makeFirstResponder(field) }

    // MARK: Claude Code's hooks, offered once

    private static let offeredKey = "side.claude-hooks.offered"
    nonisolated(unsafe) static var offerDefaults: UserDefaults = ClaudeHooks.defaults

    /// Asked once (SIDE_RFC_SESSIONS.md, decision 1), here where sessions are listed: Turn On
    /// or ×, and it isn't asked again. Settings › Agents has it after that.
    private func hooksOffer() -> NSView? {
        guard !Self.offerDefaults.bool(forKey: Self.offeredKey), !ClaudeHooks.isInstalledAnywhere else { return nil }
        let text = NSTextField(labelWithString: "See Claude Code sessions in any terminal")
        text.font = DS.Text.caption()
        text.textColor = .secondaryLabelColor
        text.toolTip = "Adds a small hook to Claude Code\u{2019}s settings so Side hears when a session is working, waiting on you or done. Settings \u{203A} Agents turns it off."
        let turnOn = NSButton(title: "Turn On", target: self, action: #selector(turnOnHooks))
        turnOn.controlSize = .small
        turnOn.bezelStyle = .push
        turnOn.setAccessibilityIdentifier("sessions.hooksOffer")
        let dismiss = DS.CircleButton(symbol: "xmark", diameter: 18, label: "Not Now")
        dismiss.target = self
        dismiss.action = #selector(dismissHooksOffer)
        let offer = NSStackView(views: [text, turnOn, dismiss])
        offer.spacing = DS.Spacing.s
        offer.alignment = .centerY
        hooksOfferView = offer
        return offer
    }
    private weak var hooksOfferView: NSView?

    @objc private func turnOnHooks() {
        Self.offerDefaults.set(true, forKey: Self.offeredKey)
        do {
            try ClaudeHooks.install(at: ClaudeHooks.userSettings)
            HookInbox.shared.start()
            hooksOfferView?.isHidden = true
        } catch {
            let alert = NSAlert()
            alert.messageText = "Claude Code\u{2019}s settings weren\u{2019}t changed"
            alert.informativeText = error.localizedDescription
            if let window { alert.beginSheetModal(for: window) }
        }
    }

    var hooksOfferShownForTesting: Bool { hooksOfferView.map { !$0.isHidden && $0.alphaValue > 0 } ?? false }
    func turnOnHooksForTesting() { turnOnHooks() }

    @objc private func dismissHooksOffer() {
        Self.offerDefaults.set(true, forKey: Self.offeredKey)
        DS.Motion.fade { self.hooksOfferView?.animator().alphaValue = 0 }
    }

    /// On its way out: the window under it takes clicks again at once.
    var passesClicksThrough = false
    override func hitTest(_ point: NSPoint) -> NSView? { passesClicksThrough ? nil : super.hitTest(point) }

    override func mouseDown(with event: NSEvent) {
        if !panelHost.frame.contains(convert(event.locationInWindow, from: nil)) { onClose?() }
    }

    // MARK: Testing

    var rowsForTesting: [String] { shown.map { "\($0.title) | \($0.state.word)" } }
    var selectedForTesting: String? { shown.indices.contains(selectedIndex) ? shown[selectedIndex].title : nil }
    func typeForTesting(_ text: String) { field.stringValue = text; reload() }
    func pickSelectedForTesting() { pick(selectedIndex) }
}

private final class SwitcherDocument: NSView {
    override var isFlipped: Bool { true }
}

/// A session: its program's mark, its title, where it is and what it said, and its state.
@MainActor
final class SessionSwitcherRow: NSView {
    var onPick: (() -> Void)?
    var onHover: (() -> Void)?
    private let session: SessionRegistry.Session

    init(session: SessionRegistry.Session) {
        self.session = session
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let icon = NSImageView(image: ProgramMarks.image(forProgram: session.program))
        icon.imageScaling = .scaleProportionallyDown
        if !ProgramMarks.hasMark(session.program) { icon.contentTintColor = .secondaryLabelColor }
        let title = NSTextField(labelWithString: session.title)
        title.font = DS.Text.body(.medium)
        title.lineBreakMode = .byTruncatingTail
        // Where: the branch (or detached checkout) and the project; a session in another terminal
        // says so. Then, from the program itself, what it's waiting for or doing.
        var place: [String] = []
        if let checkout = session.checkout { place.append(checkout.branch ?? "detached") }
        place.append(session.project?.lastPathComponent ?? (session.cwd.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Home"))
        if case .claude = session.source { place.append("in another terminal") }
        let where_ = NSTextField(labelWithString: place.joined(separator: " \u{00B7} "))
        where_.font = DS.Text.caption()
        where_.textColor = .secondaryLabelColor
        where_.lineBreakMode = .byTruncatingTail
        let said = NSTextField(labelWithString: session.message)
        said.font = DS.Text.caption()
        said.textColor = .labelColor
        said.lineBreakMode = .byTruncatingTail
        said.isHidden = session.message.isEmpty
        let words = NSStackView(views: [title, where_, said])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = 1
        for view in [title, where_, said, words] { view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        let state = DS.StatusLabel(state: session.state.status, text: session.state.word)
        state.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = NSStackView(views: [icon, words, NSView(), state])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = DS.Spacing.l
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 20), icon.heightAnchor.constraint(equalToConstant: 20),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        // Another terminal's session is listed, not gone to.
        if case .claude = session.source { alphaValue = 0.7 }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(([session.title, session.state.word] + place + (session.message.isEmpty ? [] : [session.message])).joined(separator: ", "))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?() }
    override func mouseMoved(with event: NSEvent) { onHover?() }
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { onPick?() } }
    override func accessibilityPerformPress() -> Bool { onPick?(); return true }
}
