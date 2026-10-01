import Foundation
import Heron

/// Which stages the stage control shows (Direction 02 §3.1). A stage is a view over shared
/// engines: unpinning hides a view, never a capability — every stage stays reachable through
/// ⌘⌥1–4, Navigate and the palette, and attention is never hidden.
enum StagePins {
    typealias Stage = ShellViewController.Stage

    /// Tracks is never in the control; it is reached through the track pill.
    static let pinnable: [Stage] = [.make, .think, .review, .run]
    static let didChangeNotification = Notification.Name("SideStagePinsDidChange")
    private static let defaultsKey = "SidePinnedStages"

    enum Preset: CaseIterable {
        case agent, editor, everything
        var stages: Set<Stage> {
            switch self {
            case .agent: return [.think, .review]
            case .editor: return [.make, .run]
            case .everything: return Set(pinnable)
            }
        }
        var title: String {
            switch self {
            case .agent: return "Agent"
            case .editor: return "Editor"
            case .everything: return "Everything"
            }
        }
    }

    nonisolated(unsafe) static var defaults: UserDefaults = HeronDefaults.store

    static var pinned: Set<Stage> {
        get {
            guard let raw = defaults.stringArray(forKey: defaultsKey) else { return Set(pinnable) }
            let stages = Set(raw.compactMap(Stage.init(rawValue:)).filter(pinnable.contains))
            return stages.isEmpty ? Set(pinnable) : stages
        }
        set {
            // At least one stays pinned — a control with nothing in it is a stranded user.
            guard !newValue.isEmpty else { return }
            defaults.set(pinnable.filter(newValue.contains).map(\.rawValue), forKey: defaultsKey)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    static func toggle(_ stage: Stage) {
        var set = pinned
        if set.contains(stage) { set.remove(stage) } else { set.insert(stage) }
        pinned = set
    }

    /// The control's contents, in order: pinned stages; then any unpinned stage with something
    /// that needs the user and hasn't been visited since; then the current stage if the user is
    /// on an unpinned one (it stays until they navigate away).
    static func visible(pinned: Set<Stage>, attention: Set<Stage>, dismissed: Set<Stage>, current: Stage?) -> [Stage] {
        var result = pinnable.filter(pinned.contains)
        for stage in pinnable where !pinned.contains(stage) {
            if attention.contains(stage) && !dismissed.contains(stage) { result.append(stage) }
            else if stage == current { result.append(stage) }
        }
        return result
    }
}
