import AppKit
import Heron

/// The History pane of Preferences: how long Think conversations are kept, and a way to delete
/// them now.
///
/// Sessions hold tool output verbatim, so "kept forever with no delete control" was a real gap —
/// this is the control half of it; `SecretRedactor` is the other half.
final class HistoryViewController: NSViewController {
    private let retentionPopup = NSPopUpButton()

    override func loadView() { view = NSView() }

    override func viewDidLoad() {
        super.viewDidLoad()

        for option in HistoryRetention.allCases {
            retentionPopup.addItem(withTitle: option.displayName)
            retentionPopup.lastItem?.representedObject = option.rawValue
        }
        retentionPopup.selectItem(at: HistoryRetention.allCases.firstIndex(of: .current) ?? 0)
        retentionPopup.target = self
        retentionPopup.action = #selector(retentionChanged)

        let page = SettingsForm.page([
            SettingsSplitViewController.hero(.history),
            SettingsForm.section("Conversations", footer: "Think conversations are stored in each project's own git directory, with the file contents and command output the agent read. That history is re-sent to the model provider with every message. Credential-shaped values are replaced before either happens.", [
                SettingsForm.row("Keep conversations", detail: "Expired ones are removed the next time you open the project. Checkpoints are kept either way.", retentionPopup),
                SettingsForm.row("Delete conversations", detail: "Every Think conversation in the projects open now. Tracks, checkpoints and files stay.",
                                 SettingsForm.button("Delete\u{2026}", self, #selector(deleteAll), destructive: true)),
            ]),
        ])
        SettingsForm.install(page, in: view)
    }

    @objc private func retentionChanged() {
        guard let raw = retentionPopup.selectedItem?.representedObject as? Int,
              let option = HistoryRetention(rawValue: raw) else { return }
        HistoryRetention.current = option
    }

    /// Only projects currently open can be reached from here — their `ProjectContext` is what
    /// owns the store. Said plainly in the button title and the alert rather than implying this
    /// clears every project Side has ever touched.
    @objc private func deleteAll() {
        let contexts = ProjectContextRegistry.openContexts()
        guard !contexts.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No projects are open"
            alert.informativeText = "Open a project to delete its conversations."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        let names = contexts.map { $0.projectRoot.lastPathComponent }.joined(separator: ", ")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete conversations in \(names)?"
        alert.informativeText = "Every Think conversation in \(contexts.count == 1 ? "this project" : "these projects") is deleted. Tracks, checkpoints, and your files are untouched. This can't be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for context in contexts {
            context.sessionStore.deleteAllSessions()
            // Runners are still holding the deleted turns in memory and would write them back
            // on the next append — dropping them is what makes the deletion actually stick.
            context.runnerManager.teardownAll()
        }
        NotificationCenter.default.post(name: Self.conversationsDeletedNotification, object: nil)
    }

    /// Think is a projection of a runner that's still holding the deleted turns in memory, so it
    /// needs telling — otherwise the transcript on screen outlives the file it came from.
    static let conversationsDeletedNotification = Notification.Name("SideConversationsDeleted")
}
