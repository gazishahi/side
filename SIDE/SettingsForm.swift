import AppKit

/// The grouped form Preferences and Library are built from: rounded sections of rows, a label
/// and its explanation on the left, the control on the right, the way System Settings lays
/// out. One component, so every pane has the same margins, widths and rhythm.
@MainActor
enum SettingsForm {
    /// Width of a Preferences pane's content; sections span it.
    static let contentWidth: CGFloat = 540
    static let pageInset: CGFloat = 24
    static let rowInset: CGFloat = 14
    static let rowMinHeight: CGFloat = 40

    /// A pane: sections stacked top-down in a scroll view, `contentWidth` wide.
    static func page(_ views: [NSView], maxHeight: CGFloat = 620) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DS.Spacing.section
        stack.edgeInsets = NSEdgeInsets(top: pageInset - 4, left: pageInset, bottom: pageInset, right: pageInset)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in views { view.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true }

        let document = FormFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let width = contentWidth + pageInset * 2
        let height = min(maxHeight, stack.fittingSize.height)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        // Sizes, not rules: a split view's content side fills them, a bare window uses them.
        for constraint in [scroll.widthAnchor.constraint(equalToConstant: width), scroll.heightAnchor.constraint(equalToConstant: max(200, height))] {
            constraint.priority = .defaultLow
            constraint.isActive = true
        }
        // The column stays centered and readable however wide the window gets.
        stack.leadingAnchor.constraint(greaterThanOrEqualTo: document.leadingAnchor).isActive = true
        return scroll
    }

    /// A pane's title card, System Settings style: a large icon tile, the pane's name, and what
    /// it's for, centered on a raised card.
    static func hero(symbol: String, tint: NSColor, title: String, detail: String) -> NSView {
        let tile = IconTile(symbol: symbol, tint: tint, size: 56)
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = DS.Text.custom(24, weight: .bold)
        titleLabel.alignment = .center
        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = DS.Text.body()
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .center
        detailLabel.preferredMaxLayoutWidth = contentWidth - 80
        let stack = NSStackView(views: [tile, titleLabel, detailLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = DS.Spacing.m
        stack.setCustomSpacing(DS.Spacing.l, after: tile)
        let card = NSView()
        card.bindLayerBackground(DS.Color.raised)
        card.layer?.cornerRadius = DS.Radius.surface
        card.layer?.cornerCurve = .continuous
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: DS.Spacing.section + 4),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -DS.Spacing.section),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: DS.Spacing.section),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -DS.Spacing.section),
        ])
        return card
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
        let box = NSView()
        // Tone, not a border, sets the section apart (Direction 02 §2.1): raised on canvas.
        box.bindLayerBackground(DS.Color.raised)
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
        if let title {
            let label = NSTextField(labelWithString: title)
            label.font = DS.Text.body(.semibold)
            label.textColor = .labelColor
            parts.append(indented(label))
        }
        parts.append(box)
        if let footer { parts.append(indented(footnote(footer, width: contentWidth - rowInset * 2))) }
        let group = NSStackView(views: parts)
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
        var texts: [NSView] = [titleLabel]
        if let detail {
            texts.append(footnote(detail, width: contentWidth - rowInset * 2 - accessoryWidth))
        }
        let text = NSStackView(views: texts)
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.setHuggingPriority(.defaultLow, for: .horizontal)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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

    /// Secondary text that wraps at `width`.
    static func footnote(_ text: String, width: CGFloat = contentWidth) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
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

final class FormFlippedView: NSView {
    override var isFlipped: Bool { true }
}
