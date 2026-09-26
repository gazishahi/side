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

    func testNoTwoMenuCommandsShareADefault() {
        let menu = Shortcuts.all.filter { !$0.isFixed }
        var seen: [KeyChord: String] = [:]
        for command in menu {
            guard let chord = command.defaultChord else { continue }
            XCTAssertNil(seen[chord], "\(command.id) and \(seen[chord] ?? "") both default to \(chord.display)")
            seen[chord] = command.id
        }
        XCTAssertEqual(Set(Shortcuts.all.map(\.id)).count, Shortcuts.all.count, "ids are unique")
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
}
