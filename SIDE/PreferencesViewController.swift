import AppKit

/// The first real content behind Cmd+, — replaces the "no preferences yet" stub now that
/// there's something genuinely configurable: model providers. Generalized beyond the built-in
/// Anthropic entry to cover BYOK (OpenAI-compatible) and local (Ollama/LM Studio-shaped)
/// providers — all flowing through the same `ProviderDefinition`, `Add Provider…` sheet, and
/// `OpenAICompatibleChatProvider` adapter, with no special-casing of how a provider got here.
final class PreferencesViewController: NSViewController {
    private let providerPopup = NSPopUpButton()
    private let removeProviderButton = NSButton()

    private let keyField = NSSecureTextField()
    private let keyStatusLabel = NSTextField(labelWithString: "")
    private let modelPopup = NSPopUpButton()
    private let saveKeyButton = NSButton()
    private let removeKeyButton = NSButton()
    private let keyRow = NSStackView()
    private let baseURLLabel = NSTextField(labelWithString: "")

    private var registry: ProviderRegistryStore { .shared }
    private var selectedProviderId: String {
        providerPopup.selectedItem?.representedObject as? String ?? registry.activeProviderId
    }
    private var selectedProvider: ProviderDefinition? { registry.provider(for: selectedProviderId) }

    override func loadView() { view = NSView() }

    override func viewDidLoad() {
        super.viewDidLoad()

        let title = NSTextField(labelWithString: "Model Providers")
        title.font = DS.Text.heading(.semibold)

        providerPopup.target = self
        providerPopup.action = #selector(providerSelectionChanged)
        let addButton = NSButton(title: "Add Provider…", target: self, action: #selector(addProvider))
        addButton.bezelStyle = .rounded
        addButton.controlSize = .small
        removeProviderButton.title = "Remove"
        removeProviderButton.bezelStyle = .rounded
        removeProviderButton.controlSize = .small
        removeProviderButton.target = self
        removeProviderButton.action = #selector(removeProvider)
        let providerRow = NSStackView(views: [providerPopup, addButton, removeProviderButton])
        providerRow.orientation = .horizontal
        providerRow.spacing = DS.Spacing.m

        baseURLLabel.font = DS.Text.caption()
        baseURLLabel.textColor = .secondaryLabelColor

        keyField.placeholderString = "sk-…"
        keyField.font = DS.Text.code(12, weight: .regular)
        keyField.translatesAutoresizingMaskIntoConstraints = false
        keyField.widthAnchor.constraint(equalToConstant: 280).isActive = true

        saveKeyButton.title = "Save Key"
        saveKeyButton.bezelStyle = .rounded
        saveKeyButton.controlSize = .small
        saveKeyButton.target = self
        saveKeyButton.action = #selector(saveKey)
        removeKeyButton.title = "Remove"
        removeKeyButton.bezelStyle = .rounded
        removeKeyButton.controlSize = .small
        removeKeyButton.target = self
        removeKeyButton.action = #selector(removeKey)

        keyRow.addArrangedSubview(keyField)
        keyRow.addArrangedSubview(saveKeyButton)
        keyRow.addArrangedSubview(removeKeyButton)
        keyRow.orientation = .horizontal
        keyRow.spacing = DS.Spacing.m

        keyStatusLabel.font = DS.Text.caption()
        keyStatusLabel.textColor = .secondaryLabelColor

        let modelLabel = NSTextField(labelWithString: "Default model:")
        modelLabel.font = DS.Text.body()
        modelPopup.target = self
        modelPopup.action = #selector(modelChanged)
        let modelRow = NSStackView(views: [modelLabel, modelPopup])
        modelRow.orientation = .horizontal
        modelRow.spacing = DS.Spacing.m

        let stack = NSStackView(views: [title, providerRow, baseURLLabel, keyRow, keyStatusLabel, modelRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DS.Spacing.l
        stack.setCustomSpacing(DS.Spacing.section, after: title)
        stack.edgeInsets = NSEdgeInsets(top: DS.Spacing.section, left: DS.Spacing.section, bottom: DS.Spacing.section, right: DS.Spacing.section)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            view.widthAnchor.constraint(greaterThanOrEqualToConstant: 460),
        ])

        reloadProviderPopup()
        reloadForSelectedProvider()
    }

    private func reloadProviderPopup() {
        providerPopup.removeAllItems()
        for provider in registry.providers {
            let isActive = provider.id == registry.activeProviderId
            providerPopup.addItem(withTitle: isActive ? "\(provider.displayName) (active)" : provider.displayName)
            providerPopup.lastItem?.representedObject = provider.id
        }
        if let index = registry.providers.firstIndex(where: { $0.id == registry.activeProviderId }) {
            providerPopup.selectItem(at: index)
        }
    }

    /// Rebuilds the key/model section for whichever provider is currently selected in the
    /// popup — the same controls serve every provider, since they're all just a
    /// `ProviderDefinition` underneath, but Anthropic (the one provider that can never be
    /// removed) hides the Remove-provider button.
    private func reloadForSelectedProvider() {
        guard let provider = selectedProvider else { return }
        removeProviderButton.isHidden = provider.id == "anthropic"
        baseURLLabel.stringValue = provider.baseURL.absoluteString
        keyRow.isHidden = !provider.requiresAPIKey
        keyField.stringValue = ""
        reloadModelPopup(for: provider)
        refreshKeyStatus(for: provider)
    }

    private func reloadModelPopup(for provider: ProviderDefinition) {
        modelPopup.removeAllItems()
        for model in provider.models {
            modelPopup.addItem(withTitle: model.displayName)
            modelPopup.lastItem?.representedObject = model.id
        }
        if let index = provider.models.firstIndex(where: { $0.id == provider.defaultModelId }) {
            modelPopup.selectItem(at: index)
        }
    }

    private func refreshKeyStatus(for provider: ProviderDefinition) {
        guard provider.requiresAPIKey else {
            keyStatusLabel.stringValue = "No key required."
            return
        }
        // Checked in the same order resolveAdapter actually resolves a key in — env var before
        // Keychain — so opening Preferences doesn't itself trigger a Keychain ACL prompt that
        // having the env var set was specifically meant to avoid.
        if provider.id == "anthropic", ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]?.isEmpty == false {
            keyStatusLabel.stringValue = "No key saved — currently using ANTHROPIC_API_KEY from the environment."
        } else if KeychainStore.hasSecret(account: provider.id) {
            keyStatusLabel.stringValue = "A key is saved in your Keychain."
        } else {
            keyStatusLabel.stringValue = "No key set — Think can't reach \(provider.displayName) without one."
        }
    }

    @objc private func providerSelectionChanged() {
        registry.setActiveProvider(selectedProviderId)
        reloadProviderPopup()
        reloadForSelectedProvider()
    }

    @objc private func addProvider() {
        guard let window = view.window else { return }
        let form = AddProviderForm()
        let alert = NSAlert()
        alert.messageText = "Add Provider"
        alert.informativeText = "OpenAI-compatible only — covers OpenAI itself, and local servers like Ollama or LM Studio."
        alert.accessoryView = form.view
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = form.nameField
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn, let definition = form.makeDefinition() else { return }
            self.registry.addOrUpdate(definition)
            if !form.apiKey.isEmpty { KeychainStore.set(secret: form.apiKey, account: definition.id) }
            self.registry.setActiveProvider(definition.id)
            self.reloadProviderPopup()
            self.reloadForSelectedProvider()
        }
    }

    @objc private func removeProvider() {
        guard let provider = selectedProvider, provider.id != "anthropic" else { return }
        KeychainStore.delete(account: provider.id)
        registry.removeProvider(provider.id)
        reloadProviderPopup()
        reloadForSelectedProvider()
    }

    @objc private func saveKey() {
        guard let provider = selectedProvider else { return }
        let secret = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty else { return }
        if KeychainStore.set(secret: secret, account: provider.id) {
            keyField.stringValue = ""
        } else {
            keyStatusLabel.stringValue = "Couldn't write to the Keychain."
        }
        refreshKeyStatus(for: provider)
    }

    @objc private func removeKey() {
        guard let provider = selectedProvider else { return }
        KeychainStore.delete(account: provider.id)
        refreshKeyStatus(for: provider)
    }

    @objc private func modelChanged() {
        guard let provider = selectedProvider, let modelId = modelPopup.selectedItem?.representedObject as? String else { return }
        registry.setDefaultModel(providerId: provider.id, modelId: modelId)
    }
}

/// The accessory view for the "Add Provider" sheet — a plain field group, not a separate
/// `NSViewController`, since it only ever exists for the lifetime of one `NSAlert`.
@MainActor
private final class AddProviderForm {
    let view: NSView
    let nameField = NSTextField(string: "")
    private let baseURLField = NSTextField(string: "")
    private let modelIdField = NSTextField(string: "")
    private let apiKeyField = NSSecureTextField()
    private let requiresKeyCheckbox = NSButton(checkboxWithTitle: "Requires an API key", target: nil, action: nil)

    var apiKey: String { apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }

    init() {
        nameField.placeholderString = "Display name (e.g. \"OpenAI\" or \"Local Llama\")"
        baseURLField.placeholderString = "Base URL, including /v1 (e.g. https://api.openai.com/v1)"
        modelIdField.placeholderString = "Model id (e.g. gpt-4o or llama3.1)"
        apiKeyField.placeholderString = "API key (leave blank for a local server)"
        requiresKeyCheckbox.state = .on

        for field in [nameField, baseURLField, modelIdField, apiKeyField] as [NSControl] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 320).isActive = true
        }

        let stack = NSStackView(views: [nameField, baseURLField, modelIdField, requiresKeyCheckbox, apiKeyField])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DS.Spacing.m
        // NSAlert sizes its sheet from accessoryView.frame *before* Auto Layout has a chance to
        // resolve constraints — an accessory view with translatesAutoresizingMaskIntoConstraints
        // = false and no explicit frame renders at {0,0} and gets clipped/overlapped by the
        // alert's own text. An explicit frame here (kept in sync with the width constraints
        // above) is what the working `Rename Track` accessory field elsewhere in this codebase
        // relies on too, just via a plain NSRect init instead of Auto Layout.
        stack.frame = NSRect(x: 0, y: 0, width: 340, height: 180)
        view = stack
    }

    /// `nil` if the form's required fields aren't filled in — the caller shows nothing rather
    /// than adding a half-configured provider that would just fail on first use.
    func makeDefinition() -> ProviderDefinition? {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let urlText = baseURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelId = modelIdField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !modelId.isEmpty, let baseURL = URL(string: urlText), baseURL.scheme != nil else { return nil }
        let requiresKey = requiresKeyCheckbox.state == .on
        // Slug the display name into a stable id — providers are keyed by id everywhere
        // (Keychain account, track/session `providerId`), so this must be filesystem/Keychain
        // safe and stay constant across saves.
        let id = "custom-" + name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.reduce(into: "") { $0.append($1) }
        return ProviderDefinition(
            id: id, displayName: name, kind: requiresKey ? .byokOpenAICompatible : .local,
            baseURL: baseURL, requiresAPIKey: requiresKey,
            models: [ProviderModel(id: modelId, displayName: modelId, contextWindowTokens: 128_000)],
            defaultModelId: modelId
        )
    }
}

/// The Preferences window's shell. Preferences was a single flat pane while providers were the
/// only thing configurable; usage accounting is a second, unrelated concern, so the two get
/// their own tabs rather than one scrolling wall.
final class PreferencesTabViewController: NSTabViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        tabStyle = .toolbar

        let general = NSTabViewItem(viewController: GeneralPreferencesViewController())
        general.label = "General"
        general.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "General")
        addTabViewItem(general)

        let providers = NSTabViewItem(viewController: PreferencesViewController())
        providers.label = "Providers"
        providers.image = NSImage(systemSymbolName: "cpu", accessibilityDescription: "Providers")
        addTabViewItem(providers)

        let usage = NSTabViewItem(viewController: UsageViewController())
        usage.label = "Usage"
        usage.image = NSImage(systemSymbolName: "chart.bar", accessibilityDescription: "Usage")
        addTabViewItem(usage)

        let appearance = NSTabViewItem(viewController: AppearanceViewController())
        appearance.label = "Appearance"
        appearance.image = NSImage(systemSymbolName: "textformat.size", accessibilityDescription: "Appearance")
        addTabViewItem(appearance)

        let history = NSTabViewItem(viewController: HistoryViewController())
        history.label = "History"
        history.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: "History")
        addTabViewItem(history)
    }
}

/// General → Stages: which stages the stage control shows (Direction 02 §3.1). Unpinning hides a
/// view, never a capability — every stage stays on ⌘⌥1–4, Navigate and the palette.
final class GeneralPreferencesViewController: NSViewController {
    private var boxes: [NSButton] = []
    private var observer: NSObjectProtocol?
    private var sideObserver: NSObjectProtocol?

    override func loadView() {
        let title = NSTextField(labelWithString: "Stages")
        title.font = DS.Text.heading()
        let detail = NSTextField(wrappingLabelWithString: "Pinned stages appear in the stage control. Unpinned ones stay reachable from the Navigate menu, ⌘⌥1–4 and the palette, and show up on their own when they need you.")
        detail.font = DS.Text.caption()
        detail.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DS.Spacing.m
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        for stage in StagePins.pinnable {
            let box = NSButton(checkboxWithTitle: stage.rawValue, target: self, action: #selector(toggled(_:)))
            box.identifier = NSUserInterfaceItemIdentifier(stage.rawValue)
            boxes.append(box)
            stack.addArrangedSubview(box)
        }
        detail.widthAnchor.constraint(equalToConstant: 420).isActive = true

        let explorerTitle = NSTextField(labelWithString: "File explorer")
        explorerTitle.font = DS.Text.heading()
        stack.setCustomSpacing(DS.Spacing.xl, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(explorerTitle)
        let sidePopup = NSPopUpButton()
        for side in FileExplorer.Side.allCases { sidePopup.addItem(withTitle: side.title) }
        sidePopup.selectItem(withTitle: FileExplorer.Side.preferred.title)
        sidePopup.target = self
        sidePopup.action = #selector(explorerSideChanged(_:))
        let sideRow = NSStackView(views: [NSTextField(labelWithString: "Opens on the"), sidePopup, NSTextField(labelWithString: "side of the window")])
        sideRow.orientation = .horizontal
        sideRow.spacing = DS.Spacing.s
        stack.addArrangedSubview(sideRow)
        explorerPopup = sidePopup
        view = stack
        refresh()
        observer = NotificationCenter.default.addObserver(forName: StagePins.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        sideObserver = NotificationCenter.default.addObserver(forName: FileExplorer.Side.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func refresh() {
        explorerPopup?.selectItem(withTitle: FileExplorer.Side.preferred.title)
        let pinned = StagePins.pinned
        for box in boxes {
            let isPinned = pinned.contains { $0.rawValue == box.identifier?.rawValue }
            box.state = isPinned ? .on : .off
            // The last pinned stage can't be unpinned — the control would be empty.
            box.isEnabled = !(isPinned && pinned.count == 1)
        }
    }

    private var explorerPopup: NSPopUpButton?

    @objc private func explorerSideChanged(_ sender: NSPopUpButton) {
        FileExplorer.Side.preferred = FileExplorer.Side.allCases[max(0, sender.indexOfSelectedItem)]
    }

    @objc private func toggled(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let stage = ShellViewController.Stage(rawValue: raw) else { return }
        StagePins.toggle(stage)
    }
}
