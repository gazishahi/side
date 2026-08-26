import Foundation

/// Lightweight, always-resident stand-in for a session's `turns` — everything the ledger/Think
/// header needs to know about a track's conversation without paying for its full history.
private struct SessionIndexEntry: Codable {
    let id: UUID
    let trackKey: String
    var providerId: String
    var modelId: String
    var lastActiveAt: Date
}

/// Persists Think conversations *and* checkpoints per project. Checkpoints are cheap (no file
/// content, just metadata — see `Checkpoint.swift`) and stay eagerly loaded, same as before. A
/// session's `turns`, however, can hold arbitrarily large tool-result/assistant text (up to
/// `ToolExecutor.maxOutputCharacters` per tool result alone), and the old design loaded *every*
/// track's entire history for the whole project at init and never evicted any of it — the direct
/// cause of Think's memory footprint growing with total project history rather than with what's
/// actually being looked at. Now: only a lightweight index (this file) is eager; a track's full
/// `AgentSession` loads from its own file on first access and stays resident only for tracks
/// actually visited this run, not the whole project.
final class AgentSessionStore {
    private var index: [SessionIndexEntry] = []
    private var checkpoints: [Checkpoint] = []
    /// Full sessions loaded so far this run, keyed by track key — grows only with tracks this
    /// process has actually touched, never with the project's total track count.
    private var loadedSessions: [String: AgentSession] = [:]

    private let sessionsDirectory: URL
    private let indexURL: URL
    private let checkpointsURL: URL
    /// Where `think.json` (the old single-file format) used to live — read once for migration,
    /// then removed once its contents are safely split across the new files.
    private let legacyURL: URL

    init(stateDirectory: URL) {
        let thinkDirectory = stateDirectory.appendingPathComponent("think")
        self.sessionsDirectory = thinkDirectory.appendingPathComponent("sessions")
        self.indexURL = thinkDirectory.appendingPathComponent("index.json")
        self.checkpointsURL = thinkDirectory.appendingPathComponent("checkpoints.json")
        self.legacyURL = stateDirectory.appendingPathComponent("think.json")
        load()
    }

    func session(forTrackKey trackKey: String) -> AgentSession? {
        loadedSession(forTrackKey: trackKey)
    }

    /// Appends a turn to the track's session, creating the session on first use. Returns the
    /// updated session.
    @discardableResult
    func appendTurn(_ turn: AgentTurn, trackKey: String, providerId: String, modelId: String) -> AgentSession {
        var session = loadedSession(forTrackKey: trackKey) ?? AgentSession(trackKey: trackKey, providerId: providerId, modelId: modelId)
        session.turns.append(turn)
        session.providerId = providerId
        session.modelId = modelId
        session.lastActiveAt = Date()
        loadedSessions[trackKey] = session
        saveSession(session)
        if let indexPosition = index.firstIndex(where: { $0.trackKey == trackKey }) {
            index[indexPosition].providerId = providerId
            index[indexPosition].modelId = modelId
            index[indexPosition].lastActiveAt = session.lastActiveAt
        } else {
            index.append(SessionIndexEntry(id: session.id, trackKey: trackKey, providerId: providerId, modelId: modelId, lastActiveAt: session.lastActiveAt))
        }
        saveIndex()
        return session
    }

    func checkpoints(forTrackKey trackKey: String) -> [Checkpoint] {
        checkpoints.filter { $0.trackKey == trackKey }
    }

    func appendCheckpoint(_ checkpoint: Checkpoint) {
        checkpoints.append(checkpoint)
        saveCheckpoints()
    }

    /// Called when a track is deleted — its conversation and checkpoints have nowhere to belong
    /// anymore, same cleanup contract as Make's file memory and Run's terminal sessions.
    func removeSession(forTrackKey trackKey: String) {
        loadedSessions.removeValue(forKey: trackKey)
        index.removeAll { $0.trackKey == trackKey }
        checkpoints.removeAll { $0.trackKey == trackKey }
        try? FileManager.default.removeItem(at: sessionFileURL(forTrackKey: trackKey))
        saveIndex()
        saveCheckpoints()
    }

    // MARK: - Lazy session loading

    private func loadedSession(forTrackKey trackKey: String) -> AgentSession? {
        if let cached = loadedSessions[trackKey] { return cached }
        guard index.contains(where: { $0.trackKey == trackKey }),
              let data = try? Data(contentsOf: sessionFileURL(forTrackKey: trackKey)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var session = try? decoder.decode(AgentSession.self, from: data) else { return nil }
        // Repair before anything can read it — a session with a dangling tool_use is not just
        // cosmetically odd, it's unusable (see `Self.repairingDanglingToolUses`).
        if let repaired = Self.repairingDanglingToolUses(session) {
            session = repaired
            saveSession(session)
        }
        loadedSessions[trackKey] = session
        return session
    }

    /// Returns a repaired copy when the session contains `tool_use` blocks that no `tool_result`
    /// ever answers, or `nil` when nothing needed fixing.
    ///
    /// `AgentRunner.teardown()` writes synthetic rejections for pending proposals, but only on a
    /// *graceful* shutdown. Force-quit, a crash, or power loss between persisting the assistant's
    /// tool_use turn and persisting its results leaves the conversation permanently broken rather
    /// than merely incomplete: the full turn list is replayed to the provider on every send, and
    /// a tool_use with no matching tool_result is a protocol violation the API rejects outright —
    /// so every future message in that track fails. Repairing at load time (rather than only at
    /// teardown) is what makes recovery independent of *how* the process died, and also fixes
    /// sessions already on disk in that state.
    ///
    /// Synthesizing a rejection is the honest repair: nothing was applied, because approval never
    /// happened. The result is inserted immediately after the assistant turn that made the call,
    /// which is where the wire format requires it.
    static func repairingDanglingToolUses(_ session: AgentSession) -> AgentSession? {
        var answeredIds = Set<String>()
        for turn in session.turns {
            for block in turn.content {
                if case .toolResult(let toolUseId, _, _) = block { answeredIds.insert(toolUseId) }
            }
        }

        var repairedTurns: [AgentTurn] = []
        var didRepair = false
        for turn in session.turns {
            repairedTurns.append(turn)
            let unanswered = turn.content.compactMap { block -> String? in
                guard case .toolUse(let id, _, _) = block, !answeredIds.contains(id) else { return nil }
                return id
            }
            guard !unanswered.isEmpty else { continue }
            didRepair = true
            repairedTurns.append(AgentTurn(role: .user, content: unanswered.map {
                .toolResult(
                    toolUseId: $0,
                    content: "Side closed before the user decided, so this never ran and nothing changed. Ask again if it's still needed.",
                    isError: true
                )
            }))
            answeredIds.formUnion(unanswered)
        }
        guard didRepair else { return nil }
        var repaired = session
        repaired.turns = repairedTurns
        return repaired
    }

    /// Branch-name-shaped track keys can contain `/`; `""` means "no active track" — both need a
    /// safe, unique filename, same sanitization convention `GitPaths`/`TrackStore` already use
    /// for worktree directory names.
    private func sessionFileURL(forTrackKey trackKey: String) -> URL {
        let slug = trackKey.isEmpty ? "_none_" : trackKey.replacingOccurrences(of: "/", with: "-")
        return sessionsDirectory.appendingPathComponent("\(slug).json")
    }

    // MARK: - Persistence

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: indexURL), let decoded = try? decoder.decode([SessionIndexEntry].self, from: data) {
            index = decoded
            if let checkpointData = try? Data(contentsOf: checkpointsURL) {
                checkpoints = (try? decoder.decode([Checkpoint].self, from: checkpointData)) ?? []
            }
            return
        }
        migrateLegacyStateIfPresent()
    }

    /// One-time split of the old single `think.json` (every track's full history, eagerly
    /// loaded) into the new per-track-file layout. Runs at most once per project — `load()` only
    /// calls this when `index.json` doesn't exist yet, and this writes `index.json` as its last
    /// step, so a second launch never re-enters this path.
    private func migrateLegacyStateIfPresent() {
        guard let data = try? Data(contentsOf: legacyURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var legacySessions: [AgentSession] = []
        var legacyCheckpoints: [Checkpoint] = []
        if let decoded = try? decoder.decode(ThinkStateLegacy.self, from: data) {
            legacySessions = decoded.sessions
            legacyCheckpoints = decoded.checkpoints
        } else if let decoded = try? decoder.decode([AgentSession].self, from: data) {
            // Pre-checkpoint think.json was a bare `[AgentSession]` array.
            legacySessions = decoded
        } else {
            return
        }
        checkpoints = legacyCheckpoints
        index = legacySessions.map { SessionIndexEntry(id: $0.id, trackKey: $0.trackKey, providerId: $0.providerId, modelId: $0.modelId, lastActiveAt: $0.lastActiveAt) }
        for session in legacySessions { saveSession(session) }
        saveIndex()
        saveCheckpoints()
        try? FileManager.default.removeItem(at: legacyURL)
    }

    private func saveIndex() {
        try? FileManager.default.createDirectory(at: indexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(index) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    private func saveCheckpoints() {
        try? FileManager.default.createDirectory(at: checkpointsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(checkpoints) else { return }
        try? data.write(to: checkpointsURL, options: .atomic)
    }

    private func saveSession(_ session: AgentSession) {
        try? FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(session) else { return }
        try? data.write(to: sessionFileURL(forTrackKey: session.trackKey), options: .atomic)
    }
}

/// The old `think.json` shape — read only during one-time migration in `migrateLegacyStateIfPresent`.
private struct ThinkStateLegacy: Codable {
    var sessions: [AgentSession] = []
    var checkpoints: [Checkpoint] = []
}
