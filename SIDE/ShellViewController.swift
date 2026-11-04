import AppKit
import Heron
import UserNotifications
import os

/// The alert settings (Direction 03 §3.3), in Settings › Notifications.
enum AttentionPreferences {
    static let didChangeNotification = Notification.Name("SideAttentionPreferencesDidChange")
    private static let notifyKey = "attention.notifyWhenNeedsYou"
    private static let needsYouKey = "attention.soundWhenNeedsYou"
    private static let finishedKey = "attention.soundWhenFinished"

    /// A banner when an agent needs you or a run fails. On unless turned off.
    static var notifyWhenNeedsYou: Bool {
        get { UserDefaults.standard.object(forKey: notifyKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: notifyKey); changed() }
    }

    /// Glass when an agent waits on you, Funk when a run fails. On unless turned off.
    static var soundWhenNeedsYou: Bool {
        get { UserDefaults.standard.object(forKey: needsYouKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: needsYouKey); changed() }
    }

    /// A turn finishing with something to review alerts too (Tink, and a banner if banners are
    /// on). Off unless turned on.
    static var alsoWhenFinished: Bool {
        get { UserDefaults.standard.bool(forKey: finishedKey) }
        set { UserDefaults.standard.set(newValue, forKey: finishedKey); changed() }
    }

    private static func changed() { NotificationCenter.default.post(name: didChangeNotification, object: nil) }
}

/// One banner, as `AttentionCenter` decided it.
struct AttentionNotification: Equatable {
    /// One per track: a newer state replaces the banner instead of stacking another.
    let id: String
    let title: String
    let subtitle: String
    let body: String
    let projectRoot: URL
    let trackKey: String
}

@MainActor
protocol AttentionNotifying: AnyObject {
    /// Posts the banner. True when it carries `sound` itself, so the app doesn't play it too.
    @discardableResult func post(_ notification: AttentionNotification, sound: NSSound.Name?) -> Bool
    /// The state passed (approved, answered, looked at): its banner leaves Notification Center.
    func withdraw(id: String)
}

/// Side's system notifications. Permission is asked the first time there's something to say,
/// and that first banner waits for the answer instead of being lost. A banner carries its own
/// sound when notifications may play sounds, which is what lets Focus silence it; otherwise the
/// app plays the sound. Clicking one brings its window to that track's Think.
@MainActor
final class SystemNotifier: NSObject, AttentionNotifying, @preconcurrency UNUserNotificationCenterDelegate {
    static let shared = SystemNotifier()

    static let projectKey = "projectRoot"
    static let trackKey = "trackKey"

    private static let log = Logger(subsystem: "com.shahi.side", category: "SystemNotifier")
    private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }
    private var authorization: UNAuthorizationStatus = .notDetermined
    private var soundsAllowed = false
    private var asking = false
    private var waiting: [(AttentionNotification, NSSound.Name?)] = []

    /// At launch: the delegate, and what the person has allowed so far.
    func start() {
        center.delegate = self
        refreshSettings()
        NotificationCenter.default.addObserver(self, selector: #selector(appBecameActive), name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    /// System Settings may have changed what's allowed while Side was in the background.
    @objc private func appBecameActive() { refreshSettings() }

    private func refreshSettings() {
        center.getNotificationSettings { settings in
            let status = settings.authorizationStatus
            let sounds = settings.soundSetting == .enabled
            Task { @MainActor in
                self.authorization = status
                self.soundsAllowed = sounds
            }
        }
    }

    func post(_ notification: AttentionNotification, sound: NSSound.Name?) -> Bool {
        Self.log.notice("post \(notification.body, privacy: .public), authorization \(self.authorization.rawValue, privacy: .public), sounds \(self.soundsAllowed, privacy: .public)")
        switch authorization {
        case .denied:
            return false
        case .notDetermined:
            waiting.append((notification, sound))
            ask()
            // Unknown until the answer: the app plays the sound now, and the banner goes silent.
            return false
        default:
            add(notification, sound: soundsAllowed ? sound : nil)
            return sound != nil && soundsAllowed
        }
    }

    func withdraw(id: String) {
        center.removeDeliveredNotifications(withIdentifiers: [id])
        waiting.removeAll { $0.0.id == id }
    }

    private func ask() {
        guard !asking else { return }
        asking = true
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            Self.log.notice("authorization granted \(granted, privacy: .public), error \(String(describing: error), privacy: .public)")
            Task { @MainActor in
                self.asking = false
                self.authorization = granted ? .authorized : .denied
                let pending = self.waiting
                self.waiting = []
                guard granted else { return }
                // Their sound already played when they happened.
                for (notification, _) in pending { self.add(notification, sound: nil) }
                self.refreshSettings()
            }
        }
    }

    private func add(_ notification: AttentionNotification, sound: NSSound.Name?) {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.subtitle = notification.subtitle
        content.body = notification.body
        content.threadIdentifier = notification.projectRoot.path
        content.userInfo = [Self.projectKey: notification.projectRoot.path, Self.trackKey: notification.trackKey]
        if let sound { content.sound = UNNotificationSound(named: UNNotificationSoundName(sound)) }
        center.add(UNNotificationRequest(identifier: notification.id, content: content, trigger: nil))
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Side in front but on another window, track or stage: still out of view, so the banner
    /// shows. `AttentionCenter` already left out what you were looking at.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
           let root = info[Self.projectKey] as? String, let trackKey = info[Self.trackKey] as? String {
            Self.reveal(projectRoot: URL(fileURLWithPath: root), trackKey: trackKey)
        }
        completionHandler()
    }

    /// The window already on that track if there is one, else any window on the project.
    static func reveal(projectRoot: URL, trackKey: String) {
        NSApp.activate(ignoringOtherApps: true)
        let shells = AppDelegate.shared?.shellViewControllers.filter { $0.isOnProject(projectRoot) } ?? []
        guard let shell = shells.first(where: { ($0.currentTrackKeyForAttention ?? "") == trackKey }) ?? shells.first else { return }
        shell.revealAgent(of: trackKey)
    }
}

/// The app's one decision about reaching the user (Direction 03 §3.3). Every window reports its
/// tracks' activity here; the center diffs per project and track, so two windows on one project
/// produce one event, not two. An event out of view posts its banner and its sound (at most one
/// sound every 3 s across the app; the banners still go, silently). A banner carries the sound
/// itself when it can, so nothing plays twice.
@MainActor
final class AttentionCenter {
    static let shared = AttentionCenter()

    enum Event: Equatable {
        case needsYou, failed, finished

        var sound: NSSound.Name {
            switch self {
            case .needsYou: "Glass"
            case .failed: "Funk"
            case .finished: "Tink"
            }
        }

        /// The status word (Direction 03 §3.1).
        var word: String {
            switch self {
            case .needsYou: DS.StatusState.needsYou.name
            case .failed: DS.StatusState.failed.name
            case .finished: DS.StatusState.verified.name
            }
        }

        var soundEnabled: Bool {
            switch self {
            case .needsYou, .failed: AttentionPreferences.soundWhenNeedsYou
            case .finished: AttentionPreferences.alsoWhenFinished
            }
        }

        var notifies: Bool {
            switch self {
            case .needsYou, .failed: AttentionPreferences.notifyWhenNeedsYou
            case .finished: AttentionPreferences.notifyWhenNeedsYou && AttentionPreferences.alsoWhenFinished
            }
        }
    }

    struct TrackActivity {
        let trackKey: String
        let title: String
        let activity: AgentActivity
    }

    static let soundInterval: TimeInterval = 3
    private static let log = Logger(subsystem: "com.shahi.side", category: "AttentionCenter")

    var play: (NSSound.Name) -> Void = { NSSound(named: $0)?.play() }
    var notifier: any AttentionNotifying = SystemNotifier.shared
    var now: () -> Date = Date.init
    /// Whether some key window is already showing this track's agent. Asked once per event.
    var isLooking: (URL, String) -> Bool = { root, trackKey in
        AppDelegate.shared?.shellViewControllers.contains { $0.isShowingAgent(of: trackKey, in: root) } ?? false
    }

    private var known: [String: AgentActivity] = [:]
    private var lastSound: Date?

    static func notificationID(projectRoot: URL, trackKey: String) -> String {
        "track\u{0}" + projectRoot.standardizedFileURL.path + "\u{0}" + trackKey
    }

    /// A window's view of its project's tracks. The first sight of a track only records where it
    /// stands: a state already there when Side opens isn't news.
    func report(projectRoot: URL, _ tracks: [TrackActivity]) {
        let root = projectRoot.standardizedFileURL
        for track in tracks {
            let key = root.path + "\u{0}" + track.trackKey
            let previous = known.updateValue(track.activity, forKey: key)
            guard let previous, previous != track.activity else { continue }
            Self.log.notice("\(track.trackKey, privacy: .public): \(String(describing: previous), privacy: .public) -> \(String(describing: track.activity), privacy: .public), looking \(self.isLooking(root, track.trackKey), privacy: .public)")
            let id = Self.notificationID(projectRoot: root, trackKey: track.trackKey)
            let event: Event? = switch track.activity {
            case .needsYou: .needsYou
            case .failed: .failed
            // Seen or not: Think marks a turn seen when it's on screen, even in a window behind
            // another app, so `isLooking` decides, not the unseen flag.
            case .doneUnread where previous == .working, .doneSeen where previous == .working: .finished
            default: nil
            }
            guard let event else {
                // What the banner said is over: approved, answered, retried or seen.
                if previous.wantsAttention || previous == .doneUnread || previous == .doneSeen { notifier.withdraw(id: id) }
                continue
            }
            guard !isLooking(root, track.trackKey) else { continue }
            let sound = soundAllowed(event) ? event.sound : nil
            var carried = false
            if event.notifies {
                carried = notifier.post(AttentionNotification(id: id, title: track.title, subtitle: root.lastPathComponent, body: event.word,
                                                              projectRoot: root, trackKey: track.trackKey), sound: sound)
            }
            if let sound {
                lastSound = now()
                if !carried { play(sound) }
            }
        }
    }

    /// A typed command in Run that failed while its window wasn't in front.
    func commandFailed() {
        guard soundAllowed(.failed) else { return }
        lastSound = now()
        play(Event.failed.sound)
    }

    private func soundAllowed(_ event: Event) -> Bool {
        guard event.soundEnabled else { return false }
        if let lastSound, now().timeIntervalSince(lastSound) < Self.soundInterval { return false }
        return true
    }
}

final class ShellViewController: NSViewController {
    // Think sits next to Make — those are the two stages a user bounces between most while
    // an agent works, so they get adjacent segments. Review sits right after Think (where its
    // checkpoints come from) and before Run (where its tests run) — the same order the
    // constitution's own stage table uses.
    /// The raw values are stored keys (pins, the stage a window was on, UI tests); `title` is
    /// what people read. Named as a developer would expect (the owner, 2026-11-04): the old
    /// names didn't say what each stage was.
    enum Stage: String, CaseIterable {
        case make = "Make", think = "Think", review = "Review", run = "Run", tracks = "Tracks"

        var title: String {
            switch self {
            case .make: return "Editor"
            case .think: return "Agent"
            case .review: return "Changes"
            case .run: return "Terminal"
            case .tracks: return "Branches"
            }
        }

        var symbol: String {
            switch self {
            case .make: return "chevron.left.forwardslash.chevron.right"
            case .think: return "sparkles"
            case .review: return "plusminus"
            case .run: return "terminal"
            case .tracks: return "arrow.triangle.branch"
            }
        }
    }

    /// Direction 02 §3: no title bar, no toolbar. The navigation components are plain views;
    /// `chrome` decides where they go.
    private let stageControl = SlidingSegmentedControl(titles: StagePins.pinnable.map(\.title), style: .capsule, height: 32)
    private let trackPill = TrackPill()
    private let searchButton = GlassCircleButton(symbol: "magnifyingglass", accessibilityLabel: "Search")
    private lazy var chrome = ChromeHost(placement: ChromePlacement.current, pill: trackPill, stageControl: stageControl, searchButton: searchButton)
    private let container = NSView()
    /// The stages the control currently shows, in order — see `StagePins.visible`.
    private var visibleStages: [Stage] = StagePins.pinnable
    /// Unpinned stages that showed themselves for attention and have since been visited. They
    /// stay out of the control until their attention clears and comes back.
    private var dismissedAttention: Set<Stage> = []
    private var lastAttention: Set<Stage> = []
    private var paletteHost: NSView?
    private lazy var makeVC = MakeWorkspaceViewController()
    private lazy var thinkVC = ThinkWorkspaceViewController()
    private lazy var reviewVC = ReviewWorkspaceViewController()
    private lazy var runVC = RunWorkspaceViewController()
    private lazy var tracksVC = TracksWorkspaceViewController()
    private var current: Stage?
    /// Shared with every other window that has the same project open — see `ProjectContext`.
    private var projectContext: ProjectContext?
    private var trackStore: TrackStore? { projectContext?.trackStore }
    private var trackStoreObserverToken = UUID()
    private var runnerChangeObserverToken = UUID()
    /// Track ids that were `.needsYou` as of the last `runnerActivityChanged()` — diffed against
    /// the current set so a notification fires once per transition *into* needing attention, not
    /// once per debounced recompute while it stays that way.
    private var lastKnownNeedsYouTrackIDs: Set<UUID> = []
    /// The track this window's stages (Make/Run/Think) are actually showing — distinct from
    /// `trackStore?.activeTrack`, which can change out from under this window via another window
    /// switching tracks on the shared store. Only updated at the same three points Make/Run/Think
    /// themselves get reloaded, so it never claims a track this window hasn't actually switched
    /// to yet. Backs `WorkspaceBridgeHost` — an `AgentRunner` uses it to decide whether *this*
    /// window is the one to write an approved edit into.
    private(set) var currentTrackKey: String?
    /// Where `currentTrackKey`'s stages actually operate — its own worktree if it has one, else
    /// `projectURL`. Threaded into Make/Run's `reloadForTrackSwitch` and used as the root for
    /// this window's own git-status/branch introspection (`refreshGitInfo`), so the title bar
    /// reflects the track actually being looked at rather than always the shared main tree.
    private var focusedRoot: URL?

    private var projectURL: URL?
    private var currentFileURL: URL?
    private var isDirty = false
    private var gitBranch: String?
    private var gitDirtyCount = 0

    override func loadView() { view = NSView() }

    override func viewDidLoad() {
        super.viewDidLoad()
        // The stages not on screen follow a text-size change too, for when they come back.
        TextScaleFollower.addDetachedViews { [weak self] in
            guard let self else { return [] }
            return [self.makeVC, self.runVC, self.thinkVC, self.reviewVC, self.tracksVC].filter { $0.isViewLoaded && $0.view.window == nil }.map(\.view)
        }
        LaunchSignposts.begin("shellViewDidLoad")
        buildLayout()
        makeVC.onProjectOpened = { [weak self] url in self?.projectOpened(url) }
        makeVC.onFileOpened = { [weak self] url in self?.fileOpened(url) }
        makeVC.onDirtyChanged = { [weak self] dirty in self?.isDirty = dirty; self?.applyWindowChrome() }
        makeVC.onInstruct = { [weak self] request in self?.startInstruct(request) }
        thinkVC.onEmptyStateAction = { [weak self] action in self?.performEmptyStateAction(action) }
        thinkVC.onOpenTrack = { [weak self] key in self?.focusTrack(key: key) }
        thinkVC.onOpenLibrary = { [weak self] in LibraryWindowController.shared.show(for: self) }
        reviewVC.onEmptyStateAction = { [weak self] action in self?.performEmptyStateAction(action) }
        runVC.onEmptyStateAction = { [weak self] action in self?.performEmptyStateAction(action) }
        makeVC.onScrollUnderTopRowChange = { [weak self] in
            guard let self, self.current == .make else { return }
            self.chrome.watchScrollBeneathTopRow(self.makeVC.scrollViewUnderTopRow)
        }
        tracksVC.onEmptyStateAction = { [weak self] action in self?.performEmptyStateAction(action) }
        reviewVC.onInstructRequested = { [weak self] path, lines, anchor in self?.presentReviewInstruct(path: path, lines: lines, anchor: anchor) }
        makeVC.onOpenThinkRequested = { [weak self] in self?.show(.think) }
        makeVC.onTearOutRequested = { [weak self] url, screenPoint in
            guard let self, let projectURL = self.projectURL else { return }
            AppDelegate.shared?.openTrackInNewWindow(projectRoot: projectURL, trackKey: self.currentTrackKey, soleFile: url, at: screenPoint)
        }
        runVC.onOpenFileRequested = { [weak self] url, line in
            guard let self else { return }
            self.show(.make)
            self.makeVC.revealFile(url, line: line)
        }
        runVC.onActivityChanged = { [weak self] in self?.setNeedsStageLabelsUpdate() }
        runVC.onRunTask = { [weak self] task in
            guard let self, let manager = self.projectContext?.runnerManager else { return }
            // Refused while the agent is mid-turn or another task holds the terminal — two
            // commands interleaving in one shell would corrupt both results.
            if manager.runner(forTrackKey: self.currentTrackKey ?? "").proposeUserTask(task) == nil { NSSound.beep() }
            self.refreshRunTasks()
        }
        runVC.onUserCommandFinished = { [weak self] command, exitCode, screen in
            if exitCode != 0, self?.view.window?.isKeyWindow != true { AttentionCenter.shared.commandFailed() }
            self?.offerAttach(command: command, exitCode: exitCode, screen: screen)
        }
        runVC.onResolveAttachOffer = { [weak self] attach in
            guard let self else { return }
            if attach, let verification = self.pendingAttach {
                self.projectContext?.sessionStore.attachVerification(verification, toLatestCheckpointFor: self.currentTrackKey ?? "")
            }
            self.pendingAttach = nil
            self.refreshRunTasks()
        }
        runVC.onResolvePendingTask = { [weak self] run in
            guard let self, let runner = self.currentRunner, let id = runner.pendingUserTaskProposalId else { return }
            runner.resolve(proposalId: id, decision: run ? .apply : .reject)
            self.refreshRunTasks()
        }
        // An agent's sign-in changed: its idle sessions restart with the new account, and Think
        // reattaches if it was showing one.
        NotificationCenter.default.addObserver(forName: AgentsPreferencesViewController.signInDidChangeNotification, object: nil, queue: .main) { [weak self] note in
            let agentId = note.userInfo?["agentId"] as? String
            MainActor.assumeIsolated {
                guard let self, let id = agentId, let context = self.projectContext else { return }
                let restarted = context.runnerManager.restartAgent(id: id)
                if let key = self.currentTrackKey, restarted.contains(key) { self.thinkVC.reloadForTrackSwitch(trackKey: key) }
            }
        }
        // A changed MCP server list reaches outside agents when their idle sessions restart
        // (Library step 2); session/load keeps the conversation.
        NotificationCenter.default.addObserver(forName: MCPServerStore.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let context = self.projectContext else { return }
                let restarted = ACPAgent.known.flatMap { context.runnerManager.restartAgent(id: $0.id) }
                if let key = self.currentTrackKey, restarted.contains(key) { self.thinkVC.reloadForTrackSwitch(trackKey: key) }
            }
        }
        NotificationCenter.default.addObserver(forName: AgentSessionStore.checkpointsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshRunTasks() }
        }
        runVC.onTearOutRequested = { [weak self] session, screenPoint in
            guard let self, let projectURL = self.projectURL else { return }
            AppDelegate.shared?.openTrackInNewWindow(projectRoot: projectURL, trackKey: self.currentTrackKey, soleSession: session, at: screenPoint)
        }
        // The one placement-specific hook outside the host: Think's composer and the bar are a
        // single stack, and the bar recedes while the composer holds text (§3.4).
        thinkVC.onComposerEngagedChanged = { [weak self] engaged in self?.chrome.setBarRecessed(engaged) }
        tracksVC.onSwitchRequested = { [weak self] track, completion in
            self?.switchToTrack(track, completion: completion)
        }
        tracksVC.onOpenStageRequested = { [weak self] track, stage in
            guard let self else { return }
            guard track.status != .active else { self.show(stage); return }
            self.switchToTrack(track, landOn: stage, completion: { _ in })
        }
        tracksVC.onBaseRequested = { [weak self] stage in self?.switchToBase(landOn: stage) }
        tracksVC.onCreateTrackRequested = { [weak self] completion in
            self?.confirmCloseAllUnsaved(completion: completion)
        }
        tracksVC.onTrackCreated = { [weak self] track in
            self?.branchIsNowActive(track.branchName)
        }
        tracksVC.onBranchSwitched = { [weak self] branchName in
            self?.branchIsNowActive(branchName)
        }
        tracksVC.tracksInUse = { [weak self] in self?.tracksInUse() ?? [] }
        tracksVC.onSetAside = { [weak self] in self?.sweepSetAsideTracks() }
        tracksVC.onTrackDeleted = { [weak self] track in
            guard let self else { return }
            self.makeVC.forgetLastFile(forTrackKey: track.branchName)
            self.projectContext?.terminals.discardSessions(forTrackKey: track.branchName)
            self.projectContext?.sessionStore.removeSession(forTrackKey: track.branchName)
            if let projectPath = self.projectContext?.projectRoot.path {
                UsageStore.shared.removeUsage(projectPath: projectPath, trackKey: track.branchName)
            }
            self.projectContext?.runnerManager.discardRunner(forTrackKey: track.branchName)
        }
        show(.make)
        LaunchSignposts.end("shellViewDidLoad")
    }

    var hasUnsavedChanges: Bool { makeVC.hasUnsavedChanges }
    func confirmCloseAllUnsaved(completion: @escaping (Bool) -> Void) { makeVC.confirmCloseAllUnsaved(completion: completion) }
    func restoreLastSessionIfAvailable() { makeVC.restoreLastSessionIfAvailable() }

    /// Loads a project into this (freshly-created) window and, if given, switches straight to
    /// one specific track — the entry point for Tracks' "Open in New Window", which is meant to
    /// land on the requested track directly rather than whatever this project's globally-active
    /// track happens to be. `loadProject` runs `projectOpened` synchronously (see its own
    /// comment), so `trackStore` is already populated by the time this looks the track up.
    /// `soleFile` / `soleSession`: a Make tab or Run terminal torn out of another window —
    /// this window holds it alone and lands on its stage, and the pill says it's a second view.
    func openProject(at url: URL, focusingTrackKey: String?, soleFile: URL? = nil, soleSession: TerminalSession? = nil) {
        isTornOut = soleFile != nil || soleSession != nil
        makeVC.soleFile = soleFile
        makeVC.loadProject(at: url)
        if let soleSession { runVC.adoptTornOutSession(soleSession, trackKey: focusingTrackKey ?? "") }
        let landOn: Stage = soleSession != nil ? .run : .make
        guard let focusingTrackKey, let store = trackStore,
              let track = store.tracks.first(where: { $0.branchName == focusingTrackKey }),
              track.status != .active
        else {
            if landOn != .make { show(landOn) }
            trackPill.refresh()
            return
        }
        switchToTrack(track, landOn: landOn, completion: { _ in })
    }

    /// Opened for a tab or terminal torn out of another window on the same track.
    private var isTornOut = false

    func prepareForClose() {
        makeVC.prepareForClose()
        thinkVC.prepareForClose()
        runVC.prepareForClose()
        if let projectURL {
            trackStore?.removeChangeObserver(trackStoreObserverToken)
            projectContext?.runnerManager.removeChangeObserver(runnerChangeObserverToken)
            projectContext?.unregisterBridgeHost(self)
            ProjectContextRegistry.shared.release(projectRoot: projectURL)
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        LaunchSignposts.begin("shellViewDidAppear")
        // Normally already installed by `makeWindow` before the window was shown; this is the
        // fallback for a window that acquired this controller some other way.
        if let window = view.window, window.titleVisibility != .hidden { installChrome(in: window) }
        LaunchSignposts.end("shellViewDidAppear")
    }

    /// The seamless frame (Direction 02 §3.2): no title bar drawn, no toolbar, content to the
    /// top edge. Called from `AppDelegate.makeWindow` before the window is ordered front. The
    /// title is still set — Mission Control, the Window menu and VoiceOver read it.
    func installChrome(in window: NSWindow) {
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.toolbar = nil
        chrome.keepTrafficLightsCentred(in: window)
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    guard let self, let window else { return }
                    self.chrome.setFullScreen(window.styleMask.contains(.fullScreen))
                    // Leaving full screen hands AppKit fresh buttons' layout; re-watch them.
                    self.chrome.keepTrafficLightsCentred(in: window)
                }
            }
        }
        applyWindowChrome()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if let window = view.window { chrome.positionTrafficLights(in: window) }
        chrome.adapt(toWidth: view.bounds.width)
        if let host = paletteHost, !host.isHidden { host.frame = chrome.paletteFrame(size: host.frame.size, in: view) }
    }

    private func buildLayout() {
        view.wantsLayer = true
        ChromeBackground.install(in: view)

        stageControl.onChange = { [weak self] index in
            guard let self, self.visibleStages.indices.contains(index) else { return }
            self.show(self.visibleStages[index])
        }
        stageControl.showsSymbols = true
        stageControl.setAccessibilityLabel("Stage")
        stageControl.menu = pinsMenu()
        searchButton.button.target = self
        searchButton.button.action = #selector(searchTapped(_:))
        searchButton.button.toolTip = "Search (⌘P)"
        trackPill.snapshotProvider = { [weak self] in self?.trackPillSnapshot() ?? .empty }
        trackPill.onSelectRow = { [weak self] row in self?.selectTrackRow(row) }
        trackPill.onNewTrack = { [weak self] in
            self?.show(.tracks)
            self?.tracksVC.newTrackTapped()
        }
        trackPill.onOpenTracks = { [weak self] in self?.show(.tracks) }
        trackPill.onNewTrackNamed = { [weak self] name in
            self?.show(.tracks)
            self?.tracksVC.newTrack(prefill: name)
        }

        chrome.install(in: view, content: container)
        // Make's surface is the editor theme's: the top row follows it.
        for name in [EditorThemes.didChangeNotification, DS.Appearance.didChangeNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyRowBackground() }
            }
        }
        NotificationCenter.default.addObserver(forName: StagePins.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.stageControl.menu = self.pinsMenu()
                self.refreshStageControl()
            }
        }
        installPalette()
        refreshStageControl()
        trackPill.refresh()
    }

    // MARK: - Palette

    /// The palette's engine is Make's (files, symbols, text on the shared `ProjectTextSearch`);
    /// the shell hosts its surface so it opens from any stage, and `chrome` says where.
    private func installPalette() {
        makeVC.loadViewIfNeeded()
        guard let surface = makeVC.paletteSurface else { return }
        let host = NSView()
        host.isHidden = true
        host.translatesAutoresizingMaskIntoConstraints = true
        surface.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(surface)
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: host.topAnchor), surface.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            surface.leadingAnchor.constraint(equalTo: host.leadingAnchor), surface.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ])
        host.wantsLayer = true
        host.shadow = NSShadow()
        host.layer?.shadowOpacity = 0.18
        host.layer?.shadowRadius = 18
        host.layer?.shadowOffset = CGSize(width: 0, height: -4)
        view.addSubview(host, positioned: .above, relativeTo: nil)
        paletteHost = host
        makeVC.onPaletteShow = { [weak self, weak host] size in
            guard let self, let host else { return }
            // Hidden, or on its way back into the nav: either way it opens out again.
            let appearing = host.isHidden || self.paletteClosing
            host.frame = self.chrome.paletteFrame(size: size, in: self.view)
            host.isHidden = false
            if appearing { self.animatePalette(host, in: true) }
        }
        makeVC.onPaletteHide = { [weak self, weak host] in
            guard let self, let host, !host.isHidden, !self.paletteClosing else { return }
            self.animatePalette(host, in: false)
        }
        makeVC.onPaletteNavigated = { [weak self] in self?.show(.make) }
        makeVC.commandsProvider = { [weak self] in self?.paletteCommands() ?? [] }
    }

    /// The palette grows out of the nav and shrinks back into it: the collapsed state is the
    /// nav's capsule (or search, with one stage). Kept as it was, with three things the owner
    /// asked for (2026-10-31): it opens quicker; it scales evenly, so it no longer looks squeezed
    /// into the bar (the collapsed state took the capsule's proportions); and a dismiss during the
    /// open turns it around from where it is, rather than ending it at once.
    private func animatePalette(_ host: NSView, in appearing: Bool) {
        guard let layer = host.layer else { host.isHidden = !appearing; return }
        guard !DS.Motion.reduceMotion else { host.isHidden = !appearing; paletteClosing = false; return }
        paletteAnimationGeneration += 1
        let generation = paletteAnimationGeneration
        paletteClosing = !appearing
        let source = chrome.paletteOrigin(in: view)
        // Evenly, to the capsule's width, about its centre. Layer-backed views transform about
        // their origin, so the scale is placed by hand.
        let scale = max(min(source.width / max(host.bounds.width, 1), 1), 0.05)
        let collapsedSize = NSSize(width: host.bounds.width * scale, height: host.bounds.height * scale)
        let collapsed = CATransform3DConcat(
            CATransform3DMakeScale(scale, scale, 1),
            CATransform3DMakeTranslation(source.midX - collapsedSize.width / 2 - host.frame.minX,
                                         source.midY - collapsedSize.height / 2 - host.frame.minY, 0))
        // From what's on screen when it's turned around mid-way.
        let shown = layer.presentation()
        let inFlight = layer.animation(forKey: "palette") != nil && shown != nil
        let transform = CABasicAnimation(keyPath: "transform")
        transform.fromValue = inFlight ? shown!.transform : (appearing ? collapsed : CATransform3DIdentity)
        transform.toValue = appearing ? CATransform3DIdentity : collapsed
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = inFlight ? shown!.opacity : (appearing ? 0 : 1)
        fade.toValue = appearing ? 1 : 0
        let group = CAAnimationGroup()
        group.animations = [transform, fade]
        group.duration = appearing ? 0.22 : 0.18
        group.timingFunction = DS.Motion.easeOut
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak host] in
            MainActor.assumeIsolated {
                guard let self, let host, self.paletteAnimationGeneration == generation else { return }
                if !appearing { host.isHidden = true }
                self.paletteClosing = false
                host.layer?.removeAnimation(forKey: "palette")
            }
        }
        layer.add(group, forKey: "palette")
        CATransaction.commit()
    }

    private var paletteAnimationGeneration = 0
    private var paletteClosing = false
    var paletteLayerForTesting: CALayer? { paletteHost?.layer }
    func paletteOriginForTesting() -> NSRect { chrome.paletteOrigin(in: view) }
    var updatePillForTesting: UpdatePill? { chrome.updatePill }
    var searchFrameForTesting: NSRect { searchButton.convert(searchButton.bounds, to: view) }

    /// Every stage — pinned or not — and every Navigate menu item, by name.
    private func paletteCommands() -> [PaletteCommand] {
        var commands = Stage.allCases.map { stage in
            PaletteCommand(title: "Go to \(stage.title)", shortcut: Shortcuts.display("stage.\(stage)").nonEmpty) { [weak self] in
                self?.show(stage)
            }
        }
        let navigate = NSApp.mainMenu?.items.first { $0.title == "Navigate" }?.submenu
        for item in navigate?.items ?? [] where !item.isSeparatorItem && item.action != nil && !item.title.hasPrefix("Go to ") {
            let chord = item.keyEquivalent.isEmpty ? nil : KeyChord(item.keyEquivalent, item.keyEquivalentModifierMask).display
            commands.append(PaletteCommand(title: item.title, shortcut: chord) { [weak item] in
                guard let item, let action = item.action else { return }
                NSApp.sendAction(action, to: item.target, from: item)
            })
        }
        commands.append(PaletteCommand(title: "New Track…", shortcut: Shortcuts.display("track.new").nonEmpty) { [weak self] in self?.trackPill.onNewTrack?() })
        commands.append(PaletteCommand(title: "Switch Track…", shortcut: Shortcuts.display("track.switch").nonEmpty) { [weak self] in self?.trackPill.togglePopover() })
        return commands
    }

    @objc func showQuickOpen(_ sender: Any?) { makeVC.presentPalette(.files) }
    /// The bar's search button: files, unless Make isn't pinned, where opening a file would land
    /// on a stage the bar doesn't show (2026-10-23, the owner). Then it starts in Commands;
    /// ⌘P still finds files, and opening one still shows it in Make.
    @objc func searchTapped(_ sender: Any?) { makeVC.presentPalette(StagePins.pinned.contains(.make) ? .files : .commands) }
    @objc func showCommandPalette(_ sender: Any?) { makeVC.presentPalette(.commands) }
    @objc func showFindInProject(_ sender: Any?) { makeVC.presentPalette(.text) }
    // Find in the file on screen: Make's, from Make.
    @objc func showFind(_ sender: Any?) { if current == .make { makeVC.presentFind(replace: false) } }
    @objc func showFindAndReplace(_ sender: Any?) { if current == .make { makeVC.presentFind(replace: true) } }
    @objc func findNext(_ sender: Any?) { if current == .make { makeVC.findNext(forward: true) } }
    @objc func findPrevious(_ sender: Any?) { if current == .make { makeVC.findNext(forward: false) } }
    @objc func useSelectionForFind(_ sender: Any?) { if current == .make { makeVC.useSelectionForFind() } }
    @objc func showGoToSymbol(_ sender: Any?) { makeVC.presentPalette(.symbols) }
    @objc func toggleTrackPopover(_ sender: Any?) { trackPill.togglePopover() }
    @objc func selectNextTab(_ sender: Any?) { adjacentTab(1) }
    @objc func selectPreviousTab(_ sender: Any?) { adjacentTab(-1) }

    /// ⌃Tab cycles the tabs in the current stage's top row.
    private func adjacentTab(_ offset: Int) {
        switch current {
        case .make: makeVC.selectAdjacentTab(offset)
        case .run: runVC.selectAdjacentTab(offset)
        default: break
        }
    }

    // MARK: - Pinning

    private func pinsMenu() -> NSMenu {
        let menu = NSMenu(title: "Pinned Stages")
        let pinned = StagePins.pinned
        for stage in StagePins.pinnable {
            let item = NSMenuItem(title: stage.title, action: #selector(togglePinnedStage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = stage.rawValue
            item.state = pinned.contains(stage) ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc func togglePinnedStage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let stage = Stage(rawValue: raw) else { return }
        StagePins.toggle(stage)
    }

    /// Recomputes which stages the control shows and each one's dot.
    /// The top row takes the stage's surface (and, for Make under an editor theme, its appearance).
    private func applyRowBackground() {
        let stage = children.first as? StageChromeProviding
        chrome.setRowBackground(stage?.topRowBackground ?? DS.Color.canvas, appearance: stage?.topRowAppearance)
    }

    private func refreshStageControl() {
        let attention = stagesNeedingAttention()
        // A stage whose attention cleared can come back the next time it has something.
        dismissedAttention.formIntersection(attention)
        lastAttention = attention
        let stages = StagePins.visible(pinned: StagePins.pinned, attention: attention, dismissed: dismissedAttention, current: current)
        if stages != visibleStages || stageControl.segmentAccessibilityLabels.count != stages.count {
            visibleStages = stages
            stageControl.setSegments(stages.map(\.title), symbols: stages.map(\.symbol), selected: current.flatMap { stages.firstIndex(of: $0) } ?? -1)
        } else if let current, let index = stages.firstIndex(of: current) {
            if index != stageControl.selectedIndex { stageControl.select(index, animated: true) }
        } else {
            stageControl.clearSelection()
        }
        for (index, stage) in stages.enumerated() {
            let badge = stageBadge(stage)
            stageControl.setBadge(badge?.state, spokenState: badge?.spoken, at: index)
        }
        chrome.setStageControlHidden(stages.count <= 1)
    }

    /// Unpinned stages with something that needs the user: Review has a review-ready or failed
    /// checkpoint; Run has a command awaiting approval.
    private func stagesNeedingAttention() -> Set<Stage> {
        var result: Set<Stage> = []
        if let badge = stageBadge(.review), badge.state == .needsYou || badge.state == .failed || badge.state == .verified { result.insert(.review) }
        if currentRunner?.hasCommandAwaitingApproval == true { result.insert(.run) }
        return result
    }

    private var currentRunner: (any Harness)? {
        projectContext?.runnerManager.existingRunner(forTrackKey: currentTrackKey ?? "")
    }

    /// A stage's 5 pt dot and what it says: needs-you wins over working.
    private func stageBadge(_ stage: Stage) -> (state: DS.StatusState, spoken: String)? {
        switch stage {
        case .think:
            switch currentRunner?.activity {
            case .needsYou: return (.needsYou, "needs you")
            case .failed: return (.failed, "the run failed")
            case .working: return (.working, "the agent is working")
            default: return nil
            }
        case .run:
            if currentRunner?.hasCommandAwaitingApproval == true { return (.needsYou, "a command is waiting for approval") }
            return runVC.hasBackgroundActivity ? (.unread, "a terminal has new output") : nil
        case .review:
            guard let track = trackStore?.tracks.first(where: { $0.branchName == currentTrackKey }) else { return nil }
            let newest = projectContext?.sessionStore.checkpoints(forTrackKey: track.branchName).max { $0.createdAt < $1.createdAt }
            if newest?.verification?.passed == false { return (.failed, "verification failed") }
            if track.status == .reviewReady { return (.verified, "ready for review") }
            return nil
        case .make, .tracks:
            return nil
        }
    }

    // MARK: - Track pill

    private func trackPillSnapshot() -> TrackPill.Snapshot {
        guard let store = trackStore else { return .empty }
        let manager = projectContext?.runnerManager
        func state(_ track: Track) -> DS.StatusState {
            let activity = manager?.existingRunner(forTrackKey: track.branchName)?.activity ?? .none
            return DS.StatusState(track: track.displayStatus, activity: activity)
        }
        let currentTrack = store.tracks.first { $0.branchName == currentTrackKey }
        var snapshot = TrackPill.Snapshot(
            title: currentTrack.map { $0.intent.isEmpty ? $0.branchName : $0.intent } ?? "\(gitBranch ?? store.defaultBranchName()) · Base",
            state: currentTrack.map(state) ?? .idle,
            stateName: currentTrack.map { state($0).name } ?? "Base"
        )
        snapshot.projectName = projectURL?.lastPathComponent
        snapshot.isTornOut = isTornOut
        snapshot.branch = gitBranch.map { gitDirtyCount > 0 ? "\($0) · \(gitDirtyCount) changed" : $0 }
        if current == .make, let projectURL, let currentFileURL { snapshot.filePath = humanePath(for: currentFileURL, projectURL: projectURL) }
        // The base branch first: where every track forks from and lands, and where you work
        // with no track.
        snapshot.base = TrackPill.Row(key: "", title: store.defaultBranchName(), detail: "base", state: .idle, isCurrent: currentTrackKey == nil)
        for track in store.tracks where track.status != .archived {
            let rowState = state(track)
            var row = TrackPill.Row(key: track.branchName, title: track.intent.isEmpty ? track.branchName : track.intent, detail: track.branchName, state: rowState, isCurrent: track.branchName == currentTrackKey)
            row.lastActive = track.lastActiveAt
            if rowState == .needsYou || rowState == .failed {
                snapshot.needsYou.append(row)
                if !row.isCurrent { snapshot.othersNeedingYou += 1 }
            } else if track.status == .parked || track.status == .completed {
                snapshot.parked.append(row)
            } else {
                snapshot.active.append(row)
            }
        }
        // RFC R1 v1: every other open window's needs-you tracks, so "what needs me" is answerable
        // from any window.
        snapshot.otherProjects = (AppDelegate.shared?.shellViewControllers ?? [])
            .filter { $0 !== self && $0.projectURL != nil && $0.projectContext !== projectContext }
            .flatMap { $0.needsYouRowsForOtherWindows() }
        return snapshot
    }

    /// This window's needs-you tracks, as rows another window's pill can list.
    fileprivate func needsYouRowsForOtherWindows() -> [TrackPill.Row] {
        guard let store = trackStore, let manager = projectContext?.runnerManager, let window = view.window else { return [] }
        return store.tracks.compactMap { track in
            guard let activity = manager.existingRunner(forTrackKey: track.branchName)?.activity, activity.wantsAttention else { return nil }
            var row = TrackPill.Row(key: track.branchName, title: track.intent.isEmpty ? track.branchName : track.intent,
                                    detail: projectURL?.lastPathComponent ?? "", state: activity == .failed ? .failed : .needsYou)
            row.windowNumber = window.windowNumber
            return row
        }
    }

    private func selectTrackRow(_ row: TrackPill.Row) {
        if let number = row.windowNumber {
            guard let other = AppDelegate.shared?.shellViewControllers.first(where: { $0.view.window?.windowNumber == number }) else { return }
            other.view.window?.makeKeyAndOrderFront(nil)
            other.focusTrack(key: row.key)
            return
        }
        focusTrack(key: row.key)
    }

    /// Switches this window to a track without changing stage.
    func focusTrack(key: String) {
        if key.isEmpty { switchToBase(landOn: current ?? .make); return }
        guard key != currentTrackKey, let track = trackStore?.tracks.first(where: { $0.branchName == key }) else { return }
        switchToTrack(track, landOn: current ?? .make, completion: { _ in })
    }

    // MARK: - Stage switching

    /// Navigate-menu stage jumps (⌃1–⌃5), reached via the responder chain — the constitution
    /// promised "keyboard shortcuts … move between stages" from day one; this is finally them.
    @objc func jumpToStage(_ sender: NSMenuItem) {
        guard Stage.allCases.indices.contains(sender.tag) else { return }
        show(Stage.allCases[sender.tag])
    }

    /// Routed from the app delegate's File-menu items, which are app-level commands and must
    /// stay enabled regardless of what holds first responder.
    func presentOpenProject() { makeVC.openProjectFromMenuAction() }
    func presentNewProject() { makeVC.newProjectFromMenuAction() }

    @objc private func revealProjectInFinder() {
        guard let projectURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([projectURL])
    }

    /// A template from Library: a new track named by its title, opened in Think, with the
    /// prompt sent as its first message.
    func startTrack(from prompt: SavedPrompt) {
        confirmCloseAllUnsaved { [weak self] proceed in
            guard let self, proceed, let store = self.trackStore else { return }
            store.createTrack(intent: prompt.title) { [weak self] result in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        switch result {
                        case .success(let (track, _)):
                            self.branchIsNowActive(track.branchName)
                            self.show(.think)
                            // After the stages have attached to the new track.
                            DispatchQueue.main.async { self.thinkVC.sendAsTyped(prompt.body) }
                        case .failure(let error):
                            let alert = NSAlert(error: error)
                            alert.messageText = "Couldn't start \u{201C}\(prompt.title)\u{201D}"
                            alert.runModal()
                        }
                    }
                }
            }
        }
    }

    /// What Library shows for this window: the working copy of the track on screen.
    var libraryTarget: LibraryTarget? {
        guard let projectURL else { return nil }
        return LibraryTarget(projectName: projectURL.lastPathComponent, projectRoot: projectURL, workingRoot: focusedRoot ?? projectURL,
                             stateDirectory: projectContext?.stateDirectory, trackStore: trackStore)
    }

    /// UI testing's measurement scripts: close every Make tab without asking.
    func closeAllMakeTabsForTesting() { makeVC.closeAllTabsForTesting() }
    var makeForTesting: MakeWorkspaceViewController { makeVC }
    /// UI testing: a new track on the given agent, shown in Think.
    func thinkTrackForTesting(agentId: String) {
        guard let store = trackStore else { return }
        store.createTrack(intent: "Measurement") { [weak self] result in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, case .success(let (track, _)) = result else { return }
                    store.setHarness(agentId, forTrackKey: track.branchName)
                    self.branchIsNowActive(track.branchName)
                    self.show(.think)
                }
            }
        }
    }

    /// UI testing: ⇧⌘V in Make.
    func toggleMarkdownPreviewForTesting() { makeVC.toggleMarkdownPreviewForTesting() }

    /// UI testing: the scroll view under the window's centre moves down a page at a time,
    /// one page per frame, as a fast scroll would.
    func scrollForTesting(pages: Int) {
        guard let window = view.window, let content = window.contentView else { return }
        let centre = NSPoint(x: content.bounds.midX, y: content.bounds.midY)
        guard let scroll = content.hitTest(centre)?.enclosingScrollView else { return }
        var remaining = pages * 8
        func step() {
            guard remaining > 0 else { return }
            remaining -= 1
            let clip = scroll.contentView
            let limit = max(0, (scroll.documentView?.frame.height ?? 0) - clip.bounds.height)
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: min(limit, clip.bounds.minY + clip.bounds.height / 8)))
            scroll.reflectScrolledClipView(clip)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { step() }
        }
        step()
    }

    /// UI testing: typing into Run's terminal.
    func runTypeForTesting(_ text: String) { runVC.typeForTesting(text) }

    /// UI testing: a stage brought forward by name ("make", "think", "review", "run").
    func showStageForTesting(_ name: String) {
        guard let stage = Stage.allCases.first(where: { "\($0)".lowercased() == name.lowercased() }) else { return }
        show(stage)
    }

    var chromeHiddenForTesting: Bool { chrome.isChromeHidden }
    var topRowHiddenForTesting: Bool { chrome.topRow.isHidden }
    var currentStageForTesting: String? { current.map { "\($0)" } }

    /// UI testing: a message sent in Think, as typed.
    func thinkSendForTesting(_ text: String) { thinkVC.sendAsTyped(text) }

    /// UI testing: Find and Replace open with a query typed, as ⌥⌘F and typing would.
    func findForTesting(_ query: String) {
        makeVC.presentFind(replace: true)
        makeVC.searchField.stringValue = query
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: makeVC.searchField)
    }

    // MARK: Writer mode

    /// Make alone: no top row, bar, tabs or window buttons; Esc or the menu item leaves.
    private(set) var isWriting = false
    private var escapeMonitor: Any?
    private var enteredFullScreenToWrite = false

    @objc func toggleWriterMode(_ sender: Any?) { setWriterMode(!isWriting) }

    // MARK: - Zoom

    /// What ⌘= ⌘− ⌘0 grow in the stage in front: Make's text (editor, preview, Writer Mode) or
    /// Run's terminal. The same sizes as Settings › Appearance, so the two never disagree.
    enum ZoomSurface: Equatable {
        case editor, terminal
        var name: String { self == .editor ? "Editor" : "Terminal" }
        var size: CGFloat {
            get { self == .editor ? DS.Text.CodeSize.editor : DS.Text.CodeSize.terminal }
            nonmutating set { if self == .editor { DS.Text.CodeSize.editor = newValue } else { DS.Text.CodeSize.terminal = newValue } }
        }
    }

    var zoomSurface: ZoomSurface? {
        switch current {
        case .make: .editor
        case .run: .terminal
        default: nil
        }
    }

    @objc func zoomIn(_ sender: Any?) { zoom(by: 1) }
    @objc func zoomOut(_ sender: Any?) { zoom(by: -1) }
    @objc func actualSize(_ sender: Any?) { zoom(by: 0) }

    /// Steps the size (0 is the default) and says so on the zoom pill, or in Writer mode, where
    /// the bar is hidden, in the word count's pill.
    private func zoom(by steps: Int) {
        guard let surface = zoomSurface else { NSSound.beep(); return }
        let size = steps == 0 ? DS.Text.CodeSize.standard : DS.Text.CodeSize.zoomed(surface.size, by: steps)
        if size != surface.size { surface.size = size }
        if isWriting { makeVC.showZoomWhileWriting(size); return }
        guard let pill = chrome.zoomPill else { return }
        pill.onZoomIn = { [weak self] in self?.zoom(by: 1) }
        pill.onZoomOut = { [weak self] in self?.zoom(by: -1) }
        pill.onClick = { [weak self] in self?.zoom(by: 0) }
        pill.show("\(surface.name) \u{00B7} \(Int(size)) pt")
    }

    var zoomPillForTesting: ZoomPill? { chrome.zoomPill }

    func setWriterMode(_ on: Bool) {
        guard on != isWriting else { return }
        if on { show(.make) }
        isWriting = on
        DS.Motion.crossfade(view, duration: DS.Motion.glanceDuration)
        chrome.setHidden(on, animated: true)
        if !on { refreshStageControl() }
        makeVC.setTopObstruction(on ? 0 : ChromeHost.rowHeight)
        makeVC.setBottomObstruction(on ? 0 : chrome.bottomObstruction)
        makeVC.setWriterMode(on)
        if let window = view.window {
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { window.standardWindowButton(kind)?.isHidden = on }
            let fullScreen = window.styleMask.contains(.fullScreen)
            if on, WriterPreferences.isOn(.fullScreen), !fullScreen {
                enteredFullScreenToWrite = true
                window.toggleFullScreen(nil)
            } else if !on, enteredFullScreenToWrite {
                enteredFullScreenToWrite = false
                if fullScreen { window.toggleFullScreen(nil) }
            }
        }
        NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items)
            .first { $0.action == #selector(toggleWriterMode(_:)) }?.state = on ? .on : .off
        if on {
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.isWriting, event.window === self.view.window, event.keyCode == 53,
                      event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
                      !self.makeVC.isPaletteOpen, !self.makeVC.hasTransientSurface else { return event }
                self.setWriterMode(false)
                return nil
            }
        } else if let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
            escapeMonitor = nil
        }
    }

    /// A tab torn out of another window landing here — jump to Make and show that file.
    func revealFile(_ url: URL) {
        show(.make)
        makeVC.revealFile(url, line: nil)
    }

    /// side://run/<id>: brings this window to Run, on the tab with that keeper session, if this
    /// window has the session or is on `project`. False if it has neither. A session on another
    /// track switches to that track first, as picking it would. Run restores a track's tabs
    /// (reattaching them) when it's shown, so the tab may only exist after.
    func revealTerminal(keeperID id: String, inProject project: URL?, trackKey: String?) -> Bool {
        let hasSession = projectContext?.terminals.everySession().contains(where: { $0.viewController.keeperID == id }) == true
        let onProject = project != nil && projectURL?.standardizedFileURL.path == project?.standardizedFileURL.path
        guard hasSession || onProject else { return false }
        view.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        if let key = trackKey, key != (currentTrackKey ?? ""), !runVC.listsSession(keeperID: id),
           let track = trackStore?.tracks.first(where: { $0.branchName == key }) {
            switchToTrack(track, landOn: .run) { [weak self] outcome in
                guard outcome != nil else { return }
                self?.runVC.showSession(keeperID: id)
            }
        } else {
            show(.run)
            runVC.showSession(keeperID: id)
        }
        return true
    }

    /// Whether this window's Run has that keeper session among its own tabs.
    func listsTerminal(keeperID id: String) -> Bool { runVC.listsSession(keeperID: id) }

    var hasProject: Bool { projectURL != nil }

    private func show(_ stage: Stage) {
        guard current != stage else { return }
        // Writer mode is Make alone: going anywhere else leaves it.
        if isWriting, stage != .make { setWriterMode(false) }
        // Transient surfaces never outlive the stage they were opened on (§5 acceptance).
        dismissCheckpointSheet()
        pendingAttach = nil
        makeVC.dismissInstructSurfaces()
        reviewInstructPopover?.close()
        reviewInstructPopover = nil
        current = stage
        // Visiting an unpinned stage that showed itself for attention is what dismisses it.
        if lastAttention.contains(stage) { dismissedAttention.insert(stage) }
        refreshStageControl()

        // Stages are places, not pages: the content crossfades, nothing slides (Direction 03 §2.3).
        if !children.isEmpty { DS.Motion.crossfade(container) }
        for child in children {
            child.view.removeFromSuperview()
            child.removeFromParent()
        }

        let next: NSViewController
        switch stage {
        case .make: next = makeVC
        case .think: next = thinkVC
        case .review: next = reviewVC
        case .run: next = runVC
        case .tracks: next = tracksVC
        }
        addChild(next)
        next.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(next.view)
        NSLayoutConstraint.activate([
            next.view.topAnchor.constraint(equalTo: container.topAnchor),
            next.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            next.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            next.view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        chrome.setStageContent((next as? StageChromeProviding)?.topRowContent)
        applyRowBackground()
        // Think's changes and session pills join the bar row when there is one (the spread-row
        // decision, 2026-09-22); anywhere else — or with no bar — they stay above the composer.
        // Only when they fit — a narrow window keeps them there rather than being widened.
        chrome.placeAccessories(of: next as? StageChromeProviding, width: view.bounds.width)
        chrome.watchScrollBeneathTopRow((next as? StageChromeProviding)?.scrollViewUnderTopRow)
        (next as? StageChromeProviding)?.setBottomObstruction(chrome.bottomObstruction)
        (next as? StageChromeProviding)?.setTopObstruction(ChromeHost.rowHeight)
        if stage == .run {
            runVC.activateActiveSession()
        }
        applyWindowChrome()
    }

    private func updateStageLabels() {
        refreshStageControl()
        trackPill.refresh()
    }

    /// Run reports every terminal event (a command starting or ending, a `cd`, unseen output),
    /// several per command and more under an agent's output; one refresh per 100 ms covers a
    /// burst, where one per event rebuilt the pill and the stage control each time.
    private func setNeedsStageLabelsUpdate() {
        guard !stageLabelsUpdateScheduled else { return }
        stageLabelsUpdateScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.stageLabelsUpdateScheduled = false
            self.updateStageLabels()
        }
    }

    private var stageLabelsUpdateScheduled = false

    // MARK: - Agent activity (dock badge, notifications)

    private func needsYouTrackIDs() -> Set<UUID> {
        guard let trackStore, let runnerManager = projectContext?.runnerManager else { return [] }
        return Set(trackStore.tracks.filter { runnerManager.existingRunner(forTrackKey: $0.branchName)?.activity.wantsAttention == true }.map(\.id))
    }

    private func hasWorkingTrack() -> Bool {
        guard let trackStore, let runnerManager = projectContext?.runnerManager else { return false }
        return trackStore.tracks.contains { runnerManager.existingRunner(forTrackKey: $0.branchName)?.activity == .working }
    }

    /// Read by `AppDelegate` to sum a dock badge across every open window — see
    /// `AppDelegate.refreshDockBadge()`. Two windows on the same project will double-count its
    /// tracks; an acceptable imprecision for a cosmetic badge, not worth deduplicating against
    /// the added complexity of exposing project identity to `AppDelegate`.
    var needsYouCount: Int { needsYouTrackIDs().count }

    /// Called after every debounced runner-manager change. Diffs against `lastKnownNeedsYouTrackIDs`
    /// so a notification fires once per transition *into* needing attention, not once per
    /// recompute while it stays that way, and refreshes the dock badge either way.
    // MARK: - Harness choice (SIDE_RFC_BYO_HARNESS.md)

    /// A track's agent changed (Tracks › Agent): its old engine is put away and Think reattaches
    /// to the new one. Every window runs this on the shared store's change; the first discards,
    /// and any window showing the track reattaches.
    private func syncHarnesses() {
        guard let context = projectContext else { return }
        for track in context.trackStore.tracks {
            let wanted = ACPAgent.agent(id: track.harnessId)?.displayName
            if let existing = context.runnerManager.existingRunner(forTrackKey: track.branchName), existing.harnessName != wanted {
                context.runnerManager.discardRunner(forTrackKey: track.branchName)
            }
            if track.branchName == currentTrackKey, thinkVC.attachedHarnessName != wanted {
                thinkVC.reloadForTrackSwitch(trackKey: currentTrackKey)
            }
        }
    }

    // MARK: - First run (Direction 02 §6)

    private var firstRunSheet: NSWindow?
    /// The sheet is in play this session: shown, or stepped aside while one of its steps runs.
    private var firstRunActive = false
    /// Ending our own sheet posts the same notification as a step's sheet ending; skip that one.
    private var ignoreNextSheetEnd = false
    private var firstRunObservers: [NSObjectProtocol] = []

    /// Called once launch has restored (or not) the last session.
    func presentFirstRunIfNeeded() {
        guard let window = view.window else { return }
        if !FirstRun.forced {
            guard !AppDelegate.isUITesting else { return }
            let recents = (HeronDefaults.store.array(forKey: "side.recent-projects") as? [String]) ?? []
            let hasRecents = !recents.isEmpty || HeronDefaults.store.string(forKey: "side.last-project-path") != nil
            guard FirstRun.shouldPresent(dismissed: FirstRun.dismissed, hasRecentProjects: hasRecents, modelReady: FirstRun.modelReady) else { return }
        }
        firstRunActive = true
        // A step's own sheet (open panel, New Track) ending, or Preferences closing, brings the
        // sheet back with that step ticked.
        firstRunObservers = [
            NotificationCenter.default.addObserver(forName: NSWindow.didEndSheetNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.ignoreNextSheetEnd { self.ignoreNextSheetEnd = false; return }
                    self.resumeFirstRun()
                }
            },
            NotificationCenter.default.addObserver(forName: NSWindow.didBecomeMainNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resumeFirstRun() }
            },
        ]
        showFirstRun()
    }

    private func firstRunDone() -> Set<FirstRun.Step> {
        var done: Set<FirstRun.Step> = []
        if projectURL != nil { done.insert(.project) }
        if FirstRun.modelReady { done.insert(.model) }
        if trackStore?.tracks.isEmpty == false { done.insert(.track) }
        return done
    }

    private func resumeFirstRun() {
        DispatchQueue.main.async { [weak self] in self?.showFirstRun() }
    }

    private func showFirstRun() {
        guard firstRunActive, firstRunSheet == nil, let window = view.window, window.attachedSheet == nil else { return }
        let done = firstRunDone()
        guard done.count < FirstRun.Step.allCases.count else { endFirstRun(forever: true); return }
        let needsGit = trackStore?.repoState == .notAGitRepo
        let controller = FirstRunSheetController(done: done, needsGit: needsGit)
        controller.onStep = { [weak self] step in
            guard let self else { return }
            self.hideFirstRun()
            switch step {
            case .project: self.performEmptyStateAction(.openProject)
            case .model: self.performEmptyStateAction(.setUpModel)
            case .track: self.performEmptyStateAction(needsGit ? .initializeGit : .newTrack)
            }
        }
        controller.onDismiss = { [weak self] in self?.endFirstRun(forever: true) }
        let sheet = DismissableSheetWindow(contentViewController: controller)
        sheet.styleMask = [.titled]
        // Escape puts it away for this session; only "Don't Show Again" is forever.
        sheet.onCancel = { [weak self] in self?.endFirstRun(forever: false) }
        firstRunSheet = sheet
        window.beginSheet(sheet)
    }

    /// A step finished while the sheet was already back up (track creation completes after its
    /// alert closes): redraw it with the new tick.
    private func refreshFirstRunIfShown() {
        guard firstRunSheet != nil else { return }
        hideFirstRun()
        resumeFirstRun()
    }

    private func hideFirstRun() {
        guard let sheet = firstRunSheet else { return }
        firstRunSheet = nil
        ignoreNextSheetEnd = true
        view.window?.endSheet(sheet)
    }

    private func endFirstRun(forever: Bool) {
        if forever, !FirstRun.forced { FirstRun.dismissed = true }
        firstRunActive = false
        hideFirstRun()
        firstRunObservers.forEach(NotificationCenter.default.removeObserver)
        firstRunObservers = []
    }

    // MARK: - Empty states (Direction 02 §6)

    /// Every empty state's one action lands here: the shell is the only place that can open a
    /// project, initialise git, start or choose a track, or open Providers.
    private func performEmptyStateAction(_ action: EmptyStateAction) {
        switch action {
        case .openProject: makeVC.openProjectFromMenuAction()
        case .initializeGit:
            show(.tracks)
            tracksVC.initializeGit()
        case .newTrack: trackPill.onNewTrack?()
        case .chooseTrack: trackPill.togglePopover()
        case .setUpModel: AppDelegate.shared?.openPreferences(on: .providers)
        }
    }

    // MARK: - Inline instruct (Direction 02 §5.3)

    /// The instruct in flight: its runner, the observer watching it, and where in the transcript
    /// it began — so only what it produced is shown back in Make.
    private var instruct: (runner: any Harness, token: UUID, start: Int, request: InlineInstruct.Request)?
    /// `send` records the message before the turn starts; "not busy" means finished only after
    /// the turn has been seen running.
    private var instructTurnStarted = false

    /// Sends the pointer message to the track's conversation. No stage change: Change comes back
    /// as a card beside the lines, Ask as an answer in the popover.
    private func startInstruct(_ request: InlineInstruct.Request) {
        guard let manager = projectContext?.runnerManager else { return }
        // Conversations happen on tracks (§6), and an instruct is a message in one.
        guard let trackKey = currentTrackKey, !trackKey.isEmpty else {
            let note = "Instruct works on a track. Start one first."
            makeVC.instructProblem(note)
            reviewInstructController?.showProblem(note)
            return
        }
        let runner = manager.runner(forTrackKey: trackKey)
        guard runner.isReadyToSend else {
            makeVC.instructProblem(runner.notReadyReason)
            reviewInstructController?.showProblem(runner.notReadyReason)
            return
        }
        endInstruct()
        let start = runner.entries.count
        let token = runner.addObserver { [weak self] _ in self?.instructProgressed() }
        instruct = (runner, token, start, request)
        runner.send(InlineInstruct.message(for: request))
        if request.verb == .ask {
            makeVC.instructWaiting()
            reviewInstructController?.showWaiting()
        } else {
            makeVC.instructSent()
            reviewInstructPopover?.close()
            reviewInstructPopover = nil
        }
    }

    private func instructProgressed() {
        guard let (runner, _, start, request) = instruct else { return }
        if runner.phase.isBusy { instructTurnStarted = true }
        let turnEnded = instructTurnStarted && !runner.phase.isBusy
        switch request.verb {
        case .change:
            if let (id, proposal) = InlineInstruct.pendingProposal(forRelativePath: request.relativePath, in: runner.entries, after: start) {
                let delta = AgentRunner.lineDelta(in: proposal.diffText)
                makeVC.showInstructProposal(
                    id: id, url: request.url, line: request.lines.lowerBound, added: delta.added, removed: delta.removed,
                    apply: { [weak runner] in runner?.resolve(proposalId: id, decision: .apply) },
                    reject: { [weak runner] in runner?.resolve(proposalId: id, decision: .reject) }
                )
            } else {
                // Decided in Think instead, or the turn ended without an edit to this file.
                makeVC.dismissInstructCard()
                if turnEnded { endInstruct() }
            }
        case .ask:
            guard turnEnded else { return }
            let answer = runner.entries.dropFirst(start).reversed().lazy.compactMap { entry -> String? in
                if case .assistantText(let text) = entry.kind { return text }
                return nil
            }.first
            let text = answer ?? "No answer came back. The conversation in Agent has the details."
            makeVC.instructAnswer(text)
            reviewInstructController?.showAnswer(text)
            endInstruct()
        }
    }

    private var reviewInstructPopover: NSPopover?
    private var reviewInstructController: InstructPopoverController?

    /// Review's "Instruct…" on a file: the same popover and the same message, pointing at the
    /// lines the diff touches in the track's working copy. Results come back in Think.
    private func presentReviewInstruct(path: String, lines: ClosedRange<Int>, anchor: NSView) {
        reviewInstructPopover?.close()
        let url = workingDirectoryURL(for: currentTrackKey).appendingPathComponent(path)
        let controller = InstructPopoverController(pointer: FileMention.pointer(relativePath: path, lines: lines))
        controller.onSubmit = { [weak self] verb, instruction in
            self?.startInstruct(InlineInstruct.Request(verb: verb, instruction: instruction, url: url, relativePath: path, lines: lines, diagnostic: nil))
        }
        controller.onContinueInThink = { [weak self] in
            self?.reviewInstructPopover?.close()
            self?.show(.think)
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        reviewInstructPopover = popover
        reviewInstructController = controller
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }

    private func endInstruct() {
        if let instruct { instruct.runner.removeObserver(instruct.token) }
        instruct = nil
        instructTurnStarted = false
    }

    // MARK: - Checkpoint sheet (Direction 02 §5.1)

    private var checkpointSheet: NSWindow?

    /// A checkpoint's files and diff over Think, from its transcript line — no stage change.
    private func presentCheckpointSheet(_ id: UUID) {
        guard checkpointSheet == nil, let window = view.window, let store = projectContext?.sessionStore else { return }
        let all = store.checkpoints(forTrackKey: currentTrackKey ?? "")
        guard let checkpoint = all.first(where: { $0.id == id }) else { return }
        let controller = CheckpointSheetController(checkpoint: checkpoint, checkpoints: all, worktreePath: workingDirectoryURL(for: currentTrackKey).path)
        controller.onClose = { [weak self] in self?.dismissCheckpointSheet() }
        controller.onOpenInReview = { [weak self] in
            self?.dismissCheckpointSheet()
            self?.show(.review)
        }
        let sheet = DismissableSheetWindow(contentViewController: controller)
        sheet.styleMask = [.titled, .resizable]
        sheet.onCancel = { [weak self] in self?.dismissCheckpointSheet() }
        sheet.setContentSize(NSSize(width: min(820, window.frame.width - 80), height: min(600, window.frame.height - 80)))
        checkpointSheet = sheet
        window.beginSheet(sheet)
    }

    private func dismissCheckpointSheet() {
        guard let sheet = checkpointSheet else { return }
        checkpointSheet = nil
        view.window?.endSheet(sheet)
    }

    // MARK: - Run's task row

    /// The project's tasks for the current track's working copy — detection reads a few files,
    /// so it runs off-main and is cached until the track or project changes.
    private var projectTasks: [ProjectTask] = []
    private var projectTasksRoot: URL?

    private func reloadProjectTasks() {
        guard projectURL != nil else { projectTasks = []; projectTasksRoot = nil; refreshRunTasks(); return }
        let root = workingDirectoryURL(for: currentTrackKey)
        guard root != projectTasksRoot else { refreshRunTasks(); return }
        projectTasksRoot = root
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let tasks = ProjectTasks.tasks(projectRoot: root)
            DispatchQueue.main.async {
                guard let self, self.projectTasksRoot == root else { return }
                self.projectTasks = tasks
                self.refreshRunTasks()
            }
        }
    }

    /// Task chips, the Verify chip when the newest checkpoint is unverified, the running task,
    /// and a pending Run / Cancel — all read without creating a runner.
    /// A typed command's result, held until the user attaches or dismisses it (§5.2).
    private var pendingAttach: CheckpointVerification?

    /// Offered only while the newest checkpoint has no verification — the gap this path fills.
    private func offerAttach(command: String, exitCode: Int, screen: String) {
        let newest = projectContext?.sessionStore.checkpoints(forTrackKey: currentTrackKey ?? "").max { $0.createdAt < $1.createdAt }
        guard let newest, newest.verification == nil else { return }
        let name = command.count > 48 ? String(command.prefix(47)) + "\u{2026}" : command
        // Redacted like every verification excerpt that reaches checkpoints.json.
        pendingAttach = CheckpointVerification(taskName: name, command: command, exitCode: exitCode, output: SecretRedactor.redacted(screen))
        refreshRunTasks()
    }

    private func refreshRunTasks() {
        var state = RunWorkspaceViewController.TaskRowState()
        guard projectURL != nil else { runVC.setTaskRow(state); return }
        state.tasks = projectTasks
        if let attach = pendingAttach { state.attachOffer = .init(command: attach.command, exitCode: attach.exitCode ?? -1) }
        let runner = currentRunner
        state.runningTaskName = runner?.runningUserTaskName
        if let id = runner?.pendingUserTaskProposalId,
           let entry = runner?.entries.first(where: { $0.id == id }), case .commandProposal(let presentation) = entry.kind {
            state.pendingCommand = presentation.command.command
        }
        let verification = projectTasks.first { $0.isVerification } ?? projectTasks.first { $0.name == "test" }
        let newest = projectContext?.sessionStore.checkpoints(forTrackKey: currentTrackKey ?? "").max { $0.createdAt < $1.createdAt }
        if let verification, let newest, newest.verification == nil { state.verifyTask = verification }
        runVC.setTaskRow(state)
    }

    private func runnerActivityChanged() {
        refreshRunTasks()
        let currentNeedsYou = needsYouTrackIDs()
        let newlyNeedsYou = currentNeedsYou.subtracting(lastKnownNeedsYouTrackIDs)
        lastKnownNeedsYouTrackIDs = currentNeedsYou
        AppDelegate.shared?.refreshDockBadge()
        reportAttention()

        guard !newlyNeedsYou.isEmpty else { return }
        let tracks = (trackStore?.tracks ?? []).filter { newlyNeedsYou.contains($0.id) }
        // The live-region equivalent: a VoiceOver user working in Make got no audible signal when
        // a track flipped to needs-you — the state rode entirely in a glyph on a segment they
        // weren't focused on. Announced once per transition, alongside the badge and the
        // notification, so every "reach the user" channel fires from the same predicate.
        if let window = view.window {
            let names = tracks.map { $0.intent.isEmpty ? $0.branchName : $0.intent }
            let announcement = names.count == 1
                ? "\(names[0]) needs your attention"
                : "\(names.count) tracks need your attention"
            NSAccessibility.post(
                element: window, notification: .announcementRequested,
                userInfo: [.announcement: announcement, .priority: NSAccessibilityPriorityLevel.high.rawValue]
            )
        }
    }

    /// What `AttentionCenter` diffs: every track of this window's project and its agent's state.
    private func reportAttention() {
        guard let projectURL, let trackStore, let runnerManager = projectContext?.runnerManager else { return }
        var tracks = trackStore.tracks.map { track in
            AttentionCenter.TrackActivity(trackKey: track.branchName, title: track.intent.isEmpty ? track.branchName : track.intent,
                                          activity: runnerManager.existingRunner(forTrackKey: track.branchName)?.activity ?? .none)
        }
        // Think on the base branch, with no track, runs under the empty key.
        if let base = runnerManager.existingRunner(forTrackKey: "") {
            tracks.append(AttentionCenter.TrackActivity(trackKey: "", title: trackStore.defaultBranchName(), activity: base.activity))
        }
        AttentionCenter.shared.report(projectRoot: projectURL, tracks)
    }

    /// Already looking: this window is key *and* showing the track's agent. The Tracks stage
    /// surfaces every needs-you track in its pinned section, so being on it at all counts; Think
    /// only counts for the one track it's attached to. A non-key window (app in the background,
    /// another window in front) is never looking, however visible its stage is.
    func isOnProject(_ root: URL) -> Bool { projectURL?.standardizedFileURL == root.standardizedFileURL }
    var currentTrackKeyForAttention: String? { currentTrackKey }

    /// A banner clicked: this window comes forward on that track's Think, where an approval or a
    /// question waits.
    func revealAgent(of trackKey: String) {
        view.window?.makeKeyAndOrderFront(nil)
        guard trackKey != (currentTrackKey ?? "") else { show(.think); return }
        if trackKey.isEmpty { switchToBase(landOn: .think); return }
        guard let track = trackStore?.tracks.first(where: { $0.branchName == trackKey }) else { show(.think); return }
        switchToTrack(track, landOn: .think, completion: { _ in })
    }

    func isShowingAgent(of trackKey: String, in root: URL) -> Bool {
        view.window?.isKeyWindow == true && projectURL?.standardizedFileURL == root.standardizedFileURL
            && (current == .tracks || (current == .think && trackKey == (currentTrackKey ?? "")))
    }

    // MARK: - Window chrome (title, git info)

    /// A track's own linked worktree if it has one, else the shared project root — the same
    /// resolution `ProjectContext.workingDirectory(forTrackKey:)` does for Heron, just needed
    /// here too since Make/Run are pushed-to rather than pull-based.
    /// The cwd for a *new* Run session.
    ///
    /// The home-directory fallback is deliberate but was silently reachable with no project
    /// open at all — ⌃4 spawned a shell in the user's home directory with nothing saying so,
    /// which is a surprising place to find yourself typing `rm`. Run now refuses to open a
    /// session without a project (see `activateActiveSession`), so this fallback only covers
    /// the genuinely-odd case of a project whose directory vanished mid-session.
    private func workingDirectoryURL(for trackKey: String?) -> URL {
        projectContext?.workingDirectory(forTrackKey: trackKey ?? "") ?? projectURL ?? URL(fileURLWithPath: NSHomeDirectory())
    }

    private func projectOpened(_ url: URL) {
        // Opening a different project (or reopening after this window already had one) drops
        // this window's claim on whatever it held before — without this, the old project's
        // context would never hit zero refcount and would leak for the life of the app.
        if let previousURL = projectURL, let previousContext = projectContext {
            previousContext.trackStore.removeChangeObserver(trackStoreObserverToken)
            previousContext.runnerManager.removeChangeObserver(runnerChangeObserverToken)
            previousContext.unregisterBridgeHost(self)
            ProjectContextRegistry.shared.release(projectRoot: previousURL)
        }
        projectURL = url
        LaunchSignposts.begin("acquireContext")
        let context = ProjectContextRegistry.shared.acquire(projectRoot: url)
        LaunchSignposts.end("acquireContext")
        projectContext = context
        context.registerBridgeHost(self)
        let store = context.trackStore
        // TrackStore's init resolves activeTrack/untrackedBranch synchronously specifically so
        // this can be set before Make's own (already in-flight) project-open indexing reads it —
        // otherwise the very first file restore after opening a project on an active track's
        // branch would read the shared per-project bucket instead of that track's own memory.
        currentTrackKey = store.activeTrack?.branchName
        defer { sweepSetAsideTracks() }
        let workingDirectory = workingDirectoryURL(for: currentTrackKey)
        focusedRoot = workingDirectory
        // Only bother retargeting Make/Run's LSP/indexing/terminal-cwd machinery when the active
        // track actually has its own worktree — the common case (no active track yet, or one
        // that predates Phase C) needs nothing more than the plain track-key assignment Make's
        // own `loadProject` already set up.
        if workingDirectory == url {
            makeVC.currentTrackKey = currentTrackKey
            runVC.currentTrackKey = currentTrackKey
        } else {
            makeVC.reloadForTrackSwitch(trackKey: currentTrackKey, workingDirectory: workingDirectory)
            runVC.reloadForTrackSwitch(trackKey: currentTrackKey)
        }
        runVC.attach(to: context.terminals)
        // A debugged program's terminal (SIDE_RFC_DEBUGGER.md, step 2): a Run tab whose pty the
        // program reads and writes. The tab's own process only holds the pty open.
        makeVC.debugger.openProgramTerminal = { [weak self, weak context] title, directory in
            guard let self, let terminals = context?.terminals else { return nil }
            let launch = TerminalViewController.CommandLaunch(command: "sleep", arguments: ["2147483647"], environment: [:])
            let session = terminals.makeCommandSession(forTrackKey: self.currentTrackKey ?? "", launch: launch, directory: directory, label: "Debug: \(title)")
            session.viewController.start()
            // The tab Run shows: the program may be waiting for input there.
            let key = self.currentTrackKey ?? ""
            if let index = terminals.sessions(forTrackKey: key).firstIndex(where: { $0 === session }) {
                terminals.setActiveIndex(index, forTrackKey: key)
            }
            let fd = session.viewController.terminalView.process.childfd
            guard fd >= 0, let name = ptsname(fd) else {
                terminals.removeSession(session)
                return nil
            }
            return DebugProgramTerminal(
                tty: String(cString: name),
                end: { [weak session] in session?.viewController.stopProcess() },
                close: { [weak terminals, weak session] in if let session { terminals?.removeSession(session) } }
            )
        }
        // An adapter's `runInTerminal` (debugpy, js-debug): the program itself runs in the tab.
        makeVC.debugger.openCommandTerminal = { [weak self, weak context] arguments, directory, environment, title in
            guard let self, let terminals = context?.terminals, let command = arguments.first else { return nil }
            let launch = TerminalViewController.CommandLaunch(command: command, arguments: Array(arguments.dropFirst()), environment: environment)
            let key = self.currentTrackKey ?? ""
            let session = terminals.makeCommandSession(forTrackKey: key, launch: launch, directory: directory, label: "Debug: \(title)")
            session.viewController.start()
            if let index = terminals.sessions(forTrackKey: key).firstIndex(where: { $0 === session }) { terminals.setActiveIndex(index, forTrackKey: key) }
            let pid = session.viewController.terminalView.process.shellPid
            guard pid > 0 else {
                terminals.removeSession(session)
                return nil
            }
            // The program ends itself; the tab stays with what it wrote until the next session.
            return (pid, DebugProgramTerminal(tty: "", end: {}, close: { [weak terminals, weak session] in if let session { terminals?.removeSession(session) } }))
        }
        reloadProjectTasks()
        thinkVC.onRevealFileRequested = { [weak self] url in self?.revealFile(url) }
        thinkVC.onRevealFileAtLineRequested = { [weak self] url, line in
            self?.show(.make)
            self?.makeVC.revealFile(url, line: line)
        }
        thinkVC.onOpenReviewRequested = { [weak self] in self?.show(.review) }
        thinkVC.onOpenRunRequested = { [weak self] in self?.show(.run) }
        thinkVC.onOpenCheckpointRequested = { [weak self] id in self?.presentCheckpointSheet(id) }
        LaunchSignposts.begin("thinkConfigure")
        thinkVC.coordinator = context.coordinator
        thinkVC.configure(runnerManager: context.runnerManager, trackStore: context.trackStore, projectPath: context.projectRoot.path, trackKey: currentTrackKey)
        LaunchSignposts.end("thinkConfigure")
        LaunchSignposts.begin("reviewConfigure")
        reviewVC.configure(trackStore: store, sessionStore: context.sessionStore, canonicalRoot: url)
        reviewVC.reloadForTrackSwitch(trackKey: currentTrackKey, workingDirectory: workingDirectory)
        LaunchSignposts.end("reviewConfigure")
        // Registered rather than assigned: `store` may already be shared with another window
        // (same project, two windows), and a plain single-assignment `onChange` would let this
        // window's registration silently replace that other window's.
        trackStoreObserverToken = store.addChangeObserver { [weak self] in
            guard let self else { return }
            self.tracksVC.refresh()
            // Deliberately does *not* reassign `makeVC.currentTrackKey` here — this fires on
            // *any* change to the shared store, including one driven by a different window on
            // the same project. `currentTrackKey` is this window's own authoritative field
            // (set only by `projectOpened`/`switchToTrack`/`branchIsNowActive`, all explicit
            // actions taken *in this window*); overwriting it with `store.activeTrack` here used
            // to silently snap every window back to whichever track was globally active,
            // defeating "Open Track in New Window" (and any other case of two windows
            // deliberately looking at two different tracks) the moment either one changed.
            self.applyWindowChrome()
            self.syncHarnesses()
        }
        // Same multicast reasoning as the TrackStore observer above — `context.runnerManager`
        // is shared across every window on this project, so this can't be a single-assignment
        // closure without the same clobbering bug A1 fixed for tracks.
        runnerChangeObserverToken = context.runnerManager.addChangeObserver { [weak self] in
            guard let self else { return }
            self.tracksVC.refresh()
            self.updateStageLabels()
            self.runnerActivityChanged()
        }
        tracksVC.configure(with: store, runnerManager: context.runnerManager, sessionStore: context.sessionStore)
        applyWindowChrome()
        refreshGitInfo(for: workingDirectory)
        refreshFirstRunIfShown()
    }

    /// Switching to a track with its own worktree is instant bookkeeping — no checkout, so no
    /// unsaved-changes risk from *that* alone — but this still goes through the same
    /// unsaved-changes guard tab-closing uses, because Make's own tabs are about to be closed
    /// and reopened against the new track's files regardless of how the switch itself happened.
    private func switchToTrack(_ track: Track, landOn: Stage = .make, completion: @escaping (TrackSwitchOutcome?) -> Void) {
        confirmCloseAllUnsaved { [weak self] proceed in
            guard let self, proceed, let store = self.trackStore else { completion(nil); return }
            store.switchTo(track) { [weak self] result in
                guard let self else { completion(nil); return }
                switch result {
                case .success(let outcome):
                    // Read fresh from the store, not the `track` value captured above — `switchTo`
                    // may have just materialized a worktree and updated `workingDirectoryPath` on
                    // its own copy, which this closure's `track` snapshot predates.
                    let workingDirectory = self.workingDirectoryURL(for: track.branchName)
                    self.focusedRoot = workingDirectory
                    self.refreshGitInfo(for: workingDirectory)
                    self.currentTrackKey = track.branchName
                    self.sweepSetAsideTracks()
                    self.makeVC.reloadForTrackSwitch(trackKey: track.branchName, workingDirectory: workingDirectory)
                    self.runVC.reloadForTrackSwitch(trackKey: track.branchName)
                    self.reloadProjectTasks()
                    self.thinkVC.reloadForTrackSwitch(trackKey: track.branchName)
                    self.reviewVC.reloadForTrackSwitch(trackKey: track.branchName, workingDirectory: workingDirectory)
                    self.show(landOn)
                    completion(outcome)
                case .failure(let error):
                    if let window = self.view.window {
                        let alert = NSAlert()
                        alert.alertStyle = .warning
                        alert.messageText = "Couldn't switch tracks"
                        alert.informativeText = error.localizedDescription
                        alert.addButton(withTitle: "OK")
                        alert.beginSheetModal(for: window)
                    }
                    completion(nil)
                }
            }
        }
    }

    /// The file explorer belongs to Make: from another stage, Make comes forward with it open.
    func toggleFileExplorer() {
        guard current == .make else {
            show(.make)
            makeVC.showFileExplorer()
            return
        }
        makeVC.toggleFileExplorer()
    }

    /// Working on the base branch itself, in the main checkout, with no track (the base row in
    /// Tracks and the switcher). The same guard as a track switch: Make's tabs reopen there.
    func switchToBase(landOn: Stage = .make) {
        guard currentTrackKey != nil else { show(landOn); return }
        confirmCloseAllUnsaved { [weak self] proceed in
            guard let self, proceed, let store = self.trackStore else { return }
            store.switchToBase()
            let workingDirectory = self.workingDirectoryURL(for: nil)
            self.focusedRoot = workingDirectory
            self.refreshGitInfo(for: workingDirectory)
            self.currentTrackKey = nil
            self.makeVC.reloadForTrackSwitch(trackKey: nil, workingDirectory: workingDirectory)
            self.runVC.reloadForTrackSwitch(trackKey: nil)
            self.reloadProjectTasks()
            self.thinkVC.reloadForTrackSwitch(trackKey: nil)
            self.reviewVC.reloadForTrackSwitch(trackKey: nil, workingDirectory: workingDirectory)
            self.show(landOn)
        }
    }

    /// The tracks a cleanup mustn't touch: the one any window shows (its files are open in Make,
    /// its terminals run in its folder), and any whose agent is working or waiting on you.
    func tracksInUse() -> Set<String> {
        var keys = Set(NSApp.windows.compactMap { ($0.contentViewController as? ShellViewController)?.currentTrackKey })
        if let currentTrackKey { keys.insert(currentTrackKey) }
        if let store = trackStore, let manager = projectContext?.runnerManager {
            for track in store.tracks {
                guard let runner = manager.existingRunner(forTrackKey: track.branchName) else { continue }
                if runner.phase.isBusy || runner.phase == .awaitingApproval { keys.insert(track.branchName) }
            }
        }
        return keys
    }

    /// Promoted and archived tracks' folders go, and a promoted track's merged branch, once no
    /// window is on them: when a project opens and when a window moves to another track.
    private func sweepSetAsideTracks() {
        trackStore?.cleanUp(.setAside, sparing: tracksInUse()) { [weak self] report in
            DispatchQueue.main.async { self?.tracksVC.announce(cleanup: report) }
        }
    }

    /// A brand-new track (or a newly-adopted existing branch — same shape, no `Track` object
    /// needed here since only the branch name matters) is checked out as part of creating/adopting
    /// it, not a separate step — so there's no second checkout to wait on here, just reflecting
    /// what already happened: refresh git info, reload Make/Run onto this branch's own remembered
    /// state, and land on Make so there's somewhere to actually start working.
    private func branchIsNowActive(_ branchName: String) {
        let workingDirectory = workingDirectoryURL(for: branchName)
        focusedRoot = workingDirectory
        refreshGitInfo(for: workingDirectory)
        currentTrackKey = branchName
        sweepSetAsideTracks()
        makeVC.reloadForTrackSwitch(trackKey: branchName, workingDirectory: workingDirectory)
        runVC.reloadForTrackSwitch(trackKey: branchName)
        reloadProjectTasks()
        thinkVC.reloadForTrackSwitch(trackKey: branchName)
        reviewVC.reloadForTrackSwitch(trackKey: branchName, workingDirectory: workingDirectory)
        show(.make)
        refreshFirstRunIfShown()
    }

    /// `url` is non-nil for an actual file open — from anywhere reachable regardless of stage
    /// (the toolbar's Quick Open field, the file explorer), not just from Make itself. Without
    /// jumping to Make here, opening a file while looking at Run or Tracks would silently update
    /// this window's title/represented-file and nothing else, since there's no visible editor to
    /// show it in — same fix Run's own "open file from a terminal link" feature already needed
    /// and had to do by hand; this makes it automatic for every path instead of one at a time.
    /// `nil` means a close (e.g. the last tab), which shouldn't yank you onto Make from wherever
    /// you are.
    private func fileOpened(_ url: URL?) {
        currentFileURL = url
        isDirty = false
        applyWindowChrome()
        if url != nil { show(.make) }
    }

    /// Direction 02 §3.7: Make `file — track`, other stages `track`; never a path. Drawn nowhere,
    /// but Mission Control, the Window menu, ⌘` and VoiceOver read it.
    static func windowTitle(stage: Stage?, fileName: String?, track: String?, project: String?) -> String {
        let place = track ?? project ?? "Side"
        if stage == .make, let fileName { return "\(fileName) · \(place)" }
        return place
    }

    private func applyWindowChrome() {
        trackPill.refresh()
        guard let window = view.window else { return }
        let track = trackStore?.tracks.first { $0.branchName == currentTrackKey }
        let title = Self.windowTitle(stage: current, fileName: currentFileURL?.lastPathComponent,
                                     track: track.map { $0.intent.isEmpty ? $0.branchName : $0.intent }, project: projectURL?.lastPathComponent)
        // Each of these makes AppKit lay out the title bar again, lights included; the lights
        // were put back on the next turn of the run loop, a frame late, so switching files made
        // them jump. Only what changed is set, and the lights go back in the same pass.
        var changed = false
        if window.representedURL != currentFileURL { window.representedURL = currentFileURL; changed = true }
        if window.isDocumentEdited != isDirty { window.isDocumentEdited = isDirty; changed = true }
        if window.title != title { window.title = title; changed = true }
        if changed {
            window.standardWindowButton(.closeButton)?.superview?.layoutSubtreeIfNeeded()
            chrome.positionTrafficLights(in: window)
        }
    }

    /// A project-relative path for the pill's header, never an absolute one. The old naive
    /// projectURL-prefix strip silently failed for any file living in a track's *worktree*
    /// (whose root isn't the project folder), leaking the full
    /// `…/Application Support/Side/Worktrees/…` path into the window chrome. Tries the project
    /// root, then the worktrees root (skipping the per-track directory segment), then falls
    /// back to the file's last two path components — always something a person would say.
    private func humanePath(for fileURL: URL, projectURL: URL) -> String {
        let filePath = fileURL.path
        if filePath.hasPrefix(projectURL.path + "/") {
            return String(filePath.dropFirst(projectURL.path.count + 1))
        }
        if let worktreesRoot = cachedWorktreesRootPath,
           filePath.hasPrefix(worktreesRoot + "/") {
            let insideWorktrees = filePath.dropFirst(worktreesRoot.count + 1)
            if let slash = insideWorktrees.firstIndex(of: "/") {
                return String(insideWorktrees[insideWorktrees.index(after: slash)...])
            }
        }
        return fileURL.pathComponents.suffix(2).joined(separator: "/")
    }

    /// The project's worktrees root, resolved once per project on the git background queue —
    /// never synchronously in `applyWindowChrome`, which runs on the main thread on every title
    /// update. The original version shelled out to git from there on each call, and a tear-out
    /// (two windows both rebuilding chrome at once) turned that into a burst of main-thread
    /// `Process` spawns that crashed inside Foundation.
    private var cachedWorktreesRootPath: String?

    private func refreshGitInfo(for project: URL) {
        // The worktrees root must be derived from the canonical project, not `project` (which
        // is this window's focused root and may itself be a worktree).
        let canonicalProject = projectURL
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // `symbolic-ref`, not `rev-parse --abbrev-ref HEAD`: the latter's output is
            // inconsistent on a zero-commit repo (can print a bare "HEAD" the same way real
            // detached HEAD does). `nil` here just means detached, which the pill omits
            // rather than showing a misleading branch name for.
            let branch = Self.runGit(["symbolic-ref", "--quiet", "--short", "HEAD"], in: project.path)
            let status = Self.runGit(["--no-optional-locks", "status", "--porcelain"], in: project.path)
            let dirtyCount = status?.split(separator: "\n").count ?? 0
            let worktreesRoot = canonicalProject.flatMap { GitPaths.worktreesRootDirectory(for: $0)?.path }
            DispatchQueue.main.async {
                guard let self, self.focusedRoot == project else { return }
                self.gitBranch = (branch?.isEmpty == false) ? branch : nil
                self.gitDirtyCount = dirtyCount
                self.cachedWorktreesRootPath = worktreesRoot
                self.applyWindowChrome()
            }
        }
    }

    nonisolated private static func runGit(_ args: [String], in directory: String) -> String? {
        guard DeveloperTools.gitInstalled else { return nil }
        let process = Process()
        process.environment = SpawnEnvironment.current()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", directory] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // Read before waiting — waiting first deadlocks once git fills the pipe buffer
        // (see GitPaths.runGit).
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - WorkspaceBridgeHost

/// Lets `AgentRunner`s reach into whichever window is actually showing the track they belong
/// to — see `ProjectContext.bridge(forTrackKey:)`. Deliberately not exposing `NSWindow` itself
/// to `ProjectContext`: it only ever needs a yes/no on "is this window key," not the window.
extension ShellViewController: WorkspaceBridgeHost {
    var bridgeTrackKey: String? { currentTrackKey }
    var isKeyWindow: Bool { view.window?.isKeyWindow == true }
    func liveBufferContent(for url: URL) -> String? { makeVC.unsavedContent(for: url) }
    func applyApprovedEdit(url: URL, newContent: String) -> Bool { makeVC.applyApprovedEdit(url: url, newContent: newContent) }
    // Approving an edit lands you in the file that changed — same reflex as Run's
    // open-file-from-terminal-link jump, just triggered from Think.
    func revealAfterApply(_ url: URL) {
        show(.make)
        makeVC.revealAfterApply(url)
    }
}

extension ShellViewController: NSMenuItemValidation {
    /// Zoom only where there's text to grow; everything else as it was.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(zoomIn(_:)), #selector(zoomOut(_:)), #selector(actualSize(_:)): zoomSurface != nil
        default: true
        }
    }
}
