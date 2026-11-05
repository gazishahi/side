import AppKit
import UniformTypeIdentifiers

/// A project's own logo, when its repository has one: what the project chip and the switcher
/// show before the space's symbol (the owner, 2026-11-04: "it would be neat if the repo's logo is
/// used"). Looked for in the places projects keep one, first found wins, and remembered.
@MainActor
enum ProjectLogo {
    /// Relative to the project's root, most deliberate first: a logo made for the repository,
    /// then a web project's icon, then an app's.
    static let candidates = [
        "logo.svg", "logo.png", ".github/logo.svg", ".github/logo.png", "assets/logo.svg", "assets/logo.png",
        "docs/logo.svg", "docs/logo.png", "images/logo.svg", "images/logo.png", "media/logo.svg", "media/logo.png",
        "icon.svg", "icon.png", "public/logo.svg", "public/logo.png", "public/icon.svg", "public/icon.png",
        "public/favicon.svg", "public/apple-touch-icon.png", "public/favicon.png", "static/favicon.svg", "static/favicon.png",
        "app/icon.svg", "app/icon.png", "src/app/icon.svg", "src/app/icon.png", "favicon.svg", "favicon.png", "public/favicon.ico", "favicon.ico",
    ]

    private static var cache: [String: NSImage?] = [:]

    /// The logo at `size` points, its corners rounded as an app icon's, or nil when there's none.
    static func image(for root: URL, size: CGFloat = 18) -> NSImage? {
        let path = root.standardizedFileURL.path
        let found: NSImage?
        if let cached = cache[path] {
            found = cached
        } else {
            found = find(in: root)
            cache[path] = found
        }
        guard let found else { return nil }
        return rounded(found, size: size)
    }

    /// Forgets what was found, so a logo added since is picked up.
    static func forget(_ root: URL) { cache[root.standardizedFileURL.path] = nil }

    static func find(in root: URL) -> NSImage? {
        let fm = FileManager.default
        for candidate in candidates {
            let url = root.appendingPathComponent(candidate)
            guard fm.fileExists(atPath: url.path), let image = NSImage(contentsOf: url), image.isValid, image.size.width > 0 else { continue }
            return image
        }
        // An app's icon: an Icon Composer bundle (as Side's own repository keeps it), else the
        // largest picture in an asset catalog's AppIcon set, a built `.icns` (Sill's
        // Resources/AppIcon.icns), or the one an Expo app names in its app.json. Then a
        // monorepo's packages, each looked at as a project of its own (Khidma's
        // packages/mobile, packages/frontend/public): neither was found before (2026-11-05).
        return iconComposerBundle(in: root) ?? appIconSet(in: root) ?? icns(in: root) ?? expoIcon(in: root)
            ?? workspacePackages(in: root).lazy.compactMap { package in
                candidates.lazy.compactMap { image(at: package.appendingPathComponent($0)) }.first ?? expoIcon(in: package)
            }.first
    }

    private static func image(at url: URL) -> NSImage? {
        guard FileManager.default.fileExists(atPath: url.path), let image = NSImage(contentsOf: url), image.isValid, image.size.width > 0 else { return nil }
        return image
    }

    /// A `.icns` at the root, in Resources/, or in a folder's Resources/ one down.
    private static func icns(in root: URL) -> NSImage? {
        let fm = FileManager.default
        let children = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let folders = [root, root.appendingPathComponent("Resources")]
            + children.filter { $0.hasDirectoryPath && !skippedFolders.contains($0.lastPathComponent) }.prefix(40).map { $0.appendingPathComponent("Resources") }
        for folder in folders {
            let files = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension.lowercased() == "icns" }
            // AppIcon.icns before any other a bundle carries (a document's icon).
            for file in files.sorted(by: { ($0.lastPathComponent.lowercased().hasPrefix("appicon") ? 0 : 1) < ($1.lastPathComponent.lowercased().hasPrefix("appicon") ? 0 : 1) }) {
                if let image = image(at: file) { return image }
            }
        }
        return nil
    }

    /// The icon an Expo app names in its app.json (`expo.icon`, relative to it).
    private static func expoIcon(in folder: URL) -> NSImage? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("app.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = ((json["expo"] as? [String: Any]) ?? json)["icon"] as? String else { return nil }
        return image(at: folder.appendingPathComponent(path))
    }

    /// A monorepo's packages: packages/*, apps/*.
    private static func workspacePackages(in root: URL) -> [URL] {
        ["packages", "apps"].flatMap { name -> [URL] in
            let folder = root.appendingPathComponent(name)
            let children = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            return children.filter(\.hasDirectoryPath).sorted { $0.lastPathComponent < $1.lastPathComponent }.prefix(40).map { $0 }
        }
    }

    private static let skippedFolders: Set<String> = ["node_modules", ".git", "build", "DerivedData", "Pods", ".build", "dist"]

    /// A picture the owner chose for the project (the switcher's ⋯ → Choose Icon…), drawn as a
    /// found logo is.
    static func chosen(_ file: URL, size: CGFloat = 18) -> NSImage? {
        let path = file.standardizedFileURL.path
        let found: NSImage?
        if let cached = cache[path] {
            found = cached
        } else {
            found = image(at: file)
            cache[path] = found
        }
        return found.map { rounded($0, size: size) }
    }

    /// An Icon Composer `.icon` bundle at the root or one folder down, drawn as its icon: the
    /// background fill, then each layer's artwork in its fill color (light appearance).
    private static func iconComposerBundle(in root: URL) -> NSImage? {
        let fm = FileManager.default
        let children = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let bundles = children.filter { $0.pathExtension == "icon" }
            + children.filter { $0.hasDirectoryPath && $0.pathExtension != "icon" && !["node_modules", "build", "DerivedData", "Pods"].contains($0.lastPathComponent) }.prefix(40).flatMap { folder in
                ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []).filter { $0.pathExtension == "icon" }
            }
        for bundle in bundles {
            guard let data = try? Data(contentsOf: bundle.appendingPathComponent("icon.json")),
                  let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let layers = ((manifest["groups"] as? [[String: Any]]) ?? []).flatMap { ($0["layers"] as? [[String: Any]]) ?? [] }
            let artwork: [(NSImage, NSColor?)] = layers.reversed().compactMap { layer in
                guard let name = layer["image-name"] as? String,
                      let image = NSImage(contentsOf: bundle.appendingPathComponent("Assets").appendingPathComponent(name)) else { return nil }
                let fills = (layer["fill-specializations"] as? [[String: Any]]) ?? []
                let plain = fills.first { $0["appearance"] == nil }?["value"] as? [String: Any]
                return (image, (plain?["solid"] as? String).flatMap(color) ?? (layer["fill"] as? [String: Any]).flatMap { ($0["solid"] as? String).flatMap(color) })
            }
            guard !artwork.isEmpty else { continue }
            let fill = manifest["fill"] as? [String: Any]
            let side: CGFloat = 256
            return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
                if let stops = (fill?["linear-gradient"] as? [String])?.compactMap(color), stops.count >= 2 {
                    // Icon Composer's y runs down from the top.
                    NSGradient(colors: stops)?.draw(in: rect, angle: -90)
                } else if let solid = (fill?["solid"] as? String).flatMap(color) {
                    solid.setFill()
                    rect.fill()
                } else {
                    NSColor.white.setFill()
                    rect.fill()
                }
                for (image, tint) in artwork {
                    var drawn = image
                    if let tint {
                        drawn = NSImage(size: image.size, flipped: false) { bounds in
                            image.draw(in: bounds)
                            tint.set()
                            bounds.fill(using: .sourceAtop)
                            return true
                        }
                    }
                    drawn.draw(in: rect)
                }
                return true
            }
        }
        return nil
    }

    /// "display-p3:r,g,b,a" or "srgb:…", as Icon Composer writes colors.
    private static func color(_ text: String) -> NSColor? {
        let parts = text.split(separator: ":")
        guard parts.count == 2 else { return nil }
        let values = parts[1].split(separator: ",").compactMap { Double($0) }.map { CGFloat($0) }
        guard values.count == 4 else { return nil }
        return parts[0] == "display-p3"
            ? NSColor(displayP3Red: values[0], green: values[1], blue: values[2], alpha: values[3])
            : NSColor(srgbRed: values[0], green: values[1], blue: values[2], alpha: values[3])
    }

    /// `*/Assets.xcassets/AppIcon.appiconset`, one or two folders down, as Xcode projects keep it.
    private static func appIconSet(in root: URL) -> NSImage? {
        let fm = FileManager.default
        let skipped: Set<String> = ["node_modules", ".git", "build", "DerivedData", "Pods", ".build"]
        var folders = [root]
        for _ in 0..<2 {
            var next: [URL] = []
            for folder in folders {
                let set = folder.appendingPathComponent("Assets.xcassets/AppIcon.appiconset")
                if let image = largestPNG(in: set) { return image }
                let children = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
                next += children.filter { !skipped.contains($0.lastPathComponent) && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }.prefix(40)
            }
            folders = next
        }
        return nil
    }

    private static func largestPNG(in folder: URL) -> NSImage? {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let pngs = files.filter { $0.pathExtension.lowercased() == "png" }
        func size(_ url: URL) -> Int { (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        let largest = pngs.max { size($0) < size($1) }
        return largest.flatMap { NSImage(contentsOf: $0) }
    }

    /// Drawn into a square with an app icon's rounding, so logos of any shape sit as one family.
    private static func rounded(_ image: NSImage, size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let radius = size * 0.225
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
            let aspect = image.size.width / max(image.size.height, 1)
            var target = rect
            if aspect > 1 { target.size.height = rect.width / aspect } else { target.size.width = rect.height * aspect }
            target.origin = NSPoint(x: (rect.width - target.width) / 2, y: (rect.height - target.height) / 2)
            image.draw(in: target)
            return true
        }
    }
}

extension ProjectSpaces {
    /// A project's mark: its logo, else its space's symbol in its color.
    static func mark(for space: Space, size: CGFloat = 18) -> NSImage? {
        space.logoPath.flatMap { ProjectLogo.chosen(URL(fileURLWithPath: $0), size: size) }
            ?? ProjectLogo.image(for: space.url, size: size) ?? image(for: space, pointSize: size * 0.72)
    }
}

/// The project, at the bar's leading edge: its mark in a glass disc. Click for the projects; a
/// swipe across it goes to the next or previous one. Its own control, apart from the track pill,
/// where switching projects was a row in the tracks' popover, "hard to spot" (the owner,
/// 2026-11-04).
@MainActor
final class ProjectChip: NSView {
    var onSwipeProject: ((Int) -> Void)?
    /// A click: the project switcher (`ProjectSwitcherOverlay`), which the shell shows.
    var onOpenSwitcher: (() -> Void)?
    var currentProject: (() -> URL?)?

    private let diameter: CGFloat
    private let mark = NSImageView()
    private let dot = DS.StatusDot(state: .needsYou)
    private var observers: [NSObjectProtocol] = []

    init(diameter: CGFloat) {
        self.diameter = diameter
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        let glass = DS.makeGlass(cornerRadius: diameter / 2)
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        mark.imageScaling = .scaleProportionallyDown
        mark.translatesAutoresizingMaskIntoConstraints = false
        mark.setAccessibilityElement(false)
        addSubview(mark)
        dot.isHidden = true
        dot.setAccessibilityElement(false)
        addSubview(dot)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: diameter), heightAnchor.constraint(equalToConstant: diameter),
            glass.topAnchor.constraint(equalTo: topAnchor), glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor), glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            mark.centerXAnchor.constraint(equalTo: centerXAnchor), mark.centerYAnchor.constraint(equalTo: centerYAnchor),
            mark.widthAnchor.constraint(equalToConstant: 20), mark.heightAnchor.constraint(equalToConstant: 20),
            dot.centerXAnchor.constraint(equalTo: mark.trailingAnchor, constant: 1),
            dot.centerYAnchor.constraint(equalTo: mark.topAnchor, constant: 1),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.popUpButton)
        for name in [ProjectSpaces.didChangeNotification, ActivityCenter.didChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var mouseDownCanMoveWindow: Bool { false }

    private var shownPath: String?

    func refresh() {
        guard let url = currentProject?() else {
            mark.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            mark.contentTintColor = .tertiaryLabelColor
            toolTip = nil
            dot.isHidden = true
            return
        }
        let space = ProjectSpaces.shared.space(for: url)
        // A different project's mark crossfades in, at the stage's quick project-switch pace.
        if let shown = shownPath, shown != space.path { DS.Motion.crossfade(mark, duration: ShellViewController.projectSwitchFade) }
        shownPath = space.path
        mark.image = ProjectSpaces.mark(for: space, size: 20)
        mark.contentTintColor = nil
        // Another project wants you: its dot rides on this one's mark, since only this one shows.
        let current = url.standardizedFileURL.path
        let elsewhere = ProjectSpaces.shared.spaces.lazy.filter { $0.path != current }
            .compactMap { other in ActivityCenter.shared.attentionItem(forProject: other.path).map { (other, $0) } }.first
        dot.isHidden = elsewhere == nil
        if let elsewhere { dot.state = elsewhere.1.state.status }
        // "webapp: Claude Code finished", for the project that has something to say.
        let note = elsewhere.map { "\($0.0.name): \($0.1.title) \($0.1.state.word.lowercased())" }
        toolTip = [space.name, note].compactMap { $0 }.joined(separator: "\n")
        setAccessibilityLabel("Project: \(space.name)" + (note.map { ". \($0)" } ?? ""))
    }

    override func mouseDown(with event: NSEvent) { DS.Motion.press(self, down: true, amount: ChipButton.pressScale) }
    override func mouseUp(with event: NSEvent) {
        DS.Motion.press(self, down: false, amount: ChipButton.pressScale)
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onOpenSwitcher?() }
    }
    override func accessibilityPerformPress() -> Bool { onOpenSwitcher?(); return true }

    // A two-finger swipe across it moves between projects, once per swipe.
    private var swipeTravel: CGFloat = 0
    private var swipeFired = false
    override func scrollWheel(with event: NSEvent) {
        guard event.hasPreciseScrollingDeltas, abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) || swipeTravel != 0 else {
            super.scrollWheel(with: event)
            return
        }
        if event.phase == .began { swipeTravel = 0; swipeFired = false }
        swipeTravel += event.scrollingDeltaX
        if !swipeFired, abs(swipeTravel) > 36 {
            swipeFired = true
            // Content follows the fingers: swiping left brings the next project.
            onSwipeProject?(swipeTravel < 0 ? 1 : -1)
        }
        if event.phase == .ended || event.phase == .cancelled { swipeTravel = 0; swipeFired = false }
    }

}


// MARK: - The switcher (designed with the owner, 2026-11-04)

/// One project as the switcher shows it: where it is, what it's doing, how to reach it.
struct ProjectSwitcherEntry {
    enum Openness: Equatable { case current, otherWindow, held, notOpen }
    let space: ProjectSpaces.Space
    let openness: Openness
    /// "This window · Billing", "Held · main", "Not open · yesterday".
    let place: String
    let activity: ActivityCenter.Item?
    /// "3 terminals · 2 tracks".
    let detail: String?
    let shortcut: String?
    var isOpen: Bool { openness != .notOpen }
}

@MainActor
enum ProjectSwitcherModel {
    /// What the grid shows before "More projects": as many as ⌃1–9 reach.
    static let limit = 9

    /// Open projects first (this window, another window, held), then the ones not open, most
    /// recently opened first.
    static func entries(current: URL?) -> [ProjectSwitcherEntry] {
        func key(_ url: URL) -> String { url.standardizedFileURL.path }
        let currentPath = current.map(key)
        let shells = NSApp.windows.compactMap { $0.contentViewController as? ShellViewController }
        let elsewhere = Set(shells.compactMap(\.projectRootURL).map(key)).subtracting([currentPath].compactMap { $0 })
        let contexts = ProjectContextRegistry.openContexts()
        var open: [ProjectSwitcherEntry] = [], closed: [ProjectSwitcherEntry] = []
        for (index, space) in ProjectSpaces.shared.spaces.enumerated() {
            let shortcut = index < 9 ? Shortcuts.display("project.\(index + 1)").nonEmpty : nil
            let openness: ProjectSwitcherEntry.Openness = space.path == currentPath ? .current
                : elsewhere.contains(space.path) ? .otherWindow
                : ProjectSpaces.shared.isHeld(space.url) ? .held : .notOpen
            guard openness != .notOpen else {
                let when = space.lastOpenedAt.map { " \u{00B7} " + relative.localizedString(for: $0, relativeTo: Date()) } ?? ""
                closed.append(.init(space: space, openness: .notOpen, place: "Not open" + when, activity: nil, detail: nil, shortcut: shortcut))
                continue
            }
            let context = contexts.first { key($0.projectRoot) == space.path }
            let live = context?.trackStore.tracks.filter { $0.status != .archived && $0.status != .completed } ?? []
            let active = live.first { $0.status == .active }
            let lead = openness == .current ? "This window" : openness == .otherWindow ? "Another window" : "Held"
            let trackName = active.map { $0.intent.isEmpty ? $0.branchName : $0.intent } ?? "Base"
            let terminals = SessionKeepers.liveCount(project: space.url)
            var parts: [String] = []
            if terminals > 0 { parts.append("\(terminals) terminal\(terminals == 1 ? "" : "s")") }
            if !live.isEmpty { parts.append("\(live.count) track\(live.count == 1 ? "" : "s")") }
            open.append(.init(space: space, openness: openness, place: "\(lead) \u{00B7} \(trackName)",
                              activity: ActivityCenter.shared.mostPressingItem(forProject: space.path),
                              detail: parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} "), shortcut: shortcut))
        }
        let rank: [ProjectSwitcherEntry.Openness: Int] = [.current: 0, .otherWindow: 1, .held: 2]
        open = open.enumerated().sorted { (rank[$0.element.openness] ?? 3, $0.offset) < (rank[$1.element.openness] ?? 3, $1.offset) }.map(\.element)
        closed.sort { ($0.space.lastOpenedAt ?? .distantPast) > ($1.space.lastOpenedAt ?? .distantPast) }
        return open + closed
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        return formatter
    }()

    /// A query against a project's name, as Quick Open matches: every character in order.
    static func matches(_ query: String, _ name: String) -> Bool {
        let wanted = query.lowercased().filter { !$0.isWhitespace }
        guard !wanted.isEmpty else { return true }
        var rest = Substring(name.lowercased())
        for character in wanted {
            guard let found = rest.firstIndex(of: character) else { return false }
            rest = rest[rest.index(after: found)...]
        }
        return true
    }
}

/// The project switcher: projects as cards in a panel over the window, as Spotlight opens
/// (the owner, 2026-11-04: it "gives greater importance to the list of projects"). A grid by
/// default, or a list; open projects first, then the ones not open, dimmed; nine before "More
/// projects". Type to narrow, arrows to move, Return to switch, ⌘Return for a new window, ⌘⌫ to
/// put a held project away, Escape or a click outside to leave.
@MainActor
final class ProjectSwitcherOverlay: NSView, NSTextFieldDelegate {
    enum Layout: String { case grid, list }

    var onPick: ((URL) -> Void)?
    var onOpenInNewWindow: ((URL) -> Void)?
    var onOpenProject: (() -> Void)?
    var onClose: (() -> Void)?

    static let layoutKey = "side.projectSwitcher.layout"
    static var layout: Layout {
        get { Layout(rawValue: ProjectSpaces.defaults.string(forKey: layoutKey) ?? "") ?? .grid }
        set { ProjectSpaces.defaults.set(newValue.rawValue, forKey: layoutKey) }
    }

    private let current: URL?
    private var all: [ProjectSwitcherEntry] = []
    private var shown: [ProjectSwitcherEntry] = []
    private var showingAll = false
    private(set) var selectedIndex = 0
    private var cards: [ProjectSwitcherCard] = []

    private let shadowHost = NSView()
    private let panel = NSVisualEffectView()
    private let field = NSTextField()
    private let gridButton = NSButton()
    private let listButton = NSButton()
    private let content = NSStackView()
    private let scroll = NSScrollView()
    private let hint = NSTextField(labelWithString: "")
    private let moreButton = NSButton(title: "", target: nil, action: nil)
    private var scrollHeight: NSLayoutConstraint?
    private var panelWidth: NSLayoutConstraint?
    private var observers: [NSObjectProtocol] = []
    private let openedAtPointer = NSEvent.mouseLocation

    init(current: URL?) {
        self.current = current
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.001).cgColor
        build()
        reload()
        for name in [ActivityCenter.didChangeNotification, ProjectSpaces.didChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            })
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    // MARK: Building

    private func build() {
        shadowHost.translatesAutoresizingMaskIntoConstraints = false
        shadowHost.wantsLayer = true
        shadowHost.shadow = NSShadow()
        shadowHost.layer?.shadowOpacity = 0.3
        shadowHost.layer?.shadowRadius = 28
        shadowHost.layer?.shadowOffset = CGSize(width: 0, height: -10)
        addSubview(shadowHost)

        panel.material = .popover
        panel.blendingMode = .withinWindow
        panel.state = .active
        panel.wantsLayer = true
        panel.layer?.cornerRadius = DS.Radius.palette
        panel.layer?.masksToBounds = true
        panel.translatesAutoresizingMaskIntoConstraints = false
        shadowHost.addSubview(panel)

        let searchBox = NSView()
        searchBox.bindLayerBackground(DS.Color.hoverCapsule)
        searchBox.layer?.cornerRadius = DS.Radius.surface
        let magnifier = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil) ?? NSImage())
        magnifier.symbolConfiguration = .init(pointSize: 15, weight: .medium)
        magnifier.contentTintColor = .secondaryLabelColor
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = DS.Text.custom(18)
        field.placeholderString = "Switch to a project"
        field.delegate = self
        field.setAccessibilityLabel("Find a project")
        for view in [magnifier, field] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false; searchBox.addSubview(view) }
        searchBox.translatesAutoresizingMaskIntoConstraints = false

        for (button, symbol, label) in [(gridButton, "square.grid.2x2", "Grid"), (listButton, "list.bullet", "List")] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.symbolConfiguration = .init(pointSize: 13, weight: .medium)
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.cornerRadius = DS.Radius.capsule(height: 26)
            button.target = self
            button.action = #selector(layoutTapped(_:))
            button.toolTip = label
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([button.widthAnchor.constraint(equalToConstant: 34), button.heightAnchor.constraint(equalToConstant: 26)])
        }
        let toggle = NSStackView(views: [gridButton, listButton])
        toggle.spacing = 2
        toggle.edgeInsets = NSEdgeInsets(top: 3, left: 3, bottom: 3, right: 3)
        toggle.wantsLayer = true
        toggle.bindLayerBackground(DS.Color.hoverCapsule)
        toggle.layer?.cornerRadius = DS.Radius.capsule(height: 32)

        let header = NSStackView(views: [searchBox, toggle])
        header.spacing = DS.Spacing.l
        header.alignment = .centerY

        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = DS.Spacing.m
        content.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        hint.font = DS.Text.caption()
        hint.textColor = .secondaryLabelColor
        hint.stringValue = "Return opens \u{00B7} \u{2318}Return in a new window \u{00B7} \u{2318}\u{232B} puts a project away"
        moreButton.isBordered = false
        moreButton.target = self
        moreButton.action = #selector(moreTapped)
        let open = NSButton(title: "", target: self, action: #selector(openTapped))
        open.isBordered = false
        open.attributedTitle = NSAttributedString(string: "Open Project\u{2026}", attributes: [.font: DS.Text.body(.medium), .foregroundColor: NSColor.controlAccentColor])
        let footer = NSStackView(views: [hint, NSView(), moreButton, open])
        footer.spacing = DS.Spacing.xl
        footer.alignment = .centerY

        let column = NSStackView(views: [header, scroll, footer])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = DS.Spacing.xl
        column.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(column)

        let height = scroll.heightAnchor.constraint(equalToConstant: 100)
        scrollHeight = height
        let width = shadowHost.widthAnchor.constraint(equalToConstant: 760)
        panelWidth = width
        NSLayoutConstraint.activate([
            shadowHost.centerXAnchor.constraint(equalTo: centerXAnchor),
            shadowHost.topAnchor.constraint(equalTo: topAnchor, constant: 110),
            width,
            panel.topAnchor.constraint(equalTo: shadowHost.topAnchor), panel.bottomAnchor.constraint(equalTo: shadowHost.bottomAnchor),
            panel.leadingAnchor.constraint(equalTo: shadowHost.leadingAnchor), panel.trailingAnchor.constraint(equalTo: shadowHost.trailingAnchor),
            column.topAnchor.constraint(equalTo: panel.topAnchor, constant: 16), column.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -14),
            column.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16), column.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -16),
            header.widthAnchor.constraint(equalTo: column.widthAnchor), footer.widthAnchor.constraint(equalTo: column.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: column.widthAnchor), height,
            searchBox.heightAnchor.constraint(equalToConstant: 44),
            magnifier.leadingAnchor.constraint(equalTo: searchBox.leadingAnchor, constant: 14), magnifier.centerYAnchor.constraint(equalTo: searchBox.centerYAnchor),
            field.leadingAnchor.constraint(equalTo: magnifier.trailingAnchor, constant: 10), field.trailingAnchor.constraint(equalTo: searchBox.trailingAnchor, constant: -12),
            field.centerYAnchor.constraint(equalTo: searchBox.centerYAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            content.topAnchor.constraint(equalTo: document.topAnchor), content.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor), content.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
    }

    // MARK: Contents

    private func reload() {
        all = ProjectSwitcherModel.entries(current: current)
        rebuild(keepingSelection: true)
    }

    private func rebuild(keepingSelection: Bool) {
        let selectedPath = keepingSelection && shown.indices.contains(selectedIndex) ? shown[selectedIndex].space.path : nil
        let query = field.stringValue
        let matching = all.filter { ProjectSwitcherModel.matches(query, $0.space.name) }
        shown = showingAll || !query.isEmpty ? matching : Array(matching.prefix(ProjectSwitcherModel.limit))
        let hidden = matching.count - shown.count
        moreButton.isHidden = hidden <= 0
        moreButton.attributedTitle = NSAttributedString(string: "More projects (\(hidden))\u{2026}", attributes: [.font: DS.Text.body(), .foregroundColor: NSColor.controlAccentColor])

        let layout = Self.layout
        panelWidth?.constant = layout == .grid ? 760 : 640
        for (button, mode) in [(gridButton, Layout.grid), (listButton, .list)] {
            let on = layout == mode
            button.contentTintColor = on ? .labelColor : .secondaryLabelColor
            Self.paint(button, on ? DS.Color.selectedCapsule : .clear)
            button.setAccessibilityValue(on ? "selected" : nil)
        }
        content.arrangedSubviews.forEach { $0.removeFromSuperview() }
        cards = shown.enumerated().map { index, entry in
            let card = ProjectSwitcherCard(entry: entry, style: layout)
            card.onPick = { [weak self] in self?.pick(index, newWindow: false) }
            card.onMenu = { [weak self, weak card] in
                guard let self, let card else { return }
                self.menu(for: entry).popUp(positioning: nil, at: NSPoint(x: card.bounds.maxX - 28, y: card.bounds.maxY - 4), in: card)
            }
            card.onPutAway = { [weak self] in self?.putAway(entry) }
            card.onHover = { [weak self] in
                // Only a pointer that moved picks: one resting where the panel opened would take
                // Return's project from the keyboard (found in the switcher's own check).
                guard let self, NSEvent.mouseLocation != self.openedAtPointer else { return }
                self.select(index)
            }
            return card
        }
        if layout == .grid {
            for start in stride(from: 0, to: cards.count, by: 3) {
                var row = Array(cards[start..<min(start + 3, cards.count)]) as [NSView]
                while row.count < 3 { row.append(NSView()) }
                let line = NSStackView(views: row)
                line.distribution = .fillEqually
                line.spacing = DS.Spacing.m
                line.alignment = .top
                content.addArrangedSubview(line)
                line.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
                // One height per row: the tallest card's.
                for view in row where view is ProjectSwitcherCard { view.heightAnchor.constraint(equalTo: line.heightAnchor).isActive = true }
            }
        } else {
            content.spacing = 2
            var headed = false
            for card in cards {
                if !card.entry.isOpen, !headed {
                    headed = true
                    let heading = NSTextField(labelWithString: "Not open")
                    heading.font = DS.Text.caption(.semibold)
                    heading.textColor = .secondaryLabelColor
                    let inset = NSStackView(views: [heading])
                    inset.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 2, right: 12)
                    content.addArrangedSubview(inset)
                }
                content.addArrangedSubview(card)
                card.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
            }
        }
        content.spacing = layout == .grid ? DS.Spacing.m : 2
        if shown.isEmpty {
            let none = NSTextField(labelWithString: query.isEmpty ? "No projects yet. Open one to start." : "No project matches \u{201C}\(query)\u{201D}.")
            none.font = DS.Text.body()
            none.textColor = .secondaryLabelColor
            content.addArrangedSubview(none)
        }
        if let selectedPath, let index = shown.firstIndex(where: { $0.space.path == selectedPath }) {
            selectedIndex = index
        } else {
            // Return goes somewhere new: the first project that isn't this window's.
            selectedIndex = shown.firstIndex { $0.openness != .current } ?? 0
            if !query.isEmpty { selectedIndex = 0 }
        }
        applySelection()
        fitScroll()
    }

    /// As tall as the projects, up to what the window has room for.
    private func fitScroll() {
        guard bounds.height > 0 else { needsLayout = true; return }
        content.layoutSubtreeIfNeeded()
        let fitting = content.fittingSize.height
        let room = max(160, bounds.height - 110 - 170)
        let height = min(max(fitting, 60), room)
        if scrollHeight?.constant != height { scrollHeight?.constant = height }
    }

    /// A layer's color, resolved in this view's appearance: one resolved before the view was in
    /// its window came out in the app's other appearance (found on screen, 2026-11-04).
    static func paint(_ view: NSView, _ color: NSColor) {
        view.wantsLayer = true
        view.effectiveAppearance.performAsCurrentDrawingAppearance { view.layer?.backgroundColor = color.cgColor }
    }

    private func applySelection() {
        for (index, card) in cards.enumerated() { card.isSelected = index == selectedIndex }
        if cards.indices.contains(selectedIndex) { cards[selectedIndex].scrollToVisible(cards[selectedIndex].bounds) }
    }

    private func select(_ index: Int) {
        guard cards.indices.contains(index), index != selectedIndex else { return }
        selectedIndex = index
        applySelection()
    }

    // MARK: Actions

    private func pick(_ index: Int, newWindow: Bool) {
        guard shown.indices.contains(index) else { return }
        let url = shown[index].space.url
        onClose?()
        if newWindow { onOpenInNewWindow?(url) } else { onPick?(url) }
    }

    /// A held project put away; one with work in flight asks first.
    private func putAway(_ entry: ProjectSwitcherEntry) {
        guard entry.openness == .held else { NSSound.beep(); return }
        let working = entry.activity?.state == .working
        guard working, let window else {
            ProjectSpaces.shared.putAway(entry.space.url)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Put \u{201C}\(entry.space.name)\u{201D} away?"
        alert.informativeText = "\(entry.activity?.title ?? "An agent") is working in it, and stops. You can open the project again from here."
        alert.addButton(withTitle: "Put Away")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated { ProjectSpaces.shared.putAway(entry.space.url) }
        }
    }

    /// The card's ⋯: open it in a new window, show it in Finder, its color and symbol, and put it
    /// away (held) or off the list (not open).
    private func menu(for entry: ProjectSwitcherEntry) -> NSMenu {
        let menu = NSMenu()
        func item(_ title: String, _ action: @escaping () -> Void) {
            let item = NSMenuItem(title: title, action: #selector(MenuAction.run(_:)), keyEquivalent: "")
            let box = MenuAction(action)
            item.target = box
            item.representedObject = box
            menu.addItem(item)
        }
        let url = entry.space.url
        if entry.openness != .current { item("Open in New Window") { [weak self] in self?.onClose?(); self?.onOpenInNewWindow?(url) } }
        item("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        menu.addItem(.separator())
        let colors = NSMenu()
        for (index, color) in ProjectSpaces.palette.enumerated() {
            let choice = NSMenuItem(title: Self.colorNames[index], action: #selector(MenuAction.run(_:)), keyEquivalent: "")
            let box = MenuAction { ProjectSpaces.shared.set(colorIndex: index, for: url) }
            choice.target = box
            choice.representedObject = box
            choice.state = index == entry.space.colorIndex % ProjectSpaces.palette.count ? .on : .off
            choice.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?.withSymbolConfiguration(.init(paletteColors: [color]))
            colors.addItem(choice)
        }
        let colorItem = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        colorItem.submenu = colors
        menu.addItem(colorItem)
        let symbols = NSMenu()
        for symbol in ProjectSpaces.symbols {
            let choice = NSMenuItem(title: "", action: #selector(MenuAction.run(_:)), keyEquivalent: "")
            let box = MenuAction { ProjectSpaces.shared.set(symbol: symbol, for: url) }
            choice.target = box
            choice.representedObject = box
            choice.image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)
            choice.state = symbol == entry.space.symbol ? .on : .off
            symbols.addItem(choice)
        }
        let symbolItem = NSMenuItem(title: "Symbol (without a logo)", action: nil, keyEquivalent: "")
        symbolItem.submenu = symbols
        menu.addItem(symbolItem)
        item("Choose Icon\u{2026}") { [weak self] in self?.chooseIcon(for: url) }
        if entry.space.logoPath != nil {
            item("Use the Project\u{2019}s Own Icon") { ProjectSpaces.shared.set(logo: nil, for: url) }
        }
        switch entry.openness {
        case .held:
            menu.addItem(.separator())
            item("Put Away") { [weak self] in self?.putAway(entry) }
        case .notOpen:
            menu.addItem(.separator())
            item("Remove from Recents") { ProjectSpaces.shared.remove(url) }
        case .current, .otherWindow:
            break
        }
        return menu
    }

    /// A picture of the owner's for the project's mark, when the one found isn't right or there's
    /// none to find.
    private func chooseIcon(for project: URL) {
        let panel = NSOpenPanel()
        panel.message = "Choose a picture for \u{201C}\(project.lastPathComponent)\u{201D}"
        panel.prompt = "Use Icon"
        panel.allowedContentTypes = [.image]
        panel.directoryURL = project
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        onClose?()
        panel.begin { response in
            guard response == .OK, let file = panel.url else { return }
            MainActor.assumeIsolated { ProjectSpaces.shared.set(logo: file, for: project) }
        }
    }

    private static let colorNames = ["Graphite", "Blue", "Purple", "Pink", "Red", "Orange", "Yellow", "Green", "Teal"]

    @objc private func layoutTapped(_ sender: NSButton) {
        Self.layout = sender === gridButton ? .grid : .list
        rebuild(keepingSelection: true)
    }

    @objc private func moreTapped() {
        showingAll = true
        Self.layout = .list
        rebuild(keepingSelection: true)
    }

    @objc private func openTapped() {
        onClose?()
        onOpenProject?()
    }

    func controlTextDidChange(_ obj: Notification) { rebuild(keepingSelection: false) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        let columns = Self.layout == .grid ? 3 : 1
        let command = NSApp.currentEvent?.modifierFlags.contains(.command) == true
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(columns); return true
        case #selector(NSResponder.moveUp(_:)): move(-columns); return true
        case #selector(NSResponder.moveRight(_:)) where columns > 1 && textView.string.isEmpty: move(1); return true
        case #selector(NSResponder.moveLeft(_:)) where columns > 1 && textView.string.isEmpty: move(-1); return true
        case #selector(NSResponder.insertTab(_:)): move(1); return true
        case #selector(NSResponder.insertBacktab(_:)): move(-1); return true
        case #selector(NSResponder.insertNewline(_:)): pick(selectedIndex, newWindow: command); return true
        case #selector(NSResponder.cancelOperation(_:)): onClose?(); return true
        case #selector(NSResponder.deleteToBeginningOfLine(_:)) where textView.string.isEmpty,
             #selector(NSResponder.deleteBackward(_:)) where command && textView.string.isEmpty:
            if shown.indices.contains(selectedIndex) { putAway(shown[selectedIndex]) }
            return true
        default: return false
        }
    }

    private func move(_ delta: Int) {
        guard !cards.isEmpty else { return }
        selectedIndex = min(max(selectedIndex + delta, 0), cards.count - 1)
        applySelection()
    }

    func focus() { window?.makeFirstResponder(field) }

    override func mouseDown(with event: NSEvent) {
        // A click outside the panel leaves.
        if !shadowHost.frame.contains(convert(event.locationInWindow, from: nil)) { onClose?() }
    }

    override func layout() {
        super.layout()
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.backgroundColor = NSColor.black.withAlphaComponent(dark ? 0.4 : 0.12).cgColor
        fitScroll()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        rebuild(keepingSelection: true)
    }

    // MARK: Testing

    var entryNamesForTesting: [String] { shown.map(\.space.name) }
    var selectedNameForTesting: String? { shown.indices.contains(selectedIndex) ? shown[selectedIndex].space.name : nil }
    func typeForTesting(_ text: String) { field.stringValue = text; rebuild(keepingSelection: false) }
    func commandForTesting(_ selector: Selector) {
        guard let editor = field.currentEditor() as? NSTextView else { _ = control(field, textView: NSTextView(), doCommandBy: selector); return }
        _ = control(field, textView: editor, doCommandBy: selector)
    }
    var isShowingMoreForTesting: Bool { !moreButton.isHidden }
    var framesForTesting: String { "overlay \(frame) panel \(shadowHost.frame) scroll \(scrollHeight?.constant ?? 0) content \(content.fittingSize.height)" }
}

/// A menu item's action as a closure.
@MainActor
private final class MenuAction: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run(_ sender: Any?) { action() }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// One project in the switcher, a card (grid) or a row (list): its mark, name and place, what
/// it's doing, its terminals and tracks; ⋯ and, held, × on hover. A project that isn't open is
/// dimmed, on no fill, and says so (no outline: nothing in Side is enclosed by a border).
@MainActor
final class ProjectSwitcherCard: NSView {
    var onPick: (() -> Void)?
    var onMenu: (() -> Void)?
    var onPutAway: (() -> Void)?
    var onHover: (() -> Void)?
    var isSelected = false { didSet { refreshBackground() } }
    let entry: ProjectSwitcherEntry
    private var hovered = false { didSet { refreshBackground(); refreshTrailing() } }
    private let shortcut = NSTextField(labelWithString: "")
    private let menuButton = NSButton()
    private let closeButton = NSButton()

    init(entry: ProjectSwitcherEntry, style: ProjectSwitcherOverlay.Layout) {
        self.entry = entry
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = DS.Radius.surface
        let markSize: CGFloat = style == .grid ? 32 : 28
        let mark = NSImageView(image: ProjectSpaces.mark(for: entry.space, size: markSize) ?? NSImage())
        mark.imageScaling = .scaleProportionallyUpOrDown
        mark.translatesAutoresizingMaskIntoConstraints = false
        let name = NSTextField(labelWithString: entry.space.name)
        name.font = style == .grid ? DS.Text.heading() : DS.Text.body(.semibold)
        name.lineBreakMode = .byTruncatingTail
        let place = NSTextField(labelWithString: entry.place)
        place.font = DS.Text.caption()
        place.textColor = .secondaryLabelColor
        place.lineBreakMode = .byTruncatingTail
        let titles = NSStackView(views: [name, place])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 1
        titles.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        shortcut.stringValue = entry.shortcut ?? ""
        shortcut.font = DS.Text.caption()
        shortcut.textColor = .tertiaryLabelColor
        for (button, symbol, label) in [(menuButton, "ellipsis", "More for \(entry.space.name)"), (closeButton, "xmark", "Put \(entry.space.name) away")] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
            button.isBordered = false
            button.wantsLayer = true
            button.bindLayerBackground(DS.Color.hoverCapsule)
            button.layer?.cornerRadius = DS.Radius.capsule(height: 24)
            button.contentTintColor = .secondaryLabelColor
            button.target = self
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([button.widthAnchor.constraint(equalToConstant: 24), button.heightAnchor.constraint(equalToConstant: 24)])
        }
        menuButton.action = #selector(menuTapped)
        closeButton.action = #selector(closeTapped)
        let trailing = NSStackView(views: [shortcut, menuButton, closeButton])
        trailing.spacing = 2
        trailing.setContentHuggingPriority(.required, for: .horizontal)

        var activityView: NSView?
        if let activity = entry.activity {
            let label = DS.StatusLabel(state: activity.state.status, text: "\(activity.state.word) \u{00B7} \(activity.title)")
            activityView = label
        } else if !entry.isOpen {
            let label = NSTextField(labelWithString: "Opens as you left it")
            label.font = DS.Text.caption()
            label.textColor = .secondaryLabelColor
            activityView = label
        }
        let detail = entry.detail.map { text -> NSTextField in
            let label = NSTextField(labelWithString: text)
            label.font = DS.Text.caption()
            label.textColor = .secondaryLabelColor
            return label
        }

        let root: NSStackView
        if style == .grid {
            let top = NSStackView(views: [mark, titles, NSView(), trailing])
            top.spacing = DS.Spacing.l
            top.alignment = .top
            root = NSStackView(views: [top] + [activityView, detail].compactMap { $0 })
            root.orientation = .vertical
            root.alignment = .leading
            root.spacing = DS.Spacing.l
            root.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
            top.translatesAutoresizingMaskIntoConstraints = false
            top.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -24).isActive = true
            titles.centerYAnchor.constraint(equalTo: mark.centerYAnchor).isActive = true
            heightAnchor.constraint(greaterThanOrEqualToConstant: 64).isActive = true
        } else {
            titles.widthAnchor.constraint(equalToConstant: 170).isActive = true
            let middle = NSStackView(views: [activityView, detail].compactMap { $0 })
            middle.spacing = DS.Spacing.m
            middle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            root = NSStackView(views: [mark, titles, middle, NSView(), trailing])
            root.spacing = DS.Spacing.xl
            root.alignment = .centerY
            root.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
            heightAnchor.constraint(equalToConstant: entry.isOpen ? 52 : 44).isActive = true
        }
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        NSLayoutConstraint.activate([
            mark.widthAnchor.constraint(equalToConstant: markSize), mark.heightAnchor.constraint(equalToConstant: markSize),
            root.topAnchor.constraint(equalTo: topAnchor), root.bottomAnchor.constraint(equalTo: bottomAnchor),
            root.leadingAnchor.constraint(equalTo: leadingAnchor), root.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        // Not open: the card is quieter, and says so in words too.
        if !entry.isOpen { root.alphaValue = 0.62 }
        refreshBackground()
        refreshTrailing()
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        let state = entry.activity.map { ", \($0.state.word)" } ?? ""
        setAccessibilityLabel("\(entry.space.name), \(entry.place)\(state)")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Selected, Side's selected capsule; an open project at rest, the hover capsule; one not open,
    /// none (it's dimmed, and says so). Resolved in the card's own appearance.
    private func refreshBackground() {
        let fill: NSColor = isSelected ? DS.Color.selectedCapsule : entry.isOpen ? DS.Color.hoverCapsule : .clear
        ProjectSwitcherOverlay.paint(self, fill)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshBackground()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshBackground()
    }

    /// The shortcut at rest; ⋯ (and × for a held project) on hover.
    private func refreshTrailing() {
        shortcut.isHidden = hovered || entry.shortcut == nil
        menuButton.isHidden = !hovered
        closeButton.isHidden = !hovered || entry.openness != .held
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; onHover?() }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { onPick?() } }
    override func rightMouseDown(with event: NSEvent) { onMenu?() }
    override func accessibilityPerformPress() -> Bool { onPick?(); return true }
    @objc private func menuTapped() { onMenu?() }
    @objc private func closeTapped() { onPutAway?() }

    func hoverForTesting(_ on: Bool) { hovered = on }
    var showsPutAwayForTesting: Bool { !closeButton.isHidden }
}

/// ⌃⇥ held: the projects as tiles in a small panel at the window's centre, the next one picked;
/// ⇥ again moves on, ⌃⇧⇥ back, letting go of ⌃ switches, Escape stays. As the system's app
/// switcher works, with each tile's status dot and a line for the one picked.
@MainActor
final class ProjectCycleStrip: NSView {
    private(set) var entries: [ProjectSwitcherEntry]
    private(set) var selectedIndex: Int
    private var tiles: [NSView] = []
    private let line = NSStackView()
    private let panel = NSVisualEffectView()

    init(entries: [ProjectSwitcherEntry], start: Int) {
        self.entries = entries
        self.selectedIndex = start
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        shadow = NSShadow()
        layer?.shadowOpacity = 0.3
        layer?.shadowRadius = 24
        layer?.shadowOffset = CGSize(width: 0, height: -8)
        panel.material = .popover
        panel.blendingMode = .withinWindow
        panel.state = .active
        panel.wantsLayer = true
        panel.layer?.cornerRadius = DS.Radius.palette
        panel.layer?.masksToBounds = true
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)
        let row = NSStackView()
        row.spacing = DS.Spacing.s
        for entry in entries {
            let tile = NSView()
            tile.wantsLayer = true
            tile.layer?.cornerRadius = DS.Radius.surface
            tile.translatesAutoresizingMaskIntoConstraints = false
            let mark = NSImageView(image: ProjectSpaces.mark(for: entry.space, size: 52) ?? NSImage())
            mark.imageScaling = .scaleProportionallyUpOrDown
            mark.translatesAutoresizingMaskIntoConstraints = false
            if !entry.isOpen { mark.alphaValue = 0.55 }
            let name = NSTextField(labelWithString: entry.space.name)
            name.font = DS.Text.caption(.medium)
            name.lineBreakMode = .byTruncatingTail
            name.alignment = .center
            name.textColor = entry.isOpen ? .labelColor : .secondaryLabelColor
            name.translatesAutoresizingMaskIntoConstraints = false
            tile.addSubview(mark)
            tile.addSubview(name)
            var constraints = [
                tile.widthAnchor.constraint(equalToConstant: 104), tile.heightAnchor.constraint(equalToConstant: 98),
                mark.widthAnchor.constraint(equalToConstant: 52), mark.heightAnchor.constraint(equalToConstant: 52),
                mark.centerXAnchor.constraint(equalTo: tile.centerXAnchor), mark.topAnchor.constraint(equalTo: tile.topAnchor, constant: 12),
                name.topAnchor.constraint(equalTo: mark.bottomAnchor, constant: 8),
                name.leadingAnchor.constraint(equalTo: tile.leadingAnchor, constant: 6), name.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: -6),
            ]
            if let activity = entry.activity {
                let dot = DS.StatusDot(state: activity.state.status)
                dot.translatesAutoresizingMaskIntoConstraints = false
                tile.addSubview(dot)
                constraints += [dot.centerXAnchor.constraint(equalTo: mark.trailingAnchor, constant: -2), dot.centerYAnchor.constraint(equalTo: mark.topAnchor, constant: 2)]
            }
            NSLayoutConstraint.activate(constraints)
            row.addArrangedSubview(tile)
            tiles.append(tile)
        }
        line.spacing = DS.Spacing.s
        let column = NSStackView(views: [row, line])
        column.orientation = .vertical
        column.spacing = DS.Spacing.xl
        column.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 14, right: 16)
        column.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(column)
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: topAnchor), panel.bottomAnchor.constraint(equalTo: bottomAnchor),
            panel.leadingAnchor.constraint(equalTo: leadingAnchor), panel.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: panel.topAnchor), column.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            column.leadingAnchor.constraint(equalTo: panel.leadingAnchor), column.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
        ])
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func move(_ delta: Int) {
        guard !entries.isEmpty else { return }
        selectedIndex = ((selectedIndex + delta) % entries.count + entries.count) % entries.count
        refresh()
    }

    var selected: ProjectSwitcherEntry? { entries.indices.contains(selectedIndex) ? entries[selectedIndex] : nil }

    private func refresh() {
        for (index, tile) in tiles.enumerated() { ProjectSwitcherOverlay.paint(tile, index == selectedIndex ? DS.Color.selectedCapsule : .clear) }
        line.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let entry = selected else { return }
        if let activity = entry.activity {
            line.addArrangedSubview(DS.StatusLabel(state: activity.state.status, text: "\(activity.state.word) \u{00B7} \(activity.title)"))
        } else {
            let place = NSTextField(labelWithString: "\(entry.space.name) \u{00B7} \(entry.place)")
            place.font = DS.Text.caption()
            place.textColor = .secondaryLabelColor
            line.addArrangedSubview(place)
        }
    }
}
