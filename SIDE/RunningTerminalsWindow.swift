import AppKit
import SideSessionsKit

/// Window → Running Terminals (SIDE_RFC_SESSION_RESTORE.md, phase 3): every terminal running in a
/// keeper, across projects, open or not: what it's running, how long it's been quiet, its memory,
/// and End. Nothing keeps running out of sight: a project closed with terminals left running
/// still shows them here.
@MainActor
final class RunningTerminalsWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = RunningTerminalsWindowController()

    private struct Row {
        let record: SessionRecord
        let project: String
        let tab: String
        let running: String
        let idle: String
        let memoryMB: Double
    }

    private let table = NSTableView()
    private let summary = NSTextField(labelWithString: "")
    private let endAllButton = NSButton(title: "End All", target: nil, action: nil)
    private let emptyState = DS.EmptyState()
    private var header: NSTableHeaderView?
    private var rows: [Row] = []
    private var timer: Timer?

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 360),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Running Terminals"
        window.minSize = NSSize(width: 560, height: 220)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("SideRunningTerminals")
        super.init(window: window)
        window.delegate = self
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show() {
        refresh()
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }

    private func build() {
        let columns: [(String, String, CGFloat)] = [("project", "Project", 130), ("tab", "Tab", 190), ("running", "Running", 120), ("idle", "Quiet for", 80), ("memory", "Memory", 70), ("end", "", 60)]
        for (id, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = id == "end" ? 60 : 50
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        // Side's list look, not a spreadsheet's: inset rows, no stripes (the visual audit).
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = false
        table.rowHeight = 30
        table.allowsMultipleSelection = false
        table.setAccessibilityLabel("Running terminals")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        summary.font = DS.Text.caption()
        summary.textColor = .secondaryLabelColor
        summary.translatesAutoresizingMaskIntoConstraints = false
        endAllButton.target = self
        endAllButton.action = #selector(endAll)
        endAllButton.bezelStyle = .rounded
        endAllButton.translatesAutoresizingMaskIntoConstraints = false

        emptyState.symbol = "terminal"
        emptyState.configure("No terminals are running.", action: nil, handler: nil)
        emptyState.isHidden = true
        let content = NSView()
        content.addSubview(scroll)
        content.addSubview(emptyState)
        content.addSubview(summary)
        content.addSubview(endAllButton)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: endAllButton.topAnchor, constant: -10),
            summary.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            summary.centerYAnchor.constraint(equalTo: endAllButton.centerYAnchor),
            endAllButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            endAllButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            emptyState.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
        window?.contentView = content
    }

    // MARK: - Data

    private func refresh() {
        let open = Self.openSessionsByKeeper()
        rows = SessionPaths.records().filter { $0.exit == nil && SessionKeepers.isRunning($0) }.map { record in
            let project = record.client[SessionKeepers.Fact.project].map { ($0 as NSString).lastPathComponent } ?? "—"
            let tab = open[record.id]?.title ?? TerminalViewController.cleanProgramTitle(record.title) ?? (record.directory as NSString).lastPathComponent
            let running = ForegroundProgram.name(arguments: record.foreground) ?? "shell"
            return Row(record: record, project: project, tab: tab, running: running,
                       idle: Self.idleText(Date().timeIntervalSince(record.lastOutputAt)), memoryMB: Self.treeFootprintMB(record))
        }
        table.reloadData()
        let total = rows.reduce(0) { $0 + $1.memoryMB }
        emptyState.isHidden = !rows.isEmpty
        // No headers over nothing: hidden, they still kept their band.
        if header == nil { header = table.headerView }
        table.headerView = rows.isEmpty ? nil : header
        summary.stringValue = rows.isEmpty ? "" : "\(rows.count) terminal\(rows.count == 1 ? "" : "s") running · \(String(format: "%.0f", total)) MB"
        endAllButton.isEnabled = !rows.isEmpty
    }

    static func idleText(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<10: return "now"
        case ..<60: return "\(Int(seconds)) s"
        case ..<3600: return "\(Int(seconds / 60)) min"
        case ..<86_400: return "\(Int(seconds / 3600)) h"
        default: return "\(Int(seconds / 86_400)) d"
        }
    }

    /// The keeper and everything running under it (the shell, its jobs): what the session costs.
    static func treeFootprintMB(_ record: SessionRecord) -> Double {
        var total: UInt64 = 0
        var frontier = [record.keeperPID]
        var seen = Set<pid_t>()
        while let pid = frontier.popLast(), seen.insert(pid).inserted {
            var info = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) } }
            if ok == 0 { total += info.ri_phys_footprint }
            var children = [pid_t](repeating: 0, count: 256)
            let bytes = proc_listchildpids(pid, &children, Int32(children.count * MemoryLayout<pid_t>.size))
            frontier += children.prefix(max(0, Int(bytes))).filter { $0 > 0 }
        }
        return Double(total) / 1_048_576
    }

    /// Every open tab's session, by its keeper's id.
    static func openSessionsByKeeper() -> [String: (manager: TerminalSessionManager, session: TerminalSession, title: String)] {
        var result: [String: (manager: TerminalSessionManager, session: TerminalSession, title: String)] = [:]
        for context in ProjectContextRegistry.openContexts() {
            for session in context.terminals.everySession() {
                if let id = session.viewController.keeperID { result[id] = (context.terminals, session, session.title) }
            }
        }
        return result
    }

    // MARK: - Ending

    /// A session with an open tab ends as closing its tab would; one without is ended directly.
    private func end(_ record: SessionRecord) {
        if let open = Self.openSessionsByKeeper()[record.id] {
            open.manager.removeSession(open.session)
        } else {
            SessionKeepers.end(record)
        }
    }

    @objc private func endRow(_ sender: NSButton) {
        guard rows.indices.contains(sender.tag) else { return }
        let row = rows[sender.tag]
        confirm("End \u{201C}\(row.tab)\u{201D}?", detail: "\(row.running) in \(row.project) ends, as closing its tab would.") { [weak self] in
            self?.end(row.record)
            self?.refresh()
        }
    }

    @objc private func endAll() {
        let all = rows
        guard !all.isEmpty else { return }
        confirm("End all \(all.count) terminals?", detail: "Everything running in them ends, in every project.") { [weak self] in
            for row in all { self?.end(row.record) }
            self?.refresh()
        }
    }

    private func confirm(_ message: String, detail: String, then action: @escaping () -> Void) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: "End")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in if response == .alertFirstButtonReturn { action() } }
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        guard let column = tableColumn?.identifier.rawValue, rows.indices.contains(index) else { return nil }
        let row = rows[index]
        if column == "end" {
            let button = NSButton(title: "End", target: self, action: #selector(endRow(_:)))
            button.bezelStyle = .inline
            button.controlSize = .small
            button.tag = index
            button.setAccessibilityLabel("End \(row.tab)")
            return button
        }
        let text: String
        switch column {
        case "project": text = row.project
        case "tab": text = row.tab
        case "running": text = row.running
        case "idle": text = row.idle
        default: text = String(format: "%.0f MB", row.memoryMB)
        }
        let field = NSTextField(labelWithString: text)
        field.font = column == "running" ? DS.Text.code(11.5) : DS.Text.body()
        field.lineBreakMode = .byTruncatingTail
        field.toolTip = column == "tab" ? row.record.directory : nil
        return field
    }
}
