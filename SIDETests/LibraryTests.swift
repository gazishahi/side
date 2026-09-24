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

    /// Step 4: a template is a prompt with `track: true`; Start Track hands over what's saved.
    func testTemplatesAreFlaggedPromptsAndStartTrackHandsThemOver() throws {
        let template = try PromptLibrary.save(title: "Bug bash", body: "Find and fix one bug.", scope: .project, projectRoot: root, startsTrack: true)
        XCTAssertEqual(try String(contentsOf: template.url, encoding: .utf8), "---\ntrack: true\n---\n# Bug bash\n\nFind and fix one bug.\n")
        let loaded = try XCTUnwrap(PromptLibrary.prompt(named: "bug-bash", projectRoot: root))
        XCTAssertTrue(loaded.startsTrack)
        XCTAssertEqual(loaded.title, "Bug bash")
        XCTAssertEqual(loaded.body, "Find and fix one bug.")
        let plain = try PromptLibrary.save(title: "Bug bash", body: "Just text.", scope: .project, projectRoot: root, replacing: loaded)
        XCTAssertFalse(plain.startsTrack, "unchecking it saves a plain prompt")

        let pane = PromptsPaneViewController()
        pane.loadViewIfNeeded()
        pane.target = LibraryTarget(projectName: "p", projectRoot: root, workingRoot: root)
        pane.titleField.stringValue = "Release"
        pane.bodyView.string = "Cut a release."
        pane.templateCheckbox.state = .on
        pane.save()
        XCTAssertEqual(pane.prompts.first { $0.name == "release" }?.startsTrack, true)
        var started: SavedPrompt?
        pane.onStartTrack = { started = $0 }
        pane.startTrack()
        XCTAssertEqual(started?.body, "Cut a release.")
    }

    func testMCPServerFormKeepsHiddenValuesAndSplitsArguments() {
        XCTAssertEqual(MCPServerStore.splitArguments(#"-y "@scope/server x" --flag ''"#), ["-y", "@scope/server x", "--flag", ""])
        let hidden = MCPServersPaneViewController.hiddenValue
        let parsed = MCPServersPaneViewController.parseEnvironment("KEEP=\(hidden)\nNEW=value=with=equals\n =skipped\nnoequals",
                                                                   stored: ["KEEP": "secret", "GONE": "x"])
        XCTAssertEqual(parsed, ["KEEP": "secret", "NEW": "value=with=equals"])
    }
}

/// Library step 3: skills on disk, and Storage's removal of archived tracks' working copies.
@MainActor
final class LibrarySkillsAndStorageTests: XCTestCase {
    private var root: URL!
    private var context: ProjectContext!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("library-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { _ = GitPaths.runGit(args, cwd: root.path) }
        try "hi\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = GitPaths.runGit(["add", "."], cwd: root.path); _ = GitPaths.runGit(["commit", "-q", "-m", "base"], cwd: root.path)
        context = ProjectContextRegistry.shared.acquire(projectRoot: root)
    }

    override func tearDownWithError() throws {
        for track in context.trackStore.tracks {
            if let path = track.workingDirectoryPath { _ = GitPaths.runGit(["worktree", "remove", "--force", path], cwd: root.path) }
        }
        ProjectContextRegistry.shared.release(projectRoot: root)
        try? FileManager.default.removeItem(at: root)
    }

    func testSkillsAreFoundWithTheirFrontMatter() throws {
        let home = root.appendingPathComponent("home")
        let claudeSkill = root.appendingPathComponent(".claude/skills/release")
        let shared = home.appendingPathComponent(".agents/skills/triage")
        try FileManager.default.createDirectory(at: claudeSkill, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude/skills/not-a-skill"), withIntermediateDirectories: true)
        try "---\nname: release-notes\ndescription: \"Writes release notes.\"\n---\n\nBody\n".write(to: claudeSkill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "---\nname: triage\ndescription: >\n  Sorts issues\n  by severity.\nlicense: MIT\n---\n".write(to: shared.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let skills = SkillCatalog.discover(workingRoot: root, home: home)
        XCTAssertEqual(skills.map(\.name), ["release-notes", "triage"])
        XCTAssertEqual(skills[0].description, "Writes release notes.")
        XCTAssertEqual(skills[0].scope, .project)
        XCTAssertEqual(skills[0].readers, ["Claude Code"])
        XCTAssertEqual(skills[1].description, "Sorts issues by severity.")
        XCTAssertEqual(skills[1].location, "~/.agents/skills")
        XCTAssertEqual(SkillCatalog.frontMatter("no front matter"), [:])

        // An installer's usual layout: one copy in ~/.agents/skills, linked from ~/.claude/skills.
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude/skills"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".claude/skills/triage"), withDestinationURL: shared)
        let linked = SkillCatalog.discover(workingRoot: root, home: home)
        XCTAssertEqual(linked.map(\.name), ["release-notes", "triage"], "listed once")
        let triage = try XCTUnwrap(linked.last)
        XCTAssertEqual(triage.location, "~/.agents/skills", "where it really lives")
        XCTAssertEqual(triage.alsoIn, ["~/.claude/skills"])
        XCTAssertEqual(Set(triage.readers), ["Claude Code", "Codex", "other agents that read .agents/skills"])
    }

    func testStorageRemovesArchivedWorkingCopiesButKeepsDirtyOnesAndBranches() throws {
        let clean = try createTrack("Old experiment")
        let dirty = try createTrack("Half done")
        _ = try createTrack("Current work")
        for track in [clean, dirty] { context.trackStore.setStatus(.archived, for: track) }
        let dirtyPath = try XCTUnwrap(dirty.workingDirectoryPath)
        try "unsaved\n".write(toFile: dirtyPath + "/wip.txt", atomically: true, encoding: .utf8)

        let pane = StoragePaneViewController()
        pane.target = LibraryTarget(projectName: "p", projectRoot: root, workingRoot: root,
                                    stateDirectory: context.stateDirectory, trackStore: context.trackStore)
        XCTAssertEqual(Set(pane.archivedWithCopies.map(\.id)), [clean.id, dirty.id])
        XCTAssertTrue(pane.removeButton.isEnabled)

        let done = expectation(description: "removed")
        var kept: [String] = []
        pane.removeCopies(pane.archivedWithCopies) { kept = $0; done.fulfill() }
        wait(for: [done], timeout: 30)
        XCTAssertEqual(kept, ["Half done"])
        let cleanPath = try XCTUnwrap(clean.workingDirectoryPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cleanPath))
        XCTAssertNil(context.trackStore.tracks.first { $0.id == clean.id }?.workingDirectoryPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dirtyPath + "/wip.txt"), "uncommitted work is never discarded")
        XCTAssertTrue(GitPaths.runGit(["rev-parse", "--verify", clean.branchName], cwd: root.path).success, "the branch stays")
        XCTAssertEqual(pane.archivedWithCopies.map(\.id), [dirty.id])
    }

    private func createTrack(_ intent: String) throws -> Track {
        let done = expectation(description: intent)
        let box = LibraryTrackBox()
        context.trackStore.createTrack(intent: intent) { result in
            if case .success(let (track, _)) = result { box.id = track.id }
            done.fulfill()
        }
        wait(for: [done], timeout: 30)
        return try XCTUnwrap(context.trackStore.tracks.first { $0.id == box.id })
    }
}

private final class LibraryTrackBox: @unchecked Sendable { var id: UUID? }
