import AppKit
import Heron

/// The first-run sheet (Direction 02 §6): three steps in one column — open a project, choose a
/// model, create a track — each a button that does it. No tour, no tooltips; dismissed once,
/// gone for good.
enum FirstRun {
    static let dismissedKey = "side.first-run-dismissed"

    /// First run means nothing to come back to and nothing to talk to: no recent projects and no
    /// model that can take a message. Anyone past either has found their way already.
    static func shouldPresent(dismissed: Bool, hasRecentProjects: Bool, modelReady: Bool) -> Bool {
        !dismissed && !hasRecentProjects && !modelReady
    }

    /// `-SideForceFirstRun YES`: show the sheet regardless, and never record its dismissal — for
    /// checking it without touching a real first-run state.
    static var forced: Bool { UserDefaults.standard.bool(forKey: "SideForceFirstRun") }

    static var dismissed: Bool {
        get { HeronDefaults.store.bool(forKey: dismissedKey) }
        set { HeronDefaults.store.set(newValue, forKey: dismissedKey) }
    }

    /// The active provider can take a message right now.
    static var modelReady: Bool {
        if case .ready = ProviderRegistryStore.shared.resolveAdapter(providerId: ProviderRegistryStore.shared.activeProviderId) { return true }
        return false
    }

    enum Step: CaseIterable { case project, model, track }
}

final class FirstRunSheetController: NSViewController {
    var onStep: ((FirstRun.Step) -> Void)?
    var onDismiss: (() -> Void)?
    private let done: Set<FirstRun.Step>

    /// The project is a plain folder: the track step is "Initialize Git…" first (2026-09-30
    /// audit, H10: it offered New Track, which failed with git's raw error).
    private let needsGit: Bool

    init(done: Set<FirstRun.Step>, needsGit: Bool = false) {
        self.needsGit = needsGit
        self.done = done
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 260))
        view = root
        let title = NSTextField(labelWithString: "Get started")
        title.font = DS.Text.title()
        let stack = NSStackView(views: [title])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DS.Spacing.l
        stack.setCustomSpacing(DS.Spacing.xl, after: title)
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let steps: [(FirstRun.Step, String, String)] = [
            (.project, "Open a project", "Open Project…"),
            (.model, "Choose a model", "Set Up…"),
            (.track, "Create a track", needsGit ? "Initialize Git…" : "New Track"),
        ]
        // The first step not yet done is the one to do now; it alone takes the accent.
        let next = steps.first { !done.contains($0.0) }?.0
        for (step, label, action) in steps {
            let isDone = done.contains(step)
            let mark = DS.StatusDot(state: isDone ? .verified : .idle, diameter: 8)
            let text = NSTextField(labelWithString: label)
            text.font = DS.Text.body(isDone ? .regular : .medium)
            text.textColor = isDone ? .secondaryLabelColor : .labelColor
            let button = NSButton(title: isDone ? "Done" : action, target: self, action: #selector(stepTapped(_:)))
            button.bezelStyle = .push
            // A track lives in a project: that step waits for the first.
            button.isEnabled = !isDone && (step != .track || done.contains(.project))
            button.tag = FirstRun.Step.allCases.firstIndex(of: step) ?? 0
            if step == next { button.bezelColor = .controlAccentColor; button.keyEquivalent = "\r" }
            let row = NSStackView(views: [mark, text, NSView(), button])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = DS.Spacing.m
            row.setAccessibilityElement(true)
            row.setAccessibilityLabel("\(label)\(isDone ? ", done" : "")")
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
        }
        let close = NSButton(title: "Don’t Show Again", target: self, action: #selector(dismissTapped))
        close.bezelStyle = .push
        let footer = NSStackView(views: [NSView(), close])
        footer.orientation = .horizontal
        stack.setCustomSpacing(DS.Spacing.section, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true

        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor), stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            root.widthAnchor.constraint(equalToConstant: 420),
        ])
    }

    @objc private func stepTapped(_ sender: NSButton) { onStep?(FirstRun.Step.allCases[sender.tag]) }
    @objc private func dismissTapped() { onDismiss?() }
}
