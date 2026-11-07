import AppKit

/// The grouped form Preferences and Library are built from: rounded sections of rows, a label
/// and its explanation on the left, the control on the right, the way System Settings lays
/// out. One component, so every pane has the same margins, widths and rhythm.
@MainActor
enum SettingsForm {
    /// A form's narrowest: the Settings window's content side is never less. Sections fill the
    /// pane and flow into columns as it widens (`FormPage`): one centered column left most of
    /// a wide window empty (the owner, 2026-11-05).
    static let contentWidth: CGFloat = 620
    /// A column of sections: no narrower than this, so a row's title and control sit side by
    /// side, and no wider than `maxColumnWidth`, so they don't drift apart.
    static let minColumnWidth: CGFloat = 360
    static let maxColumnWidth: CGFloat = 600
    static let columnGap: CGFloat = 20
    /// Past this, an explanation goes behind an ⓘ beside its section's title, not under it:
    /// General was half explanation (the owner, 2026-11-05: "easily gets overwhelming").
    static let footerInfoThreshold = 110
    static let pageInset: CGFloat = 24
    static let rowInset: CGFloat = 14
    static let rowMinHeight: CGFloat = 40

    /// A pane: its header and anything else that isn't a section span the page; runs of
    /// sections flow into as many columns as the width allows, in reading order down each
    /// column. `width` is only the pane's preferred size, for a window that has none of its own.
    static func page(_ views: [NSView], width preferredWidth: CGFloat = contentWidth, maxHeight: CGFloat = 620) -> NSView {
        let document = FormPage(views: views)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        let height = min(maxHeight, document.fittingSize.height)
        // Sizes, not rules: a split view's content side fills them, a bare window uses them.
        for constraint in [scroll.widthAnchor.constraint(equalToConstant: preferredWidth + pageInset * 2), scroll.heightAnchor.constraint(equalToConstant: max(200, height))] {
            constraint.priority = .defaultLow
            constraint.isActive = true
        }
        return scroll
    }

    /// A pane's header: its icon tile, its name, and what it's for, in one row. It was a 220 pt
    /// card with a 56 pt tile, most of the empty space above the fold on every pane (2026-11-05).
    static func hero(symbol: String, tint: NSColor, title: String, detail: String, width: CGFloat = contentWidth) -> NSView {
        let tile = IconTile(symbol: symbol, tint: tint, size: 32)
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = DS.Text.custom(17, weight: .semibold)
        let detailLabel = footnote(detail, width: width - 32 - DS.Spacing.l - rowInset)
        let text = NSStackView(views: [titleLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let row = NSStackView(views: [tile, text])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = DS.Spacing.l
        row.edgeInsets = NSEdgeInsets(top: 0, left: rowInset - 4, bottom: DS.Spacing.s, right: 0)
        row.setAccessibilityElement(true)
        row.setAccessibilityRole(.group)
        row.setAccessibilityLabel(title)
        return row
    }

    /// Puts a page in a pane's view, replacing the one before (panes that rebuild).
    static func install(_ page: NSView, in view: NSView) {
        view.subviews.forEach { $0.removeFromSuperview() }
        page.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: view.topAnchor),
            page.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            page.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    static func toggle(_ on: Bool, _ target: AnyObject?, _ action: Selector) -> NSSwitch {
        let control = NSSwitch()
        control.controlSize = .small
        control.state = on ? .on : .off
        control.target = target
        control.action = action
        return control
    }

    static func section(_ rows: [NSView]) -> NSView { section(nil, footer: nil, rows) }
    static func section(footer: String, _ rows: [NSView]) -> NSView { section(nil, footer: footer, rows) }

    /// A rounded group of rows with hairlines between them, an optional small title above and
    /// a footnote below.
    static func section(_ title: String? = nil, footer: String? = nil, _ rows: [NSView]) -> NSView {
        section(title, footer: footer, rows, header: nil)
    }

    /// `header`: a view in place of the title (a collapsible section's disclosure).
    static func section(_ title: String?, footer: String?, _ rows: [NSView], header: NSView?) -> NSView {
        // Tone, not a border, sets the section apart (Direction 02 §2.1): raised on canvas.
        let box = RaisedBox()
        box.wantsLayer = true
        box.layer?.cornerRadius = DS.Radius.surface
        box.layer?.cornerCurve = .continuous
        let inner = NSStackView()
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 0
        inner.translatesAutoresizingMaskIntoConstraints = false
        for (index, row) in rows.enumerated() {
            // The hairline belongs to the row below it, so hiding a row hides its line too.
            let slot = index == 0 ? row : ruled(row)
            inner.addArrangedSubview(slot)
            slot.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true
        }
        box.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: box.topAnchor),
            inner.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            inner.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            inner.trailingAnchor.constraint(equalTo: box.trailingAnchor),
        ])

        var parts: [NSView] = []
        // A long explanation, under a titled section, goes behind an ⓘ beside the title.
        let info = title != nil && (footer?.count ?? 0) > footerInfoThreshold ? footer : nil
        if let header {
            parts.append(indented(header))
        } else if let title {
            let label = NSTextField(labelWithString: title)
            label.font = DS.Text.body(.semibold)
            label.textColor = .labelColor
            if let info {
                let header = NSStackView(views: [label, infoButton(info, about: title)])
                header.orientation = .horizontal
                header.alignment = .centerY
                header.spacing = DS.Spacing.s
                parts.append(indented(header))
            } else {
                parts.append(indented(label))
            }
        }
        parts.append(box)
        if let footer, info == nil { parts.append(indented(footnote(footer, width: minColumnWidth - rowInset * 2))) }
        let group = FormSection(views: parts)
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = DS.Spacing.s
        box.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
        return group
    }

    /// Title (and an optional explanation under it) on the left; the control on the right.
    static func row(_ title: String, detail: String? = nil, _ accessory: NSView? = nil, titleColor: NSColor = .labelColor) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = DS.Text.body()
        titleLabel.textColor = titleColor
        titleLabel.lineBreakMode = .byTruncatingTail
        let accessoryWidth = accessory.map { ceil($0.fittingSize.width) + DS.Spacing.xl } ?? 0
        // A wide control beside a long explanation left the explanation a narrow strip (Agents'
        // sign-in, 26 lines): under the text instead, at its start, and the explanation the
        // row's full width. A short one ("Markdown previews.") keeps its control on the right.
        let stacked = accessory != nil && (detail?.count ?? 0) > 80 && accessoryWidth > 220
        var texts: [NSView] = [titleLabel]
        if let detail {
            texts.append(footnote(detail, width: max(120, minColumnWidth - rowInset * 2 - (stacked ? 0 : accessoryWidth))))
        }
        let text = NSStackView(views: texts)
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.setHuggingPriority(.defaultLow, for: .horizontal)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if let accessory, stacked {
            accessory.setContentHuggingPriority(.required, for: .horizontal)
            let column = NSStackView(views: [text, accessory])
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = DS.Spacing.m
            return content(column)
        }
        return content(accessory.map { accessory in
            // A stack view's own hugging is `setHuggingPriority`; the content-hugging call only
            // reaches plain views. Both, so any accessory stays at its size on the right.
            accessory.setContentHuggingPriority(.required, for: .horizontal)
            accessory.setContentCompressionResistancePriority(.required, for: .horizontal)
            (accessory as? NSStackView)?.setHuggingPriority(.required, for: .horizontal)
            let line = NSStackView(views: [text, accessory])
            line.distribution = .fill
            line.orientation = .horizontal
            line.alignment = .centerY
            line.spacing = DS.Spacing.xl
            return line
        } ?? text)
    }

    /// Any content, padded like a row.
    static func content(_ view: NSView) -> NSView {
        let container = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: DS.Spacing.l),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -DS.Spacing.l),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: rowInset),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -rowInset),
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: rowMinHeight),
        ])
        return container
    }

    /// An ⓘ that shows `text` in a popover: an explanation one click away instead of always
    /// on the page.
    static func infoButton(_ text: String, about title: String) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
        button.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        button.contentTintColor = .tertiaryLabelColor
        button.setAccessibilityLabel("About \(title)")
        button.toolTip = text
        let target = ClosureTarget { [weak button] in
            guard let button else { return }
            let label = footnote(text, width: 300)
            label.font = DS.Text.body()
            label.textColor = .labelColor
            let holder = NSViewController()
            holder.view = content(label)
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentViewController = holder
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        }
        button.target = target
        button.action = #selector(ClosureTarget.run)
        objc_setAssociatedObject(button, &ClosureTarget.key, target, .OBJC_ASSOCIATION_RETAIN)
        return button
    }

    /// Secondary text that wraps at `width`.
    static func footnote(_ text: String, width: CGFloat = minColumnWidth) -> NSTextField {
        let label = WrappingLabel(wrappingLabelWithString: text)
        label.font = DS.Text.caption()
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = width
        label.isSelectable = false
        return label
    }

    static func button(_ title: String, _ target: AnyObject?, _ action: Selector, destructive: Bool = false) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.hasDestructiveAction = destructive
        return button
    }

    static func popup(_ titles: [String], selected: Int, _ target: AnyObject?, _ action: Selector) -> NSPopUpButton {
        let popup = NSPopUpButton()
        popup.addItems(withTitles: titles)
        popup.selectItem(at: max(0, selected))
        popup.target = target
        popup.action = action
        return popup
    }

    /// A small status word next to a title: "Installed", "Not installed".
    static func badge(_ text: String, color: NSColor) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = DS.Text.custom(10.5, weight: .medium)
        label.textColor = color
        let pill = NSView()
        pill.bindLayerBackground(color.withAlphaComponent(0.12))
        pill.layer?.cornerRadius = DS.Radius.capsule(height: 18)
        label.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: pill.topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -2),
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -7),
        ])
        return pill
    }

    private static func ruled(_ row: NSView) -> NSView {
        let container = RuledRow(row: row)
        let rule = NSBox()
        rule.boxType = .custom
        rule.borderWidth = 0
        rule.fillColor = DS.Color.hairline
        for view in [rule, row] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            rule.topAnchor.constraint(equalTo: container.topAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
            rule.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: rowInset),
            rule.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            row.topAnchor.constraint(equalTo: rule.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            row.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    private static func indented(_ view: NSView) -> NSView {
        let container = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: rowInset),
            view.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -rowInset),
        ])
        return container
    }
}

/// A row with the hairline above it: hiding the row hides both.
private final class RuledRow: NSView {
    let row: NSView
    init(row: NSView) {
        self.row = row
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

class FormFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A section's rounded ground, colored when AppKit updates its layer, so in whatever appearance
/// it's drawn in: a bound color was resolved once, and a pane off screen when the appearance
/// changed came back with the old one (dark cards in light, 2026-11-05).
final class RaisedBox: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = DS.Color.raised.cgColor }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsDisplay = true
    }
}

/// A group of rows made by `SettingsForm.section`: what a page flows into columns.
final class FormSection: NSStackView {}

/// A label that wraps at the width layout gives it, not one fixed when it was made: the same
/// explanation sits in a narrow column or a wide one.
final class WrappingLabel: NSTextField {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let width = bounds.width
        guard width > 0, abs(preferredMaxLayoutWidth - width) > 0.5 else { return }
        preferredMaxLayoutWidth = width
        invalidateIntrinsicContentSize()
    }
}

/// A form page: spanning views top-down, and between them runs of sections laid in columns.
/// The column count follows the width (`SettingsForm.minColumnWidth`), up to three; the page is
/// never wider than its columns can use, and centers past that.
@MainActor
final class FormPage: FormFlippedView {
    private let stack = NSStackView()
    private var flows: [SectionFlow] = []
    private var widthCap: NSLayoutConstraint!
    private var columns = 0

    init(views: [NSView]) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DS.Spacing.section
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        var run: [NSView] = []
        func flush() {
            guard !run.isEmpty else { return }
            let flow = SectionFlow(sections: run)
            flows.append(flow)
            add(flow)
            run = []
        }
        for view in views {
            if view is FormSection { run.append(view) } else { flush(); add(view) }
        }
        flush()
        let inset = SettingsForm.pageInset
        // Fills the page, but below the window's own size (500): at .defaultHigh a column's cap
        // held the whole Settings window to one column's width.
        let fill = stack.widthAnchor.constraint(equalTo: widthAnchor, constant: -inset * 2)
        fill.priority = NSLayoutConstraint.Priority(490)
        widthCap = stack.widthAnchor.constraint(lessThanOrEqualToConstant: SettingsForm.maxColumnWidth)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: inset - 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: inset),
            stack.widthAnchor.constraint(greaterThanOrEqualToConstant: SettingsForm.minColumnWidth),
            fill, widthCap,
        ])
        arrange(columns: 1)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func add(_ view: NSView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    /// How many columns `width` holds.
    static func columns(for width: CGFloat) -> Int {
        let min = SettingsForm.minColumnWidth, gap = SettingsForm.columnGap
        return width >= min * 3 + gap * 2 ? 3 : width >= min * 2 + gap ? 2 : 1
    }

    override func layout() {
        super.layout()
        let available = bounds.width - SettingsForm.pageInset * 2
        let most = flows.map(\.sections.count).max() ?? 1
        let wanted = max(1, min(Self.columns(for: available), most))
        if wanted != columns { arrange(columns: wanted) }
    }

    private func arrange(columns count: Int) {
        columns = count
        let gap = SettingsForm.columnGap
        widthCap.constant = SettingsForm.maxColumnWidth * CGFloat(count) + gap * CGFloat(count - 1)
        flows.forEach { $0.arrange(columns: count) }
        needsLayout = true
    }

    var columnsForTesting: Int { columns }
}

/// A run of sections in `columns` columns, each filled top-down in order until it holds about
/// its share of the run's height.
@MainActor
final class SectionFlow: NSView {
    let sections: [NSView]
    private var columns: [NSView] = []

    init(sections: [NSView]) {
        self.sections = sections
        super.init(frame: .zero)
        // As short as the tallest column: each column hangs from the top at its own height.
        let shortest = heightAnchor.constraint(equalToConstant: 0)
        shortest.priority = .fittingSizeCompression
        shortest.isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func arrange(columns count: Int) {
        let heights = sections.map { max(1, $0.fittingSize.height) }
        for section in sections { section.removeFromSuperview() }
        for column in columns { column.removeFromSuperview() }
        columns = []
        let share = heights.reduce(0, +) / CGFloat(count)
        var groups: [[NSView]] = [[]]
        var placed: CGFloat = 0
        for (section, height) in zip(sections, heights) {
            // On to the next column once this one has its share, by the section's middle.
            if groups.count < count, !groups[groups.count - 1].isEmpty, placed + height / 2 > share * CGFloat(groups.count) {
                groups.append([])
            }
            groups[groups.count - 1].append(section)
            placed += height
        }
        while groups.count < count { groups.append([]) }
        // Placed by hand, not in a horizontal stack: there, a short column was stretched to the
        // tallest one's height, and its sections with it.
        var previous: NSView?
        for group in groups {
            let column = NSStackView(views: group)
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = DS.Spacing.section
            column.setHuggingPriority(.required, for: .vertical)
            column.translatesAutoresizingMaskIntoConstraints = false
            addSubview(column)
            for section in group { section.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
            NSLayoutConstraint.activate([
                column.topAnchor.constraint(equalTo: topAnchor),
                column.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
                column.leadingAnchor.constraint(equalTo: previous?.trailingAnchor ?? leadingAnchor, constant: previous == nil ? 0 : SettingsForm.columnGap),
            ])
            if let first = columns.first { column.widthAnchor.constraint(equalTo: first.widthAnchor).isActive = true }
            columns.append(column)
            previous = column
        }
        previous?.trailingAnchor.constraint(equalTo: trailingAnchor).isActive = true
    }
}
