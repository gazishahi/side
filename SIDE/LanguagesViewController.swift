import AppKit

/// Settings → Languages (SIDE_RFC_IDE_ESSENTIALS.md, L4): each language Side knows, the server
/// it uses (a preset, one of its alternatives, a command of your own, or none), whether that
/// server is installed (with Install when it isn't), its settings and format on save; and
/// languages you add yourself.
@MainActor
final class LanguagesViewController: NSViewController, NSSearchFieldDelegate {
    private let search = NSSearchField()
    private var query = ""
    /// Whether each server's binary was found, looked up off the main thread (a login shell each).
    private var installed: [String: Bool] = [:]
    /// Whether each debug adapter was found (by preset id).
    private var debuggersInstalled: [String: Bool] = [:]
    private var installPopover: NSPopover?

    override func loadView() { view = NSView() }

    override func viewDidLoad() {
        super.viewDidLoad()
        search.placeholderString = "Search languages"
        search.delegate = self
        search.setAccessibilityLabel("Search languages")
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: LanguageSettings.didChangeNotification, object: nil)
        rebuild()
        checkInstalled()
        checkDebuggers()
    }

    /// Each debug adapter, found or not, off the main thread.
    private func checkDebuggers() {
        Task.detached(priority: .utility) { [weak self] in
            var found: [String: Bool] = [:]
            for preset in DebugAdapters.presets { found[preset.id] = DebugAdapters.isInstalled(preset) }
            await MainActor.run { [weak self] in
                guard let self, found != self.debuggersInstalled else { return }
                self.debuggersInstalled = found
                self.rebuild()
            }
        }
    }

    private func debuggerRow(_ preset: DebugAdapterPreset) -> NSView {
        let languages = preset.languages.compactMap { id in LanguageSettings.presets.first { $0.id == id }?.name }.joined(separator: ", ")
        var status: NSView?
        switch debuggersInstalled[preset.id] {
        case true?:
            status = SettingsForm.badge("Installed", color: .systemGreen)
        case false?:
            if preset.install != nil {
                let install = SettingsForm.button("Install", self, #selector(installDebuggerTapped(_:)))
                install.identifier = NSUserInterfaceItemIdentifier(preset.id)
                install.toolTip = preset.install?.command
                status = install
            } else {
                status = SettingsForm.badge("Not found", color: .systemOrange)
            }
        case nil:
            status = nil
        }
        let line = NSStackView(views: [Self.statusColumn(status)])
        line.orientation = .horizontal
        return SettingsForm.row(preset.name, detail: "\(languages)  \u{00B7}  \(preset.command)\n\(preset.note)", line)
    }

    @objc private func installDebuggerTapped(_ sender: NSButton) {
        guard let preset = DebugAdapters.preset(sender.identifier?.rawValue ?? "") else { return }
        let content = LSPInstallPopoverViewController(debugger: preset) { [weak self] in
            DebugAdapters.invalidate(preset)
            self?.debuggersInstalled[preset.id] = nil
            self?.checkDebuggers()
        }
        let popover = NSPopover()
        popover.contentViewController = content
        popover.behavior = .transient
        installPopover = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    @objc private func settingsChanged() {
        rebuild()
        checkInstalled()
    }

    func controlTextDidChange(_ obj: Notification) {
        query = search.stringValue.trimmingCharacters(in: .whitespaces)
        rebuild()
        view.window?.makeFirstResponder(search)
        search.currentEditor()?.selectedRange = NSRange(location: search.stringValue.count, length: 0)
    }

    /// The binary each language uses now, found or not (cached after the first look).
    private func checkInstalled() {
        let binaries = Set(LanguageSettings.presets.compactMap { LanguageSettings.shared.entry(forExtension: $0.extensions[0].ext) }.map { ($0.binaryName, $0.installFormula) }.map { "\($0.0)\t\($0.1 ?? "")" })
            .union(LanguageSettings.shared.customLanguages.compactMap { $0.command.first })
        Task.detached(priority: .utility) { [weak self] in
            // A login shell each: side by side, not one after another.
            let keys = Array(binaries)
            let results = LockedResults(count: keys.count)
            DispatchQueue.concurrentPerform(iterations: keys.count) { index in
                let parts = keys[index].split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                results.set(index, (parts[0], LanguageServerRegistry.resolveExecutable(named: parts[0], installFormula: parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil) != nil))
            }
            let found = Dictionary(results.values.compactMap { $0 }, uniquingKeysWith: { a, _ in a })
            await MainActor.run { [weak self] in
                guard let self, found != self.installed else { return }
                self.installed = found
                self.rebuild()
            }
        }
    }

    static func matches(_ language: LanguagePreset, _ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return language.name.localizedCaseInsensitiveContains(query)
            || language.extensions.contains { $0.ext.localizedCaseInsensitiveContains(query) }
            || language.servers.contains { $0.name.localizedCaseInsensitiveContains(query) || $0.binary.localizedCaseInsensitiveContains(query) }
    }

    private func rebuild() {
        var views: [NSView] = [SettingsSplitViewController.hero(.languages), search]
        let languages = LanguageSettings.presets.filter { Self.matches($0, query) }
        if !languages.isEmpty {
            views.append(SettingsForm.section("Languages", footer: "A language's server gives it completion, problems, hover and go to definition. Side uses the server when it's installed; Install runs its own installer in your shell, so the server works in your terminal and other editors too.",
                                              languages.map(row)))
        }
        let custom = LanguageSettings.shared.customLanguages.filter { language in
            query.isEmpty || language.name.localizedCaseInsensitiveContains(query) || language.extensions.contains { $0.localizedCaseInsensitiveContains(query) }
        }
        var customRows = custom.map(customRow)
        customRows.append(SettingsForm.row("Add a language Side doesn't know", detail: "Its file extensions and the command that runs its server.",
                                           SettingsForm.button("Add Language\u{2026}", self, #selector(addLanguage))))
        views.append(SettingsForm.section("Your languages", customRows))
        let debuggers = DebugAdapters.presets.filter { preset in
            query.isEmpty || preset.name.localizedCaseInsensitiveContains(query) || preset.languages.contains { id in
                LanguageSettings.presets.first { $0.id == id }.map { Self.matches($0, query) } ?? false
            }
        }
        if !debuggers.isEmpty {
            views.append(SettingsForm.section("Debuggers", footer: "Make's debugger (Debug \u{2192} Start Debugging) uses these. Side installs js-debug and debugpy into its own folder, so they don't change your Node or Python.",
                                              debuggers.map(debuggerRow)))
        }
        if languages.isEmpty && custom.isEmpty && !query.isEmpty {
            views.insert(SettingsForm.footnote("No language matches \u{201C}\(query)\u{201D}."), at: 2)
        }
        SettingsForm.install(SettingsForm.page(views, maxHeight: 720), in: view)
    }

    // MARK: A language

    private func row(_ language: LanguagePreset) -> NSView {
        let choice = LanguageSettings.shared.choice(language.id)
        let enabled = choice.enabled ?? true
        let entry = LanguageSettings.shared.entry(forExtension: language.extensions[0].ext)
        let extensions = language.extensions.map { ".\($0.ext)" }.joined(separator: " ")

        // The server: each preset, your own command, or none.
        let popup = NSPopUpButton()
        for server in language.servers {
            popup.addItem(withTitle: server.name)
            popup.lastItem?.representedObject = server.id
        }
        popup.addItem(withTitle: "Custom Command\u{2026}")
        popup.lastItem?.representedObject = "custom"
        popup.menu?.addItem(.separator())
        popup.addItem(withTitle: "None")
        popup.lastItem?.representedObject = "none"
        if !enabled { popup.selectItem(withTitle: "None") }
        else if choice.customCommand != nil { popup.selectItem(withTitle: "Custom Command\u{2026}") }
        else if let index = language.servers.firstIndex(where: { $0.id == choice.serverID }) { popup.selectItem(at: index) }
        else { popup.selectItem(at: 0) }
        popup.target = self
        popup.action = #selector(serverChosen(_:))
        popup.identifier = NSUserInterfaceItemIdentifier(language.id)
        popup.setAccessibilityLabel("\(language.name) language server")
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.widthAnchor.constraint(equalToConstant: 200).isActive = true

        var accessories: [NSView] = []
        var detail = extensions
        if let entry, enabled {
            let command = ([entry.binaryName] + entry.arguments).joined(separator: " ")
            detail += "  \u{00B7}  \(command)"
            switch installed[entry.binaryName] {
            case true?:
                accessories.append(SettingsForm.badge("Installed", color: .systemGreen))
            case false?:
                if entry.install != nil {
                    let install = SettingsForm.button("Install", self, #selector(installTapped(_:)))
                    install.identifier = NSUserInterfaceItemIdentifier(language.id)
                    install.toolTip = entry.install?.command
                    accessories.append(install)
                } else {
                    accessories.append(SettingsForm.badge("Not found", color: .systemOrange))
                }
            case nil:
                break
            }
        }
        // One column for the status, whatever it holds, so the menus line up.
        let status = Self.statusColumn(accessories.first)
        accessories = [status]
        let more = NSButton(image: NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "\(language.name) options") ?? NSImage(), target: self, action: #selector(optionsTapped(_:)))
        more.isBordered = false
        more.identifier = NSUserInterfaceItemIdentifier(language.id)
        more.toolTip = "Settings, format on save, your own command"
        more.translatesAutoresizingMaskIntoConstraints = false
        more.widthAnchor.constraint(equalToConstant: 22).isActive = true
        accessories += [popup, more]
        let line = NSStackView(views: accessories)
        line.orientation = .horizontal
        line.spacing = DS.Spacing.m
        line.setHuggingPriority(.required, for: .horizontal)
        return SettingsForm.row(language.name, detail: detail, line, titleColor: enabled ? .labelColor : .secondaryLabelColor)
    }

    /// A fixed-width cell for a badge or an Install button, centered.
    static func statusColumn(_ content: NSView?) -> NSView {
        let column = NSView()
        column.translatesAutoresizingMaskIntoConstraints = false
        column.widthAnchor.constraint(equalToConstant: 92).isActive = true
        column.heightAnchor.constraint(equalToConstant: 24).isActive = true
        if let content {
            content.translatesAutoresizingMaskIntoConstraints = false
            column.addSubview(content)
            if let button = content as? NSButton { button.controlSize = .small; button.setContentHuggingPriority(.required, for: .horizontal) }
            NSLayoutConstraint.activate([content.centerXAnchor.constraint(equalTo: column.centerXAnchor), content.centerYAnchor.constraint(equalTo: column.centerYAnchor)])
        }
        return column
    }

    private func preset(_ sender: NSView) -> LanguagePreset? {
        LanguageSettings.presets.first { $0.id == sender.identifier?.rawValue }
    }

    @objc private func serverChosen(_ sender: NSPopUpButton) {
        guard let language = preset(sender), let picked = sender.selectedItem?.representedObject as? String else { return }
        var choice = LanguageSettings.shared.choice(language.id)
        switch picked {
        case "none":
            choice.enabled = false
        case "custom":
            choice.enabled = nil
            showOptions(language, focusingCommand: true)
            return
        default:
            choice.enabled = nil
            choice.customCommand = nil
            choice.serverID = picked == language.servers[0].id ? nil : picked
        }
        LanguageSettings.shared.setChoice(choice, for: language.id)
    }

    @objc private func installTapped(_ sender: NSButton) {
        guard let language = preset(sender), let entry = LanguageSettings.shared.entry(forExtension: language.extensions[0].ext) else { return }
        let content = LSPInstallPopoverViewController(entry: entry) { [weak self] in
            LanguageServerRegistry.invalidateResolution(for: entry.binaryName)
            self?.installed[entry.binaryName] = nil
            self?.checkInstalled()
            // Open files of this language get their server now.
            NotificationCenter.default.post(name: LanguageSettings.didChangeNotification, object: nil)
        }
        let popover = NSPopover()
        popover.contentViewController = content
        popover.behavior = .transient
        installPopover = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    @objc private func optionsTapped(_ sender: NSButton) {
        guard let language = preset(sender) else { return }
        showOptions(language, focusingCommand: false)
    }

    /// A sheet: your own command (instead of the preset), the settings the server reads, and
    /// format on save.
    private func showOptions(_ language: LanguagePreset, focusingCommand: Bool) {
        guard let window = view.window else { return }
        var choice = LanguageSettings.shared.choice(language.id)
        let command = NSTextField(string: choice.customCommand?.joined(separator: " ") ?? "")
        command.placeholderString = ([language.servers[0].binary] + language.servers[0].arguments).joined(separator: " ")
        command.setAccessibilityLabel("Command")
        let settings = NSTextView()
        settings.isRichText = false
        settings.font = DS.Text.code(12, weight: .regular)
        settings.string = choice.settingsJSON ?? ""
        settings.isAutomaticQuoteSubstitutionEnabled = false
        settings.setAccessibilityLabel("Server settings, JSON")
        let settingsScroll = NSScrollView()
        settingsScroll.documentView = settings
        settingsScroll.hasVerticalScroller = true
        settingsScroll.borderType = .bezelBorder
        settings.autoresizingMask = [.width]
        let format = NSPopUpButton()
        format.addItems(withTitles: ["As the project has it", "On", "Off"])
        format.selectItem(at: choice.formatOnSave == nil ? 0 : (choice.formatOnSave == true ? 1 : 2))

        func label(_ text: String) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            field.font = DS.Text.caption(.medium)
            return field
        }
        let stack = NSStackView(views: [
            label("Command (empty for the preset)"), command,
            label("Settings the server reads (JSON)"), settingsScroll,
            label("Format on save"), format,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.frame = NSRect(x: 0, y: 0, width: 380, height: 280)
        for view in [command, settingsScroll] { view.widthAnchor.constraint(equalToConstant: 380).isActive = true }
        settingsScroll.heightAnchor.constraint(equalToConstant: 120).isActive = true

        let alert = NSAlert()
        alert.messageText = language.name
        alert.informativeText = "The first word of the command is the program (a name on your PATH, or a path); the rest are its arguments. Settings answer the server's workspace/configuration, e.g. {\"yaml\": {\"format\": {\"enable\": true}}}."
        alert.accessoryView = stack
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = focusingCommand ? command : nil
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { self?.rebuild(); return }
            let words = command.stringValue.split(separator: " ").map(String.init)
            choice.customCommand = words.isEmpty ? nil : words
            if choice.customCommand != nil { choice.enabled = nil; choice.serverID = nil }
            let json = settings.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !json.isEmpty, (try? JSONSerialization.jsonObject(with: Data(json.utf8))) == nil {
                NSSound.beep()
            } else {
                choice.settingsJSON = json.isEmpty ? nil : json
            }
            choice.formatOnSave = [nil, true, false][format.indexOfSelectedItem]
            LanguageSettings.shared.setChoice(choice, for: language.id)
        }
    }

    // MARK: Your languages

    private func customRow(_ language: CustomLanguage) -> NSView {
        let remove = SettingsForm.button("Remove", self, #selector(removeCustom(_:)), destructive: true)
        remove.identifier = NSUserInterfaceItemIdentifier(language.id)
        let binary = language.command.first ?? ""
        var accessories: [NSView] = []
        if let found = installed[binary] {
            accessories.append(found ? SettingsForm.badge("Installed", color: .systemGreen) : SettingsForm.badge("Not found", color: .systemOrange))
        }
        accessories.append(remove)
        let line = NSStackView(views: accessories)
        line.orientation = .horizontal
        line.spacing = DS.Spacing.m
        return SettingsForm.row(language.name, detail: language.extensions.map { ".\($0)" }.joined(separator: " ") + "  \u{00B7}  " + language.command.joined(separator: " "), line)
    }

    @objc private func removeCustom(_ sender: NSButton) {
        LanguageSettings.shared.setCustomLanguages(LanguageSettings.shared.customLanguages.filter { $0.id != sender.identifier?.rawValue })
    }

    @objc private func addLanguage() {
        guard let window = view.window else { return }
        let name = NSTextField(string: ""), extensions = NSTextField(string: ""), languageId = NSTextField(string: ""), command = NSTextField(string: "")
        name.placeholderString = "Zig"
        extensions.placeholderString = "zig zon"
        languageId.placeholderString = "zig"
        command.placeholderString = "zls"
        let stack = NSStackView(views: [name, extensions, languageId, command])
        for (field, label) in [(name, "Name"), (extensions, "File extensions"), (languageId, "Language id"), (command, "Command")] {
            field.setAccessibilityLabel(label)
            field.widthAnchor.constraint(equalToConstant: 320).isActive = true
        }
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: 120)
        let alert = NSAlert()
        alert.messageText = "Add a Language"
        alert.informativeText = "Its name, its file extensions (separated by spaces), the language id its server expects, and the command that starts the server."
        alert.accessoryView = stack
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = name
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let exts = extensions.stringValue.split(whereSeparator: { $0 == " " || $0 == "," }).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased() }.filter { !$0.isEmpty }
            let words = command.stringValue.split(separator: " ").map(String.init)
            let title = name.stringValue.trimmingCharacters(in: .whitespaces)
            guard !exts.isEmpty, !words.isEmpty, !title.isEmpty else { return NSSound.beep() }
            let language = CustomLanguage(id: "custom.\(UUID().uuidString)", name: title, extensions: exts,
                                          languageId: languageId.stringValue.isEmpty ? title.lowercased() : languageId.stringValue, command: words)
            LanguageSettings.shared.setCustomLanguages(LanguageSettings.shared.customLanguages + [language])
        }
    }
}

/// Results written from `concurrentPerform`'s threads.
private final class LockedResults: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(String, Bool)?]
    init(count: Int) { storage = Array(repeating: nil, count: count) }
    func set(_ index: Int, _ value: (String, Bool)) { lock.withLock { storage[index] = value } }
    var values: [(String, Bool)?] { lock.withLock { storage } }
}
