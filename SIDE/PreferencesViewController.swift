import AppKit
import Heron

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

    private let urlLabel = NSTextField(labelWithString: "")
    private var removeProviderRow: NSView?

    override func viewDidLoad() {
        super.viewDidLoad()
        providerPopup.target = self
        providerPopup.action = #selector(providerSelectionChanged)
        removeProviderButton.title = "Remove Provider"
        removeProviderButton.bezelStyle = .rounded
        removeProviderButton.hasDestructiveAction = true
        removeProviderButton.target = self
        removeProviderButton.action = #selector(removeProvider)
        urlLabel.font = DS.Text.caption()
        urlLabel.textColor = .secondaryLabelColor
        urlLabel.lineBreakMode = .byTruncatingMiddle
        urlLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true

        keyField.placeholderString = "sk-\u{2026}"
        keyField.font = DS.Text.code(12, weight: .regular)
        keyField.translatesAutoresizingMaskIntoConstraints = false
        keyField.widthAnchor.constraint(equalToConstant: 200).isActive = true
        saveKeyButton.title = "Save"
        saveKeyButton.bezelStyle = .rounded
        saveKeyButton.target = self
        saveKeyButton.action = #selector(saveKey)
        removeKeyButton.title = "Remove"
        removeKeyButton.bezelStyle = .rounded
        removeKeyButton.target = self
        removeKeyButton.action = #selector(removeKey)
        keyRow.setViews([keyField, saveKeyButton, removeKeyButton], in: .leading)
        keyRow.orientation = .horizontal
        keyRow.spacing = DS.Spacing.s
        keyStatusLabel.font = DS.Text.caption()
        keyStatusLabel.textColor = .secondaryLabelColor
        keyStatusLabel.preferredMaxLayoutWidth = SettingsForm.contentWidth - 60
        modelPopup.target = self
        modelPopup.action = #selector(modelChanged)

        let keyStack = NSStackView(views: [keyRow, keyStatusLabel])
        keyStack.orientation = .vertical
        keyStack.alignment = .leading
        keyStack.spacing = DS.Spacing.s
        let removeRow = SettingsForm.row("Remove this provider", detail: "Its saved key is deleted from your Keychain.", removeProviderButton)
        removeProviderRow = removeRow
        let page = SettingsForm.page([
            SettingsSplitViewController.hero(.providers),
            SettingsForm.section("Model provider", footer: "Heron, Side's own agent, talks to the provider chosen here. Outside agents use their own accounts (Agents).", [
                SettingsForm.row("Provider", providerPopup),
                SettingsForm.row("Endpoint", urlLabel),
                SettingsForm.row("Default model", modelPopup),
            ]),
            SettingsForm.section("API key", [SettingsForm.content(keyStack)]),
            SettingsForm.section([
                SettingsForm.row("Add a provider", detail: "Any OpenAI-compatible endpoint: OpenAI, or a local server like Ollama or LM Studio.",
                                 SettingsForm.button("Add Provider\u{2026}", self, #selector(addProvider))),
                removeRow,
            ]),
        ])
        SettingsForm.install(page, in: view)
        reloadProviderPopup()
        reloadForSelectedProvider()
    }

    private func reloadProviderPopup() {
        providerPopup.removeAllItems()
        for provider in registry.providers {
            let isActive = provider.id == registry.activeProviderId
            providerPopup.addItem(withTitle: provider.displayName)
            _ = isActive
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
        (removeProviderRow?.superview ?? removeProviderRow)?.isHidden = provider.id == "anthropic"
        urlLabel.stringValue = provider.baseURL.absoluteString
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
        removeKeyButton.isHidden = !KeychainStore.hasSecret(account: provider.id)
        guard provider.requiresAPIKey else {
            keyStatusLabel.stringValue = "This provider doesn't need a key."
            return
        }
        // Checked in the same order resolveAdapter actually resolves a key in — env var before
        // Keychain — so opening Preferences doesn't itself trigger a Keychain ACL prompt that
        // having the env var set was specifically meant to avoid.
        if provider.id == "anthropic", ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]?.isEmpty == false {
            keyStatusLabel.stringValue = "No key saved. Using ANTHROPIC_API_KEY from the environment."
        } else if KeychainStore.hasSecret(account: provider.id) {
            keyStatusLabel.stringValue = "A key is saved in your Keychain."
        } else {
            keyStatusLabel.stringValue = "No key set. Think can't reach \(provider.displayName) without one."
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
        alert.informativeText = "OpenAI-compatible only: covers OpenAI itself and local servers like Ollama or LM Studio."
        alert.accessoryView = form.view
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = form.nameField
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn, let definition = form.makeDefinition() else { return }
            self.registry.addOrUpdate(definition)
            if !form.apiKey.isEmpty { KeychainStore.set(secret: form.apiKey, account: definition.id) }
            self.registry.refreshModels(providerId: definition.id, apiKey: form.apiKey.isEmpty ? nil : form.apiKey, force: true) { [weak self] changed in
                if changed { self?.reloadForSelectedProvider() }
            }
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
            // A new key: ask the provider for its current models now.
            registry.refreshModels(providerId: provider.id, apiKey: secret, force: true) { [weak self] changed in
                if changed { self?.reloadForSelectedProvider() }
            }
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
/// General → Stages: which stages the stage control shows (Direction 02 §3.1). Unpinning hides a
/// view, never a capability — every stage stays on ⌘⌥1–4, Navigate and the palette.
final class GeneralPreferencesViewController: NSViewController {
    private var switches: [NSSwitch] = []
    private var observer: NSObjectProtocol?
    private var sideObserver: NSObjectProtocol?

    override func loadView() {
        view = NSView()
        var stageRows: [NSView] = []
        for stage in StagePins.pinnable {
            let toggle = SettingsForm.toggle(false, self, #selector(toggled(_:)))
            toggle.identifier = NSUserInterfaceItemIdentifier(stage.rawValue)
            toggle.setAccessibilityLabel("Pin \(stage.rawValue)")
            switches.append(toggle)
            stageRows.append(SettingsForm.row(stage.rawValue, toggle))
        }
        let sidePopup = SettingsForm.popup(FileExplorer.Side.allCases.map(\.title), selected: 0, self, #selector(explorerSideChanged(_:)))
        explorerPopup = sidePopup
        let page = SettingsForm.page([
            SettingsSplitViewController.hero(.general),
            SettingsForm.section("Stages", footer: "Pinned stages appear in the stage control. Unpinned ones stay on the Navigate menu, \u{2318}\u{2325}1\u{2013}4 and the palette, and show up on their own when they need you.", stageRows),
            SettingsForm.section("Make", [SettingsForm.row("File explorer side", sidePopup)]),
            SettingsForm.section("Updates", [
                SettingsForm.row("Check for updates automatically", detail: "Side \(Self.versionText). Updates are signed, and verified before they install.",
                                 SettingsForm.toggle(Updates.shared.checksAutomatically, self, #selector(autoUpdateToggled(_:)))),
                SettingsForm.row("Check now", SettingsForm.button("Check for Updates\u{2026}", Updates.shared, #selector(Updates.checkForUpdates(_:)))),
            ]),
            SettingsForm.section([
                SettingsForm.row("Library", detail: "Instruction files, saved prompts and templates, MCP servers, skills, and storage for the frontmost project.",
                                 SettingsForm.button("Open Library\u{2026}", self, #selector(openLibrary))),
            ]),
        ])
        SettingsForm.install(page, in: view)
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
        for toggle in switches {
            let isPinned = pinned.contains { $0.rawValue == toggle.identifier?.rawValue }
            toggle.state = isPinned ? .on : .off
            // The last pinned stage can't be unpinned: the control would be empty.
            toggle.isEnabled = !(isPinned && pinned.count == 1)
        }
    }

    private var explorerPopup: NSPopUpButton?

    static var versionText: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    @objc private func autoUpdateToggled(_ sender: NSSwitch) {
        Updates.shared.checksAutomatically = sender.state == .on
    }

    @objc private func openLibrary() {
        LibraryWindowController.shared.show(for: nil)
    }

    @objc private func explorerSideChanged(_ sender: NSPopUpButton) {
        FileExplorer.Side.preferred = FileExplorer.Side.allCases[max(0, sender.indexOfSelectedItem)]
    }

    @objc private func toggled(_ sender: NSSwitch) {
        guard let raw = sender.identifier?.rawValue, let stage = ShellViewController.Stage(rawValue: raw) else { return }
        StagePins.toggle(stage)
    }
}
