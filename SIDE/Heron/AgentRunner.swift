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
    /// Resolved fresh on every use, never captured once — see `WorkspaceBridge`.
    private let bridgeProvider: () -> WorkspaceBridge
    /// The directory this track's tools actually operate in — its linked worktree if it has one,
    /// else the shared project root. Resolved fresh on every tool call/diff/staleness-check
    /// rather than cached, so a track lazily materializing its worktree mid-session (or one
    /// that's just been deleted mid-run) is picked up without any explicit invalidation.
    private let rootProvider: () -> URL
    /// Whether this track has opted out of approval for `run_shell_command`. Resolved fresh per
    /// batch, same reasoning as `rootProvider`.
    private let autoRunCommandsProvider: () -> Bool

    private(set) var entries: [RunTranscriptEntry] = []
    private(set) var phase: AgentRunPhase = .idle
    /// True from the moment a turn finishes cleanly until something acknowledges it — mirrors
    /// `RunSession.hasUnseenOutput`. Only meaningful alongside `.finishedTurn`; see
    /// `AgentActivity.init(phase:hasUnseenCompletion:)`.
    private(set) var hasUnseenCompletion = false
    var activity: AgentActivity { AgentActivity(phase: phase, hasUnseenCompletion: hasUnseenCompletion) }
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

    private static let providerId = "anthropic"
    /// Bounds one send: the model can chain tools, but a loop that never stops asking for them
    /// shouldn't be able to run forever (or bill forever) without the user re-engaging.
    private static let maxToolRoundTrips = 12
    private static let stallTimeout: TimeInterval = 90

    init(
        trackKey: String, sessionStore: AgentSessionStore, bridgeProvider: @escaping () -> WorkspaceBridge,
        rootProvider: @escaping () -> URL, autoRunCommandsProvider: @escaping () -> Bool
    ) {
        self.trackKey = trackKey
        self.sessionStore = sessionStore
        self.bridgeProvider = bridgeProvider
        self.rootProvider = rootProvider
        self.autoRunCommandsProvider = autoRunCommandsProvider
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
        phase = newPhase
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

    func send(_ text: String) {
        guard !phase.isBusy else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard case .ready(_, _, let model) = ProviderRegistryStore.shared.resolveAdapter(providerId: Self.providerId) else {
            appendMissingKeyHint()
            return
        }
        sessionStore.appendTurn(
            AgentTurn(role: .user, content: [.text(trimmed)]),
            trackKey: trackKey, providerId: Self.providerId, modelId: model.id
        )
        appendEntry(.userText(trimmed))
        runTurn(roundTrip: 0)
    }

    func stop() {
        stopStallWatchdog()
        streamTask?.cancel()
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
        sessionStore.appendTurn(AgentTurn(role: .user, content: blocks), trackKey: trackKey, providerId: Self.providerId, modelId: batch.modelId)
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
        updateEntry(at: entryIndex, .proposal(presentation))

        batch.resultsById[presentation.edit.toolUseId] = .toolResult(toolUseId: presentation.edit.toolUseId, content: outcome.toolResultText, isError: outcome.isError)
        batch.unresolvedToolUseIds.remove(presentation.edit.toolUseId)
        if case .applied = outcome {
            batch.lastAppliedURL = presentation.edit.url
            batch.changedFilePaths.insert(presentation.edit.relativePath)
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

        batch.resultsById[toolUseId] = .toolResult(toolUseId: toolUseId, content: resultText, isError: isError)
        batch.unresolvedToolUseIds.remove(toolUseId)
        if case .executed = resolution { batch.commandsRun.append(presentation.command.command) }
        pendingBatch = batch
        finishBatchIfReady()
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
        createCheckpointIfNeeded(batch)
        continueAfterTools(callOrder: batch.callOrder, resultsById: batch.resultsById, modelId: batch.modelId, roundTrip: batch.roundTrip)
    }

    /// A durable record of what this batch actually did, backed by a real git commit on the
    /// track's own branch — the constitution's "an agent run does not equal a branch; it
    /// produces a durable checkpoint." Only created if something was actually applied or
    /// executed (an all-rejected batch has nothing to checkpoint), and only ever after every
    /// proposal in the batch was already resolved — never before, never as a substitute for the
    /// approval clicks themselves.
    private func createCheckpointIfNeeded(_ batch: PendingToolBatch) {
        guard !batch.changedFilePaths.isEmpty || !batch.commandsRun.isEmpty,
              let session = sessionStore.session(forTrackKey: trackKey) else { return }
        let root = rootProvider().path

        // Stage only what this batch actually touched: paths a command left newly dirty (not
        // already dirty before the batch started — that's a concurrent manual edit sitting in
        // the same worktree, not the agent's work) plus every path an approved edit is known for
        // certain to have touched, even if that path happened to already be dirty. Deliberately
        // not `git add -A` — that would sweep any unrelated in-progress change in this worktree
        // into the agent's commit and misattribute it.
        let currentDirtyPaths = GitPaths.dirtyPaths(cwd: root)
        let newlyDirtyPaths = currentDirtyPaths.subtracting(batch.baselineDirtyPaths)
        let pathsToStage = newlyDirtyPaths.union(batch.changedFilePaths)
        guard !pathsToStage.isEmpty else {
            // Everything the batch did left the tree exactly as it already was (e.g. a command
            // that ran but touched nothing) — nothing to checkpoint.
            return
        }
        guard GitPaths.runGit(["add", "--"] + pathsToStage.sorted(), cwd: root).success else {
            appendEntry(.meta("⚠︎ Checkpoint failed: could not stage changed files."))
            return
        }
        let diffNames = GitPaths.runGit(["diff", "--cached", "--name-only"], cwd: root)
        let changedFiles = diffNames.success && !diffNames.output.isEmpty ? diffNames.output.split(separator: "\n").map(String.init) : []

        var commitSHA: String?
        if !changedFiles.isEmpty {
            let message = batch.declaredIntent.trimmingCharacters(in: .whitespacesAndNewlines)
            let commitMessage = message.isEmpty ? "Agent checkpoint" : String(message.prefix(72))
            if GitPaths.runGit(["commit", "-m", commitMessage], cwd: root).success {
                let sha = GitPaths.runGit(["rev-parse", "HEAD"], cwd: root)
                commitSHA = sha.success ? sha.output : nil
            }
        }

        let checkpoint = Checkpoint(
            trackKey: trackKey, agentSessionId: session.id, declaredIntent: batch.declaredIntent,
            changedFilePaths: changedFiles, commandsRun: batch.commandsRun,
            provenance: AgentProvenance(providerId: Self.providerId, modelId: batch.modelId, instructionSourceSummary: "Think conversation"),
            gitCommitSHA: commitSHA
        )
        sessionStore.appendCheckpoint(checkpoint)

        let intentText = checkpoint.declaredIntent.isEmpty ? "no description" : checkpoint.declaredIntent
        let marker = commitSHA.map { "✓ Checkpoint (\(String($0.prefix(7)))): \(intentText)" } ?? "✓ Checkpoint: \(intentText) (no file changes)"
        appendEntry(.meta(marker))
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
        guard case .ready(let provider, _, let model) = ProviderRegistryStore.shared.resolveAdapter(providerId: Self.providerId) else {
            appendMissingKeyHint()
            finishRun(completed: false)
            return
        }
        setPhase(.streaming)
        armStallWatchdog()
        pendingAssistantText = ""
        pendingToolCalls = []
        streamingEntryIndex = nil

        let messages = session.turns.map { AgentMessage(role: $0.role, content: $0.content) }
        let tools = ToolExecutor.specs
        streamTask = Task {
            var transportError: Error?
            do {
                try await provider.streamTurn(messages: messages, system: Self.systemPrompt, tools: tools) { event in
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
        case .messageEnd:
            break // Accounting isn't surfaced yet.
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
            sessionStore.appendTurn(AgentTurn(role: .assistant, content: content), trackKey: trackKey, providerId: Self.providerId, modelId: modelId)
        }
        pendingAssistantText = ""
        pendingToolCalls = []

        if let transportError {
            if transportError is CancellationError {
                appendEntry(.meta("Stopped."))
            } else {
                appendEntry(.failure(transportError.localizedDescription))
            }
            finishRun(completed: false)
            return
        }
        guard willRunTools else {
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
        DispatchQueue.global(qos: .userInitiated).async {
            var outcomes: [(id: String, name: String, result: ToolExecutor.Result)] = []
            for call in parsed {
                outcomes.append((call.id, call.name, executor.execute(name: call.name, input: call.input, toolUseId: call.id)))
            }
            DispatchQueue.main.async {
                self.handleToolOutcomes(outcomes, root: root, declaredIntent: declaredIntent, modelId: modelId, roundTrip: roundTrip)
            }
        }
    }

    private func handleToolOutcomes(
        _ outcomes: [(id: String, name: String, result: ToolExecutor.Result)], root: URL, declaredIntent: String, modelId: String, roundTrip: Int
    ) {
        // Results are keyed by tool_use id and reassembled in call order at the end, so a
        // proposal resolved out of order still lands in the right slot.
        var resultsById: [String: AgentContentBlock] = [:]
        var unresolvedToolUseIds: Set<String> = []
        var autoRunEntryIndices: [Int] = []

        for outcome in outcomes {
            switch outcome.result {
            case .completed(let output, let isError):
                appendEntry(.toolResult(text: isError ? "⚠︎ \(outcome.name): \(String(output.prefix(140)))" : "✓ \(outcome.name) — \(Self.describeResultSize(output))", isError: isError))
                resultsById[outcome.id] = .toolResult(toolUseId: outcome.id, content: output, isError: isError)
            case .proposal(let edit):
                let diffText = GitDiffComputer.unifiedDiffText(original: edit.baseContent, proposed: edit.proposedContent, projectRoot: root)
                appendEntry(.proposal(ProposalPresentation(edit: edit, diffText: diffText, resolution: nil)))
                unresolvedToolUseIds.insert(edit.toolUseId)
            case .commandProposal(let command):
                let index = appendEntry(.commandProposal(CommandPresentation(command: command, resolution: nil)))
                unresolvedToolUseIds.insert(command.toolUseId)
                if autoRunCommandsProvider() { autoRunEntryIndices.append(index) }
            }
        }

        guard !unresolvedToolUseIds.isEmpty else {
            continueAfterTools(callOrder: outcomes.map(\.id), resultsById: resultsById, modelId: modelId, roundTrip: roundTrip)
            return
        }

        pendingBatch = PendingToolBatch(
            callOrder: outcomes.map(\.id), resultsById: resultsById, unresolvedToolUseIds: unresolvedToolUseIds,
            lastAppliedURL: nil, roundTrip: roundTrip, modelId: modelId, declaredIntent: declaredIntent,
            baselineDirtyPaths: GitPaths.dirtyPaths(cwd: root.path)
        )
        setPhase(.awaitingApproval)
        // Kicked off after `pendingBatch` is in place, since `executeCommand` looks it up to
        // confirm the tool_use is still unresolved before doing anything.
        for index in autoRunEntryIndices { executeCommand(entryIndex: index) }
    }

    private func continueAfterTools(callOrder: [String], resultsById: [String: AgentContentBlock], modelId: String, roundTrip: Int) {
        let blocks = callOrder.compactMap { resultsById[$0] }
        guard blocks.count == callOrder.count else {
            // Defensive: a missing result would make the next request invalid, so stop cleanly
            // rather than sending a malformed turn.
            appendEntry(.meta("Couldn't assemble tool results for this turn."))
            finishRun(completed: false)
            return
        }
        sessionStore.appendTurn(AgentTurn(role: .user, content: blocks), trackKey: trackKey, providerId: Self.providerId, modelId: modelId)
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
        appendEntry(.meta("No Anthropic API key found. Open Settings (⌘,) to add one — it's stored in your Keychain."))
    }

    /// Builds the initial `entries` from whatever's already persisted for this track — the
    /// same transformation `ThinkWorkspaceViewController.renderTranscriptFromSession()` used to
    /// do, just producing data instead of views. Runs once, at construction: after that, this
    /// runner's `entries` is the source of truth, not the session (which it keeps writing to,
    /// but never re-reads wholesale).
    private func hydrateFromSession() {
        appendEntry(.meta("Think — talk to a model about this project. It can read your files, propose edits, and propose commands to run; conversations are saved per track."))
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
                }
            }
        }
    }

    // MARK: - Static helpers

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
