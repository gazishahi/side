import AppKit
import SideAgents

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
        case "\\": return "\\"
        case String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)): return "\u{2191}"
        case String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)): return "\u{2193}"
        case String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)): return "\u{2190}"
        case String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)): return "\u{2192}"
        default:
            // F1–F20.
            if let scalar = key.unicodeScalars.first, scalar.value >= 0xF704, scalar.value <= 0xF717 { return "F\(scalar.value - 0xF704 + 1)" }
            return key.uppercased()
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
        case tabs = "Tabs", stages = "Stages", run = "Terminal", debug = "Debug", track = "Tracks", window = "Window"
        case editor = "Editor", think = "Agent", review = "Changes", palette = "Palette", format = "Format"
    }

    /// A kind of file a command belongs to: its shortcut works only there, and there it wins
    /// over a command for every file on the same keys (⌘K is Link in Markdown, Instruct
    /// elsewhere; ⌘B is Bold in Markdown, Build in LaTeX).
    enum Context: String {
        case markdown, latex
    }

    struct Command: Equatable {
        let id: String
        let title: String
        let area: Area
        let defaultChord: KeyChord?
        /// Handled inside a view (a text field, a list), not by a menu: shown, not rebindable.
        var isFixed = false
        /// The kind of file it belongs to; nil for every file.
        var context: Context?
    }

    private static func c(_ id: String, _ title: String, _ area: Area, _ key: String?, _ mods: NSEvent.ModifierFlags = .command) -> Command {
        Command(id: id, title: title, area: area, defaultChord: key.map { KeyChord($0, mods) })
    }
    private static func c(_ id: String, _ title: String, _ area: Area, _ key: String?, _ mods: NSEvent.ModifierFlags = .command, in context: Context) -> Command {
        Command(id: id, title: title, area: area, defaultChord: key.map { KeyChord($0, mods) }, context: context)
    }
    private static func fixed(_ id: String, _ title: String, _ area: Area, _ key: String, _ mods: NSEvent.ModifierFlags = []) -> Command {
        Command(id: id, title: title, area: area, defaultChord: KeyChord(key, mods), isFixed: true)
    }

    static let up = String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
    static let down = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
    static let left = String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
    static let right = String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
    static func f(_ n: Int) -> String { String(Character(UnicodeScalar(UInt32(NSF1FunctionKey) + UInt32(n - 1))!)) }
    static let backspace = "\u{8}"

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
        c("file.buildLaTeX", "Build LaTeX Document", .file, "b", in: .latex),
        c("file.showInPDF", "Show in PDF", .file, "b", [.command, .option], in: .latex),

        c("format.bold", "Bold", .format, "b", in: .markdown),
        c("format.italic", "Italic", .format, "i", in: .markdown),
        c("format.link", "Link\u{2026}", .format, "k", in: .markdown),

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
        c("view.agentPanel", "Show Agent Panel", .view, "j", [.command, .option]),
        c("view.minimap", "Show Minimap", .view, "m", [.command, .control]),
        c("view.writerMode", "Writer Mode", .view, "w", [.command, .control]),
        c("view.liveMarkdown", "Live Markdown", .view, nil),
        c("view.zoomIn", "Zoom In", .view, "="),
        c("view.zoomOut", "Zoom Out", .view, "-"),
        c("view.actualSize", "Actual Size", .view, "0"),

        c("navigate.quickOpen", "Quick Open", .navigate, "p"),
        c("navigate.commandPalette", "Command Palette", .navigate, "p", [.command, .shift]),
        c("navigate.goToLine", "Go to Line\u{2026}", .navigate, "l"),
        c("navigate.goToSymbol", "Go to Symbol\u{2026}", .navigate, "o", [.command, .shift]),
        c("navigate.jumpToDefinition", "Jump to Definition", .navigate, "j", [.command, .control]),

        c("stage.make", "Go to Editor", .stages, "1", [.command, .option]),
        c("stage.think", "Go to Agent", .stages, "2", [.command, .option]),
        c("stage.review", "Go to Changes", .stages, "3", [.command, .option]),
        c("stage.run", "Go to Terminal", .stages, "4", [.command, .option]),
        c("stage.tracks", "Go to Branches", .stages, "0", [.command, .option]),

        c("tabs.1", "Switch to Tab 1", .tabs, "1"), c("tabs.2", "Switch to Tab 2", .tabs, "2"),
        c("tabs.3", "Switch to Tab 3", .tabs, "3"), c("tabs.4", "Switch to Tab 4", .tabs, "4"),
        c("tabs.5", "Switch to Tab 5", .tabs, "5"), c("tabs.6", "Switch to Tab 6", .tabs, "6"),
        c("tabs.7", "Switch to Tab 7", .tabs, "7"), c("tabs.8", "Switch to Tab 8", .tabs, "8"),
        c("tabs.last", "Switch to Last Tab", .tabs, "9"),
        c("project.switcher", "Switch Project\u{2026}", .window, "p", [.control, .command]),
        c("session.switcher", "Switch Session\u{2026}", .window, "s", [.control, .command]),
        c("project.next", "Next Project", .window, "]", [.control, .command]),
        c("project.previous", "Previous Project", .window, "[", [.control, .command]),
        c("project.1", "Switch to Project 1", .window, "1", .control), c("project.2", "Switch to Project 2", .window, "2", .control),
        c("project.3", "Switch to Project 3", .window, "3", .control), c("project.4", "Switch to Project 4", .window, "4", .control),
        c("project.5", "Switch to Project 5", .window, "5", .control), c("project.6", "Switch to Project 6", .window, "6", .control),
        c("project.7", "Switch to Project 7", .window, "7", .control), c("project.8", "Switch to Project 8", .window, "8", .control),
        c("project.9", "Switch to Project 9", .window, "9", .control),
        c("tabs.next", "Next Tab", .tabs, "\t", .control),
        c("tabs.previous", "Previous Tab", .tabs, "\t", [.control, .shift]),

        c("run.newTerminal", "New Terminal Tab", .run, "t"),
        c("run.stop", "Stop", .run, "."),
        c("run.restart", "Restart Terminal", .run, "r", [.command, .shift]),
        c("run.rerun", "Rerun Last Command", .run, nil),

        c("debug.start", "Start Debugging", .debug, "r"),
        c("debug.pauseContinue", "Pause or Continue", .debug, "y", [.command, .control]),
        c("debug.stop", "Stop Debugging", .debug, ".", [.command, .shift]),
        c("debug.stepOver", "Step Over", .debug, f(6), []),
        c("debug.stepIn", "Step Into", .debug, f(7), []),
        c("debug.stepOut", "Step Out", .debug, f(8), []),
        c("debug.choose", "Choose What to Debug\u{2026}", .debug, nil),
        c("debug.attach", "Attach to Process\u{2026}", .debug, nil),
        c("debug.toggleBreakpoint", "Toggle Breakpoint", .debug, "\\"),

        c("track.new", "New Track\u{2026}", .track, "t", [.command, .shift]),
        c("track.switch", "Switch Track\u{2026}", .track, "t", [.command, .control]),
        fixed("track.move", "Move through tracks (list and switcher)", .track, down),
        fixed("track.open", "Switch to the selected track", .track, "\r"),

        c("window.minimize", "Minimize", .window, "m"),
        c("window.zoom", "Zoom", .window, nil),
        c("window.library", "Library", .window, "l", [.command, .shift]),
        c("window.runningTerminals", "Running Terminals", .window, nil),

        c("editor.fold", "Fold", .editor, left, [.command, .option]),
        c("editor.unfold", "Unfold", .editor, right, [.command, .option]),
        c("editor.foldAll", "Fold All", .editor, left, [.command, .option, .shift]),
        c("editor.unfoldAll", "Unfold All", .editor, right, [.command, .option, .shift]),
        c("editor.complete", "Show Completions", .editor, " ", .control),
        c("editor.format", "Format Document", .editor, "i", [.control, .shift]),
        c("editor.quickHelp", "Show Quick Help", .editor, "i", [.control, .command]),
        c("editor.references", "Find References", .editor, "r", [.control, .command]),
        c("editor.rename", "Rename Symbol\u{2026}", .editor, "e", [.control, .command]),
        c("editor.quickFix", "Quick Fix\u{2026}", .editor, ".", [.command, .option]),
        c("editor.problems", "Show Problems", .editor, "m", [.command, .shift]),
        c("editor.toggleComment", "Toggle Comment", .editor, "/"),
        c("editor.moveLineUp", "Move Line Up", .editor, "[", [.command, .option]),
        c("editor.moveLineDown", "Move Line Down", .editor, "]", [.command, .option]),
        c("editor.duplicateLine", "Duplicate Line", .editor, "d"),
        c("editor.deleteLine", "Delete Line", .editor, "k", [.command, .shift]),
        c("editor.indent", "Indent", .editor, "]"),
        c("editor.outdent", "Outdent", .editor, "["),
        c("editor.joinLines", "Join Lines", .editor, nil),
        c("editor.selectNextOccurrence", "Select Next Occurrence", .editor, "e", [.command, .option]),
        c("editor.selectAllOccurrences", "Select All Occurrences", .editor, "e", [.command, .option, .shift]),
        c("editor.expandSelection", "Expand Selection", .editor, right, [.command, .control, .shift]),
        c("editor.shrinkSelection", "Shrink Selection", .editor, left, [.command, .control, .shift]),
        c("editor.matchingBracket", "Go to Matching Bracket", .editor, "\\", [.command, .shift]),
        fixed("editor.caretAbove", "Add a caret above", .editor, up, [.command, .option]),
        fixed("editor.caretBelow", "Add a caret below", .editor, down, [.command, .option]),
        fixed("editor.oneCaret", "Back to one caret", .editor, "\u{1B}"),

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
    nonisolated(unsafe) static var defaults: UserDefaults = HeronDefaults.store

    /// The person's changes: id → "modifiers:key", or "" for none.
    private static var overrides: [String: String] {
        get { defaults.dictionary(forKey: defaultsKey) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: defaultsKey) }
    }

    /// The chord in effect: the person's, else the keymap's default.
    static func chord(_ id: String) -> KeyChord? {
        if let stored = overrides[id] {
            guard !stored.isEmpty, let colon = stored.firstIndex(of: ":"), let modifiers = UInt(stored[..<colon]) else { return nil }
            return KeyChord(String(stored[stored.index(after: colon)...]), NSEvent.ModifierFlags(rawValue: modifiers))
        }
        return defaultChord(id)
    }

    // MARK: Keymaps (SIDE_RFC_IDE_ESSENTIALS.md, L5)

    /// Whose keys: Xcode's (Side's own, the table above), VS Code's or JetBrains'. The person's
    /// own changes sit on top of whichever it is.
    enum Keymap: String, CaseIterable {
        case xcode, vscode, jetbrains
        var title: String {
            switch self {
            case .xcode: return "Xcode"
            case .vscode: return "VS Code"
            case .jetbrains: return "JetBrains"
            }
        }
    }

    private static let keymapKey = "SideKeymap"

    static var keymap: Keymap {
        get { Keymap(rawValue: defaults.string(forKey: keymapKey) ?? "") ?? .xcode }
        set {
            defaults.set(newValue.rawValue, forKey: keymapKey)
            all.forEach { refreshBoundItems($0.id) }
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    /// A command's default in the current keymap (nil: none).
    static func defaultChord(_ id: String) -> KeyChord? { defaultChord(id, in: keymap) }

    static func defaultChord(_ id: String, in keymap: Keymap) -> KeyChord? {
        if let preset = presets[keymap], let chord = preset[id] { return chord }
        return command(id)?.defaultChord
    }

    /// Where each keymap differs from the table (Xcode's): id → chord, or nil to have none.
    static let presets: [Keymap: [String: KeyChord?]] = [
        .vscode: [
            "editor.moveLineUp": KeyChord(up, .option), "editor.moveLineDown": KeyChord(down, .option),
            "editor.duplicateLine": KeyChord(down, [.option, .shift]),
            "editor.selectNextOccurrence": KeyChord("d"), "editor.selectAllOccurrences": KeyChord("l", [.command, .shift]),
            "window.library": KeyChord("l", [.command, .option]),
            "navigate.goToLine": KeyChord("g", .control),
            "navigate.jumpToDefinition": KeyChord(f(12), []), "editor.references": KeyChord(f(12), .shift),
            "editor.rename": KeyChord(f(2), []),
            "editor.quickFix": KeyChord("."), "run.stop": KeyChord(".", [.command, .option]),
            "editor.joinLines": KeyChord("j", .control),
            "debug.start": KeyChord(f(5), []), "debug.pauseContinue": KeyChord(f(6), []), "debug.stop": KeyChord(f(5), .shift),
            "debug.stepOver": KeyChord(f(10), []), "debug.stepIn": KeyChord(f(11), []), "debug.stepOut": KeyChord(f(11), .shift),
            "debug.toggleBreakpoint": KeyChord(f(9), []),
        ],
        .jetbrains: [
            "editor.moveLineUp": KeyChord(up, [.option, .shift]), "editor.moveLineDown": KeyChord(down, [.option, .shift]),
            "editor.deleteLine": KeyChord(backspace),
            "editor.selectNextOccurrence": KeyChord("g", .control), "editor.selectAllOccurrences": KeyChord("g", [.command, .control]),
            "editor.expandSelection": KeyChord(up, .option), "editor.shrinkSelection": KeyChord(down, .option),
            "editor.matchingBracket": KeyChord("m", [.control, .shift]),
            "editor.joinLines": KeyChord("j", [.control, .shift]),
            "navigate.jumpToDefinition": KeyChord("b"), "editor.references": KeyChord(f(7), .option),
            "editor.rename": KeyChord(f(6), .shift), "editor.format": KeyChord("l", [.command, .option]),
            "editor.quickFix": KeyChord("\r", .option), "editor.quickHelp": KeyChord(f(1), []),
            "navigate.goToSymbol": KeyChord("o", [.command, .option]), "navigate.quickOpen": KeyChord("o", [.command, .shift]),
            "debug.start": KeyChord("d", .control), "debug.pauseContinue": KeyChord("r", [.command, .option]), "debug.stop": KeyChord(f(2)),
            "debug.stepOver": KeyChord(f(8), []), "debug.stepIn": KeyChord(f(7), []), "debug.stepOut": KeyChord(f(8), .shift),
            "debug.toggleBreakpoint": KeyChord(f(8)),
            // ⌘B is Go to Declaration there; ⌘F9 is its Build.
            "file.buildLaTeX": KeyChord(f(9)),
        ],
    ]

    static func isChanged(_ id: String) -> Bool { overrides[id] != nil }

    /// The chord as the palette and menus show it, "" for none.
    static func display(_ id: String) -> String { chord(id)?.display ?? "" }

    /// The key is being held down: a repeat of the shortcut, not a new press. Opening and closing
    /// tabs act on presses only, as Rex's do; held, ⌘W emptied the strip and ⌘T filled it.
    @MainActor static var isKeyRepeat: Bool {
        guard let event = NSApp.currentEvent, event.type == .keyDown else { return false }
        return event.isARepeat
    }

    /// Another command already on this chord, if any (fixed ones included: they'd still win in
    /// their view).
    static func conflict(for chord: KeyChord, excluding id: String) -> Command? {
        // Commands for different kinds of file, or one for a kind and one for all (which it
        // covers there), can share keys.
        let context = command(id)?.context
        return all.first { $0.id != id && $0.context == context && self.chord($0.id) == chord }
    }

    /// Rebinds a command (nil: no shortcut). Menus bound to it update at once.
    static func set(_ chord: KeyChord?, for id: String) {
        guard let command = command(id), !command.isFixed else { return }
        var stored = overrides
        if chord == defaultChord(id) {
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
        apply(effectiveChord(id), to: item)
        return item
    }

    private static func refreshBoundItems(_ id: String) {
        for weak in bound[id] ?? [] { if let item = weak.item { apply(effectiveChord(id), to: item) } }
    }

    /// The kind of file in front (Make sets it as tabs change): which contextual shortcuts
    /// are live, and which global ones they cover.
    static var activeContext: Context? {
        didSet {
            guard activeContext != oldValue else { return }
            for id in bound.keys { refreshBoundItems(id) }
        }
    }

    /// The chord a menu item carries now: a contextual command's only in its kind of file; a
    /// global one's unless a live contextual command has taken the same keys.
    static func effectiveChord(_ id: String) -> KeyChord? {
        guard let chord = chord(id), let command = command(id) else { return nil }
        if let context = command.context { return context == activeContext ? chord : nil }
        guard let activeContext else { return chord }
        let taken = all.contains { $0.context == activeContext && self.chord($0.id) == chord }
        return taken ? nil : chord
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
