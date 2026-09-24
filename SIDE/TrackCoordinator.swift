import Foundation
import Heron

/// Multi-agent work for one project (`SIDE_RFC_MULTI_AGENT.md`, step 2): a coordinator track's
/// agent creates subtracks (stacked children, each on any agent), messages them, and reads
/// their results. Owned by `ProjectContext`, so it outlives any window.
///
/// Rules held here: a subtrack can't create subtracks (one level, M3); at most four live
/// subtracks per coordinator (M3); a coordinator can message only its own subtracks (M4); at
/// most four agents stream at once across the project (navigation RFC R3), with the rest's
/// messages queued until one finishes.
@MainActor
final class TrackCoordinator: TrackCoordinating {
    static let childLimit = 4
    static let concurrencyLimit = 4

    private let trackStore: TrackStore
    private weak var runnerManager: AgentRunnerManager?
    private let sessionStore: AgentSessionStore
    /// Messages waiting for a subtrack's turn to end, or for a free slot under the ceiling.
    private var queued: [String: [String]] = [:]
    private var changeToken: UUID?

    init(trackStore: TrackStore, runnerManager: AgentRunnerManager, sessionStore: AgentSessionStore) {
        self.trackStore = trackStore
        self.runnerManager = runnerManager
        self.sessionStore = sessionStore
        changeToken = runnerManager.addChangeObserver { [weak self] in self?.drainQueue() }
    }

    private func track(_ key: String) -> Track? { trackStore.tracks.first { $0.branchName == key } }

    private func liveChildren(of parent: Track) -> [Track] {
        trackStore.tracks.filter { $0.parentTrackId == parent.id && $0.spawnedByCoordinator && ![.completed, .archived].contains($0.status) }
    }

    /// The coordinator's own subtrack, or a sentence saying why `key` isn't one (M4).
    private func child(_ key: String, of parentKey: String) -> Result<Track, CoordinatorRefusal> {
        guard let parent = track(parentKey), let child = track(key) else { return .failure(.init(message: "There's no track called \u{201C}\(key)\u{201D}.")) }
        guard child.parentTrackId == parent.id, child.spawnedByCoordinator else {
            return .failure(.init(message: "\u{201C}\(key)\u{201D} isn't one of this track's subtracks. A coordinator works only with the subtracks it created."))
        }
        return .success(child)
    }

    struct CoordinatorRefusal: Error { let message: String }

    // MARK: TrackCoordinating

    func canCoordinate(trackKey: String) -> Bool {
        guard let track = track(trackKey) else { return false }
        return !track.spawnedByCoordinator
    }

    func spawnRefusal(parentKey: String) -> String? {
        guard let parent = track(parentKey) else { return "Subtracks need a track to belong to." }
        guard !parent.spawnedByCoordinator else { return "A subtrack can't create subtracks of its own. Tell the coordinator what else is needed instead." }
        let live = liveChildren(of: parent)
        guard live.count < Self.childLimit else {
            return "This track already has \(live.count) subtracks in progress (\(live.map(\.branchName).joined(separator: ", "))), the most it can have. Wait for one to finish, or ask the user to promote or archive one."
        }
        return nil
    }

    var agentChoices: [(id: String, name: String)] {
        [("heron", "Heron")] + ACPAgent.known.filter { AgentAvailability.isInstalled($0) != false }.map { ($0.id, $0.displayName) }
    }

    func createSubtrack(parentKey: String, request: SubtrackRequest, completion: @escaping (String) -> Void) {
        if let refusal = spawnRefusal(parentKey: parentKey) { return completion(refusal) }
        guard let parent = track(parentKey) else { return completion("Subtracks need a track to belong to.") }
        let agentName = request.agentId.flatMap { ACPAgent.agent(id: $0)?.displayName } ?? "Heron"
        // TrackStore calls back on the main thread; the box carries the main-actor closures there.
        let box = CompletionBox(coordinator: self, completion: completion)
        trackStore.createTrack(intent: request.intent, baseTrack: parent, spawnedByCoordinator: true) { result in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let completion = box.completion
                    guard let self = box.coordinator else { return completion("The project was closed.") }
                    switch result {
                    case .failure(let error):
                        completion("Couldn't create the subtrack: \(error.localizedDescription)")
                    case .success(let (child, _)):
                        if let agentId = request.agentId { self.trackStore.setHarness(agentId, forTrackKey: child.branchName) }
                        let first = "From the coordinator (\u{201C}\(parent.intent)\u{201D}):\n\n\(request.instructions)"
                        let delivery = self.deliver(first, to: child.branchName)
                        completion("Created subtrack \u{201C}\(child.branchName)\u{201D} on \(agentName), stacked under this track with its own working copy. \(delivery) Read it with read_track, or wait with wait_for_tracks, using \u{201C}\(child.branchName)\u{201D}.")
                    }
                }
            }
        }
    }

    func message(parentKey: String, trackKey: String, text: String) -> String {
        switch child(trackKey, of: parentKey) {
        case .failure(let refusal): return refusal.message
        case .success(let child): return deliver("From the coordinator:\n\n\(text)", to: child.branchName)
        }
    }

    func read(parentKey: String, trackKey: String) -> String {
        let child: Track
        switch self.child(trackKey, of: parentKey) {
        case .failure(let refusal): return refusal.message
        case .success(let found): child = found
        }
        let runner = runnerManager?.existingRunner(forTrackKey: child.branchName)
        let agent = ACPAgent.agent(id: child.harnessId)?.displayName ?? "Heron"
        var lines = ["\(child.branchName) \u{00B7} \(child.intent) \u{00B7} \(agent) \u{00B7} \(Self.state(of: runner, queued: queued[child.branchName]?.count ?? 0))"]
        if let reply = runner?.entries.last(where: { if case .assistantText = $0.kind { return true } else { return false } }),
           case .assistantText(let text) = reply.kind {
            lines.append("Last reply:\n" + (text.count > 2_000 ? String(text.suffix(2_000)) : text))
        }
        let checkpoints = sessionStore.checkpoints(forTrackKey: child.branchName).sorted { $0.createdAt < $1.createdAt }
        if checkpoints.isEmpty {
            lines.append("No checkpoints yet.")
        } else {
            lines.append("Checkpoints:")
            for checkpoint in checkpoints {
                let sha = checkpoint.gitCommitSHA.map { String($0.prefix(7)) } ?? "no commit"
                let verified = checkpoint.verification.map { $0.passed ? "verified: \($0.taskName) passed" : "FAILED: \($0.taskName) exit \($0.exitCode.map(String.init) ?? "unknown")" } ?? "unverified"
                lines.append("- \(checkpoint.declaredIntent) (\(sha), \(checkpoint.changedFilePaths.count) files, \(verified))")
            }
        }
        return lines.joined(separator: "\n")
    }

    func isSettled(parentKey: String, trackKey: String) -> Bool {
        guard case .success(let child) = self.child(trackKey, of: parentKey) else { return true }
        if !(queued[child.branchName] ?? []).isEmpty { return false }
        guard let runner = runnerManager?.existingRunner(forTrackKey: child.branchName) else { return true }
        return runner.phase != .streaming && runner.phase != .runningTools
    }

    // MARK: Promotion (M2)

    func promotionFacts(parentKey: String, trackKey: String) -> Result<PromotionFacts, CoordinationError> {
        switch child(trackKey, of: parentKey) {
        case .failure(let refusal): return .failure(CoordinationError(message: refusal.message))
        case .success(let child):
            guard let parent = track(parentKey) else { return .failure(CoordinationError(message: "The coordinator's track is gone.")) }
            let checkpoints = sessionStore.checkpoints(forTrackKey: child.branchName).sorted { $0.createdAt < $1.createdAt }
            let siblings = liveChildren(of: parent).filter { $0.id != child.id }.map(\.branchName)
            return .success(PromotionFacts(
                intent: child.intent, branch: child.branchName, parentBranch: parent.branchName,
                gitDirectory: trackStore.projectRoot.path, siblingBranches: siblings,
                newestCheckpointVerified: checkpoints.last?.verification?.passed == true, hasCheckpoints: !checkpoints.isEmpty))
        }
    }

    /// Merges the subtrack into the coordinator's own working copy, the same merge Review's
    /// Promote does into a stacked track's parent.
    func promote(parentKey: String, trackKey: String, completion: @escaping (String) -> Void) {
        guard case .success(let child) = self.child(trackKey, of: parentKey), let parent = track(parentKey) else {
            return completion("\u{201C}\(trackKey)\u{201D} isn't one of this track's subtracks.")
        }
        guard let parentPath = parent.workingDirectoryPath else { return completion("This track has no working copy to promote into.") }
        let box = CompletionBox(coordinator: self, completion: completion)
        let (branch, base, intent) = (child.branchName, parent.branchName, child.intent)
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = ReviewWorkspaceViewController.performMerge(branchName: branch, baseRef: base, intent: intent, cwd: parentPath)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self = box.coordinator else { return box.completion("The project was closed.") }
                    if outcome.succeeded, let current = self.track(branch) { self.trackStore.setStatus(.completed, for: current) }
                    let message = outcome.message.replacingOccurrences(of: "\u{26A0}\u{FE0E} ", with: "")
                        .replacingOccurrences(of: "Your main working copy", with: "This track's working copy")
                    box.completion(outcome.succeeded
                        ? "Promoted \u{201C}\(intent)\u{201D} into this track. \(message)"
                        : "Not promoted: \(message)")
                }
            }
        }
    }

    // MARK: For the UI

    /// A coordinator's subtracks, oldest first, including finished ones.
    func subtracks(of trackKey: String) -> [Track] {
        guard let parent = track(trackKey) else { return [] }
        return trackStore.tracks.filter { $0.parentTrackId == parent.id && $0.spawnedByCoordinator && $0.status != .archived }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// One subtrack's state in a few words, for Think's strip.
    func stateText(of trackKey: String) -> (text: String, activity: AgentActivity) {
        let runner = runnerManager?.existingRunner(forTrackKey: trackKey)
        let activity = runner?.activity ?? .none
        if track(trackKey)?.status == .completed { return ("promoted", activity) }
        return (Self.state(of: runner, queued: queued[trackKey]?.count ?? 0), activity)
    }

    // MARK: Delivery and the ceiling

    private static func state(of runner: (any Harness)?, queued: Int) -> String {
        if queued > 0 { return "queued (\(queued) message\(queued == 1 ? "" : "s") waiting to be delivered)" }
        guard let runner else { return "not started" }
        switch runner.phase {
        case .streaming, .runningTools: return "working"
        case .awaitingApproval: return "waiting on the user to approve something"
        case .blocked(let reason): return "stopped (\(reason))"
        case .finishedTurn: return "finished its turn"
        case .idle: return runner.entries.isEmpty ? "not started" : "idle"
        }
    }

    private var busyCount: Int {
        guard let runnerManager else { return 0 }
        return trackStore.tracks.compactMap { runnerManager.existingRunner(forTrackKey: $0.branchName) }.filter(\.phase.isBusy).count
    }

    /// Sends now if the subtrack is free and a slot is open; otherwise queues. Says which.
    @discardableResult
    private func deliver(_ text: String, to trackKey: String) -> String {
        guard let runnerManager else { return "The project was closed." }
        let runner = runnerManager.runner(forTrackKey: trackKey)
        if (queued[trackKey] ?? []).isEmpty, !runner.phase.isBusy, runner.phase != .awaitingApproval, busyCount < Self.concurrencyLimit {
            runner.send(text)
            return "It has started."
        }
        queued[trackKey, default: []].append(text)
        return runner.phase.isBusy || runner.phase == .awaitingApproval
            ? "It's mid-turn, so the message waits until that turn ends."
            : "\(Self.concurrencyLimit) agents are already working in this project, so it starts when one finishes."
    }

    private func drainQueue() {
        guard let runnerManager else { return }
        for key in queued.keys.sorted() {
            guard var messages = queued[key], !messages.isEmpty else { queued.removeValue(forKey: key); continue }
            let runner = runnerManager.runner(forTrackKey: key)
            guard !runner.phase.isBusy, runner.phase != .awaitingApproval, busyCount < Self.concurrencyLimit else { continue }
            runner.send(messages.removeFirst())
            queued[key] = messages.isEmpty ? nil : messages
        }
    }
}

private final class CompletionBox: @unchecked Sendable {
    weak var coordinator: TrackCoordinator?
    let completion: (String) -> Void
    init(coordinator: TrackCoordinator, completion: @escaping (String) -> Void) {
        self.coordinator = coordinator
        self.completion = completion
    }
}
