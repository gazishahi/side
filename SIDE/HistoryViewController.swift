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

        let title = NSTextField(labelWithString: "Conversation History")
        title.font = DS.Text.heading(.semibold)

        let explainer = NSTextField(wrappingLabelWithString: "Think conversations are stored in each project's own git directory, including the file contents and command output the agent read along the way. That history is also re-sent to your configured model provider on every message in the conversation. Credential-shaped values are replaced before either happens.")
        explainer.font = DS.Text.caption()
        explainer.textColor = .secondaryLabelColor
        explainer.translatesAutoresizingMaskIntoConstraints = false
        explainer.widthAnchor.constraint(lessThanOrEqualToConstant: 440).isActive = true

        for option in HistoryRetention.allCases {
            retentionPopup.addItem(withTitle: option.displayName)
            retentionPopup.lastItem?.representedObject = option.rawValue
        }
        retentionPopup.selectItem(at: HistoryRetention.allCases.firstIndex(of: .current) ?? 0)
        retentionPopup.target = self
        retentionPopup.action = #selector(retentionChanged)

        let retentionLabel = NSTextField(labelWithString: "Keep conversations:")
        retentionLabel.font = DS.Text.body()
        let retentionRow = NSStackView(views: [retentionLabel, retentionPopup])
        retentionRow.orientation = .horizontal
        retentionRow.spacing = DS.Spacing.m

        let retentionNote = NSTextField(wrappingLabelWithString: "Expired conversations are removed the next time you open that project. Checkpoints are kept either way: they're the record of what an agent actually changed, and they point at real commits.")
        retentionNote.font = DS.Text.caption()
        retentionNote.textColor = .tertiaryLabelColor
        retentionNote.translatesAutoresizingMaskIntoConstraints = false
        retentionNote.widthAnchor.constraint(lessThanOrEqualToConstant: 440).isActive = true

        let deleteButton = NSButton(title: "Delete Conversations in Open Projects…", target: self, action: #selector(deleteAll))
        deleteButton.bezelStyle = .rounded
        deleteButton.controlSize = .small

        let stack = NSStackView(views: [title, explainer, retentionRow, retentionNote, deleteButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DS.Spacing.l
        stack.setCustomSpacing(DS.Spacing.section, after: title)
        stack.setCustomSpacing(DS.Spacing.section, after: retentionNote)
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
