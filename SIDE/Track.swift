import Foundation

enum TrackStatus: String, Codable {
    case active
    case waiting
    /// The constitution's own track lifecycle is `Active → Waiting / Review-ready / Parked →
    /// Completed → Archived` — this case was simply missing until now, leaving no way to mark a
    /// track "done from my end, wants a look" distinctly from just "waiting" on something else.
    case reviewReady
    case parked
    case completed
    case archived
}

struct Track: Codable, Identifiable {
    let id: UUID
    var intent: String
    let branchName: String
    var status: TrackStatus
    let createdAt: Date
    var lastActiveAt: Date
    /// The track's own linked git worktree, once it has one (see `TrackStore.addWorktree`).
    /// `nil` means it's never been materialized — a track created before per-track worktrees
    /// existed, or one this session hasn't visited yet — in which case tools/Run/Make fall back
    /// to the project's shared root.
    var workingDirectoryPath: String?
    /// Per-track opt-in to skip the approval step for `run_shell_command` — off by default, since
    /// "agents propose; people promote" applies to commands exactly as much as edits. Decoded
    /// with a default so tracks persisted before this field existed don't fail to load.
    var autoRunCommands: Bool
    /// `nil` means this track forks from the project's default branch — every track before this
    /// field existed, and still the common case. Non-nil means it forks from *another track's*
    /// branch instead (see "Stacked tracks" in the constitution's Change model section) — that
    /// track's own worktree, own agent, own checkpoint/review/promote cycle, nested rather than
    /// sitting side by side. Stored as an id, not a branch name, so renaming the parent track
    /// (which never touches its branch name) can't silently orphan the relationship.
    var parentTrackId: UUID?

    init(intent: String, branchName: String, parentTrackId: UUID? = nil) {
        self.id = UUID()
        self.intent = intent
        self.branchName = branchName
        self.status = .active
        self.createdAt = Date()
        self.lastActiveAt = Date()
        self.workingDirectoryPath = nil
        self.autoRunCommands = false
        self.parentTrackId = parentTrackId
    }

    private enum CodingKeys: String, CodingKey {
        case id, intent, branchName, status, createdAt, lastActiveAt, workingDirectoryPath, autoRunCommands, parentTrackId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        intent = try container.decode(String.self, forKey: .intent)
        branchName = try container.decode(String.self, forKey: .branchName)
        status = try container.decode(TrackStatus.self, forKey: .status)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        lastActiveAt = try container.decode(Date.self, forKey: .lastActiveAt)
        workingDirectoryPath = try container.decodeIfPresent(String.self, forKey: .workingDirectoryPath)
        autoRunCommands = try container.decodeIfPresent(Bool.self, forKey: .autoRunCommands) ?? false
        parentTrackId = try container.decodeIfPresent(UUID.self, forKey: .parentTrackId)
    }
}
