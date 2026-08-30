import XCTest
@testable import Side

final class TrackOverlapTests: XCTestCase {

    func testOnlySharedPathsAreReported() {
        let siblings = TrackOverlap.siblings(
            of: "feature-a",
            changedPathsByBranch: [
                "feature-a": ["src/App.swift", "src/Util.swift"],
                "feature-b": ["src/Util.swift", "README.md"],
            ],
            intentsByBranch: ["feature-b": "tidy the utils"]
        )
        XCTAssertEqual(siblings.count, 1)
        // The intersection, not either track's full set — a banner listing files the other
        // track touched but this one didn't would be noise pretending to be a warning.
        XCTAssertEqual(siblings.first?.sharedPaths, ["src/Util.swift"])
        XCTAssertEqual(siblings.first?.intent, "tidy the utils")
    }

    func testTracksWithNoOverlapAreDropped() {
        let siblings = TrackOverlap.siblings(
            of: "feature-a",
            changedPathsByBranch: [
                "feature-a": ["src/App.swift"],
                "feature-b": ["docs/guide.md"],
            ],
            intentsByBranch: [:]
        )
        XCTAssertTrue(siblings.isEmpty)
    }

    func testTheTrackNeverOverlapsItself() {
        let siblings = TrackOverlap.siblings(
            of: "feature-a",
            changedPathsByBranch: ["feature-a": ["src/App.swift"]],
            intentsByBranch: [:]
        )
        XCTAssertTrue(siblings.isEmpty)
    }

    func testWorstOverlapComesFirst() {
        let siblings = TrackOverlap.siblings(
            of: "mine",
            changedPathsByBranch: [
                "mine": ["a.swift", "b.swift", "c.swift"],
                "light": ["c.swift"],
                "heavy": ["a.swift", "b.swift"],
            ],
            intentsByBranch: [:]
        )
        XCTAssertEqual(siblings.map(\.branchName), ["heavy", "light"])
    }

    func testOrderIsStableForEqualOverlap() {
        // Dictionary iteration order isn't stable between runs; without a tiebreak the banner
        // would reshuffle on every refresh for no visible reason.
        let input: [String: Set<String>] = [
            "mine": ["a.swift"],
            "zebra": ["a.swift"],
            "alpha": ["a.swift"],
        ]
        for _ in 0..<5 {
            let siblings = TrackOverlap.siblings(of: "mine", changedPathsByBranch: input, intentsByBranch: [:])
            XCTAssertEqual(siblings.map(\.branchName), ["alpha", "zebra"])
        }
    }

    func testATrackThatChangedNothingHasNoOverlap() {
        let siblings = TrackOverlap.siblings(
            of: "fresh",
            changedPathsByBranch: ["fresh": [], "busy": ["a.swift"]],
            intentsByBranch: [:]
        )
        XCTAssertTrue(siblings.isEmpty)
    }

    // MARK: - Summary

    func testHeadlineNamesTheOtherTrack() {
        let headline = TrackOverlap.headline(for: [
            .init(branchName: "feature-b", intent: "tidy the utils", sharedPaths: ["src/Util.swift"])
        ])
        XCTAssertEqual(headline, "Also being changed by \u{201C}tidy the utils\u{201D}")
    }

    func testHeadlineFallsBackToTheBranchNameWithoutAnIntent() {
        let headline = TrackOverlap.headline(for: [
            .init(branchName: "feature-b", intent: "", sharedPaths: ["a.swift", "b.swift"])
        ])
        XCTAssertEqual(headline, "Also being changed by \u{201C}feature-b\u{201D}")
    }

    func testHeadlineCountsAdditionalTracks() {
        let headline = TrackOverlap.headline(for: [
            .init(branchName: "b", intent: "", sharedPaths: ["a.swift"]),
            .init(branchName: "c", intent: "", sharedPaths: ["a.swift"]),
            .init(branchName: "d", intent: "", sharedPaths: ["a.swift"]),
        ])
        XCTAssertEqual(headline, "Also being changed by \u{201C}b\u{201D} and 2 other tracks")
    }

    func testSharedPathsAreNamedNotCounted() {
        // The banner has the width; "3 files" without naming them is the count without the
        // answer to the question it provokes.
        let summary = TrackOverlap.sharedPathsSummary(for: [
            .init(branchName: "b", intent: "", sharedPaths: ["src/a.swift", "src/b.swift"])
        ])
        XCTAssertTrue(summary.contains("src/a.swift"))
        XCTAssertTrue(summary.contains("src/b.swift"))
    }

    func testSharedPathsAreDeduplicatedAcrossTracks() {
        let summary = TrackOverlap.sharedPathsSummary(for: [
            .init(branchName: "b", intent: "", sharedPaths: ["a.swift"]),
            .init(branchName: "c", intent: "", sharedPaths: ["a.swift", "b.swift"]),
        ])
        XCTAssertEqual(summary, "a.swift  \u{00B7}  b.swift")
    }

    func testALargeOverlapIsCappedRatherThanWrapping() {
        let many = (1...9).map { "file\($0).swift" }
        let summary = TrackOverlap.sharedPathsSummary(for: [
            .init(branchName: "b", intent: "", sharedPaths: many)
        ])
        XCTAssertTrue(summary.contains("+5 more"), summary)
        XCTAssertFalse(summary.contains("file9.swift"), summary)
    }

    func testNoSiblingsMeansNoBanner() {
        XCTAssertNil(TrackOverlap.headline(for: []))
    }

    // MARK: - Against a real repository

    func testChangedPathsUsesTheMergeBaseNotTheBaseTip() throws {
        // The three-dot case: work landing on the base *after* a track branched must not be
        // reported as that track's own change, or every stacked track would look like it
        // overlaps everything its parent has done since.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("overlap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.path
        defer { try? FileManager.default.removeItem(at: dir) }

        func git(_ args: [String]) { XCTAssertTrue(GitPaths.runGit(args, cwd: path).success, args.joined(separator: " ")) }
        func write(_ name: String, _ text: String) { try? text.write(toFile: path + "/" + name, atomically: true, encoding: .utf8) }

        git(["init", "-b", "main"])
        git(["config", "user.email", "t@t"])
        git(["config", "user.name", "T"])
        write("base.txt", "base\n")
        git(["add", "."]); git(["commit", "-m", "base"])

        git(["checkout", "-b", "feature"])
        write("mine.txt", "mine\n")
        git(["add", "."]); git(["commit", "-m", "feature work"])

        // Meanwhile, main moves on independently.
        git(["checkout", "main"])
        write("theirs.txt", "theirs\n")
        git(["add", "."]); git(["commit", "-m", "main work"])

        let changed = TrackOverlap.changedPaths(branch: "feature", baseRef: "main", cwd: path)
        XCTAssertEqual(changed, ["mine.txt"])
    }
}
