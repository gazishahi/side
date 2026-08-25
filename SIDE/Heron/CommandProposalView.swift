import AppKit

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

    private static let destructiveBorderColor = NSColor.systemRed.withAlphaComponent(0.6)
    private static let normalBorderColor = DS.Color.hairline

    init(command: ProposedCommand) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = DS.Radius.card
        layer?.borderWidth = 1
        layer?.backgroundColor = DS.Color.bg1.cgColor

        headerLabel.stringValue = "Run in terminal"
        headerLabel.font = .systemFont(ofSize: 12, weight: .semibold)

        commandLabel.stringValue = command.command
        commandLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        commandLabel.textColor = .labelColor
        commandLabel.isSelectable = true
        commandLabel.translatesAutoresizingMaskIntoConstraints = false

        warningLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        warningLabel.textColor = .systemRed
        warningLabel.translatesAutoresizingMaskIntoConstraints = false

        // Destructive commands never auto-run (see AgentRunner.handleToolOutcomes) and get a
        // visible warning here too — a red border alone is easy to miss scrolling past a
        // transcript; a human still has to read *why* before clicking Run.
        if case .destructive(let reason) = command.riskLevel {
            layer?.borderColor = Self.destructiveBorderColor.cgColor
            warningLabel.stringValue = "⚠︎ \(reason)"
            warningLabel.isHidden = false
        } else {
            layer?.borderColor = Self.normalBorderColor.cgColor
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

        resolutionLabel.font = .systemFont(ofSize: 11, weight: .medium)
        resolutionLabel.isHidden = true

        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.addArrangedSubview(applyButton)
        buttonRow.addArrangedSubview(rejectButton)
        buttonRow.addArrangedSubview(resolutionLabel)
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerLabel)
        addSubview(commandLabel)
        addSubview(warningLabel)
        addSubview(buttonRow)
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
            buttonRow.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
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

    @objc private func applyTapped() { onApply?() }
    @objc private func rejectTapped() { onReject?() }
}
