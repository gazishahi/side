import AppKit

/// Settings → Shortcuts: every shortcut, by area, searchable; click one and press new keys to
/// rebind it. A chord another command has is named, and taking it waits for a yes.
@MainActor
final class ShortcutsViewController: NSViewController, NSSearchFieldDelegate {
    private let search = NSSearchField()
    private var query = ""

    override func loadView() { view = NSView() }

    override func viewDidLoad() {
        super.viewDidLoad()
        search.placeholderString = "Search shortcuts"
        search.delegate = self
        search.setAccessibilityLabel("Search shortcuts")
        NotificationCenter.default.addObserver(self, selector: #selector(shortcutsChanged), name: Shortcuts.didChangeNotification, object: nil)
        rebuild()
    }

    @objc private func shortcutsChanged() { rebuild() }

    func controlTextDidChange(_ obj: Notification) {
        query = search.stringValue.trimmingCharacters(in: .whitespaces)
        rebuild()
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

    private func rebuild() {
        let keymap = SettingsForm.popup(Shortcuts.Keymap.allCases.map(\.title), selected: Shortcuts.Keymap.allCases.firstIndex(of: Shortcuts.keymap) ?? 0, self, #selector(keymapChosen(_:)))
        keymap.setAccessibilityLabel("Keymap")
        var views: [NSView] = [SettingsSplitViewController.hero(.shortcuts),
                               SettingsForm.section(footer: "Each keymap sets the defaults below; a shortcut you change stays yours whichever you pick.",
                                                    [SettingsForm.row("Keymap", detail: "Whose keys: Xcode's, VS Code's or JetBrains'.", keymap)]),
                               search]
        var shown = 0
        for area in Shortcuts.Area.allCases {
            let commands = Shortcuts.all.filter { $0.area == area && Self.matches($0, query) }
            guard !commands.isEmpty else { continue }
            shown += commands.count
            views.append(SettingsForm.section(area.rawValue, commands.map(row)))
        }
        if shown == 0 { views.append(SettingsForm.footnote("No shortcut matches \u{201C}\(query)\u{201D}.")) }
        let reset = SettingsForm.button("Reset All to Defaults", self, #selector(resetAll))
        reset.isEnabled = Shortcuts.all.contains { Shortcuts.isChanged($0.id) }
        views.append(SettingsForm.section(footer: "Shortcuts marked in a lighter color work inside their view (a list, a text field) and can't be changed.", [SettingsForm.row("All shortcuts", reset)]))
        SettingsForm.install(SettingsForm.page(views, maxHeight: 700), in: view)
    }

    private func row(_ command: Shortcuts.Command) -> NSView {
        if command.isFixed {
            let label = NSTextField(labelWithString: Shortcuts.display(command.id))
            label.font = DS.Text.body()
            label.textColor = .tertiaryLabelColor
            return SettingsForm.row(command.title, label, titleColor: .secondaryLabelColor)
        }
        let recorder = ShortcutRecorder(commandID: command.id)
        recorder.onRecord = { [weak self] chord in self?.record(chord, for: command) }
        var accessories: [NSView] = []
        if Shortcuts.isChanged(command.id) {
            let reset = NSButton(title: "", target: nil, action: nil)
            reset.isBordered = false
            reset.attributedTitle = NSAttributedString(string: "Reset", attributes: [.font: DS.Text.caption(.medium), .foregroundColor: NSColor.secondaryLabelColor])
            reset.setAccessibilityLabel("Reset \(command.title) to \(Shortcuts.defaultChord(command.id)?.display ?? "none")")
            reset.toolTip = "Back to \(Shortcuts.defaultChord(command.id)?.display ?? "none")"
            let target = ClosureTarget { Shortcuts.reset(command.id) }
            reset.target = target
            reset.action = #selector(ClosureTarget.run)
            objc_setAssociatedObject(reset, &ClosureTarget.key, target, .OBJC_ASSOCIATION_RETAIN)
            accessories.append(reset)
        }
        accessories.append(recorder)
        let line = NSStackView(views: accessories)
        line.orientation = .horizontal
        line.spacing = DS.Spacing.l
        line.setHuggingPriority(.required, for: .horizontal)
        return SettingsForm.row(command.title, line)
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
