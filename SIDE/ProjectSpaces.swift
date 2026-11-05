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
@MainActor
final class ProjectIndicator: NSView {
    private let row = NSStackView()
    private var hide: DispatchWorkItem?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        let glass = DS.makeGlass(cornerRadius: DS.Radius.capsule(height: 34))
        addSubview(glass)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = DS.Spacing.m
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor), glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor), glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(equalToConstant: 34),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DS.Spacing.xl),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DS.Spacing.xl),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        alphaValue = 0
        isHidden = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(current url: URL) {
        row.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let currentPath = url.standardizedFileURL.path
        for space in ProjectSpaces.shared.shown(current: url) {
            let isCurrent = space.path == currentPath
            let icon = NSImageView(image: ProjectSpaces.image(for: space, pointSize: isCurrent ? 13 : 11) ?? NSImage())
            icon.alphaValue = isCurrent ? 1 : 0.55
            row.addArrangedSubview(icon)
            if !isCurrent, let state = ActivityCenter.shared.attention(forProject: space.path) {
                let dot = DS.StatusDot(state: state)
                icon.addSubview(dot)
                NSLayoutConstraint.activate([
                    dot.centerXAnchor.constraint(equalTo: icon.trailingAnchor),
                    dot.centerYAnchor.constraint(equalTo: icon.bottomAnchor),
                ])
            }
            if isCurrent {
                let name = NSTextField(labelWithString: space.name)
                name.font = DS.Text.body(.medium)
                row.addArrangedSubview(name)
                row.setCustomSpacing(DS.Spacing.xl, after: name)
                row.setCustomSpacing(DS.Spacing.s, after: icon)
            }
        }
        hide?.cancel()
        isHidden = false
        DS.Motion.fade { self.animator().alphaValue = 1 }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            DS.Motion.fade({ self.animator().alphaValue = 0 }, completion: { [weak self] in
                if self?.alphaValue == 0 { self?.isHidden = true }
            })
        }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }

    var isShowingForTesting: Bool { !isHidden && alphaValue > 0 }
}
