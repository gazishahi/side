import AppKit
import SideAgents

/// Make's inline instruct (Direction 02 §5.3): select code, ⌘K, say what you want. Not a second
/// agent and not a new loop — a new *entry point* into the track's Think conversation, carrying
/// a pointer to the lines (`@path#L12-L40`), never their text.
enum InlineInstruct {
    enum Verb: Equatable { case change, ask }

    struct Request {
        let verb: Verb
        let instruction: String
        let url: URL
        let relativePath: String
        let lines: ClosedRange<Int>
        /// The diagnostic under the caret, when that's what was pointed at.
        let diagnostic: String?
    }

    /// The message sent to Think. The pointer goes in; the file's contents never do — the agent
    /// reads what it needs, the same design as every `@` mention.
    static func message(for request: Request) -> String {
        let pointer = FileMention.pointer(relativePath: request.relativePath, lines: request.lines)
        let instruction = request.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        var text: String
        switch request.verb {
        case .change: text = "Change \(pointer): \(instruction)"
        case .ask: text = "About \(pointer): \(instruction)"
        }
        if let diagnostic = request.diagnostic, !diagnostic.isEmpty {
            text += "\n\nThe diagnostic there says: \(diagnostic)"
        }
        return text
    }

    /// The pending edit proposal for `relativePath` that arrived after `index` — what Make shows
    /// as a gutter card while Think shows the same proposal as a card of its own.
    static func pendingProposal(forRelativePath relativePath: String, in entries: [RunTranscriptEntry], after index: Int) -> (id: UUID, presentation: ProposalPresentation)? {
        for entry in entries.dropFirst(index) {
            if case .proposal(let presentation) = entry.kind, presentation.edit.relativePath == relativePath,
               presentation.resolution == nil, !presentation.isStreaming {
                return (entry.id, presentation)
            }
        }
        return nil
    }
}

/// The ⌘K popover: one field and two verbs; then, for Ask, the answer in place with
/// "Continue in Agent". Escape closes it (transient popover).
final class InstructPopoverController: NSViewController, NSTextFieldDelegate {
    var onSubmit: ((InlineInstruct.Verb, String) -> Void)?
    var onContinueInThink: (() -> Void)?
    private let field = NSTextField()
    private let stack = NSStackView()
    private let pointer: String

    init(pointer: String) {
        self.pointer = pointer
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 90))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DS.Spacing.m
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor), stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            view.widthAnchor.constraint(equalToConstant: 380),
        ])
        showInput()
    }

    private func reset() { stack.arrangedSubviews.forEach { $0.removeFromSuperview() } }

    private func caption(_ text: String, code: Bool = false) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = code ? DS.Text.code(11, weight: .regular) : DS.Text.caption()
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        return label
    }

    private func showInput() {
        reset()
        stack.addArrangedSubview(caption(pointer, code: true))
        field.placeholderString = "Describe a change, or ask about it"
        field.delegate = self
        field.setAccessibilityLabel("Instruction")
        stack.addArrangedSubview(field)
        field.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        let change = NSButton(title: "Change", target: self, action: #selector(changeTapped))
        change.keyEquivalent = "\r"
        // One default button: ⌥⏎ reaches Ask through the field, not a second Return equivalent.
        let ask = NSButton(title: "Ask", target: self, action: #selector(askTapped))
        let hint = caption("⏎ Change · ⌥⏎ Ask")
        hint.textColor = .tertiaryLabelColor
        let row = NSStackView(views: [hint, NSView(), ask, change])
        row.orientation = .horizontal
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        view.window?.makeFirstResponder(field)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(field)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
            submit(.ask)
            return true
        }
        return false
    }

    @objc private func changeTapped() { submit(.change) }
    @objc private func askTapped() { submit(.ask) }

    private func submit(_ verb: InlineInstruct.Verb) {
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { NSSound.beep(); return }
        onSubmit?(verb, text)
    }

    /// Ask was sent; the answer is on its way.
    func showWaiting() {
        reset()
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        let row = NSStackView(views: [spinner, caption("Asking in Agent…")])
        row.orientation = .horizontal
        stack.addArrangedSubview(row)
    }

    func showAnswer(_ text: String) {
        reset()
        let body = NSTextView()
        body.isEditable = false
        body.drawsBackground = false
        body.textStorage?.setAttributedString(MarkdownRenderer.render(text, baseFont: DS.Text.body(), textColor: .labelColor))
        body.textContainerInset = .zero
        body.textContainer?.lineFragmentPadding = 0
        body.isVerticallyResizable = true
        body.autoresizingMask = [.width]
        let scroll = NSScrollView()
        scroll.documentView = body
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let height = min(320, ceil(body.attributedString().boundingRect(with: NSSize(width: 356, height: CGFloat.greatestFiniteMagnitude), options: .usesLineFragmentOrigin).height) + 8)
        scroll.heightAnchor.constraint(equalToConstant: max(40, height)).isActive = true
        stack.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        let cont = NSButton(title: "Continue in Agent", target: self, action: #selector(continueTapped))
        cont.isBordered = false
        cont.attributedTitle = NSAttributedString(string: "Continue in Agent", attributes: [.font: DS.Text.caption(.medium), .foregroundColor: NSColor.labelColor])
        let row = NSStackView(views: [NSView(), cont])
        row.orientation = .horizontal
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
    }

    func showProblem(_ text: String) {
        reset()
        stack.addArrangedSubview(caption(text))
    }

    @objc private func continueTapped() { onContinueInThink?() }
}

/// A compact card beside the lines a Change was asked about: the proposal Think is also
/// showing, decided here or there — Apply goes through the same `ProposedEditApplier` path.
final class InstructProposalCard: NSView {
    var onApply: (() -> Void)?
    var onReject: (() -> Void)?
    var onOpenInThink: (() -> Void)?
    let proposalId: UUID

    init(proposalId: UUID, added: Int, removed: Int) {
        self.proposalId = proposalId
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = DS.Radius.surface
        bindLayerBackground(DS.Color.raised)
        shadow = NSShadow()
        layer?.shadowOpacity = 0.12
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        let title = NSTextField(labelWithString: "")
        let text = NSMutableAttributedString(string: "Proposed change  ", attributes: [.font: DS.Text.caption(.semibold), .foregroundColor: NSColor.labelColor])
        text.append(NSAttributedString(string: "+\(added)", attributes: [.font: DS.Text.code(11, weight: .medium), .foregroundColor: DS.Color.statusVerified]))
        text.append(NSAttributedString(string: " \u{2212}\(removed)", attributes: [.font: DS.Text.code(11, weight: .medium), .foregroundColor: DS.Color.statusFailed]))
        title.attributedStringValue = text
        func action(_ name: String, _ selector: Selector, emphasized: Bool) -> NSButton {
            let button = NSButton(title: name, target: self, action: selector)
            button.isBordered = false
            button.attributedTitle = NSAttributedString(string: name, attributes: [.font: DS.Text.caption(emphasized ? .semibold : .regular), .foregroundColor: emphasized ? NSColor.labelColor : NSColor.secondaryLabelColor])
            return button
        }
        let row = NSStackView(views: [title, NSView(), action("Open in Agent", #selector(openTapped), emphasized: false), action("Reject", #selector(rejectTapped), emphasized: false), action("Apply", #selector(applyTapped), emphasized: true)])
        row.orientation = .horizontal
        row.spacing = DS.Spacing.l
        row.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Proposed change, \(added) lines added, \(removed) removed")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func applyTapped() { onApply?() }
    @objc private func rejectTapped() { onReject?() }
    @objc private func openTapped() { onOpenInThink?() }
}
