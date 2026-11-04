import AppKit
import SideSessionsKit
import Heron
import os.signpost

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    /// Set once in `applicationDidFinishLaunching` — lets `ShellViewController` (one per window,
    /// no reference to its siblings) ask for a dock-badge refresh without `AppDelegate` having
    /// to reach back into every window's Tracks state itself.
    static private(set) var shared: AppDelegate?

    private var windows: [NSWindow] = []
    /// Purely for tests and instrumentation to observe that the deferred restore ran.
    private(set) var didFinishRestoring = false
    private var preferencesWindow: NSWindow?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Every pipe write goes through `PipeWriting`, which turns a vanished reader into an
        // error for that descriptor; this is the backstop for any write that doesn't. A child
        // exiting must never end Side (2026-09-30 audit, H1).
        signal(SIGPIPE, SIG_IGN)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        TextScaleFollower.start()
        SystemNotifier.shared.start()
        // Which agents are installed, off the main thread: the default agent new tracks take.
        if DefaultAgent.detects { AgentAvailability.refresh {} }
        // Persistence failures used to be swallowed by `try?` — a full disk or a revoked
        // permission lost the user's tracks and conversations without a word. They arrive here
        // now and get said out loud, once per file.
        NotificationCenter.default.addObserver(
            self, selector: #selector(persistenceFailed(_:)),
            name: PersistenceFailureReporter.failureNotification, object: nil
        )
        LaunchSignposts.begin("firstFrame")
        LaunchSignposts.begin("makeWindow")
        let window = makeWindow()
        LaunchSignposts.end("makeWindow")
        windows.append(window)
        window.center()
        LaunchSignposts.begin("orderFront")
        window.makeKeyAndOrderFront(nil)
        LaunchSignposts.end("orderFront")
        LaunchSignposts.begin("activate")
        NSApp.activate(ignoringOtherApps: true)
        LaunchSignposts.end("activate")

        // UI tests launch with `-SideUITesting YES` (which lands in UserDefaults' argument
        // domain). Restoring the developer's real last project would make a test run poke at
        // their working tree — and make the tests depend on whatever was open last.
        guard !Self.isUITesting else {
            LaunchSignposts.end("firstFrame")
            LaunchSignposts.reportProcessStart()
            // A test that needs a project passes its own throwaway one — without it the stages
            // are empty shells, and "the terminal is in the AX tree" is unfalsifiable.
            // Tracks a UI test creates put their worktrees somewhere temporary, not in the
            // person's Application Support.
            GitPaths.worktreesSupportDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("SideUITests", isDirectory: true)
            let volatile = UserDefaults(suiteName: "side.uitesting.volatile") ?? .standard
            volatile.removePersistentDomain(forName: "side.uitesting.volatile")
            HeronDefaults.store = volatile
            GitLaunchProbe.defaults = volatile
            ProjectRules.defaults = volatile
            MakeWorkspaceViewController.preferences = volatile
            StagePins.defaults = volatile
            ProjectSpaces.defaults = volatile
            Shortcuts.defaults = volatile
            LanguageSettings.defaults = volatile
            ReviewViewedStore.shared = ReviewViewedStore(defaults: volatile)
            DispatchQueue.main.async { [weak self] in
                (window.contentViewController as? ShellViewController)?.presentFirstRunIfNeeded()
                // Nothing to restore here, and done: a side:// link (a notification's click)
                // waits for this, and under UI testing it never came, so the link was dropped.
                self?.didFinishRestoring = true
            }
            // Measurement scripts drive Make directly (opening through the UI with synthetic
            // events proved unreliable): "open <path>" and "close-all", UI testing only.
            DistributedNotificationCenter.default().addObserver(forName: Notification.Name("side.uitesting.command"), object: nil, queue: .main) { note in
                guard let command = note.object as? String else { return }
                MainActor.assumeIsolated {
                    guard let shell = window.contentViewController as? ShellViewController else { return }
                    if command.hasPrefix("open ") { shell.revealFile(URL(fileURLWithPath: String(command.dropFirst(5)))) }
                    if command == "close-all" { shell.closeAllMakeTabsForTesting() }
                    if command == "run-close-tab" { shell.closeActiveRunTabForTesting() }
                    // "tab-x 2": a click on the third tab's X, in Editor or Terminal, whichever shows.
                    if command.hasPrefix("tab-x "), let index = Int(command.dropFirst(6)) { shell.clickTabCloseForTesting(index) }
                    if command == "tabs-dump" {
                        FileHandle.standardError.write(Data("[tabs] \(shell.tabsDumpForTesting)\n".utf8))
                    }
                    if command == "activity-open" { shell.activityPillForTesting?.clickForTesting() }
                    if command.hasPrefix("project-switch ") { shell.switchProject(to: URL(fileURLWithPath: String(command.dropFirst(15)))) }
                    if command.hasPrefix("project-step ") { shell.switchProject(offset: Int(command.dropFirst(13)) ?? 1) }
                    if command.hasPrefix("activity-go "), let index = Int(command.dropFirst(12)), ActivityCenter.shared.items.indices.contains(index) {
                        ActivityCenter.shared.go(to: ActivityCenter.shared.items[index])
                    }
                    if command == "activity-dump" {
                        ActivityCenter.shared.refresh()
                        let sessions = ProjectContextRegistry.openContexts().flatMap { $0.terminals.everySession() }
                        let lines = sessions.map { "session \($0.title) working=\($0.viewController.isProgramWorking) program=\($0.viewController.runningProgramName ?? "-") unseen=\($0.hasUnseenOutput)" }
                            + ActivityCenter.shared.items.map { "item \($0.title) \($0.state) \($0.place)" }
                            + ["stage \(shell.currentStageForTesting ?? "-")", "pill \(shell.activityPillForTesting?.view.isShown == true ? (shell.activityPillForTesting?.view.title ?? "") + " " + (shell.activityPillForTesting?.view.countForTesting ?? "") : "-")",
                               "popover \(shell.activityPillForTesting?.popoverForTesting?.isShown == true)",
                               "project \(shell.projectRootURL?.lastPathComponent ?? "-")",
                               "windows \(self.shellViewControllers.count)"]
                        FileHandle.standardError.write(Data(("[activity]\n" + lines.joined(separator: "\n") + "\n").utf8))
                    }
                    // "stage-badge 3 needsYou": a status dot on a stage, as attention would set it.
                    if command.hasPrefix("stage-badge ") {
                        let parts = command.split(separator: " ").map(String.init)
                        let states: [String: DS.StatusState] = ["needsYou": .needsYou, "failed": .failed, "unread": .unread, "verified": .verified]
                        if parts.count == 3, let index = Int(parts[1]) { shell.stageBadgeForTesting(index, state: states[parts[2]]) }
                    }
                    if command == "hints on" || command == "hints off" { TabShortcutHints.setShowingForTesting(command == "hints on") }
                    if command.hasPrefix("window-size ") {
                        let parts = command.split(separator: " ").compactMap { Double($0) }
                        if parts.count == 2 { window.setContentSize(NSSize(width: parts[0], height: parts[1])) }
                    }
                    // "update downloading 0.05", "update ready": the update pill's stages.
                    if command.hasPrefix("update ") {
                        let parts = command.split(separator: " ").map(String.init)
                        switch parts[1] {
                        case "available": Updates.shared.driver.setStageForTesting(.available(version: "9.9.9"))
                        case "downloading": Updates.shared.driver.setStageForTesting(.downloading(fraction: parts.count > 2 ? Double(parts[2]) : nil))
                        case "preparing": Updates.shared.driver.setStageForTesting(.preparing)
                        case "ready": Updates.shared.driver.setStageForTesting(.ready)
                        default: Updates.shared.driver.setStageForTesting(.none)
                        }
                    }
                    // The window as composited, animations in flight included: "snapshot <path>",
                    // or "snapshots <dir> <count> <ms>" for frames of a motion. An app may capture
                    // its own windows without screen-recording permission.
                    if command.hasPrefix("snapshot ") { Self.snapshot(window, to: String(command.dropFirst(9))) }
                    // Every window on screen (Settings, popovers, sheets): "snapshot-all <dir>".
                    if command.hasPrefix("snapshot-all ") {
                        let dir = String(command.dropFirst(13))
                        for (index, each) in NSApp.windows.enumerated() where each.isVisible && each.frame.width > 40 {
                            let name = String(describing: type(of: each)).replacingOccurrences(of: " ", with: "")
                            Self.snapshot(each, to: "\(dir)/\(index)-\(name).png")
                        }
                    }
                    if command.hasPrefix("appearance ") {
                        let name = String(command.dropFirst(11))
                        NSApp.appearance = name == "dark" ? NSAppearance(named: .darkAqua) : name == "light" ? NSAppearance(named: .aqua) : nil
                    }
                    if command.hasPrefix("snapshots ") {
                        let parts = command.split(separator: " ").map(String.init)
                        if parts.count == 4, let count = Int(parts[2]), let ms = Int(parts[3]) {
                            // Off the main thread: what happens while it's busy (a stage loading)
                            // is what these are for.
                            let number = UInt32(window.windowNumber)
                            for frame in 0..<count {
                                DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + .milliseconds(frame * ms)) {
                                    Self.snapshot(windowNumber: number, to: "\(parts[1])/frame-\(String(format: "%03d", frame)).png")
                                }
                            }
                        }
                    }
                    if command.hasPrefix("find ") { shell.findForTesting(String(command.dropFirst(5))) }
                    if command.hasPrefix("think-track ") { shell.thinkTrackForTesting(agentId: String(command.dropFirst(12))) }
                    if command.hasPrefix("think-send ") { shell.thinkSendForTesting(String(command.dropFirst(11))) }
                    if command.hasPrefix("stage ") { shell.showStageForTesting(String(command.dropFirst(6))) }
                    if command == "toggle-preview" { shell.toggleMarkdownPreviewForTesting() }
                    if command == "switcher" { shell.toggleTrackPopover(nil) }
                    if command == "projects" { shell.projectChipForTesting.togglePopover() }
                    // "key cmd+2", "key ctrl+shift+tab": a chord as the menu bar receives it; "… repeat",
                    // as a held key's repeats arrive.
                    if command.hasPrefix("key ") {
                        let words = String(command.dropFirst(4)).split(separator: " ")
                        let isRepeat = words.dropFirst().contains("repeat")
                        let parts = (words.first.map(String.init) ?? "").split(separator: "+").map { String($0).lowercased() }
                        var flags: NSEvent.ModifierFlags = []
                        for part in parts.dropLast() {
                            switch part {
                            case "cmd": flags.insert(.command)
                            case "ctrl": flags.insert(.control)
                            case "opt", "alt": flags.insert(.option)
                            case "shift": flags.insert(.shift)
                            default: break
                            }
                        }
                        let key = parts.last.map { $0 == "tab" ? "\t" : $0 } ?? ""
                        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                                        windowNumber: window.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: isRepeat, keyCode: 0) {
                            // Through the event queue, as a real one comes: then it's the current event.
                            NSApp.postEvent(event, atStart: false)
                        }
                    }
                    // "open-url side://run/<id>": a link as macOS hands one over (a notification's click).
                    if command.hasPrefix("open-url "), let url = URL(string: String(command.dropFirst(9))) { self.application(NSApp, open: [url]) }
                    if command.hasPrefix("stage-hover ") { shell.stageControlForTesting.hoverForTesting(Int(command.dropFirst(12))) }
                    if command.hasPrefix("theme-light ") { EditorThemes.lightThemeID = String(command.dropFirst(12)) }
                    if command.hasPrefix("theme-dark ") { EditorThemes.darkThemeID = String(command.dropFirst(11)) }
                    if command.hasPrefix("theme-import "), let data = FileManager.default.contents(atPath: String(command.dropFirst(13))),
                       let theme = try? EditorThemes.importVSCodeTheme(data, fallbackName: "imported") {
                        if theme.isDark { EditorThemes.darkThemeID = theme.id } else { EditorThemes.lightThemeID = theme.id }
                    }
                    if command.hasPrefix("keymap "), let keymap = Shortcuts.Keymap(rawValue: String(command.dropFirst(7))) { Shortcuts.keymap = keymap }
                    if command.hasPrefix("pin-only ") { StagePins.pinned = [ShellViewController.Stage(rawValue: String(command.dropFirst(9)))].compactMap { $0 }.reduce(into: Set()) { $0.insert($1) } }
                    if command.hasPrefix("run-type ") { shell.runTypeForTesting(String(command.dropFirst(9))) }
                    if command.hasPrefix("run-select "), let index = Int(command.dropFirst(11)) { shell.runSelectForTesting(index) }
                    // Any menu action, down the responder chain: "action foldAll:".
                    if command.hasPrefix("action ") { NSApp.sendAction(NSSelectorFromString(String(command.dropFirst(7))), to: nil, from: nil) }
                    if command.hasPrefix("settings "), let pane = SettingsSplitViewController.Pane(rawValue: String(command.dropFirst(9))) {
                        (NSApp.delegate as? AppDelegate)?.showPreferences()
                        ((NSApp.delegate as? AppDelegate)?.preferencesWindow?.contentViewController as? SettingsSplitViewController)?.select(pane)
                    }
                    // What's scheduled on the main run loop (timers and their callouts): for finding idle wakeups.
                    if command == "runloop" { FileHandle.standardError.write(Data("\(String(describing: CFRunLoopGetMain()))\n".utf8)) }
                    if command.hasPrefix("project ") { shell.openProject(at: URL(fileURLWithPath: String(command.dropFirst(8))), focusingTrackKey: nil) }
                    if command.hasPrefix("scroll ") { shell.scrollForTesting(pages: Int(command.dropFirst(7)) ?? 1) }
                    // Settings: "settings-end" scrolls its page to the bottom; "settings-popup <label> <n>"
                    // picks the nth item of the popup with that accessibility label, as a click would.
                    if command == "settings-end" || command.hasPrefix("settings-popup "), let root = self.preferencesWindow?.contentView {
                        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
                        if command == "settings-end" {
                            for scroll in all(root).compactMap({ $0 as? NSScrollView }) {
                                guard let document = scroll.documentView else { continue }
                                document.scroll(NSPoint(x: 0, y: document.isFlipped ? document.bounds.maxY : 0))
                            }
                        } else {
                            let words = command.dropFirst(15).split(separator: " ")
                            if let index = words.last.flatMap({ Int($0) }) {
                                let label = words.dropLast().joined(separator: " ")
                                if let popup = all(root).compactMap({ $0 as? NSPopUpButton }).first(where: { $0.accessibilityLabel() == label }) {
                                    popup.selectItem(at: index)
                                    _ = popup.sendAction(popup.action, to: popup.target)
                                }
                            }
                        }
                    }
                }
            }
            if let fixture = UserDefaults.standard.string(forKey: "SideUITestingProject") {
                DispatchQueue.main.async {
                    (window.contentViewController as? ShellViewController)?.openProject(at: URL(fileURLWithPath: fixture), focusingTrackKey: nil)
                }
            }
            return
        }

        // Restoring is deferred one run-loop turn, and that single line is the whole point.
        //
        // AppKit commits a frame at the end of a run-loop iteration. The window was ordered
        // front above, but calling restore *here* means this method never returns, the loop
        // never turns, and the user stares at an empty window frame for however long the
        // restore takes. Side was showing a window in half a bounce and then holding it blank
        // — the launch looked fast and felt slow, which is the worst combination.
        //
        // Handing the work to the next turn inverts that: the first frame — the real, correct,
        // no-project state Side already ships — is committed, and the project arrives into a
        // live window. That is the "prep a single frame" shape: minimize what must be true
        // before one frame can be committed, rather than minimizing total work.
        //
        // What makes this honest rather than a trick is that the deferred work is now *fast*
        // (see GitLaunchProbe: six subprocesses became one, or zero when cached). Deferring
        // slow main-thread work only trades a blank window for a hitching one.
        DispatchQueue.main.async { [weak self] in
            LaunchSignposts.end("firstFrame")
            LaunchSignposts.reportProcessStart()
            LaunchSignposts.begin("restoreSession")
            (window.contentViewController as? ShellViewController)?.restoreLastSessionIfAvailable()
            LaunchSignposts.end("restoreSession")
            (window.contentViewController as? ShellViewController)?.presentFirstRunIfNeeded()
            self?.didFinishRestoring = true
            // Not while hosting unit tests: a real crash on this Mac would put a sheet over them.
            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil { CrashReports.offer(in: window) }
        }
    }

    @objc private func persistenceFailed(_ notification: Notification) {
        guard let failure = notification.object as? PersistenceFailureReporter.Failure else { return }
        let isWrite = failure.operation == .write
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = isWrite
            ? "Side couldn't save \(failure.url.lastPathComponent)"
            : "Side couldn't read \(failure.url.lastPathComponent)"
        let consequence = isWrite
            ? "Recent changes may not have been saved."
            : "That file's contents were skipped."
        alert.informativeText = "\(failure.error.localizedDescription)\n\n\(failure.url.path)\n\n\(consequence)"
        alert.addButton(withTitle: "OK")
        // A sheet, never `runModal()`: a store that saves on every change can fail repeatedly,
        // and a modal run loop here blocks the whole app (including whatever is mid-save) until
        // someone clicks. With no window yet — a failure during launch — the log line
        // `PersistenceFailureReporter` already wrote is the only report available.
        guard let window = NSApp.keyWindow ?? windows.first else { return }
        alert.beginSheetModal(for: window)
    }

    /// The key window's shell, or the first one if none is key — File-menu project commands
    /// act on whichever window the user is actually looking at.
    private var activeShell: ShellViewController? {
        (NSApp.keyWindow?.contentViewController as? ShellViewController)
            ?? (windows.first?.contentViewController as? ShellViewController)
    }

    /// UI tests launch with `-SideUITesting YES`. Everything that would persist the developer's
    /// state consults this: the test's fixture project must never become the last-opened project,
    /// a recent, or a cached probe — the first UI run did exactly that.
    nonisolated static let isUITesting = UserDefaults.standard.bool(forKey: "SideUITesting")

    /// About Side, with the open-source components' notices (ThirdPartyNotices.txt, written by
    /// scripts/third-party-notices.py): their MIT and BSD licenses require them to ship with the
    /// app. In the label color, so they read in dark mode, where imported text stays black.
    @objc func showAboutPanel(_ sender: Any?) {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
        if let notices = Self.thirdPartyNotices {
            options[.credits] = NSAttributedString(string: notices, attributes: [
                .font: DS.Text.caption(),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
        }
        NSApp.orderFrontStandardAboutPanel(options: options)
    }

    static var thirdPartyNotices: String? {
        Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    @objc func openProjectFromMenu() {
        if activeShell == nil { presentNewWindow() }
        activeShell?.presentOpenProject()
    }

    @objc func newProjectFromMenu() {
        if activeShell == nil { presentNewWindow() }
        activeShell?.presentNewProject()
    }

    @objc func newWindow() {
        presentNewWindow()
    }

    /// Tracks' "Open in New Window" — a fresh window on the same project, landed directly on one
    /// specific track rather than whatever this project's globally-active track happens to be,
    /// so two tracks can be watched or worked on side by side without either window's track
    /// switch disturbing the other.
    /// `soleFile` / `soleSession`: a tab or terminal torn out of another window — the new
    /// window holds it alone.
    func openTrackInNewWindow(projectRoot: URL, trackKey: String?, focusingFile: URL? = nil, soleFile: URL? = nil, soleSession: TerminalSession? = nil, at screenPoint: NSPoint? = nil) {
        let window = presentNewWindow()
        if let screenPoint {
            // A torn-out tab lands where it was dropped, not wherever the cascade would put it —
            // but always wholly on a screen: a drop near the bottom edge used to put the new
            // window mostly off it.
            window.setFrameTopLeftPoint(screenPoint)
            let screen = NSScreen.screens.first { $0.frame.contains(screenPoint) } ?? window.screen ?? NSScreen.main
            if let visible = screen?.visibleFrame {
                var frame = window.frame
                frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
                frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
                window.setFrame(frame, display: false)
            }
        }
        let shell = window.contentViewController as? ShellViewController
        shell?.openProject(at: projectRoot, focusingTrackKey: trackKey, soleFile: soleFile, soleSession: soleSession)
        if let focusingFile, soleFile == nil { shell?.revealFile(focusingFile) }
    }

    @discardableResult
    private func presentNewWindow() -> NSWindow {
        let window = makeWindow()
        windows.append(window)
        window.center()
        // Cascade so new windows don't stack exactly on top of existing ones.
        let offset = CGFloat((windows.count - 1) % 8) * 24
        var frame = window.frame
        frame.origin.x += offset
        frame.origin.y -= offset
        window.setFrame(frame, display: false)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return window
    }

    typealias PreferencesPane = SettingsSplitViewController.Pane

    /// Opens Preferences on a given pane: "Set Up an Agent…" lands on Agents (§6).
    func openPreferences(on pane: PreferencesPane) {
        showPreferences()
        (preferencesWindow?.contentViewController as? SettingsSplitViewController)?.select(pane)
    }

    /// Library for the frontmost project window (⇧⌘L).
    /// side://run/<session id>, from a notification a terminal's keeper posted: Side comes to
    /// that tab, opening its project first if no window has it.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "side" && url.host == "run" {
            let id = url.lastPathComponent
            guard !id.isEmpty, id != "/" else { continue }
            revealTerminal(id, attempts: 50)
        }
    }

    /// A click that launched Side arrives before the last project is restored (a turn after the
    /// first frame), so this waits for that first: opening the project again then would put it
    /// in a second window. Then the window with the session among its tabs (a torn-out one
    /// included), else one on its project, else a window with no project, else a new one.
    private func revealTerminal(_ id: String, attempts: Int) {
        guard attempts > 0 else { return }
        guard didFinishRestoring else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.revealTerminal(id, attempts: attempts - 1) }
            return
        }
        let record = SessionRecord.read(from: SessionPaths.record(id))
        let project = record?.client[SessionKeepers.Fact.project].map { URL(fileURLWithPath: $0) }
        let track = record?.client[SessionKeepers.Fact.track]
        let shells = shellViewControllers.sorted { $0.listsTerminal(keeperID: id) && !$1.listsTerminal(keeperID: id) }
        if shells.contains(where: { $0.revealTerminal(keeperID: id, inProject: project, trackKey: track) }) { return }
        guard let project else { return }
        // Held in the background by a window that switched away: that window comes back to it,
        // as `revealProject` does, rather than a new one opening.
        if ProjectSpaces.shared.isHeld(project),
           let front = (NSApp.keyWindow?.contentViewController as? ShellViewController) ?? shellViewControllers.first {
            front.view.window?.makeKeyAndOrderFront(nil)
            front.switchProject(to: project) { _ = $0.revealTerminal(keeperID: id, inProject: project, trackKey: track) }
            return
        }
        // Opened on the project's active track; revealing switches to the session's, landing on
        // Run (opening on that track would land on Make, and race the switch).
        if let empty = shellViewControllers.first(where: { !$0.hasProject }) {
            empty.openProject(at: project, focusingTrackKey: nil)
        } else {
            openTrackInNewWindow(projectRoot: project, trackKey: nil)
        }
        _ = shellViewControllers.contains(where: { $0.revealTerminal(keeperID: id, inProject: project, trackKey: track) })
    }

    /// UI testing: the window as the window server composites it, to a PNG.
    static func snapshot(_ window: NSWindow, to path: String) {
        snapshot(windowNumber: UInt32(window.windowNumber), to: path)
    }

    nonisolated static func snapshot(windowNumber: UInt32, to path: String) {
        // Looked up at run time: the SDK marks it unavailable (ScreenCaptureKit instead, which
        // needs screen-recording permission even for an app's own windows). Test-only.
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return }
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        let options = CGWindowImageOption.boundsIgnoreFraming.rawValue | CGWindowImageOption.bestResolution.rawValue
        guard let image = create(.null, CGWindowListOption.optionIncludingWindow.rawValue, windowNumber, options)?.takeRetainedValue() else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// The window on `project`, or a new one opened on it, then `then` on its shell.
    func revealProject(_ project: URL, then: @escaping (ShellViewController) -> Void) {
        let path = project.standardizedFileURL.path
        if let shell = shellViewControllers.first(where: { $0.projectRootURL?.standardizedFileURL.path == path }) { then(shell); return }
        // Held in the background by a window that switched away: the front window switches back,
        // as the project chip would. A new window opened for it instead (2026-11-04).
        if ProjectSpaces.shared.isHeld(project),
           let front = (NSApp.keyWindow?.contentViewController as? ShellViewController) ?? shellViewControllers.first {
            front.view.window?.makeKeyAndOrderFront(nil)
            front.switchProject(to: project) { then($0) }
            return
        }
        if let empty = shellViewControllers.first(where: { !$0.hasProject }) {
            empty.openProject(at: project, focusingTrackKey: nil)
            then(empty)
            return
        }
        openTrackInNewWindow(projectRoot: project, trackKey: nil)
        if let shell = shellViewControllers.last { then(shell) }
    }

    @objc func showRunningTerminals() {
        RunningTerminalsWindowController.shared.show()
    }

    @objc func showLibrary() {
        LibraryWindowController.shared.show(for: nil)
    }

    /// Settings, at one of its panes.
    func openSettings(at pane: SettingsSplitViewController.Pane) {
        showPreferences()
        (preferencesWindow?.contentViewController as? SettingsSplitViewController)?.select(pane)
    }

    @objc func showPreferences() {
        if preferencesWindow == nil {
            // System Settings' shape: full-height floating sidebar, no visible title bar.
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 640),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "Preferences"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.toolbar = NSToolbar(identifier: "SidePreferences")
            window.toolbarStyle = .unified
            window.isReleasedWhenClosed = false
            window.contentViewController = SettingsSplitViewController()
            window.setContentSize(NSSize(width: 820, height: 640))
            window.minSize = NSSize(width: 820, height: 420)
            window.backgroundColor = DS.Color.canvas
            window.setFrameAutosaveName("SidePreferences")
            preferencesWindow = window
        }
        if preferencesWindow?.isVisible != true { preferencesWindow?.center() }
        preferencesWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow {
        // The seamless frame (Direction 02 §3.2): full-size content, no toolbar, the title bar
        // transparent and undrawn — `installChrome` finishes the job before the window shows.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Side"
        window.minSize = NSSize(width: 760, height: 560)
        // Appearance is a preference (Match System / Light / Dark) applied at the application
        // level, not forced dark per window as it was while dark was the only palette. Every
        // token is dynamic, so the window follows whatever NSApp.appearance resolves to.
        DS.Appearance.bootstrap()
        window.backgroundColor = DS.Color.canvas
        window.titlebarAppearsTransparent = true
        let shell = ShellViewController()
        window.contentViewController = shell
        shell.installChrome(in: window)
        window.delegate = self
        // We manage window lifetime ourselves via `windows`, not an NSWindowController — the
        // default `true` has AppKit *also* drop its own ownership on close, which races our
        // array's cleanup and produces exactly the garbage-address EXC_BAD_ACCESS this was
        // causing on window close.
        window.isReleasedWhenClosed = false
        return window
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { windows.first?.makeKeyAndOrderFront(nil) }
        return true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let shell = sender.contentViewController as? ShellViewController else { return true }
        guard shell.hasUnsavedChanges else {
            shell.prepareForClose()
            return true
        }
        shell.confirmCloseAllUnsaved { [weak self] proceed in
            guard proceed else { return }
            shell.prepareForClose()
            self?.windows.removeAll { $0 === sender }
            sender.close()
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        windows.removeAll { $0 === window }
    }

    /// Always runs every shell's `prepareForClose()` before actually terminating — not just on
    /// the individual-window-close path (`windowShouldClose`). Without this, quitting with no
    /// unsaved *editor* changes (the only thing `hasUnsavedChanges` checks) skipped
    /// `prepareForClose()` entirely, so `ProjectContextRegistry` never released and an
    /// `AgentRunner` mid-approval-pause never got the chance to write its synthetic "closed
    /// before decided" tool results — leaving `think.json` with an orphaned `tool_use` the
    /// Messages API rejects outright on the next launch.
    func applicationWillTerminate(_ notification: Notification) {
        // Debugger servers (js-debug's node, Delve) don't end with their client.
        DAPSocketTransport.terminateAllServers()
        // The session index and usage are written a moment after they change; not after quit.
        JSONStore.flushPendingWrites()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let shells = windows.compactMap { $0.contentViewController as? ShellViewController }
        let dirtyShells = shells.filter { $0.hasUnsavedChanges }
        guard !dirtyShells.isEmpty else {
            shells.forEach { $0.prepareForClose() }
            return .terminateNow
        }
        confirmAll(dirtyShells) { proceed in
            if proceed { shells.forEach { $0.prepareForClose() } }
            NSApp.reply(toApplicationShouldTerminate: proceed)
        }
        return .terminateLater
    }

    /// The only signal that survives the app not being frontmost at all — everything else
    /// (stage badge, Tracks' pinned section, notifications) requires the app or a specific
    /// window/stage to already be in view. Summed across every open window; two windows on the
    /// same project double-count its tracks, an acceptable imprecision for a cosmetic badge.
    /// Every window's shell — the track pill's "Other projects" section reads across them.
    /// View › Toggle File Explorer, for the window in front, wherever its focus is.
    @objc func toggleFileExplorer(_ sender: Any?) {
        // The main window: with the explorer focused, the key window is its panel.
        (NSApp.mainWindow?.contentViewController as? ShellViewController)?.toggleFileExplorer()
    }

    var shellViewControllers: [ShellViewController] { windows.compactMap { $0.contentViewController as? ShellViewController } }

    func refreshDockBadge() {
        let total = windows.compactMap { $0.contentViewController as? ShellViewController }.reduce(0) { $0 + $1.needsYouCount }
        NSApp.dockTile.badgeLabel = total > 0 ? "\(total)" : nil
    }

    private func confirmAll(_ shells: [ShellViewController], completion: @escaping (Bool) -> Void) {
        var remaining = shells
        guard !remaining.isEmpty else { completion(true); return }
        let first = remaining.removeFirst()
        first.confirmCloseAllUnsaved { [weak self] proceed in
            guard proceed else { completion(false); return }
            self?.confirmAll(remaining, completion: completion)
        }
    }
}

@main
@MainActor
enum SideApplication {
    private static let appDelegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.delegate = appDelegate
        app.run()
    }
}
