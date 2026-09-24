import AppKit
import Heron

/// The Appearance pane of Preferences — currently one setting, and the reason `DS.Text` exists:
/// text size.
///
/// macOS has no app-wide Dynamic Type, so an app built on hardcoded point sizes offers someone
/// who needs bigger text nothing at all. This is that recourse.
final class AppearanceViewController: NSViewController {
    private let scalePopup = NSPopUpButton()
    private let themePopup = NSPopUpButton()
    private let sampleLabel = NSTextField(labelWithString: "The quick brown fox jumps over the lazy dog.")
    private let sampleCaption = NSTextField(labelWithString: "Secondary text, captions, and status lines look like this.")
    private let sampleCode = NSTextField(labelWithString: "let sample = \"code and diffs\"")
    private var titleLabel = NSTextField(labelWithString: "Appearance")
    private var scaleLabel = NSTextField(labelWithString: "Text size:")
    private let editorSizePopup = NSPopUpButton()
    private let terminalSizePopup = NSPopUpButton()

    override func loadView() { view = NSView() }

    @objc private func themeChanged() {
        guard let raw = themePopup.selectedItem?.representedObject as? String,
              let preference = DS.Appearance.Preference(rawValue: raw) else { return }
        DS.Appearance.preference = preference
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        for scale in DS.Text.Scale.allCases {
            scalePopup.addItem(withTitle: scale.displayName)
            scalePopup.lastItem?.representedObject = scale.rawValue
        }
        scalePopup.selectItem(at: DS.Text.Scale.allCases.firstIndex(of: .current) ?? 0)
        scalePopup.target = self
        scalePopup.action = #selector(scaleChanged)

        for preference in DS.Appearance.Preference.allCases {
            themePopup.addItem(withTitle: preference.displayName)
            themePopup.lastItem?.representedObject = preference.rawValue
        }
        themePopup.selectItem(at: DS.Appearance.Preference.allCases.firstIndex(of: DS.Appearance.preference) ?? 0)
        themePopup.target = self
        themePopup.action = #selector(themeChanged)
        let themeRow = NSStackView(views: [NSTextField(labelWithString: "Appearance:"), themePopup])
        themeRow.orientation = .horizontal
        themeRow.spacing = DS.Spacing.m

        let scaleRow = NSStackView(views: [scaleLabel, scalePopup])
        scaleRow.orientation = .horizontal
        scaleRow.spacing = DS.Spacing.m

        for (popup, current, action) in [(editorSizePopup, DS.Text.CodeSize.editor, #selector(editorSizeChanged)), (terminalSizePopup, DS.Text.CodeSize.terminal, #selector(terminalSizeChanged))] {
            for size in DS.Text.CodeSize.choices {
                popup.addItem(withTitle: "\(Int(size)) pt")
                popup.lastItem?.representedObject = Double(size)
            }
            popup.selectItem(at: DS.Text.CodeSize.choices.firstIndex(of: current) ?? DS.Text.CodeSize.choices.firstIndex(of: DS.Text.CodeSize.standard) ?? 0)
            popup.target = self
            popup.action = action
        }
        let editorRow = NSStackView(views: [NSTextField(labelWithString: "Editor text:"), editorSizePopup])
        editorRow.orientation = .horizontal
        editorRow.spacing = DS.Spacing.m
        let terminalRow = NSStackView(views: [NSTextField(labelWithString: "Terminal text:"), terminalSizePopup])
        terminalRow.orientation = .horizontal
        terminalRow.spacing = DS.Spacing.m

        let note = NSTextField(wrappingLabelWithString: "Text size applies to Side's own interface: stage headers, transcripts, diffs, lists, and this window. The editor and terminal have their own sizes.")
        note.textColor = .tertiaryLabelColor
        note.translatesAutoresizingMaskIntoConstraints = false
        note.widthAnchor.constraint(lessThanOrEqualToConstant: 440).isActive = true

        let samples = NSStackView(views: [sampleLabel, sampleCaption, sampleCode])
        samples.orientation = .vertical
        samples.alignment = .leading
        samples.spacing = DS.Spacing.s
        sampleCaption.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [titleLabel, themeRow, scaleRow, editorRow, terminalRow, note, samples])
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
        scaleLabel.font = DS.Text.body()
        sampleLabel.font = DS.Text.body()
        sampleCaption.font = DS.Text.caption()
        sampleCode.font = DS.Text.code()
        (view.subviews.first as? NSStackView)?.layoutSubtreeIfNeeded()
    }

    @objc private func editorSizeChanged() {
        guard let size = editorSizePopup.selectedItem?.representedObject as? Double else { return }
        DS.Text.CodeSize.editor = CGFloat(size)
    }

    @objc private func terminalSizeChanged() {
        guard let size = terminalSizePopup.selectedItem?.representedObject as? Double else { return }
        DS.Text.CodeSize.terminal = CGFloat(size)
    }

    @objc private func scaleChanged() {
        guard let raw = scalePopup.selectedItem?.representedObject as? Double,
              let scale = DS.Text.Scale(rawValue: raw) else { return }
        DS.Text.Scale.current = scale
    }
}
