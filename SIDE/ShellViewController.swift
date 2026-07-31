import AppKit

final class ShellViewController: NSViewController {
    enum Stage: String, CaseIterable { case make = "Make", run = "Run" }

    private let stageControl = NSSegmentedControl(labels: Stage.allCases.map(\.rawValue), trackingMode: .selectOne, target: nil, action: nil)
    private let container = NSView()
    private lazy var makeVC = MakeWorkspaceViewController()
    private lazy var runVC = TerminalViewController()
    private var current: Stage?

    override func loadView() { view = NSView() }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildLayout()
        makeVC.onProjectOpened = { [weak self] url in self?.runVC.workingDirectory = url.path }
        show(.make)
    }

    private func buildLayout() {
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        stageControl.segmentStyle = .texturedRounded
        stageControl.selectedSegment = 0
        stageControl.target = self
        stageControl.action = #selector(stageChanged(_:))
        stageControl.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stageControl)

        container.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(container)

        NSLayoutConstraint.activate([
            stageControl.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            stageControl.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            container.topAnchor.constraint(equalTo: stageControl.bottomAnchor, constant: 10),
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

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
}
