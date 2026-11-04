import AppKit
import Heron

/// Which outside agents are installed (harness RFC step 4), and where. Resolution asks the login
/// shell, so it runs off the main thread and is cached for the session; `refresh` re-asks.
@MainActor
enum AgentAvailability {
    private static var installed: [String: Bool] = [:]
    private static var refreshing = false

    /// nil until looked up.
    static func isInstalled(_ agent: ACPAgent) -> Bool? { installed[agent.id] }

    /// The agent's executable: a hidden per-agent override (`SideACPAgentPath.<id>`, for an
    /// agent the shell doesn't find — and for testing against a mock), else the login-shell PATH.
    nonisolated static func executable(for agent: ACPAgent) -> URL? {
        if let override = ACPAgent.defaults.string(forKey: "SideACPAgentPath.\(agent.id)") {
            return URL(fileURLWithPath: override)
        }
        return LanguageServerRegistry.resolveExecutable(named: agent.binary)
    }

    static func refresh(then completion: @escaping () -> Void) {
        guard !refreshing else { return }
        refreshing = true
        let agents = ACPAgent.known
        DispatchQueue.global(qos: .userInitiated).async {
            let found = Dictionary(uniqueKeysWithValues: agents.map { ($0.id, executable(for: $0) != nil) })
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    installed = found
                    refreshing = false
                    completion()
                }
            }
        }
    }
}

/// The "AGENT" row both session popovers start with: Heron, or an outside agent (RFC step 4).
@MainActor
enum AgentPicker {
    /// `representedObject` is the agent id, "" for Heron.
    static func makePopup(currentId: String?, target: AnyObject, action: Selector) -> NSPopUpButton {
        let popup = NSPopUpButton()
        fill(popup, currentId: currentId)
        popup.target = target
        popup.action = action
        popup.setAccessibilityLabel("Agent")
        return popup
    }

    /// (Re)fills the list — again once detection has found which agents are installed.
    static func fill(_ popup: NSPopUpButton, currentId: String?) {
        popup.removeAllItems()
        popup.menu?.autoenablesItems = false
        popup.addItem(withTitle: "Heron")
        popup.lastItem?.representedObject = ""
        popup.menu?.addItem(.separator())
        for agent in ACPAgent.known {
            let installed = AgentAvailability.isInstalled(agent)
            let label = agent.isVerified ? agent.displayName : "\(agent.displayName) (experimental)"
            popup.addItem(withTitle: installed == false ? "\(label), not installed" : label)
            popup.lastItem?.representedObject = agent.id
            if installed == false { popup.lastItem?.toolTip = "Install with: \(agent.installHint)" }
        }
        let index = (0..<popup.numberOfItems).first { (popup.item(at: $0)?.representedObject as? String) == (currentId ?? "") }
        popup.selectItem(at: index ?? 0)
    }
}

/// The session pill's popover for a track on an outside agent: which agent, then the agent's own
/// settings as it reports them — model, effort, mode… — plus context and account (RFC D6).
/// Side's Heron-only controls (scope, effort, Side's model list) don't apply and aren't shown.
final class AgentSessionSettingsViewController: NSViewController {
    weak var harness: (any Harness)?
    var harnessId: String?
    /// The agent id picked, "" for Heron.
    var onAgentChosen: ((String) -> Void)?

    private let stack = NSStackView()

    override func loadView() { view = NSView() }

    override func viewDidLoad() {
        super.viewDidLoad()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DS.Spacing.s
        stack.edgeInsets = NSEdgeInsets(top: DS.Spacing.xxl, left: DS.Spacing.xxl, bottom: DS.Spacing.xxl, right: DS.Spacing.xxl)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            view.widthAnchor.constraint(equalToConstant: 340),
        ])
        refresh()
        AgentAvailability.refresh { [weak self] in self?.refresh() }
    }

    /// Rebuilt from the harness each time something changes — options arrive when the session
    /// opens, and setting one (a model) can change another (its effort levels).
    func refresh() {
        guard isViewLoaded else { return }
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
        let width: CGFloat = 312

        func caption(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text.uppercased())
            label.font = DS.Text.caption()
            label.textColor = .tertiaryLabelColor
            return label
        }
        func note(_ text: String, color: NSColor = .tertiaryLabelColor) -> NSTextField {
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = DS.Text.caption()
            label.textColor = color
            label.preferredMaxLayoutWidth = width
            return label
        }

        let picker = AgentPicker.makePopup(currentId: harnessId, target: self, action: #selector(agentChanged(_:)))
        stack.addArrangedSubview(caption("Agent"))
        stack.addArrangedSubview(picker)
        picker.widthAnchor.constraint(equalToConstant: width).isActive = true
        stack.setCustomSpacing(DS.Spacing.xl, after: picker)

        let options = harness?.agentOptions ?? []
        if options.isEmpty {
            stack.addArrangedSubview(note("Opening a session… The agent's model and mode appear here once it answers."))
        }
        for (index, option) in options.enumerated() {
            stack.addArrangedSubview(caption(option.name))
            let popup = NSPopUpButton()
            for choice in option.choices {
                popup.addItem(withTitle: choice.name)
                popup.lastItem?.representedObject = choice.value
                popup.lastItem?.toolTip = choice.detail
            }
            popup.selectItem(at: option.choices.firstIndex { $0.value == option.current } ?? -1)
            popup.tag = index
            popup.target = self
            popup.action = #selector(optionChanged(_:))
            popup.setAccessibilityLabel(option.name)
            popup.widthAnchor.constraint(equalToConstant: width).isActive = true
            stack.addArrangedSubview(popup)
            var last: NSView = popup
            if option.category == .mode, let detail = option.currentChoice?.detail {
                let line = note(detail)
                stack.addArrangedSubview(line)
                last = line
            }
            if option.actsWithoutAsking {
                // RFC D1: the product says plainly when an agent's edits aren't pre-approved.
                let line = note("Edits land directly. Each turn is checkpointed, so you can review and undo it in Changes.", color: .secondaryLabelColor)
                stack.addArrangedSubview(line)
                last = line
            }
            stack.setCustomSpacing(DS.Spacing.xl, after: last)
        }

        let separator = NSBox()
        separator.boxType = .separator
        stack.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalToConstant: width).isActive = true
        if let harness {
            let usage = harness.contextUsage()
            if usage.windowTokens > 0 {
                stack.addArrangedSubview(note("Context: \(UsageFormatting.tokens(usage.usedTokens)) of \(UsageFormatting.tokens(usage.windowTokens)) tokens (\(Int((usage.fraction * 100).rounded()))%)", color: .secondaryLabelColor))
            }
            if let account = harness.accountLabel {
                stack.addArrangedSubview(note("Account: \(account)", color: .secondaryLabelColor))
            }
        }
    }

    @objc private func agentChanged(_ sender: NSPopUpButton) {
        guard let id = sender.selectedItem?.representedObject as? String else { return }
        onAgentChosen?(id)
    }

    @objc private func optionChanged(_ sender: NSPopUpButton) {
        guard let harness, harness.agentOptions.indices.contains(sender.tag),
              let value = sender.selectedItem?.representedObject as? String else { return }
        harness.setAgentOption(id: harness.agentOptions[sender.tag].id, value: value)
    }
}
