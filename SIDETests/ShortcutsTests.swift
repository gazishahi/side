import XCTest
@testable import Side

/// The shortcut table (docs/SIDE_PLAN_EDITOR_SHORTCUTS.md): no two commands share a default,
/// every menu shortcut comes from it, and a change reaches the menu.
@MainActor
final class ShortcutsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        Shortcuts.resetAll()
    }

    override func tearDown() {
        Shortcuts.resetAll()
        super.tearDown()
    }

    func testNoTwoMenuCommandsShareADefaultInAnyKeymap() {
        let menu = Shortcuts.all.filter { !$0.isFixed }
        for keymap in Shortcuts.Keymap.allCases {
            // Within a kind of file (or among commands for every file), keys are one command's;
            // a command for one kind of file may cover one for all.
            var seen: [String: String] = [:]
            for command in menu {
                guard let chord = Shortcuts.defaultChord(command.id, in: keymap) else { continue }
                let slot = "\(command.context?.rawValue ?? "all")|\(chord.display)"
                XCTAssertNil(seen[slot], "\(keymap.title): \(command.id) and \(seen[slot] ?? "") both default to \(chord.display)")
                seen[slot] = command.id
            }
            // A preset only names commands that exist.
            for id in Shortcuts.presets[keymap]?.keys ?? [:].keys { XCTAssertNotNil(Shortcuts.command(id), "\(keymap.title) names \(id)") }
        }
        XCTAssertEqual(Set(Shortcuts.all.map(\.id)).count, Shortcuts.all.count, "ids are unique")
    }

    /// In Markdown ⌘B, ⌘I and ⌘K format; ⌘K is Instruct again elsewhere, and ⌘B is Build in
    /// LaTeX (2026-10-24, the owner's choice in docs/SIDE_RFC_LIVE_MARKDOWN.md).
    func testShortcutsFollowTheKindOfFile() {
        let instruct = NSMenuItem(), link = NSMenuItem(), bold = NSMenuItem(), build = NSMenuItem()
        Shortcuts.bind(instruct, "edit.instruct"); Shortcuts.bind(link, "format.link")
        Shortcuts.bind(bold, "format.bold"); Shortcuts.bind(build, "file.buildLaTeX")
        defer { Shortcuts.activeContext = nil }
        Shortcuts.activeContext = nil
        XCTAssertEqual(instruct.keyEquivalent, "k")
        XCTAssertEqual(link.keyEquivalent, "", "no formatting outside Markdown")
        XCTAssertEqual(build.keyEquivalent, "", "no Build outside LaTeX")
        Shortcuts.activeContext = .markdown
        XCTAssertEqual(link.keyEquivalent, "k")
        XCTAssertEqual(instruct.keyEquivalent, "", "Link covers Instruct in Markdown")
        XCTAssertEqual(bold.keyEquivalent, "b")
        Shortcuts.activeContext = .latex
        XCTAssertEqual(build.keyEquivalent, "b")
        XCTAssertEqual(bold.keyEquivalent, "")
        XCTAssertEqual(instruct.keyEquivalent, "k")
        XCTAssertNil(Shortcuts.conflict(for: KeyChord("k"), excluding: "format.link"), "Link may share Instruct's keys")
        XCTAssertEqual(Shortcuts.conflict(for: KeyChord("k"), excluding: "format.bold")?.id, "format.link", "but not another Markdown command's")
    }

    func testAKeymapChangesDefaultsAndKeepsThePersonsOwn() {
        Shortcuts.set(KeyChord("y", [.command, .control]), for: "editor.toggleComment")
        Shortcuts.keymap = .vscode
        defer { Shortcuts.keymap = .xcode }
        XCTAssertEqual(Shortcuts.chord("editor.selectNextOccurrence"), KeyChord("d"))
        XCTAssertEqual(Shortcuts.chord("navigate.jumpToDefinition")?.display, "F12")
        XCTAssertEqual(Shortcuts.chord("editor.toggleComment"), KeyChord("y", [.command, .control]), "your own stays on top")
        Shortcuts.keymap = .jetbrains
        XCTAssertEqual(Shortcuts.chord("navigate.jumpToDefinition"), KeyChord("b"))
        XCTAssertEqual(Shortcuts.chord("editor.deleteLine")?.display, "\u{2318}\u{232B}")
        Shortcuts.keymap = .xcode
        XCTAssertEqual(Shortcuts.chord("editor.duplicateLine"), KeyChord("d"))
    }

    /// Every key in the menu bar is one of the table's, with the table's chord.
    func testEveryMenuShortcutComesFromTheTable() throws {
        let make = MakeWorkspaceViewController()
        make.loadViewIfNeeded()
        let main = try XCTUnwrap(NSApp.mainMenu)
        let tableChords = Set(Shortcuts.all.compactMap { Shortcuts.chord($0.id) })
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if let submenu = item.submenu { walk(submenu) }
                guard !item.keyEquivalent.isEmpty else { continue }
                // What macOS adds to an Edit menu itself (Dictation, Emoji & Symbols) isn't Side's.
                let system: Set<String> = ["startDictation:", "orderFrontCharacterPalette:"]
                if let action = item.action, system.contains(NSStringFromSelector(action)) { continue }
                XCTAssertTrue(tableChords.contains(KeyChord(item.keyEquivalent, item.keyEquivalentModifierMask)),
                              "\(item.title) has \(KeyChord(item.keyEquivalent, item.keyEquivalentModifierMask).display), which isn't in the table")
            }
        }
        walk(main)
    }

    func testARebindingReachesTheMenuAndCanBeUndone() throws {
        let make = MakeWorkspaceViewController()
        make.loadViewIfNeeded()
        XCTAssertEqual(Shortcuts.boundChord("edit.instruct"), KeyChord("k"))
        Shortcuts.set(KeyChord("i", [.command, .shift]), for: "edit.instruct")
        XCTAssertEqual(Shortcuts.boundChord("edit.instruct"), KeyChord("i", [.command, .shift]))
        XCTAssertEqual(Shortcuts.display("edit.instruct"), "\u{21E7}\u{2318}I")
        XCTAssertTrue(Shortcuts.isChanged("edit.instruct"))
        Shortcuts.set(nil, for: "edit.instruct")
        XCTAssertNil(Shortcuts.boundChord("edit.instruct"), "no shortcut at all")
        Shortcuts.reset("edit.instruct")
        XCTAssertEqual(Shortcuts.boundChord("edit.instruct"), KeyChord("k"))
        XCTAssertFalse(Shortcuts.isChanged("edit.instruct"))
    }

    func testConflictsAreFoundAndFixedOnesStayPut() {
        XCTAssertEqual(Shortcuts.conflict(for: KeyChord("s"), excluding: "edit.instruct")?.id, "file.save")
        XCTAssertNil(Shortcuts.conflict(for: KeyChord("y", [.command, .control, .option]), excluding: "edit.instruct"))
        Shortcuts.set(KeyChord("y", [.command, .option]), for: "think.send")
        XCTAssertEqual(Shortcuts.chord("think.send"), KeyChord("\r", []), "a fixed shortcut isn't rebound")
    }

    func testTheRecorderHearsTheKeyWithoutShiftApplied() throws {
        let recorder = ShortcutRecorder(commandID: "edit.instruct")
        var recorded: KeyChord??
        recorder.onRecord = { recorded = $0 }
        let press = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0, windowNumber: 0, context: nil,
                                                   characters: "!", charactersIgnoringModifiers: "!", isARepeat: false, keyCode: 18))
        recorder.pressForTesting(press)
        XCTAssertEqual(recorded??.display, "\u{21E7}\u{2318}1")
        let bare = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                                  characters: "k", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40))
        recorded = nil
        recorder.pressForTesting(bare)
        XCTAssertNil(recorded, "a bare letter would stop you typing it")
    }

    func testSearchFindsByTitleAreaAndKeys() {
        let instruct = Shortcuts.command("edit.instruct")!
        XCTAssertTrue(ShortcutsViewController.matches(instruct, "instr"))
        XCTAssertTrue(ShortcutsViewController.matches(instruct, "edit"))
        XCTAssertTrue(ShortcutsViewController.matches(instruct, "\u{2318}K"))
        XCTAssertFalse(ShortcutsViewController.matches(instruct, "terminal"))
    }

    /// Settings → Shortcuts as a table (2026-11-05): areas head their commands, the filters
    /// narrow them, and keys only a view's own list uses aren't counted as conflicts.
    @MainActor
    func testTheShortcutsTableFiltersByKeysChangesAndConflicts() {
        let all = ShortcutsViewController.rows(query: "", keys: nil, area: nil, changedOnly: false, conflictsOnly: false)
        XCTAssertEqual(all.filter { if case .command = $0 { return true } else { return false } }.count, Shortcuts.all.count)
        if case .area = all.first {} else { XCTFail("an area heads the table") }
        let byKeys = ShortcutsViewController.rows(query: "", keys: KeyChord("k"), area: nil, changedOnly: false, conflictsOnly: false)
        let titles = byKeys.compactMap { row -> String? in if case .command(let command) = row { return command.title } else { return nil } }
        XCTAssertTrue(titles.allSatisfy { title in Shortcuts.all.contains { $0.title == title && Shortcuts.chord($0.id) == KeyChord("k") } })
        XCTAssertFalse(titles.isEmpty)
        XCTAssertTrue(ShortcutsViewController.conflicting().allSatisfy { id in Shortcuts.command(id)?.isFixed == false })
        let editorOnly = ShortcutsViewController.rows(query: "", keys: nil, area: .editor, changedOnly: false, conflictsOnly: false)
        XCTAssertTrue(editorOnly.allSatisfy { row in
            switch row {
            case .area(let area, _): return area == .editor
            case .command(let command): return command.area == .editor
            }
        })
    }
}
