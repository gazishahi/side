import AppKit
import UserNotifications

// The menu bar's list of what's still running while Side is closed (SIDE/BackgroundSessions.swift
// has the model). Side starts it as it quits, with terminals left running:
//
//   Side Notifier --menu --side <Side.app> --defaults <Side's defaults domain> --run <run directory>
//
// It shows only while there's something to show and Side isn't running: Side opening, or the last
// session ending, quits it. One at a time (a lock in the run directory).

final class MenuBar: NSObject, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private let sideApp: URL
    private let sideBundleID: String
    private let defaults: UserDefaults?
    private let run: URL
    private let inbox: URL
    private var item: NSStatusItem?
    private var rows: [BackgroundSessions.Row] = []
    private var keepers: [BackgroundSessions.Keeper] = []
    private var agents: [String: BackgroundSessions.Agent] = [:]
    private var readEvents: Set<String> = []
    private var sources: [DispatchSourceFileSystemObject] = []
    private var timer: Timer?
    private var spin: Timer?
    private var angle: CGFloat = 0
    private var shownOnce = false
    private var lock: Int32 = -1

    init(sideApp: URL, defaultsDomain: String, run: URL) {
        self.sideApp = sideApp
        sideBundleID = Bundle(url: sideApp)?.bundleIdentifier ?? defaultsDomain
        defaults = UserDefaults(suiteName: defaultsDomain)
        self.run = run
        inbox = ProcessInfo.processInfo.environment["SIDE_HOOKS_DIR"].map { URL(fileURLWithPath: $0) }
            ?? run.deletingLastPathComponent().appendingPathComponent("hooks", isDirectory: true)
    }

    func start() {
        // Off in Side's settings, another one already up, or Side running: nothing to do.
        if defaults?.object(forKey: BackgroundSessions.showKey) as? Bool == false { return quit() }
        lock = Darwin.open(run.appendingPathComponent("menu-bar.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else { return quit() }
        if sideIsRunning { return quit() }
        UNUserNotificationCenter.current().delegate = self
        for agent in BackgroundSessions.readSnapshot(BackgroundSessions.snapshotURL(run: run)) { agents[agent.id] = agent }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appLaunched(_:)), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        watch(run)
        watch(inbox)
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }

    private var sideIsRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: sideBundleID).isEmpty
    }

    @objc private func appLaunched(_ note: Notification) {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        if app?.bundleIdentifier == sideBundleID { quit() }
    }

    private func watch(_ folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fd = Darwin.open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in self?.refresh() }
        source.setCancelHandler { close(fd) }
        source.resume()
        sources.append(source)
    }

    // MARK: - Reading

    private func refresh() {
        readHookEvents()
        keepers = BackgroundSessions.Keeper.all(in: run).filter(\.isRunning)
        agents = agents.filter { !$0.value.ended }
        let next = BackgroundSessions.rows(keepers: keepers, agents: Array(agents.values), parent: BackgroundSessions.parent(of:))
        if next.isEmpty { return finish() }
        rows = next
        show()
    }

    /// Events written since Side quit, oldest first, each once. Left in place: Side reads them
    /// when it opens.
    private func readHookEvents() {
        let files = (try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles)) ?? []
        let fresh = files.filter { $0.pathExtension == "json" && !readEvents.contains($0.lastPathComponent) }
            .map { ($0, (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) }
            .sorted { ($0.1, $0.0.lastPathComponent) < ($1.1, $1.0.lastPathComponent) }
        for (url, _) in fresh {
            readEvents.insert(url.lastPathComponent)
            if let data = try? Data(contentsOf: url) { BackgroundSessions.apply(data, to: &agents, agentPID: Self.agentPID(fromHookParent:)) }
        }
    }

    /// The agent: the hook's parent, or past the shell the agent ran the hook through.
    static func agentPID(fromHookParent pid: Int32) -> Int32 {
        var current = pid
        for _ in 0..<3 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
            guard current > 1, proc_pidinfo(current, PROC_PIDTBSDINFO, 0, &info, size) == size else { return pid }
            let name = withUnsafeBytes(of: info.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            guard ["sh", "bash", "zsh", "dash", "fish"].contains(name) else { return current }
            current = Int32(info.pbi_ppid)
        }
        return current
    }

    // MARK: - The icon

    private func show() {
        if item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.setAccessibilityLabel("Side sessions")
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            self.item = item
        }
        shownOnce = true
        let summary = BackgroundSessions.summary(rows)
        item?.button?.title = summary.needsYou > 0 ? " \(summary.needsYou)" : ""
        item?.button?.imagePosition = .imageLeading
        item?.button?.toolTip = tooltip
        if summary.state == .working {
            if spin == nil {
                spin = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    angle -= .pi * 2 / 18
                    item?.button?.image = Self.icon(summary.state, angle: angle)
                }
            }
        } else {
            spin?.invalidate()
            spin = nil
        }
        item?.button?.image = Self.icon(summary.state, angle: angle)
        dumpForTesting()
    }

    /// UI tests (no screen to capture): `SIDE_MENU_BAR_DUMP=<folder>` gets the menu's items as
    /// text and the icon as a picture, on each change.
    private func dumpForTesting() {
        guard let folder = ProcessInfo.processInfo.environment["SIDE_MENU_BAR_DUMP"], let item else { return }
        let dir = URL(fileURLWithPath: folder, isDirectory: true)
        let menu = NSMenu()
        menuNeedsUpdate(menu, refreshing: false)
        let lines = menu.items.map { item -> String in
            if item.isSeparatorItem { return "---" }
            let title = item.attributedTitle?.string ?? item.title
            return (item.isAlternate ? "  \u{2325} " : "") + title + (item.subtitle.map { " / " + $0 } ?? "")
        }
        let text = "button: \(item.button?.title ?? "")\n" + lines.joined(separator: "\n") + "\n"
        try? text.write(to: dir.appendingPathComponent("menu.txt"), atomically: true, encoding: .utf8)
        if let image = item.button?.image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: dir.appendingPathComponent("icon.png"))
        }
    }

    private var tooltip: String {
        let counts = BackgroundSessions.State.allCases.compactMap { state -> String? in
            let n = rows.filter { $0.state == state }.count
            return n == 0 ? nil : "\(n) \(state.word.lowercased())"
        }
        return "Side: " + counts.joined(separator: ", ")
    }

    /// A terminal's glyph, and what's going on: a turning arc while working, a dot when something
    /// needs you, "!" when something failed, nothing when all have finished. A template image.
    static func icon(_ state: BackgroundSessions.State?, angle: CGFloat) -> NSImage {
        let size = NSSize(width: 20, height: 16)
        let image = NSImage(size: size, flipped: false) { _ in
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            if let glyph = NSImage(systemSymbolName: "apple.terminal", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                glyph.draw(in: NSRect(x: 0, y: (size.height - glyph.size.height) / 2, width: glyph.size.width, height: glyph.size.height))
            }
            let badge = NSRect(x: size.width - 7, y: 0, width: 7, height: 7)
            // A clear ring around the badge, so it doesn't run into the glyph.
            if state != nil, state != .finished {
                NSGraphicsContext.current?.compositingOperation = .clear
                NSBezierPath(ovalIn: badge.insetBy(dx: -1.5, dy: -1.5)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
            }
            NSColor.black.set()
            switch state {
            case .working?:
                let arc = NSBezierPath()
                let centre = NSPoint(x: badge.midX, y: badge.midY)
                let start = angle * 180 / .pi
                arc.appendArc(withCenter: centre, radius: 2.8, startAngle: start, endAngle: start + 270)
                arc.lineWidth = 1.4
                arc.lineCapStyle = .round
                arc.stroke()
            case .needsYou?:
                NSBezierPath(ovalIn: badge.insetBy(dx: 0.5, dy: 0.5)).fill()
            case .failed?:
                let mark = NSAttributedString(string: "!", attributes: [.font: NSFont.systemFont(ofSize: 9, weight: .heavy), .foregroundColor: NSColor.black])
                mark.draw(at: NSPoint(x: badge.midX - mark.size().width / 2, y: -1))
            default:
                break
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: - The menu

    func menuNeedsUpdate(_ menu: NSMenu) { menuNeedsUpdate(menu, refreshing: true) }

    private func menuNeedsUpdate(_ menu: NSMenu, refreshing: Bool) {
        if refreshing { refresh() }
        menu.removeAllItems()
        menu.autoenablesItems = false
        let header = NSMenuItem(title: "Side \u{2014} \(rows.count) session\(rows.count == 1 ? "" : "s")", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let now = Date()
        for state in BackgroundSessions.State.allCases {
            let group = rows.filter { $0.state == state }
            guard !group.isEmpty else { continue }
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: state.word))
            for row in group {
                let item = NSMenuItem(title: "", action: #selector(openRow(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = row.id
                item.attributedTitle = Self.title(row, now: now)
                if !row.detail.isEmpty { item.subtitle = row.detail }
                item.toolTip = "\(row.project) \u{00B7} \(row.label)"
                menu.addItem(item)
                let stop = NSMenuItem(title: "Stop \u{201C}\(Self.short(row.label))\u{201D}", action: #selector(stopRow(_:)), keyEquivalent: "")
                stop.target = self
                stop.representedObject = row.id
                stop.isAlternate = true
                stop.keyEquivalentModifierMask = .option
                menu.addItem(stop)
            }
        }
        menu.addItem(.separator())
        let open = NSMenuItem(title: "Open Side", action: #selector(openSide), keyEquivalent: "o")
        open.target = self
        menu.addItem(open)
        let stopAll = NSMenuItem(title: "Stop All Sessions\u{2026}", action: #selector(stopAll), keyEquivalent: "")
        stopAll.target = self
        menu.addItem(stopAll)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings\u{2026}", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
    }

    /// "side · Fix the flaky login test   4m": the time in the secondary color.
    static func title(_ row: BackgroundSessions.Row, now: Date) -> NSAttributedString {
        let font = NSFont.menuFont(ofSize: 0)
        let text = NSMutableAttributedString(string: row.project + " \u{00B7} ", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
        text.append(NSAttributedString(string: short(row.label), attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
        if let since = row.since {
            let ago = BackgroundSessions.duration(now.timeIntervalSince(since))
            let when = row.state == .finished || row.state == .failed ? (ago == "now" ? "just now" : ago + " ago") : ago
            text.append(NSAttributedString(string: "   " + when, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: font.pointSize - 1, weight: .regular), .foregroundColor: NSColor.tertiaryLabelColor]))
        }
        return text
    }

    static func short(_ text: String, limit: Int = 48) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "\u{2026}"
    }

    @objc private func openRow(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let url = URL(string: "side://run/\(id)") else { return }
        open(url)
    }

    @objc private func openSide() {
        NSWorkspace.shared.openApplication(at: sideApp, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func openSettings() {
        if let url = URL(string: "side://settings") { open(url) }
    }

    private func open(_ url: URL) {
        NSWorkspace.shared.open([url], withApplicationAt: sideApp, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func stopRow(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let keeper = keepers.first(where: { $0.id == id }) else { return }
        Self.end(keeper, run: run)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.refresh() }
    }

    @objc private func stopAll() {
        let working = rows.filter { $0.state == .working || $0.state == .needsYou }.count
        let alert = NSAlert()
        alert.messageText = rows.count == 1 ? "Stop the session still running?" : "Stop all \(rows.count) sessions still running?"
        alert.informativeText = (working > 0 ? "\(working) \(working == 1 ? "is" : "are") still working. " : "")
            + "Their terminals close, and whatever runs in them ends."
        alert.addButton(withTitle: "Stop All").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let ids = Set(rows.map(\.id))
        for keeper in keepers where ids.contains(keeper.id) { Self.end(keeper, run: run) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.refresh() }
    }

    /// As closing its tab would (`SessionKeepers.end`): SIGTERM to the whole tree, SIGHUP to the
    /// shell; then the keeper and its files go, since no tab will come to hear how it ended.
    static func end(_ keeper: BackgroundSessions.Keeper, run: URL) {
        var targets = [keeper.childPID]
        var frontier = [keeper.childPID]
        while let pid = frontier.popLast() {
            var children = [pid_t](repeating: 0, count: 512)
            let bytes = proc_listchildpids(pid, &children, Int32(children.count * MemoryLayout<pid_t>.size))
            for child in children.prefix(max(0, Int(bytes))) where child > 0 { targets.append(child); frontier.append(child) }
        }
        for pid in targets where pid > 0 { kill(pid, SIGTERM) }
        if keeper.childPID > 0 { kill(keeper.childPID, SIGHUP) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if keeper.isRunning { kill(keeper.keeperPID, SIGKILL) }
            for name in ["sock", "json", "launch.json", "snap", "log"] {
                try? FileManager.default.removeItem(at: run.appendingPathComponent("\(keeper.id).\(name)"))
            }
        }
    }

    // MARK: - Going

    /// Nothing left: a check for a moment if the menu was showing, then gone.
    private func finish() {
        guard shownOnce, let button = item?.button else { return quit() }
        timer?.invalidate()
        spin?.invalidate()
        sources.forEach { $0.cancel() }
        sources = []
        button.title = ""
        button.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: "Every session has ended")
        button.image?.isTemplate = true
        item?.menu = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.quit() }
    }

    private func quit() {
        if let item { NSStatusBar.system.removeStatusItem(item) }
        NSApp.terminate(nil)
    }

    // A notification a keeper posted, clicked while the menu runs: macOS hands the click here.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if let link = response.notification.request.content.userInfo["url"] as? String, let url = URL(string: link) { open(url) }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
}
