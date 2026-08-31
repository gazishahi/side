import Foundation

/// One renderable unit of a Think conversation, owned by `AgentRunner` — never an `NSView`, so
/// more than one observer (Think today; Tracks and a stage badge once B1 lands) can render the
/// same run without inheriting AppKit assumptions. Headers ("You" / "Assistant") aren't a case
/// here — they're implied by `.userText`/`.assistantText` and drawn by whoever renders this, not
/// baked into the data.
struct RunTranscriptEntry: Identifiable {
    let id = UUID()
    /// When this entry actually happened — feeds the "Worked for Ns" header on grouped tool
    /// activity.
    ///
    /// Explicitly settable, and that is the whole point: it used to default to `Date()` at
    /// construction, and `hydrateFromSession` constructs fresh entries when a conversation is
    /// reloaded. So every historical entry was stamped with the moment of the *reload*, and a
    /// group that really took seven seconds reported one — the number was truthful only inside
    /// the session that produced it. Rehydration now passes the persisted turn's own timestamp.
    let createdAt: Date
    var kind: Kind

    init(kind: Kind, createdAt: Date = Date()) {
        self.kind = kind
        self.createdAt = createdAt
    }

    enum Kind {
        case meta(String)
        case userText(String)
        /// An image the user attached, held as encoded bytes so any observer can render it.
        case userImage(Data)
        /// Mutated in place while the model streams — each delta fires `.updated`, not a fresh
        /// `.appended`, so the transcript grows one paragraph, not one block per token.
        case assistantText(String)
        case toolCall(name: String, summary: String)
        case toolResult(text: String, isError: Bool)
        case failure(String)
        case proposal(ProposalPresentation)
        case commandProposal(CommandPresentation)
    }
}

/// What the transcript needs to render (and re-render) a `run_shell_command` proposal —
/// `ProposalPresentation`'s sibling for commands rather than edits. Separate types because the
/// two resolve completely differently (a diff-and-apply vs. typing into Run's terminal and
/// waiting for a sentinel), not because the UI shape needs to differ much.
struct CommandPresentation {
    let command: ProposedCommand
    var resolution: Resolution?

    enum Resolution {
        case executed(output: String)
        case rejected

        var label: (text: String, color: ProposalPresentation.ResolutionColor) {
            switch self {
            case .executed: return ("Ran", .success)
            case .rejected: return ("Rejected", .neutral)
            }
        }
    }
}

/// What the transcript needs to render (and re-render) a proposed edit, independent of the
/// `NSView` that displays it. Resolution lives here, not just in the view — a detach/reattach
/// (stage switch, track switch and back) rebuilds an already-resolved card showing its outcome,
/// not a fresh Apply/Reject asking the user to decide a second time. Not persisted across a
/// relaunch — once a session is reloaded from disk, a resolved proposal renders as a plain
/// toolCall/toolResult pair, same as any other completed tool exchange.
struct ProposalPresentation {
    /// `var`, not `let` — resolution strips `edit`'s full file content (see
    /// `ProposedEdit.stripContent()`) once it's no longer needed, so this entry doesn't hold a
    /// duplicate old-and-new copy of the file for the rest of the session.
    var edit: ProposedEdit
    /// `var` because a streaming preview's body is replaced as the model writes, and then once
    /// more by the real unified diff when the call completes.
    var diffText: String
    var resolution: Resolution?
    /// True while the model is still writing this tool call's arguments. The card renders, but
    /// offers no decision: what's on screen is a preview of text arriving, not a validated
    /// proposal, and Apply would be asking the user to approve half a sentence.
    var isStreaming: Bool = false

    enum Resolution {
        case applied
        case rejected
        case staleBase
        case writeFailed(String)
        /// The call finished but the executor refused it — `old_string` matched nothing, the
        /// content was identical, the path wasn't writable. The preview card stays as the record
        /// of what was attempted rather than vanishing and leaving the transcript unexplained.
        case notProposed(String)

        init(_ outcome: ProposedEditOutcome) {
            switch outcome {
            case .applied: self = .applied
            case .rejected: self = .rejected
            case .staleBase: self = .staleBase
            case .writeFailed(let message): self = .writeFailed(message)
            }
        }

        var label: (text: String, color: ResolutionColor) {
            switch self {
            case .applied: return ("Applied", .success)
            case .rejected: return ("Rejected", .neutral)
            case .staleBase: return ("File changed — not applied", .warning)
            case .writeFailed(let message): return ("Failed: \(message)", .failure)
            case .notProposed(let message): return (message, .warning)
            }
        }
    }

    /// Semantic, not `NSColor` — this type has no AppKit dependency so it can be shared with a
    /// future non-AppKit observer (Tracks' dashboard) without pulling one in.
    enum ResolutionColor { case success, neutral, warning, failure }
}

/// What decided a proposal — the human clicked one of two buttons, nothing else.
enum ProposalDecision { case apply, reject }

/// Coarse state of one run, for anything that wants to show activity without inspecting
/// `entries` — the Think send button, the Tracks dashboard, and the stage badge all derive from
/// this rather than each re-deriving their own notion of "busy."
enum AgentRunPhase: Equatable {
    case idle
    case streaming
    case runningTools
    case awaitingApproval
    /// Stopped short of a clean turn end and needs a human decision to continue — never set by
    /// a transport error or a user-initiated Stop, only by the two conditions in `BlockedReason`.
    case blocked(BlockedReason)
    /// A turn just ended cleanly (the model stopped asking for tools, nothing pending). Distinct
    /// from `.idle` — which is only ever "never started" — so `AgentActivity` can tell "finished,
    /// not yet looked at" from "finished, already seen" via `hasUnseenCompletion`, the same
    /// mechanic `RunSession.hasUnseenOutput` uses for background Run tabs.
    case finishedTurn

    enum BlockedReason: Equatable {
        /// Hit `AgentRunner`'s round-trip cap — the model kept asking for tools with no end in
        /// sight. Send another message to continue.
        case roundTripLimit
        /// No stream event for `AgentRunner`'s stall window — a hung connection is otherwise
        /// indistinguishable from a working agent.
        case stalled
        /// This month's estimated spend has reached the configured budget. Distinct from the
        /// other two because the fix isn't "send again," it's "change the budget" — see
        /// `UsageBudget`.
        case budgetReached
    }

    /// Send is only meaningful when nothing is actively running — every other phase either has
    /// a network call in flight, tool execution in flight, or a decision pending that a new
    /// message would jump the queue of.
    var isBusy: Bool {
        switch self {
        case .streaming, .runningTools, .awaitingApproval: return true
        case .idle, .blocked, .finishedTurn: return false
        }
    }
}

/// What Tracks (and eventually a stage badge) actually renders — coarser than `AgentRunPhase`,
/// and the only thing either of those need to know about a runner. Deliberately not derived from
/// `TrackStatus`: activity is machine-owned and ephemeral, status is human-owned lifecycle — see
/// `AgentRunner.activity`.
enum AgentActivity: Equatable {
    case none
    case working
    case needsYou
    case doneUnread
    case doneSeen

    init(phase: AgentRunPhase, hasUnseenCompletion: Bool) {
        switch phase {
        case .idle:
            self = .none
        case .streaming, .runningTools:
            self = .working
        case .awaitingApproval, .blocked:
            self = .needsYou
        case .finishedTurn:
            self = hasUnseenCompletion ? .doneUnread : .doneSeen
        }
    }
}

/// What changed since the last notification, so an observer can apply a minimal update instead
/// of re-rendering the whole transcript on every token.
enum AgentRunEvent {
    /// The transcript was rebuilt wholesale (attaching to a runner for the first time) — the
    /// observer should discard whatever it had and render `entries` from scratch.
    case reset
    case appended(Int)
    case updated(Int)
    case phaseChanged
}
