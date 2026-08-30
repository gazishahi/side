import XCTest
@testable import Side

final class ProjectRulesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("rules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func write(_ name: String, _ contents: String) throws {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    func testNoRulesFileMeansNoRules() {
        XCTAssertNil(ProjectRules.load(projectRoot: root))
    }

    func testLoadsTheNativeFile() throws {
        try write("SIDE.md", "Use four spaces.")
        XCTAssertEqual(ProjectRules.load(projectRoot: root), "Use four spaces.")
    }

    func testOtherAgentsRulesFilesAreHonored() throws {
        // A project already telling some other coding agent how to behave is telling this one
        // the same thing; making the user maintain a third copy would be silly.
        try write("CLAUDE.md", "Run the tests before claiming a fix works.")
        XCTAssertEqual(ProjectRules.load(projectRoot: root), "Run the tests before claiming a fix works.")
    }

    func testTheNativeFileWinsOverTheFallbacks() throws {
        try write("CLAUDE.md", "from claude")
        try write("AGENTS.md", "from agents")
        try write("SIDE.md", "from side")
        XCTAssertEqual(ProjectRules.load(projectRoot: root), "from side")
    }

    func testAnEmptyFileIsTreatedAsAbsent() throws {
        // An empty (or whitespace-only) file would otherwise spend prompt space on a heading
        // announcing that the user has instructions, followed by nothing.
        try write("SIDE.md", "   \n\n  ")
        try write("CLAUDE.md", "real rules")
        XCTAssertEqual(ProjectRules.load(projectRoot: root), "real rules")
    }

    func testOversizedRulesAreTruncatedVisibly() throws {
        // Silently dropping (or silently including) a 200KB file is the failure mode that makes
        // this feature quietly expensive; the note makes it diagnosable from the transcript.
        try write("SIDE.md", String(repeating: "x", count: ProjectRules.maxCharacters + 5_000))
        let loaded = try XCTUnwrap(ProjectRules.load(projectRoot: root))
        XCTAssertLessThan(loaded.count, ProjectRules.maxCharacters + 300)
        XCTAssertTrue(loaded.contains("truncated"), "no truncation note")
    }

    func testRulesAreRereadWhenTheFileChanges() throws {
        // Editing the file must take effect on the next message, not the next launch — the
        // whole point is that it's a living document.
        try write("SIDE.md", "first")
        XCTAssertEqual(ProjectRules.load(projectRoot: root), "first")
        try write("SIDE.md", "second")
        XCTAssertEqual(ProjectRules.load(projectRoot: root), "second")
    }

    // MARK: - Framing

    func testTheSectionCarriesTheRulesAndKeepsApprovalNonNegotiable() {
        let section = ProjectRules.systemPromptSection(rules: "Never edit Generated/.")
        XCTAssertTrue(section.contains("Never edit Generated/."))
        // A project file must not be a way to talk the agent out of asking permission.
        XCTAssertTrue(section.lowercased().contains("approval"))
        XCTAssertTrue(section.lowercased().contains("waive"))
    }

    func testTheTemplateShowsWhatBelongsInTheFile() {
        // An empty file with a heading teaches nobody what to write; the starter is examples.
        XCTAssertTrue(ProjectRules.template.contains("e.g."))
    }
}
