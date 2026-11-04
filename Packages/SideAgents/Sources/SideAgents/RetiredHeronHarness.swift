import Foundation

/// A track's Heron conversations, to read: Heron, Side's own agent, is retired
/// (SIDE_RFC_HERON_RETIREMENT.md, step 4), and what it said stays where it was. The transcript is
/// rebuilt from the stored session as Heron's runner rebuilt it after a relaunch: each turn's
/// messages, tool calls and results, and the conversation's checkpoints between them. Nothing can
/// be sent; past conversations can still be opened.
@MainActor
public final class RetiredHeronHarness: Harness {
    public let trackKey: String
    private let sessionStore: AgentSessionStore
    private var observers: [UUID: (AgentRunEvent) -> Void] = [:]
    public private(set) var entries: [RunTranscriptEntry] = []

    public init(trackKey: String, sessionStore: AgentSessionStore) {
        self.trackKey = trackKey
        self.sessionStore = sessionStore
        rebuild()
    }

    public var harnessName: String? { nil }
    public var phase: AgentRunPhase { .idle }
    public var activity: AgentActivity { .none }
    public var needsYouSince: Date? { nil }
    public var hasCommandAwaitingApproval: Bool { false }
    public var appliedEditCounts: [(path: String, added: Int, removed: Int)] { [] }
    public var archivedConversations: [ArchivedConversation] { sessionStore.archivedConversations(forTrackKey: trackKey) }
    public func contextUsage() -> (usedTokens: Int, windowTokens: Int, fraction: Double, status: ContextBudget.Status) { (0, 0, 0, .comfortable) }

    public var isReadyToSend: Bool { false }
    public var notReadyReason: String { "Heron is retired. Its conversations are kept to read." }

    @discardableResult
    public func addObserver(_ observer: @escaping (AgentRunEvent) -> Void) -> UUID {
        let token = UUID()
        observers[token] = observer
        return token
    }

    public func removeObserver(_ token: UUID) { observers.removeValue(forKey: token) }

    public func send(_ text: String, attachments: [AgentImageAttachment]) {}
    public func stop() {}
    public func resolve(proposalId: UUID, decision: ProposalDecision) {}
    public func answerPermission(proposalId: UUID, optionId: String?) {}
    public func acknowledgeCompletion() {}
    public func editableMessage(turnId: UUID) -> (text: String, attachments: [AgentImageAttachment])? { nil }
    public func editAndResend(turnId: UUID, text: String, attachments: [AgentImageAttachment]) {}
    public func compact(completion: @escaping (Result<Void, Error>) -> Void) {}
    public var canUndoCompaction: Bool { false }
    @discardableResult public func undoCompaction() -> Bool { false }
    public func startNewConversation() {}

    /// Another of the track's Heron conversations, filed as Heron filed them: the one shown goes
    /// to the archive, so opening one never loses another.
    @discardableResult
    public func openArchivedConversation(id: UUID) -> Bool {
        guard sessionStore.openArchivedConversation(id: id, forTrackKey: trackKey) != nil else { return false }
        rebuild()
        for observer in observers.values { observer(.reset) }
        return true
    }

    public var agentOptions: [HarnessOption] { [] }
    public var accountLabel: String? { nil }
    public func setAgentOption(id: String, value: String) {}
    public func prepareSession() {}
    public func teardown() { observers.removeAll() }

    public var runningUserTaskName: String? { nil }
    public var pendingUserTaskProposalId: UUID? { nil }
    @discardableResult public func proposeUserTask(_ task: ProjectTask) -> UUID? { nil }

    // MARK: The transcript

    private func rebuild() {
        entries = Self.transcript(of: sessionStore.session(forTrackKey: trackKey),
                                  checkpoints: sessionStore.checkpoints(forTrackKey: trackKey))
    }

    /// What Agent shows of a stored Heron session.
    static func transcript(of session: AgentSession?, checkpoints: [Checkpoint]) -> [RunTranscriptEntry] {
        guard let session else { return [] }
        var entries: [RunTranscriptEntry] = []
        let mine: [Checkpoint] = checkpoints.filter { $0.agentSessionId == session.id }
        var pending: ArraySlice<Checkpoint> = mine.sorted { $0.createdAt < $1.createdAt }[...]
        func placeCheckpoints(through date: Date) {
            while let next = pending.first, next.createdAt <= date {
                pending = pending.dropFirst()
                entries.append(RunTranscriptEntry(kind: .checkpoint(id: next.id, text: CheckpointCommit.checkpointMarker(next)), createdAt: next.createdAt))
            }
        }
        for turn in session.turns {
            placeCheckpoints(through: turn.createdAt)
            for block in turn.content {
                let kind: RunTranscriptEntry.Kind?
                switch block {
                case .text(let text): kind = turn.role == .user ? .userText(text) : .assistantText(text)
                case .toolUse(_, let name, let input): kind = .toolCall(name: name, summary: summarize(input: input))
                case .toolResult(_, let content, let isError):
                    kind = .toolResult(text: isError ? "\u{26A0}\u{FE0E} \(content.prefix(140))" : "\u{2713} \(describeSize(content))", isError: isError)
                case .image(_, let base64): kind = Data(base64Encoded: base64).map { .userImage($0) }
                }
                if let kind { entries.append(RunTranscriptEntry(kind: kind, createdAt: turn.createdAt, sourceTurnId: turn.role == .user ? turn.id : nil)) }
            }
            if turn.isCompactionSummary {
                entries.append(RunTranscriptEntry(kind: .compaction("Conversation compacted. The summary above is what Heron knew from here on."), createdAt: turn.createdAt))
            }
        }
        placeCheckpoints(through: .distantFuture)
        return entries
    }

    private static func summarize(input: JSONValue) -> String {
        guard case .object(let object) = input, !object.isEmpty else { return "" }
        let parts = object.keys.sorted().compactMap { key -> String? in
            switch object[key] {
            // Edit payloads are counted, not dumped into a one-line summary.
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

    private static func describeSize(_ output: String) -> String {
        let lines = output.components(separatedBy: "\n").count
        return lines == 1 ? "1 line" : "\(lines) lines"
    }
}
