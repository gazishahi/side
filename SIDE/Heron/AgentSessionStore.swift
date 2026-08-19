import Foundation

/// The persisted shape of `think.json` — sessions and checkpoints combined into one file (no
/// evidence yet they need independent write cadences), same as `TrackStore`'s conventions.
private struct ThinkState: Codable {
    var sessions: [AgentSession] = []
    var checkpoints: [Checkpoint] = []
}

/// Persists Think conversations *and* checkpoints per project, mirroring TrackStore's shape
/// exactly: JSON at a resolved state directory (`GitPaths.stateDirectory`, effectively
/// `<common-git-dir>/side/`, never tracked by the project's own history), loaded eagerly at
/// init, saved on every mutation with errors swallowed.
final class AgentSessionStore {
    private var state = ThinkState()
    private let storeURL: URL

    init(stateDirectory: URL) {
        self.storeURL = stateDirectory.appendingPathComponent("think.json")
        load()
    }

    func session(forTrackKey trackKey: String) -> AgentSession? {
        state.sessions.first { $0.trackKey == trackKey }
    }

    /// Appends a turn to the track's session, creating the session on first use. Returns the
    /// updated session.
    @discardableResult
    func appendTurn(_ turn: AgentTurn, trackKey: String, providerId: String, modelId: String) -> AgentSession {
        var session = self.session(forTrackKey: trackKey) ?? AgentSession(trackKey: trackKey, providerId: providerId, modelId: modelId)
        session.turns.append(turn)
        session.providerId = providerId
        session.modelId = modelId
        session.lastActiveAt = Date()
        if let index = state.sessions.firstIndex(where: { $0.id == session.id }) {
            state.sessions[index] = session
        } else {
            state.sessions.append(session)
        }
        save()
        return session
    }

    func checkpoints(forTrackKey trackKey: String) -> [Checkpoint] {
        state.checkpoints.filter { $0.trackKey == trackKey }
    }

    func appendCheckpoint(_ checkpoint: Checkpoint) {
        state.checkpoints.append(checkpoint)
        save()
    }

    /// Called when a track is deleted — its conversation and checkpoints have nowhere to belong
    /// anymore, same cleanup contract as Make's file memory and Run's terminal sessions.
    func removeSession(forTrackKey trackKey: String) {
        state.sessions.removeAll { $0.trackKey == trackKey }
        state.checkpoints.removeAll { $0.trackKey == trackKey }
        save()
    }

    // MARK: - Persistence (TrackStore's conventions)

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode(ThinkState.self, from: data) {
            state = decoded
        } else if let legacySessions = try? decoder.decode([AgentSession].self, from: data) {
            // Pre-checkpoint think.json was a bare `[AgentSession]` array — decode that shape
            // too so existing conversations aren't dropped the first time this runs.
            state = ThinkState(sessions: legacySessions, checkpoints: [])
        }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(state) else { return }
        try? data.write(to: storeURL)
    }
}
