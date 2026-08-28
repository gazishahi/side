import Foundation

// Heron's normalized core: every provider adapter translates its own wire shape into these
// types and nothing above the adapter layer ever sees a provider-specific field. Anthropic
// quirks live in AnthropicMessagesProvider; OpenAI-compatible quirks will live in that
// adapter when it lands (Phase 6) — never here.

/// One JSON value of arbitrary shape. Needed because tool-call arguments are arbitrary JSON
/// decided by the model at runtime — unlike LSP params, which are always statically typed
/// Swift structs, so nothing in the LSP layer ever needed this.
enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let string): try container.encode(string)
        case .number(let number): try container.encode(number)
        case .bool(let bool): try container.encode(bool)
        case .null: try container.encodeNil()
        case .array(let array): try container.encode(array)
        case .object(let object): try container.encode(object)
        }
    }

    /// Bridge to JSONSerialization's world — adapters build request bodies as [String: Any]
    /// dictionaries, and tool inputs embedded in them need to cross over.
    var anyValue: Any {
        switch self {
        case .string(let string): return string
        case .number(let number): return number
        case .bool(let bool): return bool
        case .null: return NSNull()
        case .array(let array): return array.map(\.anyValue)
        case .object(let object): return object.mapValues(\.anyValue)
        }
    }
}

struct AgentMessage: Codable, Sendable {
    enum Role: String, Codable, Sendable { case system, user, assistant, tool }
    var role: Role
    var content: [AgentContentBlock]
}

enum AgentContentBlock: Codable, Sendable {
    case text(String)
    case toolUse(id: String, name: String, input: JSONValue)
    case toolResult(toolUseId: String, content: String, isError: Bool)
    /// A user-attached image, inline as base64. Inline rather than a file reference on purpose:
    /// the image is *part of the conversation* — it must survive with the turn, ride every
    /// replay, and vanish with compaction, all of which fall out of storing it in the turn
    /// itself. The composer downscales before attaching (longest side ≤ 1568px, the API's
    /// sweet spot), which keeps a screenshot to a few hundred KB.
    case image(mediaType: String, base64: String)
}

/// What the composer hands the runner per attached image — already downscaled and encoded.
struct AgentImageAttachment: Sendable {
    let mediaType: String
    let base64: String
}

struct ToolSpec: Codable, Sendable {
    let name: String
    let description: String
    /// JSON Schema, kept as raw JSON — both target wire formats (Anthropic `input_schema`,
    /// OpenAI `parameters`) accept the same schema object verbatim.
    let inputSchema: JSONValue
}

enum StopReason: Sendable {
    case endTurn, toolUse, maxTokens, stopSequence
    case other(String)
}

struct TokenUsage: Sendable {
    let inputTokens: Int
    let outputTokens: Int
    let cachedInputTokens: Int?
}

/// Provider-level failure (bad key, rate limit, overloaded) — distinct from transport-level
/// failure, which `streamTurn` throws instead. A caller mid-stream needs to know *when* in
/// the stream a provider error happened, which is why these arrive as events.
struct AgentProviderError: Error, Sendable {
    let message: String
    /// Provider-specific error slug when one was given, e.g. "authentication_error".
    let typeSlug: String?
}

enum AgentStreamEvent: Sendable {
    case textDelta(String)
    case toolUseStart(id: String, name: String)
    case toolUseInputDelta(id: String, partialJSON: String)
    case toolUseEnd(id: String)
    case messageEnd(stopReason: StopReason, usage: TokenUsage?)
    case error(AgentProviderError)
}

/// Static capability description the UI and tool layer can inspect without a network call —
/// e.g. to know whether to even offer tool-use for a model. Local servers will override these
/// via their registry entry (Phase 6).
struct ProviderCapabilities: Sendable {
    let supportsToolUse: Bool
    let supportsStreaming: Bool
    let contextWindowTokens: Int
    let supportsPromptCaching: Bool
}

protocol ChatModelProvider {
    var capabilities: ProviderCapabilities { get }

    /// One streaming turn. `onEvent` fires on an arbitrary background context; callers hop to
    /// main themselves, same convention LSPManager already uses. Throws only for
    /// transport-level failure — provider-level errors arrive as `.error` events instead.
    /// Streaming-only by design: a non-streaming call is just "stream and buffer," which a
    /// caller can do trivially, so the protocol doesn't carry the extra surface.
    func streamTurn(
        messages: [AgentMessage],
        system: String?,
        tools: [ToolSpec],
        onEvent: @escaping @Sendable (AgentStreamEvent) -> Void
    ) async throws
}
