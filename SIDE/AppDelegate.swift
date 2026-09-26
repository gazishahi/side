import AppKit
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
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
            GitLaunchProbe.defaults = volatile
            ProjectRules.defaults = volatile
            DispatchQueue.main.async { (window.contentViewController as? ShellViewController)?.presentFirstRunIfNeeded() }
            // Measurement scripts drive Make directly (opening through the UI with synthetic
            // events proved unreliable): "open <path>" and "close-all", UI testing only.
            DistributedNotificationCenter.default().addObserver(forName: Notification.Name("side.uitesting.command"), object: nil, queue: .main) { note in
                guard let command = note.object as? String else { return }
                MainActor.assumeIsolated {
                    guard let shell = window.contentViewController as? ShellViewController else { return }
                    if command.hasPrefix("open ") { shell.revealFile(URL(fileURLWithPath: String(command.dropFirst(5)))) }
                    if command == "close-all" { shell.closeAllMakeTabsForTesting() }
                    if command.hasPrefix("find ") { shell.findForTesting(String(command.dropFirst(5))) }
                    if command.hasPrefix("think-track ") { shell.thinkTrackForTesting(agentId: String(command.dropFirst(12))) }
                    if command.hasPrefix("think-send ") { shell.thinkSendForTesting(String(command.dropFirst(11))) }
                    if command.hasPrefix("stage ") { shell.showStageForTesting(String(command.dropFirst(6))) }
                    if command == "toggle-preview" { shell.toggleMarkdownPreviewForTesting() }
                    if command == "switcher" { shell.toggleTrackPopover(nil) }
                    if command.hasPrefix("settings "), let pane = SettingsSplitViewController.Pane(rawValue: String(command.dropFirst(9))) {
                        (NSApp.delegate as? AppDelegate)?.showPreferences()
                        ((NSApp.delegate as? AppDelegate)?.preferencesWindow?.contentViewController as? SettingsSplitViewController)?.select(pane)
                    }
                    // What's scheduled on the main run loop (timers and their callouts): for finding idle wakeups.
                    if command == "runloop" { FileHandle.standardError.write(Data("\(String(describing: CFRunLoopGetMain()))\n".utf8)) }
                    if command.hasPrefix("project ") { shell.openProject(at: URL(fileURLWithPath: String(command.dropFirst(8))), focusingTrackKey: nil) }
                    if command.hasPrefix("scroll ") { shell.scrollForTesting(pages: Int(command.dropFirst(7)) ?? 1) }
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

    /// Opens Preferences on a given pane: "Set up a model…" lands on Providers (§6).
    func openPreferences(on pane: PreferencesPane) {
        showPreferences()
        (preferencesWindow?.contentViewController as? SettingsSplitViewController)?.select(pane)
    }

    /// Library for the frontmost project window (⇧⌘L).
    @objc func showLibrary() {
        LibraryWindowController.shared.show(for: nil)
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
