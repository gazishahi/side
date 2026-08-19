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
}
