import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var windows: [NSWindow] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = makeWindow()
        windows.append(window)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        (window.contentViewController as? ShellViewController)?.restoreLastSessionIfAvailable()
    }

    @objc func newWindow() {
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
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Side"
        window.toolbarStyle = .unifiedCompact
        window.minSize = NSSize(width: 900, height: 620)
        // Side is built as a single, deliberately dark experience — not "whatever the system
        // appearance happens to be". Without forcing this, the *native* title bar/toolbar
        // chrome (drawn by AppKit itself, outside any of our own view backgrounds) stays
        // light on a Mac in Light Mode, and our own NSVisualEffectView chrome materials
        // resolve their vibrancy against that light backdrop too — which is exactly why the
        // chrome still read as too bright/gray despite our own views using dark colors.
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(calibratedWhite: 0.098, alpha: 1)
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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let dirtyShells = windows.compactMap { $0.contentViewController as? ShellViewController }.filter { $0.hasUnsavedChanges }
        guard !dirtyShells.isEmpty else { return .terminateNow }
        confirmAll(dirtyShells) { proceed in
            NSApp.reply(toApplicationShouldTerminate: proceed)
        }
        return .terminateLater
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
