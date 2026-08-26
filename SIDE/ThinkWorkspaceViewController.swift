import AppKit

/// Document view for the transcript. Flipped so blocks stack from the top down — an unflipped
/// scroll-view document view pins sparse content to the bottom, the same trap the Tracks ledger
/// hit.
private final class TranscriptContainerView: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
}

/// The Think stage: a *projection* of an `AgentRunner` — it owns no conversation state of its
/// own anymore. The loop, the streaming accumulator, and the approval pause all live on the
/// runner (`Heron/AgentRunner.swift`), which is owned by `ProjectContext` and outlives this view
/// across stage switches, track switches, and even this window closing while another window
/// keeps the project open. This controller's only job is: render whichever runner it's currently
/// attached to, and forward Send/Stop/Apply/Reject back to it.
final class ThinkWorkspaceViewController: NSViewController {
    private let transcriptScroll = NSScrollView()
    private let transcriptContainer = TranscriptContainerView()
    private let transcriptStack = NSStackView()
    private let composer = ComposerView()
    private let modelLabel = NSTextField(labelWithString: "")
    /// The explainer lives here now — visible only while there's nothing else to look at,
    /// instead of as a permanent first line of every conversation.
    private let emptyStateLabel = NSTextField(wrappingLabelWithString: "Ask about this project. The agent can read files, propose edits, and run commands — everything it changes waits for your approval.")

    private var runnerManager: AgentRunnerManager?
    /// Which project's usage the header reports — set alongside `runnerManager`.
    private var projectPath: String?
    private var usageObserverToken: UUID?
    /// Branch-name key, "" for "no active track" — same convention as Make/Run.
    private var attachedTrackKey: String?
    private var runner: AgentRunner?
    private var observerToken: UUID?
    /// Parallel to `runner.entries` — the view currently rendering each entry, so a streamed
    /// delta or a proposal resolution can update one block in place instead of rebuilding the
    /// whole transcript on every token.
    private var entryViews: [NSView] = []

    override func loadView() { view = NSView() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.wantsLayer = true
        ChromeBackground.install(in: view)

        modelLabel.font = .systemFont(ofSize: 11, weight: .medium)
        modelLabel.textColor = .secondaryLabelColor
        modelLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(modelLabel)

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(divider)

        transcriptStack.orientation = .vertical
        transcriptStack.alignment = .leading
        transcriptStack.spacing = 6
        transcriptStack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        transcriptStack.translatesAutoresizingMaskIntoConstraints = false
        transcriptContainer.addSubview(transcriptStack)
        transcriptContainer.translatesAutoresizingMaskIntoConstraints = false
        transcriptScroll.documentView = transcriptContainer
        transcriptScroll.hasVerticalScroller = true
        transcriptScroll.drawsBackground = false
        transcriptScroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(transcriptScroll)

        composer.placeholder = "Ask about this project…"
        composer.onAction = { [weak self] in self?.composerActionTapped() }
        view.addSubview(composer)

        emptyStateLabel.font = .systemFont(ofSize: 12.5)
        emptyStateLabel.textColor = .tertiaryLabelColor
        emptyStateLabel.alignment = .center
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyStateLabel)

        NSLayoutConstraint.activate([
            emptyStateLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyStateLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            modelLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            modelLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            divider.topAnchor.constraint(equalTo: modelLabel.bottomAnchor, constant: 9),
            divider.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            transcriptScroll.topAnchor.constraint(equalTo: divider.bottomAnchor),
            transcriptScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            transcriptScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // Width pinned to the clip view so wrapping labels lay out against a known width
            // instead of growing horizontally forever.
            transcriptContainer.widthAnchor.constraint(equalTo: transcriptScroll.contentView.widthAnchor),
            transcriptStack.topAnchor.constraint(equalTo: transcriptContainer.topAnchor),
            transcriptStack.leadingAnchor.constraint(equalTo: transcriptContainer.leadingAnchor),
            transcriptStack.trailingAnchor.constraint(equalTo: transcriptContainer.trailingAnchor),
            transcriptStack.bottomAnchor.constraint(equalTo: transcriptContainer.bottomAnchor),
            composer.topAnchor.constraint(equalTo: transcriptScroll.bottomAnchor, constant: 10),
            composer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            composer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            composer.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
        ])

        // The header's token/cost figures come from a store the runner writes to directly, so
        // they need their own refresh signal — a run's usage lands after `.phaseChanged`, not
        // with it.
        usageObserverToken = UsageStore.shared.addChangeObserver { [weak self] in
            self?.refreshModelLabel()
        }
        // History deleted from Preferences tears down the runners this view is projecting, so
        // it has to re-attach — otherwise the transcript on screen outlives its own file.
        NotificationCenter.default.addObserver(
            self, selector: #selector(conversationsDeleted),
            name: HistoryViewController.conversationsDeletedNotification, object: nil
        )

        renderFull()
    }

    deinit {
        if let usageObserverToken { UsageStore.shared.removeChangeObserver(usageObserverToken) }
    }

    /// Same responder-chain lesson Make/Tracks already learned: without explicitly claiming
    /// first responder on appearance, nothing in this stage's hierarchy holds it and
    /// menu-routed actions targeting this controller silently go nowhere.
    override func viewDidAppear() {
        super.viewDidAppear()
        refreshModelLabel()
        composer.focus()
        // Mirrors RunWorkspaceViewController.clearUnseenOutput: becoming visible is what counts
        // as "the human looked at this," clearing the doneUnread badge Tracks would otherwise
        // keep showing for a finished run nobody's actually seen yet.
        runner?.acknowledgeCompletion()
    }

    /// Detaches observation only — the runner itself is untouched and keeps running. A window
    /// closing was never a reason for an agent conversation to stop; that's the whole point of
    /// the runner living on `ProjectContext` instead of on this view.
    func prepareForClose() {
        detach()
    }

    // MARK: - Project/track wiring (ShellViewController calls these)

    func configure(runnerManager: AgentRunnerManager, projectPath: String, trackKey: String?) {
        self.runnerManager = runnerManager
        self.projectPath = projectPath
        attach(trackKey: trackKey)
    }

    /// Cancel-observation → get new runner → rebuild. Deliberately does **not** stop whatever
    /// runner this view was previously attached to — with the loop living on `AgentRunner`
    /// rather than on this view, a track switch no longer has any state here left to wedge.
    func reloadForTrackSwitch(trackKey: String?) {
        attach(trackKey: trackKey)
    }

    private func attach(trackKey: String?) {
        detach()
        attachedTrackKey = trackKey
        if let runnerManager {
            let newRunner = runnerManager.runner(forTrackKey: trackKey ?? "")
            runner = newRunner
            observerToken = newRunner.addObserver { [weak self] event in self?.handle(event) }
        } else {
            runner = nil
        }
        if isViewLoaded {
            renderFull()
            if view.window != nil { runner?.acknowledgeCompletion() }
        }
    }

    private func detach() {
        if let runner, let observerToken { runner.removeObserver(observerToken) }
        observerToken = nil
    }

    // MARK: - Runner events

    private func handle(_ event: AgentRunEvent) {
        switch event {
        case .reset:
            renderFull()
        case .appended(let index):
            appendEntryView(at: index)
        case .updated(let index):
            updateEntryView(at: index)
        case .phaseChanged:
            updateSendButton()
            // A blocked/finished phase change can happen while this stage is the one on screen
            // (a stall firing, a round-trip cap hitting) — same acknowledgement as viewDidAppear,
            // just triggered by the runner instead of by becoming visible. `view.window != nil`
            // is the cheap proxy for "currently on screen": `show(_:)` removes a hidden stage's
            // view from the hierarchy entirely, which clears it.
            if isViewLoaded, view.window != nil { runner?.acknowledgeCompletion() }
        }
    }

    // MARK: - Sending

    private func composerActionTapped() {
        guard let runner else {
            appendLocalNotice("Open a project first — Think conversations belong to a project.")
            return
        }
        if runner.phase == .streaming || runner.phase == .runningTools {
            runner.stop()
            return
        }
        guard runner.phase != .awaitingApproval else { return }
        let text = composer.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        composer.clear()
        runner.send(text)
    }

    private func updateSendButton() {
        let phase = runner?.phase ?? .idle
        composer.setBusy(phase == .streaming || phase == .runningTools)
        let awaitingApproval = phase == .awaitingApproval
        composer.isEnabled = !awaitingApproval
        composer.placeholder = awaitingApproval
            ? "Apply or reject the proposed change above to continue…"
            : "Ask about this project…"
    }

    @objc private func conversationsDeleted() {
        attach(trackKey: attachedTrackKey)
    }

    private func refreshModelLabel() {
        let registry = ProviderRegistryStore.shared
        guard let definition = registry.provider(for: registry.activeProviderId) else { return }
        let modelName = definition.models.first { $0.id == definition.defaultModelId }?.displayName ?? definition.defaultModelId
        var label = "\(definition.displayName) · \(modelName)"
        // What this track has spent so far, right where the model it spent it on is named. Cost
        // is appended only when every model this track used has a published price — a partial
        // figure presented as a total would mislead in exactly the direction that matters.
        if let projectPath {
            let trackKey = attachedTrackKey ?? ""
            let totals = UsageStore.shared.totals(projectPath: projectPath, trackKey: trackKey)
            if totals.totalTokens > 0 {
                label += "  ·  \(UsageFormatting.tokens(totals.totalTokens)) tokens"
                let priced = UsageStore.shared.records.filter {
                    $0.projectPath == projectPath && $0.trackKey == trackKey
                }
                if priced.allSatisfy({ ModelPricing.isPriced(modelId: $0.modelId) }) {
                    let cost = priced.reduce(0.0) { $0 + (ModelPricing.estimatedCost(modelId: $1.modelId, totals: $1.totals) ?? 0) }
                    label += "  ·  ~\(UsageFormatting.cost(cost))"
                }
            }
        }
        modelLabel.stringValue = label
        modelLabel.toolTip = "Estimated spend for this track. Prices are approximate."
    }

    // MARK: - Transcript rendering

    private func renderFull() {
        transcriptStack.arrangedSubviews.forEach {
            transcriptStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        entryViews.removeAll()
        for (index, entry) in (runner?.entries ?? []).enumerated() {
            let view = makeEntryView(entry)
            entryViews.append(view)
            addBlock(view, topSpacing: index == 0 ? 0 : Self.spacing(before: entry.kind))
        }
        emptyStateLabel.isHidden = !(runner?.entries.isEmpty ?? true)
        updateSendButton()
        scrollToBottom()
    }

    private func appendEntryView(at index: Int) {
        guard let entries = runner?.entries, entries.indices.contains(index) else { return }
        guard entryViews.count == index else {
            // Out of sync with the runner (shouldn't happen outside a bug) — safest recovery is
            // a full rebuild rather than rendering into the wrong position.
            renderFull()
            return
        }
        let entry = entries[index]
        let view = makeEntryView(entry)
        entryViews.append(view)
        addBlock(view, topSpacing: index == 0 ? 0 : Self.spacing(before: entry.kind))
        emptyStateLabel.isHidden = true
        // Only live appends animate — `renderFull` (reattach, track switch) lays the whole
        // history out instantly rather than replaying every arrival.
        animateIn(view)
    }

    /// The standard arrival (see `DS.Motion`) over the block's settled Auto Layout position.
    private func animateIn(_ view: NSView) {
        transcriptContainer.layoutSubtreeIfNeeded()
        DS.Motion.appear(view)
    }

    private func updateEntryView(at index: Int) {
        guard let entries = runner?.entries, entries.indices.contains(index), entryViews.indices.contains(index) else { return }
        let entry = entries[index]
        switch entry.kind {
        case .assistantText(let text):
            // Streamed growth glides instead of jumping — a short implicit animation around the
            // re-measure/relayout makes the bubble read as continuously expanding while tokens
            // arrive, which is the whole charm of streaming.
            guard let bubble = (entryViews[index] as? BubbleRowView)?.bubble else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                context.allowsImplicitAnimation = true
                bubble.setBody(text)
                // The whole transcript's layout, not just the bubble's own subtree — the
                // bubble's height growth is meaningless unless the rows below it glide down
                // in the same animation. Animating only the bubble was exactly the "some
                // animation but the bubble itself jumps" complaint.
                self.transcriptContainer.layoutSubtreeIfNeeded()
            }
        case .proposal(let presentation):
            guard let card = entryViews[index] as? ProposedEditView, let resolution = presentation.resolution else { return }
            let label = resolution.label
            card.showResolution(label.text, color: Self.color(for: label.color))
        case .commandProposal(let presentation):
            guard let card = entryViews[index] as? CommandProposalView, let resolution = presentation.resolution else { return }
            Self.showCommandResolution(card, resolution)
        default:
            break // Only streamed assistant text and proposal resolutions mutate in place.
        }
        scrollToBottom()
    }

    /// One `RunTranscriptEntry` → exactly one view. Headers ("You"/"Assistant") aren't a
    /// separate entry — they're drawn as part of the same block as the text they belong to.
    private func makeEntryView(_ entry: RunTranscriptEntry) -> NSView {
        switch entry.kind {
        case .meta(let text):
            return makeLabel(text, font: .systemFont(ofSize: 12), color: .tertiaryLabelColor)
        case .userText(let text):
            // iMessage-shaped: sent messages are solid-accent bubbles hugging their own content
            // against the trailing edge; no "You" header — the side and color carry that.
            let bubble = TextBlockView(style: .sent, body: text, maxBubbleWidth: 460)
            return BubbleRowView(bubble: bubble, alignRight: true)
        case .assistantText(let text):
            let bubble = TextBlockView(style: .received, body: text, maxBubbleWidth: 620)
            return BubbleRowView(bubble: bubble, alignRight: false)
        case .toolCall(let name, let summary):
            return makeLabel("→ \(name)\(summary)", font: .monospacedSystemFont(ofSize: 11, weight: .regular), color: .secondaryLabelColor)
        case .toolResult(let text, let isError):
            return makeLabel(text, font: .monospacedSystemFont(ofSize: 11, weight: .regular), color: isError ? .systemOrange : .secondaryLabelColor)
        case .failure(let text):
            let bubble = TextBlockView(style: .error, body: text, maxBubbleWidth: 620)
            return BubbleRowView(bubble: bubble, alignRight: false)
        case .proposal(let presentation):
            let card = ProposedEditView(edit: presentation.edit, diffText: presentation.diffText)
            if let resolution = presentation.resolution {
                let label = resolution.label
                card.showResolution(label.text, color: Self.color(for: label.color))
            } else {
                let proposalId = entry.id
                card.onApply = { [weak self] in self?.runner?.resolve(proposalId: proposalId, decision: .apply) }
                card.onReject = { [weak self] in self?.runner?.resolve(proposalId: proposalId, decision: .reject) }
            }
            return card
        case .commandProposal(let presentation):
            let card = CommandProposalView(command: presentation.command)
            if let resolution = presentation.resolution {
                Self.showCommandResolution(card, resolution)
            } else {
                let proposalId = entry.id
                card.onApply = { [weak self] in self?.runner?.resolve(proposalId: proposalId, decision: .apply) }
                card.onReject = { [weak self] in self?.runner?.resolve(proposalId: proposalId, decision: .reject) }
            }
            return card
        }
    }

    private static func showCommandResolution(_ card: CommandProposalView, _ resolution: CommandPresentation.Resolution) {
        switch resolution {
        case .executed(let output):
            let preview = output.isEmpty ? "(no output)" : String(output.prefix(300))
            card.showResolution("Ran — \(preview)", color: .systemGreen)
        case .rejected:
            card.showResolution("Rejected", color: .secondaryLabelColor)
        }
    }

    private static func spacing(before kind: RunTranscriptEntry.Kind) -> CGFloat {
        switch kind {
        case .meta, .userText, .assistantText, .proposal, .commandProposal: return 8
        case .toolCall, .toolResult, .failure: return 4
        }
    }

    private static func color(for semantic: ProposalPresentation.ResolutionColor) -> NSColor {
        switch semantic {
        case .success: return .systemGreen
        case .neutral: return .secondaryLabelColor
        case .warning: return .systemOrange
        case .failure: return .systemRed
        }
    }

    /// Rendered directly into the transcript, with no runner behind it — only reachable when no
    /// project is open at all, since `configure` is always called before this stage is visible
    /// once a project exists.
    private func appendLocalNotice(_ text: String) {
        addBlock(makeLabel(text, font: .systemFont(ofSize: 12), color: .tertiaryLabelColor), topSpacing: transcriptStack.arrangedSubviews.isEmpty ? 0 : 8)
    }

    private func makeLabel(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = font
        label.textColor = color
        label.isSelectable = true
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func addBlock(_ view: NSView, topSpacing: CGFloat? = nil) {
        if let topSpacing, let previous = transcriptStack.arrangedSubviews.last {
            transcriptStack.setCustomSpacing(topSpacing, after: previous)
        }
        transcriptStack.addArrangedSubview(view)
        // Full-width blocks: wrapping labels need a definite width to compute their height, and
        // diff cards should span the transcript rather than hug their content.
        view.widthAnchor.constraint(equalTo: transcriptStack.widthAnchor, constant: -(transcriptStack.edgeInsets.left + transcriptStack.edgeInsets.right)).isActive = true
        scrollToBottom()
    }

    private func scrollToBottom() {
        // After the next layout pass, so the newly added block's height is already accounted
        // for — scrolling before layout lands short of the real bottom.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.transcriptContainer.layoutSubtreeIfNeeded()
            let maxY = max(0, self.transcriptContainer.bounds.height - self.transcriptScroll.contentView.bounds.height)
            self.transcriptScroll.contentView.scroll(to: NSPoint(x: 0, y: maxY))
            self.transcriptScroll.reflectScrolledClipView(self.transcriptScroll.contentView)
        }
    }
}

/// One chat bubble, iMessage-shaped: a solid rounded fill hugging its own content, no header —
/// which side it sits on and what color it is carry "who said this." Body text renders through
/// `MarkdownRenderer` (the same one Make's preview uses), and a streamed delta re-measures the
/// bubble's width in place so it grows with the response instead of being sized once.
private final class TextBlockView: NSView {
    enum Style {
        case sent      // the user: accent-filled, white text
        case received  // the assistant: gray-filled, standard text
        case error     // a failure: red-tinted, keeps a small header since it isn't a chat turn

        var fillColor: NSColor {
            switch self {
            case .sent: return .controlAccentColor
            case .received: return DS.Color.bg4
            case .error: return NSColor.systemRed.withAlphaComponent(0.18)
            }
        }
        var textColor: NSColor {
            switch self {
            case .sent: return .white
            case .received: return .labelColor
            case .error: return .systemRed
            }
        }
    }

    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private let style: Style
    private let maxBubbleWidth: CGFloat
    private let bodyWidthConstraint: NSLayoutConstraint
    /// The raw source text (not the rendered `NSAttributedString`) — kept so Copy hands back
    /// what was actually said, not whatever `MarkdownRenderer` happened to produce.
    private(set) var plainText: String = ""

    private static let insets = NSEdgeInsets(top: 7, left: 12, bottom: 8, right: 12)

    init(style: Style, body: String, maxBubbleWidth: CGFloat) {
        self.style = style
        self.maxBubbleWidth = maxBubbleWidth
        self.bodyWidthConstraint = bodyLabel.widthAnchor.constraint(equalToConstant: 10)

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = DS.Radius.bubble
        layer?.backgroundColor = style.fillColor.cgColor

        bodyLabel.isSelectable = true
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false

        var topAnchorForBody = topAnchor
        var topConstant = Self.insets.top
        if case .error = style {
            let headerLabel = NSTextField(labelWithString: "Error")
            headerLabel.font = .systemFont(ofSize: 11, weight: .semibold)
            headerLabel.textColor = .systemRed
            headerLabel.translatesAutoresizingMaskIntoConstraints = false
            addSubview(headerLabel)
            NSLayoutConstraint.activate([
                headerLabel.topAnchor.constraint(equalTo: topAnchor, constant: Self.insets.top),
                headerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.insets.left),
            ])
            topAnchorForBody = headerLabel.bottomAnchor
            topConstant = 3
        }

        addSubview(bodyLabel)
        NSLayoutConstraint.activate([
            bodyLabel.topAnchor.constraint(equalTo: topAnchorForBody, constant: topConstant),
            bodyLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.insets.left),
            bodyLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.insets.right),
            bodyLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.insets.bottom),
            bodyWidthConstraint,
        ])
        setBody(body)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityLabel() -> String? { plainText }
    /// The bubble speaks for its content, so the label inside it must not also be an element —
    /// otherwise VoiceOver reads every message twice (an audit caught exactly that).
    override func accessibilityChildren() -> [Any]? { [] }

    func setBody(_ text: String) {
        plainText = text
        let rendered = NSMutableAttributedString(attributedString: MarkdownRenderer.render(text, baseFont: .systemFont(ofSize: 13), textColor: style.textColor))
        // The renderer terminates every block with "\n\n" — fine in a document preview, but in
        // a bubble that trailing run becomes visible empty space below the last line.
        while rendered.length > 0, let last = rendered.string.last, last.isNewline || last == " " {
            rendered.deleteCharacters(in: NSRange(location: rendered.length - 1, length: 1))
        }
        bodyLabel.attributedStringValue = rendered
        // Hug the content: measure the rendered text against the cap and clamp the label to
        // exactly what it needs — this (re-run on every streamed delta) is what makes a short
        // "ok" a small pill and a long reply a full-width-capped block, live, like a real chat.
        let availableWidth = maxBubbleWidth - Self.insets.left - Self.insets.right
        let bounding = rendered.boundingRect(
            with: NSSize(width: availableWidth, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        bodyWidthConstraint.constant = max(10, min(ceil(bounding.width) + 2, availableWidth))
    }
}

/// A transparent full-width transcript row holding one bubble pinned to its side, plus the
/// hover-revealed Copy affordance sitting *outside* the bubble (inside, it collided with text
/// and got clipped by the bubble's rounded corners) — iMessage's "actions live beside the
/// bubble, not on it" arrangement.
private final class BubbleRowView: NSView {
    let bubble: TextBlockView
    private let copyButton = NSButton(title: "", target: nil, action: nil)
    private var trackingArea: NSTrackingArea?

    init(bubble: TextBlockView, alignRight: Bool) {
        self.bubble = bubble
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(bubble)

        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")?.withSymbolConfiguration(config)
        copyButton.isBordered = false
        copyButton.contentTintColor = .tertiaryLabelColor
        copyButton.alphaValue = 0
        copyButton.target = self
        copyButton.action = #selector(copyTapped)
        copyButton.toolTip = "Copy message"
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(copyButton)

        var constraints = [
            bubble.topAnchor.constraint(equalTo: topAnchor),
            bubble.bottomAnchor.constraint(equalTo: bottomAnchor),
            copyButton.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -6),
            copyButton.widthAnchor.constraint(equalToConstant: 22),
            copyButton.heightAnchor.constraint(equalToConstant: 22),
        ]
        if alignRight {
            constraints += [
                bubble.trailingAnchor.constraint(equalTo: trailingAnchor),
                bubble.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 60),
                copyButton.trailingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: -6),
            ]
        } else {
            constraints += [
                bubble.leadingAnchor.constraint(equalTo: leadingAnchor),
                bubble.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -60),
                copyButton.leadingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: 6),
            ]
        }
        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { copyButton.animator().alphaValue = 1 }
    override func mouseExited(with event: NSEvent) { copyButton.animator().alphaValue = 0 }

    @objc private func copyTapped() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(bubble.plainText, forType: .string)
        // Quick confirmation: the icon crossfades to a green check, then back — the "it worked"
        // beat every copy affordance owes the user.
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            copyButton.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self else { return }
            self.copyButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")?.withSymbolConfiguration(config)
            self.copyButton.contentTintColor = .systemGreen
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                self.copyButton.animator().alphaValue = 1
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
                guard let self else { return }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.15
                    self.copyButton.animator().alphaValue = 0
                } completionHandler: { [weak self] in
                    guard let self else { return }
                    let normalConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
                    self.copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")?.withSymbolConfiguration(normalConfig)
                    self.copyButton.contentTintColor = .tertiaryLabelColor
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.15
                        self.copyButton.animator().alphaValue = 1
                    }
                }
            }
        }
    }
}

/// The chat input: a rounded container that grows with its text (one to six lines), an embedded
/// circular send button that becomes a stop button while the agent is busy, Return to send and
/// Shift-Return for a newline — the input treatment every real chat app trains people to expect,
/// replacing the single-line text field + "Send" push button.
private final class ComposerView: NSView, NSTextViewDelegate {
    /// One handler for the button and Return alike — the owner decides whether that means
    /// send or stop based on the runner's phase.
    var onAction: (() -> Void)?

    private let textView = NSTextView()
    private let scroll = NSScrollView()
    private let placeholderLabel = NSTextField(labelWithString: "")
    private let actionButton = CircularIconButton(diameter: 28)
    private var heightConstraint: NSLayoutConstraint!
    private static let minHeight: CGFloat = 38
    private static let maxHeight: CGFloat = 122

    var text: String { textView.string }

    var placeholder: String = "" {
        didSet { placeholderLabel.stringValue = placeholder }
    }

    var isEnabled: Bool = true {
        didSet {
            textView.isEditable = isEnabled
            actionButton.isEnabled = isEnabled
            alphaValue = isEnabled ? 1 : 0.6
        }
    }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        // A capsule at rest — the radius is half the single-line height, matching the send
        // button's own curvature exactly; grown multiline it becomes a soft rounded rect
        // with the same corner circle.
        layer?.cornerRadius = Self.minHeight / 2
        layer?.borderWidth = 1
        layer?.borderColor = DS.Color.hairline.cgColor
        layer?.backgroundColor = DS.Color.bg1.cgColor

        textView.font = .systemFont(ofSize: 13)
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.delegate = self
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.autoresizingMask = [.width]
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        placeholderLabel.font = .systemFont(ofSize: 13)
        placeholderLabel.textColor = .tertiaryLabelColor
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.lineBreakMode = .byTruncatingTail

        actionButton.backgroundColor = .controlAccentColor
        actionButton.target = self
        actionButton.action = #selector(actionTapped)
        setBusy(false)

        addSubview(scroll)
        addSubview(placeholderLabel)
        addSubview(actionButton)
        heightConstraint = heightAnchor.constraint(equalToConstant: Self.minHeight)
        NSLayoutConstraint.activate([
            heightConstraint,
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: actionButton.leadingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            placeholderLabel.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 2),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: scroll.trailingAnchor),
            placeholderLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            actionButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            actionButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func clear() {
        textView.string = ""
        textDidChange(Notification(name: NSText.didChangeNotification))
    }

    func focus() {
        window?.makeFirstResponder(textView)
    }

    func setBusy(_ busy: Bool) {
        actionButton.setSymbol(busy ? "stop.fill" : "arrow.up", pointSize: 11, weight: .bold, color: .white, accessibilityLabel: busy ? "Stop" : "Send")
    }

    @objc private func actionTapped() { onAction?() }

    func textDidChange(_ notification: Notification) {
        placeholderLabel.isHidden = !textView.string.isEmpty
        guard let layoutManager = textView.layoutManager, let textContainer = textView.textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer).height
        let target = min(max(used + 20, Self.minHeight), Self.maxHeight)
        if heightConstraint.constant != target {
            heightConstraint.constant = target
            scroll.hasVerticalScroller = target >= Self.maxHeight
        }
    }

    /// Return sends, Shift-Return inserts the newline.
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { return false }
        onAction?()
        return true
    }
}
