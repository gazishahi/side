import XCTest
@testable import Side
@testable import Heron
@testable import SideAgents

/// The diff parser feeds Review's per-file cards and Think's proposal cards, so a parsing
/// regression silently misrepresents what a human is approving.
final class UnifiedDiffTests: XCTestCase {
    func testFileHeadersSplitFilesAndCarryCountsAndModes() {
        // Several files in one diff, each with its own counts; new and deleted modes are read off
        // the header.
        let diff = """
        diff --git a/src/a.swift b/src/a.swift
        index 111..222 100644
        --- a/src/a.swift
        +++ b/src/a.swift
        @@ -1,3 +1,4 @@
         let unchanged = 1
        -let removed = 2
        +let added = 2
        +let alsoAdded = 3
        diff --git a/src/b.swift b/src/b.swift
        new file mode 100644
        --- /dev/null
        +++ b/src/b.swift
        @@ -0,0 +1,1 @@
        +let brandNew = true
        diff --git a/gone.txt b/gone.txt
        deleted file mode 100644
        @@ -1,1 +0,0 @@
        -was here
        """
        let parsed = UnifiedDiff.parse(diff)
        XCTAssertEqual(parsed.files.count, 3)
        XCTAssertEqual(parsed.files[0].path, "src/a.swift")
        XCTAssertEqual(parsed.files[0].addedCount, 2)
        XCTAssertEqual(parsed.files[0].removedCount, 1)
        XCTAssertFalse(parsed.files[0].isNew)
        XCTAssertFalse(parsed.files[0].isDeleted)
        XCTAssertEqual(parsed.files[1].path, "src/b.swift")
        XCTAssertTrue(parsed.files[1].isNew)
        XCTAssertEqual(parsed.files[1].addedCount, 1)
        XCTAssertEqual(parsed.files[2].path, "gone.txt")
        XCTAssertTrue(parsed.files[2].isDeleted)
    }

    /// Line numbers drive the gutter — an off-by-one here mislabels which line changed.
    func testAssignsOldAndNewLineNumbers() {
        let diff = """
        diff --git a/f b/f
        @@ -10,3 +10,3 @@
         context
        -old
        +new
        """
        let lines = UnifiedDiff.parse(diff).files[0].hunks[0].lines
        XCTAssertEqual(lines[0].oldNumber, 10)
        XCTAssertEqual(lines[0].newNumber, 10)
        XCTAssertEqual(lines[1].kind, .removed)
        XCTAssertEqual(lines[1].oldNumber, 11)
        XCTAssertNil(lines[1].newNumber)
        XCTAssertEqual(lines[2].kind, .added)
        XCTAssertNil(lines[2].oldNumber)
        XCTAssertEqual(lines[2].newNumber, 11)
    }

    /// Proposal diffs arrive as bare hunks with no `diff --git` header, and
    /// "\ No newline at end of file" is metadata, not a content line.
    func testParsesHeaderlessHunks() {
        let hunks = UnifiedDiff.parseHunks("""
        @@ -1,2 +1,2 @@
        -before
        +after
        \\ No newline at end of file
        """)
        XCTAssertEqual(hunks.count, 1)
        XCTAssertEqual(hunks[0].lines.count, 2)
        XCTAssertEqual(hunks[0].lines.filter { $0.kind == .added }.count, 1)
        XCTAssertEqual(hunks[0].lines.filter { $0.kind == .removed }.count, 1)
    }

    func testEmptyAndBinaryDiffsDoNotCrash() {
        XCTAssertTrue(UnifiedDiff.parse("").files.isEmpty)
        let binary = """
        diff --git a/img.png b/img.png
        Binary files a/img.png and b/img.png differ
        """
        let parsed = UnifiedDiff.parse(binary)
        XCTAssertEqual(parsed.files.count, 1)
        XCTAssertTrue(parsed.files[0].hunks.isEmpty)
    }
}
