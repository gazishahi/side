import Foundation

/// Owns the persisted provider table and turns an entry + its Keychain credential into a
/// ready ChatModelProvider. App-level (one per machine, like UserDefaults), not per-project —
/// providers and keys are a machine-wide concern, unlike Tracks.
/// Marked unchecked-Sendable because it's deliberately only ever touched from the main
/// thread — same convention (and same reason) as LSPManager.
final class ProviderRegistryStore: @unchecked Sendable {
    static let shared = ProviderRegistryStore()

    private(set) var providers: [ProviderDefinition] = []
    /// Which provider Think actually talks to — app-wide, not per-track (switching providers
    /// mid-project is a machine-level preference, same footing as the key itself). Defaults to
    /// the built-in Anthropic entry, which always exists.
    private(set) var activeProviderId: String = "anthropic"
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

    func setActiveProvider(_ id: String) {
        guard provider(for: id) != nil else { return }
        activeProviderId = id
        save()
    }

    func removeProvider(_ id: String) {
        guard id != "anthropic" else { return } // the one provider that must always exist
        providers.removeAll { $0.id == id }
        if activeProviderId == id { activeProviderId = "anthropic" }
        save()
    }

    func resolveAdapter(providerId: String) -> AdapterResolution {
        guard let definition = provider(for: providerId) else { return .unknownProvider }
        guard let model = definition.models.first(where: { $0.id == definition.defaultModelId }) ?? definition.models.first else {
            return .unknownProvider
        }
        // Env var checked *before* Keychain, not just as a fallback after it — a Keychain read
        // triggers a real ACL permission prompt (macOS ties the grant to the app's code
        // signature, which an ad-hoc-signed debug build gets a fresh one of on every rebuild, so
        // this would otherwise re-prompt on every single relaunch during development). With
        // ANTHROPIC_API_KEY set, there's no reason to ever touch the Keychain at all — checking
        // it first means the prompt genuinely never fires as long as the env var is present, not
        // just "recovers gracefully after" one already did.
        var apiKey: String?
        if definition.id == "anthropic" {
            apiKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
        }
        // Only touch the Keychain at all when this provider actually needs a key and nothing
        // above already resolved one — a local server that never asked for a key shouldn't
        // trigger a Keychain ACL prompt just because it happens to be the active provider.
        if apiKey?.isEmpty != false, definition.requiresAPIKey {
            apiKey = KeychainStore.get(account: definition.id)
        }
        if definition.requiresAPIKey, apiKey?.isEmpty != false {
            return .missingAPIKey(definition)
        }
        switch definition.kind {
        case .builtIn where definition.id == "anthropic":
            return .ready(AnthropicMessagesProvider(apiKey: apiKey ?? "", modelId: model.id, baseURL: definition.baseURL), definition, model)
        case .builtIn:
            return .unknownProvider // no other builtIn ids are modeled yet
        case .byokOpenAICompatible, .local:
            // Covers OpenAI BYOK and local servers (Ollama, LM Studio) alike — both speak the
            // same chat-completions wire shape, so one adapter serves both `kind`s.
            return .ready(
                OpenAICompatibleChatProvider(apiKey: apiKey, modelId: model.id, baseURL: definition.baseURL, contextWindowTokens: model.contextWindowTokens),
                definition, model
            )
        }
    }

    // MARK: - Persistence (TrackStore's conventions: .iso8601, .prettyPrinted, try?-swallowed)

    /// Wraps `providers` + `activeProviderId` together so both persist in one file. Decodes the
    /// pre-BYOK bare-array shape as a fallback, the same pattern `AgentSessionStore` uses for its
    /// own persisted format — a file written before this field existed shouldn't need a migration
    /// step, just a default.
    private struct RegistryState: Codable {
        var providers: [ProviderDefinition]
        var activeProviderId: String

        init(providers: [ProviderDefinition], activeProviderId: String) {
            self.providers = providers
            self.activeProviderId = activeProviderId
        }

        init(from decoder: Decoder) throws {
            if let container = try? decoder.container(keyedBy: CodingKeys.self),
               let providers = try? container.decode([ProviderDefinition].self, forKey: .providers) {
                self.providers = providers
                self.activeProviderId = (try? container.decode(String.self, forKey: .activeProviderId)) ?? "anthropic"
            } else {
                self.providers = (try? [ProviderDefinition](from: decoder)) ?? []
                self.activeProviderId = "anthropic"
            }
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let state = try? decoder.decode(RegistryState.self, from: data) else { return }
        providers = state.providers
        activeProviderId = state.activeProviderId
    }

    private func save() {
        try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(RegistryState(providers: providers, activeProviderId: activeProviderId)) else { return }
        try? data.write(to: storeURL)
    }

    /// Phase 1 stored a dev key in UserDefaults; anyone who set it up that way shouldn't have
    /// their working configuration silently break when Keychain storage lands — move the key
    /// over once, then remove the old one.
    /// Runs on every launch, so the `UserDefaults` check — free, no Keychain access — comes
    /// first: there's a real legacy key to migrate on essentially no launches at this point, and
    /// `KeychainStore.hasSecret` triggers a genuine Keychain ACL prompt, which used to mean this
    /// one check alone re-prompted on every single relaunch regardless of anything else touching
    /// the Keychain that session.
    private func migrateLegacyDevKeyIfNeeded() {
        let legacyKey = "side.dev.anthropic-api-key"
        guard let legacy = UserDefaults.standard.string(forKey: legacyKey), !legacy.isEmpty,
              !KeychainStore.hasSecret(account: "anthropic") else { return }
        if KeychainStore.set(secret: legacy, account: "anthropic") {
            UserDefaults.standard.removeObject(forKey: legacyKey)
        }
    }
}
