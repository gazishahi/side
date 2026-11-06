import AppKit
import SideAgents

/// The Appearance pane of Preferences: light or dark, text sizes, and typefaces, with a live
/// preview beside them (SIDE_DESIGN_POLISH_0.5.md §5: form + preview, the one pane whose
/// settings you judge by looking).
///
/// macOS has no app-wide Dynamic Type, so an app built on hardcoded point sizes offers someone
/// who needs bigger text nothing at all. This is that recourse.
final class AppearanceViewController: NSViewController {
    private let preview = AppearancePreview()
    private let scalePopup = NSPopUpButton()
    private let themePopup = NSPopUpButton()
    private let sampleLabel = NSTextField(labelWithString: "The quick brown fox jumps over the lazy dog.")
    private let sampleCaption = NSTextField(labelWithString: "Secondary text, captions, and status lines look like this.")
    private let editorSizePopup = NSPopUpButton()
    private let terminalSizePopup = NSPopUpButton()
    private var fontPopups: [DS.Text.Fonts.Role: NSPopUpButton] = [:]
    /// The editor theme for light and for dark appearance, and removing an imported one.
    private let lightThemePopup = NSPopUpButton()
    private let darkThemePopup = NSPopUpButton()
    private let removeThemePopup = NSPopUpButton()
    /// Liquid Glass or solid surfaces; applies on restart, hence the button beside it.
    private let surfacesPopup = NSPopUpButton()
    /// Beside the popup once the choice differs from what's drawn. (A row of its own, hidden,
    /// still left its gap in the card.)
    private lazy var restartButton = SettingsForm.button("Restart Side", self, #selector(restartForSurfaces))

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

        for (mode, title) in [(DS.Surfaces.glass, "Liquid Glass"), (.solid, "Solid")] {
            surfacesPopup.addItem(withTitle: title)
            surfacesPopup.lastItem?.representedObject = mode.rawValue
        }
        surfacesPopup.selectItem(at: DS.Surfaces.chosen == .solid ? 1 : 0)
        surfacesPopup.target = self
        surfacesPopup.action = #selector(surfacesChanged)
        surfacesPopup.setAccessibilityLabel("Surfaces")
        refreshRestartButton()

        let samples = NSStackView(views: [sampleLabel, sampleCaption])
        sampleLabel.lineBreakMode = .byTruncatingTail
        sampleCaption.lineBreakMode = .byTruncatingTail
        for label in [sampleLabel, sampleCaption] { label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        samples.orientation = .vertical
        samples.alignment = .leading
        samples.spacing = DS.Spacing.s
        sampleCaption.textColor = .secondaryLabelColor

        let page = SettingsForm.page([
            SettingsSplitViewController.hero(.appearance),
            SettingsForm.section([
                SettingsForm.row("Appearance", themePopup),
                SettingsForm.row("Text size", detail: "Side's own interface: stage headers, transcripts, diffs, lists, and this window.", scalePopup),
            ] + surfacesRows()),
            SettingsForm.section("Code", [
                SettingsForm.row("Editor text", editorSizePopup),
                SettingsForm.row("Terminal text", terminalSizePopup),
            ]),
            SettingsForm.section("Editor theme", footer: "Colors the editor, the diffs in Changes and the terminal. Import a VS Code theme's .json (from an extension, or a theme's repository); its token colors are matched to Side's syntax.", [
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
        ])
        preview.interfaceSamples = samples
        let split = NSView()
        for part in [page, preview] {
            part.translatesAutoresizingMaskIntoConstraints = false
            split.addSubview(part)
        }
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: split.topAnchor),
            page.bottomAnchor.constraint(equalTo: split.bottomAnchor),
            page.leadingAnchor.constraint(equalTo: split.leadingAnchor),
            // The two share the width, the settings a little more; neither has a fixed size.
            page.widthAnchor.constraint(greaterThanOrEqualToConstant: SettingsForm.minColumnWidth + SettingsForm.pageInset * 2),
            { let share = page.widthAnchor.constraint(equalTo: split.widthAnchor, multiplier: 0.55); share.priority = .defaultHigh; return share }(),
            // Under the title bar, where the settings column's scroll view starts its content.
            preview.topAnchor.constraint(equalTo: split.safeAreaLayoutGuide.topAnchor, constant: SettingsForm.pageInset - 4),
            preview.leadingAnchor.constraint(equalTo: page.trailingAnchor),
            preview.trailingAnchor.constraint(equalTo: split.trailingAnchor, constant: -SettingsForm.pageInset),
            preview.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
            preview.bottomAnchor.constraint(lessThanOrEqualTo: split.bottomAnchor, constant: -SettingsForm.pageInset),
        ])
        SettingsForm.install(split, in: view)

        fillThemePopups()
        NotificationCenter.default.addObserver(self, selector: #selector(fillThemePopups), name: EditorThemes.didChangeNotification, object: nil)
        applyFonts()
        // The samples set their own size; the rest of the pane follows with everything else.
        TextScaleFollower.exempt(sampleLabel)
        TextScaleFollower.exempt(sampleCaption)
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
        preview.refresh()
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

    /// Surfaces exist to choose only where there's Liquid Glass to turn off (macOS 26).
    private func surfacesRows() -> [NSView] {
        guard #available(macOS 26.0, *) else { return [] }
        return [
            SettingsForm.row("Surfaces", detail: "Solid surfaces blur nothing behind them, so scrolling takes less of the GPU. Applies on restart; your terminals carry on.", surfacesAccessory()),
        ]
    }

    private func surfacesAccessory() -> NSView {
        let row = NSStackView(views: [restartButton, surfacesPopup])
        row.orientation = .horizontal
        row.spacing = DS.Spacing.s
        row.detachesHiddenViews = true
        for view in [row, restartButton, surfacesPopup] as [NSView] { view.setContentHuggingPriority(.required, for: .horizontal) }
        return row
    }

    @objc private func surfacesChanged() {
        guard let raw = surfacesPopup.selectedItem?.representedObject as? String, let mode = DS.Surfaces(rawValue: raw) else { return }
        DS.Surfaces.chosen = mode
        refreshRestartButton()
    }

    private func refreshRestartButton() {
        restartButton.isHidden = DS.Surfaces.chosen == DS.Surfaces.current
    }

    @objc private func restartForSurfaces() { AppDelegate.shared?.relaunch() }

    @objc private func scaleChanged() {
        guard let raw = scalePopup.selectedItem?.representedObject as? Double,
              let scale = DS.Text.Scale(rawValue: raw) else { return }
        DS.Text.Scale.current = scale
    }
}

/// Appearance's live preview: the editor in its theme, font and size, a terminal in its own,
/// and Side's interface text. Every choice on the left shows here as it's made.
@MainActor
final class AppearancePreview: NSView {
    private let editor = NSTextField(labelWithString: "")
    private let gutter = NSTextField(labelWithString: "")
    private let terminal = NSTextField(labelWithString: "")
    private let editorPane = NSView()
    private let terminalPane = NSView()
    private let stack = NSStackView()
    /// Side's own text: set by the pane, which sizes it.
    var interfaceSamples: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            guard let interfaceSamples else { return }
            let card = SettingsForm.section("Interface", [SettingsForm.content(interfaceSamples)])
            stack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    init() {
        super.init(frame: .zero)
        for pane in [editorPane, terminalPane] {
            pane.wantsLayer = true
            pane.layer?.cornerRadius = DS.Radius.surface
            pane.layer?.cornerCurve = .continuous
        }
        gutter.alignment = .right
        for label in [editor, gutter, terminal] {
            label.maximumNumberOfLines = 0
            label.lineBreakMode = .byClipping
            label.isSelectable = false
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            TextScaleFollower.exempt(label)
        }
        place(gutter, editor, in: editorPane)
        place(nil, terminal, in: terminalPane)
        let editorCard = SettingsForm.section("Editor", [editorPane])
        let terminalCard = SettingsForm.section("Terminal", [terminalPane])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DS.Spacing.section
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        for card in [editorCard, terminalCard] {
            stack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Preview")
        for name in [EditorThemes.didChangeNotification, DS.Appearance.didChangeNotification, DS.Text.CodeSize.didChangeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: name, object: nil)
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    private func place(_ gutter: NSTextField?, _ text: NSTextField, in pane: NSView) {
        let inset = DS.Spacing.l
        for view in [gutter, text].compactMap({ $0 }) {
            view.translatesAutoresizingMaskIntoConstraints = false
            pane.addSubview(view)
            view.topAnchor.constraint(equalTo: pane.topAnchor, constant: inset).isActive = true
        }
        if let gutter {
            NSLayoutConstraint.activate([
                gutter.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: inset),
                text.leadingAnchor.constraint(equalTo: gutter.trailingAnchor, constant: DS.Spacing.l),
            ])
        } else {
            text.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: inset).isActive = true
        }
        NSLayoutConstraint.activate([
            text.trailingAnchor.constraint(lessThanOrEqualTo: pane.trailingAnchor, constant: -inset),
            text.bottomAnchor.constraint(equalTo: pane.bottomAnchor, constant: -inset),
        ])
    }

    static let code: [[(String, String?)]] = [
        [("// Greet everyone on the list", "comment")],
        [("func", "keyword"), (" ", nil), ("greet", "function"), ("(_ names: [", nil), ("String", "type"), ("]) -> ", nil), ("Int", "type"), (" {", nil)],
        [("    ", nil), ("for", "keyword"), (" name ", nil), ("in", "keyword"), (" names {", nil)],
        [("        print(", nil), ("\"Hello, \\(name)!\"", "string"), (")", nil)],
        [("    }", nil)],
        [("    ", nil), ("return", "keyword"), (" names.count * ", nil), ("2", "number")],
        [("}", nil)],
    ]

    @objc func refresh() {
        let dark = DS.Appearance.isDark
        let theme = EditorThemes.current(dark: dark)
        let syntax = EditorThemes.syntax(dark: dark)
        let editorFont = DS.Text.Fonts.font(.editor, size: DS.Text.CodeSize.editor)
        let terminalFont = DS.Text.Fonts.font(.terminal, size: DS.Text.CodeSize.terminal)
        let text = theme?.text.nsColor ?? NSColor.labelColor
        func color(_ capture: String?) -> NSColor {
            guard let capture, let rgba = syntax.color(for: capture) else { return text }
            return NSColor(srgbRed: CGFloat(rgba.x), green: CGFloat(rgba.y), blue: CGFloat(rgba.z), alpha: CGFloat(rgba.w))
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.15
        // Lines run off the pane's edge, as in the editor, rather than wrapping.
        paragraph.lineBreakMode = .byClipping
        let code = NSMutableAttributedString()
        for (index, line) in Self.code.enumerated() {
            for (piece, capture) in line {
                code.append(NSAttributedString(string: piece, attributes: [.font: editorFont, .foregroundColor: color(capture), .paragraphStyle: paragraph]))
            }
            if index < Self.code.count - 1 { code.append(NSAttributedString(string: "\n", attributes: [.font: editorFont, .paragraphStyle: paragraph])) }
        }
        editor.attributedStringValue = code
        gutter.attributedStringValue = NSAttributedString(string: (1...Self.code.count).map(String.init).joined(separator: "\n"), attributes: [
            .font: editorFont, .foregroundColor: theme?.lineNumbers.nsColor ?? NSColor.tertiaryLabelColor, .paragraphStyle: paragraph,
        ])
        editorPane.bindLayerBackground(theme?.background.nsColor ?? DS.Color.canvas)

        let ansi = theme?.ansi?.map(\.nsColor)
        let fallback = TerminalViewController.ansiPalette(dark: dark).map {
            NSColor(srgbRed: CGFloat($0.red) / 65535, green: CGFloat($0.green) / 65535, blue: CGFloat($0.blue) / 65535, alpha: 1)
        }
        let palette = ansi ?? fallback
        let foreground = theme?.terminalText?.nsColor ?? NSColor.labelColor
        func run(_ piece: String, _ ansiIndex: Int? = nil) -> NSAttributedString {
            NSAttributedString(string: piece, attributes: [.font: terminalFont, .foregroundColor: ansiIndex.map { palette[$0] } ?? foreground, .paragraphStyle: paragraph])
        }
        let shell = NSMutableAttributedString()
        [run("~/side ", 4), run("main ", 5), run("\u{276F} ", 2), run("git status\n"),
         run("On branch main\n"),
         run("Changes not staged for commit:\n"),
         run("        modified:   ", 1), run("Settings.swift\n", 1),
         run("~/side ", 4), run("main ", 5), run("\u{276F} ", 2)].forEach(shell.append)
        terminal.attributedStringValue = shell
        terminalPane.bindLayerBackground(theme?.terminalBackground?.nsColor ?? DS.Color.raised)
        // The theme's own appearance on its panes, so a dark theme in light mode reads as dark.
        let appearance = theme.map { NSAppearance(named: $0.isDark ? .darkAqua : .aqua) } ?? nil
        editorPane.appearance = appearance
        terminalPane.appearance = appearance
    }
}
