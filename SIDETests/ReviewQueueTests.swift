import XCTest
@testable import Side

/// Sessions, phase 4 (SIDE_RFC_SESSIONS.md): Changes as a review queue.
final class ReviewQueueTests: XCTestCase {
    private let diff = """
    diff --git a/Login.swift b/Login.swift
    index 1111111..2222222 100644
    --- a/Login.swift
    +++ b/Login.swift
    @@ -1,3 +1,4 @@
     func login() {
    +  retry(2)
       send()
     }
    @@ -10,2 +11,3 @@
     // tail
    +// typed by hand
     end
    diff --git a/README.md b/README.md
    index 3333333..4444444 100644
    --- a/README.md
    +++ b/README.md
    @@ -1 +1,2 @@
     hi
    +Retry the login twice
    diff --git a/Old.swift b/Old.swift
    deleted file mode 100644
    index 5555555..0000000
    --- a/Old.swift
    +++ /dev/null
    @@ -1 +0,0 @@
    -gone
    """

    private let claude = Author(kind: .session, sessionID: "s1", agent: "claude", request: "Fix the flaky login test")

    func testHunksAreSplitAndGroupedByWhoWroteThem() {
        let hunks = ReviewQueue.hunks(in: diff)
        XCTAssertEqual(hunks.map(\.path), ["Login.swift", "Login.swift", "README.md", "Old.swift"])
        XCTAssertEqual(hunks[0].addedLines, [2])
        XCTAssertEqual(hunks[1].addedLines, [12])
        XCTAssertEqual(hunks[3].removed, 1)

        let owners: [String: [Author?]] = [
            "Login.swift": [nil, claude, nil, nil, nil, nil, nil, nil, nil, nil, nil, .you, nil],
            "README.md": [nil, claude],
        ]
        let queue = ReviewQueue.build(diff: diff) { owners[$0] ?? [] }
        XCTAssertEqual(queue.groups.map(\.title), ["Fix the flaky login test", "Your edits", "Not attributed"])
        XCTAssertEqual(queue.groups[0].paths, ["Login.swift", "README.md"])
        XCTAssertEqual(queue.groups[0].added, 2)
        XCTAssertEqual(queue.groups[1].paths, ["Login.swift"])
        XCTAssertEqual(queue.groups[2].paths, ["Old.swift"], "a hunk that only removes lines isn't attributed")
    }

    /// A group's own diff renders as any diff does: each file's header once, then its hunks.
    func testAGroupIsADiffOfItsOwn() {
        let owners: [String: [Author?]] = ["Login.swift": [nil, claude], "README.md": [nil, claude]]
        let group = ReviewQueue.build(diff: diff) { owners[$0] ?? [] }.groups[0]
        let parsed = UnifiedDiff.parse(group.diffText)
        XCTAssertEqual(parsed.files.map(\.path), ["Login.swift", "README.md"])
        XCTAssertEqual(parsed.files[0].hunks.count, 1, "only the session's hunk of Login.swift")
        XCTAssertEqual(parsed.files[0].addedCount, 1)
        XCTAssertEqual(parsed.files[1].addedCount, 1)
    }
}
