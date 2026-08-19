import Foundation

enum ProviderKind: String, Codable, Sendable {
    case builtIn
    /// A user-added provider speaking the OpenAI-compatible chat-completions wire shape —
    /// covers OpenAI BYOK and most local servers (Ollama, LM Studio). Adapter lands in
    /// Phase 6; the kind exists now so the persisted format doesn't need a migration then.
    case byokOpenAICompatible
    case local
}

struct ProviderModel: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var displayName: String
    var contextWindowTokens: Int
}

/// One entry in the provider registry — the mutable, persisted analog of
/// LanguageServerRegistry.Entry. Custom/local providers flow through this exact same struct;
/// there is deliberately no special-casing of how a provider got here.
struct ProviderDefinition: Codable, Identifiable, Sendable {
    let id: String
    var displayName: String
    let kind: ProviderKind
    var baseURL: URL
    var requiresAPIKey: Bool
    var models: [ProviderModel]
    var defaultModelId: String
}
