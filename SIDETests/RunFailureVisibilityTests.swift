import XCTest
@testable import Side
@testable import SideAgents

/// A failed run has to reach the user. It used to finish as `.idle` — no chip, no badge, no
/// notification — so a background rate-limit looked exactly like an agent that had nothing to say.
final class RunFailureVisibilityTests: XCTestCase {
    func testFailedActivity() {
        // Only an error is a failure; a round-trip cap, a stall, and a budget stop are decisions.
        let blocked: [(AgentRunPhase.BlockedReason, AgentActivity)] = [
            (.failed, .failed), (.roundTripLimit, .needsYou), (.stalled, .needsYou), (.budgetReached, .needsYou),
        ]
        for (reason, activity) in blocked {
            XCTAssertEqual(AgentActivity(phase: .blocked(reason), hasUnseenCompletion: false), activity, "\(reason)")
        }
        // A failure wants attention like an approval does; nothing else does.
        let attention: [(AgentActivity, Bool)] = [
            (.failed, true), (.needsYou, true), (.none, false), (.working, false), (.doneUnread, false), (.doneSeen, false),
        ]
        for (activity, wants) in attention {
            XCTAssertEqual(activity.wantsAttention, wants, "\(activity)")
        }
        // And a failed run is not busy, so the user can retry.
        XCTAssertFalse(AgentRunPhase.blocked(.failed).isBusy)
    }
}
