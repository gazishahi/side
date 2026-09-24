import AppKit
import Heron

/// Settings › Agents (harness RFC, D7): the outside agents Side can run, whether each is
/// installed, and how each signs in: with the user's subscription through the agent's own login,
/// or with an API key Side keeps in the Keychain. Plus any other ACP agent, added by command.
final class AgentsPreferencesViewController: NSViewController {
    /// Posted with `userInfo["agentId"]` when an agent's sign-in changes: its running sessions
    /// restart so the next message uses the new account.
    static let signInDidChangeNotification = Notification.Name("SideACPSignInDidChange")

    private let stack = NSStackView()
    private var keyFields: [String: NSSecureTextField] = [:]

    override func loadView() {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let document = AgentsFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DS.Spacing.m
        stack.edgeInsets = NSEdgeInsets(top: DS.Spacing.section, left: DS.Spacing.section, bottom: DS.Spacing.section, right: DS.Spacing.section)
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        scroll.frame = NSRect(x: 0, y: 0, width: 520, height: 520)
        view = scroll
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        rebuild()
        AgentAvailability.refresh { [weak self] in self?.rebuild() }
    }

    private func rebuild() {
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
        keyFields.removeAll()
        let width: CGFloat = 480

        let title = NSTextField(labelWithString: "Agents")
        title.font = DS.Text.heading()
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(Self.wrapping("A track can run on Heron or on an outside agent. Outside agents use your own account: your subscription through the agent's own sign-in, or an API key you give Side. Side never sees your password.", width: width))
        stack.setCustomSpacing(DS.Spacing.section, after: stack.arrangedSubviews.last!)

        for agent in ACPAgent.known {
            stack.addArrangedSubview(row(for: agent, width: width))
            let separator = NSBox()
            separator.boxType = .separator
            stack.addArrangedSubview(separator)
            separator.widthAnchor.constraint(equalToConstant: width).isActive = true
        }

        let add = NSButton(title: "Add Agent…", target: self, action: #selector(addAgent))
        add.bezelStyle = .rounded
        stack.addArrangedSubview(add)
        stack.addArrangedSubview(Self.wrapping("Any agent that speaks the Agent Client Protocol works: OpenCode, Qwen Code, Goose and others. Add it by the command that starts it in ACP mode.", width: width))
    }

    private func row(for agent: ACPAgent, width: CGFloat) -> NSView {
        let name = NSTextField(labelWithString: agent.displayName)
        name.font = DS.Text.body(.semibold)
        let installed = AgentAvailability.isInstalled(agent)
        let status = NSTextField(labelWithString: installed == nil ? "Checking…" : (installed! ? "Installed" : "Not installed"))
        status.font = DS.Text.caption()
        status.textColor = installed == true ? .secondaryLabelColor : .tertiaryLabelColor
        let header = NSStackView(views: [name, status])
        header.spacing = DS.Spacing.m
        if agent.isCustom {
            let remove = NSButton(title: "Remove", target: self, action: #selector(removeAgent(_:)))
            remove.bezelStyle = .inline
            remove.identifier = NSUserInterfaceItemIdentifier(agent.id)
            header.addArrangedSubview(remove)
        }
        var views: [NSView] = [header]

        if installed == false {
            let command = NSTextField(labelWithString: agent.installHint)
            command.font = DS.Text.code()
            command.textColor = .secondaryLabelColor
            command.isSelectable = true
            command.lineBreakMode = .byTruncatingMiddle
            let copy = NSButton(title: "Copy", target: self, action: #selector(copyInstall(_:)))
            copy.bezelStyle = .inline
            copy.identifier = NSUserInterfaceItemIdentifier(agent.installHint)
            let line = NSStackView(views: [command, copy])
            line.spacing = DS.Spacing.m
            command.widthAnchor.constraint(lessThanOrEqualToConstant: width - 80).isActive = true
            views.append(line)
        }

        let label = NSTextField(labelWithString: "Sign in with")
        label.font = DS.Text.caption()
        label.textColor = .tertiaryLabelColor
        let popup = NSPopUpButton()
        popup.addItem(withTitle: agent.subscriptionName)
        popup.lastItem?.representedObject = ACPAgent.SignIn.subscription.rawValue
        if agent.acceptsAPIKey {
            popup.addItem(withTitle: "API key")
            popup.lastItem?.representedObject = ACPAgent.SignIn.apiKey.rawValue
        }
        popup.selectItem(at: agent.signIn == .apiKey && agent.acceptsAPIKey ? 1 : 0)
        popup.identifier = NSUserInterfaceItemIdentifier(agent.id)
        popup.target = self
        popup.action = #selector(signInChanged(_:))
        popup.setAccessibilityLabel("\(agent.displayName) sign-in")
        let signInLine = NSStackView(views: [label, popup])
        signInLine.spacing = DS.Spacing.m
        views.append(signInLine)

        if agent.signIn == .apiKey, agent.acceptsAPIKey {
            let field = NSSecureTextField()
            field.placeholderString = agent.storedAPIKey == nil ? "Paste an API key" : "Saved in your Keychain"
            field.widthAnchor.constraint(equalToConstant: 300).isActive = true
            field.setAccessibilityLabel("\(agent.displayName) API key")
            keyFields[agent.id] = field
            let save = NSButton(title: "Save", target: self, action: #selector(saveKey(_:)))
            save.bezelStyle = .rounded
            save.identifier = NSUserInterfaceItemIdentifier(agent.id)
            let keyLine = NSStackView(views: [field, save])
            keyLine.spacing = DS.Spacing.m
            views.append(keyLine)
            let variable = agent.apiKeyVariables.first ?? ""
            let inherited = agent.apiKeyVariables.contains { ProcessInfo.processInfo.environment[$0]?.isEmpty == false }
            let note = agent.storedAPIKey != nil
                ? "Given to \(agent.displayName) as \(variable)."
                : (inherited ? "No key saved. Using the \(variable) already in your environment." : "No key saved yet.")
            views.append(Self.wrapping(note, width: width))
        } else {
            let note = agent.acceptsAPIKey
                ? "\(agent.displayName) uses its own sign-in. API keys in your environment (\(agent.apiKeyVariables.joined(separator: ", "))) are not passed to it."
                : "\(agent.displayName) uses its own sign-in."
            views.append(Self.wrapping(note, width: width))
        }

        let column = NSStackView(views: views)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = DS.Spacing.s
        return column
    }

    private static func wrapping(_ text: String, width: CGFloat) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = DS.Text.caption()
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = width
        return label
    }

    // MARK: Actions

    @objc private func signInChanged(_ sender: NSPopUpButton) {
        guard let id = sender.identifier?.rawValue, let agent = ACPAgent.agent(id: id),
              let raw = sender.selectedItem?.representedObject as? String, let choice = ACPAgent.SignIn(rawValue: raw) else { return }
        agent.signIn = choice
        announce(id)
        rebuild()
    }

    @objc private func saveKey(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let agent = ACPAgent.agent(id: id), let field = keyFields[id] else { return }
        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        agent.setAPIKey(key)
        announce(id)
        rebuild()
    }

    @objc private func copyInstall(_ sender: NSButton) {
        guard let command = sender.identifier?.rawValue else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    @objc private func removeAgent(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        ACPAgent.removeCustom(id: id)
        announce(id)
        rebuild()
    }

    @objc private func addAgent() {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Add Agent"
        alert.informativeText = "The command that starts the agent in ACP mode, as you'd type it in a terminal."
        let width = TracksWorkspaceViewController.alertFieldWidth
        func field(_ placeholder: String) -> NSTextField {
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: width, height: 24))
            field.placeholderString = placeholder
            field.widthAnchor.constraint(equalToConstant: width).isActive = true
            return field
        }
        let name = field("Name, like OpenCode")
        let command = field("Command, like opencode acp")
        let variable = field("API key variable (optional)")
        let form = NSStackView(views: [name, command, variable])
        form.orientation = .vertical
        form.spacing = DS.Spacing.m
        form.frame = NSRect(x: 0, y: 0, width: width, height: 96)
        alert.accessoryView = form
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = name
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let parts = command.stringValue.split(separator: " ").map(String.init)
            let title = name.stringValue.trimmingCharacters(in: .whitespaces)
            guard let executable = parts.first, !title.isEmpty else { return }
            ACPAgent.addCustom(name: title, command: executable, arguments: Array(parts.dropFirst()), apiKeyVariable: variable.stringValue)
            AgentAvailability.refresh { self?.rebuild() }
        }
    }

    private func announce(_ id: String) {
        NotificationCenter.default.post(name: Self.signInDidChangeNotification, object: nil, userInfo: ["agentId": id])
    }
}

private final class AgentsFlippedView: NSView {
    override var isFlipped: Bool { true }
}
