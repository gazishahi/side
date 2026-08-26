import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    /// Set once in `applicationDidFinishLaunching` — lets `ShellViewController` (one per window,
    /// no reference to its siblings) ask for a dock-badge refresh without `AppDelegate` having
    /// to reach back into every window's Tracks state itself.
    static private(set) var shared: AppDelegate?

    private var windows: [NSWindow] = []
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
        let window = makeWindow()
        windows.append(window)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        (window.contentViewController as? ShellViewController)?.restoreLastSessionIfAvailable()
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
    func openTrackInNewWindow(projectRoot: URL, trackKey: String?, focusingFile: URL? = nil, at screenPoint: NSPoint? = nil) {
        let window = presentNewWindow()
        if let screenPoint {
            // A torn-out tab lands where it was dropped, not wherever the cascade would put it.
            window.setFrameTopLeftPoint(screenPoint)
        }
        let shell = window.contentViewController as? ShellViewController
        shell?.openProject(at: projectRoot, focusingTrackKey: trackKey)
        if let focusingFile { shell?.revealFile(focusingFile) }
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

    @objc func showPreferences() {
        if preferencesWindow == nil {
            let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Preferences"
            window.isReleasedWhenClosed = false
            window.contentViewController = PreferencesTabViewController()
            preferencesWindow = window
        }
        preferencesWindow?.center()
        preferencesWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow {
        // .fullSizeContentView is load-bearing, not cosmetic: without it, titlebarAppearsTransparent
        // only clears the title-text row — the unified toolbar strip beneath it (where our stage
        // switcher/search field live) keeps rendering its own opaque system material regardless of
        // window.backgroundColor. With it, our content view's background extends up behind the
        // whole title+toolbar region instead of stopping below it, which is what actually lets our
        // color show through there.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Side"
        window.toolbarStyle = .unifiedCompact
        window.minSize = NSSize(width: 980, height: 620)
        // Side is built as a single, deliberately dark experience — not "whatever the system
        // appearance happens to be". Without forcing this, the *native* title bar/toolbar
        // chrome (drawn by AppKit itself, outside any of our own view backgrounds) stays
        // light on a Mac in Light Mode, and our own NSVisualEffectView chrome materials
        // resolve their vibrancy against that light backdrop too — which is exactly why the
        // chrome still read as too bright/gray despite our own views using dark colors.
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(white: 0.098, alpha: 1)
        // Even with dark appearance forced, the native title/toolbar strip still renders
        // using the system's own dark-mode material — a medium charcoal, visibly lighter
        // than the app's near-black content. This is very likely the real source of "still
        // too light": that strip runs across the top of every window, Make or Run, whether
        // or not a tab bar is showing beneath it. Making it transparent lets our own
        // near-black backgroundColor show through instead, unifying the two.
        window.titlebarAppearsTransparent = true
        window.contentViewController = ShellViewController()
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
