import AppKit

/// The Usage pane of Preferences: what every model has cost across every project, with a
/// per-project breakdown underneath.
///
/// Reads `UsageStore.shared` and re-renders on its change signal, so a run finishing while this
/// window is open updates the figures without reopening it.
final class UsageViewController: NSViewController {
    private let scrollView = NSScrollView()
    private let contentStack = NSStackView()
    private var usageObserverToken: UUID?
    private let budgetField = NSTextField()

    private static let columnWidths: (name: CGFloat, requests: CGFloat, tokens: CGFloat, cost: CGFloat) = (200, 70, 90, 80)

    override func loadView() { view = NSView() }

    override func viewDidLoad() {
        super.viewDidLoad()

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = DS.Spacing.l
        contentStack.edgeInsets = NSEdgeInsets(top: DS.Spacing.section, left: DS.Spacing.section, bottom: DS.Spacing.section, right: DS.Spacing.section)
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        let documentView = FlippedView()
        documentView.addSubview(contentStack)
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            contentStack.topAnchor.constraint(equalTo: documentView.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
            view.widthAnchor.constraint(greaterThanOrEqualToConstant: 520),
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: 560),
        ])

        usageObserverToken = UsageStore.shared.addChangeObserver { [weak self] in self?.render() }
        NotificationCenter.default.addObserver(
            self, selector: #selector(textScaleChanged),
            name: DS.Text.scaleDidChangeNotification, object: nil
        )
        render()
    }

    deinit {
        if let usageObserverToken { UsageStore.shared.removeChangeObserver(usageObserverToken) }
    }

    @objc private func textScaleChanged() { render() }

    // MARK: - Rendering

    private func render() {
        for subview in contentStack.arrangedSubviews {
            contentStack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }

        let store = UsageStore.shared
        let grand = store.grandTotal()
        guard grand.totalTokens > 0 else {
            let empty = NSTextField(wrappingLabelWithString: "No agent runs recorded yet. Token usage appears here after the first Think conversation.")
            empty.font = DS.Text.body()
            empty.textColor = .tertiaryLabelColor
            contentStack.addArrangedSubview(empty)
            // A budget is worth setting *before* spending anything, so this section shows up on
            // a fresh install rather than only once there's history to look at.
            contentStack.setCustomSpacing(DS.Spacing.section, after: empty)
            contentStack.addArrangedSubview(makeSectionTitle("Monthly budget"))
            contentStack.addArrangedSubview(makeBudgetControls())
            return
        }

        contentStack.addArrangedSubview(makeSummaryCard(grand: grand, estimate: store.estimatedCost()))
        contentStack.setCustomSpacing(DS.Spacing.section, after: contentStack.arrangedSubviews[0])

        contentStack.addArrangedSubview(makeSectionTitle("By model"))
        contentStack.addArrangedSubview(makeHeaderRow(first: "Model"))
        for entry in store.totalsByModel() {
            let providerName = ProviderRegistryStore.shared.provider(for: entry.providerId)?.displayName ?? entry.providerId
            let modelName = ProviderRegistryStore.shared
                .provider(for: entry.providerId)?
                .models.first { $0.id == entry.modelId }?.displayName ?? entry.modelId
            contentStack.addArrangedSubview(makeRow(
                title: modelName,
                subtitle: providerName,
                totals: entry.totals,
                cost: ModelPricing.estimatedCost(modelId: entry.modelId, totals: entry.totals)
            ))
        }

        let byProject = store.totalsByProject()
        if !byProject.isEmpty {
            contentStack.setCustomSpacing(DS.Spacing.section, after: contentStack.arrangedSubviews[contentStack.arrangedSubviews.count - 1])
            contentStack.addArrangedSubview(makeSectionTitle("By project"))
            contentStack.addArrangedSubview(makeHeaderRow(first: "Project"))
            for entry in byProject {
                // A project's cost is the sum of its own per-model rows, so a project that used
                // an unpriced model shows tokens and no figure rather than an undercount.
                let records = store.records.filter { $0.projectPath == entry.projectPath }
                let cost = records.allSatisfy { ModelPricing.isPriced(modelId: $0.modelId) }
                    ? records.reduce(0.0) { $0 + (ModelPricing.estimatedCost(modelId: $1.modelId, totals: $1.totals) ?? 0) }
                    : nil
                contentStack.addArrangedSubview(makeRow(
                    title: URL(fileURLWithPath: entry.projectPath).lastPathComponent,
                    subtitle: (entry.projectPath as NSString).abbreviatingWithTildeInPath,
                    totals: entry.totals,
                    cost: cost
                ))
            }
        }

        contentStack.setCustomSpacing(DS.Spacing.section, after: contentStack.arrangedSubviews[contentStack.arrangedSubviews.count - 1])
        contentStack.addArrangedSubview(makeSectionTitle("Monthly budget"))
        contentStack.addArrangedSubview(makeBudgetControls())

        let reset = NSButton(title: "Reset Usage History…", target: self, action: #selector(resetUsage))
        reset.bezelStyle = .rounded
        reset.controlSize = .small
        contentStack.setCustomSpacing(DS.Spacing.section, after: contentStack.arrangedSubviews[contentStack.arrangedSubviews.count - 1])
        contentStack.addArrangedSubview(reset)
    }

    private func makeSummaryCard(grand: UsageTotals, estimate: (total: Double, hasUnpricedModels: Bool)) -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.bindLayerBackground(DS.Color.overlay)
        card.layer?.cornerRadius = DS.Radius.surface
        card.translatesAutoresizingMaskIntoConstraints = false

        let costValue = estimate.hasUnpricedModels
            ? "\(UsageFormatting.cost(estimate.total))+"
            : UsageFormatting.cost(estimate.total)
        // The trailing "+" plus the footnote below already say the figure is a floor; spelling
        // that out in the caption wraps to three lines and throws the row of figures off.
        let costCaption = "estimated spend"

        let figures = NSStackView(views: [
            makeFigure(value: costValue, caption: costCaption),
            makeFigure(value: UsageFormatting.tokens(grand.totalTokens), caption: "tokens total"),
            makeFigure(value: UsageFormatting.tokens(grand.outputTokens), caption: "output tokens"),
            makeFigure(value: "\(grand.requestCount)", caption: grand.requestCount == 1 ? "request" : "requests"),
        ])
        figures.orientation = .horizontal
        figures.alignment = .top
        figures.distribution = .fillEqually
        figures.spacing = DS.Spacing.section
        figures.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(figures)

        let note = NSTextField(wrappingLabelWithString: "Cost is an estimate from published list prices and won't match your bill exactly. Models with no price here contribute tokens but no cost.")
        note.font = DS.Text.caption()
        note.textColor = .tertiaryLabelColor
        note.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(note)

        NSLayoutConstraint.activate([
            figures.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            figures.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            figures.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            note.topAnchor.constraint(equalTo: figures.bottomAnchor, constant: 12),
            note.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            note.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            note.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
            card.widthAnchor.constraint(greaterThanOrEqualToConstant: 460),
        ])
        return card
    }

    private func makeFigure(value: String, caption: String) -> NSView {
        let valueLabel = NSTextField(labelWithString: value)
        valueLabel.font = DS.Text.title(.semibold)
        valueLabel.textColor = .labelColor
        let captionLabel = NSTextField(wrappingLabelWithString: caption)
        captionLabel.font = DS.Text.caption()
        captionLabel.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [valueLabel, captionLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DS.Spacing.xxs
        return stack
    }

    private func makeSectionTitle(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = DS.Text.heading(.semibold)
        return label
    }

    private func makeHeaderRow(first: String) -> NSView {
        let row = makeColumnRow(
            first: makeColumnLabel(first, size: 10.5, weight: .medium, color: .tertiaryLabelColor, alignment: .left, width: Self.columnWidths.name),
            requests: makeColumnLabel("Requests", size: 10.5, weight: .medium, color: .tertiaryLabelColor, alignment: .right, width: Self.columnWidths.requests),
            tokens: makeColumnLabel("Tokens", size: 10.5, weight: .medium, color: .tertiaryLabelColor, alignment: .right, width: Self.columnWidths.tokens),
            cost: makeColumnLabel("Est. cost", size: 10.5, weight: .medium, color: .tertiaryLabelColor, alignment: .right, width: Self.columnWidths.cost)
        )
        return row
    }

    private func makeRow(title: String, subtitle: String, totals: UsageTotals, cost: Double?) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = DS.Text.body()
        titleLabel.lineBreakMode = .byTruncatingTail
        let subtitleLabel = NSTextField(labelWithString: subtitle)
        subtitleLabel.font = DS.Text.caption()
        subtitleLabel.textColor = .tertiaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingMiddle
        subtitleLabel.toolTip = subtitle

        let nameStack = NSStackView(views: [titleLabel, subtitleLabel])
        nameStack.orientation = .vertical
        nameStack.alignment = .leading
        nameStack.spacing = DS.Spacing.xxs
        nameStack.translatesAutoresizingMaskIntoConstraints = false
        nameStack.widthAnchor.constraint(equalToConstant: Self.columnWidths.name).isActive = true

        // The input/cached/output split matters for reading a bill, but only as detail — the
        // row shows one total and puts the breakdown in the tooltip.
        let tokensLabel = makeColumnLabel(
            UsageFormatting.tokens(totals.totalTokens), size: 12, weight: .regular,
            color: .labelColor, alignment: .right, width: Self.columnWidths.tokens
        )
        tokensLabel.toolTip = "\(UsageFormatting.tokens(totals.inputTokens)) input · \(UsageFormatting.tokens(totals.cachedInputTokens)) cached · \(UsageFormatting.tokens(totals.outputTokens)) output"

        return makeColumnRow(
            first: nameStack,
            requests: makeColumnLabel("\(totals.requestCount)", size: 12, weight: .regular, color: .secondaryLabelColor, alignment: .right, width: Self.columnWidths.requests),
            tokens: tokensLabel,
            cost: makeColumnLabel(
                cost.map { UsageFormatting.cost($0) } ?? "—", size: 12, weight: .regular,
                color: cost == nil ? .tertiaryLabelColor : .labelColor,
                alignment: .right, width: Self.columnWidths.cost
            )
        )
    }

    private func makeColumnRow(first: NSView, requests: NSView, tokens: NSView, cost: NSView) -> NSView {
        let row = NSStackView(views: [first, requests, tokens, cost])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = DS.Spacing.xl
        return row
    }

    private func makeColumnLabel(
        _ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor,
        alignment: NSTextAlignment, width: CGFloat
    ) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = DS.Text.custom(size, weight: weight)
        label.textColor = color
        label.alignment = alignment
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: width).isActive = true
        return label
    }


    /// The budget row: a dollar field, this month's standing against it, and a plain statement
    /// of what it does and doesn't guarantee.
    private func makeBudgetControls() -> NSView {
        let label = NSTextField(labelWithString: "Stop sending above:")
        label.font = DS.Text.body()

        budgetField.placeholderString = "No limit"
        budgetField.font = DS.Text.body()
        budgetField.alignment = .right
        budgetField.target = self
        budgetField.action = #selector(budgetChanged)
        budgetField.translatesAutoresizingMaskIntoConstraints = false
        budgetField.widthAnchor.constraint(equalToConstant: 90).isActive = true
        budgetField.stringValue = UsageBudget.monthlyLimitUSD.map { String(format: "%.2f", $0) } ?? ""

        let dollar = NSTextField(labelWithString: "$")
        dollar.font = DS.Text.body()
        let perMonth = NSTextField(labelWithString: "per month")
        perMonth.font = DS.Text.body()
        perMonth.textColor = .secondaryLabelColor

        let row = NSStackView(views: [label, dollar, budgetField, perMonth])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = DS.Spacing.s

        let statusLabel = NSTextField(wrappingLabelWithString: budgetStatusText())
        statusLabel.font = DS.Text.caption()
        statusLabel.textColor = budgetStatusColor()
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 440).isActive = true

        let stack = NSStackView(views: [row, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DS.Spacing.s
        return stack
    }

    private func budgetStatusText() -> String {
        let month = UsageStore.shared.estimatedCostThisMonth()
        let spent = UsageFormatting.cost(month.total)
        let caveat = month.hasUnpricedModels
            ? " Models with no published price here aren't counted, so the real figure is higher."
            : ""
        switch UsageBudget.status() {
        case .unlimited:
            return "No budget set — nothing is blocked. \(spent) estimated so far this month.\(caveat)"
        case .withinBudget(_, let limit):
            return "\(spent) of \(UsageFormatting.cost(limit)) estimated this month.\(caveat)"
        case .approaching(_, let limit):
            return "\(spent) of \(UsageFormatting.cost(limit)) estimated this month — close to the limit.\(caveat)"
        case .exceeded(_, let limit):
            return "\(spent) of \(UsageFormatting.cost(limit)) — the budget is reached, so Think won't send until you raise or clear it.\(caveat)"
        }
    }

    private func budgetStatusColor() -> NSColor {
        switch UsageBudget.status() {
        case .unlimited, .withinBudget: return .tertiaryLabelColor
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

/// Top-down stacking inside the scroll view — an unflipped document view pins sparse content to
/// the bottom, the same trap Think's transcript hit.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
