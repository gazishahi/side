import Foundation

/// A track's conversation run by an outside agent over the Agent Client Protocol
/// (`SIDE_RFC_BYO_HARNESS.md`). The agent's replies, reasoning and tool activity stream into the
/// same transcript Heron fills; its permission prompts become cards (step 2).
///
/// Step 3 offers the agent Side's files and terminals:
/// - **Reads** (`fs/read_text_file`) are contained to the worktree and see unsaved buffers; what
///   was served is remembered as that file's base.
/// - **Writes** (`fs/write_text_file`) go through `ProposedEditApplier`. One approval per edit
///   (D9): a write the user already allowed through the agent's permission card applies without
///   a second card; an unannounced write follows the track's autonomy exactly as Heron's edits
///   do — Full applies, Manual and Guarded show a card. A write whose base moved is refused.
/// - **Terminals** (`terminal/*`) are their own Run tabs (`ACPTerminalHost`).
/// - **Every turn that changed files ends in a checkpoint**, however the files were written —
///   staging what the agent touched plus what newly became dirty, minus what the user saved
///   during the turn (`UserSaveLog`).
@MainActor
public final class ACPHarness: Harness {
    public let trackKey: String
    public let agent: ACPAgent
    public var harnessName: String? { agent.displayName }

    public private(set) var entries: [RunTranscriptEntry] = []
    public private(set) var phase: AgentRunPhase = .idle
    public private(set) var needsYouSince: Date?
    public var activity: AgentActivity { AgentActivity(phase: phase, hasUnseenCompletion: hasUnseenCompletion) }
    public var hasCommandAwaitingApproval: Bool { !pendingPermissions.isEmpty || !pendingWrites.isEmpty }
    public var appliedEditCounts: [(path: String, added: Int, removed: Int)] {
        appliedCounts.map { (path: $0.key, added: $0.value.added, removed: $0.value.removed) }.sorted { $0.path < $1.path }
    }
    public var archivedConversations: [ArchivedConversation] { [] }
    public var runningUserTaskName: String? { nil }
    public var pendingUserTaskProposalId: UUID? { nil }

    /// Readiness is only known once the agent has been looked for, which takes a login-shell
    /// spawn; until a launch fails, sending is allowed and a missing agent is reported inline.
    public var isReadyToSend: Bool { true }
    public var notReadyReason: String { "" }

    private let launchProvider: @Sendable () -> ACPLaunch?
    private let rootProvider: () -> URL
    private let bridgeProvider: () -> WorkspaceBridge
    private let modeProvider: () -> AgentMode
    private let sessionStore: AgentSessionStore?
    private let terminalHostProvider: () -> ACPTerminalHost?
    /// Identifies this harness's terminals to the host, so Stop ends exactly these.
    private let ownerId = UUID()
    /// Files a checkpoint under this conversation — an outside session has no `AgentSession`.
    private var conversationId = UUID()
    private var observers: [UUID: (AgentRunEvent) -> Void] = [:]
    private var hasUnseenCompletion = false
    private var connection: ACPConnection?
    private var sessionId: String?
    private var streamingIndex: Int?
    private var thinkingIndex: Int?
    private var toolEntryIndex: [String: Int] = [:]
    /// Permission cards waiting for an answer: entry id → the agent's request, and the files its
    /// tool call names (a write to one of them, once allowed, needs no second card — D9).
    private struct PendingPermission { let requestId: Any; let paths: Set<String> }
    private var pendingPermissions: [UUID: PendingPermission] = [:]
    /// Edit cards for unannounced writes, waiting on Apply/Reject: entry id → request and edit.
    private var pendingWrites: [UUID: (requestId: Any, edit: ProposedEdit)] = [:]
    /// Absolute paths the user allowed the agent to change, through its own permission card.
    private var grantedPaths: Set<String> = []
    /// Absolute path → the content the agent was last shown (a read, or a diff's `oldText`) —
    /// the base a later write must still match.
    private var bases: [String: String] = [:]
    /// Tool call id → its kind and the absolute paths it names.
    private var toolCalls: [String: (kind: String?, paths: Set<String>)] = [:]
    // The turn in flight, for its checkpoint.
    private var turnBaseline: Set<String>?
    private var turnStartedAt = Date()
    /// Worktree-relative paths the agent is known to have changed this turn.
    private var turnTouched: Set<String> = []
    private var turnCommands: [String] = []
    private var turnPrompt = ""
    private var appliedCounts: [String: (added: Int, removed: Int)] = [:]
    private var usage: (used: Int, size: Int)?
    /// What the agent says it's running as — model, effort, mode (its `configOptions`) and
    /// account (`_auth/status_update`) — shown when a session opens.
    private var sessionSettings: [(id: String, value: String)] = []
    private var accountLabel: String?
    /// Fires when a turn has gone silent too long (`stallInterval`).
    private var stallWorkItem: DispatchWorkItem?
    /// `terminal/wait_for_exit` calls still waiting on a command — silence then is a command
    /// running, not a hang.
    private var waitingOnTerminals = 0
    /// Longer than Heron's 90 s: an outside agent can think or run its own tools without
    /// streaming anything for a while.
    var stallInterval: TimeInterval = 180
    /// The agent is being found and launched; a second send waits for that to finish.
    private var starting = false

    public init(trackKey: String, agent: ACPAgent, launchProvider: @escaping @Sendable () -> ACPLaunch?, rootProvider: @escaping () -> URL,
                bridgeProvider: @escaping () -> WorkspaceBridge = { .none }, modeProvider: @escaping () -> AgentMode = { .default },
                sessionStore: AgentSessionStore? = nil, terminalHost: @escaping () -> ACPTerminalHost? = { nil }) {
        self.trackKey = trackKey
        self.agent = agent
        self.launchProvider = launchProvider
        self.rootProvider = rootProvider
        self.bridgeProvider = bridgeProvider
        self.modeProvider = modeProvider
        self.sessionStore = sessionStore
        self.terminalHostProvider = terminalHost
    }

    // MARK: Observation

    @discardableResult
    public func addObserver(_ observer: @escaping (AgentRunEvent) -> Void) -> UUID {
        let token = UUID()
        observers[token] = observer
        return token
    }

    public func removeObserver(_ token: UUID) { observers.removeValue(forKey: token) }

    private func notify(_ event: AgentRunEvent) { for observer in observers.values { observer(event) } }

    private func setPhase(_ newPhase: AgentRunPhase) {
        guard phase != newPhase else { return }
        let wasNeedsYou = activity == .needsYou
        phase = newPhase
        // Waiting on the user isn't the agent hanging.
        if newPhase == .awaitingApproval { disarmStallTimer() } else if newPhase == .streaming || newPhase == .runningTools { armStallTimer() }
        let isNeedsYou = activity == .needsYou
        if isNeedsYou, !wasNeedsYou { needsYouSince = Date() } else if !isNeedsYou { needsYouSince = nil }
        notify(.phaseChanged)
    }

    @discardableResult
    private func append(_ kind: RunTranscriptEntry.Kind) -> Int {
        entries.append(RunTranscriptEntry(kind: kind))
        let index = entries.count - 1
        notify(.appended(index))
        return index
    }

    private func replace(_ index: Int, _ kind: RunTranscriptEntry.Kind) {
        guard entries.indices.contains(index) else { return }
        entries[index].kind = kind
        notify(.updated(index))
    }

    // MARK: Sending

    public func send(_ text: String, attachments: [AgentImageAttachment]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !phase.isBusy, !starting else { return }
        append(.userText(trimmed))
        streamingIndex = nil
        thinkingIndex = nil
        setPhase(.streaming)
        turnPrompt = trimmed
        turnTouched = []
        turnCommands = []
        turnStartedAt = Date()
        grantedPaths = []
        // What was already dirty before the agent starts — the checkpoint won't claim it. One
        // git spawn, off the main thread, before the prompt goes out.
        let root = rootProvider().path
        starting = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let baseline = GitPaths.dirtyPaths(cwd: root)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.starting = false
                    self.turnBaseline = baseline
                    self.withSession { [weak self] sessionId in
                        self?.prompt(trimmed, sessionId: sessionId)
                    }
                }
            }
        }
    }

    private func prompt(_ text: String, sessionId: String) {
        armStallTimer()
        connection?.request("session/prompt", params: [
            "sessionId": sessionId,
            "prompt": [["type": "text", "text": text]],
        ]) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let value):
                let stopReason = (value as? [String: Any])?["stopReason"] as? String ?? "end_turn"
                self.finishTurn(stopReason: stopReason)
            case .failure(let error):
                self.fail(error.localizedDescription)
            }
        }
    }

    private func finishTurn(stopReason: String) {
        disarmStallTimer()
        streamingIndex = nil
        thinkingIndex = nil
        answerPendingPermissions(with: nil)
        settlePendingWrites(reason: "The turn ended before this edit was decided. The file is unchanged.")
        // Whatever the turn changed is checkpointed, cancelled or not — Stop doesn't undo writes
        // that already landed, and they stay reviewable and reversible (D1).
        checkpointTurn()
        switch stopReason {
        case "cancelled":
            setPhase(.idle)
            return
        case "refusal": append(.meta("\(agent.displayName) declined to continue."))
        case "max_tokens": append(.meta("\(agent.displayName) stopped at its output limit — send another message to continue."))
        case "max_turn_requests": append(.meta("\(agent.displayName) reached its turn limit — send another message to continue."))
        default: break
        }
        hasUnseenCompletion = true
        setPhase(.finishedTurn)
    }

    private func fail(_ message: String) {
        disarmStallTimer()
        streamingIndex = nil
        thinkingIndex = nil
        answerPendingPermissions(with: nil)
        settlePendingWrites(reason: "The agent stopped before this edit was decided. The file is unchanged.")
        checkpointTurn()
        append(.failure(message))
        setPhase(.blocked(.failed))
    }

    // MARK: Session

    /// Launches the agent, negotiates the protocol, and opens a session in the track's worktree
    /// — once; later messages reuse it.
    private func withSession(_ body: @escaping (String) -> Void) {
        if let sessionId, connection?.isRunning == true { body(sessionId); return }
        starting = true
        let launchProvider = self.launchProvider
        let agent = self.agent
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Finding the agent asks the login shell, so it stays off the main thread.
            let launch = launchProvider()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.starting = false
                    guard let launch else {
                        self.fail("\(agent.displayName) isn't installed, or isn't on your shell's PATH. Install it with:\n\n\(agent.installHint)")
                        return
                    }
                    self.start(launch, then: body)
                }
            }
        }
    }

    private func start(_ launch: ACPLaunch, then body: @escaping (String) -> Void) {
        let root = rootProvider()
        let connection: ACPConnection
        do {
            connection = try ACPConnection(launch: launch, cwd: root)
        } catch {
            fail("Couldn't start \(agent.displayName): \(error.localizedDescription)")
            return
        }
        self.connection = connection
        connection.onNotification = { [weak self] method, params in self?.handleNotification(method, params) }
        connection.onRequest = { [weak self] id, method, params in self?.handleRequest(id: id, method: method, params: params) }
        connection.onExit = { [weak self] message in
            guard let self else { return }
            self.sessionId = nil
            self.connection = nil
            if self.phase.isBusy || self.phase == .awaitingApproval { self.fail(message) }
        }
        connection.request("initialize", params: [
            "protocolVersion": 1,
            // Side's files (contained, unsaved-buffer-aware, approval per D9) and — when the app
            // provides them — Side's terminals, as visible Run tabs.
            "clientCapabilities": ["fs": ["readTextFile": true, "writeTextFile": true], "terminal": terminalHostProvider() != nil],
            "clientInfo": ["name": "side", "title": "Side", "version": "1"],
        ]) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.fail("\(self.agent.displayName) didn't start: \(error.localizedDescription)")
            case .success(let value):
                let version = ((value as? [String: Any])?["protocolVersion"] as? NSNumber)?.intValue ?? 1
                guard version == 1 else {
                    self.fail("\(self.agent.displayName) speaks ACP version \(version); Side speaks version 1.")
                    connection.terminate()
                    return
                }
                connection.request("session/new", params: ["cwd": root.path, "mcpServers": [Any]()]) { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .failure(let error):
                        self.fail(Self.explain(error, agent: self.agent))
                    case .success(let value):
                        guard let id = (value as? [String: Any])?["sessionId"] as? String else {
                            self.fail("\(self.agent.displayName) didn't open a session.")
                            return
                        }
                        self.sessionId = id
                        self.sessionSettings = Self.settings(from: value)
                        self.describeSession()
                        body(id)
                    }
                }
            }
        }
    }

    /// Agents that need a login say so when a session is requested; point at the CLI's own login.
    private static func explain(_ error: Error, agent: ACPAgent) -> String {
        let text = error.localizedDescription
        if text.localizedCaseInsensitiveContains("auth") || text.localizedCaseInsensitiveContains("login") {
            return "\(agent.displayName) needs you to sign in. Run its CLI once in a terminal to log in, then try again.\n\n(\(text))"
        }
        return "\(agent.displayName) couldn't open a session: \(text)"
    }

    // MARK: Updates from the agent

    private func handleNotification(_ method: String, _ params: [String: Any]) {
        armStallTimerIfRunning()
        if method == "_auth/status_update", let status = params["authStatus"] as? [String: Any] {
            // "Claude Team", or "Anthropic API key" — which one pays matters to the user.
            accountLabel = status["label"] as? String
            return
        }
        guard method == "session/update", let update = params["update"] as? [String: Any],
              let kind = update["sessionUpdate"] as? String else { return }
        switch kind {
        case "agent_message_chunk":
            guard let text = Self.text(update["content"]) else { return }
            thinkingIndex = nil
            if let index = streamingIndex, case .assistantText(let existing) = entries[index].kind {
                replace(index, .assistantText(existing + text))
            } else {
                streamingIndex = append(.assistantText(text))
            }
        case "agent_thought_chunk":
            guard let text = Self.text(update["content"]) else { return }
            if let index = thinkingIndex, case .thinking(let existing) = entries[index].kind {
                replace(index, .thinking(existing + text))
            } else {
                thinkingIndex = append(.thinking(text))
            }
        case "tool_call":
            streamingIndex = nil
            thinkingIndex = nil
            let id = update["toolCallId"] as? String ?? UUID().uuidString
            let title = update["title"] as? String ?? "Working"
            noteToolCall(id: id, update)
            if update["status"] as? String == "completed" { markTouched(byToolCall: id) }
            toolEntryIndex[id] = append(.toolCall(name: title, summary: Self.locationSummary(update["locations"], besides: title)))
            if phase == .streaming { setPhase(.runningTools) }
        case "tool_call_update":
            let id = update["toolCallId"] as? String ?? ""
            noteToolCall(id: id, update)
            if update["status"] as? String == "completed" { markTouched(byToolCall: id) }
            guard let index = toolEntryIndex[id], case .toolCall(let name, let summary) = entries[index].kind else { return }
            let title = update["title"] as? String ?? name
            let locations = update["locations"] != nil ? Self.locationSummary(update["locations"], besides: title) : summary
            // The result folds into its own tool line — a permission card can sit between the
            // call and its completion, and a separate result line then landed in a new, empty
            // "Worked for…" group of its own.
            switch update["status"] as? String {
            case "completed":
                replace(index, .toolCall(name: title, summary: locations + " — ✓ " + Self.resultSummary(update["content"])))
                if phase == .runningTools { setPhase(.streaming) }
            case "failed":
                replace(index, .toolCall(name: title, summary: locations + " — ⚠︎ " + Self.resultSummary(update["content"])))
                if phase == .runningTools { setPhase(.streaming) }
            default:
                if title != name || locations != summary { replace(index, .toolCall(name: title, summary: locations)) }
            }
        case "usage_update":
            if let used = (update["used"] as? NSNumber)?.intValue, let size = (update["size"] as? NSNumber)?.intValue, size > 0 {
                usage = (used, size)
            }
        default:
            break // plans, command lists, mode changes: not shown yet
        }
    }

    private func handleRequest(id: Any, method: String, params: [String: Any]) {
        armStallTimerIfRunning()
        switch method {
        case "session/request_permission": requestPermission(id: id, params: params)
        case "fs/read_text_file": readTextFile(id: id, params: params)
        case "fs/write_text_file": writeTextFile(id: id, params: params)
        case "terminal/create", "terminal/output", "terminal/wait_for_exit", "terminal/kill", "terminal/release":
            handleTerminal(id: id, method: method, params: params)
        default:
            connection?.respondError(id: id, code: -32601, message: "Side doesn't offer \(method).")
        }
    }

    private func requestPermission(id: Any, params: [String: Any]) {
        let toolCall = params["toolCall"] as? [String: Any]
        let toolCallId = toolCall?["toolCallId"] as? String
        if let toolCall, let toolCallId { noteToolCall(id: toolCallId, toolCall) }
        let paths = toolCallId.flatMap { toolCalls[$0]?.paths } ?? []
        let title = (toolCall?["title"] as? String) ?? toolCall.flatMap { ($0["toolCallId"] as? String).flatMap { toolEntryIndex[$0] } }.flatMap { index -> String? in
            if case .toolCall(let name, _) = entries[index].kind { return name }
            return nil
        } ?? "\(agent.displayName) wants to continue"
        let options = (params["options"] as? [[String: Any]] ?? []).compactMap { option -> PermissionPresentation.Option? in
            guard let optionId = option["optionId"] as? String else { return nil }
            return PermissionPresentation.Option(id: optionId, name: option["name"] as? String ?? optionId,
                                                 kind: (option["kind"] as? String).flatMap(PermissionPresentation.Option.Kind.init(rawValue:)))
        }
        let index = append(.permissionRequest(PermissionPresentation(title: title, options: options)))
        pendingPermissions[entries[index].id] = PendingPermission(requestId: id, paths: paths)
        setPhase(.awaitingApproval)
    }

    public func answerPermission(proposalId: UUID, optionId: String?) {
        guard let pending = pendingPermissions.removeValue(forKey: proposalId),
              let index = entries.firstIndex(where: { $0.id == proposalId }),
              case .permissionRequest(var presentation) = entries[index].kind else { return }
        let requestId = pending.requestId
        if let optionId {
            connection?.respond(id: requestId, result: ["outcome": ["outcome": "selected", "optionId": optionId]])
            let chosen = presentation.options.first { $0.id == optionId }
            presentation.chosenOptionName = chosen?.name ?? optionId
            // Allowed: the diff was on this card, so a write it leads to needs no second one.
            if chosen?.kind == .allowOnce || chosen?.kind == .allowAlways { grantedPaths.formUnion(pending.paths) }
        } else {
            connection?.respond(id: requestId, result: ["outcome": ["outcome": "cancelled"]])
            presentation.chosenOptionName = "Cancelled"
        }
        replace(index, .permissionRequest(presentation))
        resumeIfNothingPending()
    }

    private func resumeIfNothingPending() {
        if pendingPermissions.isEmpty, pendingWrites.isEmpty, phase == .awaitingApproval { setPhase(.streaming) }
    }

    private func answerPendingPermissions(with optionId: String?) {
        for id in Array(pendingPermissions.keys) { answerPermission(proposalId: id, optionId: optionId) }
    }

    // MARK: Other actions

    public func stop() {
        answerPendingPermissions(with: nil)
        settlePendingWrites(reason: "Stopped before this edit was decided. The file is unchanged.")
        // The commands stop too; their tabs stay so the output can still be read.
        terminalHostProvider()?.endAll(owner: ownerId, closeTabs: false)
        if let sessionId { connection?.notify("session/cancel", params: ["sessionId": sessionId]) }
        // The prompt's own response arrives with stopReason "cancelled" and settles the phase;
        // if the agent is gone, settle it here.
        if connection?.isRunning != true { setPhase(.idle) }
    }

    /// Apply or Reject on the card an unannounced write produced (D9, Manual and Guarded).
    public func resolve(proposalId: UUID, decision: ProposalDecision) {
        guard let pending = pendingWrites.removeValue(forKey: proposalId) else { return }
        switch decision {
        case .apply:
            let outcome = apply(pending.edit, requestId: pending.requestId)
            setResolution(proposalId, ProposalPresentation.Resolution(outcome))
        case .reject:
            connection?.respondError(id: pending.requestId, code: -32000, message: ProposedEditOutcome.rejected.toolResultText)
            setResolution(proposalId, .rejected)
        }
        resumeIfNothingPending()
    }

    public func acknowledgeCompletion() {
        guard hasUnseenCompletion else { return }
        hasUnseenCompletion = false
        notify(.phaseChanged)
    }

    public func editableMessage(turnId: UUID) -> (text: String, attachments: [AgentImageAttachment])? { nil }
    public func editAndResend(turnId: UUID, text: String, attachments: [AgentImageAttachment]) { send(text, attachments: attachments) }

    public func compact(completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.failure(ACPConnection.RemoteError(code: -32601, message: "\(agent.displayName) manages its own context.")))
    }

    /// A fresh conversation is a fresh session: the next message opens a new one.
    public func startNewConversation() {
        guard !phase.isBusy else { return }
        sessionId = nil
        entries.removeAll()
        toolEntryIndex.removeAll()
        toolCalls.removeAll()
        bases.removeAll()
        appliedCounts.removeAll()
        conversationId = UUID()
        usage = nil
        notify(.reset)
        setPhase(.idle)
    }

    public func openArchivedConversation(id: UUID) -> Bool { false }

    public func contextUsage() -> (usedTokens: Int, windowTokens: Int, fraction: Double, status: ContextBudget.Status) {
        guard let usage else { return (0, 0, 0, .comfortable) }
        let fraction = Double(usage.used) / Double(usage.size)
        let status: ContextBudget.Status = fraction >= 0.9 ? .critical : (fraction >= 0.7 ? .approaching : .comfortable)
        return (usage.used, usage.size, fraction, status)
    }

    /// Run's task chips stay with Heron for now (RFC D8 is plan step 4).
    public func proposeUserTask(_ task: ProjectTask) -> UUID? { nil }

    public func teardown() {
        disarmStallTimer()
        answerPendingPermissions(with: nil)
        settlePendingWrites(reason: "The conversation closed before this edit was decided. The file is unchanged.")
        terminalHostProvider()?.endAll(owner: ownerId, closeTabs: true)
        connection?.terminate()
        connection = nil
        sessionId = nil
    }


    // MARK: Files (plan step 3a/3b)

    /// Worktree-relative, the shape `GitPaths.dirtyPaths` uses. Both sides symlink-resolved
    /// (`/var` is `/private/var`).
    nonisolated static func relative(_ url: URL, root: URL) -> String {
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    /// A path the agent named, resolved and contained to the track's worktree — or nil.
    private func contained(_ path: String) -> URL? {
        ProjectFileAccess.resolveInsideProject(path: path, root: rootProvider())
    }

    /// What the file holds right now: the open buffer (unsaved edits included), else disk. Nil
    /// when the file doesn't exist; `.binary` when it isn't text.
    private enum Current { case missing, binary, text(String) }
    private func currentContent(_ url: URL) -> Current {
        if let live = bridgeProvider().liveBufferProvider(url) { return .text(live) }
        guard let data = try? Data(contentsOf: url) else { return .missing }
        if TextFileCodec.looksBinary(data) { return .binary }
        return TextFileCodec.decode(data).map { .text($0.text) } ?? .binary
    }

    private func readTextFile(id: Any, params: [String: Any]) {
        guard let path = params["path"] as? String, let url = contained(path) else {
            connection?.respondError(id: id, code: -32602, message: "Refused: that path is outside this track's working copy.")
            return
        }
        guard ProjectFileAccess.isReadable(url, root: rootProvider()) else {
            connection?.respondError(id: id, code: -32602, message: "Refused: Side's own state isn't readable.")
            return
        }
        switch currentContent(url) {
        case .missing:
            connection?.respondError(id: id, code: -32002, message: "No such file: \(path)")
        case .binary:
            connection?.respondError(id: id, code: -32000, message: "\(url.lastPathComponent) isn't a text file.")
        case .text(let text):
            bases[url.path] = text
            connection?.respond(id: id, result: ["content": Self.slice(text, line: (params["line"] as? NSNumber)?.intValue, limit: (params["limit"] as? NSNumber)?.intValue)])
        }
    }

    /// `line` is 1-based; `limit` is a line count.
    static func slice(_ text: String, line: Int?, limit: Int?) -> String {
        guard line != nil || limit != nil else { return text }
        let lines = text.components(separatedBy: "\n")
        let start = max(0, (line ?? 1) - 1)
        guard start < lines.count else { return "" }
        let end = limit.map { min(lines.count, start + max(0, $0)) } ?? lines.count
        return lines[start..<end].joined(separator: "\n")
    }

    private func writeTextFile(id: Any, params: [String: Any]) {
        guard let path = params["path"] as? String, let content = params["content"] as? String, let url = contained(path) else {
            connection?.respondError(id: id, code: -32602, message: "Refused: that path is outside this track's working copy.")
            return
        }
        let root = rootProvider()
        guard ProjectFileAccess.isWritable(url, root: root) else {
            connection?.respondError(id: id, code: -32602, message: "Refused: \(url.lastPathComponent) is in a location Side doesn't let agents write (.git, .side).")
            return
        }
        // The base: what the agent was shown. A write computed against anything else would
        // overwrite whatever happened since — unsaved typing included.
        let base: String?
        switch currentContent(url) {
        case .binary:
            connection?.respondError(id: id, code: -32000, message: "Refused: \(url.lastPathComponent) isn't a text file.")
            return
        case .missing:
            base = nil
        case .text(let now):
            guard let seen = bases[url.path] else {
                connection?.respondError(id: id, code: -32000, message: "Refused: \(url.lastPathComponent) already exists and hasn't been read. Read it with fs/read_text_file first, then write.")
                return
            }
            guard seen == now else {
                connection?.respondError(id: id, code: -32000, message: "Refused: \(url.lastPathComponent) changed since you read it. Read it again, then write.")
                return
            }
            base = now
        }
        let relative = Self.relative(url, root: root)
        let edit = ProposedEdit(toolUseId: "acp", url: url, relativePath: relative,
                                baseContent: base ?? "", proposedContent: content, isNewFile: base == nil)
        // D9: allowed on the agent's own card, or Full autonomy → no second card.
        if grantedPaths.contains(url.path) || modeProvider().autonomy.autoAppliesEdits {
            _ = apply(edit, requestId: id)
            return
        }
        // Unannounced, and the track asks first: a card, like Heron's. The diff is computed off
        // the main thread (a `git diff` spawn), then the card appears.
        let original = base ?? ""
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let diff = GitDiffComputer.unifiedDiffText(original: original, proposed: content, projectRoot: root)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.streamingIndex = nil
                    self.thinkingIndex = nil
                    let index = self.append(.proposal(ProposalPresentation(edit: edit, diffText: diff, resolution: nil)))
                    self.pendingWrites[self.entries[index].id] = (id, edit)
                    self.setPhase(.awaitingApproval)
                }
            }
        }
    }

    /// The one way an outside agent's write reaches disk: disk first, then the open buffer,
    /// refusing if the base moved in the meantime.
    @discardableResult
    private func apply(_ edit: ProposedEdit, requestId: Any) -> ProposedEditOutcome {
        let bridge = bridgeProvider()
        let applier = ProposedEditApplier(applyIntoOpenTab: bridge.applyEditIntoOpenTab) { [weak self] url in
            guard let self, case .text(let text) = self.currentContent(url) else { return nil }
            return text
        }
        let outcome = applier.apply(edit)
        if case .applied = outcome {
            bases[edit.url.path] = edit.proposedContent
            turnTouched.insert(edit.relativePath)
            connection?.respond(id: requestId, result: [:])
            countLines(edit)
        } else {
            connection?.respondError(id: requestId, code: -32000, message: outcome.toolResultText)
        }
        return outcome
    }

    private func countLines(_ edit: ProposedEdit) {
        let (base, proposed, path, root) = (edit.baseContent, edit.proposedContent, edit.relativePath, rootProvider())
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let delta = AgentRunner.lineDelta(in: GitDiffComputer.unifiedDiffText(original: base, proposed: proposed, projectRoot: root))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let existing = self.appliedCounts[path] ?? (0, 0)
                    self.appliedCounts[path] = (existing.added + delta.added, existing.removed + delta.removed)
                    self.notify(.phaseChanged)
                }
            }
        }
    }

    private func setResolution(_ entryId: UUID, _ resolution: ProposalPresentation.Resolution) {
        guard let index = entries.firstIndex(where: { $0.id == entryId }), case .proposal(var presentation) = entries[index].kind else { return }
        presentation.resolution = resolution
        presentation.edit.stripContent()
        replace(index, .proposal(presentation))
    }

    private func settlePendingWrites(reason: String) {
        for (entryId, pending) in pendingWrites {
            connection?.respondError(id: pending.requestId, code: -32000, message: reason)
            setResolution(entryId, .rejected)
        }
        pendingWrites.removeAll()
    }

    /// Paths and diff bases from a tool call or its update.
    private func noteToolCall(id: String, _ update: [String: Any]) {
        var entry = toolCalls[id] ?? (kind: nil, paths: [])
        if let kind = update["kind"] as? String { entry.kind = kind }
        for location in update["locations"] as? [[String: Any]] ?? [] {
            if let path = location["path"] as? String, let url = contained(path) { entry.paths.insert(url.path) }
        }
        for item in update["content"] as? [[String: Any]] ?? [] where item["type"] as? String == "diff" {
            guard let path = item["path"] as? String, let url = contained(path) else { continue }
            entry.paths.insert(url.path)
            // The agent's own view of the file before its change — a base for a write that
            // follows, when it read the file with its own tools rather than Side's.
            if let old = item["oldText"] as? String, bases[url.path] == nil { bases[url.path] = old }
        }
        toolCalls[id] = entry
    }

    /// A completed tool call that changes files: its paths are the agent's in this turn's
    /// checkpoint. Reads and searches don't count — a file the user already had dirty mustn't be
    /// committed just because the agent looked at it.
    private func markTouched(byToolCall id: String) {
        guard let call = toolCalls[id], ["edit", "delete", "move"].contains(call.kind ?? "") || call.kind == nil && !call.paths.isEmpty else { return }
        let root = rootProvider()
        for path in call.paths { turnTouched.insert(Self.relative(URL(fileURLWithPath: path), root: root)) }
    }

    // MARK: Terminals (plan step 3a/3c)

    private func handleTerminal(id: Any, method: String, params: [String: Any]) {
        guard let host = terminalHostProvider() else {
            connection?.respondError(id: id, code: -32601, message: "Side doesn't offer terminals here.")
            return
        }
        let terminalId = params["terminalId"] as? String ?? ""
        switch method {
        case "terminal/create":
            guard let command = params["command"] as? String, !command.isEmpty else {
                connection?.respondError(id: id, code: -32602, message: "terminal/create needs a command.")
                return
            }
            let root = rootProvider()
            let cwd: URL
            if let requested = params["cwd"] as? String {
                guard let inside = contained(requested) else {
                    connection?.respondError(id: id, code: -32602, message: "Refused: \(requested) is outside this track's working copy.")
                    return
                }
                cwd = inside
            } else {
                cwd = root
            }
            let arguments = params["args"] as? [String] ?? []
            var environment: [String: String] = [:]
            for variable in params["env"] as? [[String: Any]] ?? [] {
                if let name = variable["name"] as? String, let value = variable["value"] as? String { environment[name] = value }
            }
            let limit = (params["outputByteLimit"] as? NSNumber)?.intValue ?? 1_000_000
            do {
                let terminalId = try host.createTerminal(trackKey: trackKey, command: command, arguments: arguments, environment: environment,
                                                         cwd: cwd, outputByteLimit: limit, owner: ownerId)
                turnCommands.append(([command] + arguments).joined(separator: " "))
                connection?.respond(id: id, result: ["terminalId": terminalId])
            } catch {
                connection?.respondError(id: id, code: -32000, message: "Couldn't start \(command): \(error.localizedDescription)")
            }
        case "terminal/output":
            guard let output = host.output(of: terminalId) else { return unknownTerminal(id) }
            var result: [String: Any] = ["output": output.output, "truncated": output.truncated]
            if let exit = output.exit { result["exitStatus"] = exit.json }
            connection?.respond(id: id, result: result)
        case "terminal/wait_for_exit":
            waitingOnTerminals += 1
            disarmStallTimer()
            let known = host.waitForExit(terminalId) { [weak self] exit in
                guard let self else { return }
                self.waitingOnTerminals = max(0, self.waitingOnTerminals - 1)
                self.connection?.respond(id: id, result: exit.json)
                self.armStallTimerIfRunning()
            }
            if !known {
                waitingOnTerminals = max(0, waitingOnTerminals - 1)
                unknownTerminal(id)
            }
        case "terminal/kill":
            host.kill(terminalId) ? connection?.respond(id: id, result: [:]) : unknownTerminal(id)
        default: // terminal/release
            host.release(terminalId) ? connection?.respond(id: id, result: [:]) : unknownTerminal(id)
        }
    }

    private func unknownTerminal(_ id: Any) {
        connection?.respondError(id: id, code: -32602, message: "No such terminal.")
    }

    // MARK: Stalls

    private func armStallTimerIfRunning() {
        if phase == .streaming || phase == .runningTools { armStallTimer() }
    }

    /// A turn that goes silent for `stallInterval` says so, instead of looking busy forever —
    /// the same promise Heron's watchdog keeps (constitution: attention is explicit).
    private func armStallTimer() {
        stallWorkItem?.cancel()
        guard waitingOnTerminals == 0 else { stallWorkItem = nil; return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.phase == .streaming || self.phase == .runningTools, self.waitingOnTerminals == 0 else { return }
            if let sessionId = self.sessionId { self.connection?.notify("session/cancel", params: ["sessionId": sessionId]) }
            self.streamingIndex = nil
            self.thinkingIndex = nil
            self.answerPendingPermissions(with: nil)
            self.settlePendingWrites(reason: "The turn stalled before this edit was decided. The file is unchanged.")
            self.checkpointTurn()
            let seconds = Int(self.stallInterval)
            let span = seconds >= 120 ? "\(seconds / 60) minutes" : "\(seconds) seconds"
            self.append(.failure("No response from \(self.agent.displayName) for \(span), so Side stopped waiting. Send the message again. If it keeps happening, run the agent's CLI in a terminal to check it works and is signed in."))
            self.setPhase(.blocked(.stalled))
        }
        stallWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + stallInterval, execute: work)
    }

    private func disarmStallTimer() {
        stallWorkItem?.cancel()
        stallWorkItem = nil
    }

    // MARK: Session settings

    /// `configOptions` (model, effort, mode…) as (id, current option's name), in the agent's order.
    static func settings(from sessionResult: Any) -> [(id: String, value: String)] {
        let options = (sessionResult as? [String: Any])?["configOptions"] as? [[String: Any]] ?? []
        return options.compactMap { option in
            guard let id = option["id"] as? String, let current = option["currentValue"] as? String else { return nil }
            let choices = option["options"] as? [[String: Any]] ?? []
            let name = choices.first { $0["value"] as? String == current }?["name"] as? String ?? current
            return (id, name)
        }
    }

    /// "Claude Code · Opus 5.5 · Medium effort · Auto mode · Claude Team" — which model, how
    /// hard it thinks, who decides permissions, and which account pays. (Changing them from the
    /// pill is plan step 4.)
    private func describeSession() {
        let value = { (id: String) in self.sessionSettings.first { $0.id == id }?.value }
        var parts = [agent.displayName]
        if let model = value("model") { parts.append(model) }
        if let effort = value("effort") { parts.append("\(effort) effort") }
        if let mode = value("mode") { parts.append("\(mode) mode") }
        if let accountLabel { parts.append(accountLabel) }
        guard parts.count > 1 else { return }
        append(.meta(parts.joined(separator: " · ")))
    }

    // MARK: The turn's checkpoint

    /// Commits what the turn changed, however it was written (D1): paths the agent is known to
    /// have changed, plus paths that became dirty during the turn — minus paths the user saved
    /// in Make meanwhile, which are theirs. Runs once per turn.
    private func checkpointTurn() {
        guard let baseline = turnBaseline, let sessionStore else { turnBaseline = nil; return }
        turnBaseline = nil
        let root = rootProvider().path
        let touched = turnTouched
        let userSaved = UserSaveLog.shared.paths(savedSince: turnStartedAt, under: root)
        let shared = touched.intersection(userSaved)
        let firstLine = turnPrompt.split(separator: "\n").first.map(String.init) ?? ""
        let intent = firstLine.count > 72 ? String(firstLine.prefix(71)) + "…" : firstLine
        let commands = turnCommands
        let (trackKey, conversationId, agent) = (self.trackKey, self.conversationId, self.agent)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Only touched paths that actually differ now: a path the agent changed and changed
            // back has nothing to commit, and `git add` of a vanished untracked path would fail.
            let dirty = GitPaths.dirtyPaths(cwd: root)
            let outcome = AgentRunner.stageAndCommit(root: root, baseline: baseline, knownChanged: touched.intersection(dirty),
                                                     userSaved: userSaved, message: intent.isEmpty ? "\(agent.displayName) checkpoint" : intent)
            var fileChanges: [CheckpointFileChange] = []
            if case .committed(let sha, _)? = outcome {
                fileChanges = Self.numstat(sha: sha, cwd: root)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    switch outcome {
                    case .none, .nothingToCommit?:
                        return
                    case .failed(let step, let message)?:
                        self.append(.failure("Couldn't create a checkpoint — git \(step) failed\(message.isEmpty ? "" : ": \(message)").\nThe changes are still in your working copy, uncommitted."))
                    case .committed(let sha, let paths)?:
                        let names = paths.map { ($0 as NSString).lastPathComponent }
                        let described = intent.isEmpty
                            ? (names.count == 1 ? "Edited \(names[0])" : "Edited \(names.first ?? "files") and \(max(0, names.count - 1)) other files")
                            : intent
                        let checkpoint = Checkpoint(
                            trackKey: trackKey, agentSessionId: conversationId, declaredIntent: described,
                            changedFilePaths: paths, commandsRun: commands,
                            provenance: AgentProvenance(providerId: "acp:\(agent.id)", modelId: agent.displayName, instructionSourceSummary: "\(agent.displayName) conversation"),
                            gitCommitSHA: sha, fileChanges: fileChanges)
                        sessionStore.appendCheckpoint(checkpoint)
                        self.append(.checkpoint(id: checkpoint.id, text: AgentRunner.checkpointMarker(checkpoint)))
                        let sharedNames = shared.sorted().map { ($0 as NSString).lastPathComponent }
                        if !sharedNames.isEmpty {
                            self.append(.meta("Also has your own saved edits, committed with the agent's: \(sharedNames.joined(separator: ", "))."))
                        }
                    }
                }
            }
        }
    }

    /// Per-file line counts of one commit.
    private nonisolated static func numstat(sha: String, cwd: String) -> [CheckpointFileChange] {
        let result = GitPaths.runGitRaw(["show", "--numstat", "--format=", sha], cwd: cwd)
        guard result.success else { return [] }
        return result.output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { return nil }
            return CheckpointFileChange(path: parts[2], added: Int(parts[0]) ?? 0, removed: Int(parts[1]) ?? 0)
        }
    }

    // MARK: Content helpers

    /// A content block's text (`{"type":"text","text":…}`), or nil for images and the like.
    private static func text(_ content: Any?) -> String? {
        guard let block = content as? [String: Any], block["type"] as? String == "text" else { return nil }
        return block["text"] as? String
    }

    /// " path/one, path/two" from a tool call's `locations`, for the tool line's summary — minus
    /// any the title already names ("Read README.md" needs no second "README.md").
    private static func locationSummary(_ locations: Any?, besides title: String) -> String {
        let paths = (locations as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
            .filter { !title.contains(($0 as NSString).lastPathComponent) }
        guard !paths.isEmpty else { return "" }
        let names = paths.prefix(2).map { ($0 as NSString).lastPathComponent }
        return " " + names.joined(separator: ", ") + (paths.count > 2 ? " +\(paths.count - 2)" : "")
    }

    /// One short line about what a finished tool produced: the files it changed, or its text.
    private static func resultSummary(_ content: Any?) -> String {
        let items = content as? [[String: Any]] ?? []
        let changed = items.filter { $0["type"] as? String == "diff" }.compactMap { $0["path"] as? String }
        if !changed.isEmpty {
            return "Changed " + changed.prefix(3).map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        }
        for item in items where item["type"] as? String == "content" {
            if let text = text(item["content"])?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                let line = text.split(separator: "\n").first.map(String.init) ?? text
                return line.count > 120 ? String(line.prefix(120)) + "…" : line
            }
        }
        return "Done"
    }
}
