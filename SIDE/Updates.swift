import AppKit
import Sparkle

/// Side's updater (docs/SIDE_DISTRIBUTION.md, D1): Sparkle 2, reading a signed appcast from the
/// public releases repository. An update is verified against the EdDSA key in Info.plist and the
/// Developer ID signature before it installs. Sparkle finds, downloads, verifies and installs;
/// Side's own `UpdateDriver` shows it, as a pill in the bar (Direction 03 §5).
@MainActor
final class Updates {
    static let shared = Updates()

    let driver = UpdateDriver()
    let updater: SPUUpdater

    private init() {
        updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: nil)
        // Debug builds and test runs don't check: they'd offer the released app over the one
        // being worked on.
        #if DEBUG
        let starts = false
        #else
        let starts = !AppDelegate.isUITesting
        #endif
        if starts {
            do { try updater.start() } catch { NSLog("[Side] updater failed to start: \(error.localizedDescription)") }
        }
    }

    var checksAutomatically: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
    }

    var canCheck: Bool { updater.canCheckForUpdates }

    @objc func checkForUpdates(_ sender: Any?) {
        updater.checkForUpdates()
    }
}

/// What the update pill shows, and the replies Sparkle is waiting on. Sparkle calls in on the
/// main thread; every reply it hands over is answered exactly once.
@MainActor
final class UpdateDriver: NSObject, SPUUserDriver {
    static let didChangeNotification = Notification.Name("SideUpdateDriverDidChange")

    enum Stage: Equatable {
        case none
        case checking
        case upToDate
        case available(version: String)
        case downloading(fraction: Double?)
        case preparing
        case ready
        case failed(reason: String)

        /// The pill's words.
        var title: String {
            switch self {
            case .none: ""
            case .checking: "Checking for Updates"
            case .upToDate: "Side is up to date"
            case .available(let version): "Update to \(version)"
            case .downloading(let fraction): fraction.map { "Downloading \(Int(($0 * 100).rounded()))%" } ?? "Downloading"
            case .preparing: "Preparing"
            case .ready: "Relaunch to Update"
            case .failed: "Update failed"
            }
        }
    }

    /// How long "Side is up to date" stays before the pill leaves.
    static let upToDateDuration: TimeInterval = 3

    private(set) var stage: Stage = .none { didSet { if stage != oldValue { post() } } }
    /// The release notes for the version on offer, as Markdown, HTML or plain text.
    private(set) var notes: (text: String, format: String)?

    private var choice: ((SPUUserUpdateChoice) -> Void)?
    private var cancellation: (() -> Void)?
    private var acknowledgement: (() -> Void)?
    private var userInitiated = false
    /// Clicked Install and Relaunch: once it's downloaded, it installs without asking again.
    private var installRequested = false
    /// Later: the version stays out of the bar until the next launch, or a newer one.
    private var laterVersion: String?
    private var expectedLength: UInt64 = 0
    private var receivedLength: UInt64 = 0
    private var upToDateGeneration = 0

    // MARK: Actions (the pill and its popover)

    func install() {
        installRequested = true
        reply(.install)
    }

    func later() {
        if case .available(let version) = stage { laterVersion = version }
        reply(.dismiss)
        stage = .none
    }

    func cancelDownload() {
        cancellation?()
        cancellation = nil
        stage = .none
    }

    func relaunch() { reply(.install) }

    func tryAgain() {
        acknowledgement?()
        acknowledgement = nil
        stage = .none
        Updates.shared.checkForUpdates(nil)
    }

    private func reply(_ choice: SPUUserUpdateChoice) {
        let pending = self.choice
        self.choice = nil
        pending?(choice)
    }

    private func post() { NotificationCenter.default.post(name: Self.didChangeNotification, object: self) }

    // MARK: SPUUserDriver

    /// Side checks automatically unless Settings › General says not to, as the privacy page
    /// says; nothing downloads until you click. So there's no second-launch prompt.
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        userInitiated = true
        self.cancellation = cancellation
        stage = .checking
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let version = appcastItem.displayVersionString
        cancellation = nil
        if !state.userInitiated, !userInitiated, version == laterVersion {
            reply(.dismiss)
            return
        }
        userInitiated = false
        notes = appcastItem.itemDescription.map { ($0, appcastItem.itemDescriptionFormat ?? "html") }
        choice = reply
        switch state.stage {
        case .downloaded, .installing:
            stage = .ready
        default:
            installRequested = false
            stage = .available(version: version)
        }
    }

    /// Notes from a separate URL, when the feed doesn't embed them (Side's does).
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        guard let text = String(data: downloadData.data, encoding: .utf8) else { return }
        let format = downloadData.mimeType?.contains("markdown") == true ? "markdown" : downloadData.mimeType == "text/plain" ? "plain-text" : "html"
        notes = (text, format)
        post()
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        acknowledgement()
        cancellation = nil
        // Only a check you asked for says so; a background check that finds nothing is silent.
        guard userInitiated else { return }
        userInitiated = false
        stage = .upToDate
        upToDateGeneration += 1
        let generation = upToDateGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.upToDateDuration) { [weak self] in
            guard let self, self.upToDateGeneration == generation, self.stage == .upToDate else { return }
            self.stage = .none
        }
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        cancellation = nil
        // A background check that can't reach the feed isn't worth a pill: it tries again later.
        // A check you asked for, or an update under way, says what went wrong.
        let underWay: Bool = switch stage {
        case .downloading, .preparing, .ready, .available: true
        default: false
        }
        guard userInitiated || underWay else { acknowledgement(); return }
        userInitiated = false
        self.acknowledgement = acknowledgement
        stage = .failed(reason: error.localizedDescription)
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
        expectedLength = 0
        receivedLength = 0
        stage = .downloading(fraction: nil)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedLength = expectedContentLength
        receivedLength = 0
        stage = .downloading(fraction: expectedLength > 0 ? 0 : nil)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedLength += length
        guard expectedLength > 0 else { return }
        // Whole percents: the pill's words change at most a hundred times.
        let fraction = (min(1, Double(receivedLength) / Double(expectedLength)) * 100).rounded(.down) / 100
        stage = .downloading(fraction: fraction)
    }

    func showDownloadDidStartExtractingUpdate() {
        cancellation = nil
        stage = .preparing
    }

    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        choice = reply
        if installRequested {
            self.reply(.install)
            stage = .preparing
        } else {
            stage = .ready
        }
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        stage = .preparing
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
        stage = .none
    }

    func showUpdateInFocus() {}

    func dismissUpdateInstallation() {
        choice = nil
        cancellation = nil
        installRequested = false
        if stage != .upToDate, !isFailed { stage = .none }
    }

    private var isFailed: Bool { if case .failed = stage { true } else { false } }
    var failureReason: String? { if case .failed(let reason) = stage { reason } else { nil } }

    // MARK: Tests

    func setStageForTesting(_ stage: Stage, notes: (String, String)? = nil) {
        self.notes = notes
        self.stage = stage
    }
}

/// The update pill in one window's bar (Direction 03 §5.1): the driver's stage, in words, with
/// the ring while it works and the failed dot when it didn't. Every window has one; they all
/// show the same thing.
@MainActor
final class UpdatePill {
    let view: GlassPill
    private let driver: UpdateDriver
    private var popover: NSPopover?
    private var observer: NSObjectProtocol?

    init(driver: UpdateDriver = Updates.shared.driver, glass: Bool, height: CGFloat) {
        self.driver = driver
        view = GlassPill(height: height, glass: glass)
        view.isHidden = true
        view.onClick = { [weak self] in self?.clicked() }
        observer = NotificationCenter.default.addObserver(forName: UpdateDriver.didChangeNotification, object: driver, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(animated: true) }
        }
        refresh(animated: false)
    }

    func refresh(animated: Bool) {
        let stage = driver.stage
        let mark: GlassPill.Mark = switch stage {
        case .checking, .preparing: .ring(fraction: nil)
        case .downloading(let fraction): .ring(fraction: fraction)
        case .failed: .dot(.failed)
        default: .none
        }
        if stage != .none { view.set(title: stage.title, mark: mark) }
        view.toolTip = driver.failureReason
        view.setShown(stage != .none, animated: animated)
        if stage == .none || stage == .upToDate || stage == .checking || stage == .preparing { popover?.close() }
        (popover?.contentViewController as? UpdatePopoverViewController)?.show(driver)
    }

    private func clicked() {
        switch driver.stage {
        case .ready:
            driver.relaunch()
        case .available, .downloading, .failed:
            togglePopover()
        default:
            break
        }
    }

    private func togglePopover() {
        if let popover, popover.isShown { popover.close(); return }
        let content = UpdatePopoverViewController(driver: driver)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = content
        content.onDone = { [weak popover] in popover?.close() }
        self.popover = popover
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
    }

    var popoverForTesting: NSPopover? { popover }
    func clickForTesting() { clicked() }
}

/// What the pill opens: the release notes with Install and Relaunch and Later; the download
/// with Cancel; or what went wrong with Try Again.
@MainActor
final class UpdatePopoverViewController: NSViewController {
    static let width: CGFloat = 360
    static let notesHeight: CGFloat = 280

    var onDone: (() -> Void)?
    private let driver: UpdateDriver
    private let heading = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let notesView = NSTextView()
    private let notesScroll = NSScrollView()
    private let buttons = NSStackView()
    private var shownStage: UpdateDriver.Stage?

    init(driver: UpdateDriver) {
        self.driver = driver
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        heading.font = DS.Text.heading()
        detail.font = DS.Text.body()
        detail.textColor = .secondaryLabelColor
        detail.preferredMaxLayoutWidth = Self.width - 2 * DS.Spacing.l
        notesView.isEditable = false
        notesView.drawsBackground = false
        notesView.textContainerInset = .zero
        notesView.textContainer?.lineFragmentPadding = 0
        notesView.isVerticallyResizable = true
        notesView.autoresizingMask = [.width]
        notesView.textContainer?.widthTracksTextView = true
        notesScroll.documentView = notesView
        notesScroll.hasVerticalScroller = true
        notesScroll.drawsBackground = false
        notesScroll.borderType = .noBorder
        notesScroll.translatesAutoresizingMaskIntoConstraints = false
        buttons.orientation = .horizontal
        buttons.spacing = DS.Spacing.s
        let stack = NSStackView(views: [heading, detail, notesScroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DS.Spacing.m
        stack.detachesHiddenViews = true
        stack.edgeInsets = NSEdgeInsets(top: DS.Spacing.l, left: DS.Spacing.l, bottom: DS.Spacing.l, right: DS.Spacing.l)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Self.width),
            stack.topAnchor.constraint(equalTo: root.topAnchor), stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            notesScroll.widthAnchor.constraint(equalToConstant: Self.width - 2 * DS.Spacing.l),
            notesScroll.heightAnchor.constraint(equalToConstant: Self.notesHeight),
            buttons.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -DS.Spacing.l),
        ])
        view = root
        show(driver)
    }

    func show(_ driver: UpdateDriver) {
        guard isViewLoaded else { return }
        let stage = driver.stage
        // A download counting up only changes the words, not the buttons.
        let sameKind: Bool = switch (shownStage, stage) {
        case (.downloading, .downloading): true
        default: shownStage == stage
        }
        shownStage = stage
        switch stage {
        case .available(let version):
            heading.stringValue = "Side \(version)"
            detail.stringValue = "Side downloads it, then relaunches to install it."
            notesScroll.isHidden = renderNotes()
            if !sameKind { setButtons([("Later", false, #selector(later)), ("Install and Relaunch", true, #selector(install))]) }
        case .downloading:
            heading.stringValue = stage.title
            detail.stringValue = "Side relaunches when it's ready."
            notesScroll.isHidden = true
            if !sameKind { setButtons([("Cancel", false, #selector(cancel))]) }
        case .failed(let reason):
            heading.stringValue = "The update didn't install"
            detail.stringValue = reason
            notesScroll.isHidden = true
            if !sameKind { setButtons([("Close", false, #selector(close)), ("Try Again", true, #selector(tryAgain))]) }
        default:
            break
        }
    }

    /// The feed's notes in the reading type of Markdown previews. True when there are none.
    private func renderNotes() -> Bool {
        guard let notes = driver.notes, !notes.text.isEmpty else { return true }
        let dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let style = MarkdownPreview.Style.current(dark: dark)
        let text: NSAttributedString
        switch notes.format {
        case "markdown":
            text = MarkdownPreview.render(notes.text, style: style)
        case "plain-text":
            text = NSAttributedString(string: notes.text, attributes: [.font: style.body, .foregroundColor: NSColor.labelColor])
        default:
            // Older feeds embed HTML: its words, in the same type.
            let html = (try? NSAttributedString(data: Data(notes.text.utf8), options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil))?.string ?? notes.text
            text = NSAttributedString(string: html.trimmingCharacters(in: .whitespacesAndNewlines), attributes: [.font: style.body, .foregroundColor: NSColor.labelColor])
        }
        notesView.textStorage?.setAttributedString(text)
        return false
    }

    private func setButtons(_ specs: [(title: String, isDefault: Bool, action: Selector)]) {
        buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for spec in specs {
            let button = NSButton(title: spec.title, target: self, action: spec.action)
            button.bezelStyle = .push
            if spec.isDefault { button.keyEquivalent = "\r" }
            buttons.addArrangedSubview(button)
        }
    }

    var buttonTitlesForTesting: [String] { buttons.arrangedSubviews.compactMap { ($0 as? NSButton)?.title } }
    var notesForTesting: String { notesView.string }

    @objc private func install() { driver.install(); onDone?() }
    @objc private func later() { driver.later(); onDone?() }
    @objc private func cancel() { driver.cancelDownload(); onDone?() }
    @objc private func tryAgain() { driver.tryAgain(); onDone?() }
    @objc private func close() { onDone?() }
}
