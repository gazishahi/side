import Foundation

/// A past conversation on a track, kept rather than destroyed.
///
/// Until now a track had exactly one conversation and `/new` deleted it. That made every
/// conversation disposable, which is the single thing that most made Think feel like a demo
/// rather than a tool: the transcript is where the reasoning behind a change lives, and throwing
/// it away to start the next task is a strange trade.
///
/// Deliberately implemented *beside* the live session rather than by re-keying the store. The
/// active conversation is still stored per track exactly as before, so every existing read and
/// write is untouched; archiving copies the file aside and records this. That keeps the risky
/// surface at zero for the paths that run on every keystroke, and the cost is that opening an
/// archived conversation is a swap rather than a pointer change — which is fine, because it
/// happens when a human clicks a menu.
struct ArchivedConversation: Codable, Identifiable, Equatable {
    let id: UUID
    let trackKey: String
    /// Drawn from the first thing the user said, because that is what they will recognize it by.
    /// A conversation with no user message at all falls back to its date.
    let title: String
    let turnCount: Int
    let createdAt: Date
    let archivedAt: Date

    init(id: UUID, trackKey: String, title: String, turnCount: Int, createdAt: Date, archivedAt: Date = Date()) {
        self.id = id
        self.trackKey = trackKey
        self.title = title
        self.turnCount = turnCount
        self.createdAt = createdAt
        self.archivedAt = archivedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, trackKey, title, turnCount, createdAt, archivedAt
    }

    // Tolerant, like every other persisted struct here.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        trackKey = try container.decode(String.self, forKey: .trackKey)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        turnCount = try container.decodeIfPresent(Int.self, forKey: .turnCount) ?? 0
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        archivedAt = try container.decodeIfPresent(Date.self, forKey: .archivedAt) ?? createdAt
    }

    /// The title a session should be filed under: its first user message, trimmed to something
    /// that fits a menu row.
    static func title(for session: AgentSession) -> String {
        for turn in session.turns where turn.role == .user {
            for block in turn.content {
                guard case .text(let text) = block else { continue }
                let oneLine = text
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !oneLine.isEmpty else { continue }
                // A compacted conversation's first "user" turn is the summary Side wrote, not
                // anything the user said — titling a row "[Earlier conversation, compacted to
                // fit the context window…" tells them nothing about which conversation it was.
                guard !oneLine.hasPrefix(Self.compactionMarker) else { continue }
                return oneLine.count > 70 ? String(oneLine.prefix(70)) + "…" : oneLine
            }
        }
        return ""
    }

    /// The opening of `ContextBudget.summaryTurnText` — the one user-role turn Side writes
    /// itself, rather than something the user typed.
    private static let compactionMarker = "[Earlier conversation, compacted"
}
