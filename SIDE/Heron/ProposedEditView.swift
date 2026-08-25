import AppKit

/// Inline review card for one proposed edit, shown in the Think transcript. Deliberately not a
/// separate window or sheet: the decision belongs next to the conversation that produced it, and
/// a modal would make a multi-file change a series of interruptions rather than a review.
final class ProposedEditView: NSView {
    var onApply: (() -> Void)?
    var onReject: (() -> Void)?

    private let headerLabel = NSTextField(labelWithString: "")
    private let diffView = NSTextView()
    private let diffScroll = NSScrollView()
    private let applyButton = NSButton(title: "Apply", target: nil, action: nil)
    private let rejectButton = NSButton(title: "Reject", target: nil, action: nil)
    private let resolutionLabel = NSTextField(labelWithString: "")
    private let buttonRow = NSStackView()

    private static let addedColor = NSColor(red: 0.45, green: 0.82, blue: 0.55, alpha: 1)
    private static let removedColor = NSColor(red: 0.92, green: 0.50, blue: 0.48, alpha: 1)
    private static let hunkColor = NSColor(red: 0.55, green: 0.72, blue: 0.95, alpha: 1)

    init(edit: ProposedEdit, diffText: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 0.28, alpha: 1).cgColor
        layer?.backgroundColor = NSColor(white: 0.13, alpha: 1).cgColor

        let action = edit.isNewFile ? "Create" : "Edit"
        let delta = edit.addedLineCount
        let deltaText = delta == 0 ? "" : (delta > 0 ? "  +\(delta) lines" : "  \(delta) lines")
        headerLabel.stringValue = "\(action) \(edit.relativePath)\(deltaText)"
        headerLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        headerLabel.lineBreakMode = .byTruncatingMiddle

        diffView.isEditable = false
        diffView.drawsBackground = false
        diffView.textContainerInset = NSSize(width: 8, height: 6)
        diffView.textStorage?.setAttributedString(Self.attributedDiff(diffText))
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
        let contentHeight = diffView.attributedString().boundingRect(with: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude), options: .usesLineFragmentOrigin).height + 16
        diffScroll.heightAnchor.constraint(equalToConstant: min(max(contentHeight, 40), 260)).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Called once the decision is made — the card stays in the transcript as a record of what
    /// was proposed and what the human decided, rather than vanishing.
    func showResolution(_ text: String, color: NSColor) {
        applyButton.isHidden = true
        rejectButton.isHidden = true
        resolutionLabel.stringValue = text
        resolutionLabel.textColor = color
        resolutionLabel.isHidden = false
    }

    @objc private func applyTapped() { onApply?() }
    @objc private func rejectTapped() { onReject?() }

    private static func attributedDiff(_ diffText: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        for (index, line) in diffText.components(separatedBy: "\n").enumerated() {
            let color: NSColor
            if line.hasPrefix("+") {
                color = addedColor
            } else if line.hasPrefix("-") {
                color = removedColor
            } else if line.hasPrefix("@@") {
                color = hunkColor
            } else {
                color = .secondaryLabelColor
            }
            let prefix = index == 0 ? "" : "\n"
            result.append(NSAttributedString(string: prefix + line, attributes: [.font: font, .foregroundColor: color]))
        }
        return result
    }
}
