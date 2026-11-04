import AppKit

/// Make's and Run's tabs (Direction 03 §4): one component for the chips in a stage's glass
/// track, their order, the drag that reorders them or tears one out into a window, renaming,
/// and arriving and leaving. The owner keeps its own model (files, terminals) and hands the
/// strip its items; the strip reports what the person did.
///
/// Each stage used to build its own copy of all of this, and rebuilt every chip on any change:
/// Run did so on every terminal event. Items are matched by id, so an unchanged tab keeps its
/// chip and only what changed is redrawn.
@MainActor
final class TabStrip: NSObject {
    struct Item {
        var id: UUID
        var title: String
        /// After the title, quieter: the folder that tells same-named files apart.
        var detail = ""
        var toolTip: String?
        /// The file's own icon, or Run's terminal glyph: in the card a dragged-out tab becomes.
        var icon: NSImage?
        var isDirty = false
        var isDead = false
        var hasUnseenOutput = false
        /// Run's: what happened out of sight that the tab's dot says in color (a turn that
        /// finished, a bell that wants you); nil leaves new output a plain dot.
        var news: DS.StatusState?
        /// Run's: an agent in the terminal is working (DS's breathing Working ring).
        var isWorking = false
        var menu: NSMenu?
        /// What the tab shows, drawn into the card it becomes when dragged out.
        var preview: (() -> NSImage?)?
    }

    let bar: TabStripView
    let stack: NSStackView
    private(set) var chips: [TabChipView] = []
    private(set) var ids: [UUID] = []

    var onSelect: ((Int) -> Void)?
    /// A chip moved from one place to another, live, during a drag: the owner moves its model.
    var onMove: ((Int, Int) -> Void)?
    /// A drag ended with the chip set down: the order is final, to remember.
    var onMoveEnded: (() -> Void)?
    var onClose: ((Int) -> Void)?
    /// Released outside the window: the tab becomes a window there. Nil: tabs can't.
    var onTearOut: ((Int, NSPoint) -> Void)?
    /// A new name, or nil for the automatic one. Nil: tabs can't be renamed.
    var onRename: ((Int, String?) -> Void)?

    /// The selected tab's tint: one capsule behind the chips that slides to whichever tab is
    /// selected. Each chip drew its own, so after a close the tint appeared on the next tab only
    /// once the closing animation had ended (the owner, 2026-10-31); now it moves as the gap
    /// closes, and on every switch.
    private let selection = NSView()
    /// Held off while the selected tab is lifted out of its slot.
    private var selectionHeld = false

    init(bar: TabStripView, stack: NSStackView, accessibilityLabel: String) {
        self.bar = bar
        self.stack = stack
        super.init()
        bar.accessibilityGroupLabel = accessibilityLabel
        selection.wantsLayer = true
        selection.bindLayerBackground(DS.Color.selectedCapsule)
        selection.layer?.cornerRadius = TabChipView.height / 2
        selection.layer?.shadowColor = NSColor.black.cgColor
        selection.layer?.shadowOpacity = 0.12
        selection.layer?.shadowRadius = 2
        selection.layer?.shadowOffset = CGSize(width: 0, height: -0.5)
        selection.isHidden = true
        stack.addSubview(selection, positioned: .below, relativeTo: nil)
        TabShortcutHints.start()
        NotificationCenter.default.addObserver(self, selector: #selector(applyShortcutHints), name: TabShortcutHints.changed, object: nil)
    }

    /// Each tab's shortcut in its trailing slot while the hints show, in the key window only.
    @objc private func applyShortcutHints() {
        let showing = TabShortcutHints.showing && bar.window?.isKeyWindow == true
        for (index, chip) in chips.enumerated() {
            chip.shortcutHint = showing ? TabShortcutHints.hint(at: index, count: chips.count) : nil
        }
    }

    /// Where the tint sits: under the selected chip's capsule.
    ///
    /// Nil until the chip has a real size. A new chip is first placed with no width, and
    /// insetting that gives the null rect, whose origin is infinite: set as the tint's frame it
    /// broke the strip's layout ("Invalid view geometry: y is infinity"), and the new tab went
    /// undrawn until a click laid the strip out again (the owner, 2026-10-31).
    private func selectionFrame() -> NSRect? {
        guard !selectionHeld, let chip = chips.first(where: \.isActive) else { return nil }
        let inset = TabChipView.flare - 2
        guard chip.frame.width > inset * 2 + 1, chip.frame.height > 0 else { return nil }
        let frame = chip.frame.insetBy(dx: inset, dy: 0)
        guard !frame.isNull, frame.minX.isFinite, frame.minY.isFinite else { return nil }
        return frame
    }

    private func placeSelection() {
        guard let frame = selectionFrame() else { selection.isHidden = true; return }
        selection.frame = frame
        selection.isHidden = false
    }

    /// Lays the strip out on a spring: the chips, the glass track around them (it used to
    /// jump to its new width while the chips slid, 2026-10-31) and the tint under the selected
    /// chip all move together.
    private func relayout(_ spring: DS.Motion.Spring, _ changes: () -> Void = {}, completion: (@MainActor () -> Void)? = nil) {
        isRelayingOut = true
        changes()
        // The tabs live in a scroll view, which draws only what its content covered when an
        // animation began: a strip growing inside the animation left its new part, where a new
        // tab arrives, undrawn until the next layout (the owner, 2026-10-31: blank new tabs,
        // sometimes). The content takes its new width at once; the tabs and the track move on
        // the spring inside it.
        growContentToFit()
        DS.Motion.animate(spring, crossfading: bar, {
            bar.needsLayout = true
            bar.layoutSubtreeIfNeeded()
            bar.setTrackWidth(tabsWidth(), spring: spring)
            keepTabsInView()
            if let frame = selectionFrame() {
                if selection.isHidden {
                    selection.frame = frame
                    selection.isHidden = false
                } else {
                    selection.animator().frame = frame
                }
            } else {
                selection.isHidden = true
            }
        }, completion: completion)
        isRelayingOut = false
    }

    /// A strip that got narrower (a tab closed or torn out) kept its old scroll position, past
    /// the end of the tabs, so they sat scrolled out of view until something moved them (the
    /// owner, 2026-10-31). The scroll stays within the tabs.
    private func keepTabsInView() {
        guard let clip = stack.enclosingScrollView?.contentView else { return }
        // The tabs' own width: the stack's frame catches up only on the window's next layout.
        let maxX = max(0, stack.fittingSize.width - clip.bounds.width)
        guard clip.bounds.origin.x > maxX + 0.5 || clip.bounds.origin.x < 0 else { return }
        let origin = NSPoint(x: min(max(0, clip.bounds.origin.x), maxX), y: clip.bounds.origin.y)
        // Inside `relayout`'s group this moves on its spring, as the frames around it do.
        clip.setBoundsOrigin(origin)
        stack.enclosingScrollView?.reflectScrolledClipView(clip)
    }

    /// The tabs' width as laid out: the last chip's end and the stack's inset after it.
    private func tabsWidth() -> CGFloat {
        guard let last = chips.last else { return 0 }
        return last.frame.maxX + stack.edgeInsets.right
    }

    /// The scroll view's content takes a new, larger width at once, never on a spring.
    private func growContentToFit() {
        let fitting = stack.fittingSize.width
        guard fitting > stack.frame.width else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            stack.setFrameSize(NSSize(width: fitting, height: stack.frame.height))
        }
    }

    /// Set while `relayout` moves things itself.
    private var isRelayingOut = false

    /// A chip moved or resized outside an animation of the strip's own (the first layout after
    /// launch, a window resize): the tint follows it at once. On launch it was placed before
    /// the strip had its size, and stayed off the selected tab.
    ///
    /// Never during the layout that moved the chip: placing a sibling view from inside a layout
    /// pass could leave part of the strip undrawn, and new tabs sometimes showed blank (the owner,
    /// 2026-10-31). One update, just after the layout.
    func chipFrameChanged(_ chip: TabChipView) {
        guard chip.isActive, !isRelayingOut, !selectionSyncQueued else { return }
        selectionSyncQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.selectionSyncQueued = false
            guard !self.isRelayingOut else { return }
            self.placeSelection()
        }
    }

    private var selectionSyncQueued = false

    // MARK: Items

    /// Shows `items`, the one at `active` selected. One tab needs no strip: a single tab is only a
    /// label with a close button for the one thing you're looking at, so the strip shows from two.
    func reload(_ items: [Item], active: Int?) {
        // A strip still fading out goes now: what comes next is drawn fresh.
        leaving.forEach { $0.removeFromSuperview() }
        leaving = []
        selection.layer?.removeAnimation(forKey: "stripSlide")
        selection.alphaValue = 1
        guard items.count > 1 else {
            dismiss(keeping: items.first?.id)
            showSolo(items.first)
            return
        }
        showSolo(nil)
        // The same tabs while a close is on its way (the owner's reload just after it): only what
        // they say and which is selected. Laying out here would stop the close's spring halfway.
        if items.map(\.id) == ids, !chips.isEmpty, !closing.isEmpty {
            let wasActive = chips.firstIndex(where: \.isActive)
            for (index, (chip, item)) in zip(chips, items).enumerated() { configure(chip, item, index: index, isActive: index == active) }
            if wasActive != active { relayout(DS.Motion.snappy) }
            return
        }
        let appearing = chips.isEmpty && bar.window?.isVisible == true && !bar.isHiddenOrHasHiddenAncestor
        let wasActive = chips.first(where: \.isActive)?.id
        let newIDs = items.map(\.id)
        let previous = Dictionary(uniqueKeysWithValues: zip(ids, chips))
        // One tab more than before, everything else the same: that one arrives. Anything else (a
        // track switch, a restore) lays out at once.
        let arriving: UUID? = !ids.isEmpty && newIDs.count == ids.count + 1 && newIDs.filter({ previous[$0] == nil }).count == 1
            ? newIDs.first { previous[$0] == nil } : nil
        var next: [TabChipView] = []
        for (index, item) in items.enumerated() {
            let chip = previous[item.id] ?? makeChip()
            configure(chip, item, index: index, isActive: index == active)
            next.append(chip)
        }
        for chip in chips where !next.contains(where: { $0 === chip }) { chip.removeFromSuperview() }
        for (index, chip) in next.enumerated() where stack.arrangedSubviews.firstIndex(of: chip) != index {
            if chip.superview === stack { stack.removeArrangedSubview(chip) }
            stack.insertArrangedSubview(chip, at: index)
        }
        chips = next
        ids = newIDs
        bar.accessibleTabs = chips
        applyShortcutHints()
        if appearing {
            appear()
        } else if previous.isEmpty {
            bar.showTrack(true, animated: false)
            bar.layoutSubtreeIfNeeded()
            bar.setTrackWidth(tabsWidth(), spring: nil)
            keepTabsInView()
            placeSelection()
        } else if let arriving, let chip = chips.first(where: { $0.id == arriving }) {
            grow(chip)
        } else if let wasActive, wasActive != active.flatMap({ newIDs.indices.contains($0) ? newIDs[$0] : nil }), !selection.isHidden {
            // Another tab selected: the tint slides to it.
            relayout(DS.Motion.snappy)
        } else {
            bar.layoutSubtreeIfNeeded()
            bar.setTrackWidth(tabsWidth(), spring: nil)
            keepTabsInView()
            placeSelection()
        }
    }

    /// One tab is no strip (the owner, 2026-11-04: no tab for a single item), but it still says
    /// what's open: its name, plain, where the tab would start. It fades in as the strip goes.
    private lazy var soloLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = DS.Text.body(.medium)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.alphaValue = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        bar.addSubview(label)
        soloLeading = label.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 0)
        NSLayoutConstraint.activate([
            soloLeading!,
            label.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: bar.trailingAnchor, constant: -DS.Spacing.l),
        ])
        return label
    }()
    /// The tab's icon beside it, where the chip drew it, so the chip crossfades into the two.
    private lazy var soloIcon: NSImageView = {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.contentTintColor = .secondaryLabelColor
        view.symbolConfiguration = .init(pointSize: 11, weight: .medium)
        view.alphaValue = 0
        view.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(view)
        NSLayoutConstraint.activate([
            view.centerXAnchor.constraint(equalTo: stack.leadingAnchor, constant: stack.edgeInsets.left + TabChipView.iconCenterX),
            view.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            view.widthAnchor.constraint(equalToConstant: 14), view.heightAnchor.constraint(equalToConstant: 14),
        ])
        return view
    }()
    private var soloLeading: NSLayoutConstraint?
    var soloTitleForTesting: String? { soloLabel.alphaValue > 0 || soloShown ? soloLabel.stringValue : nil }
    private var soloShown = false
    /// Set by `dismiss` when the tab that stays doesn't move: the name can come in under it.
    private var soloUnderKeptTab = false

    private func showSolo(_ item: Item?) {
        let shown = item != nil
        if let item {
            soloLabel.attributedStringValue = TabChipView.label(title: item.title, detail: item.detail, attributes: [.font: DS.Text.body(.medium), .foregroundColor: NSColor.secondaryLabelColor])
            soloLabel.toolTip = item.toolTip
            soloIcon.image = item.icon
            soloLeading?.constant = stack.edgeInsets.left + TabChipView.textX(hasIcon: item.icon != nil)
        }
        let views: [NSView] = [soloLabel, soloIcon]
        guard shown != soloShown else { return }
        soloShown = shown
        guard bar.window != nil, !DS.Motion.reduceMotion else { views.forEach { $0.alphaValue = shown ? 1 : 0 }; return }
        // In as the strip fades out over it (`dismiss`), out at once as a strip opens.
        // When the tab that stays is already where the name goes, the name comes in under it at
        // once, and the tab fades off a name already there: started together, both were half
        // there at once and the name all but blinked out between them. When the tab slides
        // there, the name waits for it.
        let delay = shown && !soloUnderKeptTab ? max(0, DS.Motion.snappy.duration - DS.Motion.fadeDuration * 1.3) : 0
        soloUnderKeptTab = false
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.soloShown == shown else { return }
            DS.Motion.fade { views.forEach { $0.animator().alphaValue = shown ? 1 : 0 } }
        }
    }

    /// Chips fading out with the strip, removed when the fade ends or the next reload comes.
    private var leaving: [TabChipView] = []

    /// A second tab opened: the strip opens out of the first tab (the owner, 2026-10-31: a
    /// plain fade was dull). The track and the first tab come in together; the track springs
    /// open from the first tab's width while the others slide out from under it, the tint riding
    /// with its tab.
    private func appear() {
        appearCountForTesting += 1
        growContentToFit()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            stack.layoutSubtreeIfNeeded()
        }
        bar.layoutSubtreeIfNeeded()
        placeSelection()
        guard let first = chips.first else { return }
        let firstEnd = first.frame.maxX + stack.edgeInsets.right
        bar.showTrack(true, animated: true)
        // Quick: it's chrome making room, not a presentation (the owner: faster).
        bar.setTrackWidth(tabsWidth(), spring: DS.Motion.snappy, from: firstEnd)
        guard !DS.Motion.reduceMotion else { return }
        // Above the others, so they come out from under it rather than across it.
        first.layer?.zPosition = 1
        first.alphaValue = 0
        for chip in chips.dropFirst() { chip.alphaValue = 0 }
        selection.alphaValue = 0
        DS.Motion.fade {
            first.animator().alphaValue = 1
            for chip in chips.dropFirst() { chip.animator().alphaValue = 1 }
            selection.animator().alphaValue = 1
        }
        // From under the first tab: each starts where the first one is.
        let activeChip = chips.first(where: \.isActive)
        for chip in chips.dropFirst() {
            slide(chip, from: first.frame.minX - chip.frame.minX, to: 0, spring: DS.Motion.snappy)
            if chip === activeChip { slide(selection, from: first.frame.minX - chip.frame.minX, to: 0, spring: DS.Motion.snappy) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + DS.Motion.snappy.duration) { first.layer?.zPosition = 0 }
    }

    /// A horizontal offset that springs away (or in), additively, over the view's laid-out place.
    private func slide(_ view: NSView, from: CGFloat, to: CGFloat, spring: DS.Motion.Spring) {
        guard let layer = view.layer, from != to else { return }
        let move = DS.Motion.spring(spring, keyPath: "transform.translation.x")
        move.isAdditive = true
        move.fromValue = from
        move.toValue = to
        move.fillMode = .forwards
        move.isRemovedOnCompletion = to == 0
        layer.add(move, forKey: "stripSlide")
    }

    var appearCountForTesting = 0

    /// Down to one tab (the owner: it lingered, and then that the closed tab crossed the other,
    /// 2026-11-03 and 11-04). The tab that went fades where it is, at once; the one that stays
    /// moves to the strip's start if it wasn't there, taking the tint; the track closes to it;
    /// and the strip fades as they arrive. Sliding the closed tab onto the one that stays, the
    /// earlier design, put its title and tint over that tab's title: tabs have no background of
    /// their own to hide it under.
    private func dismiss(keeping kept: UUID? = nil) {
        guard !chips.isEmpty else { return }
        let gone = chips
        chips = []
        ids = []
        bar.accessibleTabs = []
        guard bar.window != nil, !bar.isHiddenOrHasHiddenAncestor, !DS.Motion.reduceMotion,
              let first = gone.first(where: { $0.id == kept }) ?? gone.first, let leading = gone.first else {
            gone.forEach { $0.removeFromSuperview() }
            selection.isHidden = true
            bar.showTrack(false, animated: false)
            return
        }
        leaving = gone
        let others = gone.filter { $0 !== first }
        let shift = leading.frame.minX - first.frame.minX
        soloUnderKeptTab = shift == 0
        // Where the one that stays moves into their place, they're gone at once: even a short
        // fade showed them under it.
        if shift != 0 {
            others.forEach { $0.alphaValue = 0 }
        } else {
            DS.Motion.fade(duration: 0.08) { others.forEach { $0.animator().alphaValue = 0 } }
        }
        slide(first, from: 0, to: shift, spring: DS.Motion.snappy)
        // The tint sits under the selected tab, which may be the one that went.
        let tinted = gone.first(where: \.isActive) ?? first
        slide(selection, from: 0, to: leading.frame.minX - tinted.frame.minX, spring: DS.Motion.snappy)
        bar.setTrackWidth(leading.frame.minX + first.frame.width + stack.edgeInsets.right, spring: DS.Motion.snappy)
        // The fade starts as the slide is most of the way home and ends with it.
        let fadeAt = max(0, DS.Motion.snappy.duration - DS.Motion.fadeDuration * 1.3)
        DispatchQueue.main.asyncAfter(deadline: .now() + fadeAt) { [weak self] in
            guard let self, self.chips.isEmpty else { return }
            self.bar.showTrack(false, animated: true)
            DS.Motion.fade({
                gone.forEach { $0.animator().alphaValue = 0 }
                self.selection.animator().alphaValue = 0
            }, completion: { [weak self] in
                guard let self, self.leaving.contains(where: { gone.contains($0) }) else { return }
                gone.forEach { $0.layer?.removeAnimation(forKey: "stripSlide"); $0.layer?.zPosition = 0; $0.removeFromSuperview() }
                self.leaving.removeAll { gone.contains($0) }
                self.selection.layer?.removeAnimation(forKey: "stripSlide")
                if self.chips.isEmpty {
                    self.selection.isHidden = true
                    self.selection.alphaValue = 1
                }
            })
        }
    }

    /// The selected tab changed, nothing else.
    func setActive(_ active: Int?) {
        for (index, chip) in chips.enumerated() { chip.isActive = index == active }
        relayout(DS.Motion.snappy)
    }

    private func configure(_ chip: TabChipView, _ item: Item, index: Int, isActive: Bool) {
        chip.id = item.id
        chip.index = index
        if chip.title != item.title { chip.title = item.title }
        if chip.detail != item.detail { chip.detail = item.detail }
        chip.toolTip = item.toolTip
        chip.dragIcon = item.icon
        chip.dragPreview = item.preview
        if chip.isDirty != item.isDirty { chip.isDirty = item.isDirty }
        if chip.isDead != item.isDead { chip.isDead = item.isDead }
        if chip.hasUnseenOutput != item.hasUnseenOutput { chip.hasUnseenOutput = item.hasUnseenOutput }
        if chip.news != item.news { chip.news = item.news }
        if chip.isWorking != item.isWorking { chip.isWorking = item.isWorking }
        if chip.isActive != isActive { chip.isActive = isActive }
        chip.menu = item.menu
    }

    private func makeChip() -> TabChipView {
        let chip = TabChipView()
        chip.strip = self
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.heightAnchor.constraint(equalToConstant: TabChipView.height).isActive = true
        let close = TabCloseButton()
        close.target = self
        close.action = #selector(closeTapped(_:))
        close.translatesAutoresizingMaskIntoConstraints = false
        close.isHidden = true
        chip.addSubview(close)
        chip.closeButton = close
        NSLayoutConstraint.activate([
            close.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -(5 + TabChipView.flare)),
            close.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
        ])
        return chip
    }

    @objc private func closeTapped(_ sender: NSView) {
        guard let chip = sender.superview as? TabChipView, let index = chips.firstIndex(of: chip) else { return }
        onClose?(index)
    }

    // MARK: Arriving and leaving (§4.4)

    /// A new tab is laid out at its place at once and only fades in; the glass track and the tint
    /// glide to it. Arrivals that moved the tab itself (growing from no width, rising and scaling
    /// in) sometimes left it blank on screen though laid out and drawn (the owner, 2026-10-31:
    /// only opening a tab, never closing or dragging); a fade is all an arrival needs.
    private func grow(_ chip: TabChipView) {
        growContentToFit()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            stack.layoutSubtreeIfNeeded()
        }
        chip.alphaValue = 0
        relayout(DS.Motion.smooth)
        DS.Motion.fade { chip.animator().alphaValue = 1 }
    }

    /// The closing tab narrows to nothing and fades as its neighbours close the gap.
    /// `activeAfter` is the tab selected once it's gone (indexed after the close): it takes the
    /// selection now, the tint sliding over as the gap closes.
    ///
    /// The chip leaves `chips` at once, so the strip's indices are the owner's as soon as the owner
    /// drops the tab, which it does right away. Until 2026-11-04 the chip stayed listed until its
    /// animation ended and the owner waited for it: a second close in that time used an index
    /// counted with the vanishing tab in it and removed the wrong one, after which the X and
    /// clicks on tabs did nothing (the owner: "sometimes closing a tab by clicking on the X
    /// doesn't work"). The vanishing chip took clicks too: a view at alpha 0 is still hit.
    /// `completion` is the animation's end, for anyone watching it.
    func animateClose(at index: Int, activeAfter: Int?, completion: (@MainActor () -> Void)? = nil) {
        // Two down to one is the strip going (`dismiss`, from the owner's reload).
        guard chips.indices.contains(index), chips.count > 2 else { completion?(); return }
        let chip = chips.remove(at: index)
        ids.remove(at: index)
        for (position, each) in chips.enumerated() {
            each.index = position
            each.isActive = position == activeAfter
        }
        bar.accessibleTabs = chips
        applyShortcutHints()
        chip.isLeaving = true
        chip.isActive = false
        guard bar.window != nil, !DS.Motion.reduceMotion else {
            chip.removeFromSuperview()
            relayout(DS.Motion.snappy, completion: completion)
            return
        }
        // Out of the row, over its old place: the row closes up on the spring while the chip
        // narrows from its trailing edge, clipped, so it's gone as its neighbour arrives.
        let frame = chip.frame
        stack.removeArrangedSubview(chip)
        chip.removeConstraints(chip.constraints.filter { $0.firstItem === chip && $0.secondItem == nil })
        chip.translatesAutoresizingMaskIntoConstraints = true
        chip.frame = frame
        chip.layer?.masksToBounds = true
        closing.append(chip)
        DS.Motion.animate(DS.Motion.snappy, {
            chip.animator().frame = NSRect(x: frame.minX, y: frame.minY, width: 0, height: frame.height)
        })
        // Quick: narrowing, it shows its icon alone for a moment, which shouldn't linger.
        DS.Motion.fade(duration: DS.Motion.fadeDuration * 0.4, { chip.animator().alphaValue = 0 })
        relayout(DS.Motion.snappy, completion: { [weak self] in
            chip.removeFromSuperview()
            self?.closing.removeAll { $0 === chip }
            completion?()
        })
    }

    /// UI testing: a click on the X of the tab at `index`, as the pointer makes one: hit-tested
    /// at the X's centre, so a view over it (a tab on its way out) takes the click instead.
    func clickCloseForTesting(_ index: Int) {
        guard chips.indices.contains(index), let close = chips[index].closeButton, let window = bar.window,
              let content = window.contentView else { return }
        close.isHidden = false
        let point = content.convert(NSPoint(x: close.bounds.midX, y: close.bounds.midY), from: close)
        guard let hit = content.hitTest(point) as? NSControl else { return }
        hit.sendAction(hit.action, to: hit.target)
    }

    /// Chips on their way out after `animateClose`: drawn, never listed, never hit.
    private var closing: [TabChipView] = []

    // MARK: Drag (§4.2), called by the chip being dragged

    /// The held chip's slot follows the pointer: it takes the place of however many siblings
    /// sit left of the pointer, and the siblings slide aside.
    func chipMoved(_ chip: TabChipView, toWindowX x: CGFloat) {
        guard let from = chips.firstIndex(of: chip) else { return }
        // Counted, never a sibling's own index: that pointed one slot short after a swap, and the
        // tab swapped straight back on the next event.
        var to = 0
        for sibling in chips where sibling !== chip {
            if x > sibling.convert(NSPoint(x: sibling.bounds.midX, y: 0), to: nil).x { to += 1 }
        }
        move(chip, from: from, to: to, animated: true)
    }

    private func move(_ chip: TabChipView, from: Int, to: Int, animated: Bool) {
        guard to != from else { return }
        chips.insert(chips.remove(at: from), at: to)
        ids.insert(ids.remove(at: from), at: to)
        for (index, each) in chips.enumerated() { each.index = index }
        stack.removeArrangedSubview(chip)
        stack.insertArrangedSubview(chip, at: to)
        onMove?(from, to)
        guard animated else { bar.layoutSubtreeIfNeeded(); placeSelection(); return }
        relayout(DS.Motion.snappy)
    }

    /// Back where a cancelled drag started.
    func chipReturned(_ chip: TabChipView, to index: Int) {
        guard let from = chips.firstIndex(of: chip) else { return }
        move(chip, from: from, to: min(index, chips.count - 1), animated: true)
    }

    /// The selected tab lifted out of its slot takes its tint with it.
    func chipLifted(_ chip: TabChipView) {
        guard chip.isActive else { return }
        selectionHeld = true
        selection.isHidden = true
    }

    func chipSetDown(_ chip: TabChipView) { onMoveEnded?() }

    /// Settled in its slot: the tint comes back under it.
    func chipSettled(_ chip: TabChipView) {
        guard selectionHeld else { return }
        selectionHeld = false
        placeSelection()
    }

    var selectionFrameForTesting: NSRect? { selection.isHidden ? nil : selection.frame }
    /// Whether the tint is drawn under every chip, as it must be.
    var tintIsUnderTheChipsForTesting: Bool {
        guard let tint = stack.subviews.firstIndex(of: selection) else { return false }
        return chips.allSatisfy { (stack.subviews.firstIndex(of: $0) ?? -1) > tint }
    }

    /// The frame the tint would be given now.
    var intendedSelectionFrameForTesting: NSRect? { selectionFrame() }

    var canTearOut: Bool { onTearOut != nil }

    /// Torn out: the slot closes up, the neighbours closing the gap.
    func collapseSlot(of chip: TabChipView) {
        chip.slotWidth?.isActive = false
        let constraint = chip.widthAnchor.constraint(equalToConstant: chip.frame.width)
        constraint.isActive = true
        chip.slotWidth = constraint
        relayout(DS.Motion.snappy, { constraint.constant = 0 })
    }

    /// Back over the strip: a slot opens where the pointer is.
    func reopenSlot(of chip: TabChipView, atWindowX x: CGFloat) {
        chipMoved(chip, toWindowX: x)
        guard let constraint = chip.slotWidth else { return }
        let width = chip.intrinsicContentSize.width
        relayout(DS.Motion.snappy, { constraint.constant = width }, completion: { [weak chip] in
            guard let chip, chip.slotWidth === constraint else { return }
            constraint.isActive = false
            chip.slotWidth = nil
        })
    }

    /// A tear-out that opened no window (the tab couldn't close: a save prompt cancelled): the
    /// tab comes back to its slot. It stayed invisible there.
    func chipStayed(_ chip: TabChipView) {
        guard chips.contains(chip) else { return }
        chip.alphaValue = 1
        if let constraint = chip.slotWidth {
            relayout(DS.Motion.snappy, { constraint.constant = chip.intrinsicContentSize.width }, completion: { [weak chip] in
                guard let chip, chip.slotWidth === constraint else { return }
                constraint.isActive = false
                chip.slotWidth = nil
            })
        }
        chipSettled(chip)
    }

    func chipTornOut(_ chip: TabChipView, at screenPoint: NSPoint) {
        guard let index = chips.firstIndex(of: chip) else { return }
        onTearOut?(index, screenPoint)
    }

    func chipSelected(_ chip: TabChipView) {
        guard let index = chips.firstIndex(of: chip) else { return }
        onSelect?(index)
    }

    var canRename: Bool { onRename != nil }

    func chipRenamed(_ chip: TabChipView, to name: String?) {
        guard let index = chips.firstIndex(of: chip) else { return }
        onRename?(index, name)
    }
}

// MARK: - The chip

/// One tab: a capsule on the strip's glass, its title, and the trailing slot that shows the close
/// button on hover, else the unsaved or unseen dot. It owns its drag (§4.2): pressed, lifted into
/// the floating layer, following the pointer, torn out into a card, set down or landed.
final class TabChipView: NSView, PointerHoverSyncing {
    weak var strip: TabStrip?
    /// Closed and on its way out: still drawn, never clicked.
    var isLeaving = false
    override func hitTest(_ point: NSPoint) -> NSView? { isLeaving ? nil : super.hitTest(point) }
    weak var closeButton: TabCloseButton?
    var id = UUID()
    var index: Int = 0
    var title: String = "" { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    /// After the title, quieter: the folder that tells this tab from another of the same name.
    var detail: String = "" { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var isActive: Bool = false {
        didSet {
            needsDisplay = true
            updateCloseVisibility()
            if isActive { revealWhenLaidOut() }
        }
    }
    /// Run's: an exited process, and output printed while the tab wasn't shown.
    var isDead: Bool = false { didSet { needsDisplay = true } }
    var hasUnseenOutput: Bool = false { didSet { needsDisplay = true } }
    /// The dot in color: a turn finished (green), a bell wanting you (amber).
    var news: DS.StatusState? { didSet { needsDisplay = true } }
    /// Unsaved edits: a dot where the close button sits, until hover swaps it for the ×.
    var isDirty: Bool = false { didSet { needsDisplay = true; updateCloseVisibility() } }
    /// An agent working in the tab's terminal: the Working ring (the app's one animated
    /// indicator, Direction 02 §2.4) in place of the tab's icon, where the eye starts reading.
    /// In the trailing slot it was easy to miss (the owner, 2026-11-04).
    var isWorking: Bool = false {
        didSet {
            guard isWorking != oldValue else { return }
            workingTextRect = .zero
            needsDisplay = true
            updateWorkingIndicator()
            updateCloseVisibility()
        }
    }

    // MARK: Working

    /// A working tab's title shimmers: a band of light sweeps across it, the title a step
    /// quieter underneath. Kept from five tried on 2026-11-04 (the owner: "shimmer"); the ring
    /// before it was "lazy and ugly".
    private var workingLayers: [CALayer] = []
    /// Where the title was last drawn: the shimmer follows it.
    private var workingTextRect = NSRect.zero
    var isShowingWorkingLightForTesting: Bool { !workingLayers.isEmpty }

    private func updateWorkingIndicator() {
        workingLayers.forEach { $0.removeFromSuperlayer() }
        workingLayers = []
        iconView.isHidden = dragIcon == nil
        guard isWorking, let host = layer, bounds.width > 0, !drawsLifted else { return }
        let reduce = DS.Motion.reduceMotion
        effectiveAppearance.performAsCurrentDrawingAppearance { workingLayers = shimmerLayers(reduce: reduce) }
        workingLayers.forEach { host.addSublayer($0) }
    }

    private var backingScale: CGFloat { window?.backingScaleFactor ?? 2 }

    /// The working light's colors are resolved when it's made: made again for a new appearance,
    /// or a light-mode band stayed on a dark tab until the turn ended.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if isWorking { updateWorkingIndicator() }
    }

    /// On one clock for every tab: each tab's light at the same point of its cycle, whenever its
    /// work began, so several working tabs move as one rather than each its own way (the owner,
    /// 2026-11-04: lights "overstimulating … on multiple terminal tabs").
    private static func inStep(_ animation: CABasicAnimation) {
        let now = CACurrentMediaTime()
        animation.beginTime = now - fmod(now, animation.duration)
    }

    private func shimmerLayers(reduce: Bool) -> [CALayer] {
        guard workingTextRect.width > 0 else { return [] }
        let text = CATextLayer()
        text.string = Self.label(title: title, detail: detail, attributes: [.font: DS.Text.body(isActive ? .medium : .regular), .foregroundColor: NSColor.black])
        text.truncationMode = .end
        text.contentsScale = backingScale
        text.frame = CGRect(origin: .zero, size: workingTextRect.size)
        let band = CAGradientLayer()
        band.frame = workingTextRect
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
        let light = NSColor.labelColor.cgColor
        band.colors = [NSColor.clear.cgColor, light, NSColor.clear.cgColor]
        band.locations = [0.4, 0.5, 0.6]
        band.mask = text
        guard !reduce else { return [band] }
        let sweep = CABasicAnimation(keyPath: "locations")
        sweep.fromValue = [-0.3, -0.15, 0]
        sweep.toValue = [1, 1.15, 1.3]
        sweep.duration = 1.6
        sweep.repeatCount = .infinity
        Self.inStep(sweep)
        band.add(sweep, forKey: "shimmer")
        return [band]
    }

    /// Its shortcut ("⌘2") while the modifier is held (`TabShortcutHints`): it fades in over
    /// the trailing slot as the × or ring there fades out, and back (the owner, 2026-11-04: they
    /// popped in).
    var shortcutHint: String? {
        didSet {
            guard shortcutHint != oldValue else { return }
            if let shortcutHint { hintLabel.stringValue = shortcutHint }
            let showing = shortcutHint != nil
            if showing { hintLabel.isHidden = false }
            needsDisplay = true
            DS.Motion.fade(duration: DS.Motion.fadeDuration, {
                hintLabel.animator().alphaValue = showing ? 1 : 0
                closeButton?.animator().alphaValue = showing ? 0 : 1
            }, completion: { [weak self] in
                guard let self, self.shortcutHint == nil else { return }
                self.hintLabel.isHidden = true
            })
        }
    }
    var isShowingHintForTesting: Bool { !hintLabel.isHidden }
    private lazy var hintLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = DS.Text.caption(.medium)
        label.textColor = .secondaryLabelColor
        label.alphaValue = 0
        label.isHidden = true
        label.wantsLayer = true
        label.setAccessibilityElement(false)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: trailingAnchor, constant: -(5 + Self.flare + 8)),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        return label
    }()
    /// For the card a dragged-out tab becomes: its icon, and what it shows.
    /// The file's icon, or the Terminal's glyph: before the title, and in the card a dragged-out
    /// tab becomes. While an agent works, the Working ring takes its place.
    var dragIcon: NSImage? {
        didSet {
            guard dragIcon !== oldValue else { return }
            iconView.image = dragIcon
            iconView.isHidden = dragIcon == nil
            if (dragIcon == nil) != (oldValue == nil) { invalidateIntrinsicContentSize(); needsDisplay = true }
        }
    }
    private lazy var iconView: NSImageView = {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.contentTintColor = .secondaryLabelColor
        view.symbolConfiguration = .init(pointSize: 11, weight: .medium)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setAccessibilityElement(false)
        addSubview(view)
        NSLayoutConstraint.activate([
            view.centerXAnchor.constraint(equalTo: leadingAnchor, constant: Self.iconCenterX),
            view.centerYAnchor.constraint(equalTo: centerYAnchor),
            view.widthAnchor.constraint(equalToConstant: Self.iconSize),
            view.heightAnchor.constraint(equalToConstant: Self.iconSize),
        ])
        return view
    }()
    private static let iconSize: CGFloat = 14
    static var iconCenterX: CGFloat { flare + 10 + iconSize / 2 }
    /// Where the title starts: after the icon when there is one.
    private var textX: CGFloat { Self.textX(hasIcon: dragIcon != nil) }
    static func textX(hasIcon: Bool) -> CGFloat { hasIcon ? flare + 10 + iconSize + 6 : flare + textInset }
    var dragPreview: (() -> NSImage?)?
    /// Holds the slot closed while the tab is torn out of the strip.
    fileprivate var slotWidth: NSLayoutConstraint?

    private static let textInset: CGFloat = 12
    private static let trailingReserve: CGFloat = 26
    private static let maxTextWidth: CGFloat = 200
    /// A capsule inside the strip's 30 pt glass track.
    static let height: CGFloat = 24
    private static let minWidth: CGFloat = 96
    /// Margin on each side, reserved on every chip so activating one never changes its width.
    static let flare: CGFloat = 4

    private var trackingArea: NSTrackingArea?
    private(set) var isHovered = false { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Drawn when asked, never stretched or redrawn per frame by an animation: a resize asks
        // (`setFrameSize`), so what's drawn always matches the size it ends at.
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    /// In the title-bar region AppKit moves the window for any transparent view that doesn't
    /// say otherwise, which swallowed every tab drag once the tabs moved up there.
    override var mouseDownCanMoveWindow: Bool { false }

    /// Measured at the heavier weight whatever the state, so selecting a tab never changes its
    /// width: the whole strip used to shuffle by a few points on every click.
    override var intrinsicContentSize: NSSize {
        let font = DS.Text.body(.medium)
        let textWidth = min(Self.label(title: title, detail: detail, attributes: [.font: font]).size().width, Self.maxTextWidth)
        return NSSize(width: max(Self.minWidth, textWidth + (textX - Self.flare) + Self.trailingReserve + Self.flare * 2), height: Self.height)
    }

    /// The title, then the detail in a quieter color.
    static func label(title: String, detail: String, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let label = NSMutableAttributedString(string: title, attributes: attributes)
        guard !detail.isEmpty else { return label }
        var quiet = attributes
        quiet[.foregroundColor] = NSColor.tertiaryLabelColor
        quiet[.font] = DS.Text.caption()
        label.append(NSAttributedString(string: "  " + detail, attributes: quiet))
        return label
    }

    /// The active tab is always in view: in an overflowing strip it's scrolled to, after layout
    /// has placed it (a new chip has no frame yet).
    private func revealWhenLaidOut() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isActive, self.window != nil else { return }
                self.scrollToVisible(self.bounds.insetBy(dx: -16, dy: 0))
            }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if isActive { revealWhenLaidOut() }
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        strip?.chipFrameChanged(self)
    }

    /// Redrawn at every new size: a new tab is first drawn at no width, where its title is
    /// skipped, and as it grew the title never came until a click or a drag redrew it (the owner,
    /// 2026-10-31).
    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { needsDisplay = true }
        strip?.chipFrameChanged(self)
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        setWindowMovable(false)
        updateCloseVisibility()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        if phase == .idle { window?.isMovable = true }
        updateCloseVisibility()
    }

    /// The strip scrolled under a still pointer (`TabStripScrollView`).
    func syncHover(pointerInWindow pointer: NSPoint) {
        // Its own bounds, as shown: `visibleRect` alone can reach past them, over the next tab.
        let inside = bounds.intersection(visibleRect).contains(convert(pointer, from: nil))
        guard inside != isHovered else { return }
        isHovered = inside
        if inside { setWindowMovable(false) } else if phase == .idle { window?.isMovable = true }
        updateCloseVisibility()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        // A chip removed while hovered (closed, strip rebuilt) must not leave the window stuck.
        if isHovered { window?.isMovable = true }
        super.viewWillMove(toWindow: newWindow)
    }

    /// The active tab always offers its ×; others on hover. A dirty or working tab shows its
    /// dot or ring there instead until hovered.
    func updateCloseVisibility() {
        closeButton?.isHidden = renameField != nil || !(isHovered || (isActive && !isDirty))
    }

    /// In the title-bar strip the window server decides a press is a window drag before any view
    /// sees it, so the window is unmovable only while the pointer is over a tab. Never left off:
    /// an unmovable window also refuses window managers and tiling.
    private func setWindowMovable(_ movable: Bool) {
        guard phase == .idle || !movable else { return }
        window?.isMovable = movable
    }

    // MARK: Drawing

    /// The width it was last drawn at (tests).
    private(set) var lastDrawnWidthForTesting: CGFloat = 0

    override func draw(_ dirtyRect: NSRect) {
        lastDrawnWidthForTesting = bounds.width
        guard bounds.width > Self.flare * 2 + 16, bounds.height > 4 else { return }
        // A capsule on the strip's glass, drawn like the stage control's selection: the active
        // tab is the soft selected capsule, the rest are the glass itself until hovered.
        let body = bounds.insetBy(dx: Self.flare - 2, dy: 0)
        let pill = NSBezierPath(roundedRect: body, xRadius: body.height / 2, yRadius: body.height / 2)
        if drawsLifted {
            // The floating layer draws the shadow, from the capsule's own shape.
            DS.Color.raised.setFill()
            pill.fill()
        } else if isActive {
            // The strip's sliding tint is under it (`TabStrip.selection`).
        } else if isHovered || phase == .pressed {
            (phase == .pressed ? DS.Color.scrimMedium : DS.Color.scrimSoft).setFill()
            pill.fill()
        }

        if renameField == nil, !drawsLifted {
            // Under the shimmer the title sits a step quieter, so the band of light reads.
            let shimmering = isWorking
            // The quieter colors carry their own transparency: `withAlphaComponent(1)` replaced
            // it, and every inactive title drew as dark as the active one (found 2026-11-04).
            let tone: NSColor = shimmering ? .tertiaryLabelColor : isActive || drawsLifted ? .labelColor : .secondaryLabelColor
            let attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: isDead ? tone.withAlphaComponent(0.35) : tone,
                .font: DS.Text.body(isActive || drawsLifted ? .medium : .regular),
            ]
            let text = Self.label(title: title, detail: detail, attributes: attributes)
            let size = text.size()
            let maxWidth = max(0, bounds.width - textX - Self.trailingReserve - Self.flare)
            let drawRect = NSRect(x: textX, y: (bounds.height - size.height) / 2, width: min(size.width, maxWidth) + 1, height: size.height)
            text.draw(with: drawRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            if isWorking, drawRect != workingTextRect {
                workingTextRect = drawRect
                DispatchQueue.main.async { [weak self] in self?.updateWorkingIndicator() }
            }
        }

        // Unsaved edits and unseen output are marks, not states (Direction 03 §3.1): one quiet
        // 5 pt dot in the trailing slot, where the close button goes, until hover swaps it for ×.
        // News is the same dot in its state's color, a little larger: a turn that finished out
        // of sight read the same as any output (the owner, 2026-11-04: "no clear completion
        // indicator").
        // Working, the indicator says it: output while it works is no news.
        if shortcutHint == nil, (isDirty || (hasUnseenOutput && !isWorking) || news != nil) && !isHovered && !drawsLifted && closeButton?.isHidden != false {
            (news?.color ?? NSColor.secondaryLabelColor).setFill()
            let dotSize: CGFloat = news == nil ? 5 : 7
            let x = bounds.width - Self.flare - 5 - 8 - dotSize / 2
            NSBezierPath(ovalIn: NSRect(x: x, y: (bounds.height - dotSize) / 2, width: dotSize, height: dotSize)).fill()
        }
    }

    /// Drawn as it looks lifted, for the floating layer's picture of it.
    private var drawsLifted = false

    /// The chip as it looks lifted: a solid capsule, no shadow and no title (the floating layer
    /// adds both: the title as a layer of its own, which travels into the card).
    func liftedImage() -> NSImage {
        drawsLifted = true
        defer { drawsLifted = false; needsDisplay = true }
        let wasHidden = closeButton?.isHidden ?? true
        closeButton?.isHidden = true
        // The floating layer adds the title and the card its icon: the chip is only its capsule.
        let iconWasHidden = iconView.isHidden
        iconView.isHidden = true
        workingLayers.forEach { $0.isHidden = true }
        defer { closeButton?.isHidden = wasHidden; iconView.isHidden = iconWasHidden; workingLayers.forEach { $0.isHidden = false } }
        let image = NSImage(size: bounds.size)
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
            effectiveAppearance.performAsCurrentDrawingAppearance { cacheDisplay(in: bounds, to: rep) }
            image.addRepresentation(rep)
        }
        return image
    }

    // MARK: Drag (§4.2)

    enum Phase { case idle, pressed, lifted, torn }
    private(set) var phase: Phase = .idle { didSet { if phase != oldValue { needsDisplay = true } } }
    private var pressPoint = NSPoint.zero
    /// Where in the chip it was grabbed, so it stays under the pointer at that spot.
    private var grabOffset = NSPoint.zero
    private var startIndex = 0
    private var overlay: TabDragOverlay?
    private var escapeMonitor: Any?
    private var lastSamples: [(point: NSPoint, time: TimeInterval)] = []

    /// How far the pointer moves before a press becomes a drag: in any direction, so a pull
    /// straight down tears a tab out (it used to need sideways movement first).
    static let liftDistance: CGFloat = 3
    /// Past the strip's edge by this much, measured from the strip, the tab tears out.
    static let tearDistance: CGFloat = 24
    /// How far a pull along the strip's edge stretches before it breaks free.
    private static let stretch: CGFloat = 12

    override func mouseDown(with event: NSEvent) {
        guard renameField == nil else { return }
        window?.isMovable = false
        pressPoint = event.locationInWindow
        let local = convert(event.locationInWindow, from: nil)
        grabOffset = NSPoint(x: local.x, y: local.y)
        lastSamples = [(screenPoint(of: event), event.timestamp)]
        phase = .pressed
    }

    override func mouseDragged(with event: NSEvent) {
        guard phase != .idle else { return }
        let point = event.locationInWindow
        let screen = screenPoint(of: event)
        lastSamples.append((screen, event.timestamp))
        if lastSamples.count > 4 { lastSamples.removeFirst() }
        if phase == .pressed {
            guard hypot(point.x - pressPoint.x, point.y - pressPoint.y) > Self.liftDistance else { return }
            lift()
        }
        guard let strip, let band = stripFrameInWindow() else { return }
        let outsideBand = point.y > band.maxY + Self.tearDistance || point.y < band.minY - Self.tearDistance
        switch phase {
        case .lifted where outsideBand && strip.canTearOut:
            phase = .torn
            strip.collapseSlot(of: self)
            overlay?.becomeCard(at: screen, outsideWindow: !(window?.frame.contains(screen) ?? true))
        case .torn where !outsideBand && band.insetBy(dx: -Self.tearDistance, dy: 0).contains(NSPoint(x: point.x, y: band.midY)):
            phase = .lifted
            strip.reopenSlot(of: self, atWindowX: point.x)
            overlay?.becomeChip(frame: liftedFrame(pointerInWindow: point, band: band))
        case .torn:
            overlay?.follow(screen, outsideWindow: !(window?.frame.contains(screen) ?? true))
        default:
            strip.chipMoved(self, toWindowX: point.x)
            overlay?.place(chipFrame: liftedFrame(pointerInWindow: point, band: band))
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { if !isHovered { window?.isMovable = true } }
        switch phase {
        case .idle:
            return
        case .pressed:
            phase = .idle
            if event.clickCount == 2, strip?.canRename == true { beginRename() } else if event.clickCount == 1 { strip?.chipSelected(self) }
        case .lifted:
            setDown(velocity: velocity())
        case .torn:
            let screen = screenPoint(of: event)
            if let window, !window.frame.contains(screen) {
                land(at: screen)
            } else {
                returnHome(to: nil)
            }
        }
    }

    /// The event's place on screen: a drag keeps reporting it past the window's edge.
    private func screenPoint(of event: NSEvent) -> NSPoint {
        window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
    }

    private func lift() {
        phase = .lifted
        startIndex = index
        guard let window else { return }
        let image = liftedImage()
        let content = dragPreview?()
        let card = TabDragOverlay.cardSize(for: window.frame.size, outside: true)
        let windowImage = content.map { Self.miniWindow(content: $0, size: card) }
        let frame = window.convertToScreen(convert(bounds, to: nil))
        let overlay = TabDragOverlay(chip: image, title: titleImage(), icon: cardIcon(), card: windowImage, sourceWindow: window, chipFrame: frame,
                                     grab: NSPoint(x: grabOffset.x / max(1, bounds.width), y: grabOffset.y),
                                     chipTitleX: textX, chipIconCenterX: Self.iconCenterX)
        overlay.show()
        self.overlay = overlay
        alphaValue = 0
        strip?.chipLifted(self)
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self, self.phase == .lifted || self.phase == .torn else { return event }
            self.returnHome(to: self.startIndex)
            return nil
        }
    }

    /// Where the lifted chip sits: along the strip under the pointer at the grab point, held to
    /// the glass track, and stretching toward the pointer across the strip's edge.
    private func liftedFrame(pointerInWindow point: NSPoint, band: NSRect) -> NSRect {
        guard let window else { return .zero }
        let track = band.insetBy(dx: 3, dy: 0)
        let x = min(max(point.x - grabOffset.x, track.minX), track.maxX - bounds.width)
        let natural = convert(bounds, to: nil)
        let pull = point.y - pressPoint.y
        let stretched = (pull < 0 ? -1 : 1) * Self.stretch * (1 - 1 / (abs(pull) / Self.stretch + 1))
        return window.convertToScreen(NSRect(x: x, y: natural.minY + stretched, width: bounds.width, height: bounds.height))
    }

    private func stripFrameInWindow() -> NSRect? {
        guard let bar = strip?.bar else { return nil }
        return bar.convert(bar.bounds, to: nil)
    }

    /// Points per second over the last few events, for the settle to carry.
    private func velocity() -> CGVector {
        guard let first = lastSamples.first, let last = lastSamples.last, last.time > first.time else { return .zero }
        let dt = last.time - first.time
        return CGVector(dx: (last.point.x - first.point.x) / dt, dy: (last.point.y - first.point.y) / dt)
    }

    private func slotFrameOnScreen() -> NSRect {
        strip?.bar.layoutSubtreeIfNeeded()
        guard let window else { return .zero }
        return window.convertToScreen(convert(bounds, to: nil))
    }

    /// Released in the strip: it settles into its slot, carrying the hand's speed.
    private func setDown(velocity: CGVector) {
        phase = .idle
        removeEscapeMonitor()
        let overlay = self.overlay
        self.overlay = nil
        overlay?.settle(into: slotFrameOnScreen(), velocity: velocity) { [weak self] in
            guard let self else { return }
            self.alphaValue = 1
            overlay?.handOver()
            self.strip?.chipSettled(self)
        }
        strip?.chipSetDown(self)
    }

    /// Back to its slot: dropped in the window off the strip, or Escape (to where it started).
    private func returnHome(to index: Int?) {
        guard let strip else { return }
        let wasTorn = phase == .torn
        phase = .idle
        removeEscapeMonitor()
        if let index { strip.chipReturned(self, to: index) }
        if wasTorn { strip.reopenSlot(of: self, atWindowX: convert(NSPoint(x: bounds.midX, y: 0), to: nil).x) }
        // After the slot opens: the settle aims at where it ends up.
        DispatchQueue.main.asyncAfter(deadline: .now() + (wasTorn ? DS.Motion.snappy.duration * 0.6 : 0)) { [weak self] in
            guard let self else { return }
            let overlay = self.overlay
            self.overlay = nil
            overlay?.settle(into: self.slotFrameOnScreen(), velocity: .zero) { [weak self] in
                guard let self else { return }
                self.alphaValue = 1
                overlay?.handOver()
                self.strip?.chipSettled(self)
            }
            strip.chipSetDown(self)
        }
    }

    /// Released outside the window: the tab becomes a window there, and the card grows into it.
    private func land(at screenPoint: NSPoint) {
        phase = .idle
        removeEscapeMonitor()
        let overlay = self.overlay
        self.overlay = nil
        overlay?.landInNewWindow(from: window)
        strip?.chipTornOut(self, at: overlay?.windowTopLeft(for: screenPoint) ?? screenPoint)
        // Still here once the landing gave up: no window came, and the tab goes home.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            guard let self, self.superview != nil else { return }
            self.strip?.chipStayed(self)
        }
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }

    // MARK: Rename (§4.3)

    private var renameField: NSTextField?

    func beginRename() {
        guard renameField == nil else { return }
        let field = NSTextField(string: title)
        field.font = DS.Text.body(.medium)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.delegate = self
        let x = textX
        field.frame = NSRect(x: x - 2, y: (bounds.height - 18) / 2, width: bounds.width - x - Self.flare - 6, height: 18)
        addSubview(field)
        renameField = field
        updateCloseVisibility()
        needsDisplay = true
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    fileprivate func endRename(commit: Bool) {
        guard let field = renameField else { return }
        renameField = nil
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.removeFromSuperview()
        updateCloseVisibility()
        needsDisplay = true
        if commit { strip?.chipRenamed(self, to: name.isEmpty ? nil : name) }
    }

    // MARK: The card's picture

    /// The card's picture: the tab's content at its whole width, from its top (cropping it to
    /// cover the card cut off its right side, 2026-10-31), its own background carrying on below
    /// short content. The title bar above it is the card's (`TabDragOverlay`).
    static func miniWindow(content: NSImage, size: NSSize) -> NSImage {
        let body = NSSize(width: size.width, height: max(1, size.height - TabDragOverlay.titleBarHeight))
        return NSImage(size: body, flipped: false) { rect in
            DS.Color.raised.setFill()
            rect.fill()
            if let rep = content.representations.first as? NSBitmapImageRep ?? content.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)),
               let below = rep.colorAt(x: 2, y: rep.pixelsHigh - 2) {
                below.setFill()
                rect.fill()
            }
            let scale = rect.width / max(1, content.size.width)
            let sourceHeight = min(content.size.height, rect.height / scale)
            content.draw(in: NSRect(x: 0, y: rect.maxY - sourceHeight * scale, width: rect.width, height: sourceHeight * scale),
                         from: NSRect(x: 0, y: content.size.height - sourceHeight, width: content.size.width, height: sourceHeight),
                         operation: .sourceOver, fraction: 1)
            return true
        }
    }

    /// The title alone, as the chip draws it lifted: the layer that travels into the card.
    func titleImage() -> NSImage {
        let attributes: [NSAttributedString.Key: Any] = [.font: DS.Text.body(.medium), .foregroundColor: NSColor.labelColor]
        let text = Self.label(title: title, detail: "", attributes: attributes)
        let size = NSSize(width: ceil(min(text.size().width, Self.maxTextWidth)) + 1, height: ceil(text.size().height))
        return Self.drawnNow(size: size, appearance: effectiveAppearance) {
            text.draw(with: NSRect(origin: .zero, size: size), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    /// The icon for the card's title bar: a symbol (Run's terminal) is a template, tinted to
    /// read as the title does, or it draws black in dark.
    func cardIcon() -> NSImage? {
        guard let icon = dragIcon else { return nil }
        guard icon.isTemplate else { return icon }
        let size = NSSize(width: 14, height: 14)
        return Self.drawnNow(size: size, appearance: effectiveAppearance) {
            icon.draw(in: NSRect(origin: .zero, size: size))
            NSColor.secondaryLabelColor.set()
            NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
        }
    }

    /// Drawn at once, in `appearance`: an image's drawing handler would run later, in whatever
    /// appearance is current then, and a layer's contents never redraw.
    private static func drawnNow(size: NSSize, appearance: NSAppearance, _ draw: () -> Void) -> NSImage {
        let image = NSImage(size: size)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return image }
        rep.size = size
        appearance.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            draw()
            NSGraphicsContext.restoreGraphicsState()
        }
        image.addRepresentation(rep)
        return image
    }

    // MARK: Accessibility

    // Hand-drawn: a tab is a radio button inside its strip's tab group, and says whether it's
    // the selected one.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .radioButton }
    override func accessibilityLabel() -> String? {
        var parts = [title]
        if !detail.isEmpty { parts.append(detail) }
        if isDirty { parts.append("unsaved") }
        if isWorking { parts.append("working") }
        switch news {
        case .verified?: parts.append("finished")
        case .needsYou?: parts.append("needs you")
        default: if hasUnseenOutput { parts.append("new output") }
        }
        return parts.joined(separator: ", ")
    }
    override func accessibilityValue() -> Any? { isActive ? 1 : 0 }
    override func accessibilityPerformPress() -> Bool {
        strip?.chipSelected(self)
        return true
    }
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard strip?.canRename == true else { return nil }
        return [NSAccessibilityCustomAction(name: "Rename") { [weak self] in self?.beginRename(); return true }]
    }

    // MARK: Tests

    /// The drag, by its steps, for tests: points are in the window.
    func pressForTesting(at point: NSPoint) {
        pressPoint = point
        grabOffset = convert(point, from: nil)
        phase = .pressed
    }
    var overlayForTesting: TabDragOverlay? { overlay }
}

extension TabChipView: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) { endRename(commit: false); return true }
        if selector == #selector(NSResponder.insertNewline(_:)) { endRename(commit: true); return true }
        return false
    }

    func controlTextDidEndEditing(_ notification: Notification) { endRename(commit: true) }
}

// MARK: - The floating layer

/// What a dragged tab is while it's held (§4.2): one layer, over everything, that is the chip
/// along the strip and becomes the card past it, the same layer throughout. It lives in a clear
/// panel the size of the screen, so neither the strip's clipping nor the window's edge cuts it
/// or its shadow.
@MainActor
final class TabDragOverlay {
    private let panel: NSPanel
    private let card = CALayer()
    private let chipLayer = CALayer()
    private let cardLayer = CALayer()
    /// The tab's title, one layer that travels from its place in the tab to the card's title
    /// bar, so the card grows out of the tab rather than fading in a second label (the owner,
    /// 2026-10-31, as Rex does).
    private let titleLayer = CALayer()
    private let iconLayer = CALayer()
    /// Under the card's title bar.
    private let hairline = CALayer()
    /// The card's rounded shape, clipping what's in it; the card itself keeps the shadow,
    /// which a clipping layer would cut off.
    private let clip = CALayer()
    private let titleSize: NSSize
    private let chipSize: NSSize
    private let hasCard: Bool
    /// Where the chip draws its title and icon, so the lifted chip shows both where the tab
    /// does: without them the icon blinked back and the title jumped at the drop (the owner,
    /// 2026-11-04).
    private let chipTitleX: CGFloat
    private let chipIconCenterX: CGFloat
    private let hasIcon: Bool
    private weak var sourceWindow: NSWindow?
    /// Where the pointer holds it, as a fraction across and points down from the top.
    private let grab: NSPoint
    private(set) var isCard = false
    private(set) var isOutside = false

    /// The card: the window's proportions at a third of its size, 340 to 500 pt wide, big as
    /// Rex's is without crowding the window (the owner, 2026-10-30 and 10-31); outside the window
    /// it grows to 42%, toward the window it will become.
    static func cardSize(for windowSize: NSSize, outside: Bool) -> NSSize {
        let scale: CGFloat = outside ? 0.42 : 0.34
        let width = min(max(windowSize.width * scale, outside ? 420 : 340), outside ? 620 : 500)
        let aspect = windowSize.height / max(1, windowSize.width)
        return NSSize(width: width.rounded(), height: (width * aspect).rounded())
    }

    /// The card's title bar, where the title lands.
    /// Tall enough to leave room under the title (the owner, 2026-10-31).
    static let titleBarHeight: CGFloat = 36
    /// Where the title sits in the chip: its text inset.
    static let chipTitleInset: CGFloat = 16

    init(chip: NSImage, title: NSImage, icon: NSImage?, card cardImage: NSImage?, sourceWindow: NSWindow, chipFrame: NSRect, grab: NSPoint,
         chipTitleX: CGFloat = TabDragOverlay.chipTitleInset, chipIconCenterX: CGFloat = 0) {
        chipSize = chipFrame.size
        self.chipTitleX = chipTitleX
        self.chipIconCenterX = chipIconCenterX
        hasIcon = icon != nil
        titleSize = title.size
        hasCard = cardImage != nil
        self.sourceWindow = sourceWindow
        self.grab = grab
        let screen = sourceWindow.screen ?? NSScreen.main ?? NSScreen.screens[0]
        panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.appearance = sourceWindow.effectiveAppearance
        let content = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        content.wantsLayer = true
        panel.contentView = content
        let raised = Self.resolved(DS.Color.raised, in: sourceWindow.effectiveAppearance)
        card.backgroundColor = raised
        card.shadowColor = NSColor.black.cgColor
        clip.masksToBounds = true
        card.addSublayer(clip)
        for layer in [chipLayer, cardLayer] {
            layer.contentsScale = sourceWindow.backingScaleFactor
            clip.addSublayer(layer)
        }
        chipLayer.contents = chip
        chipLayer.contentsGravity = .center
        cardLayer.contents = cardImage
        cardLayer.contentsGravity = .resizeAspectFill
        cardLayer.opacity = 0
        hairline.backgroundColor = Self.resolved(DS.Color.hairline, in: sourceWindow.effectiveAppearance)
        hairline.opacity = 0
        clip.addSublayer(hairline)
        titleLayer.contents = title
        titleLayer.contentsScale = sourceWindow.backingScaleFactor
        titleLayer.bounds = CGRect(origin: .zero, size: title.size)
        card.addSublayer(titleLayer)
        iconLayer.contents = icon
        iconLayer.contentsScale = sourceWindow.backingScaleFactor
        iconLayer.bounds = CGRect(x: 0, y: 0, width: 14, height: 14)
        // In the chip and in the card alike: it travels from one place to the other.
        iconLayer.opacity = icon == nil ? 0 : 1
        card.addSublayer(iconLayer)
        content.layer?.addSublayer(card)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        apply(frame: local(chipFrame), radius: chipFrame.height / 2, chip: true)
        CATransaction.commit()
    }

    private static func resolved(_ color: NSColor, in appearance: NSAppearance) -> CGColor {
        var out = color.cgColor
        appearance.performAsCurrentDrawingAppearance { out = color.cgColor }
        return out
    }

    func show() { panel.orderFrontRegardless() }
    func close() { panel.orderOut(nil) }

    private func local(_ screenRect: NSRect) -> NSRect {
        screenRect.offsetBy(dx: -panel.frame.minX, dy: -panel.frame.minY)
    }

    /// The card's frame with the pointer at its grab point: across at the same fraction, down in
    /// its title bar.
    private func cardFrame(at pointer: NSPoint, outside: Bool) -> NSRect {
        let size = Self.cardSize(for: sourceWindow?.frame.size ?? NSSize(width: 1000, height: 700), outside: outside)
        return NSRect(x: pointer.x - size.width * grab.x, y: pointer.y - size.height + 14, width: size.width, height: size.height)
    }

    /// The top-left a new window should take for the card under `pointer` to grow into it.
    func windowTopLeft(for pointer: NSPoint) -> NSPoint {
        guard let size = sourceWindow?.frame.size else { return pointer }
        return NSPoint(x: pointer.x - size.width * grab.x, y: pointer.y + 14)
    }

    /// Sets the card's look for a frame, springing from what's on screen when `spring` is given.
    /// Position and size move additively, so following the pointer mid-spring stays continuous:
    /// the offset decays while the target keeps moving.
    private func apply(frame: NSRect, radius: CGFloat, chip: Bool, spring: DS.Motion.Spring? = nil, velocity: CGVector = .zero) {
        let size = frame.size
        // The card's title bar is the card's own surface with a hairline under it, drawn by
        // layers rather than baked into the picture: scaled with the picture, the bar shrank
        // under a title placed for its full height (the owner, 2026-10-31: uneven above and below).
        let bar = Self.titleBarHeight
        let titleAt = titlePosition(in: size, chip: chip)
        let targets: [(CALayer, CGRect)] = [
            (card, CGRect(x: frame.minX, y: frame.minY, width: size.width, height: size.height)),
            (clip, CGRect(origin: .zero, size: size)),
            (chipLayer, CGRect(origin: .zero, size: size)),
            (cardLayer, CGRect(x: 0, y: 0, width: size.width, height: max(0, size.height - bar))),
            (hairline, CGRect(x: 0, y: max(0, size.height - bar), width: size.width, height: 1)),
            (titleLayer, CGRect(x: titleAt.x - titleSize.width / 2, y: titleAt.y - titleSize.height / 2, width: titleSize.width, height: titleSize.height)),
            (iconLayer, chip || !hasCard
                ? CGRect(x: chipIconCenterX - 7, y: size.height / 2 - 7, width: 14, height: 14)
                : CGRect(x: titleAt.x - titleSize.width / 2 - 20, y: titleAt.y - 7, width: 14, height: 14)),
        ]
        // What's on screen now, for the spring to start from.
        let shown = targets.map { layer, _ in ((layer.presentation() ?? layer).position, (layer.presentation() ?? layer).bounds.size) }
        let fromRadius = (card.presentation() ?? card).cornerRadius
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (layer, target) in targets {
            layer.bounds = CGRect(origin: .zero, size: target.size)
            layer.position = CGPoint(x: target.midX, y: target.midY)
        }
        for layer in [card, clip] { layer.cornerRadius = radius }
        // A pill casts a small, close shadow; a card a deeper one.
        card.shadowOpacity = chip ? 0.18 : 0.3
        card.shadowRadius = chip ? 5 : 18
        card.shadowOffset = CGSize(width: 0, height: chip ? -2 : -8)
        CATransaction.commit()
        guard let spring, !DS.Motion.reduceMotion else { return }
        // Additive: each layer's offset from its new place decays, so following the pointer
        // mid-spring stays continuous.
        for ((layer, _), (fromPosition, fromSize)) in zip(targets, shown) {
            let dx = fromPosition.x - layer.position.x, dy = fromPosition.y - layer.position.y
            let move = layer === card
                ? DS.Motion.spring(spring, keyPath: "position", velocity: hypot(velocity.dx, velocity.dy), distance: hypot(dx, dy))
                : DS.Motion.spring(spring, keyPath: "position")
            move.isAdditive = true
            move.fromValue = NSValue(point: NSPoint(x: dx, y: dy))
            move.toValue = NSValue(point: .zero)
            layer.add(move, forKey: nil)
            let grow = DS.Motion.spring(spring, keyPath: "bounds.size")
            grow.isAdditive = true
            grow.fromValue = NSValue(size: NSSize(width: fromSize.width - layer.bounds.width, height: fromSize.height - layer.bounds.height))
            grow.toValue = NSValue(size: .zero)
            layer.add(grow, forKey: nil)
        }
        for layer in [card, clip] {
            let corner = DS.Motion.spring(spring, keyPath: "cornerRadius")
            corner.fromValue = fromRadius
            corner.toValue = radius
            layer.add(corner, forKey: "corner")
        }
    }

    /// The title's centre in the card's own coordinates (origin bottom-left): at its inset in
    /// the chip, centred in the card's title bar beside the icon.
    private func titlePosition(in size: NSSize, chip: Bool) -> CGPoint {
        if chip || !hasCard {
            return CGPoint(x: chipTitleX + titleSize.width / 2, y: size.height / 2)
        }
        return CGPoint(x: size.width / 2 + 10, y: size.height - Self.titleBarHeight / 2)
    }

    private func crossfade(toCard: Bool) {
        let fade = { (layer: CALayer, to: Float) in
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = (layer.presentation() ?? layer).opacity
            animation.toValue = to
            animation.duration = DS.Motion.fadeDuration
            animation.timingFunction = DS.Motion.fadeCurve
            layer.opacity = to
            layer.add(animation, forKey: "fade")
        }
        fade(chipLayer, toCard ? 0 : 1)
        fade(cardLayer, toCard && hasCard ? 1 : 0)
        fade(hairline, toCard && hasCard ? 1 : 0)
    }

    /// Along the strip: exactly where the chip is held, no spring.
    func place(chipFrame: NSRect) {
        guard !isCard else { return }
        apply(frame: local(chipFrame), radius: chipFrame.height / 2, chip: true)
    }

    /// Past the strip: one spring from the chip into the card under the pointer.
    func becomeCard(at pointer: NSPoint, outsideWindow: Bool) {
        isCard = true
        isOutside = outsideWindow
        guard hasCard else { follow(pointer, outsideWindow: outsideWindow); return }
        crossfade(toCard: true)
        apply(frame: local(cardFrame(at: pointer, outside: outsideWindow)), radius: DS.Radius.surface, chip: false, spring: DS.Motion.smooth)
    }

    /// Back over the strip: the card springs back into the chip.
    func becomeChip(frame: NSRect) {
        isCard = false
        crossfade(toCard: false)
        apply(frame: local(frame), radius: frame.height / 2, chip: true, spring: DS.Motion.smooth)
    }

    /// Free of the strip, the card stays under the pointer; leaving the window it grows a little
    /// toward the window it would become.
    func follow(_ pointer: NSPoint, outsideWindow: Bool) {
        if !hasCard {
            // No picture to show (an empty tab): the chip itself follows.
            let frame = NSRect(x: pointer.x - chipSize.width * grab.x, y: pointer.y - chipSize.height / 2, width: chipSize.width, height: chipSize.height)
            apply(frame: local(frame), radius: chipSize.height / 2, chip: true)
            return
        }
        let grew = outsideWindow != isOutside
        isOutside = outsideWindow
        apply(frame: local(cardFrame(at: pointer, outside: outsideWindow)), radius: DS.Radius.surface, chip: false, spring: grew ? DS.Motion.smooth : nil)
    }

    /// Set down: springs into the slot as a chip, carrying the hand's speed.
    func settle(into screenFrame: NSRect, velocity: CGVector, completion: @escaping () -> Void) {
        if isCard {
            isCard = false
            crossfade(toCard: false)
        }
        apply(frame: local(screenFrame), radius: screenFrame.height / 2, chip: true, spring: DS.Motion.snappy, velocity: velocity)
        // Coming to rest it lies flat: the shadow goes on the way in, not at the hand-over.
        let flatten = CABasicAnimation(keyPath: "shadowOpacity")
        flatten.fromValue = (card.presentation() ?? card).shadowOpacity
        flatten.toValue = 0
        flatten.duration = DS.Motion.reduceMotion ? 0 : DS.Motion.snappy.duration
        flatten.timingFunction = DS.Motion.fadeCurve
        card.shadowOpacity = 0
        card.add(flatten, forKey: "flatten")
        DispatchQueue.main.asyncAfter(deadline: .now() + (DS.Motion.reduceMotion ? 0 : DS.Motion.snappy.duration), execute: completion)
    }

    /// Settled, with the tab showing again under it: the lifted capsule fades into the tab
    /// rather than giving way in one frame, where its solid fill and the tab's own look
    /// differed (the owner, 2026-11-04: "an instant change when I release it").
    static let handOverDuration: TimeInterval = 0.12

    func handOver() {
        Self.landing.append(self)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [self] in
            MainActor.assumeIsolated {
                panel.orderOut(nil)
                Self.landing.removeAll { $0 === self }
            }
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = (card.presentation() ?? card).opacity
        fade.toValue = 0
        fade.duration = DS.Motion.reduceMotion ? 0.01 : Self.handOverDuration
        fade.timingFunction = DS.Motion.fadeCurve
        card.opacity = 0
        card.add(fade, forKey: "fade")
        CATransaction.commit()
    }

    /// Dropped outside the window: the card grows into the new window as it opens, then gives
    /// way to it. If no window comes (the tab couldn't close), the card fades where it is.
    func landInNewWindow(from source: NSWindow?) {
        // Held until it has faded and closed its panel: the tab lets go of it at the drop, and
        // with only weak references left the overlay went away mid-landing and its panel stayed
        // over every app (the owner, 2026-10-31).
        Self.landing.append(self)
        landingSource = source
        landingObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.windowBecameKey() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.finishLanding() }
    }

    private static var landing: [TabDragOverlay] = []
    private var landingObserver: NSObjectProtocol?
    private weak var landingSource: NSWindow?
    private var landed = false

    private func windowBecameKey() {
        guard !landed, let window = NSApp.keyWindow, window !== landingSource, window !== panel,
              window.contentViewController is ShellViewController else { return }
        landed = true
        stopWatchingForLanding()
        apply(frame: local(window.frame), radius: DS.Radius.surface, chip: false, spring: DS.Motion.smooth)
        DispatchQueue.main.asyncAfter(deadline: .now() + DS.Motion.smooth.duration * 0.8) { [weak self] in self?.fadeAway() }
    }

    /// No window came (the tab couldn't close): the card fades where it is.
    private func finishLanding() {
        stopWatchingForLanding()
        guard !landed else { return }
        landed = true
        fadeAway()
    }

    private func stopWatchingForLanding() {
        if let landingObserver { NotificationCenter.default.removeObserver(landingObserver) }
        landingObserver = nil
    }

    private func fadeAway() {
        CATransaction.begin()
        CATransaction.setCompletionBlock { [self] in
            MainActor.assumeIsolated {
                panel.orderOut(nil)
                Self.landing.removeAll { $0 === self }
            }
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = DS.Motion.fadeDuration
        card.opacity = 0
        card.add(fade, forKey: "fade")
        CATransaction.commit()
    }

    // MARK: Tests

    /// Drag panels still on screen.
    static var panelsOnScreenForTesting: Int { NSApp.windows.filter { $0 is NSPanel && $0.level == .popUpMenu && $0.isVisible }.count }
    var cardFrameForTesting: NSRect { card.frame.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY) }
    var isShowingCardForTesting: Bool { cardLayer.opacity > 0.5 }
    /// The icon's and the title's frames on screen, and whether the icon shows.
    var iconFrameForTesting: NSRect { iconLayer.frame.offsetBy(dx: card.frame.minX + panel.frame.minX, dy: card.frame.minY + panel.frame.minY) }
    var titleFrameForTesting: NSRect { titleLayer.frame.offsetBy(dx: card.frame.minX + panel.frame.minX, dy: card.frame.minY + panel.frame.minY) }
    var showsIconForTesting: Bool { iconLayer.opacity > 0.5 }
    var isOnScreenForTesting: Bool { panel.isVisible }

    /// The layer as it stands, shadow included, over a backdrop.
    func renderedForTesting(backdrop: NSColor) -> NSImage? {
        CATransaction.flush()
        let margin: CGFloat = 40
        let area = card.frame.insetBy(dx: -margin, dy: -margin)
        let scale: CGFloat = 2
        guard let context = CGContext(data: nil, width: Int(area.width * scale), height: Int(area.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(backdrop.cgColor)
        context.fill(CGRect(origin: .zero, size: area.size))
        context.translateBy(x: -area.minX, y: -area.minY)
        panel.contentView?.layer?.render(in: context)
        return context.makeImage().map { NSImage(cgImage: $0, size: area.size) }
    }
}

// MARK: - Close button

final class TabCloseButton: CircularIconButton {
    init() {
        super.init(diameter: 16)
        setSymbol("xmark", pointSize: 9, weight: .bold, color: NSColor.secondaryLabelColor, accessibilityLabel: "Close Tab")
        // Stronger than the selected tab it sits on: in dark mode the old hover (white 16 %) sat
        // on an active tab of white 18 % and disappeared.
        hoverBackgroundColor = DS.Color.tabCloseHover
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Holding the tab shortcuts' modifier (⌘ unless rebound) for a moment shows each tab's shortcut
/// on it, as Rex does. After a moment, not at once: every ⌘C would flash them. Any key, click or
/// other modifier puts them away.
@MainActor
enum TabShortcutHints {
    static let changed = Notification.Name("SideTabShortcutHintsChanged")
    private(set) static var showing = false
    private static var monitor: Any?
    private static var pending: Timer?
    static let delay: TimeInterval = 0.5

    static func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) { event in
            MainActor.assumeIsolated { handle(event) }
            return event
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { cancel() }
        }
    }

    private static func handle(_ event: NSEvent) {
        let held = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.type == .flagsChanged, let wanted = Shortcuts.chord("tabs.1")?.flags.intersection([.command, .option, .control, .shift]),
           !wanted.isEmpty, held == wanted {
            guard !showing, pending == nil else { return }
            pending = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
                MainActor.assumeIsolated {
                    pending = nil
                    set(true)
                }
            }
        } else {
            cancel()
        }
    }

    private static func cancel() {
        pending?.invalidate()
        pending = nil
        set(false)
    }

    private static func set(_ on: Bool) {
        guard on != showing else { return }
        showing = on
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// Tabs 1–8 by number; the last tab, past the eighth, by "Switch to Last Tab".
    static func hint(at index: Int, count: Int) -> String? {
        let id = index < 8 ? "tabs.\(index + 1)" : index == count - 1 ? "tabs.last" : nil
        return id.map(Shortcuts.display).flatMap { $0.isEmpty ? nil : $0 }
    }

    static func setShowingForTesting(_ on: Bool) { set(on) }
}
