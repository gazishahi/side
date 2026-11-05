import AppKit

/// Settings → Shortcuts: an area to a card, the cards flowing into columns as the window
/// widens, each folded to its name and count until opened (SIDE_DESIGN_POLISH_0.5.md §5; the
/// owner, 2026-11-05: still "a long list", and the width left empty). Search by name or by
/// pressing the keys, or show only what you changed or what shares keys: the cards with a match
/// open. Click a shortcut and press new keys to rebind it; a chord another command has is
/// named, and taking it waits for a yes.
@MainActor
final class ShortcutsViewController: NSViewController, NSSearchFieldDelegate {
    private let search = NSSearchField()
    private let keySearch = KeyCaptureButton()
    /// Changed, Conflicts: either, both or neither.
    private let filters = NSSegmentedControl(labels: ["Changed", "Conflicts"], trackingMode: .selectAny, target: nil, action: nil)
    private var changedOnly: Bool { filters.isSelected(forSegment: 0) }
    private var conflictsOnly: Bool { filters.isSelected(forSegment: 1) }
    private let keymapPopup = NSPopUpButton()
    private let foldAllButton = NSButton(title: "", target: nil, action: nil)
    private var query = ""
    private var keyFilter: KeyChord?
    private var cards: [Shortcuts.Area: ShortcutAreaCard] = [:]
    private var searchSized = false

    enum Row: Equatable {
        case area(Shortcuts.Area, count: Int)
        case command(Shortcuts.Command)
    }

    /// Areas left open, kept between visits.
    private static let openKey = "SideShortcutsOpenAreas"
    static var openAreas: Set<String> {
        get { Set(Shortcuts.defaults.stringArray(forKey: openKey) ?? []) }
        set { Shortcuts.defaults.set(newValue.sorted(), forKey: openKey) }
    }

    override func loadView() { view = NSView() }

    override func viewDidLoad() {
        super.viewDidLoad()
        search.placeholderString = "Search commands"
        search.delegate = self
        search.setAccessibilityLabel("Search shortcuts")
        keySearch.onChord = { [weak self] chord in self?.keyFilter = chord; self?.reload() }
        filters.target = self
        filters.action = #selector(filterToggled)
        filters.setToolTip("Only the shortcuts you changed", forSegment: 0)
        filters.setToolTip("Only keys two commands share in the same place", forSegment: 1)
        filters.setAccessibilityLabel("Show only")
        for keymap in Shortcuts.Keymap.allCases { keymapPopup.addItem(withTitle: keymap.title) }
        keymapPopup.target = self
        keymapPopup.action = #selector(keymapChosen(_:))
        keymapPopup.setAccessibilityLabel("Keymap")
        keymapPopup.toolTip = "Whose keys the defaults are: Xcode's, VS Code's or JetBrains'. A shortcut you change stays yours whichever you pick."
        foldAllButton.bezelStyle = .push
        foldAllButton.target = self
        foldAllButton.action = #selector(foldAll)
        NotificationCenter.default.addObserver(self, selector: #selector(shortcutsChanged), name: Shortcuts.didChangeNotification, object: nil)
        reload()
    }

    @objc private func shortcutsChanged() { reload() }

    func controlTextDidChange(_ obj: Notification) {
        query = search.stringValue.trimmingCharacters(in: .whitespaces)
        reload()
        view.window?.makeFirstResponder(search)
        search.currentEditor()?.selectedRange = NSRange(location: search.stringValue.count, length: 0)
    }

    /// The commands a search finds: by title, area, or the keys as written ("⌘K", "cmd k").
    static func matches(_ command: Shortcuts.Command, _ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let chord = Shortcuts.display(command.id)
        return command.title.localizedCaseInsensitiveContains(query) || command.area.rawValue.localizedCaseInsensitiveContains(query)
            || (!chord.isEmpty && chord.localizedCaseInsensitiveContains(query))
    }

    /// Commands on keys another command has in the same place: one of them never runs. Fixed
    /// keys work only inside their own view (↩ in a list), so they share nothing.
    static func conflicting() -> Set<String> {
        var byKeys: [String: [String]] = [:]
        for command in Shortcuts.all where !command.isFixed {
            guard let chord = Shortcuts.chord(command.id) else { continue }
            byKeys["\(command.context?.rawValue ?? "")|\(chord.display)", default: []].append(command.id)
        }
        return Set(byKeys.values.filter { $0.count > 1 }.flatMap { $0 })
    }

    /// What the page shows: each area with a match, then its matching commands.
    static func rows(query: String, keys: KeyChord?, area: Shortcuts.Area?, changedOnly: Bool, conflictsOnly: Bool) -> [Row] {
        let conflicts = conflictsOnly ? conflicting() : []
        var rows: [Row] = []
        for each in Shortcuts.Area.allCases where area == nil || each == area {
            let commands = Shortcuts.all.filter { command in
                command.area == each && matches(command, query)
                    && (keys == nil || Shortcuts.chord(command.id) == keys)
                    && (!changedOnly || Shortcuts.isChanged(command.id))
                    && (!conflictsOnly || conflicts.contains(command.id))
            }
            guard !commands.isEmpty else { continue }
            rows.append(.area(each, count: commands.count))
            rows += commands.map(Row.command)
        }
        return rows
    }

    /// A search or a filter: its matches show open, whatever was folded.
    private var isFiltering: Bool { !query.isEmpty || keyFilter != nil || changedOnly || conflictsOnly }

    private func reload() {
        keymapPopup.selectItem(at: Shortcuts.Keymap.allCases.firstIndex(of: Shortcuts.keymap) ?? 0)
        let rows = Self.rows(query: query, keys: keyFilter, area: nil, changedOnly: changedOnly, conflictsOnly: conflictsOnly)
        let conflicts = Self.conflicting()
        let open = Self.openAreas
        var grouped: [(Shortcuts.Area, [Shortcuts.Command])] = []
        for row in rows {
            switch row {
            case .area(let area, _): grouped.append((area, []))
            case .command(let command): grouped[grouped.count - 1].1.append(command)
            }
        }
        cards = [:]
        var views: [NSView] = [SettingsSplitViewController.hero(.shortcuts), toolbar()]
        for (area, commands) in grouped {
            let card = ShortcutAreaCard(area: area, rows: commands.map { commandRow($0, conflicts: conflicts) }, open: isFiltering || open.contains(area.rawValue))
            card.onToggle = { [weak self] isOpen in self?.remember(area, open: isOpen) }
            cards[area] = card
            views.append(card.view)
        }
        if grouped.isEmpty { views.append(SettingsForm.footnote(emptyText)) }
        views.append(footer())
        foldAllButton.title = cards.values.contains { $0.isOpen } ? "Collapse All" : "Expand All"
        foldAllButton.isHidden = isFiltering || grouped.isEmpty
        let scroll = view.subviews.first as? NSScrollView
        let origin = scroll?.contentView.bounds.origin
        let page = SettingsForm.page(views, maxHeight: 700)
        SettingsForm.install(page, in: view)
        // The same place after a rebind or a filter, not back at the top.
        if let origin, let newScroll = page as? NSScrollView {
            view.layoutSubtreeIfNeeded()
            newScroll.contentView.scroll(to: origin)
            newScroll.reflectScrolledClipView(newScroll.contentView)
        }
    }

    private var emptyText: String {
        if conflictsOnly, query.isEmpty, keyFilter == nil { return "No two commands share keys." }
        if changedOnly, query.isEmpty, keyFilter == nil { return "You haven\u{2019}t changed any shortcut." }
        if let keyFilter, query.isEmpty { return "\(keyFilter.display) is free." }
        return "No shortcut matches."
    }

    private func toolbar() -> NSView {
        let keymapLabel = NSTextField(labelWithString: "Keymap")
        keymapLabel.textColor = .secondaryLabelColor
        keymapLabel.font = DS.Text.caption()
        let bar = NSStackView(views: [search, keySearch, filters, foldAllButton, NSView(), keymapLabel, keymapPopup])
        bar.orientation = .horizontal
        bar.alignment = .centerY
        bar.spacing = DS.Spacing.m
        bar.setCustomSpacing(DS.Spacing.s, after: keymapLabel)
        if !searchSized {
            searchSized = true
            search.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
            search.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            // The search gives way first; the keymap always reads whole.
            keymapPopup.setContentCompressionResistancePriority(.required, for: .horizontal)
            search.widthAnchor.constraint(lessThanOrEqualToConstant: 320).isActive = true
        }
        return bar
    }

    private func footer() -> NSView {
        let reset = SettingsForm.button("Reset All to Defaults", self, #selector(resetAll))
        reset.isEnabled = Shortcuts.all.contains { Shortcuts.isChanged($0.id) }
        let note = SettingsForm.footnote("Lighter shortcuts work inside their view (a list, a text field) and can't be changed.")
        let bar = NSStackView(views: [note, NSView(), reset])
        bar.orientation = .horizontal
        bar.alignment = .centerY
        bar.edgeInsets = NSEdgeInsets(top: 0, left: SettingsForm.rowInset, bottom: 0, right: 0)
        return bar
    }

    private func remember(_ area: Shortcuts.Area, open: Bool) {
        foldAllButton.title = cards.values.contains { $0.isOpen } ? "Collapse All" : "Expand All"
        guard !isFiltering else { return }
        var areas = Self.openAreas
        if open { areas.insert(area.rawValue) } else { areas.remove(area.rawValue) }
        Self.openAreas = areas
    }

    @objc private func foldAll() {
        let opening = !cards.values.contains { $0.isOpen }
        for card in cards.values { card.setOpen(opening) }
        Self.openAreas = opening ? Set(cards.keys.map(\.rawValue)) : []
        foldAllButton.title = opening ? "Collapse All" : "Expand All"
    }

    @objc private func filterToggled() { reload() }

    /// Title (and where it works, when that's one kind of file) on the left; reset and the keys
    /// on the right, the keys in one column.
    private func commandRow(_ command: Shortcuts.Command, conflicts: Set<String>) -> NSView {
        var accessory: [NSView] = []
        if Shortcuts.isChanged(command.id), !command.isFixed {
            let reset = NSButton(image: NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: nil) ?? NSImage(), target: nil, action: nil)
            reset.isBordered = false
            reset.contentTintColor = .secondaryLabelColor
            reset.setAccessibilityLabel("Reset \(command.title) to \(Shortcuts.defaultChord(command.id)?.display ?? "none")")
            reset.toolTip = "Back to \(Shortcuts.defaultChord(command.id)?.display ?? "none")"
            let target = ClosureTarget { Shortcuts.reset(command.id) }
            reset.target = target
            reset.action = #selector(ClosureTarget.run)
            objc_setAssociatedObject(reset, &ClosureTarget.key, target, .OBJC_ASSOCIATION_RETAIN)
            accessory.append(reset)
        }
        if command.isFixed {
            let label = NSTextField(labelWithString: Shortcuts.display(command.id))
            label.font = DS.Text.body()
            label.textColor = .tertiaryLabelColor
            label.alignment = .center
            label.widthAnchor.constraint(equalToConstant: 120).isActive = true
            accessory.append(label)
        } else {
            let recorder = ShortcutRecorder(commandID: command.id)
            recorder.onRecord = { [weak self] chord in self?.record(chord, for: command) }
            accessory.append(recorder)
        }
        let keys = NSStackView(views: accessory)
        keys.orientation = .horizontal
        keys.spacing = DS.Spacing.m
        keys.setHuggingPriority(.required, for: .horizontal)
        let row = SettingsForm.row(command.title, keys, titleColor: command.isFixed ? .secondaryLabelColor : .labelColor)
        // Where it works, and that it shares its keys: beside the title.
        var marks: [NSView] = []
        if let context = command.context {
            marks.append(SettingsForm.badge(context == .markdown ? "Markdown" : "LaTeX", color: .secondaryLabelColor))
        }
        if conflicts.contains(command.id) {
            let mark = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Shares its keys") ?? NSImage())
            mark.contentTintColor = .systemOrange
            mark.symbolConfiguration = .init(pointSize: 11, weight: .regular)
            let other = Shortcuts.chord(command.id).flatMap { Shortcuts.conflict(for: $0, excluding: command.id) }
            mark.toolTip = other.map { "Same keys as \u{201C}\($0.title)\u{201D}" }
            marks.append(mark)
        }
        if !marks.isEmpty, let line = row.subviews.first as? NSStackView, let text = line.arrangedSubviews.first as? NSStackView,
           let title = text.arrangedSubviews.first {
            text.removeArrangedSubview(title)
            title.removeFromSuperview()
            let titled = NSStackView(views: [title] + marks)
            titled.orientation = .horizontal
            titled.spacing = DS.Spacing.s
            text.insertArrangedSubview(titled, at: 0)
        }
        return row
    }

    /// A new chord for a command: taken at once, or, if another command has it, after asking.
    private func record(_ chord: KeyChord?, for command: Shortcuts.Command) {
        guard let chord else { Shortcuts.set(nil, for: command.id); return }
        guard let other = Shortcuts.conflict(for: chord, excluding: command.id) else {
            Shortcuts.set(chord, for: command.id)
            return
        }
        guard let window = view.window, !other.isFixed else {
            if other.isFixed { NSSound.beep() }
            return
        }
        let alert = NSAlert()
        alert.messageText = "\(chord.display) is \u{201C}\(other.title)\u{201D}"
        alert.informativeText = "Use it for \u{201C}\(command.title)\u{201D} instead? \u{201C}\(other.title)\u{201D} will have no shortcut."
        alert.addButton(withTitle: "Use It Here")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            Shortcuts.set(nil, for: other.id)
            Shortcuts.set(chord, for: command.id)
        }
    }

    @objc private func resetAll() { Shortcuts.resetAll() }

    @objc private func keymapChosen(_ sender: NSPopUpButton) {
        let chosen = Shortcuts.Keymap.allCases[max(0, sender.indexOfSelectedItem)]
        guard chosen != Shortcuts.keymap else { return }
        Shortcuts.keymap = chosen
    }

    // MARK: Testing

    func searchForTesting(_ text: String) { search.stringValue = text; query = text; reload() }
    func keysForTesting(_ chord: KeyChord?) { keyFilter = chord; keySearch.chord = chord; reload() }
    func filterForTesting(changed: Bool, conflicts: Bool) {
        filters.setSelected(changed, forSegment: 0)
        filters.setSelected(conflicts, forSegment: 1)
        reload()
    }
    func toggleForTesting(_ area: Shortcuts.Area) { cards[area]?.setOpen(!(cards[area]?.isOpen ?? false)); remember(area, open: cards[area]?.isOpen ?? false) }
    func foldAllForTesting() { foldAll() }
    var openCardsForTesting: [String] { cards.filter { $0.value.isOpen }.map(\.key.rawValue).sorted() }
}

/// One area's card: a disclosure row with its name and count, and its commands under it while
/// open. Folding hides the rows; the card keeps its column.
@MainActor
final class ShortcutAreaCard {
    let view: NSView
    private let rows: [NSView]
    private let disclosure: DisclosureRow
    private(set) var isOpen: Bool
    var onToggle: ((Bool) -> Void)?

    init(area: Shortcuts.Area, rows: [NSView], open: Bool) {
        self.rows = rows
        isOpen = open
        disclosure = DisclosureRow(title: area.rawValue, count: rows.count, open: open)
        view = SettingsForm.section(nil, footer: nil, [disclosure] + rows, header: nil)
        disclosure.onToggle = { [weak self] in
            guard let self else { return }
            self.setOpen(!self.isOpen)
            self.onToggle?(self.isOpen)
        }
        apply()
    }

    func setOpen(_ open: Bool) {
        guard open != isOpen else { return }
        isOpen = open
        apply()
    }

    private func apply() {
        disclosure.isOpen = isOpen
        // The row's slot (its hairline with it) is what hides.
        for row in rows { (row.superview is NSStackView ? row : row.superview ?? row).isHidden = !isOpen }
    }
}

/// A card's heading row: chevron, name, count. The whole row toggles; so do Space and Return.
@MainActor
final class DisclosureRow: NSView {
    var onToggle: (() -> Void)?
    var isOpen: Bool { didSet { refresh() } }
    private let chevron = NSImageView()
    private let titleLabel: NSTextField
    private let countLabel: NSTextField

    init(title: String, count: Int, open: Bool) {
        isOpen = open
        titleLabel = NSTextField(labelWithString: title)
        countLabel = NSTextField(labelWithString: "\(count)")
        super.init(frame: .zero)
        titleLabel.font = DS.Text.body(.semibold)
        countLabel.font = DS.Text.caption()
        countLabel.textColor = .tertiaryLabelColor
        chevron.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        chevron.contentTintColor = .secondaryLabelColor
        let line = NSStackView(views: [titleLabel, countLabel, NSView(), chevron])
        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = DS.Spacing.s
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SettingsForm.rowInset),
            line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SettingsForm.rowInset),
            line.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: SettingsForm.rowMinHeight + 4),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.disclosureTriangle)
        setAccessibilityLabel("\(title), \(count) shortcuts")
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func refresh() {
        chevron.image = NSImage(systemSymbolName: isOpen ? "chevron.up" : "chevron.down", accessibilityDescription: nil)
        setAccessibilityValue(isOpen ? 1 : 0)
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onToggle?() }
    }
    override func accessibilityPerformPress() -> Bool { onToggle?(); return true }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 || event.keyCode == 36 { onToggle?() } else { super.keyDown(with: event) }
    }
}

/// Search by keys: click, press a chord, and the table shows what it's bound to (or that it's
/// free). Click again to stop searching by keys. Escape cancels while listening.
@MainActor
final class KeyCaptureButton: NSButton {
    var onChord: ((KeyChord?) -> Void)?
    var chord: KeyChord? { didSet { refresh() } }
    private var isListening = false { didSet { refresh() } }

    init() {
        super.init(frame: .zero)
        bezelStyle = .push
        controlSize = .regular
        target = self
        action = #selector(clicked)
        setContentHuggingPriority(.required, for: .horizontal)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func refresh() {
        if isListening {
            title = "Press keys\u{2026}"
            image = nil
        } else if let chord {
            title = chord.display
            image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)
            imagePosition = .imageTrailing
        } else {
            title = ""
            image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)
            imagePosition = .imageOnly
        }
        toolTip = chord == nil ? "Search by keys: press a shortcut to see what it does" : "Stop searching by keys"
        setAccessibilityLabel(isListening ? "Listening for keys" : chord.map { "Searching by \($0.display); press to clear" } ?? "Search by keys")
    }

    @objc private func clicked() {
        if chord != nil, !isListening {
            chord = nil
            onChord?(nil)
            return
        }
        isListening.toggle()
        if isListening { window?.makeFirstResponder(self) }
    }

    override var acceptsFirstResponder: Bool { true }
    override func resignFirstResponder() -> Bool {
        if isListening { isListening = false }
        return super.resignFirstResponder()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isListening, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        handle(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isListening else { return super.keyDown(with: event) }
        handle(event)
    }

    private func handle(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 53, modifiers.isEmpty { isListening = false; return }
        guard let pressed = KeyChord(event: event) else { NSSound.beep(); return }
        isListening = false
        chord = pressed
        onChord?(pressed)
    }
}

/// A button showing a command's chord; click it and press new keys. Escape cancels, Delete
/// removes the shortcut. It takes ⌘-keys before the menu bar does while it's listening.
@MainActor
final class ShortcutRecorder: NSButton {
    let commandID: String
    var onRecord: ((KeyChord?) -> Void)?
    private(set) var isRecording = false { didSet { refresh() } }
    private var hint: String?

    init(commandID: String) {
        self.commandID = commandID
        super.init(frame: .zero)
        bezelStyle = .push
        controlSize = .small
        target = self
        action = #selector(toggle)
        // One width, so the column of shortcuts lines up whatever each says.
        widthAnchor.constraint(equalToConstant: 120).isActive = true
        setContentHuggingPriority(.required, for: .horizontal)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func refresh() {
        let text = isRecording ? (hint ?? "Type a shortcut\u{2026}") : (Shortcuts.display(commandID).nonEmpty ?? "None")
        attributedTitle = NSAttributedString(string: text, attributes: [
            .font: isRecording ? DS.Text.caption() : DS.Text.body(),
            .foregroundColor: isRecording || Shortcuts.chord(commandID) == nil ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ])
        let title = Shortcuts.command(commandID)?.title ?? ""
        setAccessibilityLabel(isRecording ? "Recording a shortcut for \(title)" : "\(title) shortcut, \(Shortcuts.display(commandID).nonEmpty ?? "none")")
    }

    @objc private func toggle() {
        hint = nil
        isRecording.toggle()
        if isRecording { window?.makeFirstResponder(self) }
    }

    override var acceptsFirstResponder: Bool { true }
    override func resignFirstResponder() -> Bool {
        if isRecording { isRecording = false }
        return super.resignFirstResponder()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        handle(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return super.keyDown(with: event) }
        handle(event)
    }

    /// Tests: a key press while listening.
    func pressForTesting(_ event: NSEvent) { isRecording = true; handle(event) }

    private func handle(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 53, modifiers.isEmpty { isRecording = false; return }            // Escape
        if (event.keyCode == 51 || event.keyCode == 117), modifiers.isEmpty {                 // Delete
            isRecording = false
            onRecord?(nil)
            return
        }
        guard let chord = KeyChord(event: event), chord.isUsable else {
            hint = "Include \u{2318} or \u{2303}"
            refresh()
            NSSound.beep()
            return
        }
        isRecording = false
        onRecord?(chord)
    }
}

/// A target for a button that runs a closure.
@MainActor
final class ClosureTarget: NSObject {
    nonisolated(unsafe) static var key: UInt8 = 0
    private let body: () -> Void
    init(_ body: @escaping () -> Void) { self.body = body }
    @objc func run() { body() }
}
