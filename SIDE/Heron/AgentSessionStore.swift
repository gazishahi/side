import Foundation

/// Lightweight, always-resident stand-in for a session's `turns` — everything the ledger/Think
/// header needs to know about a track's conversation without paying for its full history.
private struct SessionIndexEntry: Codable {
    let id: UUID
    let trackKey: String
    var providerId: String
    var modelId: String
    var lastActiveAt: Date
    /// Lives here rather than in the log's header for the same reason provider/model do: the
    /// header is written once, at creation, which is precisely what lets an append write only
    /// the new turn — while this changes on every request. The index is small and already
    /// rewritten per turn.
    var lastReportedInputTokens: Int?

    private enum CodingKeys: String, CodingKey {
        case id, trackKey, providerId, modelId, lastActiveAt, lastReportedInputTokens
    }

    init(id: UUID, trackKey: String, providerId: String, modelId: String, lastActiveAt: Date, lastReportedInputTokens: Int? = nil) {
        self.id = id
        self.trackKey = trackKey
        self.providerId = providerId
        self.modelId = modelId
        self.lastActiveAt = lastActiveAt
        self.lastReportedInputTokens = lastReportedInputTokens
    }

    // Tolerant, like every other persisted struct here: an index written before this field
    // existed must still load.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        trackKey = try container.decode(String.self, forKey: .trackKey)
        providerId = try container.decodeIfPresent(String.self, forKey: .providerId) ?? ""
        modelId = try container.decodeIfPresent(String.self, forKey: .modelId) ?? ""
        lastActiveAt = try container.decodeIfPresent(Date.self, forKey: .lastActiveAt) ?? Date()
        lastReportedInputTokens = try container.decodeIfPresent(Int.self, forKey: .lastReportedInputTokens)
    }
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

    private var archives: [ArchivedConversation] = []

    private let sessionsDirectory: URL
    /// Archived conversations, alongside the live ones rather than mixed in with them, so a
    /// directory listing still answers "what is current".
    private let archivesDirectory: URL
    private let indexURL: URL
    private let archivesURL: URL
    private let checkpointsURL: URL
    /// Where `think.json` (the old single-file format) used to live — read once for migration,
    /// then removed once its contents are safely split across the new files.
    private let legacyURL: URL

    init(stateDirectory: URL) {
        let thinkDirectory = stateDirectory.appendingPathComponent("think")
        self.sessionsDirectory = thinkDirectory.appendingPathComponent("sessions")
        self.archivesDirectory = thinkDirectory.appendingPathComponent("archive")
        self.indexURL = thinkDirectory.appendingPathComponent("index.json")
        self.archivesURL = thinkDirectory.appendingPathComponent("archives.json")
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
        touchResidency(trackKey)
        // The hot path: one appended line, not a full re-serialization of the conversation.
        // Falls back to a full write when there's no file yet (first turn) or the append fails.
        if !SessionLog.append(turn, to: sessionFileURL(forTrackKey: trackKey)) {
            saveSession(session)
        }
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

    /// Wholesale replacement of a track's turns — how compaction lands. Deliberately not an
    /// in-place edit of `turns`: the replacement has to be written and re-read as one unit, or a
    /// crash mid-compaction could leave half a conversation.
    @discardableResult
    func replaceTurns(_ turns: [AgentTurn], trackKey: String, providerId: String, modelId: String) -> AgentSession {
        var session = loadedSession(forTrackKey: trackKey) ?? AgentSession(trackKey: trackKey, providerId: providerId, modelId: modelId)
        session.turns = turns
        session.lastActiveAt = Date()
        loadedSessions[trackKey] = session
        touchResidency(trackKey)
        saveSession(session)
        if let indexPosition = index.firstIndex(where: { $0.trackKey == trackKey }) {
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

    /// Attaches a verification result to the most recent checkpoint on a track.
    ///
    /// Most recent, rather than "the checkpoint that produced the change": a task runs in a
    /// later round trip than the edit it verifies, and by then the batch that made the change
    /// is closed. The newest checkpoint is the one the task was run *against*, which is what
    /// the user means by "did that work?".
    @discardableResult
    func attachVerification(_ verification: CheckpointVerification, toLatestCheckpointFor trackKey: String) -> Bool {
        guard let index = checkpoints.lastIndex(where: { $0.trackKey == trackKey }) else { return false }
        checkpoints[index].verification = verification
        saveCheckpoints()
        return true
    }

    /// Records the provider's measured input-token count for a track's most recent request.
    ///
    /// Kept out of `appendTurn` on purpose: the count arrives with the response, which is a
    /// different moment from the turns being written, and conflating them would mean either
    /// writing the index twice per turn or losing the count on the turn that produced it.
    func recordReportedInputTokens(_ tokens: Int?, forTrackKey trackKey: String) {
        guard let position = index.firstIndex(where: { $0.trackKey == trackKey }) else { return }
        guard index[position].lastReportedInputTokens != tokens else { return }
        index[position].lastReportedInputTokens = tokens
        loadedSessions[trackKey]?.lastReportedInputTokens = tokens
        saveIndex()
    }

    func appendCheckpoint(_ checkpoint: Checkpoint) {
        checkpoints.append(checkpoint)
        saveCheckpoints()
    }

    /// Called when a track is deleted — its conversation and checkpoints have nowhere to belong
    /// anymore, same cleanup contract as Make's file memory and Run's terminal sessions.
    func removeSession(forTrackKey trackKey: String) {
        for record in archives where record.trackKey == trackKey {
            try? FileManager.default.removeItem(at: archiveFileURL(id: record.id))
        }
        archives.removeAll { $0.trackKey == trackKey }
        saveArchives()
        loadedSessions.removeValue(forKey: trackKey)
        residency.removeAll { $0 == trackKey }
        index.removeAll { $0.trackKey == trackKey }
        checkpoints.removeAll { $0.trackKey == trackKey }
        try? FileManager.default.removeItem(at: sessionFileURL(forTrackKey: trackKey))
        try? FileManager.default.removeItem(at: legacySessionFileURL(forTrackKey: trackKey))
        saveIndex()
        saveCheckpoints()
    }

    // MARK: - Lazy session loading

    /// Most-recently-used track keys, oldest first. The lazy-load fix stopped *eagerly*
    /// loading every track's history, but nothing evicted, so memory scaled with tracks
    /// ever visited rather than tracks in use — browsing eight tracks kept eight full
    /// conversations resident for the life of the project.
    private var residency: [String] = []
    private static let maxResidentSessions = 3

    private func touchResidency(_ trackKey: String) {
        residency.removeAll { $0 == trackKey }
        residency.append(trackKey)
        while residency.count > Self.maxResidentSessions {
            let evicted = residency.removeFirst()
            // Safe to drop: every mutation writes through to disk before returning, so the
            // cache is never the only copy of anything.
            loadedSessions.removeValue(forKey: evicted)
        }
    }

    private func loadedSession(forTrackKey trackKey: String) -> AgentSession? {
        if let cached = loadedSessions[trackKey] {
            touchResidency(trackKey)
            return cached
        }
        guard index.contains(where: { $0.trackKey == trackKey }) else { return nil }
        var session: AgentSession
        if let logged = SessionLog.read(from: sessionFileURL(forTrackKey: trackKey)) {
            session = logged
        } else if let legacy = JSONStore.read(AgentSession.self, from: legacySessionFileURL(forTrackKey: trackKey))?.payload {
            // One-time migration to the append-only log, then the old file goes away.
            session = legacy
            SessionLog.write(session, to: sessionFileURL(forTrackKey: trackKey))
            try? FileManager.default.removeItem(at: legacySessionFileURL(forTrackKey: trackKey))
        } else {
            return nil
        }
        // The index is authoritative for the mutable metadata it carries (see
        // `SessionIndexEntry`), so it wins over whatever the log header was created with.
        if let entry = index.first(where: { $0.trackKey == trackKey }) {
            session.lastReportedInputTokens = entry.lastReportedInputTokens
        }
        // Repair before anything can read it — a session with a dangling tool_use is not just
        // cosmetically odd, it's unusable (see `Self.repairingDanglingToolUses`).
        if let repaired = Self.repairingDanglingToolUses(session) {
            session = repaired
            saveSession(session)
        }
        loadedSessions[trackKey] = session
        touchResidency(trackKey)
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
        sessionsDirectory.appendingPathComponent("\(Self.slug(for: trackKey)).jsonl")
    }

    /// The pre-JSONL filename, still read once so an existing conversation migrates instead of
    /// vanishing.
    private func legacySessionFileURL(forTrackKey trackKey: String) -> URL {
        let slug = trackKey.isEmpty ? "_none_" : trackKey.replacingOccurrences(of: "/", with: "-")
        return sessionsDirectory.appendingPathComponent("\(slug).json")
    }

    /// A filesystem-safe name that can't collide. The old form just mapped `/`→`-`, so the
    /// branches `feat/x` and `feat-x` — both reachable, since either can be adopted as a track —
    /// shared one conversation file and silently merged two conversations. The suffix is derived
    /// from the full key, so distinct keys stay distinct however they're spelled.
    private static func slug(for trackKey: String) -> String {
        guard !trackKey.isEmpty else { return "_none_" }
        let safe = String(trackKey.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" }.prefix(60))
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in Array(trackKey.utf8) {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return "\(safe)-\(String(hash, radix: 36))"
    }

    // MARK: - Persistence

    private func load() {
        if let loaded = JSONStore.read([SessionIndexEntry].self, from: indexURL) {
            index = loaded.payload
            archives = JSONStore.read([ArchivedConversation].self, from: archivesURL)?.payload ?? []
            checkpoints = JSONStore.read([Checkpoint].self, from: checkpointsURL)?.payload ?? []
            pruneExpiredSessions()
            return
        }
        migrateLegacyStateIfPresent()
    }

    /// Applies the user's retention setting. At load, rather than on a timer: a project's
    /// history can only expire while someone's looking at that project, and a background sweep
    /// deleting files for projects nobody has open is a worse trade than a slightly late one.
    private func pruneExpiredSessions() {
        guard let cutoff = HistoryRetention.current.cutoffDate() else { return }
        let expired = index.filter { $0.lastActiveAt < cutoff }
        guard !expired.isEmpty else { return }
        for entry in expired {
            loadedSessions.removeValue(forKey: entry.trackKey)
            try? FileManager.default.removeItem(at: sessionFileURL(forTrackKey: entry.trackKey))
            try? FileManager.default.removeItem(at: legacySessionFileURL(forTrackKey: entry.trackKey))
        }
        index.removeAll { $0.lastActiveAt < cutoff }
        saveIndex()
    }

    /// Drops every conversation in this project, keeping tracks and checkpoints. The blunt
    /// instrument behind Preferences' "Delete All Conversations."
    func deleteAllSessions() {
        for record in archives {
            try? FileManager.default.removeItem(at: archiveFileURL(id: record.id))
        }
        archives.removeAll()
        saveArchives()
        loadedSessions.removeAll()
        residency.removeAll()
        for entry in index {
            try? FileManager.default.removeItem(at: sessionFileURL(forTrackKey: entry.trackKey))
            try? FileManager.default.removeItem(at: legacySessionFileURL(forTrackKey: entry.trackKey))
        }
        index.removeAll()
        saveIndex()
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
        JSONStore.write(index, to: indexURL)
    }

    // MARK: - Conversation history

    /// Past conversations for a track, newest first.
    func archivedConversations(forTrackKey trackKey: String) -> [ArchivedConversation] {
        archives.filter { $0.trackKey == trackKey }.sorted { $0.archivedAt > $1.archivedAt }
    }

    /// Files the track's current conversation away and clears the live slot.
    ///
    /// Returns false when there is nothing worth keeping — an empty conversation is not history,
    /// and archiving it would fill the picker with blank rows.
    @discardableResult
    func archiveActiveConversation(forTrackKey trackKey: String) -> Bool {
        guard let session = loadedSession(forTrackKey: trackKey), !session.turns.isEmpty else { return false }
        let record = ArchivedConversation(
            id: session.id, trackKey: trackKey,
            title: ArchivedConversation.title(for: session),
            turnCount: session.turns.count,
            createdAt: session.createdAt
        )
        // Written before the live copy is cleared: if this fails the conversation is still where
        // it was, which is the safe direction for a failure whose alternative is losing it.
        guard SessionLog.write(session, to: archiveFileURL(id: session.id)) else { return false }
        archives.append(record)
        saveArchives()
        clearActiveConversation(forTrackKey: trackKey)
        return true
    }

    /// Swaps an archived conversation back into the live slot, filing away whatever was there.
    ///
    /// The current conversation is archived first rather than discarded — reopening an old one
    /// must not be a way to lose the new one.
    @discardableResult
    func openArchivedConversation(id: UUID, forTrackKey trackKey: String) -> AgentSession? {
        guard let record = archives.first(where: { $0.id == id && $0.trackKey == trackKey }),
              let session = SessionLog.read(from: archiveFileURL(id: id)) else { return nil }
        archiveActiveConversation(forTrackKey: trackKey)
        guard SessionLog.write(session, to: sessionFileURL(forTrackKey: trackKey)) else { return nil }
        try? FileManager.default.removeItem(at: archiveFileURL(id: id))
        archives.removeAll { $0.id == record.id }
        saveArchives()
        loadedSessions[trackKey] = session
        touchResidency(trackKey)
        upsertIndexEntry(for: session, trackKey: trackKey)
        return session
    }

    /// Removes the live conversation without keeping it — what `startNewConversation` used to do
    /// unconditionally, now reserved for a user who explicitly discards.
    func clearActiveConversation(forTrackKey trackKey: String) {
        loadedSessions.removeValue(forKey: trackKey)
        residency.removeAll { $0 == trackKey }
        index.removeAll { $0.trackKey == trackKey }
        try? FileManager.default.removeItem(at: sessionFileURL(forTrackKey: trackKey))
        try? FileManager.default.removeItem(at: legacySessionFileURL(forTrackKey: trackKey))
        saveIndex()
    }

    private func archiveFileURL(id: UUID) -> URL {
        archivesDirectory.appendingPathComponent("\(id.uuidString).jsonl")
    }

    private func saveArchives() {
        JSONStore.write(archives, to: archivesURL)
    }

    private func upsertIndexEntry(for session: AgentSession, trackKey: String) {
        if let position = index.firstIndex(where: { $0.trackKey == trackKey }) {
            index[position].providerId = session.providerId
            index[position].modelId = session.modelId
            index[position].lastActiveAt = session.lastActiveAt
            index[position].lastReportedInputTokens = session.lastReportedInputTokens
        } else {
            index.append(SessionIndexEntry(
                id: session.id, trackKey: trackKey, providerId: session.providerId,
                modelId: session.modelId, lastActiveAt: session.lastActiveAt,
                lastReportedInputTokens: session.lastReportedInputTokens
            ))
        }
        saveIndex()
    }

    private func saveCheckpoints() {
        JSONStore.write(checkpoints, to: checkpointsURL)
    }

    private func saveSession(_ session: AgentSession) {
        SessionLog.write(session, to: sessionFileURL(forTrackKey: session.trackKey))
    }
}

/// The old `think.json` shape — read only during one-time migration in `migrateLegacyStateIfPresent`.
private struct ThinkStateLegacy: Codable {
    var sessions: [AgentSession] = []
    var checkpoints: [Checkpoint] = []
}
