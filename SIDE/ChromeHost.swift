import AppKit
import SideAgents

/// Where the navigation components live (Direction 02 §3.0). The floating bar is the layout —
/// its trial ended 2026-09-23 with the owner keeping it. `.topRow` stays as the hidden fallback;
/// the seamless frame and top row are correct under both.
enum ChromePlacement: String {
    case floatingBar, topRow

    /// A hidden key so both layouts can be compared on one build — not a user setting.
    static var current: ChromePlacement {
        HeronDefaults.store.string(forKey: "SideChromePlacement").flatMap(Self.init(rawValue:)) ?? .floatingBar
    }
}

/// A stage header that spans the whole top row, so controls can sit at its trailing end.
protocol TopRowFilling: NSView {}

/// What a stage contributes to the window's chrome. Nothing here knows where the chrome is.
@MainActor
protocol StageChromeProviding: AnyObject {
    /// The stage's own top-row content — its tabs, or its header.
    var topRowContent: NSView? { get }
    /// Height at the bottom of the stage that something else is drawn over. Scrolling content
    /// scrolls clear of it; content that must never be covered (a prompt) ends above it.
    func setBottomObstruction(_ height: CGFloat)
    /// The same at the top: the window's top row floats over the stage, which runs to the top
    /// edge. Content starts below it and scrolls up underneath it.
    func setTopObstruction(_ height: CGFloat)
    /// The stage's own surface, which the top row takes on so the two read as one sheet.
    var topRowBackground: NSColor { get }
    /// The appearance the top row's frosting takes when the stage wears another (Make under an
    /// editor theme of the other appearance); nil for the window's.
    var topRowAppearance: NSAppearance? { get }
    /// Stage controls that belong beside the bar when there is one (Think's changes and session
    /// pills): leading sits after the track pill, trailing before search.
    var barAccessories: (leading: NSView?, trailing: NSView?) { get }
    /// Told whether the accessories are in the bar, so the stage can lay them out itself if not.
    func setAccessoriesDocked(_ docked: Bool)
    /// The scroll view whose content runs up under the top row, if any — the row frosts only
    /// once that content has actually scrolled beneath it.
    var scrollViewUnderTopRow: NSScrollView? { get }
}

extension StageChromeProviding {
    func setBottomObstruction(_ height: CGFloat) {}
    func setTopObstruction(_ height: CGFloat) {}
    var topRowBackground: NSColor { DS.Color.canvas }
    var topRowAppearance: NSAppearance? { nil }
    var barAccessories: (leading: NSView?, trailing: NSView?) { (nil, nil) }
    func setAccessoriesDocked(_ docked: Bool) {}
    var scrollViewUnderTopRow: NSScrollView? { nil }
}

/// Owns placement: the top row every window has, and — under `.floatingBar` — the glass bar.
/// The components it places (track pill, stage control, search button) are plain views that
/// never read this class or their own position.
@MainActor
final class ChromeHost {
    /// 38: the traffic lights' own title-bar strip, with the lights centred in it. (52 was
    /// tried for a bar-height tab capsule: too tall, and the lights then had to sit lower than
    /// their system container allows, so AppKit's re-layouts kept snapping them back up.)
    static let rowHeight: CGFloat = 38
    static let barHeight: CGFloat = 40
    static let barGap: CGFloat = 12

    let placement: ChromePlacement
    let topRow = TopRowView()
    private let topRowBackdrop = TopRowBackdrop()
    let pill: TrackPill
    /// The project, in its own glass disc before the track pill.
    let projectChip = ProjectChip(diameter: ChromeHost.barHeight)
    let stageControl: SlidingSegmentedControl
    let searchButton: GlassCircleButton
    private let stageSlot = NSView()
    private var stageContent: NSView?
    private var bar: NSView?
    private var barPieces: [NSView] = []
    /// The update pill, beside search (Direction 03 §5.1).
    private(set) var updatePill: UpdatePill?
    private(set) var diskPill: DiskSpacePill?
    /// A loose file's window: its folder, made a project, in place of the chip and track pill.
    private(set) var openFolderPill: GlassPill?
    var onOpenFolderAsProject: (() -> Void)?
    /// The activity pill (prototype): what's happening out of sight, beside zoom and update.
    private(set) var activityPill: ActivityPill?
    /// Zoom's pill, beside the update pill: only while you're zooming.
    private(set) var zoomPill: ZoomPill?
    /// Search and the update pill, as one trailing piece of the bar.
    private var trailingCluster: NSView?
    private var updateObserver: NSObjectProtocol?
    private var diskObserver: NSObjectProtocol?
    private var activityObserver: NSObjectProtocol?
    private var leadingInset: NSLayoutConstraint?
    private var rowTrailing: NSLayoutConstraint?

    init(placement: ChromePlacement, pill: TrackPill, stageControl: SlidingSegmentedControl, searchButton: GlassCircleButton) {
        self.placement = placement
        self.pill = pill
        self.stageControl = stageControl
        self.searchButton = searchButton
    }

    /// The covered band at the bottom of every stage — the bar and the gap beneath it.
    var bottomObstruction: CGFloat { placement == .floatingBar ? Self.barHeight + Self.barGap : 0 }

    func install(in root: NSView, content: NSView) {
        content.translatesAutoresizingMaskIntoConstraints = false
        topRow.translatesAutoresizingMaskIntoConstraints = false
        stageSlot.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)
        root.addSubview(topRowBackdrop)
        root.addSubview(topRow)

        let row = NSStackView()
        // Never let the row's contents size the window: a stack view's default clipping
        // resistance is *required*, so a long conversation title or track intent widened the
        // whole window the moment Think or Review came forward.
        row.setClippingResistancePriority(.defaultLow, for: .horizontal)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = DS.Spacing.m
        row.translatesAutoresizingMaskIntoConstraints = false
        topRow.addSubview(row)
        switch placement {
        case .topRow:
            searchButton.setGlass(false)
            let update = UpdatePill(glass: false, height: 28)
            updatePill = update
            let disk = DiskSpacePill(glass: false, height: 28)
            diskPill = disk
            let zoom = ZoomPill(height: 28, glass: false)
            zoomPill = zoom
            let activity = ActivityPill(glass: false, height: 28)
            activityPill = activity
            for view in [projectChip, pill, stageSlot, stageControl, activity.view, zoom, disk.view, update.view, searchButton] as [NSView] { row.addArrangedSubview(view) }
            row.setCustomSpacing(DS.Spacing.l, after: stageSlot)
        case .floatingBar:
            row.addArrangedSubview(stageSlot)
            installBar(in: root)
        }
        stageSlot.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stageSlot.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let inset = row.leadingAnchor.constraint(equalTo: topRow.leadingAnchor, constant: Self.trafficLightInset)
        leadingInset = inset
        let rowTrailing = row.trailingAnchor.constraint(equalTo: topRow.trailingAnchor, constant: -DS.Spacing.m)
        self.rowTrailing = rowTrailing
        NSLayoutConstraint.activate([
            topRow.topAnchor.constraint(equalTo: root.topAnchor),
            topRow.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topRow.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            topRow.heightAnchor.constraint(equalToConstant: Self.rowHeight),
            inset,
            rowTrailing,
            row.topAnchor.constraint(equalTo: topRow.topAnchor),
            row.bottomAnchor.constraint(equalTo: topRow.bottomAnchor),
            stageSlot.topAnchor.constraint(equalTo: row.topAnchor),
            stageSlot.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            // Edge to edge: the stage runs under the top row, which fades into it.
            content.topAnchor.constraint(equalTo: root.topAnchor),
            topRowBackdrop.topAnchor.constraint(equalTo: root.topAnchor),
            topRowBackdrop.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topRowBackdrop.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            topRowBackdrop.heightAnchor.constraint(equalToConstant: Self.rowHeight),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
    }

    /// The bar: three pieces of glass spread across the bottom — the track pill at the leading
    /// margin, the stage control centred, search at the trailing margin — so under Think's
    /// full-width composer the row spans the same width and no corner is left empty. On a
    /// narrow window the pill gives way (truncates, then dot only) before anything overlaps.
    private func installBar(in root: NSView) {
        let pillCapsule = Self.glassCapsule(around: pill, insets: NSEdgeInsets(top: 0, left: DS.Spacing.xs, bottom: 0, right: DS.Spacing.xs))
        let stagesCapsule = Self.glassCapsule(around: stageControl, insets: NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4))
        searchButton.setGlass(true)
        let update = UpdatePill(glass: true, height: Self.barHeight)
        updatePill = update
        let disk = DiskSpacePill(glass: true, height: Self.barHeight)
        diskPill = disk
        let zoom = ZoomPill(height: Self.barHeight, glass: true)
        zoomPill = zoom
        let activity = ActivityPill(glass: true, height: Self.barHeight)
        activityPill = activity
        let cluster = NSStackView(views: [activity.view, zoom, disk.view, update.view, searchButton])
        cluster.orientation = .horizontal
        cluster.alignment = .centerY
        cluster.spacing = DS.Spacing.m
        cluster.detachesHiddenViews = true
        // What the cluster holds never sizes the window (500), and its pills' titles truncate
        // (480) before it clips them: at 250 a long one was cut off under its neighbour.
        cluster.setClippingResistancePriority(NSLayoutConstraint.Priority(490), for: .horizontal)
        cluster.translatesAutoresizingMaskIntoConstraints = false
        trailingCluster = cluster
        let folder = GlassPill(height: Self.barHeight, glass: true)
        folder.setMarkSize(16)
        folder.set(title: "Open Folder as Project", mark: .symbol("folder", nil))
        folder.toolTip = "Open this file's folder as a project, in this window"
        folder.onClick = { [weak self] in self?.onOpenFolderAsProject?() }
        folder.isHidden = true
        folder.translatesAutoresizingMaskIntoConstraints = false
        openFolderPill = folder
        for piece in [projectChip, pillCapsule, stagesCapsule, cluster, folder] as [NSView] { root.addSubview(piece) }
        NSLayoutConstraint.activate([
            projectChip.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.barMargin),
            projectChip.centerYAnchor.constraint(equalTo: stagesCapsule.centerYAnchor),
            pillCapsule.leadingAnchor.constraint(equalTo: projectChip.trailingAnchor, constant: DS.Spacing.m),
            pillCapsule.trailingAnchor.constraint(lessThanOrEqualTo: stagesCapsule.leadingAnchor, constant: -DS.Spacing.m),
            stagesCapsule.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            cluster.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Self.barMargin),
            cluster.leadingAnchor.constraint(greaterThanOrEqualTo: stagesCapsule.trailingAnchor, constant: DS.Spacing.m),
            pillCapsule.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Self.barGap),
            stagesCapsule.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Self.barGap),
            cluster.centerYAnchor.constraint(equalTo: stagesCapsule.centerYAnchor),
            folder.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.barMargin),
            folder.centerYAnchor.constraint(equalTo: stagesCapsule.centerYAnchor),
            folder.trailingAnchor.constraint(lessThanOrEqualTo: cluster.leadingAnchor, constant: -DS.Spacing.m),
        ])
        bar = stagesCapsule
        barPieces = [projectChip, pillCapsule, stagesCapsule, cluster]
        // The pill coming or going changes what fits beside the stage control.
        updateObserver = NotificationCenter.default.addObserver(forName: UpdateDriver.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.replaceAccessories() }
        }
        zoom.onShownChanged = { [weak self] in self?.replaceAccessories() }
        diskObserver = NotificationCenter.default.addObserver(forName: DiskSpace.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.replaceAccessories() }
        }
        activityObserver = NotificationCenter.default.addObserver(forName: ActivityCenter.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.replaceAccessories() }
        }
        barRoot = root
        pillPiece = pillCapsule
    }

    private func replaceAccessories() {
        guard let root = barRoot, accessoryStage != nil else { return }
        placeAccessories(of: accessoryStage, width: root.bounds.width)
    }

    /// With one stage to show there's nowhere to switch to: the stage control goes (its glass
    /// too, on the bar). The track pill and search stay; they aren't about stages.
    func setStageControlHidden(_ hidden: Bool) {
        (placement == .floatingBar ? bar : stageControl)?.isHidden = hidden
    }

    var stageControlHiddenForTesting: Bool { (placement == .floatingBar ? bar : stageControl)?.isHidden ?? true }

    /// A loose file's window has no project to show or switch: the chip and the track pill go.
    /// `animated`: Open Folder as Project, the pill giving way to the chip and track pill. Glass
    /// is drawn by the window server, so each piece fades by its own alpha (as Writer mode's do).
    func setProjectPiecesHidden(_ hidden: Bool, animated: Bool = false) {
        let projectPieces: [NSView] = [projectChip, (placement == .floatingBar ? pillPiece : pill)].compactMap { $0 }
        let coming = hidden ? [openFolderPill].compactMap { $0 } : projectPieces
        let going = hidden ? projectPieces : [openFolderPill].compactMap { $0 }
        guard animated, topRow.window != nil, !DS.Motion.reduceMotion else {
            // Alpha left alone for what's shown: Writer mode may be fading it in.
            for piece in coming { piece.isHidden = false }
            for piece in going { piece.isHidden = true; piece.alphaValue = 1 }
            return
        }
        for piece in coming where piece.isHidden { piece.alphaValue = 0; piece.isHidden = false }
        DS.Motion.fade(duration: DS.Motion.presentDuration, {
            for piece in coming { piece.animator().alphaValue = 1 }
            for piece in going { piece.animator().alphaValue = 0 }
        }, completion: {
            for piece in going { piece.isHidden = true; piece.alphaValue = 1 }
        })
    }

    private weak var barRoot: NSView?
    private weak var pillPiece: NSView?
    private var dockedAccessories: [NSView] = []

    /// Places a stage's accessories in the bar row — after the track pill and before search,
    /// never over the stage control. Returns false when there is no bar (the top-row
    /// placement), so the stage keeps them itself.
    @discardableResult
    private func dockAccessories(leading: NSView?, trailing: NSView?) -> Bool {
        dockedAccessories.forEach { $0.removeFromSuperview() }
        dockedAccessories = []
        guard placement == .floatingBar, let root = barRoot, let pillPiece, let bar else { return false }
        var constraints: [NSLayoutConstraint] = []
        if let leading {
            leading.removeFromSuperview()
            leading.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(leading)
            constraints += [
                leading.leadingAnchor.constraint(equalTo: pillPiece.trailingAnchor, constant: DS.Spacing.m),
                Self.yieldingToResize(leading.trailingAnchor.constraint(lessThanOrEqualTo: bar.leadingAnchor, constant: -DS.Spacing.m)),
                leading.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            ]
            dockedAccessories.append(leading)
        }
        if let trailing {
            trailing.removeFromSuperview()
            trailing.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(trailing)
            constraints += [
                trailing.trailingAnchor.constraint(equalTo: (trailingCluster ?? searchButton).leadingAnchor, constant: -DS.Spacing.m),
                Self.yieldingToResize(trailing.leadingAnchor.constraint(greaterThanOrEqualTo: bar.trailingAnchor, constant: DS.Spacing.m)),
                trailing.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            ]
            dockedAccessories.append(trailing)
        }
        NSLayoutConstraint.activate(constraints)
        return true
    }

    /// Never holds the window's size: any resize narrower than the docked pills allow goes
    /// through, and `adapt(toWidth:)` then undocks them. (They only dock when they fit, so this
    /// never gives way in a settled layout.) Just above the track pill's name (490), which
    /// truncates first.
    private static func yieldingToResize(_ constraint: NSLayoutConstraint) -> NSLayoutConstraint {
        constraint.priority = NSLayoutConstraint.Priority(rawValue: NSLayoutConstraint.Priority.windowSizeStayPut.rawValue - 1)
        return constraint
    }

    /// Lines the bar up with Think's composer row (the + button and the composer's edge).
    static let barMargin: CGFloat = DS.Spacing.xxl

    private static func glassCapsule(around content: NSView, insets: NSEdgeInsets) -> NSView {
        let capsule = NSView()
        capsule.translatesAutoresizingMaskIntoConstraints = false
        let glass = DS.makeGlass(cornerRadius: barHeight / 2)
        capsule.addSubview(glass)
        content.translatesAutoresizingMaskIntoConstraints = false
        capsule.addSubview(content)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: capsule.topAnchor), glass.bottomAnchor.constraint(equalTo: capsule.bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: capsule.leadingAnchor), glass.trailingAnchor.constraint(equalTo: capsule.trailingAnchor),
            content.leadingAnchor.constraint(equalTo: capsule.leadingAnchor, constant: insets.left),
            content.trailingAnchor.constraint(equalTo: capsule.trailingAnchor, constant: -insets.right),
            content.centerYAnchor.constraint(equalTo: capsule.centerYAnchor),
            capsule.heightAnchor.constraint(equalToConstant: barHeight),
        ])
        return capsule
    }

    /// The row takes the stage's own surface, so the top of the window and the stage are one
    /// sheet: canvas for most stages, the terminal's tone for Run.
    func setRowBackground(_ color: NSColor, appearance: NSAppearance? = nil) {
        topRowBackdrop.appearance = appearance
        topRowBackdrop.tint = color
    }

    /// Writer mode: no top row and no bar, only the stage.
    /// `animated`: the glass fades in a glance (Writer mode). Glass is drawn by the window
    /// server, so a crossfade of the window's layers can't carry it; its own alpha does.
    func setHidden(_ hidden: Bool, animated: Bool = false) {
        isChromeHidden = hidden
        let pieces: [NSView] = [topRow, topRowBackdrop] + barPieces + [openFolderPill].compactMap { $0 }
        guard animated, topRow.window != nil else {
            for piece in pieces { piece.isHidden = hidden; piece.alphaValue = 1 }
            return
        }
        if !hidden {
            for piece in pieces where piece.isHidden { piece.alphaValue = 0; piece.isHidden = false }
        }
        DS.Motion.fade(duration: DS.Motion.glanceDuration, {
            for piece in pieces { piece.animator().alphaValue = hidden ? 0 : 1 }
        }, completion: { [weak self] in
            guard let self, hidden, self.isChromeHidden else { return }
            for piece in pieces { piece.isHidden = true; piece.alphaValue = 1 }
        })
    }
    private(set) var isChromeHidden = false

    private var scrollObserver: NSObjectProtocol?
    private weak var watchedScroll: NSScrollView?

    /// macOS's own toolbar behaviour: the row is clear — nothing but the stage — until content
    /// scrolls beneath it, and only then frosts. A permanently frosted row was a band a few
    /// levels lighter than the stage even with nothing under it.
    func watchScrollBeneathTopRow(_ scroll: NSScrollView?) {
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        scrollObserver = nil
        watchedScroll = scroll
        guard let scroll else { topRowBackdrop.setFrosted(false, animated: false); return }
        scroll.contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateFrost(animated: true) }
        }
        updateFrost(animated: false)
    }

    private func updateFrost(animated: Bool) {
        guard let scroll = watchedScroll else { return }
        let clip = scroll.contentView
        let flipped = scroll.documentView?.isFlipped ?? true
        // At rest the clip sits `contentInsets.top` above the document's top edge.
        let scrolled: Bool
        if flipped {
            scrolled = clip.bounds.minY > -scroll.contentInsets.top + 1
        } else {
            let top = (scroll.documentView?.frame.maxY ?? 0) + scroll.contentInsets.top
            scrolled = clip.bounds.maxY < top - 1
        }
        topRowBackdrop.setFrosted(scrolled, animated: animated)
    }

    /// Replaces the stage's top-row content (its tabs or header).
    func setStageContent(_ view: NSView?) {
        guard view !== stageContent else { return }
        stageContent?.removeFromSuperview()
        stageContent = view
        guard let view else { return }
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        stageSlot.addSubview(view)
        defer {
            // A strip re-parented into the row keeps the layout it had in its old home until
            // something resizes the window — why the tabs sometimes didn't draw until a resize.
            topRow.layoutSubtreeIfNeeded()
            Self.markNeedsDisplay(view)
        }
        // Tab strips fill the row so the active tab reaches the content below it; a header
        // sits on the row's centre line, level with the traffic lights.
        //
        // A strip must *fill* the slot: its scroll view has no intrinsic width, so pinned with
        // `≤` it collapsed to zero the second time it was placed here — the tabs that vanished
        // after a trip to another stage and came back on resize. A header hugs its text.
        let isStrip = view is TabStripView
        // A header with controls at the row's far end (Agent's panel toggle) fills it too.
        let fills = isStrip || view is TopRowFilling
        NSLayoutConstraint.activate([
            isStrip ? view.topAnchor.constraint(equalTo: stageSlot.topAnchor) : view.centerYAnchor.constraint(equalTo: stageSlot.centerYAnchor),
            isStrip ? view.bottomAnchor.constraint(equalTo: stageSlot.bottomAnchor) : view.heightAnchor.constraint(lessThanOrEqualTo: stageSlot.heightAnchor),
            view.leadingAnchor.constraint(equalTo: stageSlot.leadingAnchor),
            fills ? view.trailingAnchor.constraint(equalTo: stageSlot.trailingAnchor) : view.trailingAnchor.constraint(lessThanOrEqualTo: stageSlot.trailingAnchor),
        ])
    }

    private static func markNeedsDisplay(_ view: NSView) {
        view.needsLayout = true
        view.needsDisplay = true
        view.subviews.forEach(markNeedsDisplay)
    }

    /// Where the palette grows from, in `root`'s coordinates: the stage bar under
    /// `.floatingBar`, the search button in the top row.
    func paletteSource(in root: NSView) -> NSRect {
        if let bar { return bar.convert(bar.bounds, to: root) }
        return searchButton.convert(searchButton.bounds, to: root)
    }

    /// The piece the palette morphs out of and back into: the nav's stage capsule, or the
    /// search button when the nav is hidden (one stage) or in the top row. It hides while the
    /// palette is out: it became the palette.
    func paletteOriginPiece() -> NSView {
        if let bar, !bar.isHidden, bar.window != nil { return bar }
        return searchButton
    }

    func paletteOrigin(in root: NSView) -> NSRect {
        let piece = paletteOriginPiece()
        return piece.convert(piece.bounds, to: root)
    }

    /// While Think's composer holds text, the bar recedes (still operable) so there aren't two
    /// equally loud things at the bottom of the window.
    func setBarRecessed(_ recessed: Bool) {
        guard placement == .floatingBar else { return }
        (barPieces + dockedAccessories).forEach { $0.alphaValue = recessed ? 0.55 : 1 }
    }

    /// Narrow windows: the pill's intent truncates with an ellipsis — layout decides, not a width
    /// threshold. The old threshold flipped the pill to dot-only on a transient layout pass and
    /// could stay there, so the track name "suddenly disappeared".
    /// Re-decides docking as the window resizes: a narrow window takes the pills back above
    /// the composer, a wide enough one docks them again.
    func adapt(toWidth width: CGFloat) {
        guard accessoryStage != nil, dockedWidthNeeded > 0 else { return }
        if accessoriesDocked != (width >= dockedWidthNeeded) { updateAccessoryDocking(width: width) }
    }

    private var accessoryStage: (any StageChromeProviding)?
    private var accessoriesDocked = false
    /// The window width the bar needs with the accessories in it, measured when they last were.
    private var dockedWidthNeeded: CGFloat = 0

    /// Puts a stage's accessories in the bar row when they fit, else leaves them to the stage.
    /// Docking only when there's room is what keeps a narrow window narrow: docked, the pills'
    /// required spacing beside a centred stage control pushed a 760 pt window out to 856 the
    /// moment Think was entered.
    func placeAccessories(of stage: (any StageChromeProviding)?, width: CGFloat) {
        accessoryStage = stage
        dockedWidthNeeded = 0
        updateAccessoryDocking(width: width)
    }

    private func updateAccessoryDocking(width: CGFloat) {
        let accessories: (leading: NSView?, trailing: NSView?) = accessoryStage?.barAccessories ?? (nil, nil)
        guard let stage = accessoryStage, accessories.leading != nil || accessories.trailing != nil else {
            dockAccessories(leading: nil, trailing: nil)
            accessoriesDocked = false
            return
        }
        // Dock, measure at bar size, and back out before any layout pass if it doesn't fit —
        // the window never sees the wider arrangement.
        accessoriesDocked = dockAccessories(leading: accessories.leading, trailing: accessories.trailing)
        stage.setAccessoriesDocked(accessoriesDocked)
        guard accessoriesDocked else { return }
        dockedWidthNeeded = widthNeeded(leading: accessories.leading, trailing: accessories.trailing)
        if width < dockedWidthNeeded {
            dockAccessories(leading: nil, trailing: nil)
            accessoriesDocked = false
            stage.setAccessoriesDocked(false)
        }
    }

    /// The stage control is centred, so the wider side sets the width: track pill (at a
    /// readable, truncated width) and the leading pill on one side, search and the trailing
    /// pill on the other.
    private func widthNeeded(leading: NSView?, trailing: NSView?) -> CGFloat {
        guard let bar else { return 0 }
        func piece(_ view: NSView?) -> CGFloat { view.map { $0.fittingSize.width + DS.Spacing.m } ?? 0 }
        let pillWidth = min(pillPiece?.fittingSize.width ?? 0, 180)
        let left = Self.barMargin + Self.barHeight + DS.Spacing.m + pillWidth + DS.Spacing.m + piece(leading)
        let right = Self.barMargin + (trailingCluster ?? searchButton).fittingSize.width + DS.Spacing.m + piece(trailing)
        return bar.fittingSize.width + 2 * max(left, right)
    }

    /// Where the palette goes, in `root`'s coordinates: expanding upward from the bar, or
    /// centred in the window under the top row.
    func paletteFrame(size: NSSize, in root: NSView) -> NSRect {
        var origin: NSPoint
        if placement == .floatingBar, let bar {
            let barFrame = bar.convert(bar.bounds, to: root)
            origin = NSPoint(x: barFrame.midX - size.width / 2, y: barFrame.maxY + DS.Spacing.m)
        } else {
            origin = NSPoint(x: root.bounds.midX - size.width / 2, y: root.bounds.maxY - Self.rowHeight - 60 - size.height)
        }
        origin.x = max(12, min(origin.x, root.bounds.maxX - size.width - 12))
        return NSRect(origin: origin, size: size)
    }

    // MARK: Traffic lights

    /// Content starts after the lights; in full screen, where they hide, the inset collapses.
    static let trafficLightInset: CGFloat = 78
    func setFullScreen(_ fullScreen: Bool) {
        leadingInset?.constant = fullScreen ? 12 : Self.trafficLightInset
    }

    /// The one line the row's contents centre on — the tab capsule, headers, and the lights.
    static var rowCentreFromTop: CGFloat { rowHeight / 2 }

    private var lightObservers: [NSObjectProtocol] = []
    private var isPositioningLights = false

    /// Centres the traffic lights on the row's centre line, and keeps them there.
    ///
    /// AppKit lays the lights out for its own ~28 pt title bar (centre ≈ 15 pt down) and re-lays
    /// them whenever it likes — stage switches, resizes, key changes, full-screen exits. Moving
    /// them once, from Side's own layout pass, lost that race at random: Make happened to look
    /// right, other stages didn't, and even Make sat ~4 pt above the tabs. So the buttons are
    /// watched, and every time AppKit moves one it goes straight back to the shared centre line.
    func positionTrafficLights(in window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen), !isPositioningLights else { return }
        isPositioningLights = true
        defer { isPositioningLights = false }
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(type), let container = button.superview else { continue }
            // The container is unflipped: y counts up from its bottom edge, and its top edge is
            // the window's top edge.
            let y = container.bounds.height - Self.rowCentreFromTop - button.frame.height / 2
            if abs(button.frame.origin.y - y) > 0.25 { button.setFrameOrigin(NSPoint(x: button.frame.origin.x, y: y)) }
        }
    }

    private var lightCorrectionPending = false

    /// After AppKit's pass, not inside it: a frame set from within the button's own
    /// frame-change notification is overwritten when AppKit finishes laying that button out —
    /// which is exactly how one light (usually the green one) stayed 3 pt high.
    private func scheduleLightCorrection(in window: NSWindow) {
        guard !isPositioningLights, !lightCorrectionPending else { return }
        lightCorrectionPending = true
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self else { return }
            self.lightCorrectionPending = false
            if let window { self.positionTrafficLights(in: window) }
        }
    }

    /// Re-centres the lights whenever AppKit moves them.
    func keepTrafficLightsCentred(in window: NSWindow) {
        lightObservers.forEach(NotificationCenter.default.removeObserver)
        lightObservers = []
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(type) else { continue }
            for view in [button, button.superview].compactMap({ $0 }) {
                view.postsFrameChangedNotifications = true
                lightObservers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: view, queue: .main) { [weak self, weak window] _ in
                    MainActor.assumeIsolated {
                        guard let self, let window else { return }
                        self.scheduleLightCorrection(in: window)
                    }
                })
            }
        }
        positionTrafficLights(in: window)
    }
}

/// Behind the top row: the stage's own tone, translucent and blurred over whatever has scrolled
/// beneath — the row is a pane of frosted glass the stage runs under, with no edge and no fade
/// (a gradient fall-off read as a smudge; owner's call, 2026-09-22).
final class TopRowBackdrop: NSView {
    private let blur = NSVisualEffectView()
    private let tintView = NSView()
    private var frosted = false
    var tint: NSColor = DS.Color.canvas { didSet { applyLook() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        blur.material = .headerView
        blur.blendingMode = .withinWindow
        blur.state = .active
        tintView.wantsLayer = true
        for view in [blur, tintView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: topAnchor), view.bottomAnchor.constraint(equalTo: bottomAnchor),
                view.leadingAnchor.constraint(equalTo: leadingAnchor), view.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
        }
        tint = DS.Color.canvas
        alphaValue = 0
        NotificationCenter.default.addObserver(self, selector: #selector(applyLook), name: DS.Appearance.didChangeNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Solid window: the stage's tone, frosted over what's beneath. Translucent window: no blur
    /// of its own (a blur in a see-through window, fading in, drew a flat dark grey band over a
    /// light window: the owner, 2026-11-12), only the canvas tone over the window's glass, enough
    /// that what scrolled under it doesn't show.
    @objc private func applyLook() {
        let translucent = DS.Translucency.isOn
        blur.isHidden = translucent
        tintView.bindLayerBackground(translucent ? DS.Translucency.coverTint : tint.withAlphaComponent(0.72))
    }

    /// Clear at rest; frosted glass once something has scrolled underneath.
    func setFrosted(_ on: Bool, animated: Bool) {
        guard on != frosted else { return }
        frosted = on
        guard animated else { alphaValue = on ? 1 : 0; return }
        DS.Motion.fade { animator().alphaValue = on ? 1 : 0 }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var mouseDownCanMoveWindow: Bool { false }
}

/// The unified top row: traffic lights, then the stage's tabs or header. Every point that isn't
/// a control drags the window, and a double-click does what the system titlebar would.
final class TopRowView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// False, deliberately: a `true` here marks the whole row as a window-drag region that
    /// AppKit honours before any subview sees the press, so dragging a tab dragged the window.
    /// Empty space still drags — `mouseDown` below calls `performDrag` itself.
    override var mouseDownCanMoveWindow: Bool { false }

    /// Controls keep their clicks; everything else — empty tab-strip space, labels, stack
    /// padding — belongs to the row, so it drags.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        var view: NSView? = hit
        while let current = view, current !== self {
            if Self.isInteractive(current) { return hit }
            view = current.superview
        }
        return self
    }

    static func isInteractive(_ view: NSView) -> Bool {
        if view is TrackPill || view is TabChipView || view is GlassPill { return true }
        if let field = view as? NSTextField { return field.isEditable || field.isSelectable }
        return view is NSControl
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.clickCount == 2 {
            Self.performTitlebarDoubleClick(on: window)
        } else {
            window.performDrag(with: event)
        }
    }

    /// Scrolling over a tab strip's empty space still scrolls the strip.
    override func scrollWheel(with event: NSEvent) {
        guard let superview else { return super.scrollWheel(with: event) }
        let point = superview.convert(event.locationInWindow, from: nil)
        if let scroll = super.hitTest(point)?.enclosingScrollView { scroll.scrollWheel(with: event) } else { super.scrollWheel(with: event) }
    }

    /// Honours System Settings → Desktop & Dock → "Double-click a window's title bar to".
    static func performTitlebarDoubleClick(on window: NSWindow) {
        let action = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleActionOnDoubleClick"] as? String
        switch action {
        case "Minimize": window.miniaturize(nil)
        case "None", "No Action": break
        default: window.zoom(nil)
        }
    }
}
