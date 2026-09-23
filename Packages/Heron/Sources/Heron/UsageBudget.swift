import Foundation

/// A monthly spend ceiling, checked before a request goes out.
///
/// Visibility alone doesn't stop a tool loop from spending real money while nobody's watching —
/// the runner's round-trip cap bounds one send, not a day of them. This is the other half: an
/// opt-in limit, off by default, enforced at the one place a request is about to be made.
///
/// Enforced against *estimated* spend, which means it can only be as accurate as
/// `ModelPricing`. Two consequences stated plainly wherever it's shown: a month that used an
/// unpriced model is under-counted, and the estimate never matches a bill exactly. It's a
/// guardrail against runaway loops, not an accounting control.
public enum UsageBudget {
    private static let limitKey = "SideMonthlyBudgetUSD"
    /// Where "you're getting close" starts. Not configurable: another knob for a number nobody
    /// would tune, and a warning at 80% is the convention everywhere else this appears.
    public static let warningFraction = 0.8

    /// `nil` means no budget. Stored as a `Double` so `0` and "unset" are the same thing —
    /// a zero-dollar budget that blocks everything is never what someone means.
    public static var monthlyLimitUSD: Double? {
        get {
            let stored = UserDefaults.standard.double(forKey: limitKey)
            return stored > 0 ? stored : nil
        }
        set {
            let value = newValue ?? 0
            UserDefaults.standard.set(value > 0 ? value : 0, forKey: limitKey)
        }
    }

    public enum Status: Equatable {
        /// No budget set — the default.
        case unlimited
        case withinBudget(spent: Double, limit: Double)
        case approaching(spent: Double, limit: Double)
        case exceeded(spent: Double, limit: Double)

        public var blocksSending: Bool {
            if case .exceeded = self { return true }
            return false
        }
    }

    public static func status(store: UsageStore = .shared, now: Date = Date()) -> Status {
        guard let limit = monthlyLimitUSD else { return .unlimited }
        let spent = store.estimatedCostThisMonth(now: now).total
        if spent >= limit { return .exceeded(spent: spent, limit: limit) }
        if spent >= limit * warningFraction { return .approaching(spent: spent, limit: limit) }
        return .withinBudget(spent: spent, limit: limit)
    }

    /// What Think shows in place of a model turn when the budget is spent. Says the number, says
    /// where to change it, and doesn't pretend the estimate is exact.
    public static func blockedMessage(spent: Double, limit: Double) -> String {
        "This month's estimated spend (\(UsageFormatting.cost(spent))) has reached your \(UsageFormatting.cost(limit)) budget, so nothing was sent. Raise or clear the budget in Settings → Usage to continue. Estimates are approximate and won't match your bill exactly."
    }
}
