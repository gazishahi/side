import XCTest
@testable import Side

/// A failed run has to reach the user. It used to finish as `.idle` — no chip, no badge, no
/// notification — so a background rate-limit looked exactly like an agent that had nothing to say.
final class RunFailureVisibilityTests: XCTestCase {
    func testAFailedRunIsItsOwnActivity() {
        XCTAssertEqual(AgentActivity(phase: .blocked(.failed), hasUnseenCompletion: false), .failed)
        XCTAssertTrue(AgentActivity.failed.wantsAttention)
    }

    func testFailureWantsAttentionLikeAnApprovalDoes() {
        XCTAssertTrue(AgentActivity.needsYou.wantsAttention)
        XCTAssertTrue(AgentActivity.failed.wantsAttention)
        for quiet in [AgentActivity.none, .working, .doneUnread, .doneSeen] {
            XCTAssertFalse(quiet.wantsAttention, "\(quiet)")
        }
    }

    func testAFailedRunIsNotBusySoTheUserCanRetry() {
        XCTAssertFalse(AgentRunPhase.blocked(.failed).isBusy)
    }

    func testTheOtherBlockedReasonsStillReadAsNeedsYou() {
        // Only an error is a failure; a round-trip cap, a stall, and a budget stop are decisions.
        for reason in [AgentRunPhase.BlockedReason.roundTripLimit, .stalled, .budgetReached] {
            XCTAssertEqual(AgentActivity(phase: .blocked(reason), hasUnseenCompletion: false), .needsYou, "\(reason)")
        }
    }
}
