import AppKit
import Heron

/// Inline review card for one proposed `run_shell_command` call — `ProposedEditView`'s sibling
/// for commands rather than edits. Simpler by design: there's no diff to render, just the exact
/// command text that will be typed into the track's own visible Run session if approved.
final class CommandProposalView: NSView {
    var onApply: (() -> Void)?
    var onReject: (() -> Void)?

    private let headerLabel = NSTextField(labelWithString: "")
    private let commandLabel = NSTextField(wrappingLabelWithString: "")
    private let warningLabel = NSTextField(wrappingLabelWithString: "")
    private let applyButton = NSButton(title: "Run", target: nil, action: nil)
    private let rejectButton = NSButton(title: "Reject", target: nil, action: nil)
    private let resolutionLabel = NSTextField(labelWithString: "")
    private let buttonRow = NSStackView()
    /// The terminal's last lines once the command has run (Direction 02 §5.1) — what it printed,
    /// right here, without a trip to Run.
    private let tailStack = NSStackView()
    private var tailTop: NSLayoutConstraint!
    static let tailLineCount = 40

    convenience init(command: ProposedCommand) {
        // A named task says what it *is*, not just what it runs — "Run the test task" is a
        // decision the user can make at a glance; a command line is something they have to
        // parse first. The command itself stays visible below either way.
        let header = command.spawnRequest != nil ? "Hand work to a subtrack"
            : command.fetchURL != nil ? "Fetch a web page"
            : (command.taskName.map { "Run the \($0) task" } ?? "Run in terminal")
        var warning: String?
        if case .destructive(let reason) = command.riskLevel { warning = reason }
        self.init(header: header, command: command.command, warning: warning)
        if command.spawnRequest != nil { applyButton.title = "Create" }
    }

    /// An outside agent's command (Claude Code's Bash, Codex's exec): the agent has already
    /// asked, so there's nothing to decide; the card shows what it prints as it reports it.
    convenience init(agentCommand: AgentCommandPresentation) {
        self.init(header: "Run in terminal", command: agentCommand.command, warning: nil)
        applyButton.isHidden = true
        rejectButton.isHidden = true
        update(agentCommand)
    }

    private init(header: String, command: String, warning: String?) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = DS.Radius.surface
        bindLayerBackground(DS.Color.raised)
        headerLabel.stringValue = header
        headerLabel.font = DS.Text.body(.semibold)

        commandLabel.stringValue = command
        commandLabel.font = DS.Text.code(12, weight: .regular)
        commandLabel.textColor = .labelColor
        commandLabel.isSelectable = true
        commandLabel.translatesAutoresizingMaskIntoConstraints = false

        warningLabel.font = DS.Text.caption(.semibold)
        warningLabel.textColor = DS.Color.statusFailed
        warningLabel.translatesAutoresizingMaskIntoConstraints = false

        // Destructive commands never auto-run (see AgentRunner.handleToolOutcomes) and say why
        // here, in words: a human has to read the reason before clicking Run. (No red border —
        // Direction 02 §2.1; a tinted enclosure was the easiest thing to scroll past anyway.)
        if let reason = warning {
            warningLabel.stringValue = "⚠︎ \(reason)"
            warningLabel.isHidden = false
        } else {
            warningLabel.isHidden = true
            // A hidden NSView still participates in Auto Layout (unlike a collapsed stack view
            // arranged subview) — without pinning its height to zero, its intrinsic
            // single-empty-line height would still push the button row down, leaving an
            // unexplained gap on every ordinary command's card.
            warningLabel.heightAnchor.constraint(equalToConstant: 0).isActive = true
        }

        applyButton.bezelStyle = .rounded
        applyButton.controlSize = .small
        applyButton.keyEquivalent = "\r"
        applyButton.target = self
        applyButton.action = #selector(applyTapped)
        rejectButton.bezelStyle = .rounded
        rejectButton.controlSize = .small
        rejectButton.target = self
        rejectButton.action = #selector(rejectTapped)

        resolutionLabel.font = DS.Text.caption(.medium)
        resolutionLabel.isHidden = true

        buttonRow.orientation = .horizontal
        buttonRow.spacing = DS.Spacing.m
        buttonRow.addArrangedSubview(applyButton)
        buttonRow.addArrangedSubview(rejectButton)
        runningRing.isHidden = true
        buttonRow.addArrangedSubview(runningRing)
        buttonRow.addArrangedSubview(resolutionLabel)
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        tailStack.orientation = .vertical
        tailStack.alignment = .trailing
        tailStack.spacing = DS.Spacing.s
        tailStack.translatesAutoresizingMaskIntoConstraints = false

        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerLabel)
        addSubview(commandLabel)
        addSubview(warningLabel)
        addSubview(buttonRow)
        addSubview(tailStack)
        tailTop = tailStack.topAnchor.constraint(equalTo: buttonRow.bottomAnchor, constant: 0)
        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            headerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            headerLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            commandLabel.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 6),
            commandLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            commandLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            warningLabel.topAnchor.constraint(equalTo: commandLabel.bottomAnchor, constant: warningLabel.isHidden ? 0 : 6),
            warningLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            warningLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            buttonRow.topAnchor.constraint(equalTo: warningLabel.bottomAnchor, constant: 8),
            buttonRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            tailTop,
            tailStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            tailStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            tailStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Called once the decision is made (or, for an executed command, once its output comes
    /// back) — the card stays in the transcript as a record of what ran and what it produced,
    /// rather than vanishing.
    func showResolution(_ text: String, color: NSColor) {
        applyButton.isHidden = true
        rejectButton.isHidden = true
        resolutionLabel.stringValue = text
        resolutionLabel.textColor = color
        resolutionLabel.isHidden = false
    }

    /// The last `tailLineCount` lines of what the command printed, in code type on `overlay`
    /// (the card is `raised`), radius 10, with "Open in Run" when there's a terminal to go to.
    func showOutputTail(_ output: String, onOpenInRun: (() -> Void)?) {
        tailStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        let tail = lines.suffix(Self.tailLineCount).joined(separator: "\n").trimmingCharacters(in: .newlines)
        guard !tail.isEmpty || onOpenInRun != nil else { return }
        tailTop.constant = 8
        if !tail.isEmpty {
            let text = NSTextView()
            text.isEditable = false
            text.isSelectable = true
            text.drawsBackground = false
            text.font = DS.Text.code(11, weight: .regular)
            text.textColor = .secondaryLabelColor
            text.string = tail
            text.textContainerInset = NSSize(width: 10, height: 8)
            text.isVerticallyResizable = true
            text.autoresizingMask = [.width]
            text.textContainer?.widthTracksTextView = true
            let scroll = NSScrollView()
            scroll.documentView = text
            scroll.hasVerticalScroller = true
            scroll.drawsBackground = false
            scroll.translatesAutoresizingMaskIntoConstraints = false
            // The tone lives on a plain container: a scroll view's own layer fill never shows.
            let surface = NSView()
            surface.wantsLayer = true
            surface.layer?.cornerRadius = DS.Radius.surface
            surface.layer?.masksToBounds = true
            surface.bindLayerBackground(DS.Color.overlay)
            surface.translatesAutoresizingMaskIntoConstraints = false
            surface.addSubview(scroll)
            let lineHeight = ceil(DS.Text.code(11).boundingRectForFont.height)
            let shown = min(tail.split(separator: "\n", omittingEmptySubsequences: false).count, 14)
            NSLayoutConstraint.activate([
                scroll.topAnchor.constraint(equalTo: surface.topAnchor), scroll.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
                scroll.leadingAnchor.constraint(equalTo: surface.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
                surface.heightAnchor.constraint(equalToConstant: CGFloat(shown) * lineHeight + 18),
            ])
            tailStack.addArrangedSubview(surface)
            surface.widthAnchor.constraint(equalTo: tailStack.widthAnchor).isActive = true
            // Starts at the end, where a command's result — and its error — lives.
            DispatchQueue.main.async { text.scrollToEndOfDocument(nil) }
            scroll.setAccessibilityLabel("Command output, last lines")
        }
        if let onOpenInRun {
            let open = NSButton(title: "Open in Run", target: nil, action: nil)
            open.isBordered = false
            open.attributedTitle = NSAttributedString(string: "Open in Run", attributes: [.font: DS.Text.caption(.medium), .foregroundColor: NSColor.labelColor])
            openInRun = onOpenInRun
            open.target = self
            open.action = #selector(openInRunTapped)
            tailStack.addArrangedSubview(open)
        }
    }

    // MARK: An outside agent's command

    private let runningRing = ProgressRing()
    private var liveText: NSTextView?
    private var liveHeight: NSLayoutConstraint?
    private var runningSince: Date?
    private var elapsedTimer: Timer?

    /// The command as the agent last reported it: its line, what it has printed (all of what the
    /// card keeps, scrollable, following the end unless scrolled up), and how it ended.
    func update(_ presentation: AgentCommandPresentation) {
        commandLabel.stringValue = presentation.command
        showLiveOutput(presentation.output, truncated: presentation.isTruncated)
        runningRing.isHidden = !presentation.isRunning
        resolutionLabel.isHidden = false
        switch presentation.state {
        case .running:
            if runningSince == nil { runningSince = Date() }
            resolutionLabel.textColor = .secondaryLabelColor
            refreshElapsed()
            if elapsedTimer == nil, window != nil { startElapsedTimer() }
        case .finished(let code):
            stopElapsed()
            resolutionLabel.stringValue = code.map { $0 == 0 ? "Ran" : "Ran · exit \($0)" } ?? "Ran"
            resolutionLabel.textColor = DS.Color.statusVerified
        case .failed(let code):
            stopElapsed()
            resolutionLabel.stringValue = code.map { "Failed · exit \($0)" } ?? "Failed"
            resolutionLabel.textColor = DS.Color.statusFailed
        case .stopped:
            stopElapsed()
            resolutionLabel.stringValue = "Stopped"
            resolutionLabel.textColor = .secondaryLabelColor
        }
        setAccessibilityLabel("\(headerLabel.stringValue): \(presentation.command), \(resolutionLabel.stringValue)")
    }

    var agentStatusForTesting: String { resolutionLabel.stringValue }
    var liveOutputForTesting: String? { liveText?.string }

    private func refreshElapsed() {
        let seconds = Int(Date().timeIntervalSince(runningSince ?? Date()))
        resolutionLabel.stringValue = seconds < 1 ? "Running" : "Running · \(seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s")"
    }

    private func startElapsedTimer() {
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.refreshElapsed() }
        }
    }

    private func stopElapsed() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        runningSince = nil
    }

    // The tick follows window membership (Swift 6 forbids touching the Timer in deinit).
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        if newWindow != nil, runningSince != nil { startElapsedTimer() }
    }

    private func showLiveOutput(_ output: String, truncated: Bool) {
        let text = output.trimmingCharacters(in: .newlines)
        guard !text.isEmpty else { return }
        let lineHeight = ceil(DS.Text.code(11).boundingRectForFont.height)
        let lines = text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        let height = CGFloat(min(lines, 14)) * lineHeight + 18
        if let liveText, let scroll = liveText.enclosingScrollView {
            let clip = scroll.contentView
            let atEnd = clip.bounds.maxY >= liveText.frame.height - lineHeight * 2
            // New output extends the old: append it, rather than re-laying out every line kept.
            let old = liveText.string
            if text.hasPrefix(old), let storage = liveText.textStorage {
                let added = String(text.dropFirst(old.count))
                storage.append(NSAttributedString(string: added, attributes: [.font: DS.Text.code(11, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]))
            } else if text != old {
                liveText.string = text
            }
            liveHeight?.constant = height
            if atEnd { liveText.scrollToEndOfDocument(nil) }
            return
        }
        tailTop.constant = 8
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = DS.Text.code(11, weight: .regular)
        textView.textColor = .secondaryLabelColor
        textView.string = text
        textView.textContainerInset = NSSize(width: 10, height: 8)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.setAccessibilityLabel(truncated ? "Command output, latest part" : "Command output")
        let surface = NSView()
        surface.wantsLayer = true
        surface.layer?.cornerRadius = DS.Radius.surface
        surface.layer?.masksToBounds = true
        surface.bindLayerBackground(DS.Color.overlay)
        surface.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(scroll)
        let heightConstraint = surface.heightAnchor.constraint(equalToConstant: height)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: surface.topAnchor), scroll.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: surface.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            heightConstraint,
        ])
        tailStack.addArrangedSubview(surface)
        surface.widthAnchor.constraint(equalTo: tailStack.widthAnchor).isActive = true
        liveText = textView
        liveHeight = heightConstraint
        DispatchQueue.main.async { textView.scrollToEndOfDocument(nil) }
    }

    private var openInRun: (() -> Void)?
    @objc private func openInRunTapped() { openInRun?() }

    @objc private func applyTapped() { onApply?() }
    @objc private func rejectTapped() { onReject?() }
}
