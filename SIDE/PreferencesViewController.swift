import AppKit

/// The first real content behind Cmd+, — replaces the "no preferences yet" stub now that
/// there's something genuinely configurable: model providers. Phase 2 scope is the built-in
/// Anthropic entry (key + default model); the provider list generalizes with BYOK/local
/// entries in Phase 6.
final class PreferencesViewController: NSViewController {
    private let keyField = NSSecureTextField()
    private let keyStatusLabel = NSTextField(labelWithString: "")
    private let modelPopup = NSPopUpButton()

    private var anthropic: ProviderDefinition? { ProviderRegistryStore.shared.provider(for: "anthropic") }

    override func loadView() { view = NSView() }

    override func viewDidLoad() {
        super.viewDidLoad()

        let title = NSTextField(labelWithString: "Model Providers")
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        let providerName = NSTextField(labelWithString: anthropic?.displayName ?? "Anthropic")
        providerName.font = .systemFont(ofSize: 12, weight: .medium)

        keyField.placeholderString = "sk-ant-…"
        keyField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        keyField.translatesAutoresizingMaskIntoConstraints = false
        keyField.widthAnchor.constraint(equalToConstant: 280).isActive = true

        let saveButton = NSButton(title: "Save Key", target: self, action: #selector(saveKey))
        saveButton.bezelStyle = .rounded
        saveButton.controlSize = .small
        let removeButton = NSButton(title: "Remove", target: self, action: #selector(removeKey))
        removeButton.bezelStyle = .rounded
        removeButton.controlSize = .small

        let keyRow = NSStackView(views: [keyField, saveButton, removeButton])
        keyRow.orientation = .horizontal
        keyRow.spacing = 8

        keyStatusLabel.font = .systemFont(ofSize: 11)
        keyStatusLabel.textColor = .secondaryLabelColor

        let modelLabel = NSTextField(labelWithString: "Default model:")
        modelLabel.font = .systemFont(ofSize: 12)
        modelPopup.target = self
        modelPopup.action = #selector(modelChanged)
        let modelRow = NSStackView(views: [modelLabel, modelPopup])
        modelRow.orientation = .horizontal
        modelRow.spacing = 8

        let stack = NSStackView(views: [title, providerName, keyRow, keyStatusLabel, modelRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(16, after: title)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            view.widthAnchor.constraint(greaterThanOrEqualToConstant: 440),
        ])

        reloadModelPopup()
        refreshKeyStatus()
    }

    private func reloadModelPopup() {
        modelPopup.removeAllItems()
        guard let anthropic else { return }
        for model in anthropic.models {
            modelPopup.addItem(withTitle: model.displayName)
            modelPopup.lastItem?.representedObject = model.id
        }
        if let index = anthropic.models.firstIndex(where: { $0.id == anthropic.defaultModelId }) {
            modelPopup.selectItem(at: index)
        }
    }

    private func refreshKeyStatus() {
        if KeychainStore.hasSecret(account: "anthropic") {
            keyStatusLabel.stringValue = "A key is saved in your Keychain."
        } else if ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]?.isEmpty == false {
            keyStatusLabel.stringValue = "No key saved — currently using ANTHROPIC_API_KEY from the environment."
        } else {
            keyStatusLabel.stringValue = "No key set — Think can't reach Anthropic without one."
        }
    }

    @objc private func saveKey() {
        let secret = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty else { return }
        if KeychainStore.set(secret: secret, account: "anthropic") {
            keyField.stringValue = ""
        } else {
            keyStatusLabel.stringValue = "Couldn't write to the Keychain."
        }
        refreshKeyStatus()
    }

    @objc private func removeKey() {
        KeychainStore.delete(account: "anthropic")
        refreshKeyStatus()
    }

    @objc private func modelChanged() {
        guard let modelId = modelPopup.selectedItem?.representedObject as? String else { return }
        ProviderRegistryStore.shared.setDefaultModel(providerId: "anthropic", modelId: modelId)
    }
}
