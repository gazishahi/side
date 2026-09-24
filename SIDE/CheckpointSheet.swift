import AppKit
import Heron

/// Undoing a checkpoint, from wherever it's offered (Review's section, Think's checkpoint sheet):
/// the scope question as a window sheet, then the revert as a new commit. One flow, so the two
/// places can never disagree about what Undo means.
@MainActor
enum CheckpointUndo {
    /// `done` gets the line to show and its colour, and whether anything changed on disk.
    static func present(target: Checkpoint, checkpoints: [Checkpoint], worktreePath: String, window: NSWindow,
                        done: @escaping (_ message: String, _ color: NSColor, _ changed: Bool) -> Void) {
        let laterCount = checkpoints.filter { $0.createdAt > target.createdAt && $0.gitCommitSHA != nil }.count
        let alert = NSAlert()
        alert.messageText = "Undo this checkpoint?"
        let intent = target.declaredIntent.isEmpty ? "this checkpoint" : "\u{201C}\(target.declaredIntent)\u{201D}"
        // Says plainly what it does *and* what it doesn't: nothing is deleted, and the choice
        // between the two scopes is the only real decision.
        alert.informativeText = laterCount == 0
            ? "The changes from \(intent) are reversed by a new commit. Nothing is deleted: the checkpoint stays in your history, and the undo can itself be undone."
            : "The changes from \(intent) are reversed by a new commit. \(laterCount) later checkpoint\(laterCount == 1 ? " was" : "s were") made on top of it. You can undo just this one, or everything back to it.\n\nNothing is deleted either way, and an undo can itself be undone."
        alert.addButton(withTitle: laterCount == 0 ? "Undo" : "Undo Just This One")
        if laterCount > 0 { alert.addButton(withTitle: "Undo Everything After") }
        alert.addButton(withTitle: "Cancel")
        // A sheet on the window, never an app-modal `runModal` (audit 32.6).
        alert.beginSheetModal(for: window) { response in
            guard response != .alertThirdButtonReturn, !(laterCount == 0 && response == .alertSecondButtonReturn) else { return }
            let scope: CheckpointRestore.Scope = (laterCount > 0 && response == .alertSecondButtonReturn) ? .throughLatest : .single
            let commits = CheckpointRestore.commitsToRevert(checkpoints: checkpoints, target: target, scope: scope)
            let message = CheckpointRestore.revertMessage(target: target, scope: scope, count: commits.count)
            switch CheckpointRestore.perform(commits: commits, message: message, worktreePath: worktreePath) {
            case .reverted(_, let count):
                done("Undid \(count) checkpoint\(count == 1 ? "" : "s"), reversed by a new commit. Nothing was deleted.", .secondaryLabelColor, true)
            case .conflicted(let paths):
                done("⚠︎ Couldn't undo cleanly: \(paths.joined(separator: ", ")) changed since. Nothing was modified.", DS.Color.statusNeedsYou, false)
            case .failed(let message):
                done("⚠︎ Undo failed: \(message)", DS.Color.statusNeedsYou, false)
            case .nothingToDo:
                done("Nothing to undo. That checkpoint changed no files.", .secondaryLabelColor, false)
            }
        }
    }
}

/// One checkpoint's Review section — heading, meta, files and diff — as a sheet over Think
/// (Direction 02 §5.1), with "Open in Review" and "Undo…". Dismissed by Done, Escape, or a
/// stage change; nothing about it persists.
final class CheckpointSheetController: NSViewController {
    private let checkpoint: Checkpoint
    private let checkpoints: [Checkpoint]
    private let worktreePath: String
    private let diffViewer = DiffViewer()
    private let statusLabel = NSTextField(labelWithString: "")
    var onOpenInReview: (() -> Void)?
    var onClose: (() -> Void)?

    init(checkpoint: Checkpoint, checkpoints: [Checkpoint], worktreePath: String) {
        self.checkpoint = checkpoint
        self.checkpoints = checkpoints
        self.worktreePath = worktreePath
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 560))
        root.wantsLayer = true
        root.bindLayerBackground(DS.Color.canvas)
        view = root

        let heading = NSTextField(wrappingLabelWithString: checkpoint.declaredIntent.isEmpty ? "Checkpoint" : checkpoint.declaredIntent)
        heading.font = DS.Text.heading()
        let meta = NSTextField(wrappingLabelWithString: "")
        meta.attributedStringValue = ReviewWorkspaceViewController.checkpointMeta(checkpoint)

        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(diffViewer)
        let scroll = NSScrollView()
        scroll.documentView = FlippedDocument(wrapping: document)
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = DS.Text.caption()
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let openInReview = NSButton(title: "Open in Review", target: self, action: #selector(openInReviewTapped))
        let undo = NSButton(title: "Undo…", target: self, action: #selector(undoTapped))
        undo.isEnabled = checkpoint.gitCommitSHA != nil
        let done = NSButton(title: "Done", target: self, action: #selector(closeTapped))
        done.keyEquivalent = "\r"
        for button in [openInReview, undo, done] { button.bezelStyle = .push }
        let buttons = NSStackView(views: [statusLabel, NSView(), openInReview, undo, done])
        buttons.orientation = .horizontal
        buttons.spacing = DS.Spacing.m

        let stack = NSStackView(views: [heading, meta, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DS.Spacing.m
        stack.setCustomSpacing(DS.Spacing.l, after: meta)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor), stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            heading.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -40),
            diffViewer.topAnchor.constraint(equalTo: document.topAnchor),
            diffViewer.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            diffViewer.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            diffViewer.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 640),
            root.heightAnchor.constraint(greaterThanOrEqualToConstant: 420),
        ])
        loadDiff()
    }

    /// The checkpoint's own commit — `git show`, off-main — in Review's diff component.
    private func loadDiff() {
        guard let sha = checkpoint.gitCommitSHA else {
            diffViewer.render(diffText: "")
            return
        }
        diffViewer.renderLoading()
        let cwd = worktreePath
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = GitPaths.runGit(["show", "--format=", "--no-color", sha], cwd: cwd)
            DispatchQueue.main.async { self?.diffViewer.render(diffText: result.success ? result.output : "") }
        }
    }

    @objc private func openInReviewTapped() { onOpenInReview?() }
    @objc private func closeTapped() { onClose?() }
    override func cancelOperation(_ sender: Any?) { onClose?() }

    @objc private func undoTapped() {
        guard let window = view.window else { return }
        CheckpointUndo.present(target: checkpoint, checkpoints: checkpoints, worktreePath: worktreePath, window: window) { [weak self] message, color, _ in
            self?.statusLabel.stringValue = message
            self?.statusLabel.textColor = color
        }
    }
}

/// A sheet window that hands Escape to its owner — a sheet's content controller isn't in the
/// responder chain, so `cancelOperation` there never fired.
final class DismissableSheetWindow: NSWindow {
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// A flipped scroll document that sizes to what it wraps — content reads from the top.
private final class FlippedDocument: NSView {
    override var isFlipped: Bool { true }
    init(wrapping content: NSView) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor), content.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor), content.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
