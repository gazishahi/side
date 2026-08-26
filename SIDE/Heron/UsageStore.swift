import Foundation

/// What one (project, track, provider, model) combination has cost so far, in tokens.
struct UsageTotals: Codable, Equatable {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    /// Prompt tokens served from the provider's cache — counted separately because they're
    /// billed differently (and much cheaper) than fresh input.
    var cachedInputTokens: Int = 0
    /// Model turns, not user messages: one agent reply that makes three tool round-trips is
    /// three requests, and each one is billed.
    var requestCount: Int = 0

    var totalTokens: Int { inputTokens + outputTokens + cachedInputTokens }

    mutating func add(_ other: UsageTotals) {
        inputTokens += other.inputTokens
        outputTokens += other.outputTokens
        cachedInputTokens += other.cachedInputTokens
        requestCount += other.requestCount
    }
}

/// One aggregate row. Deliberately an aggregate rather than an event log: the ask was visibility,
/// not an audit trail, and per-request events would grow without bound — re-creating the very
/// memory problem `AgentSessionStore` was just restructured to avoid.
struct UsageRecord: Codable, Equatable {
    let projectPath: String
    let trackKey: String
    let providerId: String
    let modelId: String
    var totals: UsageTotals
    var lastUsedAt: Date

    var projectName: String {
        URL(fileURLWithPath: projectPath).lastPathComponent
    }
}

/// Token accounting across every project. Providers already report usage at the end of each
/// streamed turn and `AgentRunner` used to drop it on the floor, so a run's cost was invisible:
/// no per-track total, no per-model total, no way to notice a tool loop burning tokens.
///
/// App-wide rather than per-project (unlike the session store) because the question it answers —
/// "what have I spent?" — is asked in Preferences, which isn't scoped to an open project.
/// Marked unchecked-Sendable because it's deliberately only ever touched from the main thread —
/// same convention (and same reason) as `ProviderRegistryStore`.
final class UsageStore: @unchecked Sendable {
    static let shared = UsageStore()

    private(set) var records: [UsageRecord] = []
    private let storeURL: URL
    private var changeObservers: [UUID: () -> Void] = [:]

    init(storeURL: URL? = nil) {
        if let storeURL {
            self.storeURL = storeURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
            self.storeURL = support.appendingPathComponent("Side/usage.json")
        }
        load()
    }

    @discardableResult
    func addChangeObserver(_ observer: @escaping () -> Void) -> UUID {
        let token = UUID()
        changeObservers[token] = observer
        return token
    }

    func removeChangeObserver(_ token: UUID) { changeObservers.removeValue(forKey: token) }

    func record(projectPath: String, trackKey: String, providerId: String, modelId: String, usage: TokenUsage) {
        var incoming = UsageTotals()
        incoming.inputTokens = usage.inputTokens
        incoming.outputTokens = usage.outputTokens
        incoming.cachedInputTokens = usage.cachedInputTokens ?? 0
        incoming.requestCount = 1

        if let index = records.firstIndex(where: {
            $0.projectPath == projectPath && $0.trackKey == trackKey && $0.providerId == providerId && $0.modelId == modelId
        }) {
            records[index].totals.add(incoming)
            records[index].lastUsedAt = Date()
        } else {
            records.append(UsageRecord(
                projectPath: projectPath, trackKey: trackKey, providerId: providerId,
                modelId: modelId, totals: incoming, lastUsedAt: Date()
            ))
        }
        save()
        notifyObservers()
    }

    func totals(projectPath: String, trackKey: String) -> UsageTotals {
        records
            .filter { $0.projectPath == projectPath && $0.trackKey == trackKey }
            .reduce(into: UsageTotals()) { $0.add($1.totals) }
    }

    /// Rolled up per model, biggest spender first — the shape Preferences lists.
    func totalsByModel() -> [(providerId: String, modelId: String, totals: UsageTotals, lastUsedAt: Date)] {
        var grouped: [String: (providerId: String, modelId: String, totals: UsageTotals, lastUsedAt: Date)] = [:]
        for record in records {
            let key = "\(record.providerId)|\(record.modelId)"
            var entry = grouped[key] ?? (record.providerId, record.modelId, UsageTotals(), record.lastUsedAt)
            entry.totals.add(record.totals)
            entry.lastUsedAt = max(entry.lastUsedAt, record.lastUsedAt)
            grouped[key] = entry
        }
        return grouped.values.sorted {
            let left = ModelPricing.estimatedCost(modelId: $0.modelId, totals: $0.totals) ?? 0
            let right = ModelPricing.estimatedCost(modelId: $1.modelId, totals: $1.totals) ?? 0
            if left != right { return left > right }
            return $0.totals.totalTokens > $1.totals.totalTokens
        }
    }

    func totalsByProject() -> [(projectPath: String, totals: UsageTotals, lastUsedAt: Date)] {
        var grouped: [String: (projectPath: String, totals: UsageTotals, lastUsedAt: Date)] = [:]
        for record in records {
            var entry = grouped[record.projectPath] ?? (record.projectPath, UsageTotals(), record.lastUsedAt)
            entry.totals.add(record.totals)
            entry.lastUsedAt = max(entry.lastUsedAt, record.lastUsedAt)
            grouped[record.projectPath] = entry
        }
        return grouped.values.sorted { $0.lastUsedAt > $1.lastUsedAt }
    }

    func grandTotal() -> UsageTotals {
        records.reduce(into: UsageTotals()) { $0.add($1.totals) }
    }

    /// Sum of the per-model estimates, plus whether any model in the mix has no published price
    /// here — the caller needs that flag to avoid presenting a partial figure as a complete one.
    func estimatedCost() -> (total: Double, hasUnpricedModels: Bool) {
        var total = 0.0
        var hasUnpriced = false
        for entry in totalsByModel() {
            if let cost = ModelPricing.estimatedCost(modelId: entry.modelId, totals: entry.totals) {
                total += cost
            } else if entry.totals.totalTokens > 0 {
                hasUnpriced = true
            }
        }
        return (total, hasUnpriced)
    }

    /// Dropped alongside a track's conversation and checkpoints — same cleanup contract.
    func removeUsage(projectPath: String, trackKey: String) {
        records.removeAll { $0.projectPath == projectPath && $0.trackKey == trackKey }
        save()
        notifyObservers()
    }

    func removeAll() {
        records = []
        save()
        notifyObservers()
    }

    private func notifyObservers() {
        for observer in changeObservers.values { observer() }
    }

    private func load() {
        records = JSONStore.read([UsageRecord].self, from: storeURL)?.payload ?? []
    }

    private func save() {
        JSONStore.write(records, to: storeURL)
    }
}

/// Rough per-million-token prices, used only to turn token counts into a sense of scale.
///
/// Deliberately conservative about what it claims: a model with no entry here shows tokens and no
/// cost rather than a guess, and every figure is labelled an estimate wherever it's shown.
/// Published prices change, and a confidently wrong number is worse than an honest blank.
enum ModelPricing {
    struct Price {
        let inputPerMillion: Double
        let outputPerMillion: Double
        /// Cache reads are billed at a fraction of fresh input on every provider that offers
        /// them; 10% is the common figure and the one used here.
        var cachedInputPerMillion: Double { inputPerMillion * 0.1 }
    }

    private static let table: [String: Price] = [
        "claude-opus-5": Price(inputPerMillion: 15, outputPerMillion: 75),
        "claude-sonnet-5": Price(inputPerMillion: 3, outputPerMillion: 15),
        "claude-haiku-4-5-20251001": Price(inputPerMillion: 1, outputPerMillion: 5),
    ]

    /// `nil` when the model isn't priced here — a local model costs nothing, and an unknown
    /// remote one shouldn't be guessed at.
    static func estimatedCost(modelId: String, totals: UsageTotals) -> Double? {
        guard let price = table[modelId] else { return nil }
        return Double(totals.inputTokens) / 1_000_000 * price.inputPerMillion
            + Double(totals.outputTokens) / 1_000_000 * price.outputPerMillion
            + Double(totals.cachedInputTokens) / 1_000_000 * price.cachedInputPerMillion
    }

    static func isPriced(modelId: String) -> Bool { table[modelId] != nil }
}

/// Shared formatting so a token count reads the same in Think's header and in Preferences.
enum UsageFormatting {
    static func tokens(_ count: Int) -> String {
        switch count {
        case ..<1_000: return "\(count)"
        case ..<1_000_000: return String(format: "%.1fK", Double(count) / 1_000)
        default: return String(format: "%.2fM", Double(count) / 1_000_000)
        }
    }

    static func cost(_ amount: Double) -> String {
        amount > 0 && amount < 0.01 ? "<$0.01" : String(format: "$%.2f", amount)
    }
}
