import Foundation

/// A track's conversation run by an outside agent over the Agent Client Protocol
/// (`SIDE_RFC_BYO_HARNESS.md`). Step 2 of that plan: read-only on Side's side — the agent's
/// replies, reasoning and tool activity stream into the same transcript Heron fills, and its
/// permission prompts become cards. Side doesn't yet offer the agent its file or terminal
/// capabilities (step 3), so the agent reads, writes and runs commands itself, in the track's
/// worktree, and says so through its tool calls.
@MainActor
public final class ACPHarness: Harness {
    public let trackKey: String
    public let agent: ACPAgent
    public var harnessName: String? { agent.displayName }

    public private(set) var entries: [RunTranscriptEntry] = []
    public private(set) var phase: AgentRunPhase = .idle
    public private(set) var needsYouSince: Date?
    public var activity: AgentActivity { AgentActivity(phase: phase, hasUnseenCompletion: hasUnseenCompletion) }
    public var hasCommandAwaitingApproval: Bool { !pendingPermissions.isEmpty }
    public var appliedEditCounts: [(path: String, added: Int, removed: Int)] { [] }
    public var archivedConversations: [ArchivedConversation] { [] }
    public var runningUserTaskName: String? { nil }
    public var pendingUserTaskProposalId: UUID? { nil }

    /// Readiness is only known once the agent has been looked for, which takes a login-shell
    /// spawn; until a launch fails, sending is allowed and a missing agent is reported inline.
    public var isReadyToSend: Bool { true }
    public var notReadyReason: String { "" }

    private let launchProvider: @Sendable () -> ACPLaunch?
    private let rootProvider: () -> URL
    private var observers: [UUID: (AgentRunEvent) -> Void] = [:]
    private var hasUnseenCompletion = false
    private var connection: ACPConnection?
    private var sessionId: String?
    private var streamingIndex: Int?
    private var thinkingIndex: Int?
    private var toolEntryIndex: [String: Int] = [:]
    /// Permission cards waiting for an answer: entry id → the agent's request id.
    private var pendingPermissions: [UUID: Any] = [:]
    private var usage: (used: Int, size: Int)?
    /// The agent is being found and launched; a second send waits for that to finish.
    private var starting = false

    public init(trackKey: String, agent: ACPAgent, launchProvider: @escaping @Sendable () -> ACPLaunch?, rootProvider: @escaping () -> URL) {
        self.trackKey = trackKey
        self.agent = agent
        self.launchProvider = launchProvider
        self.rootProvider = rootProvider
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
        withSession { [weak self] sessionId in
            self?.prompt(trimmed, sessionId: sessionId)
        }
    }

    private func prompt(_ text: String, sessionId: String) {
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
        streamingIndex = nil
        thinkingIndex = nil
        answerPendingPermissions(with: nil)
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
        streamingIndex = nil
        thinkingIndex = nil
        answerPendingPermissions(with: nil)
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
            // Read-only for now: the agent uses its own file and terminal access (plan step 3
            // offers Side's).
            "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false],
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
            toolEntryIndex[id] = append(.toolCall(name: title, summary: Self.locationSummary(update["locations"], besides: title)))
            if phase == .streaming { setPhase(.runningTools) }
        case "tool_call_update":
            let id = update["toolCallId"] as? String ?? ""
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
        guard method == "session/request_permission" else {
            // File and terminal capabilities weren't offered (plan step 3).
            connection?.respondError(id: id, code: -32601, message: "Side doesn't offer \(method) yet.")
            return
        }
        let toolCall = params["toolCall"] as? [String: Any]
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
        pendingPermissions[entries[index].id] = id
        setPhase(.awaitingApproval)
    }

    public func answerPermission(proposalId: UUID, optionId: String?) {
        guard let requestId = pendingPermissions.removeValue(forKey: proposalId),
              let index = entries.firstIndex(where: { $0.id == proposalId }),
              case .permissionRequest(var presentation) = entries[index].kind else { return }
        if let optionId {
            connection?.respond(id: requestId, result: ["outcome": ["outcome": "selected", "optionId": optionId]])
            presentation.chosenOptionName = presentation.options.first { $0.id == optionId }?.name ?? optionId
        } else {
            connection?.respond(id: requestId, result: ["outcome": ["outcome": "cancelled"]])
            presentation.chosenOptionName = "Cancelled"
        }
        replace(index, .permissionRequest(presentation))
        if pendingPermissions.isEmpty, phase == .awaitingApproval { setPhase(.streaming) }
    }

    private func answerPendingPermissions(with optionId: String?) {
        for id in Array(pendingPermissions.keys) { answerPermission(proposalId: id, optionId: optionId) }
    }

    // MARK: Other actions

    public func stop() {
        answerPendingPermissions(with: nil)
        if let sessionId { connection?.notify("session/cancel", params: ["sessionId": sessionId]) }
        // The prompt's own response arrives with stopReason "cancelled" and settles the phase;
        // if the agent is gone, settle it here.
        if connection?.isRunning != true { setPhase(.idle) }
    }

    /// Outside agents ask through permission prompts; there are no proposal cards to resolve yet.
    public func resolve(proposalId: UUID, decision: ProposalDecision) {}

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

    /// Run's task chips stay with Heron until plan step 3 gives outside agents Side's terminal.
    public func proposeUserTask(_ task: ProjectTask) -> UUID? { nil }

    public func teardown() {
        answerPendingPermissions(with: nil)
        connection?.terminate()
        connection = nil
        sessionId = nil
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
