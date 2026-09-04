import AppKit

/// Content of the popover shown when clicking Make's missing-LSP indicator. While installing,
/// shows just a spinner and status line — raw Homebrew output is captured but only surfaced if
/// the install actually fails, since a wall of terminal text in a small monospaced popover isn't
/// legible and isn't something the user needs to watch when things are going fine. That's a
/// narrower reading of "don't hide what the machine is doing" than a full terminal tab: visible
/// on request (failure), not forced on you for a one-shot unattended command.
final class LSPInstallPopoverViewController: NSViewController {
    private let entry: LanguageServerRegistry.Entry
    private let onInstalled: () -> Void

    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let installButton = NSButton(title: "Install", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private let logView = NSTextView()
    private let logScroll = NSScrollView()
    private var logHeightConstraint: NSLayoutConstraint!
    private var task: Process?

    init(entry: LanguageServerRegistry.Entry, onInstalled: @escaping () -> Void) {
        self.entry = entry
        self.onInstalled = onInstalled
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() { view = NSView() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.widthAnchor.constraint(equalToConstant: 280).isActive = true

        messageLabel.stringValue = "\(entry.languageId.capitalized) language server (\(entry.binaryName)) isn't installed. Diagnostics and autocomplete are disabled for this file. Installing will use Homebrew system-wide — it'll also be available in your terminal and other editors, not just Side."
        messageLabel.font = DS.Text.body()
        messageLabel.textColor = .labelColor
        messageLabel.translatesAutoresizingMaskIntoConstraints = false

        installButton.bezelStyle = .rounded
        installButton.controlSize = .small
        installButton.target = self
        installButton.action = #selector(installTapped)
        installButton.translatesAutoresizingMaskIntoConstraints = false
        installButton.isHidden = entry.installFormula == nil

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
        guard let formula = entry.installFormula, task == nil else { return }
        installButton.isHidden = true
        spinner.startAnimation(nil)
        messageLabel.stringValue = "Installing \(formula) via Homebrew…"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lic", "brew install \(formula)"]
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
            appendLog("Couldn't launch Homebrew: \(error.localizedDescription)")
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
            messageLabel.stringValue = "\(entry.languageId.capitalized) language server installed and activated."
            onInstalled()
        } else {
            messageLabel.stringValue = "Install failed (exit \(exitCode)) — see the log below."
            installButton.isHidden = false
            installButton.isEnabled = true
            logScroll.isHidden = false
            logHeightConstraint.constant = 90
            view.layoutSubtreeIfNeeded()
        }
    }
}
