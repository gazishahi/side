import Foundation

struct AgentTurn: Codable, Identifiable {
    let id: UUID
    let role: AgentMessage.Role
    var content: [AgentContentBlock]
    let createdAt: Date

    init(role: AgentMessage.Role, content: [AgentContentBlock]) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.createdAt = Date()
    }

    // Tolerant decoding, for the same reason `Track` has it: a persisted turn written by an
    // older build is missing whatever field the newer build added, and synthesized Codable
    // treats that as a hard failure — which would take the whole conversation file down with
    // it. Identity and content are the only fields worth refusing to load without.
    private enum CodingKeys: String, CodingKey {
        case id, role, content, createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        role = try container.decode(AgentMessage.Role.self, forKey: .role)
        content = try container.decode([AgentContentBlock].self, forKey: .content)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

/// One conversation with an agent, tied to one track. Keyed by branch name (`""` for "no
/// active track"), the same per-track convention Make's file memory and Run's terminal
/// sessions already use — a string key, not a Track UUID, because a session must be able to
/// exist for a project with no tracks at all.
struct AgentSession: Codable, Identifiable {
    let id: UUID
    let trackKey: String
    var providerId: String
    var modelId: String
    var turns: [AgentTurn]
    let createdAt: Date
    var lastActiveAt: Date

    init(trackKey: String, providerId: String, modelId: String) {
        self.id = UUID()
        self.trackKey = trackKey
        self.providerId = providerId
        self.modelId = modelId
        self.turns = []
        self.createdAt = Date()
        self.lastActiveAt = Date()
    }

    /// Memberwise — used by `SessionLog`, which reconstructs a session from a header line plus
    /// separately-decoded turns rather than decoding one whole object.
    init(id: UUID, trackKey: String, providerId: String, modelId: String, turns: [AgentTurn], createdAt: Date, lastActiveAt: Date) {
        self.id = id
        self.trackKey = trackKey
        self.providerId = providerId
        self.modelId = modelId
        self.turns = turns
        self.createdAt = createdAt
        self.lastActiveAt = lastActiveAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, trackKey, providerId, modelId, turns, createdAt, lastActiveAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        trackKey = try container.decode(String.self, forKey: .trackKey)
        turns = try container.decodeIfPresent([AgentTurn].self, forKey: .turns) ?? []
        // Provider/model are metadata about who answered, not part of the conversation — a file
        // missing them should still open, with the active provider filling in on the next turn.
        providerId = try container.decodeIfPresent(String.self, forKey: .providerId) ?? ""
        modelId = try container.decodeIfPresent(String.self, forKey: .modelId) ?? ""
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        lastActiveAt = try container.decodeIfPresent(Date.self, forKey: .lastActiveAt) ?? createdAt
    }
}
