import AppKit

/// The Appearance pane of Preferences — currently one setting, and the reason `DS.Text` exists:
/// text size.
///
/// macOS has no app-wide Dynamic Type, so an app built on hardcoded point sizes offers someone
/// who needs bigger text nothing at all. This is that recourse.
final class AppearanceViewController: NSViewController {
    private let scalePopup = NSPopUpButton()
    private let sampleLabel = NSTextField(labelWithString: "The quick brown fox jumps over the lazy dog.")
    private let sampleCaption = NSTextField(labelWithString: "Secondary text, captions, and status lines look like this.")
    private let sampleCode = NSTextField(labelWithString: "let sample = \"code and diffs\"")
    private var titleLabel = NSTextField(labelWithString: "Appearance")
    private var scaleLabel = NSTextField(labelWithString: "Text size:")

    override func loadView() { view = NSView() }

    override func viewDidLoad() {
        super.viewDidLoad()

        for scale in DS.Text.Scale.allCases {
            scalePopup.addItem(withTitle: scale.displayName)
            scalePopup.lastItem?.representedObject = scale.rawValue
        }
        scalePopup.selectItem(at: DS.Text.Scale.allCases.firstIndex(of: .current) ?? 0)
        scalePopup.target = self
        scalePopup.action = #selector(scaleChanged)

        let scaleRow = NSStackView(views: [scaleLabel, scalePopup])
        scaleRow.orientation = .horizontal
        scaleRow.spacing = DS.Spacing.m

        let note = NSTextField(wrappingLabelWithString: "Applies to Side's own interface — stage headers, transcripts, diffs, lists, and this window. The editor's and terminal's own text size is set separately, in Make and Run.")
        note.textColor = .tertiaryLabelColor
        note.translatesAutoresizingMaskIntoConstraints = false
        note.widthAnchor.constraint(lessThanOrEqualToConstant: 440).isActive = true

        let samples = NSStackView(views: [sampleLabel, sampleCaption, sampleCode])
        samples.orientation = .vertical
        samples.alignment = .leading
        samples.spacing = DS.Spacing.s
        sampleCaption.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [titleLabel, scaleRow, note, samples])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DS.Spacing.l
        stack.setCustomSpacing(DS.Spacing.section, after: titleLabel)
        stack.setCustomSpacing(DS.Spacing.section, after: note)
        stack.edgeInsets = NSEdgeInsets(top: DS.Spacing.section, left: DS.Spacing.section, bottom: DS.Spacing.section, right: DS.Spacing.section)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor),
            view.widthAnchor.constraint(greaterThanOrEqualToConstant: 520),
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: 320),
        ])

        applyFonts()
        NotificationCenter.default.addObserver(
            self, selector: #selector(applyFonts),
            name: DS.Text.scaleDidChangeNotification, object: nil
        )
    }

    /// The samples are the preview: picking a size and not seeing it is how a settings pane
    /// makes you doubt it did anything.
    @objc private func applyFonts() {
        titleLabel.font = DS.Text.heading(.semibold)
        scaleLabel.font = DS.Text.control()
        sampleLabel.font = DS.Text.body()
        sampleCaption.font = DS.Text.caption()
        sampleCode.font = DS.Text.code()
        (view.subviews.first as? NSStackView)?.layoutSubtreeIfNeeded()
    }

    @objc private func scaleChanged() {
        guard let raw = scalePopup.selectedItem?.representedObject as? Double,
              let scale = DS.Text.Scale(rawValue: raw) else { return }
        DS.Text.Scale.current = scale
    }
}
