import XCTest
@testable import Side

/// Direction 02 §4: what each stage says, as tables.
final class StageCompositionTests: XCTestCase {
    /// Tracks' trailing action is the specific verb — never a stage name that goes elsewhere
    /// (audit A-3). Activity outranks lifecycle: a parked track whose run failed says Retry.
    func testTrackRowVerbs() {
        let cases: [(TrackStatus, AgentActivity, TrackRowVerb)] = [
            (.waiting, .needsYou, .respond),
            (.active, .failed, .retry),
            (.parked, .failed, .retry),
            (.active, .doneUnread, .review),
            (.reviewReady, .none, .review),
            (.active, .working, .open),
            (.waiting, .doneSeen, .open),
            (.parked, .none, .resume),
            (.completed, .none, .resume),
            (.archived, .none, .resume),
        ]
        for (status, activity, expected) in cases {
            XCTAssertEqual(TrackRowVerb.primary(status: status, activity: activity), expected, "\(status) / \(activity)")
        }
    }
}
