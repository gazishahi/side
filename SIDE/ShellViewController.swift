import AppKit

private extension NSToolbarItem.Identifier {
    static let projectLabel = NSToolbarItem.Identifier("side.project-label")
    static let stageSwitcher = NSToolbarItem.Identifier("side.stage-switcher")
    static let quickOpen = NSToolbarItem.Identifier("side.quick-open")
}

final class ShellViewController: NSViewController, NSToolbarDelegate {
    enum Stage: String, CaseIterable { case make = "Make", run = "Run" }

    private let stageControl = NSSegmentedControl(labels: Stage.allCases.map(\.rawValue), trackingMode: .selectOne, target: nil, action: nil)
    private let projectLabel = NSTextField(labelWithString: "")
    private let container = NSView()
    private lazy var makeVC = MakeWorkspaceViewController()
    private lazy var runVC = TerminalViewController()
    private var current: Stage?

    private var projectURL: URL?
    private var currentFileURL: URL?
    private var isDirty = false
    private var gitBranch: String?
    private var gitDirtyCount = 0

    override func loadView() { view = NSView() }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildLayout()
        makeVC.onProjectOpened = { [weak self] url in self?.projectOpened(url) }
        makeVC.onFileOpened = { [weak self] url in self?.fileOpened(url) }
        makeVC.onDirtyChanged = { [weak self] dirty in self?.isDirty = dirty; self?.applyWindowChrome() }
        show(.make)
    }

    var hasUnsavedChanges: Bool { makeVC.hasUnsavedChanges }
    func confirmCloseAllUnsaved(completion: @escaping (Bool) -> Void) { makeVC.confirmCloseAllUnsaved(completion: completion) }
    func restoreLastSessionIfAvailable() { makeVC.restoreLastSessionIfAvailable() }
    func prepareForClose() {
        makeVC.prepareForClose()
        runVC.prepareForClose()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard let window = view.window, window.toolbar == nil else { return }
        let toolbar = NSToolbar(identifier: "side.shell.toolbar")
        toolbar.delegate = self
        toolbar.centeredItemIdentifier = .stageSwitcher
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.titleVisibility = .visible
        applyWindowChrome()
    }

    private func buildLayout() {
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        stageControl.segmentStyle = .texturedRounded
        stageControl.selectedSegment = 0
        stageControl.target = self
        stageControl.action = #selector(stageChanged(_:))

        projectLabel.font = .systemFont(ofSize: 12, weight: .medium)
        projectLabel.textColor = .secondaryLabelColor
        projectLabel.lineBreakMode = .byTruncatingMiddle

        container.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(container)

        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: view.topAnchor),
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    // MARK: - Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.projectLabel, .flexibleSpace, .stageSwitcher, .flexibleSpace, .quickOpen] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.projectLabel, .stageSwitcher, .quickOpen, .flexibleSpace] }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .projectLabel:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            projectLabel.translatesAutoresizingMaskIntoConstraints = false
            projectLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 200).isActive = true
            item.view = projectLabel
            item.label = "Project"
            return item
        case .stageSwitcher:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = stageControl
            item.label = "Stage"
            return item
        case .quickOpen:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            let field = makeVC.searchField
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 320).isActive = true
            item.view = field
            item.label = "Quick Open"
            return item
        default:
            return nil
        }
    }

    // MARK: - Stage switching

    @objc private func stageChanged(_ sender: NSSegmentedControl) {
        show(Stage.allCases[sender.selectedSegment])
    }

    private func show(_ stage: Stage) {
        guard current != stage else { return }
        current = stage
        stageControl.selectedSegment = Stage.allCases.firstIndex(of: stage) ?? 0

        for child in children {
            child.view.removeFromSuperview()
            child.removeFromParent()
        }

        let next: NSViewController = stage == .make ? makeVC : runVC
        addChild(next)
        next.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(next.view)
        NSLayoutConstraint.activate([
            next.view.topAnchor.constraint(equalTo: container.topAnchor),
            next.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            next.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            next.view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        if stage == .run {
            runVC.activate()
        }
    }

    // MARK: - Window chrome (title, subtitle, git info)

    private func projectOpened(_ url: URL) {
        projectURL = url
        runVC.workingDirectory = url.path
        applyWindowChrome()
        refreshGitInfo(for: url)
    }

    private func fileOpened(_ url: URL?) {
        currentFileURL = url
        isDirty = false
        applyWindowChrome()
    }

    private func applyWindowChrome() {
        projectLabel.stringValue = projectURL?.lastPathComponent ?? ""
        guard let window = view.window else { return }
        window.representedURL = currentFileURL
        let fileName = currentFileURL?.lastPathComponent
        window.title = (isDirty ? fileName.map { "\($0) — Edited" } : fileName) ?? projectURL?.lastPathComponent ?? "Side"

        var subtitleParts: [String] = []
        if let projectURL, let currentFileURL {
            let relative = currentFileURL.path.replacingOccurrences(of: projectURL.path + "/", with: "")
            subtitleParts.append(relative)
        } else if let projectName = projectURL?.lastPathComponent {
            subtitleParts.append(projectName)
        }
        if let branch = gitBranch {
            subtitleParts.append(gitDirtyCount > 0 ? "\(branch) · \(gitDirtyCount) changed" : branch)
        }
        window.subtitle = subtitleParts.joined(separator: " — ")
    }

    private func refreshGitInfo(for project: URL) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let branch = Self.runGit(["rev-parse", "--abbrev-ref", "HEAD"], in: project.path)
            let status = Self.runGit(["status", "--porcelain"], in: project.path)
            let dirtyCount = status?.split(separator: "\n").count ?? 0
            DispatchQueue.main.async {
                guard let self, self.projectURL == project else { return }
                self.gitBranch = (branch?.isEmpty == false) ? branch : nil
                self.gitDirtyCount = dirtyCount
                self.applyWindowChrome()
            }
        }
    }

    nonisolated private static func runGit(_ args: [String], in directory: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", directory] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
