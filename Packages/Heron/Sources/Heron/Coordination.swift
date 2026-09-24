import Foundation

/// Multi-agent work (`SIDE_RFC_MULTI_AGENT.md`, step 2): a coordinator track hands parts of its
/// task to subtracks, each on any agent, and reads their results back. Everything here is a
/// track creating and reading tracks; there is no agent-to-agent channel besides the
/// coordinator's own, visible messages (M4).

/// What a coordinator asks for when it creates a subtrack.
public struct SubtrackRequest: Equatable, Sendable {
    public let intent: String
    /// An `ACPAgent.id`, or nil for Heron.
    public let agentId: String?
    /// The subtrack's first message.
    public let instructions: String

    public init(intent: String, agentId: String?, instructions: String) {
        self.intent = intent
        self.agentId = agentId
        self.instructions = instructions
    }
}

/// Implemented by the app, which owns tracks and their agents. Main-actor: every call reads or
/// changes track state.
@MainActor
public protocol TrackCoordinating: AnyObject {
    /// Whether a track may coordinate at all: not a subtrack itself (one level deep, M3).
    func canCoordinate(trackKey: String) -> Bool
    /// Why `parentKey` can't create a subtrack right now (M3: 4 live children, one level deep),
    /// or nil if it can.
    func spawnRefusal(parentKey: String) -> String?
    /// Creates the subtrack (its own branch and worktree, never switching anyone's view), starts
    /// its agent on the instructions, and reports what happened.
    func createSubtrack(parentKey: String, request: SubtrackRequest, completion: @escaping (String) -> Void)
    /// Sends one of `parentKey`'s own children a message (queued if it's mid-turn).
    func message(parentKey: String, trackKey: String, text: String) -> String
    /// A child's status, last reply, checkpoints and their verification.
    func read(parentKey: String, trackKey: String) -> String
    /// Whether a child has stopped working (finished, blocked, or waiting on the user).
    func isSettled(parentKey: String, trackKey: String) -> Bool
    /// The agents a subtrack can run on: (id to pass, name). "heron" is Heron.
    var agentChoices: [(id: String, name: String)] { get }
}

/// The coordinator's tools, callable from any thread: Heron's executor and the MCP server both
/// run off the main thread. Each call hops to the main actor for the state it needs.
public struct CoordinationBridge: @unchecked Sendable {
    let parentKey: String
    /// Held weakly: the coordinator is the project's, and outlives no project.
    private final class WeakCoordinator: @unchecked Sendable {
        weak var value: (any TrackCoordinating)?
        init(_ value: any TrackCoordinating) { self.value = value }
    }
    private let box: WeakCoordinator

    public init(parentKey: String, coordinator: any TrackCoordinating) {
        self.parentKey = parentKey
        self.box = WeakCoordinator(coordinator)
    }

    /// Longest a `wait_for_tracks` call holds before answering with where things stand; the
    /// coordinator can call again. Kept short enough for an MCP client's own tool timeout.
    public static let maxWait: TimeInterval = 120

    private func onMain<T: Sendable>(_ fallback: T, _ body: @escaping @MainActor @Sendable (any TrackCoordinating) -> T) -> T {
        let box = self.box
        let work = { @Sendable () -> T in MainActor.assumeIsolated { box.value.map { body($0) } ?? fallback } }
        return Thread.isMainThread ? work() : DispatchQueue.main.sync(execute: work)
    }

    /// Creates the subtrack (after approval) and calls back with the report, from any thread.
    public func create(_ request: SubtrackRequest, completion: @escaping @Sendable (String) -> Void) {
        let (box, parentKey) = (self.box, self.parentKey)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let coordinator = box.value else { return completion("The project was closed.") }
                coordinator.createSubtrack(parentKey: parentKey, request: request) { completion($0) }
            }
        }
    }

    public func refusal() -> String? { onMain("Side can't create subtracks right now.") { $0.spawnRefusal(parentKey: parentKey) } }
    public func message(track: String, text: String) -> String { onMain("The project was closed.") { $0.message(parentKey: parentKey, trackKey: track, text: text) } }
    public func read(track: String) -> String { onMain("The project was closed.") { $0.read(parentKey: parentKey, trackKey: track) } }
    public var agentChoices: [(id: String, name: String)] {
        onMain([AgentChoice]()) { $0.agentChoices.map { AgentChoice(id: $0.id, name: $0.name) } }.map { ($0.id, $0.name) }
    }
    private struct AgentChoice: Sendable { let id: String; let name: String }

    /// Blocks the calling (background) thread until every track has settled or `timeout`
    /// passes, then reads each one.
    public func wait(tracks: [String], timeout: TimeInterval) -> String {
        let deadline = Date().addingTimeInterval(min(max(timeout, 1), Self.maxWait))
        while Date() < deadline {
            let settled = onMain(true) { coordinator in tracks.allSatisfy { coordinator.isSettled(parentKey: parentKey, trackKey: $0) } }
            if settled { break }
            Thread.sleep(forTimeInterval: 1)
        }
        let stillWorking = onMain([String]()) { coordinator in tracks.filter { !coordinator.isSettled(parentKey: parentKey, trackKey: $0) } }
        let reports = tracks.map { read(track: $0) }.joined(separator: "\n\n---\n\n")
        guard !stillWorking.isEmpty else { return reports }
        return "Still working after the wait: \(stillWorking.joined(separator: ", ")). Call wait_for_tracks again to keep waiting.\n\n" + reports
    }

    /// The four tools, as the model sees them. `create_subtrack` names the agents it can use.
    public static func toolSpecs(agentChoices: [(id: String, name: String)]) -> [ToolSpec] {
        let agents = agentChoices.map { "\($0.id) (\($0.name))" }.joined(separator: ", ")
        func schema(_ properties: [String: JSONValue], required: [String]) -> JSONValue {
            .object(["type": .string("object"), "properties": .object(properties), "required": .array(required.map { .string($0) })])
        }
        return [
            ToolSpec(
                name: "create_subtrack",
                description: "Hand part of this track's work to another agent as a subtrack: its own branch and working copy, stacked under this track, with its own checkpoints. Its work comes back when the user promotes it into this track. Use it for a separable piece of work, and say exactly what done means in the instructions. The user approves new subtracks unless the track runs on Full autonomy. At most 4 at a time; a subtrack can't create its own. Agents: \(agents).",
                inputSchema: schema([
                    "intent": .object(["type": .string("string"), "description": .string("A short title for the subtrack, like a commit subject.")]),
                    "agent": .object(["type": .string("string"), "description": .string("Which agent runs it: one of the ids listed in this tool's description.")]),
                    "instructions": .object(["type": .string("string"), "description": .string("The subtrack's first message: what to do, which files, how to verify it.")]),
                ], required: ["intent", "agent", "instructions"])
            ),
            ToolSpec(
                name: "message_track",
                description: "Send one of this track's own subtracks a message (a follow-up, a correction, an answer to its question). It appears in that subtrack's conversation as coming from you, the coordinator. Delivered when its current turn ends if it's busy.",
                inputSchema: schema([
                    "track": .object(["type": .string("string"), "description": .string("The subtrack's branch name.")]),
                    "text": .object(["type": .string("string")]),
                ], required: ["track", "text"])
            ),
            ToolSpec(
                name: "read_track",
                description: "Read one of this track's subtracks: whether it's working, finished, blocked or waiting on the user; its last reply; and its checkpoints with their verification (test results). Trust the verification over the subtrack's own account.",
                inputSchema: schema(["track": .object(["type": .string("string"), "description": .string("The subtrack's branch name.")])], required: ["track"])
            ),
            ToolSpec(
                name: "wait_for_tracks",
                description: "Wait until the given subtracks stop working (finish, block, or need the user), up to \(Int(maxWait)) seconds, then read each one. Call again if some are still working.",
                inputSchema: schema([
                    "tracks": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
                    "timeout_seconds": .object(["type": .string("number")]),
                ], required: ["tracks"])
            ),
        ]
    }

    /// Runs one of the non-spawning tools. `create_subtrack` goes through an approval card, so
    /// it isn't here.
    public func run(_ name: String, input: JSONValue) -> (output: String, isError: Bool)? {
        switch name {
        case "message_track":
            guard let track = input.text("track"), let text = input.text("text"), !text.isEmpty else {
                return ("message_track needs a track and some text.", true)
            }
            return (message(track: track, text: text), false)
        case "read_track":
            guard let track = input.text("track") else { return ("read_track needs a track.", true) }
            return (read(track: track), false)
        case "wait_for_tracks":
            let tracks = input.texts("tracks")
            guard !tracks.isEmpty else { return ("wait_for_tracks needs at least one track.", true) }
            let timeout = input.number("timeout_seconds") ?? Self.maxWait
            return (wait(tracks: tracks, timeout: timeout), false)
        default:
            return nil
        }
    }

    /// A `create_subtrack` call's arguments, or why they don't make sense.
    public func request(from input: JSONValue) -> Result<SubtrackRequest, RequestError> {
        guard let intent = input.text("intent")?.trimmingCharacters(in: .whitespacesAndNewlines), !intent.isEmpty,
              let instructions = input.text("instructions"), !instructions.isEmpty else {
            return .failure(RequestError(message: "create_subtrack needs an intent and instructions."))
        }
        let agent = (input.text("agent") ?? "heron").trimmingCharacters(in: .whitespaces).lowercased()
        let choices = agentChoices
        guard let choice = choices.first(where: { $0.id.lowercased() == agent || $0.name.lowercased() == agent }) else {
            return .failure(RequestError(message: "Unknown agent \u{201C}\(agent)\u{201D}. Use one of: \(choices.map(\.id).joined(separator: ", "))."))
        }
        return .success(SubtrackRequest(intent: intent, agentId: choice.id == "heron" ? nil : choice.id, instructions: instructions))
    }

    public struct RequestError: Error { public let message: String }
}

fileprivate extension JSONValue {
    func text(_ key: String) -> String? {
        guard case .object(let object) = self, case .string(let value)? = object[key] else { return nil }
        return value
    }
    func texts(_ key: String) -> [String] {
        guard case .object(let object) = self else { return [] }
        switch object[key] {
        case .array(let items)?: return items.compactMap { if case .string(let value) = $0 { return value } else { return nil } }
        case .string(let value)?: return [value]
        default: return []
        }
    }
    func number(_ key: String) -> Double? {
        guard case .object(let object) = self else { return nil }
        switch object[key] {
        case .number(let value)?: return value
        case .string(let value)?: return Double(value)
        default: return nil
        }
    }
}
