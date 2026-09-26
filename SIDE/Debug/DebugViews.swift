import AppKit
import Heron

// MARK: - The debug bar

/// The controls over the editor while a session runs (SIDE_RFC_DEBUGGER.md, Q1): continue or
/// pause, step over, into and out, restart and stop, and what the session is doing. Glass, like
/// the tab strip.
@MainActor
final class DebugBar: NSView {
    enum Action { case pauseContinue, stepOver, stepIn, stepOut, restart, stop }
    var onAction: ((Action) -> Void)?

    static let height: CGFloat = 30
    private let glass = DS.makeGlass(cornerRadius: DebugBar.height / 2)
    private let pauseContinue = DebugBar.button("pause.fill", "Pause")
    private let stepOver = DebugBar.button("arrow.turn.down.right", "Step Over")
    private let stepIn = DebugBar.button("arrow.down.to.line", "Step Into")
    private let stepOut = DebugBar.button("arrow.up.to.line", "Step Out")
    private let restart = DebugBar.button("arrow.clockwise", "Restart")
    private let stop = DebugBar.button("stop.fill", "Stop Debugging")
    let statusLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        let buttons: [(NSButton, Action)] = [(pauseContinue, .pauseContinue), (stepOver, .stepOver), (stepIn, .stepIn), (stepOut, .stepOut), (restart, .restart), (stop, .stop)]
        for (button, action) in buttons {
            button.target = self
            button.action = #selector(pressed(_:))
            button.tag = buttons.firstIndex { $0.1 == action }!
        }
        statusLabel.font = DS.Text.caption(.medium)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        let divider = NSBox()
        divider.boxType = .separator
        let stack = NSStackView(views: [pauseContinue, stepOver, stepIn, stepOut, divider, restart, stop, statusLabel])
        stack.orientation = .horizontal
        stack.spacing = DS.Spacing.xs
        stack.setCustomSpacing(DS.Spacing.m, after: stop)
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor), glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor), glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(equalToConstant: Self.height),
            divider.heightAnchor.constraint(equalToConstant: 16),
            statusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 240),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("Debug")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func button(_ symbol: String, _ label: String) -> NSButton {
        let button = NSButton(image: symbolImage(symbol, label), target: nil, action: nil)
        button.isBordered = false
        button.contentTintColor = .labelColor
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        return button
    }

    private static func symbolImage(_ symbol: String, _ label: String) -> NSImage {
        NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)) ?? NSImage()
    }

    @objc private func pressed(_ sender: NSButton) {
        let actions: [Action] = [.pauseContinue, .stepOver, .stepIn, .stepOut, .restart, .stop]
        onAction?(actions[sender.tag])
    }

    /// Shows what the session is doing: which controls apply, and a line of status.
    func show(_ state: DebugSession.State, name: String) {
        let stopped: Bool
        switch state {
        case .building: statusLabel.stringValue = "Building \(name)\u{2026}"; stopped = false
        case .starting: statusLabel.stringValue = "Starting \(name)\u{2026}"; stopped = false
        case .running: statusLabel.stringValue = "Running \(name)"; stopped = false
        case .stopped(let reason, _, let text):
            // An exception's text says what was thrown; a breakpoint's ("breakpoint 1.1") is noise.
            statusLabel.stringValue = reason == "exception" ? "Paused: " + (text.flatMap { $0.isEmpty ? nil : $0 } ?? "exception") : DebugBar.describe(reason)
            stopped = true
        case .ended(let message):
            // The whole message is in the console; the bar says it in a few words.
            statusLabel.stringValue = message.map { _ in "Couldn\u{2019}t run \(name): see the console" } ?? "Ended"
            statusLabel.toolTip = message
            stopped = false
        }
        let label = stopped ? "Continue" : "Pause"
        pauseContinue.image = Self.symbolImage(stopped ? "play.fill" : "pause.fill", label)
        pauseContinue.toolTip = label
        pauseContinue.setAccessibilityLabel(label)
        let running: Bool = { if case .running = state { return true } else { return false } }()
        pauseContinue.isEnabled = stopped || running
        [stepOver, stepIn, stepOut].forEach { $0.isEnabled = stopped }
    }

    static func describe(_ reason: String) -> String {
        switch reason {
        case "breakpoint", "function breakpoint", "data breakpoint", "instruction breakpoint": return "Paused at a breakpoint"
        case "step": return "Paused after a step"
        case "entry": return "Paused at entry"
        case "exception": return "Paused on an exception"
        default: return "Paused"
        }
    }
}

// MARK: - The inspector

/// A variable in the inspector: its value, and its children once it's opened (D5: one level at
/// a time, and big arrays a page at a time).
@MainActor
final class DebugVariableNode {
    enum Kind { case scope(DAPScope), variable(DAPVariable), more(reference: Int, start: Int, remaining: Int) }
    let kind: Kind
    var children: [DebugVariableNode]?
    init(_ kind: Kind) { self.kind = kind }

    var reference: Int {
        switch kind {
        case .scope(let scope): return scope.variablesReference
        case .variable(let variable): return variable.variablesReference
        case .more: return 0
        }
    }
}

/// A watch expression and what it came to at the last stop.
struct DebugWatch: Equatable {
    var expression: String
    /// nil while running (or before the first stop).
    var value: String?
    var failed = false
}

/// While debugging, the call stack, the stopped frame's variables, watches, the breakpoints
/// (exception breakpoints first) and the console (SIDE_RFC_DEBUGGER.md), in the file explorer's
/// place.
@MainActor
final class DebugInspector: NSView, NSTableViewDataSource, NSTableViewDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate {
    static let width: CGFloat = 300
    /// A page of an array's elements.
    static let pageSize = 200

    var onSelectFrame: ((Int) -> Void)?
    var onRevealBreakpoint: ((String, Int) -> Void)?
    var onToggleBreakpoint: ((String, Int, Bool) -> Void)?
    var onRemoveBreakpoint: ((String, Int) -> Void)?
    /// Edit Breakpoint… (condition, hit count, log message), anchored on the row.
    var onEditBreakpoint: ((String, Int, NSView) -> Void)?
    var onExceptionFilter: ((String, Bool) -> Void)?
    var onAddWatch: ((String) -> Void)?
    var onRemoveWatch: ((Int) -> Void)?
    /// An expression typed into the console.
    var onEvaluate: ((String) -> Void)?
    /// Children of a variables reference (a page of indexed ones when start and count are given).
    var fetchVariables: ((Int, Int?, Int?) async -> [DAPVariable])?

    private(set) var frames: [DAPStackFrame] = []
    private var selectedFrame = 0
    private var breakpoints: [(path: String, breakpoint: Breakpoint)] = []
    private var exceptionFilters: [(filter: DAPExceptionFilter, enabled: Bool)] = []
    private(set) var watches: [DebugWatch] = []
    private var scopes: [DebugVariableNode] = []
    /// Bumped on each stop: an answer for an older stop is dropped.
    private var generation = 0

    let stackTable = NSTableView()
    let variablesOutline = NSOutlineView()
    let breakpointsTable = NSTableView()
    let watchesTable = NSTableView()
    let outputView = NSTextView()
    let consoleField = NSTextField()
    let watchField = NSTextField()
    /// The console's history, ↑ and ↓ through it.
    private var consoleHistory: [String] = []
    private var historyIndex: Int?
    private let variablesPlaceholder = NSTextField(labelWithString: "Not paused")

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        for (table, id) in [(stackTable, "stack"), (breakpointsTable, "breakpoints"), (watchesTable, "watches")] {
            Self.style(table, id)
            table.dataSource = self
            table.delegate = self
        }
        stackTable.target = self
        stackTable.action = #selector(stackClicked)
        breakpointsTable.target = self
        breakpointsTable.doubleAction = #selector(breakpointDoubleClicked)
        let menu = NSMenu()
        menu.addItem(withTitle: "Edit Breakpoint\u{2026}", action: #selector(editClickedBreakpoint), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Delete Breakpoint", action: #selector(deleteClickedBreakpoint), keyEquivalent: "").target = self
        breakpointsTable.menu = menu
        let watchMenu = NSMenu()
        watchMenu.addItem(withTitle: "Remove Watch", action: #selector(removeClickedWatch), keyEquivalent: "").target = self
        watchesTable.menu = watchMenu
        for (field, placeholder) in [(watchField, "Add a watch expression"), (consoleField, "Evaluate in the paused frame")] {
            field.placeholderString = placeholder
            field.font = DS.Text.code(11)
            field.isBordered = false
            field.drawsBackground = false
            field.focusRingType = .none
            field.delegate = self
            field.translatesAutoresizingMaskIntoConstraints = false
        }
        consoleField.setAccessibilityLabel("Debug console")
        watchField.setAccessibilityLabel("Add a watch expression")

        Self.style(variablesOutline, "variables")
        variablesOutline.outlineTableColumn = variablesOutline.tableColumns.first
        variablesOutline.indentationPerLevel = 12
        variablesOutline.dataSource = self
        variablesOutline.delegate = self
        variablesOutline.target = self
        variablesOutline.doubleAction = #selector(variableDoubleClicked)

        outputView.isEditable = false
        outputView.isRichText = false
        outputView.drawsBackground = false
        outputView.font = DS.Text.code(11)
        outputView.textContainerInset = NSSize(width: 6, height: 6)
        let outputScroll = NSScrollView()
        outputScroll.documentView = outputView
        outputScroll.hasVerticalScroller = true
        outputScroll.drawsBackground = false
        outputView.autoresizingMask = [.width]
        outputView.isVerticallyResizable = true

        variablesPlaceholder.font = DS.Text.caption()
        variablesPlaceholder.textColor = .tertiaryLabelColor
        variablesPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        let variablesScroll = Self.scroll(variablesOutline)
        variablesScroll.addSubview(variablesPlaceholder)
        NSLayoutConstraint.activate([
            variablesPlaceholder.centerXAnchor.constraint(equalTo: variablesScroll.centerXAnchor),
            variablesPlaceholder.topAnchor.constraint(equalTo: variablesScroll.topAnchor, constant: 12),
        ])

        let split = NSSplitView()
        split.isVertical = false
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        let watchesView = Self.stack(Self.scroll(watchesTable), watchField)
        let consoleView = Self.stack(outputScroll, consoleField)
        // Each keeps room for a row or two, however small the window.
        for (title, content, least) in [("Call Stack", Self.scroll(stackTable), 56.0), ("Variables", variablesScroll, 84.0), ("Watches", watchesView, 78.0),
                                        ("Breakpoints", Self.scroll(breakpointsTable), 70.0), ("Console", consoleView, 84.0)] {
            let section = Self.section(title, content)
            section.heightAnchor.constraint(greaterThanOrEqualToConstant: least).isActive = true
            split.addArrangedSubview(section)
        }

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.state = .active
        effect.blendingMode = .withinWindow
        // The explorer's shape, since it stands in the explorer's place.
        effect.maskImage = DS.roundedMask(radius: 16)
        effect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effect)
        effect.addSubview(split)
        NSLayoutConstraint.activate([
            effect.topAnchor.constraint(equalTo: topAnchor), effect.bottomAnchor.constraint(equalTo: bottomAnchor),
            effect.leadingAnchor.constraint(equalTo: leadingAnchor), effect.trailingAnchor.constraint(equalTo: trailingAnchor),
            split.topAnchor.constraint(equalTo: effect.topAnchor, constant: 8), split.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -8),
            split.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 6), split.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -6),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Debug")
        layoutSubtreeIfNeeded()
        // Stack and breakpoints small, variables the most, output a strip.
        DispatchQueue.main.async {
            let height = split.bounds.height
            guard height > 200 else { return }
            split.setPosition(height * 0.17, ofDividerAt: 0)
            split.setPosition(height * 0.45, ofDividerAt: 1)
            split.setPosition(height * 0.58, ofDividerAt: 2)
            split.setPosition(height * 0.8, ofDividerAt: 3)
        }
    }

    private static func style(_ table: NSTableView, _ id: String) {
        table.headerView = nil
        table.style = .sourceList
        table.backgroundColor = .clear
        table.rowHeight = 20
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.allowsEmptySelection = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
    }

    private static func scroll(_ view: NSView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.documentView = view
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        return scroll
    }

    /// A list with a field under it (watches, the console).
    private static func stack(_ top: NSView, _ field: NSTextField) -> NSView {
        let view = NSView()
        top.translatesAutoresizingMaskIntoConstraints = false
        let rule = NSBox()
        rule.boxType = .separator
        rule.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(top)
        view.addSubview(rule)
        view.addSubview(field)
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: view.topAnchor), top.leadingAnchor.constraint(equalTo: view.leadingAnchor), top.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            rule.topAnchor.constraint(equalTo: top.bottomAnchor), rule.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8), rule.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            field.topAnchor.constraint(equalTo: rule.bottomAnchor, constant: 4), field.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8), field.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -4),
        ])
        return view
    }

    private static func section(_ title: String, _ content: NSView) -> NSView {
        let label = NSTextField(labelWithString: title.uppercased())
        label.font = DS.Text.caption(.semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        let view = NSView()
        view.addSubview(label)
        view.addSubview(content)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: view.topAnchor, constant: 6), label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            content.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 2), content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor), content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        return view
    }

    // MARK: What it shows

    func show(frames: [DAPStackFrame], selected: Int) {
        self.frames = frames
        selectedFrame = selected
        stackTable.reloadData()
        if frames.indices.contains(selected) {
            stackTable.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
            stackTable.scrollRowToVisible(selected)
        }
    }

    /// A frame's scopes: the first (Locals) opened at once, the rest (Globals, Registers) left
    /// closed.
    func show(scopes list: [DAPScope]) {
        generation += 1
        scopes = list.map { DebugVariableNode(.scope($0)) }
        variablesPlaceholder.stringValue = "No variables"
        variablesPlaceholder.isHidden = !list.isEmpty
        variablesOutline.reloadData()
        if let first = scopes.first, list.first?.expensive == false { variablesOutline.expandItem(first) }
    }

    func clearVariables(placeholder: String) {
        generation += 1
        scopes = []
        variablesOutline.reloadData()
        variablesPlaceholder.stringValue = placeholder
        variablesPlaceholder.isHidden = false
    }

    func show(breakpoints list: [(path: String, breakpoint: Breakpoint)]) {
        breakpoints = list
        breakpointsTable.reloadData()
    }

    /// The adapter's exception breakpoints (none before a session has said).
    func show(exceptionFilters list: [(filter: DAPExceptionFilter, enabled: Bool)]) {
        exceptionFilters = list
        breakpointsTable.reloadData()
    }

    func show(watches list: [DebugWatch]) {
        watches = list
        watchesTable.reloadData()
    }

    /// The console's text: replaced (nil appends nothing) or added to.
    func show(output: String) {
        outputView.string = output
        outputView.scrollToEndOfDocument(nil)
    }

    func append(output: String, style: ConsoleStyle = .program) {
        guard let storage = outputView.textStorage else { return }
        let atBottom = outputView.enclosingScrollView.map { $0.documentVisibleRect.maxY >= outputView.bounds.maxY - 4 } ?? true
        let color: NSColor
        switch style {
        case .program: color = .labelColor
        case .adapter: color = .secondaryLabelColor
        case .input: color = .controlAccentColor
        case .error: color = .systemRed
        }
        storage.append(NSAttributedString(string: output, attributes: [.font: DS.Text.code(11), .foregroundColor: color]))
        // Bounded, as the session's own copy is.
        if storage.length > 400_000 { storage.deleteCharacters(in: NSRange(location: 0, length: storage.length - 300_000)) }
        if atBottom { outputView.scrollToEndOfDocument(nil) }
    }

    enum ConsoleStyle { case program, adapter, input, error }

    // MARK: Tables

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === stackTable { return frames.count }
        if tableView === watchesTable { return watches.count }
        return exceptionFilters.count + breakpoints.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === stackTable {
            let frame = frames[row]
            let place = frame.path.map { "\(($0 as NSString).lastPathComponent):\(frame.line)" } ?? ""
            return Self.cell(tableView, "frame", frame.name, place, dim: frame.path == nil || frame.isSubtle)
        }
        if tableView === watchesTable {
            let watch = watches[row]
            let cell = Self.cell(tableView, "variable", watch.expression, watch.value ?? "\u{2014}", dim: false)
            (cell as? DebugCell)?.detail.textColor = watch.failed ? .systemRed : .secondaryLabelColor
            cell.toolTip = watch.value
            return cell
        }
        if row < exceptionFilters.count {
            let entry = exceptionFilters[row]
            let identifier = NSUserInterfaceItemIdentifier("exception")
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? DebugCheckCell ?? DebugCheckCell(identifier: identifier)
            cell.check.title = entry.filter.label
            cell.check.state = entry.enabled ? .on : .off
            cell.onToggle = { [weak self] on in self?.onExceptionFilter?(entry.filter.id, on) }
            return cell
        }
        let entry = breakpoints[row - exceptionFilters.count]
        let identifier = NSUserInterfaceItemIdentifier("breakpoint")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? DebugCheckCell ?? DebugCheckCell(identifier: identifier)
        cell.check.title = "\((entry.path as NSString).lastPathComponent):\(entry.breakpoint.line + 1)"
        cell.check.state = entry.breakpoint.enabled ? .on : .off
        cell.detail.stringValue = Self.describe(entry.breakpoint)
        cell.toolTip = [entry.path, entry.breakpoint.message].compactMap { $0 }.joined(separator: "\n")
        cell.onToggle = { [weak self] on in self?.onToggleBreakpoint?(entry.path, entry.breakpoint.line, on) }
        return cell
    }

    private static func cell(_ table: NSTableView, _ id: String, _ title: String, _ detail: String, dim: Bool) -> NSTableCellView {
        let identifier = NSUserInterfaceItemIdentifier(id)
        let cell = table.makeView(withIdentifier: identifier, owner: nil) as? DebugCell ?? DebugCell(identifier: identifier)
        cell.title.stringValue = title
        cell.detail.stringValue = detail
        cell.title.textColor = dim ? .tertiaryLabelColor : .labelColor
        return cell
    }

    @objc private func stackClicked() {
        let row = stackTable.clickedRow
        guard frames.indices.contains(row), row != selectedFrame else { return }
        selectedFrame = row
        onSelectFrame?(row)
    }

    /// What a breakpoint does besides stop: "if x > 3", "hits ≥ 5", "log: …".
    static func describe(_ breakpoint: Breakpoint) -> String {
        var parts: [String] = []
        if let logMessage = breakpoint.logMessage { parts.append("log: " + logMessage) }
        if let condition = breakpoint.condition { parts.append("if " + condition) }
        if let hitCondition = breakpoint.hitCondition { parts.append("hits " + hitCondition) }
        if parts.isEmpty, breakpoint.verified == false { parts.append("not placed") }
        return parts.joined(separator: ", ")
    }

    /// The file breakpoint on a row of the breakpoints table (not an exception row).
    private func breakpoint(atRow row: Int) -> (path: String, breakpoint: Breakpoint)? {
        let index = row - exceptionFilters.count
        return breakpoints.indices.contains(index) ? breakpoints[index] : nil
    }

    @objc private func breakpointDoubleClicked() {
        guard let entry = breakpoint(atRow: breakpointsTable.clickedRow) else { return }
        onRevealBreakpoint?(entry.path, entry.breakpoint.line)
    }

    @objc private func deleteClickedBreakpoint() {
        guard let entry = breakpoint(atRow: breakpointsTable.clickedRow) else { return }
        onRemoveBreakpoint?(entry.path, entry.breakpoint.line)
    }

    @objc private func editClickedBreakpoint() {
        let row = breakpointsTable.clickedRow
        guard let entry = breakpoint(atRow: row), let view = breakpointsTable.view(atColumn: 0, row: row, makeIfNecessary: false) else { return }
        onEditBreakpoint?(entry.path, entry.breakpoint.line, view)
    }

    @objc private func removeClickedWatch() {
        let row = watchesTable.clickedRow
        guard watches.indices.contains(row) else { return }
        onRemoveWatch?(row)
    }

    // MARK: Fields

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard let field = control as? NSTextField else { return false }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return true }
            field.stringValue = ""
            if field === consoleField {
                if consoleHistory.last != text { consoleHistory.append(text) }
                historyIndex = nil
                onEvaluate?(text)
            } else {
                onAddWatch?(text)
            }
            return true
        case #selector(NSResponder.moveUp(_:)) where field === consoleField && !consoleHistory.isEmpty:
            let index = max(0, (historyIndex ?? consoleHistory.count) - 1)
            historyIndex = index
            field.stringValue = consoleHistory[index]
            return true
        case #selector(NSResponder.moveDown(_:)) where field === consoleField:
            guard let index = historyIndex else { return true }
            historyIndex = index + 1 < consoleHistory.count ? index + 1 : nil
            field.stringValue = historyIndex.map { consoleHistory[$0] } ?? ""
            return true
        default:
            return false
        }
    }

    // MARK: Variables

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? DebugVariableNode else { return scopes.count }
        return node.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? DebugVariableNode else { return scopes[index] }
        return node.children![index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? DebugVariableNode)?.reference ?? 0 > 0
    }

    func outlineViewItemWillExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? DebugVariableNode, node.children == nil else { return }
        node.children = []
        load(node, start: 0)
    }

    /// A node's children, or the next page of an array's.
    private func load(_ node: DebugVariableNode, start: Int) {
        let reference = node.reference
        guard reference > 0, let fetchVariables else { return }
        let generation = self.generation
        var indexed: Int?
        if case .variable(let variable) = node.kind, let count = variable.indexedCount, count > Self.pageSize { indexed = count }
        Task {
            let page = indexed.map { min(Self.pageSize, $0 - start) }
            let list = await fetchVariables(reference, indexed == nil ? nil : start, page)
            guard generation == self.generation else { return }
            var children = (node.children ?? []).filter { if case .more = $0.kind { return false } else { return true } }
            children += list.map { DebugVariableNode(.variable($0)) }
            if let indexed, start + list.count < indexed, !list.isEmpty {
                children.append(DebugVariableNode(.more(reference: reference, start: start + list.count, remaining: indexed - start - list.count)))
            }
            node.children = children
            self.variablesOutline.reloadItem(node, reloadChildren: true)
        }
    }

    @objc private func variableDoubleClicked() {
        let row = variablesOutline.clickedRow
        guard row >= 0, let node = variablesOutline.item(atRow: row) as? DebugVariableNode, case .more(_, let start, _) = node.kind,
              let parent = variablesOutline.parent(forItem: node) as? DebugVariableNode else { return }
        load(parent, start: start)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? DebugVariableNode else { return nil }
        switch node.kind {
        case .scope(let scope):
            return Self.cell(outlineView, "scope", scope.name, "", dim: false)
        case .variable(let variable):
            let cell = Self.cell(outlineView, "variable", variable.name, variable.value, dim: false)
            cell.toolTip = [variable.type, variable.value].compactMap { $0 }.joined(separator: "\n")
            return cell
        case .more(_, _, let remaining):
            return Self.cell(outlineView, "more", "\(remaining) more\u{2026}", "double-click", dim: true)
        }
    }
}

/// A row with a checkbox: an exception breakpoint, or a file breakpoint with what it does.
private final class DebugCheckCell: NSTableCellView {
    let check = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let detail = NSTextField(labelWithString: "")
    var onToggle: ((Bool) -> Void)?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        check.font = DS.Text.caption()
        check.target = self
        check.action = #selector(toggled)
        check.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        detail.font = DS.Text.caption()
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [check, detail])
        stack.orientation = .horizontal
        stack.spacing = DS.Spacing.s
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func toggled() { onToggle?(check.state == .on) }
}

/// Edit Breakpoint: the condition, the hits it stops on, and a log message (a logpoint).
@MainActor
final class BreakpointEditor: NSViewController, NSTextFieldDelegate {
    let condition = NSTextField()
    let hitCondition = NSTextField()
    let logMessage = NSTextField()
    var onDone: ((String, String, String) -> Void)?

    init(_ breakpoint: Breakpoint) {
        super.init(nibName: nil, bundle: nil)
        condition.stringValue = breakpoint.condition ?? ""
        hitCondition.stringValue = breakpoint.hitCondition ?? ""
        logMessage.stringValue = breakpoint.logMessage ?? ""
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let rows: [(String, NSTextField, String)] = [
            ("Condition", condition, "dx > 3"),
            ("Hit count", hitCondition, "5, >= 10, % 2"),
            ("Log message", logMessage, "x is {x}: logs instead of stopping"),
        ]
        let grid = NSGridView(views: rows.map { title, field, placeholder in
            field.placeholderString = placeholder
            field.font = DS.Text.code(11)
            field.delegate = self
            field.setAccessibilityLabel(title)
            field.widthAnchor.constraint(equalToConstant: 240).isActive = true
            let label = NSTextField(labelWithString: title)
            label.font = DS.Text.caption()
            label.textColor = .secondaryLabelColor
            return [label, field]
        })
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = DS.Spacing.m
        grid.columnSpacing = DS.Spacing.m
        let done = NSButton(title: "Done", target: self, action: #selector(finish))
        done.keyEquivalent = "\r"
        done.bezelStyle = .rounded
        let stack = NSStackView(views: [grid, done])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = DS.Spacing.l
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 12, right: 14)
        view = stack
    }

    /// Return in any field is Done; Escape closes without saving.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): finish(); return true
        case #selector(NSResponder.cancelOperation(_:)): close(); return true
        default: return false
        }
    }

    @objc private func finish() {
        onDone?(condition.stringValue, hitCondition.stringValue, logMessage.stringValue)
        close()
    }

    private func close() {
        onDone = nil
        popover?.performClose(nil)
    }
    weak var popover: NSPopover?
}

/// A row: a name, and a detail after it (a frame's file and line, a variable's value).
final class DebugCell: NSTableCellView {
    let title = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        let isValue = identifier.rawValue == "variable"
        title.font = isValue ? DS.Text.code(11, weight: .medium) : DS.Text.caption()
        detail.font = isValue ? DS.Text.code(11) : DS.Text.caption()
        detail.textColor = .secondaryLabelColor
        title.lineBreakMode = .byTruncatingTail
        detail.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [title, detail])
        stack.orientation = .horizontal
        stack.spacing = DS.Spacing.s
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        textField = title
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
