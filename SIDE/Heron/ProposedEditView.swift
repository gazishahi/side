import AppKit

/// Inline review card for one proposed edit, shown in the Think transcript. Deliberately not a
/// separate window or sheet: the decision belongs next to the conversation that produced it, and
/// a modal would make a multi-file change a series of interruptions rather than a review.
final class ProposedEditView: NSView {
    var onApply: (() -> Void)?
    var onReject: (() -> Void)?

    private let headerLabel = NSTextField(labelWithString: "")
    private let diffView = DiffBody.makeBodyTextView()
    private let diffScroll = NSScrollView()
    private let applyButton = NSButton(title: "Apply", target: nil, action: nil)
    private let rejectButton = NSButton(title: "Reject", target: nil, action: nil)
    private let resolutionLabel = NSTextField(labelWithString: "")
    private let buttonRow = NSStackView()

    /// Height of the diff box. Mutable because a streaming preview's body grows as the model
    /// writes: pinned at init, the card was sized for the first fragment that arrived and then
    /// clipped everything after it.
    private var diffHeight: NSLayoutConstraint!
    private let progressIndicator = NSProgressIndicator()

    init(edit: ProposedEdit, diffText: String, isStreaming: Bool = false) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = DS.Radius.card
        layer?.borderWidth = 1
        bindLayerBorder(DS.Color.hairline)
        bindLayerBackground(DS.Color.bg1)
        headerLabel.stringValue = Self.headerText(for: edit, isStreaming: isStreaming)
        headerLabel.font = DS.Text.control(.semibold)
        headerLabel.lineBreakMode = .byTruncatingMiddle

        // Same renderer as Review's per-file cards — line-number gutters and full-line tints,
        // so a proposal's diff reads identically to the diff the track's Review shows later.
        DiffBody.fill(diffView, hunks: UnifiedDiff.parseHunks(diffText))
        diffScroll.documentView = diffView
        diffScroll.drawsBackground = false
        diffScroll.hasVerticalScroller = true
        diffScroll.translatesAutoresizingMaskIntoConstraints = false

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

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false

        buttonRow.orientation = .horizontal
        buttonRow.spacing = DS.Spacing.m
        buttonRow.addArrangedSubview(progressIndicator)
        buttonRow.addArrangedSubview(applyButton)
        buttonRow.addArrangedSubview(rejectButton)
        buttonRow.addArrangedSubview(resolutionLabel)
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerLabel)
        addSubview(diffScroll)
        addSubview(buttonRow)
        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            headerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            headerLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            diffScroll.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 8),
            diffScroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            diffScroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            diffScroll.heightAnchor.constraint(lessThanOrEqualToConstant: 260),
            buttonRow.topAnchor.constraint(equalTo: diffScroll.bottomAnchor, constant: 8),
            buttonRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            buttonRow.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        // Grows with content up to the scroll cap above, so a one-line change doesn't get a
        // 260pt box and a large change doesn't push the conversation off screen.
        diffHeight = diffScroll.heightAnchor.constraint(equalToConstant: measuredDiffHeight())
        diffHeight.isActive = true

        // No decision while the arguments are still arriving: what's on screen is text in
        // flight, not a validated proposal, and Apply would be asking the user to approve half a
        // sentence. The spinner is the card saying so.
        if isStreaming { setStreaming(true) }
    }

    private static func headerText(for edit: ProposedEdit, isStreaming: Bool) -> String {
        // No line count while streaming: `addedLineCount` is computed against a `baseContent` the
        // preview doesn't have yet, so it would count the whole file as added and then jump.
        guard !isStreaming else {
            return "\(edit.isNewFile ? "Creating" : "Writing") \(edit.relativePath)…"
        }
        let action = edit.isNewFile ? "Create" : "Edit"
        let delta = edit.addedLineCount
        let deltaText = delta == 0 ? "" : (delta > 0 ? "  +\(delta) lines" : "  \(delta) lines")
        return "\(action) \(edit.relativePath)\(deltaText)"
    }

    private func measuredDiffHeight() -> CGFloat {
        let bounding = diffView.attributedString().boundingRect(
            with: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude),
            options: .usesLineFragmentOrigin
        )
        return min(max(bounding.height + 16, 40), 260)
    }

    private func setStreaming(_ streaming: Bool) {
        applyButton.isHidden = streaming
        rejectButton.isHidden = streaming
        if streaming { progressIndicator.startAnimation(nil) } else { progressIndicator.stopAnimation(nil) }
    }

    /// A new fragment of the body arrived, or the real diff replaced the preview. Called on every
    /// refresh, so it does the minimum: refill the text and re-measure the box.
    func update(edit: ProposedEdit, diffText: String, isStreaming: Bool) {
        headerLabel.stringValue = Self.headerText(for: edit, isStreaming: isStreaming)
        DiffBody.fill(diffView, hunks: UnifiedDiff.parseHunks(diffText))
        diffHeight.constant = measuredDiffHeight()
        setStreaming(isStreaming)
        // Streaming previews scroll themselves to the newest line — the interesting end of a file
        // being written is the bottom, the same reason a terminal follows its own output.
        if isStreaming { diffView.scrollToEndOfDocument(nil) }
    }

    /// Turns the card into a live proposal once its arguments finished arriving and the executor
    /// accepted them.
    func enableDecision() {
        setStreaming(false)
        resolutionLabel.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Called once the decision is made — the card stays in the transcript as a record of what
    /// was proposed and what the human decided, rather than vanishing.
    func showResolution(_ text: String, color: NSColor) {
        setStreaming(false)
        applyButton.isHidden = true
        rejectButton.isHidden = true
        resolutionLabel.stringValue = text
        resolutionLabel.textColor = color
        resolutionLabel.isHidden = false
    }

    @objc private func applyTapped() { onApply?() }
    @objc private func rejectTapped() { onReject?() }

}
