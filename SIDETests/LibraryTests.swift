import XCTest
@testable import Heron
@testable import Side

/// Library step 1 (`SIDE_RFC_LIBRARY.md`): instruction files and who reads them, saved prompts,
/// and the window's panes over both.
@MainActor
final class LibraryTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var savedDefaults: UserDefaults!
    private var savedPrompts: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("side-library-\(UUID().uuidString)")
        root = base.appendingPathComponent("project")
        home = base.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        savedDefaults = ProjectRules.defaults
        ProjectRules.defaults = UserDefaults(suiteName: "side-tests-\(UUID().uuidString)")!
        savedPrompts = PromptLibrary.userDirectory
        PromptLibrary.userDirectory = base.appendingPathComponent("prompts")
    }

    override func tearDownWithError() throws {
        ProjectRules.defaults = savedDefaults
        PromptLibrary.userDirectory = savedPrompts
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    func testInstructionFilesSayWhoReadsThemAndWhichOneHeronUses() throws {
        try "Use tabs.\n".write(to: root.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        try "Claude only.\n".write(to: root.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".gemini"), withIntermediateDirectories: true)
        try "Mine.\n".write(to: home.appendingPathComponent(".gemini/GEMINI.md"), atomically: true, encoding: .utf8)

        var files = InstructionFiles.discover(workingRoot: root, home: home)
        let agents = try XCTUnwrap(files.first { $0.displayPath == "AGENTS.md" })
        XCTAssertEqual(agents.heron, .inUse(acknowledged: false), "AGENTS.md comes before CLAUDE.md in Heron's order")
        XCTAssertEqual(InstructionFiles.readerNames(agents).prefix(3), ["Heron", "Codex", "Pi"])
        XCTAssertEqual(files.first { $0.displayPath == "CLAUDE.md" }?.heron, .shadowed(by: "AGENTS.md"))
        XCTAssertEqual(files.first { $0.displayPath == "SIDE.md" }?.heron, .candidate)
        XCTAssertEqual(files.first { $0.displayPath == "SIDE.md" }?.exists, false)
        let gemini = try XCTUnwrap(files.first { $0.displayPath == "~/.gemini/GEMINI.md" })
        XCTAssertTrue(gemini.exists)
        XCTAssertNil(gemini.heron, "Heron doesn't read files in the home folder")

        // Accepting it is the same acknowledgement Think asks for.
        ProjectRules.acknowledge(url: agents.url, contents: "Use tabs.")
        files = InstructionFiles.discover(workingRoot: root, home: home)
        XCTAssertEqual(files.first { $0.displayPath == "AGENTS.md" }?.heron, .inUse(acknowledged: true))
        XCTAssertEqual(ProjectRules.load(projectRoot: root), "Use tabs.")
    }

    func testPromptsSaveAsMarkdownAndTheProjectsWinOnAName() throws {
        XCTAssertEqual(PromptLibrary.slug("Review for Concurrency Bugs!"), "review-for-concurrency-bugs")
        let mine = try PromptLibrary.save(title: "Release notes", body: "Write release notes for the last tag.", scope: .user, projectRoot: root)
        XCTAssertEqual(mine.name, "release-notes")
        XCTAssertEqual(try String(contentsOf: mine.url, encoding: .utf8), "# Release notes\n\nWrite release notes for the last tag.\n")
        XCTAssertEqual(PromptLibrary.all(projectRoot: root).map(\.scope), [.user])

        let shared = try PromptLibrary.save(title: "Release Notes", body: "Use the team's template.", scope: .project, projectRoot: root)
        XCTAssertEqual(shared.url.deletingLastPathComponent().path, root.appendingPathComponent(".side/prompts").path)
        let found = try XCTUnwrap(PromptLibrary.prompt(named: "release-notes", projectRoot: root))
        XCTAssertEqual(found.scope, .project)
        XCTAssertEqual(found.body, "Use the team's template.")
        XCTAssertEqual(PromptLibrary.prompt(named: "release-notes", projectRoot: nil)?.scope, .user)

        // Renaming replaces the old file rather than leaving both.
        let renamed = try PromptLibrary.save(title: "Changelog", body: "x", scope: .user, projectRoot: root, replacing: mine)
        XCTAssertFalse(FileManager.default.fileExists(atPath: mine.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.url.path))
        try PromptLibrary.delete(renamed)
        XCTAssertEqual(PromptLibrary.all(projectRoot: root).map(\.name), ["release-notes"])
    }

    func testTheWindowsPanesShowTheTarget() throws {
        try "Standing rules.\n".write(to: root.appendingPathComponent("SIDE.md"), atomically: true, encoding: .utf8)
        let library = LibraryViewController()
        library.loadViewIfNeeded()
        library.target = LibraryTarget(projectName: "project", projectRoot: root, workingRoot: root)
        let sideFile = try XCTUnwrap(library.instructions.files.first { $0.displayPath == "SIDE.md" })
        XCTAssertEqual(InstructionsPaneViewController.stateText(sideFile), "Heron will ask before using this")

        library.select(.prompts)
        XCTAssertEqual(library.section, .prompts)
        let prompts = library.prompts
        prompts.titleField.stringValue = "Explain this"
        prompts.bodyView.string = "Explain the selected code."
        prompts.save()
        XCTAssertEqual(prompts.prompts.map(\.name), ["explain-this"])
        XCTAssertEqual(PromptLibrary.prompt(named: "explain-this", projectRoot: root)?.body, "Explain the selected code.")
        XCTAssertTrue(ThinkWorkspaceViewController.builtInSlashNames.contains("library"))
    }

    func testMCPServerFormKeepsHiddenValuesAndSplitsArguments() {
        XCTAssertEqual(MCPServerStore.splitArguments(#"-y "@scope/server x" --flag ''"#), ["-y", "@scope/server x", "--flag", ""])
        let hidden = MCPServersPaneViewController.hiddenValue
        let parsed = MCPServersPaneViewController.parseEnvironment("KEEP=\(hidden)\nNEW=value=with=equals\n =skipped\nnoequals",
                                                                   stored: ["KEEP": "secret", "GONE": "x"])
        XCTAssertEqual(parsed, ["KEEP": "secret", "NEW": "value=with=equals"])
    }
}
