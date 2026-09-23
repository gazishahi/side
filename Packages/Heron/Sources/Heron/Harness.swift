import Foundation

/// The engine behind one track's conversation — what Think, the track pill, Tracks, Run's task
/// row and inline instruct talk to. Heron's `AgentRunner` is one; an Agent Client Protocol
/// client for outside agents (Claude Code, Codex, Gemini CLI, Pi…) will be another
/// (`SIDE_RFC_BYO_HARNESS.md`). Nothing above this protocol knows which one it's driving.
///
/// The surface is the one the app already used on `AgentRunner`, lifted as-is: a renderable
/// transcript, a coarse phase, a multicast of changes, and the handful of actions a person can
/// take. Where a harness can't do something (compact a conversation, run a task on its own),
/// it says so through the same members rather than through a second API.
@MainActor
public protocol Harness: AnyObject {
    /// The track this conversation belongs to — its branch name.
    var trackKey: String { get }

    // MARK: What's on screen

    /// The renderable transcript, never an `NSView`.
    var entries: [RunTranscriptEntry] { get }
    var phase: AgentRunPhase { get }
    /// `phase` projected for anything that shows status without understanding the loop.
    var activity: AgentActivity { get }
    /// When the harness last started waiting on a person, for oldest-first ordering.
    var needsYouSince: Date? { get }
    var hasCommandAwaitingApproval: Bool { get }
    /// Per-file line counts applied in this conversation — Think's changed-files pill.
    var appliedEditCounts: [(path: String, added: Int, removed: Int)] { get }
    var archivedConversations: [ArchivedConversation] { get }
    func contextUsage() -> (usedTokens: Int, windowTokens: Int, fraction: Double, status: ContextBudget.Status)

    // MARK: Readiness

    /// A message could be sent right now (a model is configured and reachable).
    var isReadyToSend: Bool { get }
    var notReadyReason: String { get }

    // MARK: Observation

    @discardableResult
    func addObserver(_ observer: @escaping (AgentRunEvent) -> Void) -> UUID
    func removeObserver(_ token: UUID)

    // MARK: Actions

    func send(_ text: String, attachments: [AgentImageAttachment])
    func stop()
    func resolve(proposalId: UUID, decision: ProposalDecision)
    func acknowledgeCompletion()
    func editableMessage(turnId: UUID) -> (text: String, attachments: [AgentImageAttachment])?
    func editAndResend(turnId: UUID, text: String, attachments: [AgentImageAttachment])
    func compact(completion: @escaping (Result<Void, Error>) -> Void)
    func startNewConversation()
    func openArchivedConversation(id: UUID) -> Bool

    // MARK: Lifecycle

    /// The project is closing or the track was deleted: end whatever is in flight, for good.
    func teardown()

    // MARK: Run's task row

    var runningUserTaskName: String? { get }
    var pendingUserTaskProposalId: UUID? { get }
    /// Proposes a project task as a command card; nil when the harness is busy.
    @discardableResult
    func proposeUserTask(_ task: ProjectTask) -> UUID?
}

extension Harness {
    public func send(_ text: String) { send(text, attachments: []) }
    public func editAndResend(turnId: UUID, text: String) { editAndResend(turnId: turnId, text: text, attachments: []) }
}

extension AgentRunner: Harness {}
