import AppKit

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
        // largest picture in an asset catalog's AppIcon set.
        return iconComposerBundle(in: root) ?? appIconSet(in: root)
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
        ProjectLogo.image(for: space.url, size: size) ?? image(for: space, pointSize: size * 0.72)
    }
}

/// The project, at the bar's leading edge: its mark in a glass disc. Click for the projects; a
/// swipe across it goes to the next or previous one. Its own control, apart from the track pill,
/// where switching projects was a row in the tracks' popover, "hard to spot" (the owner,
/// 2026-11-04).
@MainActor
final class ProjectChip: NSView {
    var onSwitchProject: ((URL) -> Void)?
    var onSwipeProject: ((Int) -> Void)?
    var onAddProject: (() -> Void)?
    var currentProject: (() -> URL?)?

    private let diameter: CGFloat
    private let mark = NSImageView()
    private let dot = DS.StatusDot(state: .needsYou)
    private var popover: NSPopover?
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

    func refresh() {
        guard let url = currentProject?() else {
            mark.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            mark.contentTintColor = .tertiaryLabelColor
            toolTip = nil
            dot.isHidden = true
            return
        }
        let space = ProjectSpaces.shared.space(for: url)
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
        if bounds.contains(convert(event.locationInWindow, from: nil)) { togglePopover() }
    }
    override func accessibilityPerformPress() -> Bool { togglePopover(); return true }

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

    func togglePopover() {
        if let popover, popover.isShown { popover.close(); return }
        let content = ProjectSwitcherViewController(current: currentProject?())
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = content
        content.onPick = { [weak self, weak popover] url in popover?.close(); self?.onSwitchProject?(url) }
        content.onOpen = { [weak self, weak popover] in popover?.close(); self?.onAddProject?() }
        self.popover = popover
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
    }

    var popoverForTesting: NSPopover? { popover }
}

/// The projects, as a list: each its mark, name and folder, what it has to say, and its ⌃
/// number; the current one marked. One click moves the window there; the one left keeps running.
@MainActor
final class ProjectSwitcherViewController: NSViewController {
    var onPick: ((URL) -> Void)?
    var onOpen: (() -> Void)?
    private let current: URL?
    private let stack = NSStackView()

    init(current: URL?) {
        self.current = current
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DS.Spacing.xxs
        stack.edgeInsets = NSEdgeInsets(top: DS.Spacing.m, left: DS.Spacing.s, bottom: DS.Spacing.m, right: DS.Spacing.s)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor), stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            root.widthAnchor.constraint(equalToConstant: 320),
        ])
        view = root
        let currentPath = current?.standardizedFileURL.path
        let spaces = ProjectSpaces.shared.shown(current: current)
        for space in spaces {
            let number = ProjectSpaces.shared.index(of: space.url).map { $0 + 1 }
            let shortcut = number.flatMap { $0 <= 9 ? Shortcuts.display("project.\($0)").nonEmpty : nil }
            let isCurrent = space.path == currentPath
            let row = ProjectRow(mark: ProjectSpaces.mark(for: space, size: 20), name: space.name,
                                 place: (space.path as NSString).abbreviatingWithTildeInPath,
                                 attention: isCurrent ? nil : ActivityCenter.shared.attentionItem(forProject: space.path).map { ($0.state.status, $0.state.word) },
                                 shortcut: shortcut, isCurrent: isCurrent)
            row.onPick = { [weak self] in self?.onPick?(space.url) }
            row.menu = menu(for: space, isCurrent: isCurrent)
            add(row)
        }
        if !spaces.isEmpty { add(Separator()) }
        let open = ProjectRow(mark: NSImage(systemSymbolName: "plus", accessibilityDescription: nil), name: "Open Project\u{2026}",
                              place: nil, attention: nil, shortcut: Shortcuts.display("file.openProject").nonEmpty, isCurrent: false)
        open.onPick = { [weak self] in self?.onOpen?() }
        add(open)
    }

    private func add(_ row: NSView) {
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -DS.Spacing.s * 2).isActive = true
    }

    /// The project's own menu: its color and symbol (shown when it has no logo), and closing it.
    private func menu(for space: ProjectSpaces.Space, isCurrent: Bool) -> NSMenu {
        let menu = NSMenu()
        let colors = NSMenu()
        for (index, color) in ProjectSpaces.palette.enumerated() {
            let item = NSMenuItem(title: Self.colorNames[index], action: #selector(pickColor(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.representedObject = space.path
            item.state = index == space.colorIndex % ProjectSpaces.palette.count ? .on : .off
            item.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [color]))
            colors.addItem(item)
        }
        let colorItem = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        colorItem.submenu = colors
        menu.addItem(colorItem)
        let symbols = NSMenu()
        for symbol in ProjectSpaces.symbols {
            let item = NSMenuItem(title: "", action: #selector(pickSymbol(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = [space.path, symbol]
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)
            item.state = symbol == space.symbol ? .on : .off
            symbols.addItem(item)
        }
        let symbolItem = NSMenuItem(title: "Symbol", action: nil, keyEquivalent: "")
        symbolItem.submenu = symbols
        menu.addItem(symbolItem)
        if !isCurrent {
            menu.addItem(.separator())
            let close = NSMenuItem(title: "Close \u{201C}\(space.name)\u{201D}", action: #selector(closeProject(_:)), keyEquivalent: "")
            close.target = self
            close.representedObject = space.path
            menu.addItem(close)
        }
        return menu
    }

    private static let colorNames = ["Graphite", "Blue", "Purple", "Pink", "Red", "Orange", "Yellow", "Green", "Teal"]

    @objc private func pickColor(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        ProjectSpaces.shared.set(colorIndex: sender.tag, for: URL(fileURLWithPath: path))
    }
    @objc private func pickSymbol(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2 else { return }
        ProjectSpaces.shared.set(symbol: pair[1], for: URL(fileURLWithPath: pair[0]))
    }
    @objc private func closeProject(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        ProjectSpaces.shared.remove(URL(fileURLWithPath: path))
        view.window?.performClose(nil)
    }

    var rowNamesForTesting: [String] { stack.arrangedSubviews.compactMap { ($0 as? ProjectRow)?.name } }
}

/// A hairline between the projects and Open Project.
@MainActor
private final class Separator: NSBox {
    init() {
        super.init(frame: .zero)
        boxType = .separator
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// One project: mark, name over folder, then what it has to say or its shortcut. The current
/// one sits on the selected capsule; the others take it on hover.
@MainActor
private final class ProjectRow: NSView {
    var onPick: (() -> Void)?
    let name: String
    private let isCurrent: Bool
    private var hovered = false { didSet { needsDisplay = true } }

    init(mark: NSImage?, name: String, place: String?, attention: (state: DS.StatusState, word: String)?, shortcut: String?, isCurrent: Bool) {
        self.name = name
        self.isCurrent = isCurrent
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let icon = NSImageView(image: mark ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        icon.contentTintColor = .secondaryLabelColor
        icon.imageScaling = .scaleProportionallyDown
        let title = NSTextField(labelWithString: name)
        title.font = DS.Text.body(isCurrent ? .semibold : .medium)
        title.lineBreakMode = .byTruncatingTail
        var words: [NSView] = [title]
        if let place {
            let folder = NSTextField(labelWithString: place)
            folder.font = DS.Text.caption()
            folder.textColor = .secondaryLabelColor
            folder.lineBreakMode = .byTruncatingMiddle
            words.append(folder)
        }
        let column = NSStackView(views: words)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 1
        column.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var trailing: NSView = NSView()
        if let attention {
            trailing = DS.StatusLabel(state: attention.state, text: attention.word)
        } else if let shortcut {
            let label = NSTextField(labelWithString: shortcut)
            label.font = DS.Text.caption()
            label.textColor = .tertiaryLabelColor
            trailing = label
        }
        trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = NSStackView(views: [icon, column, NSView(), trailing])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = DS.Spacing.m
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 20), icon.heightAnchor.constraint(equalToConstant: 20),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DS.Spacing.m),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DS.Spacing.m),
            row.topAnchor.constraint(equalTo: topAnchor, constant: DS.Spacing.s),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -DS.Spacing.s),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(isCurrent ? "\(name), current project" : name + (attention.map { ", \($0.word)" } ?? ""))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { onPick?() } }
    override func accessibilityPerformPress() -> Bool { onPick?(); return true }

    override func draw(_ dirtyRect: NSRect) {
        guard hovered || isCurrent else { return }
        DS.Color.selectedCapsule.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: DS.Radius.control + 2, yRadius: DS.Radius.control + 2).fill()
    }
}
