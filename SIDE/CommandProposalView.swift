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

    init(command: ProposedCommand) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = DS.Radius.surface
        bindLayerBackground(DS.Color.raised)
        // A named task says what it *is*, not just what it runs — "Run the test task" is a
        // decision the user can make at a glance; a command line is something they have to
        // parse first. The command itself stays visible below either way.
        headerLabel.stringValue = command.fetchURL != nil
            ? "Fetch a web page"
            : (command.taskName.map { "Run the \($0) task" } ?? "Run in terminal")
        headerLabel.font = DS.Text.body(.semibold)

        commandLabel.stringValue = command.command
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
        if case .destructive(let reason) = command.riskLevel {
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
