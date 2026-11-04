import AppKit
import SideAgents

/// The Usage pane of Preferences: what every model has cost across every project, with a
/// per-project breakdown underneath.
///
/// Reads `UsageStore.shared` and re-renders on its change signal, so a run finishing while this
/// window is open updates the figures without reopening it.
final class UsageViewController: NSViewController {
    private var usageObserverToken: UUID?
    private let budgetField = NSTextField()

    /// Which records the pane counts.
    enum Period: Int { case thisMonth, allTime }
    private(set) var period: Period = .thisMonth
    /// Groups the user expanded past the first few rows.
    private var expanded: Set<String> = []
    static let collapsedCount = 5

    override func loadView() { view = NSView() }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Restyles itself on a text-size change (`textScaleChanged`): not the follower's.
        TextScaleFollower.exempt(view)
        usageObserverToken = UsageStore.shared.addChangeObserver { [weak self] in self?.render() }
        NotificationCenter.default.addObserver(self, selector: #selector(textScaleChanged), name: DS.Text.scaleDidChangeNotification, object: nil)
        render()
    }

    deinit {
        if let usageObserverToken { UsageStore.shared.removeChangeObserver(usageObserverToken) }
    }

    @objc private func textScaleChanged() { render() }

    // MARK: - Figures

    struct Line: Equatable {
        var title: String
        var subtitle: String
        var totals: UsageTotals
        var cost: Double?
        /// What the prompt cache saved against the full price (nil: unpriced).
        var saving: Double? = nil
    }

    var records: [UsageRecord] {
        let all = UsageStore.shared.records
        guard period == .thisMonth else { return all }
        let current = UsageRecord.periodKey(for: Date())
        return all.filter { $0.periodKey == current }
    }

    /// Per model, most tokens first; an agent's models under the agent's own name.
    func modelLines() -> [Line] {
        var grouped: [String: (providerId: String, modelId: String, totals: UsageTotals)] = [:]
        for record in records {
            let key = record.providerId + "|" + record.modelId
            var entry = grouped[key] ?? (record.providerId, record.modelId, UsageTotals())
            entry.totals.add(record.totals)
            grouped[key] = entry
        }
        return grouped.values.map { entry in
            let names = UsageNames.names(providerId: entry.providerId, modelId: entry.modelId)
            return Line(title: names.model, subtitle: names.provider, totals: entry.totals,
                        cost: ModelPricing.estimatedCost(modelId: entry.modelId, totals: entry.totals),
                        saving: ModelPricing.cacheSaving(modelId: entry.modelId, totals: entry.totals))
        }.sorted { $0.totals.totalTokens > $1.totals.totalTokens }
    }

    func projectLines() -> [Line] {
        Dictionary(grouping: records, by: \.projectPath).map { path, records in
            var totals = UsageTotals()
            records.forEach { totals.add($0.totals) }
            // A project that used an unpriced model shows no figure rather than an undercount.
            let cost = records.allSatisfy { ModelPricing.isPriced(modelId: $0.modelId) }
                ? records.reduce(0.0) { $0 + (ModelPricing.estimatedCost(modelId: $1.modelId, totals: $1.totals) ?? 0) }
                : nil
            return Line(title: URL(fileURLWithPath: path).lastPathComponent, subtitle: (path as NSString).abbreviatingWithTildeInPath, totals: totals, cost: cost)
        }.sorted { $0.totals.totalTokens > $1.totals.totalTokens }
    }

    // MARK: - Rendering

    private func render() {
        let periodControl = NSSegmentedControl(labels: ["This Month", "All Time"], trackingMode: .selectOne, target: self, action: #selector(periodChanged(_:)))
        periodControl.selectedSegment = period.rawValue
        periodControl.setAccessibilityIdentifier("usage.period")

        var sections: [NSView] = [SettingsSplitViewController.hero(.usage)]
        let models = modelLines()
        if models.isEmpty {
            sections.append(SettingsForm.section([SettingsForm.row("Period", detail: period == .thisMonth ? "Nothing recorded this month." : "No agent runs recorded yet. Usage appears here after the first Think conversation.", periodControl)]))
        } else {
            var grand = UsageTotals()
            records.forEach { grand.add($0.totals) }
            let unpriced = models.contains { $0.cost == nil }
            let spend = models.compactMap(\.cost).reduce(0, +)
            sections.append(SettingsForm.section(footer: "Cost is an estimate from published list prices and won't match your bill exactly. A + means some models have no price here.", [
                SettingsForm.row("Period", periodControl),
                SettingsForm.content(summary(spend: UsageFormatting.cost(spend) + (unpriced ? "+" : ""), grand: grand,
                                             saved: models.compactMap(\.saving).reduce(0, +))),
            ]))
            sections.append(group("By model", key: "models", lines: models))
            let projects = projectLines()
            if !projects.isEmpty { sections.append(group("By project", key: "projects", lines: projects)) }
        }
        sections.append(SettingsForm.section("Budget", [budgetRow()]))
        sections.append(SettingsForm.section([
            SettingsForm.row("Reset usage history", detail: "Clears recorded token counts for every project. Conversations and your bill are unaffected.",
                             SettingsForm.button("Reset\u{2026}", self, #selector(resetUsage), destructive: true)),
        ]))
        SettingsForm.install(SettingsForm.page(sections), in: view)
    }

    private func summary(spend: String, grand: UsageTotals, saved: Double) -> NSView {
        var views = [
            figure(spend, "estimated spend"),
            figure(UsageFormatting.tokens(grand.totalTokens), "tokens"),
            figure("\(grand.requestCount)", grand.requestCount == 1 ? "request" : "requests"),
        ]
        // Only once there's something cached: a figure of $0.00 saved says nothing.
        if grand.cachedInputTokens > 0 { views.append(figure(UsageFormatting.cost(max(0, saved)), "saved by caching")) }
        let figures = NSStackView(views: views)
        figures.orientation = .horizontal
        figures.alignment = .top
        figures.distribution = .fillEqually
        figures.spacing = DS.Spacing.section
        return figures
    }

    private func figure(_ value: String, _ caption: String) -> NSView {
        let valueLabel = NSTextField(labelWithString: value)
        valueLabel.font = DS.Text.title(.semibold)
        let captionLabel = NSTextField(labelWithString: caption)
        captionLabel.font = DS.Text.caption()
        captionLabel.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [valueLabel, captionLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        return stack
    }

    /// The first few lines, a share bar each, and "Show all" when there are more.
    private func group(_ title: String, key: String, lines: [Line]) -> NSView {
        let isExpanded = expanded.contains(key)
        let shown = isExpanded ? lines : Array(lines.prefix(Self.collapsedCount))
        let most = max(1, lines.first?.totals.totalTokens ?? 1)
        var rows = shown.map { line(for: $0, share: Double($0.totals.totalTokens) / Double(most)) }
        if lines.count > Self.collapsedCount {
            let toggle = NSButton(title: isExpanded ? "Show Fewer" : "Show All \(lines.count)", target: self, action: #selector(toggleGroup(_:)))
            toggle.bezelStyle = .inline
            toggle.identifier = NSUserInterfaceItemIdentifier(key)
            rows.append(SettingsForm.row(isExpanded ? "" : "\(lines.count - Self.collapsedCount) more", toggle, titleColor: .secondaryLabelColor))
        }
        return SettingsForm.section(title, rows)
    }

    private func line(for line: Line, share: Double) -> NSView {
        let tokens = NSTextField(labelWithString: UsageFormatting.tokens(line.totals.totalTokens))
        tokens.font = NSFont.monospacedDigitSystemFont(ofSize: DS.Text.body().pointSize, weight: .regular)
        tokens.alignment = .right
        tokens.toolTip = "\(UsageFormatting.tokens(line.totals.inputTokens)) input \u{00B7} \(UsageFormatting.tokens(line.totals.cachedInputTokens)) read from the cache \u{00B7} \(UsageFormatting.tokens(line.totals.cacheWriteInputTokens)) written to it \u{00B7} \(UsageFormatting.tokens(line.totals.outputTokens)) output \u{00B7} \(line.totals.requestCount) requests"
        let cost = NSTextField(labelWithString: line.cost.map { UsageFormatting.cost($0) } ?? "\u{2013}")
        cost.font = NSFont.monospacedDigitSystemFont(ofSize: DS.Text.body().pointSize, weight: .regular)
        cost.textColor = line.cost == nil ? .tertiaryLabelColor : .labelColor
        cost.alignment = .right
        tokens.widthAnchor.constraint(equalToConstant: 64).isActive = true
        cost.widthAnchor.constraint(equalToConstant: 56).isActive = true
        let bar = ShareBar(share: share)
        bar.widthAnchor.constraint(equalToConstant: 64).isActive = true
        bar.heightAnchor.constraint(equalToConstant: 4).isActive = true
        let figures = NSStackView(views: [bar, tokens, cost])
        figures.orientation = .horizontal
        figures.alignment = .centerY
        figures.spacing = DS.Spacing.l
        return SettingsForm.row(line.title, detail: line.subtitle, figures)
    }

    @objc private func periodChanged(_ sender: NSSegmentedControl) {
        period = Period(rawValue: sender.selectedSegment) ?? .thisMonth
        render()
    }

    @objc private func toggleGroup(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        if expanded.contains(key) { expanded.remove(key) } else { expanded.insert(key) }
        render()
    }

    private func budgetRow() -> NSView {
        budgetField.placeholderString = "No limit"
        budgetField.alignment = .right
        budgetField.target = self
        budgetField.action = #selector(budgetChanged)
        budgetField.translatesAutoresizingMaskIntoConstraints = false
        budgetField.widthAnchor.constraint(equalToConstant: 80).isActive = true
        budgetField.stringValue = UsageBudget.monthlyLimitUSD.map { String(format: "%.2f", $0) } ?? ""
        let dollar = NSTextField(labelWithString: "$")
        let field = NSStackView(views: [dollar, budgetField])
        field.spacing = 4
        let row = SettingsForm.row("Monthly limit", detail: budgetStatusText(), field)
        if let detail = (row.subviews.first as? NSStackView)?.arrangedSubviews.first as? NSStackView,
           let status = detail.arrangedSubviews.last as? NSTextField {
            status.textColor = budgetStatusColor()
        }
        return row
    }

    private func budgetStatusText() -> String {
        let month = UsageStore.shared.estimatedCostThisMonth()
        let spent = UsageFormatting.cost(month.total)
        // Said plainly (2026-09-30 audit, H11): outside agents report tokens, not a price, so the
        // budget stops them at the limit but doesn't count them; a model with no price is refused.
        let caveat = (month.hasUnpricedModels
            ? " Models with no published price here aren't counted, so the real figure is higher."
            : "") + " With a limit set, a model with no price isn't sent to, and outside agents stop at the limit, though their own spend isn't in the estimate."
        switch UsageBudget.status() {
        case .unlimited:
            return "No budget set, so nothing is blocked. \(spent) estimated so far this month.\(caveat)"
        case .withinBudget(_, let limit):
            return "\(spent) of \(UsageFormatting.cost(limit)) estimated this month.\(caveat)"
        case .approaching(_, let limit):
            return "\(spent) of \(UsageFormatting.cost(limit)) estimated this month, close to the limit.\(caveat)"
        case .exceeded(_, let limit):
            return "\(spent) of \(UsageFormatting.cost(limit)). The budget is reached, so Agent won't send until you raise or clear it.\(caveat)"
        }
    }

    private func budgetStatusColor() -> NSColor {
        switch UsageBudget.status() {
        case .unlimited, .withinBudget: return .secondaryLabelColor
        case .approaching: return .systemOrange
        case .exceeded: return .systemRed
        }
    }

    @objc private func budgetChanged() {
        let text = budgetField.stringValue.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
        // Blank, zero, or unparseable all mean "no budget" — a zero-dollar limit that blocks
        // everything is never what someone typing in this field meant.
        UsageBudget.monthlyLimitUSD = Double(text).flatMap { $0 > 0 ? $0 : nil }
        render()
    }

    @objc private func resetUsage() {
        let alert = NSAlert()
        alert.messageText = "Reset usage history?"
        alert.informativeText = "This clears the recorded token counts for every project. It doesn't affect your conversations or anything you've been billed."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        UsageStore.shared.removeAll()
    }
}

/// How much of the group's largest line this one is.
private final class ShareBar: NSView {
    private let share: Double
    init(share: Double) {
        self.share = max(0.02, min(1, share))
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func draw(_ dirtyRect: NSRect) {
        let track = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        DS.Color.scrimMedium.setFill()
        track.fill()
        var filled = bounds
        filled.size.width = bounds.width * share
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: filled, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }
}

/// Names people recognize for a usage line: "Claude Code" rather than "acp:claude-code", and
/// the agent's own name for its model when Side has seen it.
enum UsageNames {
    static func names(providerId: String, modelId: String) -> (model: String, provider: String) {
        if providerId.hasPrefix("acp:") {
            let agentId = String(providerId.dropFirst(4))
            let agent = ACPAgent.agent(id: agentId)?.displayName ?? agentId
            return (agentModelName(agentId: agentId, value: modelId) ?? modelId, agent)
        }
        // Anything else is Heron's, retired: its usage stays, under its provider's id.
        return (modelId, providerId == "anthropic" ? "Anthropic (Heron)" : "\(providerId) (Heron)")
    }

    private static func agentModelName(agentId: String, value: String) -> String? {
        guard let data = HeronDefaults.store.data(forKey: "SideACPKnownOptions.\(agentId)"),
              let options = try? JSONDecoder().decode([HarnessOption].self, from: data) else { return nil }
        return options.first { $0.category == .model }?.choices.first { $0.value == value }?.name
    }
}
