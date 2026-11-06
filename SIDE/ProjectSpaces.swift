import AppKit

/// Project switching in one window (prototype, 2026-11-04): the projects you move between, in
/// a fixed order (⌃1–9 follow it), each with a symbol and a color of its own so they differ by
/// shape, not color alone (Sill's spaces, docs/DESIGN.md in Sill). A project you switch away
/// from stays open in the background: its terminals keep running, its agents keep working, and
/// the activity pill keeps telling you about them.
@MainActor
final class ProjectSpaces {
    static let shared = ProjectSpaces()
    static let didChangeNotification = Notification.Name("SideProjectSpacesDidChange")

    struct Space: Codable, Equatable {
        let path: String
        var symbol: String
        var colorIndex: Int
        /// When a window last opened it: a project that isn't open says how long ago.
        var lastOpenedAt: Date? = nil
        /// A picture chosen for it, over the logo found in the repository.
        var logoPath: String? = nil

        var url: URL { URL(fileURLWithPath: path) }
        var name: String { url.lastPathComponent }
        var color: NSColor { ProjectSpaces.palette[colorIndex % ProjectSpaces.palette.count] }
    }

    /// Sill's palette, as system colors so both appearances are right.
    nonisolated static let palette: [NSColor] = [.systemGray, .systemBlue, .systemPurple, .systemPink, .systemRed, .systemOrange, .systemYellow, .systemGreen, .systemTeal]
    static let symbols = ["square.stack.3d.up.fill", "hammer.fill", "leaf.fill", "bolt.fill", "flame.fill", "cube.fill", "star.fill",
                          "paperplane.fill", "globe.americas.fill", "books.vertical.fill", "puzzlepiece.fill", "shippingbox.fill",
                          "sparkle", "bubble.left.fill", "music.note", "camera.fill"]

    /// Under XCTest, a store of its own: the test host opens dozens of throwaway projects, and
    /// they filled the real switcher (found 2026-11-04, the night it was built).
    static var defaults: UserDefaults = NSClassFromString("XCTestCase") != nil
        ? UserDefaults(suiteName: "side.tests.projectSpaces") ?? .standard
        : .standard
    private static let key = "side.projectSpaces"

    private(set) var spaces: [Space]
    /// Projects held open in the background, whatever window shows them.
    private var held: Set<String> = []

    private let store: UserDefaults

    /// `store`: where the order, symbols and colors are kept (tests pass their own).
    init(store: UserDefaults = ProjectSpaces.defaults) {
        self.store = store
        spaces = (store.data(forKey: Self.key)).flatMap { try? JSONDecoder().decode([Space].self, from: $0) } ?? []
    }

    private func save() {
        if let data = try? JSONEncoder().encode(spaces) { store.set(data, forKey: Self.key) }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    private static func normalized(_ url: URL) -> String { url.standardizedFileURL.path }

    /// The project's space, made (with a symbol no other space has) the first time it's seen.
    @discardableResult
    func space(for url: URL) -> Space {
        let path = Self.normalized(url)
        if let existing = spaces.first(where: { $0.path == path }) { return existing }
        let used = Set(spaces.map(\.symbol))
        let symbol = Self.symbols.first { !used.contains($0) } ?? Self.symbols[spaces.count % Self.symbols.count]
        let space = Space(path: path, symbol: symbol, colorIndex: (spaces.count + 1) % Self.palette.count)
        spaces.append(space)
        save()
        return space
    }

    func index(of url: URL) -> Int? { spaces.firstIndex { $0.path == Self.normalized(url) } }

    /// What the switcher shows: the first nine (⌃1–9 reach them), and the current one wherever
    /// it falls. Every project opened becomes a space, so the whole list can run long.
    func shown(current url: URL?) -> [Space] {
        var shown = Array(spaces.prefix(9))
        if let url, let space = spaces.first(where: { $0.path == Self.normalized(url) }), !shown.contains(space) { shown.append(space) }
        return shown
    }

    /// Keeps a project open after its window moves on.
    func hold(_ url: URL) {
        let path = Self.normalized(url)
        guard !held.contains(path) else { return }
        held.insert(path)
        _ = ProjectContextRegistry.shared.acquire(projectRoot: url)
    }

    /// Open in the background, left by a window that switched to another project.
    /// By the folder itself: a session's record can name it through a symlink (`/tmp`) where
    /// the window holds it resolved (`/private/tmp`), or the other way round.
    func isHeld(_ url: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        return held.contains { $0 == Self.normalized(url) || URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path == resolved }
    }

    var isHoldingForTesting: Set<String> { held }

    /// A window opened it now.
    func touch(_ url: URL) {
        guard let index = index(of: url) else { return }
        spaces[index].lastOpenedAt = Date()
        save()
    }

    /// No longer held in the background: closed unless a window has it, still in the switcher
    /// (under Not open) to come back to.
    func putAway(_ url: URL) {
        let path = Self.normalized(url)
        if held.remove(path) != nil { ProjectContextRegistry.shared.release(projectRoot: url) }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    /// Out of the switcher, and closed if nothing else has it open.
    func remove(_ url: URL) {
        let path = Self.normalized(url)
        if held.remove(path) != nil { ProjectContextRegistry.shared.release(projectRoot: url) }
        spaces.removeAll { $0.path == path }
        save()
    }

    /// `nil`: back to the logo found in the repository.
    func set(logo: URL?, for url: URL) {
        guard let index = index(of: url) else { return }
        spaces[index].logoPath = logo?.standardizedFileURL.path
        save()
    }

    func set(symbol: String? = nil, colorIndex: Int? = nil, for url: URL) {
        guard let index = index(of: url) else { return }
        if let symbol { spaces[index].symbol = symbol }
        if let colorIndex { spaces[index].colorIndex = colorIndex }
        save()
    }

    /// The space `offset` places from `url`'s, wrapping (a swipe on the chip).
    func neighbor(of url: URL, offset: Int) -> Space? {
        guard spaces.count > 1, let index = index(of: url) else { return nil }
        return spaces[((index + offset) % spaces.count + spaces.count) % spaces.count]
    }

    static func image(for space: Space, pointSize: CGFloat = 12) -> NSImage? {
        NSImage(systemSymbolName: space.symbol, accessibilityDescription: space.name)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold).applying(.init(paletteColors: [space.color])))
    }
}

/// Shown above the chip for a moment after each switch (Sill's indicator): a mark per project,
/// the current one opened out with its name, so you see where you landed and what's either side.
/// The marks are the projects' own, as on the chip; switching while it shows, the name moves to
/// the next mark and the glass springs to its new width (the owner, 2026-11-05).
@MainActor
final class ProjectIndicator: NSView {
    private let row = NSStackView()
    private let name = NSTextField(labelWithString: "")
    /// Each project's mark, by its path, kept from one switch to the next so they can move.
    private var marks: [String: NSImageView] = [:]
    private var markSizes: [String: NSLayoutConstraint] = [:]
    private var order: [String] = []
    private var dots: [NSView] = []
    private var isShown = false
    private var hide: DispatchWorkItem?
    private lazy var widthSpring = DS.Motion.WidthSpring(self)

    static let currentMarkSize: CGFloat = 18
    static let otherMarkSize: CGFloat = 15

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        let glass = DS.makeGlass(cornerRadius: DS.Radius.capsule(height: 34))
        addSubview(glass)
        // The marks inside the glass while it springs to a wider width than it has yet.
        let clip = NSView()
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        clip.layer?.cornerRadius = DS.Radius.capsule(height: 34)
        clip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(clip)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = DS.Spacing.m
        row.translatesAutoresizingMaskIntoConstraints = false
        clip.addSubview(row)
        name.font = DS.Text.body(.medium)
        name.wantsLayer = true
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor), glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor), glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            clip.topAnchor.constraint(equalTo: topAnchor), clip.bottomAnchor.constraint(equalTo: bottomAnchor),
            clip.leadingAnchor.constraint(equalTo: leadingAnchor), clip.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(equalToConstant: 34),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DS.Spacing.xl),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        // Its width, unless the spring holds another for a moment.
        let fits = row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DS.Spacing.xl)
        fits.priority = .defaultHigh
        fits.isActive = true
        alphaValue = 0
        isHidden = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(current url: URL) {
        let spaces = ProjectSpaces.shared.shown(current: url)
        let currentPath = url.standardizedFileURL.path
        // Showing already: the change animates from what's on screen, so whatever else is
        // waiting for layout lands first, unanimated.
        let moves = isShown && !DS.Motion.reduceMotion
        if moves { superview?.layoutSubtreeIfNeeded() }
        let oldWidth = widthSpring.currentWidth
        if order != spaces.map(\.path) {
            row.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for space in spaces {
                let mark = marks[space.path] ?? {
                    let mark = NSImageView()
                    mark.imageScaling = .scaleProportionallyUpOrDown
                    mark.translatesAutoresizingMaskIntoConstraints = false
                    let size = mark.widthAnchor.constraint(equalToConstant: Self.otherMarkSize)
                    NSLayoutConstraint.activate([size, mark.heightAnchor.constraint(equalTo: mark.widthAnchor)])
                    marks[space.path] = mark
                    markSizes[space.path] = size
                    return mark
                }()
                row.addArrangedSubview(mark)
            }
            order = spaces.map(\.path)
        }
        dots.forEach { $0.removeFromSuperview() }
        dots = []
        for space in spaces {
            guard let mark = marks[space.path] else { continue }
            let isCurrent = space.path == currentPath
            mark.image = ProjectSpaces.mark(for: space, size: Self.currentMarkSize)
            mark.alphaValue = isCurrent ? 1 : 0.55
            markSizes[space.path]?.constant = isCurrent ? Self.currentMarkSize : Self.otherMarkSize
            row.setCustomSpacing(NSStackView.useDefaultSpacing, after: mark)
            if !isCurrent, let state = ActivityCenter.shared.attention(forProject: space.path) {
                let dot = DS.StatusDot(state: state)
                mark.addSubview(dot)
                NSLayoutConstraint.activate([
                    dot.centerXAnchor.constraint(equalTo: mark.trailingAnchor),
                    dot.centerYAnchor.constraint(equalTo: mark.bottomAnchor),
                ])
                dots.append(dot)
            }
        }
        // The name, after the current mark. Moved, not re-added, so it slides there.
        // (Removing a view that isn't arranged throws.)
        if row.arrangedSubviews.contains(name) { row.removeArrangedSubview(name) }
        if let index = spaces.firstIndex(where: { $0.path == currentPath }), let mark = marks[currentPath] {
            name.stringValue = spaces[index].name
            row.insertArrangedSubview(name, at: index + 1)
            row.setCustomSpacing(DS.Spacing.s, after: mark)
            row.setCustomSpacing(DS.Spacing.xl, after: name)
        } else {
            name.removeFromSuperview()
        }
        if moves {
            // The marks slide to their places, the glass springs to its width, and the name
            // fades in on its way to the mark it now follows.
            widthSpring.release()
            widthSpring.run(from: oldWidth, to: fittingSize.width)
            DS.Motion.animate(DS.Motion.snappy) { self.superview?.layoutSubtreeIfNeeded() }
            // From nothing, a beat late, so the marks crossing its place have gone by. (Its
            // alpha set to 0 and animated to 1 in one pass started from 1.)
            let fadeIn = CABasicAnimation(keyPath: "opacity")
            fadeIn.fromValue = 0
            fadeIn.toValue = 1
            fadeIn.beginTime = CACurrentMediaTime() + DS.Motion.glanceDuration
            fadeIn.duration = DS.Motion.presentDuration
            fadeIn.timingFunction = DS.Motion.fadeCurve
            fadeIn.fillMode = .backwards
            name.layer?.add(fadeIn, forKey: "nameFadeIn")
        }
        hide?.cancel()
        isShown = true
        isHidden = false
        DS.Motion.fade { self.animator().alphaValue = 1 }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.isShown = false
            DS.Motion.fade({ self.animator().alphaValue = 0 }, completion: { [weak self] in
                if self?.isShown == false { self?.isHidden = true }
            })
        }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }

    var isShowingForTesting: Bool { !isHidden && alphaValue > 0 }
    /// The projects' names as shown, the current one's after its mark: "·|·|side|·".
    var layoutForTesting: String { row.arrangedSubviews.map { $0 === name ? name.stringValue : "\u{00B7}" }.joined(separator: "|") }
    var widthForTesting: CGFloat { frame.width }
}
