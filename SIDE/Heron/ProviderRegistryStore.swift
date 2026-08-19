import Foundation

/// Owns the persisted provider table and turns an entry + its Keychain credential into a
/// ready ChatModelProvider. App-level (one per machine, like UserDefaults), not per-project —
/// providers and keys are a machine-wide concern, unlike Tracks.
/// Marked unchecked-Sendable because it's deliberately only ever touched from the main
/// thread — same convention (and same reason) as LSPManager.
final class ProviderRegistryStore: @unchecked Sendable {
    static let shared = ProviderRegistryStore()

    private(set) var providers: [ProviderDefinition] = []
    private let storeURL: URL

    /// Resolution is deliberately a typed result, not an Optional — a missing credential must
    /// surface as "add your key in Preferences" in the UI, never as a provider that silently
    /// doesn't work.
    enum AdapterResolution {
        case ready(ChatModelProvider, ProviderDefinition, ProviderModel)
        case missingAPIKey(ProviderDefinition)
        case unknownProvider
    }

    init(storeURL: URL? = nil) {
        if let storeURL {
            self.storeURL = storeURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
            self.storeURL = support.appendingPathComponent("Side/providers.json")
        }
        load()
        if providers.isEmpty {
            providers = Self.builtInSeeds
            save()
        }
        migrateLegacyDevKeyIfNeeded()
    }

    static let builtInSeeds: [ProviderDefinition] = [
        ProviderDefinition(
            id: "anthropic",
            displayName: "Anthropic",
            kind: .builtIn,
            baseURL: URL(string: "https://api.anthropic.com")!,
            requiresAPIKey: true,
            models: [
                ProviderModel(id: "claude-sonnet-5", displayName: "Claude Sonnet 5", contextWindowTokens: 200_000),
                ProviderModel(id: "claude-opus-5", displayName: "Claude Opus 5", contextWindowTokens: 200_000),
                ProviderModel(id: "claude-haiku-4-5-20251001", displayName: "Claude Haiku 4.5", contextWindowTokens: 200_000),
            ],
            defaultModelId: "claude-sonnet-5"
        ),
    ]

    func provider(for id: String) -> ProviderDefinition? {
        providers.first { $0.id == id }
    }

    func addOrUpdate(_ provider: ProviderDefinition) {
        if let index = providers.firstIndex(where: { $0.id == provider.id }) {
            providers[index] = provider
        } else {
            providers.append(provider)
        }
        save()
    }

    func setDefaultModel(providerId: String, modelId: String) {
        guard var definition = provider(for: providerId),
              definition.models.contains(where: { $0.id == modelId }) else { return }
        definition.defaultModelId = modelId
        addOrUpdate(definition)
    }

    func resolveAdapter(providerId: String) -> AdapterResolution {
        guard let definition = provider(for: providerId) else { return .unknownProvider }
        guard let model = definition.models.first(where: { $0.id == definition.defaultModelId }) ?? definition.models.first else {
            return .unknownProvider
        }
        var apiKey = KeychainStore.get(account: definition.id)
        // Env-var fallback survives on purpose — launching from a terminal with
        // ANTHROPIC_API_KEY set should keep working for development even with nothing in
        // the Keychain.
        if apiKey?.isEmpty != false, definition.id == "anthropic" {
            apiKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
        }
        if definition.requiresAPIKey, apiKey?.isEmpty != false {
            return .missingAPIKey(definition)
        }
        switch definition.kind {
        case .builtIn where definition.id == "anthropic":
            return .ready(AnthropicMessagesProvider(apiKey: apiKey ?? "", modelId: model.id, baseURL: definition.baseURL), definition, model)
        case .builtIn, .byokOpenAICompatible, .local:
            // OpenAICompatibleChatProvider arrives in Phase 6.
            return .unknownProvider
        }
    }

    // MARK: - Persistence (TrackStore's conventions: .iso8601, .prettyPrinted, try?-swallowed)

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        providers = (try? decoder.decode([ProviderDefinition].self, from: data)) ?? []
    }

    private func save() {
        try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(providers) else { return }
        try? data.write(to: storeURL)
    }

    /// Phase 1 stored a dev key in UserDefaults; anyone who set it up that way shouldn't have
    /// their working configuration silently break when Keychain storage lands — move the key
    /// over once, then remove the old one.
    private func migrateLegacyDevKeyIfNeeded() {
        let legacyKey = "side.dev.anthropic-api-key"
        guard !KeychainStore.hasSecret(account: "anthropic"),
              let legacy = UserDefaults.standard.string(forKey: legacyKey), !legacy.isEmpty else { return }
        if KeychainStore.set(secret: legacy, account: "anthropic") {
            UserDefaults.standard.removeObject(forKey: legacyKey)
        }
    }
}
