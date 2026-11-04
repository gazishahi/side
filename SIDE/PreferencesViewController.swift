import AppKit
import Heron

/// Notifications → banners and sounds (Direction 03 §3.3): only for what changes out of view.
/// System sounds people already know; a banner carries its own, so Focus can silence it.
final class NotificationsPreferencesViewController: NSViewController {
    private let notifySwitch = NSSwitch()
    private let needsYouSwitch = NSSwitch()
    private let finishedSwitch = NSSwitch()
    private var observer: NSObjectProtocol?

    override func loadView() {
        view = NSView()
        for (toggle, label, action) in [(notifySwitch, "Show a notification", #selector(notifyToggled(_:))),
                                        (needsYouSwitch, "Sound when an agent needs you", #selector(needsYouToggled(_:))),
                                        (finishedSwitch, "Also when a turn finishes", #selector(finishedToggled(_:)))] {
            toggle.target = self
            toggle.action = action
            toggle.controlSize = .small
            toggle.setAccessibilityLabel(label)
        }
        let page = SettingsForm.page([
            SettingsSplitViewController.hero(.notifications),
            SettingsForm.section("When an agent needs you", footer: "Only when it happens out of view: Side is in the background, or the window shows another track or stage. Click a notification to go to that track. macOS decides how they look, in System Settings \u{203A} Notifications \u{203A} Side.", [
                SettingsForm.row("Show a notification", detail: "When an agent waits on an approval or an answer, or a run fails.", notifySwitch),
                SettingsForm.row("Play a sound when an agent needs you", detail: "Glass when it waits on you, Funk when a run fails.", needsYouSwitch),
                SettingsForm.row("Also when a turn finishes", detail: "Tink, and a notification, when an agent is done with changes to review.", finishedSwitch),
            ]),
        ])
        SettingsForm.install(page, in: view)
        refresh()
        observer = NotificationCenter.default.addObserver(forName: AttentionPreferences.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func refresh() {
        notifySwitch.state = AttentionPreferences.notifyWhenNeedsYou ? .on : .off
        needsYouSwitch.state = AttentionPreferences.soundWhenNeedsYou ? .on : .off
        finishedSwitch.state = AttentionPreferences.alsoWhenFinished ? .on : .off
    }

    @objc private func notifyToggled(_ sender: NSSwitch) { AttentionPreferences.notifyWhenNeedsYou = sender.state == .on }
    @objc private func needsYouToggled(_ sender: NSSwitch) { AttentionPreferences.soundWhenNeedsYou = sender.state == .on }
    @objc private func finishedToggled(_ sender: NSSwitch) { AttentionPreferences.alsoWhenFinished = sender.state == .on }
}

/// The Preferences window's shell. Preferences was a single flat pane while providers were the
/// only thing configurable; usage accounting is a second, unrelated concern, so the two get
/// their own tabs rather than one scrolling wall.
/// General → Stages: which stages the stage control shows (Direction 02 §3.1). Unpinning hides a
/// view, never a capability — every stage stays on ⌘⌥1–4, Navigate and the palette.
final class GeneralPreferencesViewController: NSViewController {
    private var switches: [NSSwitch] = []
    private let foldingSwitch = NSSwitch()
    private let minimapSwitch = NSSwitch()
    private let keepRunningSwitch = NSSwitch()
    private let confirmCloseSwitch = NSSwitch()
    private var writerSwitches: [WriterPreferences.Aid: NSSwitch] = [:]
    private var observer: NSObjectProtocol?
    private var sideObserver: NSObjectProtocol?

    override func loadView() {
        view = NSView()
        var stageRows: [NSView] = []
        for stage in StagePins.pinnable {
            let toggle = SettingsForm.toggle(false, self, #selector(toggled(_:)))
            toggle.identifier = NSUserInterfaceItemIdentifier(stage.rawValue)
            toggle.setAccessibilityLabel("Pin \(stage.title)")
            switches.append(toggle)
            stageRows.append(SettingsForm.row(stage.title, toggle))
        }
        foldingSwitch.target = self
        foldingSwitch.action = #selector(foldingToggled(_:))
        foldingSwitch.controlSize = .small
        foldingSwitch.setAccessibilityLabel("Code folding")
        minimapSwitch.target = self
        minimapSwitch.action = #selector(minimapToggled(_:))
        minimapSwitch.controlSize = .small
        minimapSwitch.setAccessibilityLabel("Minimap")
        keepRunningSwitch.target = self
        keepRunningSwitch.action = #selector(keepRunningToggled(_:))
        keepRunningSwitch.controlSize = .small
        keepRunningSwitch.setAccessibilityLabel("Keep terminals running when Side quits")
        confirmCloseSwitch.target = self
        confirmCloseSwitch.action = #selector(confirmCloseToggled(_:))
        confirmCloseSwitch.controlSize = .small
        confirmCloseSwitch.setAccessibilityLabel("Ask before closing a running terminal")
        let sidePopup = SettingsForm.popup(FileExplorer.Side.allCases.map(\.title), selected: 0, self, #selector(explorerSideChanged(_:)))
        explorerPopup = sidePopup
        let page = SettingsForm.page([
            SettingsSplitViewController.hero(.general),
            SettingsForm.section("Stages", footer: "Pinned stages appear in the stage control. Unpinned ones stay on the Navigate menu, \u{2318}\u{2325}1\u{2013}4 and the palette, and show up on their own when they need you.", stageRows),
            SettingsForm.section("Editor", footer: "Folding and the minimap are also in the View menu, with their shortcuts in Shortcuts.", [
                SettingsForm.row("File explorer side", sidePopup),
                SettingsForm.row("Code folding", detail: "Fold regions from the gutter's arrows.", foldingSwitch),
                SettingsForm.row("Minimap", detail: "The file drawn small beside the text; click or drag it to scroll.", minimapSwitch),
            ]),
            SettingsForm.section("Terminal", footer: "Each terminal runs in a small helper outside Side, so closing a window or quitting doesn't end what's running in it. Reopen the project and each tab is as you left it. Closing a tab always ends its terminal.", [
                SettingsForm.row("Keep terminals running when Side quits", detail: "Off, quitting or closing a project ends its terminals.",
                                 keepRunningSwitch),
                SettingsForm.row("Ask before closing a running terminal", detail: "When a program is running in a tab you close.",
                                 confirmCloseSwitch),
            ]),
            SettingsForm.section("Writer Mode", footer: "View \u{2192} Writer Mode: the Editor alone, one column of text, nothing else on screen.",
                                 WriterPreferences.Aid.allCases.map { aid in
                                     let toggle = SettingsForm.toggle(WriterPreferences.isOn(aid), self, #selector(writerAidToggled(_:)))
                                     toggle.identifier = NSUserInterfaceItemIdentifier(aid.rawValue)
                                     toggle.setAccessibilityLabel(aid.title)
                                     writerSwitches[aid] = toggle
                                     return SettingsForm.row(aid.title, detail: aid.detail, toggle)
                                 }),
            SettingsForm.section("Updates", [
                SettingsForm.row("Check for updates automatically", detail: "Side \(Self.versionText). Updates are signed, and verified before they install.",
                                 SettingsForm.toggle(Updates.shared.checksAutomatically, self, #selector(autoUpdateToggled(_:)))),
                SettingsForm.row("Check now", SettingsForm.button("Check for Updates\u{2026}", Updates.shared, #selector(Updates.checkForUpdates(_:)))),
            ]),
            SettingsForm.section([
                SettingsForm.row("Library", detail: "Instruction files, saved prompts and templates, MCP servers, skills, and storage for the frontmost project.",
                                 SettingsForm.button("Open Library\u{2026}", self, #selector(openLibrary))),
            ]),
        ])
        SettingsForm.install(page, in: view)
        refresh()
        observer = NotificationCenter.default.addObserver(forName: StagePins.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(editorPreferencesChanged), name: EditorPreferences.didChangeNotification, object: nil)
        sideObserver = NotificationCenter.default.addObserver(forName: FileExplorer.Side.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func refresh() {
        explorerPopup?.selectItem(withTitle: FileExplorer.Side.preferred.title)
        foldingSwitch.state = EditorPreferences.foldingEnabled ? .on : .off
        minimapSwitch.state = EditorPreferences.minimapShown ? .on : .off
        keepRunningSwitch.state = SessionKeepers.keepsRunningOnQuit ? .on : .off
        confirmCloseSwitch.state = SessionKeepers.confirmsClosingRunning ? .on : .off
        for (aid, toggle) in writerSwitches { toggle.state = WriterPreferences.isOn(aid) ? .on : .off }
        let pinned = StagePins.pinned
        for toggle in switches {
            let isPinned = pinned.contains { $0.rawValue == toggle.identifier?.rawValue }
            toggle.state = isPinned ? .on : .off
            // The last pinned stage can't be unpinned: the control would be empty.
            toggle.isEnabled = !(isPinned && pinned.count == 1)
        }
    }

    private var explorerPopup: NSPopUpButton?

    static var versionText: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    @objc private func confirmCloseToggled(_ sender: NSSwitch) {
        SessionKeepers.confirmsClosingRunning = sender.state == .on
    }

    @objc private func keepRunningToggled(_ sender: NSSwitch) {
        SessionKeepers.keepsRunningOnQuit = sender.state == .on
    }

    @objc private func autoUpdateToggled(_ sender: NSSwitch) {
        Updates.shared.checksAutomatically = sender.state == .on
    }

    @objc private func openLibrary() {
        LibraryWindowController.shared.show(for: nil)
    }

    @objc private func explorerSideChanged(_ sender: NSPopUpButton) {
        FileExplorer.Side.preferred = FileExplorer.Side.allCases[max(0, sender.indexOfSelectedItem)]
    }

    @objc private func editorPreferencesChanged() { refresh() }
    @objc private func foldingToggled(_ sender: NSSwitch) { EditorPreferences.foldingEnabled = sender.state == .on }
    @objc private func minimapToggled(_ sender: NSSwitch) { EditorPreferences.minimapShown = sender.state == .on }
    @objc private func writerAidToggled(_ sender: NSSwitch) {
        guard let raw = sender.identifier?.rawValue, let aid = WriterPreferences.Aid(rawValue: raw) else { return }
        WriterPreferences.set(aid, sender.state == .on)
    }

    @objc private func toggled(_ sender: NSSwitch) {
        guard let raw = sender.identifier?.rawValue, let stage = ShellViewController.Stage(rawValue: raw) else { return }
        StagePins.toggle(stage)
    }
}
