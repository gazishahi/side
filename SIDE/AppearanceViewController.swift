import AppKit
import Heron

/// The Appearance pane of Preferences: light or dark, text sizes, and typefaces.
///
/// macOS has no app-wide Dynamic Type, so an app built on hardcoded point sizes offers someone
/// who needs bigger text nothing at all. This is that recourse.
final class AppearanceViewController: NSViewController {
    private let scalePopup = NSPopUpButton()
    private let themePopup = NSPopUpButton()
    private let sampleLabel = NSTextField(labelWithString: "The quick brown fox jumps over the lazy dog.")
    private let sampleCaption = NSTextField(labelWithString: "Secondary text, captions, and status lines look like this.")
    private let sampleCode = NSTextField(labelWithString: "let sample = \"code and diffs\"")
    private let editorSizePopup = NSPopUpButton()
    private let terminalSizePopup = NSPopUpButton()
    private var fontPopups: [DS.Text.Fonts.Role: NSPopUpButton] = [:]
    /// The editor theme for light and for dark appearance, and removing an imported one.
    private let lightThemePopup = NSPopUpButton()
    private let darkThemePopup = NSPopUpButton()
    private let removeThemePopup = NSPopUpButton()

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
        for (popup, current, action) in [(editorSizePopup, DS.Text.CodeSize.editor, #selector(editorSizeChanged)), (terminalSizePopup, DS.Text.CodeSize.terminal, #selector(terminalSizeChanged))] {
            for size in DS.Text.CodeSize.choices {
                popup.addItem(withTitle: "\(Int(size)) pt")
                popup.lastItem?.representedObject = Double(size)
            }
            popup.selectItem(at: DS.Text.CodeSize.choices.firstIndex(of: current) ?? DS.Text.CodeSize.choices.firstIndex(of: DS.Text.CodeSize.standard) ?? 0)
            popup.target = self
            popup.action = action
        }

        // Typefaces: code families for the editor and the terminal, any family for reading.
        for role in DS.Text.Fonts.Role.allCases {
            let popup = NSPopUpButton()
            let defaultName: String
            switch role {
            case .editor: defaultName = "SF Mono"
            case .terminal: defaultName = NSFont(name: "MesloLGS-NF-Regular", size: 12) != nil ? "Meslo Nerd Font" : "SF Mono"
            case .reading: defaultName = "New York"
            }
            popup.addItem(withTitle: "Default (\(defaultName))")
            popup.menu?.addItem(.separator())
            var families = role == .reading ? DS.Text.Fonts.allFamilies() : DS.Text.Fonts.monospacedFamilies()
            if role == .reading { families.insert(contentsOf: ["SF Pro"].filter { !families.contains($0) }, at: 0) }
            for family in families {
                popup.addItem(withTitle: family)
                popup.lastItem?.representedObject = family
            }
            if let chosen = DS.Text.Fonts.family(role), let item = popup.itemArray.first(where: { $0.representedObject as? String == chosen }) {
                popup.select(item)
            } else {
                popup.selectItem(at: 0)
            }
            popup.target = self
            popup.action = #selector(fontChanged(_:))
            popup.tag = DS.Text.Fonts.Role.allCases.firstIndex(of: role)!
            fontPopups[role] = popup
        }

        let samples = NSStackView(views: [sampleLabel, sampleCaption, sampleCode])
        samples.orientation = .vertical
        samples.alignment = .leading
        samples.spacing = DS.Spacing.s
        sampleCaption.textColor = .secondaryLabelColor

        let page = SettingsForm.page([
            SettingsSplitViewController.hero(.appearance),
            SettingsForm.section([
                SettingsForm.row("Appearance", themePopup),
                SettingsForm.row("Text size", detail: "Side's own interface: stage headers, transcripts, diffs, lists, and this window.", scalePopup),
            ]),
            SettingsForm.section("Code", [
                SettingsForm.row("Editor text", editorSizePopup),
                SettingsForm.row("Terminal text", terminalSizePopup),
            ]),
            SettingsForm.section("Editor theme", footer: "Colors the editor, Review's diffs and the terminal. Import a VS Code theme's .json (from an extension, or a theme's repository); its token colors are matched to Side's syntax.", [
                SettingsForm.row("In light appearance", lightThemePopup),
                SettingsForm.row("In dark appearance", darkThemePopup),
                SettingsForm.row("Import a VS Code theme", SettingsForm.button("Import\u{2026}", self, #selector(importTheme))),
                SettingsForm.row("Remove an imported theme", removeThemePopup),
            ]),
            SettingsForm.section("Fonts", [
                SettingsForm.row("Editor", fontPopups[.editor]!),
                SettingsForm.row("Terminal", fontPopups[.terminal]!),
                SettingsForm.row("Reading", detail: "Markdown previews.", fontPopups[.reading]!),
            ]),
            SettingsForm.section("Preview", [SettingsForm.content(samples)]),
        ])
        SettingsForm.install(page, in: view)

        fillThemePopups()
        NotificationCenter.default.addObserver(self, selector: #selector(fillThemePopups), name: EditorThemes.didChangeNotification, object: nil)
        applyFonts()
        NotificationCenter.default.addObserver(
            self, selector: #selector(applyFonts),
            name: DS.Text.scaleDidChangeNotification, object: nil
        )
    }

    /// The samples are the preview: picking a size and not seeing it is how a settings pane
    /// makes you doubt it did anything.
    @objc private func applyFonts() {
        sampleLabel.font = DS.Text.body()
        sampleCaption.font = DS.Text.caption()
        sampleCode.font = DS.Text.Fonts.font(.editor, size: DS.Text.code().pointSize)
        view.layoutSubtreeIfNeeded()
    }

    // MARK: Editor theme

    @objc private func fillThemePopups() {
        for (popup, current, action) in [(lightThemePopup, EditorThemes.lightThemeID, #selector(lightThemeChosen(_:))),
                                         (darkThemePopup, EditorThemes.darkThemeID, #selector(darkThemeChosen(_:)))] {
            popup.removeAllItems()
            popup.addItem(withTitle: "Side")
            popup.lastItem?.representedObject = EditorThemes.sideID
            popup.menu?.addItem(.separator())
            for theme in EditorThemes.all {
                popup.addItem(withTitle: theme.name + (theme.isDark ? " (dark)" : " (light)"))
                popup.lastItem?.representedObject = theme.id
            }
            popup.select(popup.itemArray.first { $0.representedObject as? String == current } ?? popup.item(at: 0))
            popup.target = self
            popup.action = action
        }
        removeThemePopup.removeAllItems()
        removeThemePopup.addItem(withTitle: EditorThemes.imported.isEmpty ? "None imported" : "Choose\u{2026}")
        for theme in EditorThemes.imported {
            removeThemePopup.addItem(withTitle: theme.name)
            removeThemePopup.lastItem?.representedObject = theme.id
        }
        removeThemePopup.isEnabled = !EditorThemes.imported.isEmpty
        removeThemePopup.target = self
        removeThemePopup.action = #selector(removeTheme(_:))
    }

    @objc private func lightThemeChosen(_ sender: NSPopUpButton) {
        if let id = sender.selectedItem?.representedObject as? String { EditorThemes.lightThemeID = id }
    }

    @objc private func darkThemeChosen(_ sender: NSPopUpButton) {
        if let id = sender.selectedItem?.representedObject as? String { EditorThemes.darkThemeID = id }
    }

    @objc private func removeTheme(_ sender: NSPopUpButton) {
        guard let id = sender.selectedItem?.representedObject as? String else { return }
        EditorThemes.remove(id)
    }

    /// A VS Code theme's .json, imported and chosen for its own appearance.
    @objc private func importTheme() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "Choose a VS Code color theme (.json)"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let theme = try EditorThemes.importVSCodeTheme(Data(contentsOf: url), fallbackName: url.deletingPathExtension().lastPathComponent)
                if theme.isDark { EditorThemes.darkThemeID = theme.id } else { EditorThemes.lightThemeID = theme.id }
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn't import \u{201C}\(url.lastPathComponent)\u{201D}"
                alert.informativeText = error.localizedDescription
                alert.beginSheetModal(for: window)
            }
        }
    }

    @objc private func fontChanged(_ sender: NSPopUpButton) {
        let role = DS.Text.Fonts.Role.allCases[sender.tag]
        DS.Text.Fonts.setFamily(sender.selectedItem?.representedObject as? String, for: role)
        applyFonts()
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
