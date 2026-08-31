import Foundation

/// Everything pending between a batch of tool calls landing and every proposal in it being
/// resolved. Lifted verbatim in shape from what used to be a set of escaping-closure captures
/// inside `ThinkWorkspaceViewController` (`resultsById`, `remaining`, `lastAppliedURL`) — making
/// it an explicit struct is what lets `AgentRunner` survive its view being torn down mid-pause:
/// there's no closure holding the rest of the turn hostage to one view's lifetime anymore.
private struct PendingToolBatch {
    /// Every tool_use id from this round, in the order the model asked for them — results are
    /// reassembled in this order regardless of which proposal the human resolves first.
    let callOrder: [String]
    var resultsById: [String: AgentContentBlock]
    var unresolvedToolUseIds: Set<String>
    var lastAppliedURL: URL?
    let roundTrip: Int
    let modelId: String
    /// Captured alongside `modelId` when the request went out — never re-read from the live
    /// registry at checkpoint time, so switching providers mid-approval can't produce a
    /// checkpoint claiming the new provider ran the old model.
    let providerId: String
    /// The assistant's own text just before it asked for these tools — used as a checkpoint's
    /// `declaredIntent` if anything in this batch actually gets applied or executed.
    let declaredIntent: String
    var changedFilePaths: Set<String> = []
    var commandsRun: [String] = []
    /// Every path git considered dirty in the track's worktree *before* this batch executed
    /// anything — a checkpoint only stages paths that became newly dirty since this snapshot
    /// (plus whatever `changedFilePaths` names directly), so a concurrent manual edit sitting in
    /// the same worktree never gets swept into the agent's commit.
    let baselineDirtyPaths: Set<String>

    var remaining: Int { unresolvedToolUseIds.count }
}

/// One agent conversation for one `(project, trackKey)`. Owns exactly what used to live as
/// private state inside `ThinkWorkspaceViewController` — the loop, the streaming accumulator,
/// the approval pause — so that state now survives the view being torn down and rebuilt (a
/// stage switch, a track switch, even the window itself closing while another window keeps the
/// project open) instead of being cancelled by it. `@MainActor` because every entry point here
/// used to be implicitly main-thread-only by virtue of living on an `NSViewController`; making
/// that explicit means callers no longer get that guarantee for free just by being a view.
@MainActor
final class AgentRunner {
    let trackKey: String
    private let sessionStore: AgentSessionStore
    /// Which project's ledger this runner's token usage is filed under.
    private let projectPath: String
    /// The model the in-flight request went out to — captured when the stream starts so a
    /// usage report is filed against the model that actually produced it, even if the user
    /// switches models while it's streaming.
    private var activeModelId = ""
    /// The provider's own input-token count for the most recent request — `nil` until one
    /// completes, in which case the gauge falls back to an estimate.
    private(set) var lastReportedInputTokens: Int?
    /// The provider the in-flight request went to — recorded alongside `activeModelId` so usage
    /// is filed against what actually answered, not whatever is active in Settings now.
    private var activeProviderId = ProviderRegistryStore.shared.activeProviderId
    /// Resolved fresh on every use, never captured once — see `WorkspaceBridge`.
    private let bridgeProvider: () -> WorkspaceBridge
    /// The directory this track's tools actually operate in — its linked worktree if it has one,
    /// else the shared project root. Resolved fresh on every tool call/diff/staleness-check
    /// rather than cached, so a track lazily materializing its worktree mid-session (or one
    /// that's just been deleted mid-run) is picked up without any explicit invalidation.
    private let rootProvider: () -> URL
    /// Whether this track has opted out of approval for `run_shell_command`. Resolved fresh per
    /// batch, same reasoning as `rootProvider`.
    /// The track's mode, resolved fresh per request — same convention as `rootProvider`, so
    /// changing mode mid-conversation takes effect on the very next turn.
    private let modeProvider: () -> AgentMode
    /// The track's own model choice, resolved fresh per request — same convention as
    /// `rootProvider`, so switching model mid-conversation takes effect on the very next turn
    /// instead of needing a new runner.
    private let modelSelectionProvider: () -> (providerId: String?, modelId: String?, effort: AgentEffort?)

    private(set) var entries: [RunTranscriptEntry] = []
    private(set) var phase: AgentRunPhase = .idle
    /// True from the moment a turn finishes cleanly until something acknowledges it — mirrors
    /// `RunSession.hasUnseenOutput`. Only meaningful alongside `.finishedTurn`; see
    /// `AgentActivity.init(phase:hasUnseenCompletion:)`.
    private(set) var hasUnseenCompletion = false
    var activity: AgentActivity { AgentActivity(phase: phase, hasUnseenCompletion: hasUnseenCompletion) }
    /// When this run most recently *became* `.needsYou` — `nil` whenever it isn't right now.
    /// Distinct from `Track.lastActiveAt` (which only updates on a track switch, not on an agent
    /// blocking): this is what lets Tracks' pinned "Needs You" section order by how long
    /// something has actually been waiting on a decision, oldest first, instead of by whatever
    /// track the user happened to look at most recently.
    private(set) var needsYouSince: Date?
    private var pendingBatch: PendingToolBatch?
    /// Non-nil only while a tool batch is genuinely awaiting a human decision — exposed so a
    /// caller doesn't have to reach into private state to know whether `resolve` even applies.
    var isAwaitingApproval: Bool { pendingBatch != nil }

    private var observers: [UUID: (AgentRunEvent) -> Void] = [:]

    private var streamTask: Task<Void, Never>?
    private var pendingAssistantText = ""
    private var pendingToolCalls: [(id: String, name: String, partialJSON: String)] = []
    /// Index into `entries` of the assistant block currently receiving streamed deltas, so
    /// tokens append into one growing entry instead of one entry per delta.
    private var streamingEntryIndex: Int?
    /// Cancelled and re-armed on every stream event — fires only if `.streaming` goes quiet for
    /// `stallTimeout`, since a hung SSE connection is otherwise indistinguishable from a working
    /// agent (`SSEHTTPClient`'s own request timeout is the transport-level backstop under this).
    private var stallWatchdog: DispatchWorkItem?
    /// Whether this turn's stream delivered a well-formed terminator, and with what stop reason.
    /// A stream that just *stops* — truncated response, a socket closed after malformed events —
    /// produces no `messageEnd`, which is the only way to tell "the model had nothing to say"
    /// apart from "the response never arrived." Without that distinction an empty turn finished
    /// as a success and the agent appeared to answer with silence.
    private var didReceiveMessageEnd = false
    private var lastStopReason: StopReason?
    /// A provider-level error (bad key, rate limit, overloaded) already surfaced as an entry this
    /// turn — the turn must not then report success.
    private var didReceiveProviderError = false
    /// Set by `stop()`, cleared when the user sends again — see `continueAfterTools`.
    private var isStopRequested = false

    /// Bounds one send: the model can chain tools, but a loop that never stops asking for them
    /// shouldn't be able to run forever (or bill forever) without the user re-engaging.
    private static let maxToolRoundTrips = 12
    private static let stallTimeout: TimeInterval = 90

    init(
        trackKey: String, sessionStore: AgentSessionStore, projectPath: String,
        bridgeProvider: @escaping () -> WorkspaceBridge,
        rootProvider: @escaping () -> URL, modeProvider: @escaping () -> AgentMode = { .default },
        modelSelectionProvider: @escaping () -> (providerId: String?, modelId: String?, effort: AgentEffort?) = { (nil, nil, nil) }
    ) {
        self.trackKey = trackKey
        self.sessionStore = sessionStore
        self.projectPath = projectPath
        self.bridgeProvider = bridgeProvider
        self.rootProvider = rootProvider
        self.modeProvider = modeProvider
        self.modelSelectionProvider = modelSelectionProvider
        hydrateFromSession()
    }

    // MARK: - Observation

    @discardableResult
    func addObserver(_ observer: @escaping (AgentRunEvent) -> Void) -> UUID {
        let token = UUID()
        observers[token] = observer
        return token
    }

    func removeObserver(_ token: UUID) {
        observers.removeValue(forKey: token)
    }

    private func notify(_ event: AgentRunEvent) {
        for observer in observers.values { observer(event) }
    }

    private func setPhase(_ newPhase: AgentRunPhase) {
        guard phase != newPhase else { return }
        let wasNeedsYou = activity == .needsYou
        phase = newPhase
        let isNeedsYou = activity == .needsYou
        if isNeedsYou, !wasNeedsYou {
            needsYouSince = Date()
        } else if !isNeedsYou {
            needsYouSince = nil
        }
        notify(.phaseChanged)
    }

    /// Called by whoever is actually looking at this run right now (Think, on becoming visible)
    /// once a finished turn is on screen. Reuses `.phaseChanged` rather than growing a separate
    /// event case — every observer that cares about activity already recomputes it from `phase`
    /// and `hasUnseenCompletion` together, so a dedicated event would just be a second signal for
    /// the same recomputation.
    func acknowledgeCompletion() {
        guard hasUnseenCompletion else { return }
        hasUnseenCompletion = false
        notify(.phaseChanged)
    }

    private func armStallWatchdog() {
        stallWatchdog?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.handleStall() }
        stallWatchdog = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.stallTimeout, execute: workItem)
    }

    private func stopStallWatchdog() {
        stallWatchdog?.cancel()
        stallWatchdog = nil
    }

    private func handleStall() {
        guard phase == .streaming else { return }
        streamTask?.cancel()
        streamTask = nil
        streamingEntryIndex = nil
        appendEntry(.failure("No response for \(Int(Self.stallTimeout))s — the connection may have stalled."))
        setPhase(.blocked(.stalled))
    }

    // MARK: - Sending

    /// Whether a message could actually be sent right now — i.e. a provider is configured with
    /// a usable key. Exposed so the composer can check *before* clearing itself: the send used
    /// to fail after the text was already gone, so a missing key silently ate what you typed.
    var isReadyToSend: Bool {
        let selection = resolvedSelection()
        if case .ready = ProviderRegistryStore.shared.resolveAdapter(
            providerId: selection.providerId, modelId: selection.modelId, effort: selection.effort
        ) { return true }
        return false
    }

    /// The reason `isReadyToSend` is false, for the UI to show.
    var notReadyReason: String {
        let name = ProviderRegistryStore.shared.provider(for: resolvedSelection().providerId)?.displayName ?? "the active provider"
        return "No API key for \(name) yet. Add one in Settings (⌘,) — it's stored in your Keychain."
    }

    func send(_ text: String, attachments: [AgentImageAttachment] = []) {
        guard !phase.isBusy else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        let selection = resolvedSelection()
        guard case .ready(_, _, let model) = ProviderRegistryStore.shared.resolveAdapter(
            providerId: selection.providerId, modelId: selection.modelId, effort: selection.effort
        ) else {
            appendMissingKeyHint()
            return
        }
        // What's persisted is exactly what the user typed. The `@`-mention note is *not* stored
        // with it: a stored note shows up in the bubble when the transcript is rebuilt from disk
        // (the live transcript and the reloaded one disagreed, which is how this was caught), and
        // it would freeze the resolution — a path that didn't exist when the message was sent
        // would stay "doesn't exist" forever. It's attached per request instead, in `runTurn`.
        // Images lead, text follows — the API reads a message top to bottom and the prose
        // usually refers to "this screenshot."
        var content: [AgentContentBlock] = attachments.map { .image(mediaType: $0.mediaType, base64: $0.base64) }
        if !trimmed.isEmpty { content.append(.text(trimmed)) }
        sessionStore.appendTurn(
            AgentTurn(role: .user, content: content),
            trackKey: trackKey, providerId: selection.providerId, modelId: model.id
        )
        for attachment in attachments {
            if let data = Data(base64Encoded: attachment.base64) { appendEntry(.userImage(data)) }
        }
        if !trimmed.isEmpty { appendEntry(.userText(trimmed)) }
        runTurn(roundTrip: 0)
    }

    func stop() {
        stopStallWatchdog()
        // Cancelling the network task only stops what's *streaming*. Tools run on their own
        // queue and their results are submitted in a fresh request when they land, so pressing
        // Stop during .runningTools still sent a new (billed) request and continued the loop.
        // This flag is what the continuation consults.
        isStopRequested = true
        streamTask?.cancel()
        // Stop has to reach the shell too. A command runs in the track's visible terminal and
        // keeps running after its result is reported (or times out), so cancelling only the
        // network stream left a runaway command with no stop path except the user typing Ctrl-C
        // into the terminal themselves. The interrupt resolves the pending tool result honestly.
        bridgeProvider().interruptShellCommand()
    }

    /// Called only when the last window watching this project closes (see
    /// `ProjectContextRegistry.release`). Cancels any in-flight network call and, if a proposal
    /// (edit or command) was left awaiting a human decision, writes a synthetic rejection for
    /// every unresolved tool_use — without this, `think.json` would keep a `tool_use` with no
    /// matching `tool_result`, which the Messages API rejects outright, permanently wedging that
    /// track's conversation the next time the project is opened.
    func teardown() {
        stopStallWatchdog()
        streamTask?.cancel()
        streamTask = nil
        guard let batch = pendingBatch else { return }
        pendingBatch = nil
        var resultsById = batch.resultsById
        for toolUseId in batch.unresolvedToolUseIds {
            resultsById[toolUseId] = .toolResult(
                toolUseId: toolUseId,
                content: "Side closed before the user decided. Ask again if this is still needed.",
                isError: true
            )
        }
        let blocks = batch.callOrder.compactMap { resultsById[$0] }
        guard blocks.count == batch.callOrder.count else { return }
        sessionStore.appendTurn(AgentTurn(role: .user, content: blocks), trackKey: trackKey, providerId: activeProviderId, modelId: batch.modelId)
    }

    // MARK: - Proposal resolution

    /// Dispatches to whichever kind of proposal `proposalId` actually is — an edit or a command
    /// resolve completely differently (diff-and-apply vs. type-into-Run-and-wait), but both
    /// share the same "decrement the batch, finish the batch once nothing's left" tail.
    func resolve(proposalId: UUID, decision: ProposalDecision) {
        guard let entryIndex = entries.firstIndex(where: { $0.id == proposalId }) else { return }
        switch entries[entryIndex].kind {
        case .proposal(let presentation):
            guard presentation.resolution == nil else { return }
            resolveEditProposal(entryIndex: entryIndex, presentation: presentation, decision: decision)
        case .commandProposal(let presentation):
            guard presentation.resolution == nil else { return }
            resolveCommandProposal(entryIndex: entryIndex, presentation: presentation, decision: decision)
        default:
            return
        }
    }

    /// Cumulative +/- line counts per file for edits applied in this conversation — the data
    /// behind Think's changed-files pill. Session-scoped and rebuilt from nothing on relaunch:
    /// the durable record is the checkpoints in Review, this is just "what happened here."
    private(set) var appliedEditCounts: [(path: String, added: Int, removed: Int)] = []

    private func recordAppliedEdit(path: String, diffText: String) {
        var added = 0, removed = 0
        for line in diffText.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("+"), !line.hasPrefix("+++") { added += 1 }
            else if line.hasPrefix("-"), !line.hasPrefix("---") { removed += 1 }
        }
        if let index = appliedEditCounts.firstIndex(where: { $0.path == path }) {
            appliedEditCounts[index].added += added
            appliedEditCounts[index].removed += removed
        } else {
            appliedEditCounts.append((path, added, removed))
        }
    }

    private func resolveEditProposal(entryIndex: Int, presentation: ProposalPresentation, decision: ProposalDecision) {
        guard var batch = pendingBatch, batch.unresolvedToolUseIds.contains(presentation.edit.toolUseId) else { return }
        var presentation = presentation

        let bridge = bridgeProvider()
        let outcome: ProposedEditOutcome
        switch decision {
        case .reject:
            outcome = .rejected
        case .apply:
            let applier = ProposedEditApplier(
                applyIntoOpenTab: bridge.applyEditIntoOpenTab,
                currentContent: { url in ToolExecutor(projectRoot: self.rootProvider(), liveBufferProvider: bridge.liveBufferProvider).currentContent(of: url) }
            )
            outcome = applier.apply(presentation.edit)
        }

        presentation.resolution = ProposalPresentation.Resolution(outcome)
        presentation.edit.stripContent()
        updateEntry(at: entryIndex, .proposal(presentation))

        batch.resultsById[presentation.edit.toolUseId] = Self.toolResult(toolUseId: presentation.edit.toolUseId, content: outcome.toolResultText, isError: outcome.isError)
        batch.unresolvedToolUseIds.remove(presentation.edit.toolUseId)
        if case .applied = outcome {
            batch.lastAppliedURL = presentation.edit.url
            batch.changedFilePaths.insert(presentation.edit.relativePath)
            recordAppliedEdit(path: presentation.edit.relativePath, diffText: presentation.diffText)
        }
        pendingBatch = batch
        finishBatchIfReady()
    }

    private func resolveCommandProposal(entryIndex: Int, presentation: CommandPresentation, decision: ProposalDecision) {
        guard pendingBatch?.unresolvedToolUseIds.contains(presentation.command.toolUseId) == true else { return }
        switch decision {
        case .reject:
            completeCommandResolution(
                entryIndex: entryIndex, toolUseId: presentation.command.toolUseId, resolution: .rejected,
                resultText: "Rejected by the user. Ask what they'd prefer instead of retrying the same command.", isError: true
            )
        case .apply:
            executeCommand(entryIndex: entryIndex)
        }
    }

    /// Types the command into the track's own Run session (see `WorkspaceBridge.runShellCommand`)
    /// and waits for its result — used both for a human's Apply click and for an auto-run track's
    /// commands, which skip straight to this without ever pausing visibly.
    private func executeCommand(entryIndex: Int) {
        guard entries.indices.contains(entryIndex), case .commandProposal(let presentation) = entries[entryIndex].kind else { return }
        let toolUseId = presentation.command.toolUseId
        let commandText = presentation.command.command
        bridgeProvider().runShellCommand(commandText) { [weak self] output in
            self?.completeCommandResolution(entryIndex: entryIndex, toolUseId: toolUseId, resolution: .executed(output: output), resultText: output, isError: false)
        }
    }

    private func completeCommandResolution(entryIndex: Int, toolUseId: String, resolution: CommandPresentation.Resolution, resultText: String, isError: Bool) {
        guard var batch = pendingBatch, batch.unresolvedToolUseIds.contains(toolUseId),
              entries.indices.contains(entryIndex), case .commandProposal(var presentation) = entries[entryIndex].kind else { return }
        presentation.resolution = resolution
        updateEntry(at: entryIndex, .commandProposal(presentation))

        batch.resultsById[toolUseId] = Self.toolResult(toolUseId: toolUseId, content: resultText, isError: isError)
        batch.unresolvedToolUseIds.remove(toolUseId)
        if case .executed(let output) = resolution {
            batch.commandsRun.append(presentation.command.command)
            // A named task's result is evidence about the code, not just another command that
            // ran — so it lands on the checkpoint, where Review and Promote can see it.
            if let taskName = presentation.command.taskName {
                let verification = CheckpointVerification(
                    taskName: taskName, command: presentation.command.command,
                    exitCode: Self.exitCode(fromCommandOutput: output), output: output
                )
                if sessionStore.attachVerification(verification, toLatestCheckpointFor: trackKey) {
                    appendEntry(.meta(verification.passed
                        ? "\u{2713} Verified — \(taskName) passed"
                        : "\u{26A0}\u{FE0E} \(taskName) failed — this checkpoint is recorded as unverified"))
                }
            }
        }
        pendingBatch = batch
        finishBatchIfReady()
    }

    /// The exit status a task reported, when the shell integration told us one.
    ///
    /// `TerminalViewController` appends an exit-status line to a command's captured output when
    /// OSC 133 marks are available. Without marks there's no honest way to know, and guessing
    /// from output text ("error" appearing somewhere) would produce false verdicts about
    /// whether the project works — so an unknown status is reported as unknown, and
    /// `CheckpointVerification.passed` is false unless the code is explicitly zero.
    private static func exitCode(fromCommandOutput output: String) -> Int? {
        for line in output.split(separator: "\n", omittingEmptySubsequences: true).reversed().prefix(4) {
            guard let range = line.range(of: "[exit code: ") else { continue }
            let rest = line[range.upperBound...]
            guard let close = rest.firstIndex(of: "]") else { continue }
            return Int(rest[rest.startIndex..<close])
        }
        return nil
    }

    /// Shared tail for both proposal kinds: once nothing in the batch is left unresolved, reveal
    /// the last-applied file (if any), create a checkpoint if anything actually happened, and
    /// hand the assembled results back to the model.
    private func finishBatchIfReady() {
        guard let batch = pendingBatch, batch.remaining == 0 else { return }
        pendingBatch = nil
        let bridge = bridgeProvider()
        // Revealing the changed file switches to Make, which would hide any sibling proposals
        // still awaiting a decision — so the jump is deferred until every card in the batch is
        // resolved.
        if let lastAppliedURL = batch.lastAppliedURL { bridge.onRevealFileRequested(lastAppliedURL) }
        // Checkpointing runs nine serial git subprocesses, three of which retry for up to five
        // seconds each with `Thread.sleep` — up to fifteen seconds of frozen UI on this
        // @MainActor class, and index-lock contention (the very thing the retry exists for) is
        // most likely exactly when a command the agent just ran is still touching git. So the
        // git work happens off-main and the loop resumes when it lands.
        createCheckpointIfNeeded(batch) { [weak self] in
            guard let self else { return }
            self.continueAfterTools(callOrder: batch.callOrder, resultsById: batch.resultsById, modelId: batch.modelId, roundTrip: batch.roundTrip)
        }
    }

    /// A durable record of what this batch actually did, backed by a real git commit on the
    /// track's own branch — the constitution's "an agent run does not equal a branch; it
    /// produces a durable checkpoint." Only created if something was actually applied or
    /// executed (an all-rejected batch has nothing to checkpoint), and only ever after every
    /// proposal in the batch was already resolved — never before, never as a substitute for the
    /// approval clicks themselves.
    private func createCheckpointIfNeeded(_ batch: PendingToolBatch, completion: @escaping () -> Void) {
        guard !batch.changedFilePaths.isEmpty || !batch.commandsRun.isEmpty,
              let session = sessionStore.session(forTrackKey: trackKey) else { return completion() }
        let root = rootProvider().path
        let baseline = batch.baselineDirtyPaths
        let knownChanged = batch.changedFilePaths
        let message = batch.declaredIntent.trimmingCharacters(in: .whitespacesAndNewlines)
        let commitMessage = message.isEmpty ? "Agent checkpoint" : String(message.prefix(72))

        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.stageAndCommit(
                root: root, baseline: baseline, knownChanged: knownChanged, message: commitMessage
            )
            DispatchQueue.main.async { [weak self] in
                guard let self else { return completion() }
                self.recordCheckpoint(result, batch: batch, sessionId: session.id)
                completion()
            }
        }
    }

    /// The git half — safe to run off the main thread, and deliberately free of any `self`
    /// reference so it cannot touch main-actor state from a background queue.
    private nonisolated static func stageAndCommit(
        root: String, baseline: Set<String>, knownChanged: Set<String>, message: String
    ) -> CheckpointCommitOutcome? {

        // Stage only what this batch actually touched: paths a command left newly dirty (not
        // already dirty before the batch started — that's a concurrent manual edit sitting in
        // the same worktree, not the agent's work) plus every path an approved edit is known for
        // certain to have touched, even if that path happened to already be dirty. Deliberately
        // not `git add -A` — that would sweep any unrelated in-progress change in this worktree
        // into the agent's commit and misattribute it.
        let currentDirtyPaths = GitPaths.dirtyPaths(cwd: root)
        let pathsToStage = currentDirtyPaths.subtracting(baseline).union(knownChanged)
        // Everything the batch did left the tree exactly as it already was (e.g. a command that
        // ran but touched nothing) — nothing to checkpoint at all.
        guard !pathsToStage.isEmpty else { return nil }
        return commitPathsInIsolatedIndex(pathsToStage.sorted(), message: message, cwd: root)
    }

    private func recordCheckpoint(_ outcome: CheckpointCommitOutcome?, batch: PendingToolBatch, sessionId: UUID) {
        guard let outcome else { return }
        // A failed commit is not a checkpoint. Recording one anyway is what produced a card
        // claiming success for work that was never committed and could never be undone.
        if case .failed(let step, let message) = outcome {
            appendEntry(.failure("Couldn't create a checkpoint — git \(step) failed\(message.isEmpty ? "" : ": \(message)").\nThe agent's changes are still in your working copy, uncommitted."))
            return
        }
        var commitSHA: String?
        var changedFiles: [String] = []
        if case .committed(let sha, let paths) = outcome {
            commitSHA = sha
            changedFiles = paths
        }

        let checkpoint = Checkpoint(
            trackKey: trackKey, agentSessionId: sessionId, declaredIntent: batch.declaredIntent,
            changedFilePaths: changedFiles, commandsRun: batch.commandsRun,
            // Provider and model both come from the batch — captured together when the request
            // was made. Reading the provider from the live registry here (as this used to) could
            // pair a new provider with the old model if the user switched during the approval.
            provenance: AgentProvenance(providerId: batch.providerId, modelId: batch.modelId, instructionSourceSummary: "Think conversation"),
            gitCommitSHA: commitSHA
        )
        sessionStore.appendCheckpoint(checkpoint)

        let intentText = checkpoint.declaredIntent.isEmpty ? "no description" : checkpoint.declaredIntent
        let marker = commitSHA.map { "✓ Checkpoint (\(String($0.prefix(7)))): \(intentText)" } ?? "✓ Checkpoint: \(intentText) (no file changes)"
        appendEntry(.meta(marker))
    }



    /// Discards the conversation without summarizing it.
    ///
    /// Distinct from `compact` on purpose: compaction preserves what was learned, this throws it
    /// away. That's the right tool when the next thing you want to talk about has nothing to do
    /// with the last thing — a summary would just drag irrelevant context into every future turn.
    /// Checkpoints, usage history, and files are untouched; only the turns go.
    func startNewConversation() {
        guard !phase.isBusy else { return }
        appliedEditCounts = []
        let selection = resolvedSelection()
        sessionStore.replaceTurns([], trackKey: trackKey, providerId: selection.providerId, modelId: selection.modelId ?? "")
        entries = []
        lastReportedInputTokens = nil
        pendingBatch = nil
        setPhase(.idle)
        notify(.reset)
    }

    // MARK: - Context budget

    /// How full this track's context window is. Uses the resolved model's window, so switching
    /// to a model with a different window immediately re-reads the same conversation against it.
    func contextUsage() -> (usedTokens: Int, windowTokens: Int, fraction: Double, status: ContextBudget.Status) {
        let turns = sessionStore.session(forTrackKey: trackKey)?.turns ?? []
        let selection = resolvedSelection()
        var window = 200_000
        if case .ready(_, _, let model) = ProviderRegistryStore.shared.resolveAdapter(
            providerId: selection.providerId, modelId: selection.modelId, effort: selection.effort
        ) {
            window = model.contextWindowTokens
        }
        return ContextBudget.usage(turns: turns, windowTokens: window, lastReportedInputTokens: lastReportedInputTokens)
    }

    /// Replaces the conversation with a model-written summary of it.
    ///
    /// The summary is produced by a real request (a local heuristic summary reads like a changelog
    /// and loses the reasoning that makes a continuation coherent), then *all* turns are replaced
    /// with one user turn holding it. Replacing everything — rather than keeping a tail of recent
    /// turns — is what guarantees no `tool_use` is left without its `tool_result`, which the API
    /// rejects outright.
    ///
    /// Costs one request. That's the trade being made explicit: a summarization request now, or a
    /// conversation that stops working later.
    func compact(completion: @escaping (Result<Void, Error>) -> Void) {
        guard !phase.isBusy else {
            return completion(.failure(CompactionError.busy))
        }
        guard let session = sessionStore.session(forTrackKey: trackKey), !session.turns.isEmpty else {
            return completion(.failure(CompactionError.nothingToCompact))
        }
        let selection = resolvedSelection()
        guard case .ready(let provider, _, let model) = ProviderRegistryStore.shared.resolveAdapter(
            providerId: selection.providerId, modelId: selection.modelId, effort: selection.effort
        ) else {
            return completion(.failure(CompactionError.noProvider))
        }

        appendEntry(.meta("Compacting conversation…"))
        setPhase(.streaming)
        var messages = session.turns.map { AgentMessage(role: $0.role, content: $0.content) }
        messages.append(AgentMessage(role: .user, content: [.text(ContextBudget.compactionInstruction)]))

        // The stream callback is `@Sendable` and fires off-actor, so the accumulating text needs
        // a reference box rather than a captured `var`.
        let collector = SummaryCollector()
        Task { [weak self] in
            var failure: Error?
            do {
                // No tools: this request is meant to produce prose, and offering tools invites a
                // model to go read more files while summarizing.
                try await provider.streamTurn(messages: messages, system: nil, tools: []) { event in
                    if case .textDelta(let delta) = event { collector.append(delta) }
                }
            } catch {
                failure = error
            }
            let collected = collector.text
            let error = failure
            await MainActor.run {
                guard let self else { return }
                self.setPhase(.idle)
                if let error {
                    self.appendEntry(.failure("Couldn't compact: \(error.localizedDescription). The conversation is unchanged."))
                    return completion(.failure(error))
                }
                let trimmed = collected.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    // An empty summary must not be allowed to eat the conversation.
                    self.appendEntry(.failure("Compaction produced no summary, so the conversation is unchanged."))
                    return completion(.failure(CompactionError.emptySummary))
                }
                let replacement = AgentTurn(role: .user, content: [.text(ContextBudget.summaryTurnText(trimmed))])
                self.sessionStore.replaceTurns(
                    [replacement], trackKey: self.trackKey,
                    providerId: selection.providerId, modelId: model.id
                )
                // The gauge's measured value describes the *old* request; drop it so the estimate
                // of the compacted conversation is what shows.
                self.lastReportedInputTokens = nil
                // Clear first: `hydrateFromSession` *appends*, so without this the old turns
                // stayed on screen next to the summary until the app restarted — the transcript
                // claimed context that was already gone.
                self.entries = []
                self.hydrateFromSession()
                self.notify(.reset)
                self.appendEntry(.meta("Conversation compacted. Earlier turns are gone; the summary above is what the agent now knows."))
                completion(.success(()))
            }
        }
    }

    /// Thread-safe accumulator for a streamed summary.
    private final class SummaryCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var value = ""

        func append(_ delta: String) {
            lock.lock()
            value += delta
            lock.unlock()
        }

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    enum CompactionError: LocalizedError {
        case busy, nothingToCompact, noProvider, emptySummary

        var errorDescription: String? {
            switch self {
            case .busy: return "Wait for the current run to finish before compacting."
            case .nothingToCompact: return "There's nothing to compact yet."
            case .noProvider: return "No model provider is configured."
            case .emptySummary: return "The model returned an empty summary."
            }
        }
    }

    // MARK: - The loop

    /// One request/response cycle, recursing while the model keeps asking for tools. Re-resolves
    /// the provider on every call — including every continuation after a tool round-trip or an
    /// approval pause — rather than threading one captured instance through the whole
    /// conversation, so a key fixed in Preferences mid-pause takes effect on the very next call
    /// instead of requiring a fresh send.
    private func runTurn(roundTrip: Int) {
        guard let session = sessionStore.session(forTrackKey: trackKey) else {
            finishRun(completed: false)
            return
        }
        guard roundTrip < Self.maxToolRoundTrips else {
            appendEntry(.meta("Stopped after \(Self.maxToolRoundTrips) tool round-trips. Send another message to continue."))
            streamTask = nil
            streamingEntryIndex = nil
            setPhase(.blocked(.roundTripLimit))
            return
        }
        // Checked here, immediately before the request, rather than at send: a tool chain can
        // cross the limit mid-run, and the round-trip that crosses it is the one to stop.
        if case .exceeded(let spent, let limit) = UsageBudget.status() {
            appendEntry(.failure(UsageBudget.blockedMessage(spent: spent, limit: limit)))
            streamTask = nil
            streamingEntryIndex = nil
            setPhase(.blocked(.budgetReached))
            return
        }
        let selection = resolvedSelection()
        guard case .ready(let provider, _, let model) = ProviderRegistryStore.shared.resolveAdapter(
            providerId: selection.providerId, modelId: selection.modelId, effort: selection.effort
        ) else {
            appendMissingKeyHint()
            finishRun(completed: false)
            return
        }
        setPhase(.streaming)
        isStopRequested = false
        activeModelId = model.id
        activeProviderId = selection.providerId
        armStallWatchdog()
        pendingAssistantText = ""
        pendingToolCalls = []
        streamingEntryIndex = nil
        didReceiveMessageEnd = false
        lastStopReason = nil
        didReceiveProviderError = false

        // Mentions resolve here, against the project as it is *now*, and the note rides along
        // with the most recent user message rather than being baked into stored history. Paths
        // only — never file contents; see `FileMentionResolver`.
        var messages = session.turns.map { AgentMessage(role: $0.role, content: $0.content) }
        if let lastUserIndex = messages.lastIndex(where: { $0.role == .user }),
           case .text(let userText)? = messages[lastUserIndex].content.first(where: { if case .text = $0 { return true } else { return false } }) {
            let resolution = FileMentionResolver.resolve(text: userText, projectRoot: rootProvider())
            if let note = FileMentionResolver.contextNote(mentions: resolution.mentions, unresolved: resolution.unresolved) {
                var content = messages[lastUserIndex].content
                content.append(.text(note))
                messages[lastUserIndex] = AgentMessage(role: .user, content: content)
            }
        }
        let mode = modeProvider()
        let tools = ToolExecutor.specs(for: mode.scope)
        // Read per request, off the track's own root: editing the rules file takes effect on
        // the next message rather than the next launch.
        let systemPrompt = Self.systemPrompt(for: mode.scope, projectRules: ProjectRules.load(projectRoot: rootProvider()))
        streamTask = Task {
            var transportError: Error?
            do {
                try await provider.streamTurn(messages: messages, system: systemPrompt, tools: tools) { event in
                    DispatchQueue.main.async { self.handle(event) }
                }
            } catch {
                transportError = error
            }
            let finalError = transportError
            DispatchQueue.main.async {
                self.finishModelTurn(transportError: finalError, modelId: model.id, roundTrip: roundTrip)
            }
        }
    }

    /// The one place a tool's output becomes part of the conversation — and so the one place
    /// that can keep a credential out of both the session file on disk and every future request
    /// that replays it. See `SecretRedactor` for what this can and can't catch.
    private static func toolResult(toolUseId: String, content: String, isError: Bool) -> AgentContentBlock {
        let redaction = SecretRedactor.redacting(content)
        guard redaction.didRedact else {
            return .toolResult(toolUseId: toolUseId, content: content, isError: isError)
        }
        // Told to the model explicitly: without this it may read a redaction marker as the
        // file's literal contents and, say, "fix" a config by writing that string back.
        let note = "\n\n[Side replaced credential-shaped values above before storing this output. The real values are unchanged on disk.]"
        return .toolResult(toolUseId: toolUseId, content: redaction.text + note, isError: isError)
    }


    /// The provider/model/effort this track's next request should use: its own choice where it
    /// has one, the app default otherwise.
    private func resolvedSelection() -> (providerId: String, modelId: String?, effort: AgentEffort) {
        let selection = modelSelectionProvider()
        return (
            selection.providerId ?? ProviderRegistryStore.shared.activeProviderId,
            selection.modelId,
            selection.effort ?? .default
        )
    }

    private func handle(_ event: AgentStreamEvent) {
        // Any event is progress — re-arm regardless of kind, so a model that's slow to finish a
        // tool-call's JSON (all deltas, no text) doesn't trip the watchdog just because
        // `textDelta` specifically went quiet.
        armStallWatchdog()
        switch event {
        case .textDelta(let delta):
            pendingAssistantText += delta
            if let index = streamingEntryIndex, entries.indices.contains(index) {
                updateEntry(at: index, .assistantText(pendingAssistantText))
            } else {
                streamingEntryIndex = appendEntry(.assistantText(pendingAssistantText), resetStreaming: false)
            }
        case .toolUseStart(let id, let name):
            pendingToolCalls.append((id: id, name: name, partialJSON: ""))
        case .toolUseInputDelta(let id, let partialJSON):
            if let index = pendingToolCalls.firstIndex(where: { $0.id == id }) {
                pendingToolCalls[index].partialJSON += partialJSON
            }
        case .toolUseEnd(let id):
            guard let call = pendingToolCalls.first(where: { $0.id == id }) else { return }
            appendEntry(.toolCall(name: call.name, summary: Self.summarize(argumentsJSON: call.partialJSON)))
        case .error(let error):
            appendEntry(.failure(error.message))
            didReceiveProviderError = true
        case .messageEnd(let stopReason, let usage):
            didReceiveMessageEnd = true
            lastStopReason = stopReason
            // Every round trip is billed separately, so this accumulates per streamed turn
            // rather than per user message — a reply that chains four tool calls reports four
            // times, which is what the provider actually charges for.
            if let usage {
                // Kept for the context gauge: a measured count beats an estimate, and the next
                // request is this conversation plus a little.
                lastReportedInputTokens = usage.inputTokens + (usage.cachedInputTokens ?? 0)
                UsageStore.shared.record(
                    projectPath: projectPath, trackKey: trackKey,
                    providerId: activeProviderId,
                    modelId: activeModelId, usage: usage
                )
            }
        }
    }

    private func finishModelTurn(transportError: Error?, modelId: String, roundTrip: Int) {
        stopStallWatchdog()
        streamingEntryIndex = nil
        // Persist what the model produced before doing anything else — even a cancelled or
        // errored turn keeps its partial text, since the model said it and silently dropping it
        // would make the next turn's context lie.
        var content: [AgentContentBlock] = []
        if !pendingAssistantText.isEmpty { content.append(.text(pendingAssistantText)) }
        // Captured before `pendingAssistantText` is cleared below — this is what a checkpoint
        // produced by this round's tool calls (if any) will use as its declared intent.
        let declaredIntent = pendingAssistantText
        let toolCalls = pendingToolCalls
        // A tool_use block is only valid in history alongside its tool_result, so cancelled
        // turns drop the calls rather than persisting a dangling request the API would reject.
        let willRunTools = transportError == nil && !toolCalls.isEmpty
        if willRunTools {
            for call in toolCalls {
                content.append(.toolUse(id: call.id, name: call.name, input: Self.parseArguments(call.partialJSON)))
            }
        }
        if !content.isEmpty {
            sessionStore.appendTurn(AgentTurn(role: .assistant, content: content), trackKey: trackKey, providerId: activeProviderId, modelId: modelId)
        }
        pendingAssistantText = ""
        pendingToolCalls = []

        if let transportError {
            // handleStall() already fully handled this: it appended the "no response" failure
            // and set .blocked(.stalled) itself, before cancelling streamTask — the
            // CancellationError/URLError this produces here is just an echo of that cancellation,
            // not a new failure. Without this guard, finishRun(completed: false) below would
            // silently overwrite .blocked(.stalled) back to .idle moments after it was set
            // (defeating the entire point of a stall being distinguishable from idle in Tracks/
            // dock badge/notifications), and the transcript would show a redundant second error.
            guard case .blocked(.stalled) = phase else {
                if transportError is CancellationError {
                    appendEntry(.meta("Stopped."))
                } else {
                    appendEntry(.failure(transportError.localizedDescription))
                }
                finishRun(completed: false)
                return
            }
            return
        }
        guard willRunTools else {
            // Nothing to run and nothing said. Distinguish the three ways that happens instead
            // of reporting a completed turn the user can't see the result of.
            if content.isEmpty {
                if didReceiveProviderError {
                    // The provider's own error is already in the transcript; don't claim success.
                    finishRun(completed: false)
                } else if !didReceiveMessageEnd {
                    appendEntry(.failure("The response ended before it completed — nothing was received. This is usually a dropped connection or a truncated reply; send again."))
                    finishRun(completed: false)
                } else {
                    appendEntry(.failure(Self.emptyResponseMessage(for: lastStopReason)))
                    finishRun(completed: false)
                }
                return
            }
            finishRun(completed: true)
            return
        }
        setPhase(.runningTools)
        runTools(toolCalls, declaredIntent: declaredIntent, modelId: modelId, roundTrip: roundTrip)
    }

    /// Read tools auto-run with no prompt — they can't change anything. Write tools and
    /// `run_shell_command` produce a proposal and stop, so the loop pauses here until a human
    /// decides (or, for a command on an auto-run track, until it finishes executing). Either way
    /// every tool call gets exactly one result, in the order the model asked, before the next
    /// request.
    private func runTools(_ calls: [(id: String, name: String, partialJSON: String)], declaredIntent: String, modelId: String, roundTrip: Int) {
        let bridge = bridgeProvider()
        // Resolved once for the whole batch — every tool call in one round trip operates
        // against the same root, and the diff computed for any resulting proposal below needs
        // to agree with whatever root actually produced it.
        let root = rootProvider()
        let executor = ToolExecutor(projectRoot: root, liveBufferProvider: { url in
            var result: String?
            if Thread.isMainThread {
                result = bridge.liveBufferProvider(url)
            } else {
                DispatchQueue.main.sync { result = bridge.liveBufferProvider(url) }
            }
            return result
        })
        let parsed = calls.map { (id: $0.id, name: $0.name, input: Self.parseArguments($0.partialJSON)) }
        // Read here, on the main actor, and passed in — the scope that governs a batch is the
        // one in force when its calls arrive, and the executor runs on a background queue.
        let scope = modeProvider().scope
        DispatchQueue.global(qos: .userInitiated).async {
            var outcomes: [(id: String, name: String, result: ToolExecutor.Result)] = []
            for call in parsed {
                outcomes.append((call.id, call.name, executor.execute(name: call.name, input: call.input, toolUseId: call.id, scope: scope)))
            }
            // Each proposal's diff costs two temp-file writes plus a `git diff --no-index`
            // subprocess. Computing them after hopping back to main froze the UI for ~0.5s on a
            // ten-file batch — right at the moment the approval cards appear. They're computed
            // here instead, on the queue that just ran the tools.
            var diffsByToolUseId: [String: String] = [:]
            for outcome in outcomes {
                guard case .proposal(let edit) = outcome.result, !edit.isNewFile else { continue }
                diffsByToolUseId[edit.toolUseId] = GitDiffComputer.unifiedDiffText(
                    original: edit.baseContent, proposed: edit.proposedContent, projectRoot: root
                )
            }
            DispatchQueue.main.async {
                self.handleToolOutcomes(outcomes, root: root, declaredIntent: declaredIntent, modelId: modelId, roundTrip: roundTrip, precomputedDiffs: diffsByToolUseId)
            }
        }
    }

    private func handleToolOutcomes(
        _ outcomes: [(id: String, name: String, result: ToolExecutor.Result)], root: URL, declaredIntent: String, modelId: String, roundTrip: Int,
        precomputedDiffs: [String: String] = [:]
    ) {
        // Results are keyed by tool_use id and reassembled in call order at the end, so a
        // proposal resolved out of order still lands in the right slot.
        var resultsById: [String: AgentContentBlock] = [:]
        var unresolvedToolUseIds: Set<String> = []
        var autoRunEntryIndices: [Int] = []
        var autoApplyEntryIndices: [Int] = []

        for outcome in outcomes {
            switch outcome.result {
            case .completed(let output, let isError):
                appendEntry(.toolResult(text: isError ? "⚠︎ \(outcome.name): \(String(output.prefix(140)))" : "✓ \(outcome.name) — \(Self.describeResultSize(output))", isError: isError))
                resultsById[outcome.id] = Self.toolResult(toolUseId: outcome.id, content: output, isError: isError)
            case .proposal(let edit):
                var diffText = precomputedDiffs[edit.toolUseId]
                    ?? GitDiffComputer.unifiedDiffText(original: edit.baseContent, proposed: edit.proposedContent, projectRoot: root)
                // A brand-new file has no meaningful `git diff` (nothing to diff against), so
                // synthesize one here, eagerly, while `proposedContent` is still around — rather
                // than leaving `diffText` empty and making the view reach into `proposedContent`
                // again later, which is exactly the content `stripContent()` needs to be able to
                // drop once this proposal is resolved.
                if diffText.isEmpty && edit.isNewFile {
                    let lines = edit.proposedContent.components(separatedBy: "\n")
                    diffText = "@@ -0,0 +\(lines.isEmpty ? 0 : 1),\(lines.count) @@\n" + lines.map { "+" + $0 }.joined(separator: "\n")
                }
                let editIndex = appendEntry(.proposal(ProposalPresentation(edit: edit, diffText: diffText, resolution: nil)))
                unresolvedToolUseIds.insert(edit.toolUseId)
                // `.full` autonomy applies edits without a click. Deliberately still routed
                // through the same `resolveEditProposal` the button calls, so an auto-applied
                // edit is indistinguishable afterwards: same transcript entry, same checkpoint,
                // same revert path. See `AgentAutonomy.autoAppliesEdits` for why this exists.
                if modeProvider().autonomy.autoAppliesEdits { autoApplyEntryIndices.append(editIndex) }
            case .commandProposal(let command):
                let index = appendEntry(.commandProposal(CommandPresentation(command: command, resolution: nil)))
                unresolvedToolUseIds.insert(command.toolUseId)
                // A command flagged destructive never benefits from the track's auto-run
                // opt-out — that toggle is meant for "skip approval on ordinary commands," not
                // "let an agent force-push or rm -rf unattended."
                // Allowlist, not "didn't match the destructive blacklist" — see
                // CommandAutoRunPolicy. Anything unrecognized goes to the human.
                if modeProvider().autonomy.autoRunsAllowlistedCommands,
                   CommandAutoRunPolicy.isAutoRunnable(command.command) { autoRunEntryIndices.append(index) }
            }
        }

        guard !unresolvedToolUseIds.isEmpty else {
            continueAfterTools(callOrder: outcomes.map(\.id), resultsById: resultsById, modelId: modelId, roundTrip: roundTrip)
            return
        }

        pendingBatch = PendingToolBatch(
            callOrder: outcomes.map(\.id), resultsById: resultsById, unresolvedToolUseIds: unresolvedToolUseIds,
            lastAppliedURL: nil, roundTrip: roundTrip, modelId: modelId, providerId: activeProviderId, declaredIntent: declaredIntent,
            baselineDirtyPaths: GitPaths.dirtyPaths(cwd: root.path)
        )
        setPhase(.awaitingApproval)
        // Kicked off after `pendingBatch` is in place, since `executeCommand` looks it up to
        // confirm the tool_use is still unresolved before doing anything.
        for index in autoRunEntryIndices { executeCommand(entryIndex: index) }
        for index in autoApplyEntryIndices {
            guard entries.indices.contains(index), case .proposal(let presentation) = entries[index].kind else { continue }
            resolveEditProposal(entryIndex: index, presentation: presentation, decision: .apply)
        }
    }

    private func continueAfterTools(callOrder: [String], resultsById: [String: AgentContentBlock], modelId: String, roundTrip: Int) {
        let blocks = callOrder.compactMap { resultsById[$0] }
        // Results are still persisted before stopping: the model asked for these tools and they
        // ran, so dropping the results would leave a tool_use with no tool_result — the exact
        // shape the API rejects, which would wedge the conversation permanently.
        if isStopRequested, blocks.count == callOrder.count {
            sessionStore.appendTurn(AgentTurn(role: .user, content: blocks), trackKey: trackKey, providerId: activeProviderId, modelId: modelId)
            appendEntry(.meta("Stopped. The tools that were already running finished; nothing new was sent."))
            finishRun(completed: false)
            return
        }
        guard blocks.count == callOrder.count else {
            // Defensive: a missing result would make the next request invalid, so stop cleanly
            // rather than sending a malformed turn.
            appendEntry(.meta("Couldn't assemble tool results for this turn."))
            finishRun(completed: false)
            return
        }
        sessionStore.appendTurn(AgentTurn(role: .user, content: blocks), trackKey: trackKey, providerId: activeProviderId, modelId: modelId)
        runTurn(roundTrip: roundTrip + 1)
    }

    /// `completed` distinguishes a turn that actually finished (the model stopped on its own,
    /// nothing pending) from one that was aborted (transport error, cancellation, an internal
    /// bookkeeping failure) — only the former is worth flagging to Tracks as "done, take a look."
    private func finishRun(completed: Bool) {
        streamTask = nil
        streamingEntryIndex = nil
        if completed {
            hasUnseenCompletion = true
            setPhase(.finishedTurn)
        } else {
            setPhase(.idle)
        }
    }

    // MARK: - Transcript

    @discardableResult
    private func appendEntry(_ kind: RunTranscriptEntry.Kind, resetStreaming: Bool = true) -> Int {
        if resetStreaming { streamingEntryIndex = nil }
        entries.append(RunTranscriptEntry(kind: kind))
        let index = entries.count - 1
        notify(.appended(index))
        return index
    }

    private func updateEntry(at index: Int, _ kind: RunTranscriptEntry.Kind) {
        guard entries.indices.contains(index) else { return }
        entries[index].kind = kind
        notify(.updated(index))
    }

    private func appendMissingKeyHint() {
        let name = ProviderRegistryStore.shared.provider(for: resolvedSelection().providerId)?.displayName ?? "the active provider"
        appendEntry(.meta("No API key found for \(name). Open Settings (⌘,) to add one — it's stored in your Keychain."))
    }

    /// Builds the initial `entries` from whatever's already persisted for this track — the
    /// same transformation `ThinkWorkspaceViewController.renderTranscriptFromSession()` used to
    /// do, just producing data instead of views. Runs once, at construction: after that, this
    /// runner's `entries` is the source of truth, not the session (which it keeps writing to,
    /// but never re-reads wholesale).
    private func hydrateFromSession() {
        // No permanent explainer line — per the design charter, explaining belongs in empty
        // states, not chrome that every conversation carries forever.
        guard let session = sessionStore.session(forTrackKey: trackKey) else { return }
        for turn in session.turns {
            for block in turn.content {
                switch block {
                case .text(let text):
                    appendEntry(turn.role == .user ? .userText(text) : .assistantText(text))
                case .toolUse(_, let name, let input):
                    appendEntry(.toolCall(name: name, summary: Self.summarize(input: input)))
                case .toolResult(_, let content, let isError):
                    appendEntry(.toolResult(text: isError ? "⚠︎ \(content.prefix(140))" : "✓ \(Self.describeResultSize(content))", isError: isError))
                case .image(_, let base64):
                    if let data = Data(base64Encoded: base64) { appendEntry(.userImage(data)) }
                }
            }
        }
    }

    // MARK: - Static helpers

    /// Other git activity in this app (window-subtitle status polling, Tracks' uncommitted-file
    /// counts) can legitimately land at the same instant as a checkpoint's own `git add` — both
    /// sides just want a quick read or a stage, but git's index lock makes even that transient
    /// overlap fail outright with no automatic retry of its own. A short bounded retry absorbs
    /// that instead of surfacing a spurious "checkpoint failed" for what was actually just bad
    /// timing. Caught live, twice: a mixed edit+command batch (the edit's file-reveal triggers a
    /// git-status refresh) reliably reproduced the failure — and a fixed attempt-count retry (3,
    /// then 8, both tried live) still wasn't reliably enough margin, meaning the real contention
    /// window can run longer than a couple seconds (plausible cause: a git-aware shell prompt —
    /// oh-my-zsh's git plugin, starship, powerlevel10k, all common — runs several of its own git
    /// subcommands on every prompt redraw in the very same repo `run_shell_command` just used).
    /// A time-based deadline rather than a fixed attempt count is the more principled fix: keep
    /// retrying for up to `maxWait`, however many attempts that takes, instead of guessing a
    /// count and being wrong about it a second time.
    /// Returns git's own output on failure, not just `false`. Discarding it produced
    /// "couldn't stage 2 paths" — a message that says something went wrong and refuses to say
    /// what, which is precisely the shape this codebase calls out elsewhere as unacceptable.
    @discardableResult
    private nonisolated static func runGitWithRetry(_ args: [String], cwd: String, maxWait: TimeInterval = 5, extraEnvironment: [String: String] = [:]) -> (success: Bool, output: String) {
        let deadline = Date().addingTimeInterval(maxWait)
        while true {
            let result = GitPaths.runGit(args, cwd: cwd, extraEnvironment: extraEnvironment)
            if result.success { return (true, result.output) }
            guard Date() < deadline else { return (false, result.output) }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    /// Commits exactly `paths` without ever consuming the repository's real index.
    ///
    /// The old implementation staged with `git add` and committed with `git commit`, both of
    /// which operate on the shared index — so anything the *user* had already staged rode along
    /// in the agent's commit and got attributed to the agent (reproduced by the audit: a staged
    /// `manual.txt` landing in a checkpoint for `agent.txt`). This builds the commit in a
    /// private index instead: seed it from HEAD, add only the agent's paths, write a tree,
    /// commit that tree with HEAD as parent, then move the branch. The user's index is touched
    /// only at the very end, and only to refresh those same paths so they don't linger as
    /// phantom modifications.
    /// Why this returns a three-valued result instead of an Optional: `nil` used to mean both
    /// "nothing to commit" and "six different git failures", so a checkpoint whose commit
    /// actually failed was reported to the user as a green "✓ Checkpoint … (no file changes)"
    /// and recorded with no SHA — a checkpoint that claimed success, changed nothing, and
    /// couldn't be undone, with the agent's work left uncommitted underneath it. Found by an
    /// audit. Failure now has to be stated.
    enum CheckpointCommitOutcome {
        case committed(sha: String, paths: [String])
        /// The staged tree matched HEAD — the batch genuinely changed nothing on disk.
        case nothingToCommit
        case failed(step: String, message: String)
    }

    private nonisolated static func commitPathsInIsolatedIndex(_ paths: [String], message: String, cwd: String) -> CheckpointCommitOutcome {
        let indexPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("side-checkpoint-index-\(UUID().uuidString)").path
        let environment = ["GIT_INDEX_FILE": indexPath]
        defer { try? FileManager.default.removeItem(atPath: indexPath) }

        let headSHA = GitPaths.runGit(["rev-parse", "HEAD"], cwd: cwd)
        let hasParent = headSHA.success && !headSHA.output.isEmpty
        // Seed from HEAD so the commit's baseline is the last commit, never the user's staged
        // state. A repo with no commits yet starts from an empty index instead.
        if hasParent {
            let readTree = runGitWithRetry(["read-tree", "HEAD"], cwd: cwd, extraEnvironment: environment)
            guard readTree.success else {
                return .failed(step: "read-tree", message: readTree.output)
            }
        }
        let add = runGitWithRetry(["add", "--"] + paths, cwd: cwd, extraEnvironment: environment)
        guard add.success else {
            // Naming the paths matters: the failure is almost always about *which* path was
            // asked for, so a count tells the user nothing they can act on.
            return .failed(step: "add", message: "\(add.output) (paths: \(paths.joined(separator: ", ")))")
        }

        let staged = GitPaths.runGit(["diff", "--cached", "--name-only"] + (hasParent ? ["HEAD"] : []), cwd: cwd, extraEnvironment: environment)
        let committedPaths = staged.success && !staged.output.isEmpty
            ? staged.output.split(separator: "\n").map(String.init) : []
        guard staged.success else {
            return .failed(step: "diff --cached", message: staged.output)
        }
        guard !committedPaths.isEmpty else { return .nothingToCommit }

        let tree = GitPaths.runGit(["write-tree"], cwd: cwd, extraEnvironment: environment)
        guard tree.success, !tree.output.isEmpty else {
            return .failed(step: "write-tree", message: tree.output)
        }
        var commitArgs = ["commit-tree", tree.output, "-m", message]
        if hasParent { commitArgs += ["-p", headSHA.output] }
        let commit = GitPaths.runGit(commitArgs, cwd: cwd, extraEnvironment: environment)
        guard commit.success, !commit.output.isEmpty else {
            return .failed(step: "commit-tree", message: commit.output)
        }
        // `update-ref` with the expected old value: HEAD was read at the top of this function
        // and is the new commit's parent, so if anything committed in between — the user typing
        // `git commit` in the Run terminal, which shares this worktree — moving HEAD
        // unconditionally would orphan their commit. Git refuses the swap instead.
        var updateArgs = ["update-ref", "HEAD", commit.output]
        if hasParent { updateArgs.append(headSHA.output) }
        let update = GitPaths.runGit(updateArgs, cwd: cwd)
        guard update.success else {
            return .failed(step: "update-ref", message: update.output.isEmpty
                ? "the branch moved while the checkpoint was being written"
                : update.output)
        }

        // Refresh just these paths in the real index so they read as committed rather than as
        // modified-vs-index. Explicit pathspecs, so unrelated staged entries stay staged.
        _ = runGitWithRetry(["add", "--"] + paths, cwd: cwd)
        return .committed(sha: commit.output, paths: committedPaths)
    }

    /// A well-formed stream that carried no content at all — legal on the wire, useless to the
    /// user, so it's reported rather than passed off as a finished turn.
    private static func emptyResponseMessage(for stopReason: StopReason?) -> String {
        switch stopReason {
        case .maxTokens:
            return "The response hit the model's output limit before producing anything. Try a shorter request."
        case .stopSequence:
            return "The response stopped immediately on a stop sequence and produced nothing."
        case .other(let reason):
            return "The model returned nothing (\(reason))."
        case .endTurn, .toolUse, .none:
            return "The model returned an empty response. Send again."
        }
    }

    /// The base prompt plus whatever the current scope needs to say about itself. Appended, not
    /// substituted: a read-only scope's tools are already filtered, so this only explains the
    /// shape the agent finds itself in.
    private static func systemPrompt(for scope: AgentToolScope, projectRules: String? = nil) -> String {
        var parts = [systemPrompt]
        if let addendum = scope.systemPromptAddendum { parts.append(addendum) }
        // Project rules come last so they read as the most specific instruction in the prompt,
        // and after the scope addendum so they can't appear to soften it.
        if let projectRules { parts.append(ProjectRules.systemPromptSection(rules: projectRules)) }
        return parts.joined(separator: "\n\n")
    }

    private static let systemPrompt = """
    You are an assistant embedded in Side, a native macOS development environment. You are \
    looking at the user's open project: you can read its files, and you can propose edits with \
    edit_file/write_file, and propose shell commands with run_shell_command. Proposed edits and \
    commands are shown to the user as something they must approve — they do NOT happen when the \
    tool returns, so never claim a change is done or a command has run until the tool result \
    says so. A command you propose runs in the project's own visible terminal (Run), not a \
    hidden process — the user can always see exactly what ran. Prefer reading the actual code \
    over guessing, keep answers concise, and cite file paths and line numbers when referring to \
    code.

    Check your work rather than asserting it: after an edit is applied, read_diagnostics tells \
    you whether it introduced errors, and run_task runs what this project itself uses to build \
    or test (list_tasks shows which). Prefer run_task over run_shell_command for those — its \
    result is recorded against the checkpoint, so the user can see the change was verified. \
    Never claim something works when you have not checked; say what you did and did not verify.
    """

    private static func parseArguments(_ json: String) -> JSONValue {
        // Anthropic sends `{}` as an empty string for zero-argument calls.
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return .object([:]) }
        return value
    }

    /// A compact one-line rendering of a tool call's arguments for the transcript — the point
    /// is that every tool call is visible and attributable, not that the full JSON is shown.
    private static func summarize(argumentsJSON: String) -> String {
        summarize(input: parseArguments(argumentsJSON))
    }

    private static func summarize(input: JSONValue) -> String {
        guard case .object(let object) = input, !object.isEmpty else { return "" }
        let parts = object.keys.sorted().compactMap { key -> String? in
            switch object[key] {
            // Edit payloads (old_string/new_string/content) are shown in the diff card, not
            // dumped into the one-line summary.
            case .string(let value) where key == "old_string" || key == "new_string" || key == "content":
                return "\(key): \(value.components(separatedBy: "\n").count) lines"
            case .string(let value): return "\(key): \(value)"
            case .number(let value): return "\(key): \(Int(value))"
            case .bool(let value): return "\(key): \(value)"
            default: return nil
            }
        }
        return parts.isEmpty ? "" : " (" + parts.joined(separator: ", ") + ")"
    }

    private static func describeResultSize(_ output: String) -> String {
        let lines = output.components(separatedBy: "\n").count
        return lines == 1 ? "1 line" : "\(lines) lines"
    }
}
