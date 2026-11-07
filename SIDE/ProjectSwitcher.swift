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

/// The project switcher (⌃⌘P, the project chip): a glass panel that grows out of the stage bar,
/// as the palette and Find do (SIDE_DESIGN_POLISH_0.5.md §2). Open projects first, then the ones
/// not open, dimmed; nine before "Show more". A list, or cards (Settings → General). Type to
/// narrow, arrows to move, Return to switch, ⌘Return for a new window, ⌘⌫ to put a held project
/// away, Escape or a click outside to leave.
@MainActor
final class ProjectSwitcherOverlay: NSView, NSTextFieldDelegate {
    enum Layout: String, CaseIterable {
        case list, grid
        var title: String { self == .list ? "List" : "Grid" }
    }

    var onPick: ((URL) -> Void)?
    var onOpenInNewWindow: ((URL) -> Void)?
    var onOpenProject: (() -> Void)?
    var onClose: (() -> Void)?
    /// Where the panel goes for a size: above the stage bar, centred (the shell's chrome).
    var placePanel: ((NSSize) -> NSRect)?

    /// A list unless chosen otherwise (the owner, 2026-11-05). A new key: the old toggle's saved
    /// "grid" would otherwise outlive the decision.
    static let layoutKey = "side.projectSwitcher.style"
    static var layout: Layout {
        get { Layout(rawValue: ProjectSpaces.defaults.string(forKey: layoutKey) ?? "") ?? .list }
        set { ProjectSpaces.defaults.set(newValue.rawValue, forKey: layoutKey); NotificationCenter.default.post(name: layoutDidChange, object: nil) }
    }
    static let layoutDidChange = Notification.Name("SideProjectSwitcherLayoutDidChange")

    static let listWidth: CGFloat = 560
    static let gridWidth: CGFloat = 700
    static let headerHeight: CGFloat = 54
    static let footerHeight: CGFloat = 40
    static let rowHeight: CGFloat = 48

    private let current: URL?
    private var all: [ProjectSwitcherEntry] = []
    private var shown: [ProjectSwitcherEntry] = []
    private var showingAll = false
    private(set) var selectedIndex = 0
    private var cards: [ProjectSwitcherCard] = []

    /// What grows out of the bar: the surface and its shadow.
    let panelHost = NSView()
    private let field = NSTextField()
    private let content = NSStackView()
    private let document = FlippedView()
    private let scroll = NSScrollView()
    private let selection = DS.Fill(DS.Color.selectedCapsule, cornerRadius: DS.Radius.surface)
    private let hint = NSTextField(labelWithString: "")
    private var scrollHeight: NSLayoutConstraint?
    private var observers: [NSObjectProtocol] = []
    private let openedAtPointer = NSEvent.mouseLocation

    init(current: URL?) {
        self.current = current
        super.init(frame: .zero)
        build()
        reload()
        for name in [ActivityCenter.didChangeNotification, ProjectSpaces.didChangeNotification, Self.layoutDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            })
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    // MARK: Building

    private func build() {
        panelHost.wantsLayer = true
        // Glass brings its own depth on macOS 26; before it, a shadow under the popover material.
        if DS.Surfaces.needsShadow {
            panelHost.shadow = NSShadow()
            panelHost.layer?.shadowOpacity = 0.18
            panelHost.layer?.shadowRadius = 18
            panelHost.layer?.shadowOffset = CGSize(width: 0, height: -4)
        }
        addSubview(panelHost)

        let magnifier = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil) ?? NSImage())
        magnifier.symbolConfiguration = .init(pointSize: 14, weight: .medium)
        magnifier.contentTintColor = .secondaryLabelColor
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = DS.Text.custom(16)
        field.placeholderString = "Switch to a project"
        field.delegate = self
        field.setAccessibilityLabel("Find a project")
        let header = NSView()
        for view in [magnifier, field] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false; header.addSubview(view) }

        let divider = NSBox()
        divider.boxType = .custom
        divider.borderWidth = 0
        divider.fillColor = DS.Color.hairline

        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 2
        content.translatesAutoresizingMaskIntoConstraints = false
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(selection)
        document.addSubview(content)
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)

        // Keys, not sentences: a glyph and a word each.
        hint.attributedStringValue = Self.hints([("\u{21A9}", "Open"), ("\u{2318}\u{21A9}", "New Window"), ("\u{2318}\u{232B}", "Close")])
        let open = NSButton(title: "", target: self, action: #selector(openTapped))
        open.isBordered = false
        let openKeys = Shortcuts.display("file.openProject")
        let openTitle = NSMutableAttributedString(string: "Open\u{2026}", attributes: [.font: DS.Text.caption(.medium), .foregroundColor: DS.Color.accent])
        if !openKeys.isEmpty { openTitle.append(NSAttributedString(string: "  " + openKeys, attributes: [.font: DS.Text.caption(), .foregroundColor: NSColor.tertiaryLabelColor])) }
        open.attributedTitle = openTitle
        open.setAccessibilityLabel("Open a project")
        let footer = NSStackView(views: [hint, NSView(), open])
        footer.alignment = .centerY
        footer.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 14)

        let body = NSView()
        for view in [header, divider, scroll, footer] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false; body.addSubview(view) }
        let surface = DS.makeFloatingSurface(embedding: body)
        surface.frame = panelHost.bounds
        surface.autoresizingMask = [.width, .height]
        panelHost.addSubview(surface)

        let height = scroll.heightAnchor.constraint(equalToConstant: Self.rowHeight)
        scrollHeight = height
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: body.topAnchor), header.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: body.trailingAnchor), header.heightAnchor.constraint(equalToConstant: Self.headerHeight),
            magnifier.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 18), magnifier.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            field.leadingAnchor.constraint(equalTo: magnifier.trailingAnchor, constant: 10), field.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16),
            field.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            divider.topAnchor.constraint(equalTo: header.bottomAnchor), divider.heightAnchor.constraint(equalToConstant: 1),
            divider.leadingAnchor.constraint(equalTo: body.leadingAnchor), divider.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: divider.bottomAnchor), scroll.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -6), height,
            footer.topAnchor.constraint(equalTo: scroll.bottomAnchor), footer.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: body.trailingAnchor), footer.heightAnchor.constraint(equalToConstant: Self.footerHeight),
            footer.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            content.topAnchor.constraint(equalTo: document.topAnchor), content.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor), content.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
    }

    /// "↩ Open   ⌘↩ New Window": keys a step brighter than their words.
    static func hints(_ pairs: [(String, String)]) -> NSAttributedString {
        let text = NSMutableAttributedString()
        for (index, (keys, word)) in pairs.enumerated() {
            if index > 0 { text.append(NSAttributedString(string: "    ")) }
            text.append(NSAttributedString(string: keys + " ", attributes: [.font: DS.Text.caption(.medium), .foregroundColor: NSColor.secondaryLabelColor]))
            text.append(NSAttributedString(string: word, attributes: [.font: DS.Text.caption(), .foregroundColor: NSColor.tertiaryLabelColor]))
        }
        return text
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

        let layout = Self.layout
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
            content.spacing = DS.Spacing.s
            for start in stride(from: 0, to: cards.count, by: 3) {
                var row = Array(cards[start..<min(start + 3, cards.count)]) as [NSView]
                while row.count < 3 { row.append(NSView()) }
                let line = NSStackView(views: row)
                line.distribution = .fillEqually
                line.spacing = DS.Spacing.s
                line.alignment = .top
                content.addArrangedSubview(line)
                line.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
                for view in row where view is ProjectSwitcherCard { view.heightAnchor.constraint(equalTo: line.heightAnchor).isActive = true }
            }
        } else {
            content.spacing = 2
            var headed = false
            for card in cards {
                if !card.entry.isOpen, !headed {
                    headed = true
                    content.addArrangedSubview(Self.heading("Not open"))
                }
                content.addArrangedSubview(card)
                card.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
            }
        }
        if hidden > 0 {
            // A row like the others, not a footer button.
            let more = NSButton(title: "", target: self, action: #selector(moreTapped))
            more.isBordered = false
            more.alignment = .left
            more.attributedTitle = NSAttributedString(string: "Show \(hidden) more", attributes: [.font: DS.Text.body(), .foregroundColor: NSColor.secondaryLabelColor])
            let row = NSStackView(views: [more])
            row.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
            row.heightAnchor.constraint(equalToConstant: 36).isActive = true
            content.addArrangedSubview(row)
        }
        if shown.isEmpty {
            let none = NSTextField(labelWithString: query.isEmpty ? "No projects yet. Open one to start." : "No project matches \u{201C}\(query)\u{201D}.")
            none.font = DS.Text.body()
            none.textColor = .secondaryLabelColor
            let row = NSStackView(views: [none])
            row.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
            content.addArrangedSubview(row)
        }
        if let selectedPath, let index = shown.firstIndex(where: { $0.space.path == selectedPath }) {
            selectedIndex = index
        } else {
            // Return goes somewhere new: the first project that isn't this window's.
            selectedIndex = shown.firstIndex { $0.openness != .current } ?? 0
            if !query.isEmpty { selectedIndex = 0 }
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        applySelection(animated: false)
    }

    static func heading(_ text: String) -> NSView {
        let heading = NSTextField(labelWithString: text)
        heading.font = DS.Text.caption(.semibold)
        heading.textColor = .tertiaryLabelColor
        let inset = NSStackView(views: [heading])
        inset.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 4, right: 12)
        return inset
    }

    override func layout() {
        super.layout()
        placePanelHost()
        // The rows reach their width only once the panel has its own: the capsule follows,
        // or it hugged the name (found on screen, 2026-11-05).
        if selection.layer?.animationKeys()?.isEmpty ?? true { applySelection(animated: false, reveal: false) }
    }

    /// The panel's size from what it holds, up to 60% of the window; placed by the shell above
    /// the stage bar. The list scrolls past that.
    private func placePanelHost() {
        guard bounds.height > 0 else { return }
        let width = min(Self.layout == .grid ? Self.gridWidth : Self.listWidth, bounds.width - 24)
        content.layoutSubtreeIfNeeded()
        let fitting = content.fittingSize.height + 12
        let chrome = Self.headerHeight + 1 + Self.footerHeight
        let room = max(Self.rowHeight * 2, bounds.height * 0.6 - chrome)
        let listHeight = min(max(fitting, Self.rowHeight), room)
        if scrollHeight?.constant != listHeight { scrollHeight?.constant = listHeight }
        let size = NSSize(width: width, height: chrome + listHeight)
        let frame = placePanel?(size) ?? NSRect(x: bounds.midX - width / 2, y: 80, width: width, height: size.height)
        // Not while it grows or shrinks: the transform is figured from where it is.
        if panelHost.frame != frame, panelHost.layer?.animationKeys()?.isEmpty ?? true { panelHost.frame = frame }
    }

    /// The selection is one capsule that slides to the selected project, not cards repainting.
    private func applySelection(animated: Bool, reveal: Bool = true) {
        guard cards.indices.contains(selectedIndex) else { selection.isHidden = true; return }
        let card = cards[selectedIndex]
        document.layoutSubtreeIfNeeded()
        let target = card.convert(card.bounds, to: document)
        selection.isHidden = false
        if animated, !selection.frame.isEmpty {
            DS.Motion.animate(DS.Motion.snappy, { selection.animator().frame = target })
        } else {
            if selection.frame != target { selection.frame = target }
        }
        for (index, each) in cards.enumerated() where each.isSelected != (index == selectedIndex) { each.isSelected = index == selectedIndex }
        if reveal { card.scrollToVisible(card.bounds) }
    }

    private func select(_ index: Int) {
        guard cards.indices.contains(index), index != selectedIndex else { return }
        selectedIndex = index
        applySelection(animated: true)
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

    @objc private func moreTapped() {
        showingAll = true
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
        let next = min(max(selectedIndex + delta, 0), cards.count - 1)
        guard next != selectedIndex else { return }
        selectedIndex = next
        applySelection(animated: true)
    }

    func focus() { window?.makeFirstResponder(field) }

    /// On its way out: the window under it takes clicks again at once.
    var passesClicksThrough = false
    override func hitTest(_ point: NSPoint) -> NSView? { passesClicksThrough ? nil : super.hitTest(point) }

    override func mouseDown(with event: NSEvent) {
        // A click outside the panel leaves.
        if !panelHost.frame.contains(convert(event.locationInWindow, from: nil)) { onClose?() }
    }

    // MARK: Testing

    var entryNamesForTesting: [String] { shown.map(\.space.name) }
    var selectedNameForTesting: String? { shown.indices.contains(selectedIndex) ? shown[selectedIndex].space.name : nil }
    func typeForTesting(_ text: String) { field.stringValue = text; rebuild(keepingSelection: false) }
    func commandForTesting(_ selector: Selector) {
        guard let editor = field.currentEditor() as? NSTextView else { _ = control(field, textView: NSTextView(), doCommandBy: selector); return }
        _ = control(field, textView: editor, doCommandBy: selector)
    }
    var isShowingMoreForTesting: Bool { shown.count < all.count && field.stringValue.isEmpty && !showingAll }
    var framesForTesting: String { "overlay \(frame) panel \(panelHost.frame) scroll \(scrollHeight?.constant ?? 0) content \(content.fittingSize.height)" }
    var selectionFrameForTesting: NSRect { selection.frame }
    func hoverForTesting(_ index: Int) { cards.enumerated().forEach { $0.element.hoverForTesting($0.offset == index) } }
    var hoverReflowsForTesting: Bool {
        guard let card = cards.first else { return false }
        let before = card.frame
        card.hoverForTesting(true)
        layoutSubtreeIfNeeded()
        defer { card.hoverForTesting(false) }
        return card.frame != before
    }
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

/// One project in the switcher, a row (list) or a card (grid): its mark, name, and a line for
/// what it's doing or where it is; its shortcut at the end. On hover, ⋯ and (held) × fade in over
/// the shortcut's place, which keeps its width: hover never moves anything. The selection is the
/// panel's capsule underneath; a project that isn't open is dimmed and says so.
@MainActor
final class ProjectSwitcherCard: NSView {
    var onPick: (() -> Void)?
    var onMenu: (() -> Void)?
    var onPutAway: (() -> Void)?
    var onHover: (() -> Void)?
    var isSelected = false { didSet { refreshHover() } }
    let entry: ProjectSwitcherEntry
    private var hovered = false { didSet { refreshHover() } }
    private let hoverFill = DS.Fill(DS.Color.hoverCapsule, cornerRadius: DS.Radius.surface)
    private let shortcut = NSTextField(labelWithString: "")
    private let menuButton: DS.CircleButton
    private let closeButton: DS.CircleButton
    private let trailing = NSView()

    static let trailingWidth: CGFloat = 52

    init(entry: ProjectSwitcherEntry, style: ProjectSwitcherOverlay.Layout) {
        self.entry = entry
        menuButton = DS.CircleButton(symbol: "ellipsis", diameter: 22, label: "More for \(entry.space.name)")
        closeButton = DS.CircleButton(symbol: "xmark", diameter: 22, label: "Put \(entry.space.name) away")
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        hoverFill.alphaValue = 0
        hoverFill.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hoverFill)
        let markSize: CGFloat = style == .grid ? 32 : 24
        let mark = NSImageView(image: ProjectSpaces.mark(for: entry.space, size: markSize) ?? NSImage())
        mark.imageScaling = .scaleProportionallyUpOrDown
        mark.translatesAutoresizingMaskIntoConstraints = false
        let name = NSTextField(labelWithString: entry.space.name)
        name.font = DS.Text.body(.semibold)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // One line under the name: what it's doing when something is, else where it is.
        let second: NSView
        if let activity = entry.activity {
            second = DS.StatusLabel(state: activity.state.status, text: "\(activity.title) \(activity.state.word.lowercased())")
        } else {
            let place = NSTextField(labelWithString: [entry.place, entry.detail].compactMap { $0 }.joined(separator: " \u{00B7} "))
            place.font = DS.Text.caption()
            place.textColor = .secondaryLabelColor
            place.lineBreakMode = .byTruncatingTail
            place.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            second = place
        }
        let titles = NSStackView(views: [name, second])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 2
        titles.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titles.translatesAutoresizingMaskIntoConstraints = false

        shortcut.stringValue = entry.shortcut ?? ""
        shortcut.font = DS.Text.caption()
        shortcut.textColor = .tertiaryLabelColor
        shortcut.alignment = .right
        menuButton.target = self
        menuButton.action = #selector(menuTapped)
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        for view in [shortcut, menuButton, closeButton] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false; trailing.addSubview(view) }
        menuButton.alphaValue = 0
        closeButton.alphaValue = 0
        menuButton.isHidden = true
        closeButton.isHidden = true
        trailing.translatesAutoresizingMaskIntoConstraints = false

        let body = NSView()
        body.translatesAutoresizingMaskIntoConstraints = false
        for view in [mark, titles, trailing] as [NSView] { body.addSubview(view) }
        addSubview(body)
        let showsClose = entry.openness == .held
        NSLayoutConstraint.activate([
            hoverFill.topAnchor.constraint(equalTo: topAnchor), hoverFill.bottomAnchor.constraint(equalTo: bottomAnchor),
            hoverFill.leadingAnchor.constraint(equalTo: leadingAnchor), hoverFill.trailingAnchor.constraint(equalTo: trailingAnchor),
            body.topAnchor.constraint(equalTo: topAnchor), body.bottomAnchor.constraint(equalTo: bottomAnchor),
            body.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), body.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            mark.widthAnchor.constraint(equalToConstant: markSize), mark.heightAnchor.constraint(equalToConstant: markSize),
            mark.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            titles.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: 12),
            titles.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -8),
            trailing.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            trailing.widthAnchor.constraint(equalToConstant: Self.trailingWidth), trailing.heightAnchor.constraint(equalToConstant: 22),
            shortcut.trailingAnchor.constraint(equalTo: trailing.trailingAnchor), shortcut.centerYAnchor.constraint(equalTo: trailing.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailing.trailingAnchor), closeButton.centerYAnchor.constraint(equalTo: trailing.centerYAnchor),
            menuButton.trailingAnchor.constraint(equalTo: showsClose ? closeButton.leadingAnchor : trailing.trailingAnchor, constant: showsClose ? -6 : 0),
            menuButton.centerYAnchor.constraint(equalTo: trailing.centerYAnchor),
        ])
        if style == .grid {
            NSLayoutConstraint.activate([
                mark.topAnchor.constraint(equalTo: body.topAnchor, constant: 12),
                titles.centerYAnchor.constraint(equalTo: mark.centerYAnchor),
                trailing.topAnchor.constraint(equalTo: body.topAnchor, constant: 11),
                heightAnchor.constraint(equalToConstant: 56),
            ])
        } else {
            NSLayoutConstraint.activate([
                mark.centerYAnchor.constraint(equalTo: body.centerYAnchor),
                titles.centerYAnchor.constraint(equalTo: body.centerYAnchor),
                trailing.centerYAnchor.constraint(equalTo: body.centerYAnchor),
                heightAnchor.constraint(equalToConstant: ProjectSwitcherOverlay.rowHeight),
            ])
        }
        // Not open: quieter, and it says so in words too.
        if !entry.isOpen { body.alphaValue = 0.62 }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        let state = entry.activity.map { ", \($0.title) \($0.state.word.lowercased())" } ?? ""
        setAccessibilityLabel("\(entry.space.name), \(entry.place)\(state)")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Hover: a faint fill (none under the selection, which is already there) and the shortcut
    /// giving its place to ⋯ and ×, crossfaded. Nothing is laid out again.
    private func refreshHover() {
        let showControls = hovered
        let fill: CGFloat = hovered && !isSelected ? 1 : 0
        if showControls { menuButton.isHidden = false; closeButton.isHidden = entry.openness != .held }
        DS.Motion.fade(duration: DS.Motion.glanceDuration, {
            hoverFill.animator().alphaValue = fill
            shortcut.animator().alphaValue = showControls ? 0 : 1
            menuButton.animator().alphaValue = showControls ? 1 : 0
            closeButton.animator().alphaValue = showControls ? 1 : 0
        }, completion: { [weak self] in
            guard let self, !self.hovered else { return }
            self.menuButton.isHidden = true
            self.closeButton.isHidden = true
        })
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
    var closeButtonSizeForTesting: NSSize { closeButton.frame.size }
}

/// ⌃⇥ held: the open projects as tiles in a glass panel grown out of the stage bar, the next
/// one picked; ⇥ again moves on, ⌃⇧⇥ back, letting go of ⌃ switches, Escape stays. A quick tap
/// switches with no panel (the shell waits before showing it). The caption is one centred line
/// the panel's width, its words crossfading: it never moves as the selection does.
@MainActor
final class ProjectCycleStrip: NSView {
    private(set) var entries: [ProjectSwitcherEntry]
    private(set) var selectedIndex: Int
    private var tiles: [NSView] = []
    private let selection = DS.Fill(DS.Color.selectedCapsule, cornerRadius: DS.Radius.surface)
    private let caption = NSTextField(labelWithString: "")
    private let row = NSView()

    static let tileWidth: CGFloat = 88
    static let tileHeight: CGFloat = 84
    static let captionHeight: CGFloat = 30
    static let inset: CGFloat = 12

    static let maxWidth: CGFloat = 520

    /// The tiles' width: the row is exactly its tiles.
    private static func rowWidth(_ count: Int) -> CGFloat {
        tileWidth * CGFloat(count) + DS.Spacing.xs * CGFloat(max(0, count - 1))
    }

    /// The panel's size for these entries: its tiles, or wider for the longest caption — two
    /// tiles left the line under them 180 pt, and "main · 2 terminals" cut off (the owner,
    /// 2026-11-05). Capped; past that it truncates.
    static func size(for entries: [ProjectSwitcherEntry]) -> NSSize {
        let captionWidth = entries.map { ceil(caption(for: $0).size().width) + DS.Spacing.l * 2 }.max() ?? 0
        let content = min(maxWidth - inset * 2, max(rowWidth(entries.count), captionWidth))
        return NSSize(width: inset * 2 + content, height: inset + tileHeight + captionHeight + 6)
    }

    init(entries: [ProjectSwitcherEntry], start: Int) {
        self.entries = entries
        self.selectedIndex = start
        super.init(frame: .zero)
        wantsLayer = true
        if DS.Surfaces.needsShadow {
            shadow = NSShadow()
            layer?.shadowOpacity = 0.18
            layer?.shadowRadius = 18
            layer?.shadowOffset = CGSize(width: 0, height: -4)
        }
        let body = NSView()
        let surface = DS.makeFloatingSurface(embedding: body)
        surface.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surface)
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: topAnchor), surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            surface.leadingAnchor.constraint(equalTo: leadingAnchor), surface.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(selection)
        body.addSubview(row)
        caption.alignment = .center
        caption.lineBreakMode = .byTruncatingTail
        caption.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(caption)
        var previous: NSView?
        for entry in entries {
            let tile = NSView()
            tile.translatesAutoresizingMaskIntoConstraints = false
            let mark = NSImageView(image: ProjectSpaces.mark(for: entry.space, size: 44) ?? NSImage())
            mark.imageScaling = .scaleProportionallyUpOrDown
            mark.translatesAutoresizingMaskIntoConstraints = false
            let name = NSTextField(labelWithString: entry.space.name)
            name.font = DS.Text.caption(.medium)
            name.lineBreakMode = .byTruncatingTail
            name.alignment = .center
            name.translatesAutoresizingMaskIntoConstraints = false
            tile.addSubview(mark)
            tile.addSubview(name)
            row.addSubview(tile)
            var constraints = [
                tile.widthAnchor.constraint(equalToConstant: Self.tileWidth), tile.heightAnchor.constraint(equalToConstant: Self.tileHeight),
                tile.topAnchor.constraint(equalTo: row.topAnchor),
                tile.leadingAnchor.constraint(equalTo: previous?.trailingAnchor ?? row.leadingAnchor, constant: previous == nil ? 0 : DS.Spacing.xs),
                mark.widthAnchor.constraint(equalToConstant: 44), mark.heightAnchor.constraint(equalToConstant: 44),
                mark.centerXAnchor.constraint(equalTo: tile.centerXAnchor), mark.topAnchor.constraint(equalTo: tile.topAnchor, constant: 10),
                name.topAnchor.constraint(equalTo: mark.bottomAnchor, constant: 6),
                name.leadingAnchor.constraint(equalTo: tile.leadingAnchor, constant: 6), name.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: -6),
            ]
            if let activity = entry.activity {
                let dot = DS.StatusDot(state: activity.state.status)
                dot.translatesAutoresizingMaskIntoConstraints = false
                tile.addSubview(dot)
                constraints += [dot.centerXAnchor.constraint(equalTo: mark.trailingAnchor, constant: -2), dot.centerYAnchor.constraint(equalTo: mark.topAnchor, constant: 2)]
            }
            NSLayoutConstraint.activate(constraints)
            tiles.append(tile)
            previous = tile
        }
        // The row is exactly its tiles, centred: the panel is theirs or the caption's width, and
        // the tiles sit in its middle (pinned to the leading edge they had drawn ~28 pt off).
        previous?.trailingAnchor.constraint(equalTo: row.trailingAnchor).isActive = true
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: body.topAnchor, constant: Self.inset),
            row.centerXAnchor.constraint(equalTo: body.centerXAnchor),
            row.widthAnchor.constraint(equalToConstant: Self.rowWidth(entries.count)),
            row.heightAnchor.constraint(equalToConstant: Self.tileHeight),
            caption.topAnchor.constraint(equalTo: row.bottomAnchor, constant: 6),
            caption.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: Self.inset),
            caption.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -Self.inset),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Projects")
        refresh(animated: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func move(_ delta: Int) {
        guard !entries.isEmpty else { return }
        selectedIndex = ((selectedIndex + delta) % entries.count + entries.count) % entries.count
        refresh(animated: true)
    }

    var selected: ProjectSwitcherEntry? { entries.indices.contains(selectedIndex) ? entries[selectedIndex] : nil }

    /// The capsule slides to the picked tile; the caption's words crossfade in place.
    private func refresh(animated: Bool) {
        layoutSubtreeIfNeeded()
        if tiles.indices.contains(selectedIndex) {
            let target = NSRect(x: (Self.tileWidth + DS.Spacing.xs) * CGFloat(selectedIndex), y: 0, width: Self.tileWidth, height: Self.tileHeight)
            if animated { DS.Motion.animate(DS.Motion.snappy, { selection.animator().frame = target }) } else { selection.frame = target }
        }
        if animated { DS.Motion.crossfade(caption, duration: DS.Motion.glanceDuration) }
        caption.attributedStringValue = Self.caption(for: selected)
        setAccessibilityValue(selected?.space.name)
    }

    /// "● Claude Code finished" or "main · 2 terminals": one string, its dot a glyph in it, so
    /// the line is one centred field whatever it says.
    static func caption(for entry: ProjectSwitcherEntry?) -> NSAttributedString {
        guard let entry else { return NSAttributedString() }
        let text = NSMutableAttributedString()
        defer {
            // Centred by the string itself: its own (default, left) alignment overrode the
            // field's, and the line sat at the left edge.
            let centered = NSMutableParagraphStyle()
            centered.alignment = .center
            centered.lineBreakMode = .byTruncatingTail
            text.addAttribute(.paragraphStyle, value: centered, range: NSRange(location: 0, length: text.length))
        }
        if let activity = entry.activity {
            text.append(NSAttributedString(string: "\u{25CF} ", attributes: [.font: DS.Text.caption(), .foregroundColor: activity.state.status.color]))
            text.append(NSAttributedString(string: "\(activity.title) \(activity.state.word.lowercased())", attributes: [.font: DS.Text.caption(.medium), .foregroundColor: NSColor.labelColor]))
        } else {
            let line = [entry.place, entry.detail].compactMap { $0 }.joined(separator: " \u{00B7} ")
            text.append(NSAttributedString(string: line, attributes: [.font: DS.Text.caption(), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        return text
    }

    var captionForTesting: String { caption.stringValue }
    var selectionFrameForTesting: NSRect { selection.frame }
}
