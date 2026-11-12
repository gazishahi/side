import AppKit
import SideAgents

/// Settings › Agents (harness RFC, D7): the outside agents Side can run, whether each is
/// installed, and how each signs in: with the user's subscription through the agent's own login,
/// or with an API key Side keeps in the Keychain. Plus any other ACP agent, added by command.
final class AgentsPreferencesViewController: NSViewController {
    /// Posted with `userInfo["agentId"]` when an agent's sign-in changes: its running sessions
    /// restart so the next message uses the new account.
    static let signInDidChangeNotification = Notification.Name("SideACPSignInDidChange")

    private var keyFields: [String: NSSecureTextField] = [:]

    override func loadView() { view = NSView() }

    override func viewDidLoad() {
        super.viewDidLoad()
        rebuild()
        AgentAvailability.refresh { [weak self] in self?.rebuild() }
    }

    private func rebuild() {
        keyFields.removeAll()
        var sections: [NSView] = [SettingsSplitViewController.hero(.agents), defaultSection(), hooksSection()]
        sections += ACPAgent.known.map(section(for:))
        sections.append(SettingsForm.section(footer: "Other agents that speak the Agent Client Protocol (Qwen Code, Goose and more) can be added by the command that starts them in ACP mode. Side has verified Claude Code; the others are experimental, and may not work fully.", [
            SettingsForm.row("Add another agent", SettingsForm.button("Add Agent\u{2026}", self, #selector(addAgent))),
        ]))
        SettingsForm.install(SettingsForm.page(sections), in: view)
    }

    /// The agent new tracks run on (SIDE_RFC_HERON_RETIREMENT.md, step 1). Only installed agents
    /// can be chosen; "Automatic" is the first installed, and says which.
    private func defaultSection() -> NSView {
        let popup = NSPopUpButton()
        popup.menu?.autoenablesItems = false
        let automatic = DefaultAgent.chosenId == nil ? DefaultAgent.agent : nil
        popup.addItem(withTitle: automatic.map { "Automatic (\($0.displayName))" } ?? "Automatic")
        popup.lastItem?.representedObject = ""
        popup.menu?.addItem(.separator())
        for agent in ACPAgent.known {
            let installed = AgentAvailability.isInstalled(agent)
            popup.addItem(withTitle: installed == false ? "\(agent.displayName), not installed" : agent.displayName)
            popup.lastItem?.representedObject = agent.id
            popup.lastItem?.isEnabled = installed != false || agent.id == DefaultAgent.chosenId
        }
        let index = (0..<popup.numberOfItems).first { (popup.item(at: $0)?.representedObject as? String) == (DefaultAgent.chosenId ?? "") }
        popup.selectItem(at: index ?? 0)
        popup.target = self
        popup.action = #selector(defaultAgentChanged(_:))
        popup.setAccessibilityLabel("Default agent")
        defaultPopup = popup
        let anyInstalled = ACPAgent.known.contains { AgentAvailability.isInstalled($0) == true }
        let detail = DefaultAgent.agent != nil
            ? "New tracks and subtracks start on it. A track can still change agent from its session pill."
            : anyInstalled ? "Choose one for new tracks to start on." : "No agent is installed yet. Install one below, then come back to choose it."
        return SettingsForm.section([SettingsForm.row("Default agent", detail: detail, popup)])
    }

    private(set) var defaultPopup: NSPopUpButton?

    /// Claude Code's hooks (SIDE_RFC_SESSIONS.md, phase 2): every Claude Code session's state,
    /// in Side's terminals or any other, from Claude Code itself. Opt-in, and removable.
    private func hooksSection() -> NSView {
        let status = ClaudeHooks.status(at: ClaudeHooks.userSettings)
        let detail: String
        let action: NSButton
        switch status {
        case .installed:
            detail = "On for every project."
            action = SettingsForm.button("Remove", self, #selector(removeHooks))
        case .incomplete:
            detail = "Some of Side\u{2019}s hooks were taken out of Claude Code\u{2019}s settings."
            action = SettingsForm.button("Put Back", self, #selector(installHooks))
        case .notInstalled:
            detail = "Off."
            action = SettingsForm.button("Turn On", self, #selector(installHooks))
        }
        action.setAccessibilityIdentifier("settings.claudeHooks")
        var rows = [SettingsForm.row("Session hooks", detail: detail, action)]
        for project in ClaudeHooks.projects {
            let remove = SettingsForm.button("Remove", self, #selector(removeProjectHooks(_:)))
            remove.identifier = NSUserInterfaceItemIdentifier(project.path)
            rows.append(SettingsForm.row(project.lastPathComponent, detail: "On for this project only.", remove))
        }
        if status == .notInstalled {
            rows.append(SettingsForm.row("For one project", SettingsForm.button("Choose Project\u{2026}", self, #selector(installProjectHooks))))
        }
        let footer = "Side adds a small hook to Claude Code\u{2019}s settings (\(Self.shortPath(ClaudeHooks.userSettings))) so it hears from every Claude Code session, in Side or any other terminal: when it\u{2019}s working, what it\u{2019}s waiting for, and when it\u{2019}s done. Nothing else in the file changes, and the file as it was is kept beside it. Side never reads your sign-in or your conversations."
        return SettingsForm.section("Claude Code sessions", footer: footer, rows)
    }

    private static func shortPath(_ url: URL) -> String { (url.path as NSString).abbreviatingWithTildeInPath }

    @objc private func installHooks() { changeHooks { try ClaudeHooks.install(at: ClaudeHooks.userSettings) } }
    @objc private func removeHooks() { changeHooks { try ClaudeHooks.remove(at: ClaudeHooks.userSettings) } }

    @objc private func removeProjectHooks(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        changeHooks { try ClaudeHooks.remove(at: ClaudeHooks.projectSettings(URL(fileURLWithPath: path, isDirectory: true))) }
    }

    @objc private func installProjectHooks() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Turn On"
        panel.message = "Hooks go in the project\u{2019}s .claude/settings.local.json, which Claude Code keeps out of the repository."
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let project = panel.url else { return }
            self?.changeHooks { try ClaudeHooks.install(at: ClaudeHooks.projectSettings(project), project: project) }
        }
    }

    private func changeHooks(_ change: () throws -> Void) {
        do {
            try change()
            HookInbox.shared.start()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Claude Code\u{2019}s settings weren\u{2019}t changed"
            alert.informativeText = error.localizedDescription
            if let window = view.window { alert.beginSheetModal(for: window) } else { alert.runModal() }
        }
        rebuild()
    }

    @objc private func defaultAgentChanged(_ sender: NSPopUpButton) {
        let id = sender.selectedItem?.representedObject as? String ?? ""
        DefaultAgent.chosenId = id.isEmpty ? nil : id
        rebuild()
    }

    private func section(for agent: ACPAgent) -> NSView {
        let installed = AgentAvailability.isInstalled(agent)
        let name = NSTextField(labelWithString: agent.displayName)
        name.font = DS.Text.body(.semibold)
        let badge = SettingsForm.badge(installed == nil ? "Checking" : (installed! ? "Installed" : "Not installed"),
                                       color: installed == true ? DS.Color.statusVerified : .secondaryLabelColor)
        var headerViews: [NSView] = [name, badge]
        if !agent.isVerified { headerViews.append(SettingsForm.badge("Experimental", color: .secondaryLabelColor)) }
        headerViews.append(NSView())
        if agent.isCustom {
            let remove = SettingsForm.button("Remove", self, #selector(removeAgent(_:)), destructive: true)
            remove.identifier = NSUserInterfaceItemIdentifier(agent.id)
            headerViews.append(remove)
        }
        let header = NSStackView(views: headerViews)
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = DS.Spacing.m
        var rows: [NSView] = [SettingsForm.content(header)]

        if installed == false {
            let copy = SettingsForm.button("Copy", self, #selector(copyInstall(_:)))
            copy.identifier = NSUserInterfaceItemIdentifier(agent.installHint)
            let command = NSTextField(labelWithString: agent.installHint)
            command.font = DS.Text.code(11.5)
            command.textColor = .secondaryLabelColor
            command.isSelectable = true
            command.lineBreakMode = .byTruncatingMiddle
            command.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let line = NSStackView(views: [command, NSView(), copy])
            line.orientation = .horizontal
            line.alignment = .centerY
            line.spacing = DS.Spacing.m
            let install = NSStackView(views: [Self.label("Install"), line])
            install.orientation = .vertical
            install.alignment = .leading
            install.spacing = 4
            line.widthAnchor.constraint(equalTo: install.widthAnchor).isActive = true
            rows.append(SettingsForm.content(install))
        }

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

        if agent.signIn == .apiKey, agent.acceptsAPIKey {
            rows.append(SettingsForm.row("Sign in with", popup))
            let field = NSSecureTextField()
            field.placeholderString = agent.storedAPIKey == nil ? "Paste an API key" : "Saved in your Keychain"
            field.widthAnchor.constraint(equalToConstant: 200).isActive = true
            field.setAccessibilityLabel("\(agent.displayName) API key")
            keyFields[agent.id] = field
            let save = SettingsForm.button("Save", self, #selector(saveKey(_:)))
            save.identifier = NSUserInterfaceItemIdentifier(agent.id)
            let keyLine = NSStackView(views: [field, save])
            keyLine.spacing = DS.Spacing.s
            let variable = agent.apiKeyVariables.first ?? ""
            let inherited = agent.apiKeyVariables.contains { ProcessInfo.processInfo.environment[$0]?.isEmpty == false }
            let note = agent.storedAPIKey != nil
                ? "Given to \(agent.displayName) as \(variable)."
                : (inherited ? "No key saved. Using the \(variable) already in your environment." : "No key saved yet.")
            rows.append(SettingsForm.row("API key", detail: note, keyLine))
        } else {
            var note = agent.acceptsAPIKey
                ? "Uses its own sign-in. Keys in your environment (\(agent.apiKeyVariables.joined(separator: ", "))) aren't passed to it."
                : "Uses its own sign-in."
            // Claude Code runs through Anthropic's Agent SDK on the person's own `claude` login,
            // as T3 Code does; Side never sees or keeps the sign-in. Anthropic's terms ask tools
            // built on the Agent SDK to use API keys, which is said rather than hidden
            // (decided with the owner 2026-10-03; code.claude.com/docs/en/legal-and-compliance).
            if agent.id == "claude-code" {
                note += " This is your own claude login, run through Anthropic\u{2019}s Agent SDK; Side never sees it. Anthropic\u{2019}s terms ask tools built on the Agent SDK to use API keys, so an API key is the choice that raises no question."
            }
            rows.append(SettingsForm.row("Sign in with", detail: note, popup))
        }
        return SettingsForm.section(rows)
    }

    private static func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = DS.Text.body()
        return label
    }

    private static func wrapping(_ text: String, width: CGFloat) -> NSTextField {
        let label = WrappingLabel(wrappingLabelWithString: text)
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

    /// Asked first (UX-10): tracks set to this agent offer to continue on the default agent.
    @objc private func removeAgent(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \u{201C}\(ACPAgent.agent(id: id)?.displayName ?? id)\u{201D}?"
        alert.informativeText = "Side forgets how to start it. Its own install and sign-in are untouched; you can add it again."
        alert.addButton(withTitle: "Remove Agent").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            ACPAgent.removeCustom(id: id)
            self.announce(id)
            self.rebuild()
        }
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
