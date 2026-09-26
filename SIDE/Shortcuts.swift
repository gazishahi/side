import AppKit

/// A key and its modifiers, as a menu item takes them.
struct KeyChord: Equatable, Hashable, Codable {
    /// The key equivalent: a lowercase character, or a special one ("\t", "\r", an arrow).
    var key: String
    var modifiers: UInt

    init(_ key: String, _ modifiers: NSEvent.ModifierFlags = .command) {
        self.key = key
        self.modifiers = modifiers.intersection([.command, .option, .control, .shift]).rawValue
    }

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    /// ⌃⌥⇧⌘ then the key, as the menu bar writes it.
    var display: String {
        var text = ""
        if flags.contains(.control) { text += "\u{2303}" }
        if flags.contains(.option) { text += "\u{2325}" }
        if flags.contains(.shift) { text += "\u{21E7}" }
        if flags.contains(.command) { text += "\u{2318}" }
        return text + Self.keyName(key)
    }

    static func keyName(_ key: String) -> String {
        switch key {
        case "\t": return "\u{21E5}"
        case "\r": return "\u{21A9}"
        case " ": return "Space"
        case "\u{1B}": return "\u{238B}"
        case "\u{8}", "\u{7F}": return "\u{232B}"
        case String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)): return "\u{2191}"
        case String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)): return "\u{2193}"
        case String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)): return "\u{2190}"
        case String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)): return "\u{2192}"
        default: return key.uppercased()
        }
    }

    /// From a key press, as the recorder hears it. Nil for a press with no key a menu can use.
    init?(event: NSEvent) {
        // The key itself, without Shift applied: ⇧⌘1 is "1" with ⇧, not "!".
        guard let characters = (event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers)?.lowercased(),
              let first = characters.first else { return nil }
        var key = String(first)
        if event.keyCode == 48 { key = "\t" }
        if event.keyCode == 36 { key = "\r" }
        self.init(key, event.modifierFlags)
    }

    /// A menu shortcut needs ⌘ or ⌃ (or is a function key): a bare letter would stop typing it.
    var isUsable: Bool {
        flags.contains(.command) || flags.contains(.control) || key.unicodeScalars.first.map { $0.value >= 0xF700 } == true
    }
}

/// Every keyboard shortcut Side has, in one table (docs/SIDE_PLAN_EDITOR_SHORTCUTS.md): menus and
/// the palette take their keys from here, and Settings → Shortcuts lists and rebinds them.
@MainActor
enum Shortcuts {
    enum Area: String, CaseIterable {
        case app = "Side", file = "File", edit = "Edit", find = "Find", view = "View", navigate = "Navigate"
        case tabs = "Tabs", stages = "Stages", run = "Run", track = "Tracks", window = "Window"
        case think = "Think", review = "Review", palette = "Palette"
    }

    struct Command: Equatable {
        let id: String
        let title: String
        let area: Area
        let defaultChord: KeyChord?
        /// Handled inside a view (a text field, a list), not by a menu: shown, not rebindable.
        var isFixed = false
    }

    private static func c(_ id: String, _ title: String, _ area: Area, _ key: String?, _ mods: NSEvent.ModifierFlags = .command) -> Command {
        Command(id: id, title: title, area: area, defaultChord: key.map { KeyChord($0, mods) })
    }
    private static func fixed(_ id: String, _ title: String, _ area: Area, _ key: String, _ mods: NSEvent.ModifierFlags = []) -> Command {
        Command(id: id, title: title, area: area, defaultChord: KeyChord(key, mods), isFixed: true)
    }

    static let up = String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
    static let down = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
    static let left = String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
    static let right = String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))

    static let all: [Command] = [
        c("app.preferences", "Settings\u{2026}", .app, ","),
        c("app.hide", "Hide Side", .app, "h"),
        c("app.hideOthers", "Hide Others", .app, "h", [.command, .option]),
        c("app.quit", "Quit Side", .app, "q"),

        c("file.newWindow", "New Window", .file, "n", [.command, .shift]),
        c("file.newFile", "New File", .file, "n"),
        c("file.newProject", "New Project\u{2026}", .file, nil),
        c("file.openProject", "Open Project\u{2026}", .file, "o"),
        c("file.save", "Save", .file, "s"),
        c("file.saveAs", "Save As\u{2026}", .file, "s", [.command, .shift]),
        c("file.revert", "Revert to Saved", .file, nil),
        c("file.closeTab", "Close Tab", .file, "w"),

        c("edit.undo", "Undo", .edit, "z"),
        c("edit.redo", "Redo", .edit, "z", [.command, .shift]),
        c("edit.cut", "Cut", .edit, "x"),
        c("edit.copy", "Copy", .edit, "c"),
        c("edit.paste", "Paste", .edit, "v"),
        c("edit.selectAll", "Select All", .edit, "a"),
        c("edit.instruct", "Instruct\u{2026}", .edit, "k"),

        c("find.find", "Find\u{2026}", .find, "f"),
        c("find.replace", "Find and Replace\u{2026}", .find, "f", [.command, .option]),
        c("find.next", "Find Next", .find, "g"),
        c("find.previous", "Find Previous", .find, "g", [.command, .shift]),
        c("find.useSelection", "Use Selection for Find", .find, "e"),
        c("find.inProject", "Find in Project\u{2026}", .find, "f", [.command, .shift]),
        fixed("find.replaceAll", "Replace All (in the replace field)", .find, "\r", .option),

        c("view.markdownPreview", "Toggle Markdown Preview", .view, "v", [.command, .shift]),
        c("view.fileExplorer", "Toggle File Explorer", .view, "e", [.command, .shift]),

        c("navigate.quickOpen", "Quick Open", .navigate, "p"),
        c("navigate.commandPalette", "Command Palette", .navigate, "p", [.command, .shift]),
        c("navigate.goToLine", "Go to Line\u{2026}", .navigate, "l"),
        c("navigate.goToSymbol", "Go to Symbol\u{2026}", .navigate, "o", [.command, .shift]),
        c("navigate.jumpToDefinition", "Jump to Definition", .navigate, "j", [.command, .control]),

        c("stage.make", "Go to Make", .stages, "1", [.command, .option]),
        c("stage.think", "Go to Think", .stages, "2", [.command, .option]),
        c("stage.review", "Go to Review", .stages, "3", [.command, .option]),
        c("stage.run", "Go to Run", .stages, "4", [.command, .option]),
        c("stage.tracks", "Go to Tracks", .stages, "0", [.command, .option]),

        c("tabs.1", "Switch to Tab 1", .tabs, "1"), c("tabs.2", "Switch to Tab 2", .tabs, "2"),
        c("tabs.3", "Switch to Tab 3", .tabs, "3"), c("tabs.4", "Switch to Tab 4", .tabs, "4"),
        c("tabs.5", "Switch to Tab 5", .tabs, "5"), c("tabs.6", "Switch to Tab 6", .tabs, "6"),
        c("tabs.7", "Switch to Tab 7", .tabs, "7"), c("tabs.8", "Switch to Tab 8", .tabs, "8"),
        c("tabs.last", "Switch to Last Tab", .tabs, "9"),
        c("tabs.next", "Next Tab", .tabs, "\t", .control),
        c("tabs.previous", "Previous Tab", .tabs, "\t", [.control, .shift]),

        c("run.newTerminal", "New Terminal Tab", .run, "t"),
        c("run.stop", "Stop", .run, "."),
        c("run.restart", "Restart Terminal", .run, "r", [.command, .shift]),
        c("run.rerun", "Rerun Last Command", .run, nil),

        c("track.new", "New Track\u{2026}", .track, "t", [.command, .shift]),
        c("track.switch", "Switch Track\u{2026}", .track, "t", [.command, .control]),
        fixed("track.move", "Move through tracks (list and switcher)", .track, down),
        fixed("track.open", "Switch to the selected track", .track, "\r"),

        c("window.minimize", "Minimize", .window, "m"),
        c("window.zoom", "Zoom", .window, nil),
        c("window.library", "Library", .window, "l", [.command, .shift]),

        fixed("think.send", "Send", .think, "\r"),
        fixed("think.newline", "New line", .think, "\r", .shift),
        fixed("think.history", "Earlier messages (on the first line)", .think, up),

        fixed("review.step", "Step through checkpoints", .review, right),
        fixed("review.extend", "Extend the range", .review, right, .shift),
        fixed("review.viewed", "Mark a file viewed (in the list)", .review, " "),
        fixed("review.all", "All changes", .review, "\u{1B}"),

        fixed("palette.move", "Move through results", .palette, down),
        fixed("palette.open", "Open the result", .palette, "\r"),
        fixed("palette.previous", "Previous match (Find)", .palette, "\r", .shift),
        fixed("palette.scope", "This file / project (Find)", .palette, "\t"),
        fixed("palette.close", "Close", .palette, "\u{1B}"),
    ]

    static func command(_ id: String) -> Command? { all.first { $0.id == id } }

    // MARK: What's in effect

    static let didChangeNotification = Notification.Name("SideShortcutsDidChange")
    private static let defaultsKey = "SideShortcuts"
    /// Per process under tests, like the other preferences.
    nonisolated(unsafe) static var defaults: UserDefaults = NSClassFromString("XCTestCase") == nil
        ? .standard : UserDefaults(suiteName: "side.tests.shortcuts.\(ProcessInfo.processInfo.processIdentifier)") ?? .standard

    /// The person's changes: id → "modifiers:key", or "" for none.
    private static var overrides: [String: String] {
        get { defaults.dictionary(forKey: defaultsKey) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: defaultsKey) }
    }

    /// The chord in effect: the person's, else the default.
    static func chord(_ id: String) -> KeyChord? {
        if let stored = overrides[id] {
            guard !stored.isEmpty, let colon = stored.firstIndex(of: ":"), let modifiers = UInt(stored[..<colon]) else { return nil }
            return KeyChord(String(stored[stored.index(after: colon)...]), NSEvent.ModifierFlags(rawValue: modifiers))
        }
        return command(id)?.defaultChord
    }

    static func isChanged(_ id: String) -> Bool { overrides[id] != nil }

    /// The chord as the palette and menus show it, "" for none.
    static func display(_ id: String) -> String { chord(id)?.display ?? "" }

    /// Another command already on this chord, if any (fixed ones included: they'd still win in
    /// their view).
    static func conflict(for chord: KeyChord, excluding id: String) -> Command? {
        all.first { $0.id != id && self.chord($0.id) == chord }
    }

    /// Rebinds a command (nil: no shortcut). Menus bound to it update at once.
    static func set(_ chord: KeyChord?, for id: String) {
        guard let command = command(id), !command.isFixed else { return }
        var stored = overrides
        if chord == command.defaultChord {
            stored[id] = nil
        } else {
            stored[id] = chord.map { "\($0.modifiers):\($0.key)" } ?? ""
        }
        overrides = stored
        refreshBoundItems(id)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    static func reset(_ id: String) {
        var stored = overrides
        stored[id] = nil
        overrides = stored
        refreshBoundItems(id)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    static func resetAll() {
        let changed = Array(overrides.keys)
        overrides = [:]
        changed.forEach(refreshBoundItems)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    // MARK: Menus

    private final class WeakItem { weak var item: NSMenuItem? ; init(_ item: NSMenuItem) { self.item = item } }
    private static var bound: [String: [WeakItem]] = [:]

    /// Gives a menu item its command's chord, and keeps it current as the person rebinds.
    @discardableResult
    static func bind(_ item: NSMenuItem, _ id: String) -> NSMenuItem {
        assert(command(id) != nil, "no shortcut command \(id)")
        bound[id, default: []].removeAll { $0.item == nil }
        bound[id, default: []].append(WeakItem(item))
        apply(chord(id), to: item)
        return item
    }

    private static func refreshBoundItems(_ id: String) {
        for weak in bound[id] ?? [] { if let item = weak.item { apply(chord(id), to: item) } }
    }

    private static func apply(_ chord: KeyChord?, to item: NSMenuItem) {
        item.keyEquivalent = chord?.key ?? ""
        item.keyEquivalentModifierMask = chord?.flags ?? []
    }

    /// The chord a bound menu item has now (tests).
    static func boundChord(_ id: String) -> KeyChord? {
        bound[id]?.compactMap(\.item).first.flatMap { $0.keyEquivalent.isEmpty ? nil : KeyChord($0.keyEquivalent, $0.keyEquivalentModifierMask) }
    }
}

extension String {
    /// Nil for "", for labels that shouldn't show an empty shortcut.
    var nonEmpty: String? { isEmpty ? nil : self }
}
