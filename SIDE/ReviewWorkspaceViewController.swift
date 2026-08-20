import AppKit

/// Shared with Tracks' card/chip look — kept as a private duplicate rather than a cross-file
/// import since each stage still owns its own visual constants independently for now.
private enum ReviewPalette {
    static let cardBackground = NSColor(white: 0.145, alpha: 1)
    static let cardBorder = NSColor(white: 0.24, alpha: 1)
    static let chip = NSColor(white: 0.21, alpha: 1)
}

/// The Review stage: "checkpoints, diffs, rationale, test evidence, and promotion decisions"
/// per the constitution's stage table — the surface where a track's accumulated work (its
/// checkpoints, and the cumulative diff they produced against the project's base branch) gets
/// looked at as a whole and, when ready, promoted into `main`. Deliberately narrow for v1: it
/// folds in only the one piece of Integration's fuller "action surface" vision that the
/// constitution's own "First alpha" scenario actually requires — a single safe promote action —
/// rather than building out Integration's full base/checkpoint/verification/integration
/// four-concern model before real usage has shown what that needs to look like.
final class ReviewWorkspaceViewController: NSViewController {
    private weak var trackStore: TrackStore?
    private weak var sessionStore: AgentSessionStore?
    private var canonicalRoot: URL?
    private var currentTrack: Track?
    private var currentWorkingDirectory: URL?

    private let emptyStateLabel = NSTextField(labelWithString: "Switch to a track to review its work.")
    private let contentStack = NSStackView()
    private let scrollView = NSScrollView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleRow = NSStackView()
    private let branchChip = NSView()
    private let branchChipLabel = NSTextField(labelWithString: "")
    private let baseChip = NSView()
    private let baseChipLabel = NSTextField(labelWithString: "")
    private let arrowLabel = NSTextField(labelWithString: "\u{2192}")
    private let checkpointsHeader = NSTextField(labelWithString: "Checkpoints")
    private let checkpointsStack = NSStackView()
    private let diffHeader = NSTextField(labelWithString: "")
    private let diffTextView = NSTextView()
    private let diffScroll = NSScrollView()
    private let diffCard = NSView()
    // Real label set per-track in refresh() — "to main" isn't right for a stacked track, whose
    // actual base is its parent's branch.
    private let promoteButton = NSButton(title: "Promote", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let bottomBar = NSStackView()

    override func loadView() { view = NSView() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(white: 0.1, alpha: 1).cgColor

        emptyStateLabel.font = .systemFont(ofSize: 13)
        emptyStateLabel.textColor = .tertiaryLabelColor
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)

        Self.styleChip(branchChip, branchChipLabel)
        Self.styleChip(baseChip, baseChipLabel)
        arrowLabel.font = .systemFont(ofSize: 11)
        arrowLabel.textColor = .tertiaryLabelColor
        subtitleRow.orientation = .horizontal
        subtitleRow.alignment = .centerY
        subtitleRow.spacing = 6
        subtitleRow.addArrangedSubview(branchChip)
        subtitleRow.addArrangedSubview(arrowLabel)
        subtitleRow.addArrangedSubview(baseChip)
        subtitleRow.translatesAutoresizingMaskIntoConstraints = false

        checkpointsHeader.font = .systemFont(ofSize: 12, weight: .semibold)
        checkpointsHeader.textColor = .secondaryLabelColor
        checkpointsStack.orientation = .vertical
        checkpointsStack.alignment = .leading
        checkpointsStack.spacing = 8
        checkpointsStack.translatesAutoresizingMaskIntoConstraints = false

        diffHeader.font = .systemFont(ofSize: 12, weight: .semibold)
        diffHeader.textColor = .secondaryLabelColor

        diffTextView.isEditable = false
        diffTextView.drawsBackground = false
        diffTextView.textContainerInset = NSSize(width: 4, height: 4)
        diffScroll.documentView = diffTextView
        diffScroll.drawsBackground = false
        diffScroll.hasVerticalScroller = true
        diffScroll.translatesAutoresizingMaskIntoConstraints = false
        diffScroll.heightAnchor.constraint(equalToConstant: 360).isActive = true

        diffCard.wantsLayer = true
        diffCard.layer?.cornerRadius = 10
        diffCard.layer?.borderWidth = 1
        diffCard.layer?.borderColor = ReviewPalette.cardBorder.cgColor
        diffCard.layer?.backgroundColor = ReviewPalette.cardBackground.cgColor
        diffCard.translatesAutoresizingMaskIntoConstraints = false
        diffCard.addSubview(diffScroll)
        NSLayoutConstraint.activate([
            diffScroll.topAnchor.constraint(equalTo: diffCard.topAnchor, constant: 6),
            diffScroll.leadingAnchor.constraint(equalTo: diffCard.leadingAnchor, constant: 8),
            diffScroll.trailingAnchor.constraint(equalTo: diffCard.trailingAnchor, constant: -8),
            diffScroll.bottomAnchor.constraint(equalTo: diffCard.bottomAnchor, constant: -6),
        ])

        promoteButton.bezelStyle = .rounded
        promoteButton.controlSize = .large
        promoteButton.contentTintColor = .controlAccentColor
        promoteButton.target = self
        promoteButton.action = #selector(promoteTapped)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 2

        bottomBar.orientation = .horizontal
        bottomBar.alignment = .firstBaseline
        bottomBar.spacing = 10
        bottomBar.addArrangedSubview(promoteButton)
        bottomBar.addArrangedSubview(statusLabel)
        bottomBar.translatesAutoresizingMaskIntoConstraints = false

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 12
        contentStack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        for view in [titleLabel, subtitleRow, checkpointsHeader, checkpointsStack, diffHeader, diffCard, bottomBar] {
            contentStack.addArrangedSubview(view)
            // `contentStack.alignment = .leading` means arranged subviews use their intrinsic
            // width by default — without this, a wrapping label or the diff card would collapse
            // to whatever width its content happens to need instead of spanning the stage, same
            // reasoning as Think's transcript `addBlock`.
            view.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -32).isActive = true
        }
        contentStack.setCustomSpacing(6, after: titleLabel)
        contentStack.setCustomSpacing(20, after: subtitleRow)
        contentStack.setCustomSpacing(20, after: checkpointsStack)

        scrollView.documentView = contentStack
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(scrollView)
        view.addSubview(emptyStateLabel)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            contentStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
            emptyStateLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        // Not just `showEmptyState(true)` — `reloadForTrackSwitch` can (and typically does, on
        // a restored window) run before this view ever loads, since it's only added as a child
        // and given a chance to load when the Review segment is first actually clicked. Without
        // reflecting whatever `currentTrack` was already set to, a track switch that happened
        // while this stage was never visited would get silently dropped on the floor the first
        // time it's opened.
        refresh()
    }

    // MARK: - Wiring

    func configure(trackStore: TrackStore, sessionStore: AgentSessionStore, canonicalRoot: URL) {
        self.trackStore = trackStore
        self.sessionStore = sessionStore
        self.canonicalRoot = canonicalRoot
    }

    func reloadForTrackSwitch(trackKey: String?, workingDirectory: URL) {
        currentWorkingDirectory = workingDirectory
        currentTrack = trackKey.flatMap { key in trackStore?.tracks.first { $0.branchName == key } }
        refresh()
    }

    // MARK: - Rendering

    private func showEmptyState(_ empty: Bool) {
        emptyStateLabel.isHidden = !empty
        scrollView.isHidden = empty
    }

    private func refresh() {
        guard isViewLoaded, let track = currentTrack, let trackStore else {
            showEmptyState(true)
            return
        }
        showEmptyState(false)
        statusLabel.stringValue = ""

        let baseRef = Self.baseRef(for: track, trackStore: trackStore)
        titleLabel.stringValue = track.intent.isEmpty ? track.branchName : track.intent
        branchChipLabel.stringValue = track.branchName
        baseChipLabel.stringValue = baseRef
        promoteButton.title = "Promote to \(baseRef)"

        checkpointsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let checkpoints = (sessionStore?.checkpoints(forTrackKey: track.branchName) ?? []).sorted { $0.createdAt > $1.createdAt }
        if checkpoints.isEmpty {
            checkpointsStack.addArrangedSubview(Self.makeMetaLabel("No checkpoints yet — one is created automatically the first time an approved edit or command lands on this track."))
        } else {
            for checkpoint in checkpoints {
                checkpointsStack.addArrangedSubview(makeCheckpointCard(checkpoint))
            }
        }

        diffHeader.stringValue = "Changes vs \(baseRef)"
        diffTextView.textStorage?.setAttributedString(NSAttributedString(string: "Loading diff…", attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor,
        ]))
        promoteButton.isEnabled = false

        guard let canonicalRoot else { return }
        let cwd = canonicalRoot.path
        let branchName = track.branchName
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let diffText = GitDiffComputer.refDiff(fromRef: baseRef, toRef: branchName, cwd: cwd)
            DispatchQueue.main.async {
                guard let self, self.currentTrack?.branchName == branchName else { return }
                self.diffTextView.textStorage?.setAttributedString(Self.attributedDiff(diffText))
                self.promoteButton.isEnabled = !diffText.isEmpty
            }
        }
    }

    private func makeCheckpointCard(_ checkpoint: Checkpoint) -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.borderWidth = 1
        card.layer?.borderColor = ReviewPalette.cardBorder.cgColor
        card.layer?.backgroundColor = ReviewPalette.cardBackground.cgColor

        let intentLabel = NSTextField(wrappingLabelWithString: checkpoint.declaredIntent.isEmpty ? "No description" : checkpoint.declaredIntent)
        intentLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        intentLabel.translatesAutoresizingMaskIntoConstraints = false

        var metaParts: [String] = [Self.relativeTime(checkpoint.createdAt)]
        if let sha = checkpoint.gitCommitSHA { metaParts.append(String(sha.prefix(7))) }
        if !checkpoint.changedFilePaths.isEmpty {
            metaParts.append("\(checkpoint.changedFilePaths.count) file\(checkpoint.changedFilePaths.count == 1 ? "" : "s")")
        }
        if !checkpoint.commandsRun.isEmpty {
            metaParts.append("\(checkpoint.commandsRun.count) command\(checkpoint.commandsRun.count == 1 ? "" : "s")")
        }
        let metaLabel = NSTextField(labelWithString: metaParts.joined(separator: " · "))
        metaLabel.font = .systemFont(ofSize: 11)
        metaLabel.textColor = .secondaryLabelColor
        metaLabel.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(intentLabel)
        card.addSubview(metaLabel)
        NSLayoutConstraint.activate([
            intentLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            intentLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            intentLabel.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -12),
            metaLabel.topAnchor.constraint(equalTo: intentLabel.bottomAnchor, constant: 5),
            metaLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            metaLabel.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
        ])
        card.translatesAutoresizingMaskIntoConstraints = false
        card.widthAnchor.constraint(equalTo: checkpointsStack.widthAnchor).isActive = true
        return card
    }

    private static func styleChip(_ chip: NSView, _ label: NSTextField) {
        chip.wantsLayer = true
        chip.layer?.backgroundColor = ReviewPalette.chip.cgColor
        chip.layer?.cornerRadius = 4
        chip.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -5),
            label.topAnchor.constraint(equalTo: chip.topAnchor, constant: 1),
            label.bottomAnchor.constraint(equalTo: chip.bottomAnchor, constant: -1),
        ])
    }

    // MARK: - Promote

    @objc private func promoteTapped() {
        guard let track = currentTrack, let trackStore, let window = view.window else { return }
        let baseRef = Self.baseRef(for: track, trackStore: trackStore)
        guard let target = mergeTarget(for: track, trackStore: trackStore) else {
            statusLabel.stringValue = "⚠︎ \u{201C}\(baseRef)\u{201D}'s working copy has been removed — resume it (Tracks) before promoting into it."
            statusLabel.textColor = .systemOrange
            return
        }
        let alert = NSAlert()
        alert.messageText = "Promote to \(baseRef)?"
        alert.informativeText = "This merges \(track.branchName) into \(baseRef) in \(target.isParent ? "that track's" : "your main") working copy. \(track.intent.isEmpty ? "" : "\u{201C}\(track.intent)\u{201D}")"
        alert.addButton(withTitle: "Promote")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.promote(track: track, baseRef: baseRef, mergeRoot: target.root, trackStore: trackStore)
        }
    }

    /// Where a track's changes actually land, and what they land on top of. A root track's base
    /// is the project default, merged into the canonical (shared) checkout — unchanged from
    /// before stacking existed. A stacked track's base is its *parent's own branch*, and that
    /// only exists checked out in the parent's own worktree — never the canonical root, which
    /// might be sitting on a completely different branch. `nil` means there's nowhere to merge
    /// into right now (a stacked track whose parent's worktree was removed via "Remove Working
    /// Copy" and hasn't been re-materialized).
    private func mergeTarget(for track: Track, trackStore: TrackStore) -> (root: URL, isParent: Bool)? {
        guard let parentId = track.parentTrackId, let parent = trackStore.tracks.first(where: { $0.id == parentId }) else {
            guard let canonicalRoot else { return nil }
            return (canonicalRoot, false)
        }
        guard let parentPath = parent.workingDirectoryPath else { return nil }
        return (URL(fileURLWithPath: parentPath), true)
    }

    private static func baseRef(for track: Track, trackStore: TrackStore) -> String {
        guard let parentId = track.parentTrackId, let parent = trackStore.tracks.first(where: { $0.id == parentId }) else {
            return trackStore.defaultBranchName()
        }
        return parent.branchName
    }

    /// Runs entirely against `mergeRoot` — the track's actual base's own working copy (the
    /// canonical checkout for a root track, the parent track's own worktree for a stacked one) —
    /// never the track's own worktree, since promoting means moving the *base* forward, not the
    /// track's. Never leaves that working copy mid-merge: any conflict aborts immediately rather
    /// than leaving other windows/stages looking at a half-merged base.
    private func promote(track: Track, baseRef: String, mergeRoot: URL, trackStore: TrackStore) {
        promoteButton.isEnabled = false
        statusLabel.stringValue = "Promoting…"
        let cwd = mergeRoot.path
        let branchName = track.branchName
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = Self.performMerge(branchName: branchName, baseRef: baseRef, intent: track.intent, cwd: cwd)
            DispatchQueue.main.async {
                guard let self else { return }
                self.statusLabel.stringValue = outcome.message
                self.statusLabel.textColor = outcome.succeeded ? .systemGreen : .systemOrange
                self.promoteButton.isEnabled = true
                if outcome.succeeded {
                    trackStore.setStatus(.completed, for: track)
                    self.refresh()
                }
            }
        }
    }

    private static func performMerge(branchName: String, baseRef: String, intent: String, cwd: String) -> (succeeded: Bool, message: String) {
        let dirty = GitPaths.dirtyPaths(cwd: cwd)
        guard dirty.isEmpty else {
            return (false, "⚠︎ Your main working copy has uncommitted changes — commit or stash them first.")
        }
        let currentBranch = GitPaths.runGit(["symbolic-ref", "--short", "HEAD"], cwd: cwd)
        if currentBranch.success, currentBranch.output != baseRef {
            let checkout = GitPaths.runGit(["checkout", baseRef], cwd: cwd)
            guard checkout.success else { return (false, "⚠︎ Couldn't check out \(baseRef): \(checkout.output.prefix(200))") }
        }
        let ahead = GitPaths.runGit(["rev-list", "--count", "\(baseRef)..\(branchName)"], cwd: cwd)
        if ahead.success, Int(ahead.output) == 0 {
            return (false, "Nothing to promote — no commits ahead of \(baseRef).")
        }
        let mergeAttempt = GitPaths.runGit(["merge", "--no-commit", "--no-ff", branchName], cwd: cwd)
        guard mergeAttempt.success else {
            GitPaths.runGit(["merge", "--abort"], cwd: cwd)
            return (false, "⚠︎ Merging would conflict with \(baseRef) — resolve manually (e.g. rebase the track) and try again.")
        }
        let message = intent.isEmpty ? "Merge \(branchName)" : "Merge: \(intent)"
        let commit = GitPaths.runGit(["commit", "-m", message], cwd: cwd)
        guard commit.success else {
            GitPaths.runGit(["merge", "--abort"], cwd: cwd)
            return (false, "⚠︎ Couldn't finalize the merge commit.")
        }
        let sha = GitPaths.runGit(["rev-parse", "--short", "HEAD"], cwd: cwd)
        return (true, "✓ Promoted to \(baseRef) (\(sha.success ? sha.output : "?")).")
    }

    // MARK: - Static helpers

    private static let addedColor = NSColor(red: 0.45, green: 0.82, blue: 0.55, alpha: 1)
    private static let removedColor = NSColor(red: 0.92, green: 0.50, blue: 0.48, alpha: 1)
    private static let hunkColor = NSColor(red: 0.55, green: 0.72, blue: 0.95, alpha: 1)

    private static func attributedDiff(_ diffText: String) -> NSAttributedString {
        guard !diffText.isEmpty else {
            return NSAttributedString(string: "No changes against this base.", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor])
        }
        let result = NSMutableAttributedString()
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        for (index, line) in diffText.components(separatedBy: "\n").enumerated() {
            let color: NSColor
            if line.hasPrefix("+") {
                color = addedColor
            } else if line.hasPrefix("-") {
                color = removedColor
            } else if line.hasPrefix("@@") || line.hasPrefix("diff --git") {
                color = hunkColor
            } else {
                color = .secondaryLabelColor
            }
            let prefix = index == 0 ? "" : "\n"
            result.append(NSAttributedString(string: prefix + line, attributes: [.font: font, .foregroundColor: color]))
        }
        return result
    }

    private static func makeMetaLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .tertiaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private static func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
