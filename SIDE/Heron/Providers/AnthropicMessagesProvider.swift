import Foundation

/// Adapter for Anthropic's Messages API (`POST /v1/messages`, SSE streaming). Every
/// Anthropic-only concern — the `x-api-key`/`anthropic-version` headers, the Messages event
/// vocabulary (`content_block_start`/`content_block_delta`/…) — lives inside this file and
/// is translated into Heron's normalized AgentStreamEvent before anything else sees it.
final class AnthropicMessagesProvider: ChatModelProvider {
    private let apiKey: String
    private let modelId: String
    private let baseURL: URL
    private let maxTokens: Int
    private let effort: AgentEffort

    init(
        apiKey: String, modelId: String, baseURL: URL = URL(string: "https://api.anthropic.com")!,
        maxTokens: Int = 8192, effort: AgentEffort = .standard
    ) {
        self.apiKey = apiKey
        self.modelId = modelId
        self.baseURL = baseURL
        // Extended thinking spends tokens before the answer starts, so the budget form's
        // ceiling has to make room for both — see `AgentEffort.anthropicMaxTokens`. Adaptive
        // thinking manages its own, so the ceiling stays where it was.
        self.maxTokens = Self.usesAdaptiveThinking(modelId: modelId) ? maxTokens : effort.anthropicMaxTokens(base: maxTokens)
        self.effort = effort
    }

    var capabilities: ProviderCapabilities {
        ProviderCapabilities(supportsToolUse: true, supportsStreaming: true, contextWindowTokens: 200_000, supportsPromptCaching: true)
    }

    func streamTurn(
        messages: [AgentMessage],
        system: String?,
        tools: [ToolSpec],
        onEvent: @escaping @Sendable (AgentStreamEvent) -> Void
    ) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/messages"))
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody(messages: messages, system: system, tools: tools))

        let state = TurnState()
        do {
            try await SSEHTTPClient.stream(request: request) { sse in
                Self.handle(sse: sse, state: state, onEvent: onEvent)
            }
        } catch let error as SSEHTTPClientError {
            // Non-200 responses are provider-level failures (bad key, rate limit, overloaded)
            // — per the ChatModelProvider contract they surface as an .error event, not a
            // throw. The body is Anthropic's own error JSON when it can be parsed.
            guard case .httpError(let statusCode, let body) = error else { throw error }
            onEvent(.error(Self.providerError(fromHTTPStatus: statusCode, body: body)))
        }
    }

    /// Model-family check rather than a capability flag on `ProviderModel`: the split is
    /// Anthropic's own API-version detail, so it belongs in Anthropic's adapter. A BYOK provider
    /// naming a Claude 5 model gets the same treatment, which is what you want.
    static func usesAdaptiveThinking(modelId: String) -> Bool {
        ["claude-opus-5", "claude-sonnet-5", "claude-fable-5"].contains { modelId.hasPrefix($0) }
    }

    // MARK: - Request building

    private func requestBody(messages: [AgentMessage], system: String?, tools: [ToolSpec]) -> [String: Any] {
        var body: [String: Any] = [
            "model": modelId,
            "max_tokens": maxTokens,
            "stream": true,
            // System messages never appear in the messages array — Anthropic takes the
            // system prompt as a top-level field, so .system roles are filtered below.
            "messages": messages.filter { $0.role != .system }.map { message -> [String: Any] in
                [
                    // Anthropic has no "tool" role — tool results travel as content blocks
                    // inside a user message.
                    "role": message.role == .assistant ? "assistant" : "user",
                    "content": message.content.map(Self.contentBlockJSON),
                ]
            },
        ]
        if let system, !system.isEmpty { body["system"] = system }
        if !tools.isEmpty {
            body["tools"] = tools.map { ["name": $0.name, "description": $0.description, "input_schema": $0.inputSchema.anyValue] }
        }
        // Omitted entirely at `.standard`: the API rejects a budget below its minimum, so
        // "no thinking" has to mean "no block," not "a zero budget."
        //
        // Which shape depends on the model, and this was found the only way it could be — by a
        // real request coming back rejected: Claude 5 refuses `thinking.type.enabled` and asks
        // for `thinking.type.adaptive` + `output_config.effort`, while 4.x only knows the
        // budget form.
        if Self.usesAdaptiveThinking(modelId: modelId) {
            if let effortName = effort.anthropicOutputEffort {
                body["thinking"] = ["type": "adaptive"]
                body["output_config"] = ["effort": effortName]
            }
        } else if let budget = effort.anthropicThinkingBudget {
            body["thinking"] = ["type": "enabled", "budget_tokens": budget]
        }
        return body
    }

    private static func contentBlockJSON(_ block: AgentContentBlock) -> [String: Any] {
        switch block {
        case .text(let text):
            return ["type": "text", "text": text]
        case .toolUse(let id, let name, let input):
            return ["type": "tool_use", "id": id, "name": name, "input": input.anyValue]
        case .toolResult(let toolUseId, let content, let isError):
            return ["type": "tool_result", "tool_use_id": toolUseId, "content": content, "is_error": isError]
        }
    }

    // MARK: - Stream parsing

    /// Per-turn accumulation across SSE frames. Only ever touched from the SSE callback,
    /// which SSEHTTPClient invokes serially from the awaiting task — no synchronization
    /// needed.
    private final class TurnState {
        var toolUseIdsByIndex: [Int: String] = [:]
        var stopReason: StopReason = .endTurn
        var inputTokens: Int?
        var cachedInputTokens: Int?
        var outputTokens: Int?
    }

    private static func handle(sse: SSEEvent, state: TurnState, onEvent: (AgentStreamEvent) -> Void) {
        guard let data = sse.data.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        switch sse.event ?? (object["type"] as? String) ?? "" {
        case "message_start":
            if let message = object["message"] as? [String: Any], let usage = message["usage"] as? [String: Any] {
                state.inputTokens = usage["input_tokens"] as? Int
                state.cachedInputTokens = usage["cache_read_input_tokens"] as? Int
            }
        case "content_block_start":
            // Text blocks need no start marker — their deltas carry everything. Tool-use
            // blocks do: the id/name arrive here and only the input streams as deltas, and
            // deltas are keyed by block *index* on the wire, so remember index → id.
            if let index = object["index"] as? Int,
               let block = object["content_block"] as? [String: Any],
               block["type"] as? String == "tool_use",
               let id = block["id"] as? String, let name = block["name"] as? String {
                state.toolUseIdsByIndex[index] = id
                onEvent(.toolUseStart(id: id, name: name))
            }
        case "content_block_delta":
            guard let delta = object["delta"] as? [String: Any] else { return }
            switch delta["type"] as? String {
            case "text_delta":
                if let text = delta["text"] as? String { onEvent(.textDelta(text)) }
            case "input_json_delta":
                if let index = object["index"] as? Int, let id = state.toolUseIdsByIndex[index],
                   let partial = delta["partial_json"] as? String {
                    onEvent(.toolUseInputDelta(id: id, partialJSON: partial))
                }
            default:
                break
            }
        case "content_block_stop":
            if let index = object["index"] as? Int, let id = state.toolUseIdsByIndex[index] {
                onEvent(.toolUseEnd(id: id))
            }
        case "message_delta":
            if let delta = object["delta"] as? [String: Any], let raw = delta["stop_reason"] as? String {
                state.stopReason = stopReason(from: raw)
            }
            if let usage = object["usage"] as? [String: Any] {
                state.outputTokens = usage["output_tokens"] as? Int
            }
        case "message_stop":
            let usage = TokenUsage(inputTokens: state.inputTokens ?? 0, outputTokens: state.outputTokens ?? 0, cachedInputTokens: state.cachedInputTokens)
            onEvent(.messageEnd(stopReason: state.stopReason, usage: usage))
        case "error":
            let error = object["error"] as? [String: Any]
            onEvent(.error(AgentProviderError(message: error?["message"] as? String ?? "Unknown provider error", typeSlug: error?["type"] as? String)))
        default:
            break // ping and future event types
        }
    }

    private static func stopReason(from raw: String) -> StopReason {
        switch raw {
        case "end_turn": return .endTurn
        case "tool_use": return .toolUse
        case "max_tokens": return .maxTokens
        case "stop_sequence": return .stopSequence
        default: return .other(raw)
        }
    }

    private static func providerError(fromHTTPStatus statusCode: Int, body: String) -> AgentProviderError {
        if let data = body.data(using: .utf8),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let error = object["error"] as? [String: Any],
           let message = error["message"] as? String {
            return AgentProviderError(message: message, typeSlug: error["type"] as? String)
        }
        return AgentProviderError(message: "HTTP \(statusCode): \(body.prefix(500))", typeSlug: nil)
    }
}
