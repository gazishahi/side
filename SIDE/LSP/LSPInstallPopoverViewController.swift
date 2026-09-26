import AppKit
import Heron

/// Content of the popover shown when clicking Make's missing-LSP indicator. While installing,
/// shows just a spinner and status line — raw Homebrew output is captured but only surfaced if
/// the install actually fails, since a wall of terminal text in a small monospaced popover isn't
/// legible and isn't something the user needs to watch when things are going fine. That's a
/// narrower reading of "don't hide what the machine is doing" than a full terminal tab: visible
/// on request (failure), not forced on you for a one-shot unattended command.
final class LSPInstallPopoverViewController: NSViewController {
    /// What's installed (its binary's name, for the words), how, and what's said first.
    private let name: String
    private let install: LanguageInstall?
    private let intro: String
    private let onInstalled: () -> Void

    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let installButton = NSButton(title: "Install", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private let logView = NSTextView()
    private let logScroll = NSScrollView()
    private var logHeightConstraint: NSLayoutConstraint!
    private var task: Process?

    init(entry: LanguageServerRegistry.Entry, onInstalled: @escaping () -> Void) {
        let language = LanguageSettings.presets.first { $0.id == entry.languageKey }?.name ?? entry.languageId.capitalized
        name = entry.binaryName
        install = entry.install
        intro = "\(language)'s language server (\(entry.binaryName)) isn't installed, so completion and problems are off for it. \(entry.install.map { "Installing runs \u{201C}\($0.command)\u{201D}, so it'll also be available in your terminal and other editors, not just Side." } ?? "Install it, then reopen the file.")"
        self.onInstalled = onInstalled
        super.init(nibName: nil, bundle: nil)
    }

    /// A debug adapter (SIDE_RFC_DEBUGGER.md, D2).
    init(debugger: DebugAdapterPreset, onInstalled: @escaping () -> Void) {
        name = debugger.name
        install = debugger.install
        intro = "\(debugger.name) isn't installed, so debugging \(debugger.languages.compactMap { id in LanguageSettings.presets.first { $0.id == id }?.name }.joined(separator: ", ")) is off. Installing uses \(debugger.install?.tool ?? "its installer"). \(debugger.note)"
        self.onInstalled = onInstalled
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() { view = NSView() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.widthAnchor.constraint(equalToConstant: 280).isActive = true

        messageLabel.stringValue = intro
        messageLabel.font = DS.Text.body()
        messageLabel.textColor = .labelColor
        messageLabel.translatesAutoresizingMaskIntoConstraints = false

        installButton.bezelStyle = .rounded
        installButton.controlSize = .small
        installButton.target = self
        installButton.action = #selector(installTapped)
        installButton.translatesAutoresizingMaskIntoConstraints = false
        installButton.isHidden = install == nil

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        logView.isEditable = false
        logView.font = DS.Text.code(10, weight: .regular)
        logView.textColor = .secondaryLabelColor
        logView.drawsBackground = false
        logScroll.documentView = logView
        logScroll.hasVerticalScroller = true
        logScroll.drawsBackground = false
        logScroll.translatesAutoresizingMaskIntoConstraints = false
        logScroll.isHidden = true
        logHeightConstraint = logScroll.heightAnchor.constraint(equalToConstant: 0)
        logHeightConstraint.isActive = true

        let buttonRow = NSStackView(views: [installButton, spinner])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = DS.Spacing.m
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [messageLabel, buttonRow, logScroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DS.Spacing.l
        stack.edgeInsets = NSEdgeInsets(top: DS.Spacing.xxl, left: DS.Spacing.xxl, bottom: DS.Spacing.xxl, right: DS.Spacing.xxl)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor), stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor), stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            messageLabel.widthAnchor.constraint(equalToConstant: 252),
            logScroll.widthAnchor.constraint(equalToConstant: 252)
        ])
    }

    @objc private func installTapped() {
        guard let install, task == nil else { return }
        installButton.isHidden = true
        spinner.startAnimation(nil)
        messageLabel.stringValue = "Checking for \(install.tool)…"
        // The installer has to be there first: say what's missing rather than run a command
        // that can only fail.
        let requirement = install.requirement
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let present = LanguageServerRegistry.resolveExecutable(named: requirement.binary) != nil
            DispatchQueue.main.async {
                guard let self else { return }
                guard present else {
                    LanguageServerRegistry.invalidateResolution(for: requirement.binary)
                    self.spinner.stopAnimation(nil)
                    self.messageLabel.stringValue = "Installing \(self.name) needs \(requirement.hint). Install that, then try again."
                    self.installButton.isHidden = false
                    return
                }
                self.runInstall(install)
            }
        }
    }

    private func runInstall(_ install: LanguageInstall) {
        messageLabel.stringValue = "Installing \(name) with \(install.tool)…"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lic", install.command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.appendLog(text) }
        }
        process.terminationHandler = { [weak self] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async { self?.installFinished(exitCode: proc.terminationStatus) }
        }
        task = process
        do {
            try process.run()
        } catch {
            appendLog("Couldn't launch \(install.tool): \(error.localizedDescription)")
            installFinished(exitCode: -1)
        }
    }

    private func appendLog(_ text: String) {
        logView.textStorage?.append(NSAttributedString(string: text))
        logView.scrollToEndOfDocument(nil)
    }

    private func installFinished(exitCode: Int32) {
        task = nil
        spinner.stopAnimation(nil)
        if exitCode == 0 {
            messageLabel.stringValue = "\(name) is installed and running."
            onInstalled()
        } else {
            messageLabel.stringValue = "Install failed (exit \(exitCode)). See the log below."
            installButton.isHidden = false
            installButton.isEnabled = true
            logScroll.isHidden = false
            logHeightConstraint.constant = 90
            view.layoutSubtreeIfNeeded()
        }
    }
}
