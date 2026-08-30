import AppKit

/// Flipped scroll-document container — same arrangement Think's transcript uses. Review used to
/// hand its content stack directly to the scroll view with only a width constraint, which left
/// the document's height ambiguous on the *first* layout pass: the stage rendered completely
/// blank after a fresh launch until a second stage switch forced a new pass.
private final class ReviewDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// Thin forwarding layer onto `DS` (the charter's token file).
private enum ReviewPalette {
    static let cardBackground = DS.Color.bg1
    static let cardBorder = DS.Color.hairline
    static let chip = DS.Color.bg3
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
    /// Sibling-overlap warning; hidden entirely when nothing overlaps, because a banner that's
    /// always present is a banner nobody reads.
    private let overlapBanner = NSView()
    private let overlapLabel = NSTextField(wrappingLabelWithString: "")
    /// The shared paths themselves. They used to live only in a tooltip, which left the banner
    /// as a wide strip of empty colour saying "3 files" — the count without the answer to the
    /// question it provokes.
    private let overlapPathsLabel = NSTextField(wrappingLabelWithString: "")
    private let checkpointsHeader = NSTextField(labelWithString: "Checkpoints")
    private let checkpointsStack = NSStackView()
    private let diffHeader = NSTextField(labelWithString: "")
    private let diffViewer = DiffViewer()
    // Real label set per-track in refresh() — "to main" isn't right for a stacked track, whose
    // actual base is its parent's branch.
    private let promoteButton = NSButton(title: "Promote", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let bottomBar = NSStackView()

    override func loadView() { view = NSView() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.wantsLayer = true
        view.layer?.backgroundColor = DS.Color.chrome.cgColor
        NotificationCenter.default.addObserver(
            self, selector: #selector(textScaleChanged),
            name: DS.Text.scaleDidChangeNotification, object: nil
        )

        emptyStateLabel.font = DS.Text.heading()
        emptyStateLabel.textColor = .tertiaryLabelColor
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = DS.Text.title(.semibold)

        Self.styleChip(branchChip, branchChipLabel)
        Self.styleChip(baseChip, baseChipLabel)
        arrowLabel.font = DS.Text.caption()
        arrowLabel.textColor = .tertiaryLabelColor
        subtitleRow.orientation = .horizontal
        subtitleRow.alignment = .centerY
        subtitleRow.spacing = DS.Spacing.s
        subtitleRow.addArrangedSubview(branchChip)
        subtitleRow.addArrangedSubview(arrowLabel)
        subtitleRow.addArrangedSubview(baseChip)
        subtitleRow.translatesAutoresizingMaskIntoConstraints = false

        checkpointsHeader.font = DS.Text.control(.semibold)
        checkpointsHeader.textColor = .secondaryLabelColor
        checkpointsStack.orientation = .vertical
        checkpointsStack.alignment = .leading
        checkpointsStack.spacing = DS.Spacing.m
        checkpointsStack.translatesAutoresizingMaskIntoConstraints = false

        diffHeader.font = DS.Text.control(.semibold)
        diffHeader.textColor = .secondaryLabelColor


        promoteButton.bezelStyle = .rounded
        promoteButton.controlSize = .large
        promoteButton.contentTintColor = .controlAccentColor
        promoteButton.target = self
        promoteButton.action = #selector(promoteTapped)
        statusLabel.font = DS.Text.caption()
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 2

        bottomBar.orientation = .horizontal
        bottomBar.alignment = .firstBaseline
        bottomBar.spacing = DS.Spacing.l
        bottomBar.addArrangedSubview(promoteButton)
        bottomBar.addArrangedSubview(statusLabel)
        bottomBar.translatesAutoresizingMaskIntoConstraints = false

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = DS.Spacing.xl
        contentStack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        overlapBanner.wantsLayer = true
        overlapBanner.layer?.cornerRadius = DS.Radius.card
        overlapBanner.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.12).cgColor
        overlapBanner.layer?.borderWidth = 1
        overlapBanner.layer?.borderColor = NSColor.systemOrange.withAlphaComponent(0.35).cgColor
        overlapBanner.isHidden = true
        overlapBanner.translatesAutoresizingMaskIntoConstraints = false
        overlapLabel.font = DS.Text.body(.medium)
        overlapLabel.textColor = .labelColor
        overlapLabel.translatesAutoresizingMaskIntoConstraints = false
        overlapPathsLabel.font = DS.Text.caption()
        overlapPathsLabel.textColor = .secondaryLabelColor
        overlapPathsLabel.translatesAutoresizingMaskIntoConstraints = false

        let overlapIcon = NSImageView()
        overlapIcon.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .medium))
        overlapIcon.contentTintColor = .systemOrange
        overlapIcon.translatesAutoresizingMaskIntoConstraints = false
        // A fixed size, and not by accident: NSImageView hugs its content only weakly, so
        // without this it stretched to fill the banner — leaving the glyph floating in the
        // middle of a wide empty strip with the text shoved against the right edge.
        NSLayoutConstraint.activate([
            overlapIcon.widthAnchor.constraint(equalToConstant: 16),
            overlapIcon.heightAnchor.constraint(equalToConstant: 16),
        ])

        let overlapText = NSStackView(views: [overlapLabel, overlapPathsLabel])
        overlapText.orientation = .vertical
        overlapText.alignment = .leading
        overlapText.spacing = 2
        overlapText.translatesAutoresizingMaskIntoConstraints = false

        overlapBanner.addSubview(overlapIcon)
        overlapBanner.addSubview(overlapText)
        NSLayoutConstraint.activate([
            overlapIcon.leadingAnchor.constraint(equalTo: overlapBanner.leadingAnchor, constant: 12),
            // Aligned to the first line's centre, not the top edge — the glyph should sit with
            // the headline whether or not a second line is present.
            overlapIcon.centerYAnchor.constraint(equalTo: overlapLabel.centerYAnchor),
            overlapText.leadingAnchor.constraint(equalTo: overlapIcon.trailingAnchor, constant: DS.Spacing.l),
            overlapText.trailingAnchor.constraint(lessThanOrEqualTo: overlapBanner.trailingAnchor, constant: -12),
            overlapText.topAnchor.constraint(equalTo: overlapBanner.topAnchor, constant: 10),
            overlapText.bottomAnchor.constraint(equalTo: overlapBanner.bottomAnchor, constant: -10),
        ])

        for view in [titleLabel, subtitleRow, overlapBanner, checkpointsHeader, checkpointsStack, diffHeader, diffViewer, bottomBar] {
            contentStack.addArrangedSubview(view)
            // `contentStack.alignment = .leading` means arranged subviews use their intrinsic
            // width by default — without this, a wrapping label or the diff card would collapse
            // to whatever width its content happens to need instead of spanning the stage, same
            // reasoning as Think's transcript `addBlock`.
            view.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -32).isActive = true
        }
        contentStack.setCustomSpacing(DS.Spacing.s, after: titleLabel)
        contentStack.setCustomSpacing(DS.Spacing.section, after: subtitleRow)
        contentStack.setCustomSpacing(DS.Spacing.section, after: checkpointsStack)

        let documentView = ReviewDocumentView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(contentStack)
        scrollView.documentView = documentView
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
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            contentStack.topAnchor.constraint(equalTo: documentView.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
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

    /// `message` overrides the default copy — the empty state has to say *which* thing is
    /// missing (no project, no repo, no track), since the remedy differs for each.
    private func showEmptyState(_ empty: Bool, message: String? = nil) {
        if let message { emptyStateLabel.stringValue = message }
        else if empty { emptyStateLabel.stringValue = Self.defaultEmptyStateText }
        emptyStateLabel.isHidden = !empty
        scrollView.isHidden = empty
    }

    private static let defaultEmptyStateText = "Switch to a track to review its work."

    @objc private func textScaleChanged() { refresh() }

    private func refresh() {
        guard isViewLoaded else { return }
        // Review never consulted repoState, so a plain folder got "Switch to a track to review
        // its work" — advice the user cannot follow, since tracks require a repo. Tracks says
        // this plainly; Review used to never mention git at all.
        if trackStore == nil {
            showEmptyState(true, message: "No project is open. Review shows an open project's checkpoints and the changes a track has made.")
            return
        }
        if trackStore?.repoState == .notAGitRepo {
            showEmptyState(true, message: "This project isn't a git repository yet. Review works from commits and branches — initialize git in Tracks to get started.")
            return
        }
        guard let track = currentTrack, let trackStore else {
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
                let card = makeCheckpointCard(checkpoint)
                checkpointsStack.addArrangedSubview(card)
                // Only after the card is in the stack's hierarchy — activating this inside the
                // factory (before addArrangedSubview) threw NSGenericException, which AppKit
                // swallowed mid-viewDidLoad and left the whole stage blank on first visit. That
                // was the "Review renders blank after a fresh launch" bug: it only fired for
                // tracks that actually had a checkpoint to build a card for.
                card.widthAnchor.constraint(equalTo: checkpointsStack.widthAnchor).isActive = true
            }
        }

        overlapBanner.isHidden = true
        diffHeader.stringValue = "Changes vs \(baseRef)"
        diffViewer.renderLoading()
        promoteButton.isEnabled = false

        guard let canonicalRoot else { return }
        let cwd = canonicalRoot.path
        let branchName = track.branchName
        // Every other track's base, resolved on the main thread — `trackStore` isn't safe to
        // read from the background, and this is a handful of dictionary lookups.
        let siblingTracks = trackStore.tracks.filter {
            $0.branchName != branchName && $0.status != .archived && $0.status != .completed
        }
        let baseRefsByBranch = Dictionary(
            uniqueKeysWithValues: siblingTracks.map { ($0.branchName, Self.baseRef(for: $0, trackStore: trackStore)) }
        )
        let intentsByBranch = Dictionary(uniqueKeysWithValues: siblingTracks.map { ($0.branchName, $0.intent) })

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let diffText = GitDiffComputer.refDiff(fromRef: baseRef, toRef: branchName, cwd: cwd)
            // One `git diff --name-only` per track — cheap, and it costs the model nothing:
            // this is awareness for the human, not context for the agent.
            var changedPathsByBranch = [branchName: TrackOverlap.changedPaths(branch: branchName, baseRef: baseRef, cwd: cwd)]
            for (branch, base) in baseRefsByBranch {
                changedPathsByBranch[branch] = TrackOverlap.changedPaths(branch: branch, baseRef: base, cwd: cwd)
            }
            let siblings = TrackOverlap.siblings(
                of: branchName, changedPathsByBranch: changedPathsByBranch, intentsByBranch: intentsByBranch
            )
            DispatchQueue.main.async {
                guard let self, self.currentTrack?.branchName == branchName else { return }
                self.diffViewer.render(diffText: diffText)
                self.promoteButton.isEnabled = !diffText.isEmpty
                self.overlapBanner.isHidden = siblings.isEmpty
                if let headline = TrackOverlap.headline(for: siblings) {
                    self.overlapLabel.stringValue = headline
                    self.overlapPathsLabel.stringValue = TrackOverlap.sharedPathsSummary(for: siblings)
                    self.overlapBanner.setAccessibilityLabel("\(headline). \(self.overlapPathsLabel.stringValue)")
                }
            }
        }
    }

    private func makeCheckpointCard(_ checkpoint: Checkpoint) -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = DS.Radius.card
        card.layer?.borderWidth = 1
        card.layer?.borderColor = ReviewPalette.cardBorder.cgColor
        card.layer?.backgroundColor = ReviewPalette.cardBackground.cgColor

        let intentLabel = NSTextField(wrappingLabelWithString: checkpoint.declaredIntent.isEmpty ? "No description" : checkpoint.declaredIntent)
        intentLabel.font = DS.Text.body(.medium)
        intentLabel.translatesAutoresizingMaskIntoConstraints = false

        // Verification reads before the metadata: "did this work?" outranks "when did it
        // happen?" for anyone deciding whether to promote.
        let verificationLabel = NSTextField(labelWithString: Self.verificationText(for: checkpoint))
        verificationLabel.font = DS.Text.caption(.medium)
        verificationLabel.textColor = Self.verificationColor(for: checkpoint)
        verificationLabel.translatesAutoresizingMaskIntoConstraints = false
        if let verification = checkpoint.verification, !verification.passed {
            // The failing output is what the user actually needs; the card stays one line.
            verificationLabel.toolTip = verification.outputExcerpt
        }

        var metaParts: [String] = [Self.relativeTime(checkpoint.createdAt)]
        if let sha = checkpoint.gitCommitSHA { metaParts.append(String(sha.prefix(7))) }
        if !checkpoint.changedFilePaths.isEmpty {
            metaParts.append("\(checkpoint.changedFilePaths.count) file\(checkpoint.changedFilePaths.count == 1 ? "" : "s")")
        }
        if !checkpoint.commandsRun.isEmpty {
            metaParts.append("\(checkpoint.commandsRun.count) command\(checkpoint.commandsRun.count == 1 ? "" : "s")")
        }
        let metaLabel = NSTextField(labelWithString: metaParts.joined(separator: " · "))
        metaLabel.font = DS.Text.caption()
        metaLabel.textColor = .secondaryLabelColor
        metaLabel.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(intentLabel)
        card.addSubview(verificationLabel)
        card.addSubview(metaLabel)
        var constraints: [NSLayoutConstraint] = [
            intentLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            intentLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            verificationLabel.topAnchor.constraint(equalTo: intentLabel.bottomAnchor, constant: 5),
            verificationLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            metaLabel.topAnchor.constraint(equalTo: verificationLabel.bottomAnchor, constant: 3),
            metaLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            metaLabel.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
        ]
        // Only a checkpoint that produced a commit can be undone — a command-only one changed
        // no files, so there is nothing to reverse.
        if checkpoint.gitCommitSHA != nil {
            let undoButton = NSButton(title: "Undo…", target: self, action: #selector(undoCheckpointTapped(_:)))
            undoButton.bezelStyle = .rounded
            undoButton.controlSize = .small
            undoButton.font = DS.Text.caption()
            undoButton.identifier = NSUserInterfaceItemIdentifier(checkpoint.id.uuidString)
            undoButton.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(undoButton)
            constraints += [
                undoButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
                undoButton.centerYAnchor.constraint(equalTo: card.centerYAnchor),
                intentLabel.trailingAnchor.constraint(lessThanOrEqualTo: undoButton.leadingAnchor, constant: -12),
            ]
        } else {
            constraints.append(intentLabel.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -12))
        }
        NSLayoutConstraint.activate(constraints)
        card.translatesAutoresizingMaskIntoConstraints = false
        return card
    }

    private static func verificationText(for checkpoint: Checkpoint) -> String {
        guard let verification = checkpoint.verification else {
            return "Unverified — no task has been run against this change"
        }
        if verification.passed {
            return "\u{2713} Verified — \(verification.taskName) passed"
        }
        if let code = verification.exitCode {
            return "\u{2715} \(verification.taskName) failed (exit \(code))"
        }
        return "\u{26A0}\u{FE0E} \(verification.taskName) ran, but its result couldn't be read"
    }

    private static func verificationColor(for checkpoint: Checkpoint) -> NSColor {
        guard let verification = checkpoint.verification else { return .tertiaryLabelColor }
        return verification.passed ? .systemGreen : .systemRed
    }

    // MARK: - Undo

    /// Reverses a checkpoint's changes — as a *new commit*, never by rewriting history. See
    /// `CheckpointRestore` for why that's the only defensible choice here.
    @objc private func undoCheckpointTapped(_ sender: NSButton) {
        guard let id = sender.identifier.flatMap({ UUID(uuidString: $0.rawValue) }),
              let track = currentTrack,
              let checkpoints = sessionStore?.checkpoints(forTrackKey: track.branchName),
              let target = checkpoints.first(where: { $0.id == id }),
              let worktreePath = track.workingDirectoryPath ?? canonicalRoot?.path else { return }

        let laterCount = checkpoints.filter { $0.createdAt > target.createdAt && $0.gitCommitSHA != nil }.count
        let alert = NSAlert()
        alert.messageText = "Undo this checkpoint?"
        let intent = target.declaredIntent.isEmpty ? "this checkpoint" : "\u{201C}\(target.declaredIntent)\u{201D}"
        // Says plainly what it does *and* what it doesn't: nothing is deleted, and the choice
        // between the two scopes is the only real decision.
        alert.informativeText = laterCount == 0
            ? "The changes from \(intent) are reversed by a new commit. Nothing is deleted — the checkpoint stays in your history, and the undo can itself be undone."
            : "The changes from \(intent) are reversed by a new commit. \(laterCount) later checkpoint\(laterCount == 1 ? " was" : "s were") made on top of it — you can undo just this one, or everything back to it.\n\nNothing is deleted either way, and an undo can itself be undone."
        alert.addButton(withTitle: laterCount == 0 ? "Undo" : "Undo Just This One")
        if laterCount > 0 { alert.addButton(withTitle: "Undo Everything After") }
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        guard response != .alertThirdButtonReturn, !(laterCount == 0 && response == .alertSecondButtonReturn) else { return }
        let scope: CheckpointRestore.Scope = (laterCount > 0 && response == .alertSecondButtonReturn) ? .throughLatest : .single

        let commits = CheckpointRestore.commitsToRevert(checkpoints: checkpoints, target: target, scope: scope)
        let message = CheckpointRestore.revertMessage(target: target, scope: scope, count: commits.count)
        let outcome = CheckpointRestore.perform(commits: commits, message: message, worktreePath: worktreePath)

        switch outcome {
        case .reverted(_, let count):
            statusLabel.stringValue = "Undid \(count) checkpoint\(count == 1 ? "" : "s") — reversed by a new commit, nothing deleted."
            statusLabel.textColor = .secondaryLabelColor
            refresh()
        case .conflicted(let paths):
            statusLabel.stringValue = "⚠︎ Couldn't undo cleanly — \(paths.joined(separator: ", ")) changed since. Nothing was modified."
            statusLabel.textColor = .systemOrange
        case .failed(let message):
            statusLabel.stringValue = "⚠︎ Undo failed: \(message)"
            statusLabel.textColor = .systemOrange
        case .nothingToDo:
            statusLabel.stringValue = "Nothing to undo — that checkpoint changed no files."
            statusLabel.textColor = .secondaryLabelColor
        }
    }

    private static func styleChip(_ chip: NSView, _ label: NSTextField) {
        chip.wantsLayer = true
        chip.layer?.backgroundColor = ReviewPalette.chip.cgColor
        chip.layer?.cornerRadius = DS.Radius.chip
        chip.translatesAutoresizingMaskIntoConstraints = false
        label.font = DS.Text.code(11, weight: .regular)
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
        // Verification is the point of recording it: promoting known-broken work should take a
        // deliberate second decision, not the same click as promoting verified work. A *failed*
        // verification is stated as such and the default button becomes Cancel; merely
        // unverified is mentioned without obstructing, since plenty of work legitimately has no
        // test to run.
        let checkpoints = sessionStore?.checkpoints(forTrackKey: track.branchName) ?? []
        let latestVerified = checkpoints.sorted { $0.createdAt > $1.createdAt }.first { $0.verification != nil }
        let failedVerification = latestVerified?.verification.flatMap { $0.passed ? nil : $0 }

        let alert = NSAlert()
        alert.messageText = failedVerification == nil ? "Promote to \(baseRef)?" : "Promote work that failed \(failedVerification!.taskName)?"
        var detail = "This merges \(track.branchName) into \(baseRef) in \(target.isParent ? "that track's" : "your main") working copy. \(track.intent.isEmpty ? "" : "\u{201C}\(track.intent)\u{201D}")"
        if let failedVerification {
            alert.alertStyle = .warning
            detail += "\n\n\(failedVerification.taskName) last ran against this track and did not pass"
                + (failedVerification.exitCode.map { " (exit \($0))" } ?? "")
                + ". Promoting merges it anyway."
        } else if latestVerified == nil, !checkpoints.isEmpty {
            detail += "\n\nNothing has been verified on this track — no task has been run against these changes."
        }
        alert.informativeText = detail
        alert.addButton(withTitle: "Promote")
        alert.addButton(withTitle: "Cancel")
        // Cancel is the safe default when the evidence says the work is broken.
        if failedVerification != nil { alert.buttons.last?.keyEquivalent = "\r"; alert.buttons.first?.keyEquivalent = "" }
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

    private static func makeMetaLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = DS.Text.control()
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
