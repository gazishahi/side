import AppKit

/// Changes' left column as a review queue (SIDE_RFC_SESSIONS.md, phase 4): who has changes to
/// review, each agent session by what it was asked, then your edits, then what isn't
/// attributed; the chosen one's files under it; and the whole branch, as before, at the end.
/// Replaces the files list while there's anything uncommitted (the owner's choice, 2026-11-12).
final class ReviewQueueRail: NSView {
    struct Item: Equatable {
        var title: String
        /// "Finished · +12 −3 · 2 files".
        var detail: String
        var icon: NSImage?
        var paths: [String]
    }

    var items: [Item] = [] { didSet { rebuild() } }
    /// The chosen item; nil for the whole branch.
    var selected: Int? = 0 { didSet { rebuild() } }
    var onSelect: ((Int?) -> Void)?
    /// One of the chosen item's files: bring it up in the diff.
    var onSelectPath: ((String) -> Void)?

    private let title = NSTextField(labelWithString: "TO REVIEW")
    private let stack = NSStackView()
    private let scroll = NSScrollView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        title.font = DS.Text.custom(11, weight: .semibold)
        title.textColor = .secondaryLabelColor
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        for view in [title, scroll] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.centerYAnchor.constraint(equalTo: topAnchor, constant: ReviewFileRail.headerHeight / 2),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DS.Spacing.l + DS.Spacing.xs),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: ReviewFileRail.headerHeight + DS.Spacing.s),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: DS.Spacing.s),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -DS.Spacing.s),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityLabel("Changes to review")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var bottomInset: CGFloat = 0 {
        didSet { scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: bottomInset, right: 0) }
    }

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, item) in items.enumerated() {
            let chosen = selected == index
            add(QueueRow(title: item.title, detail: item.detail, icon: item.icon, selected: chosen) { [weak self] in
                self?.selected = index
                self?.onSelect?(index)
            })
            guard chosen else { continue }
            for path in item.paths {
                add(QueueFileRow(path: path) { [weak self] in self?.onSelectPath?(path) })
            }
        }
        let divider = NSBox()
        divider.boxType = .separator
        add(divider, spacingBefore: DS.Spacing.m)
        add(QueueRow(title: "Whole branch", detail: "Everything, as before", icon: DS.Glyph.image(named: DS.Glyph.name("branches"), pointSize: 13),
                     selected: selected == nil) { [weak self] in
            self?.selected = nil
            self?.onSelect?(nil)
        }, spacingBefore: DS.Spacing.m)
    }

    private func add(_ view: NSView, spacingBefore: CGFloat? = nil) {
        if let spacingBefore, let last = stack.arrangedSubviews.last { stack.setCustomSpacing(spacingBefore, after: last) }
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    var titlesForTesting: [String] { items.map(\.title) }
}

/// One entry: its mark, what it is, and a line about it; the selected capsule when chosen.
private final class QueueRow: NSView {
    private let action: () -> Void

    init(title: String, detail: String, icon: NSImage?, selected: Bool, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = DS.Radius.control + 2
        if selected { bindLayerBackground(DS.Color.selectedCapsule) }
        let image = NSImageView(image: icon ?? NSImage())
        image.translatesAutoresizingMaskIntoConstraints = false
        image.contentTintColor = .secondaryLabelColor
        let name = NSTextField(labelWithString: title)
        name.font = DS.Text.body(.medium)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let meta = NSTextField(labelWithString: detail)
        meta.font = DS.Text.caption()
        meta.textColor = .secondaryLabelColor
        meta.lineBreakMode = .byTruncatingTail
        meta.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [image, name, meta] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 44),
            image.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DS.Spacing.m),
            image.centerYAnchor.constraint(equalTo: name.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 14), image.heightAnchor.constraint(equalToConstant: 14),
            name.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: DS.Spacing.s),
            name.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -DS.Spacing.m),
            name.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            meta.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            meta.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -DS.Spacing.m),
            meta.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 1),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(title), \(detail)")
        toolTip = title
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }
    override func accessibilityPerformPress() -> Bool { action(); return true }
}

/// A file of the chosen entry, indented under it.
private final class QueueFileRow: NSView {
    private let action: () -> Void

    init(path: String, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let name = NSTextField(labelWithString: (path as NSString).lastPathComponent)
        name.font = DS.Text.caption()
        name.textColor = .secondaryLabelColor
        name.lineBreakMode = .byTruncatingMiddle
        name.translatesAutoresizingMaskIntoConstraints = false
        name.toolTip = path
        addSubview(name)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 22),
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DS.Spacing.m + 14 + DS.Spacing.s),
            name.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -DS.Spacing.m),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(path)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
