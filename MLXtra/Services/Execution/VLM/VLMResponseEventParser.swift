import Foundation

struct VLMParsedResponseEvents {
    let events: [ExecutionEvent]
    let finishesStream: Bool
}

final class VLMResponseEventParser: @unchecked Sendable {
    private let modelId: String
    private let backend: RuntimeBackend
    private let responseBuilder: ResponseBuilder

    init(
        modelId: String,
        backend: RuntimeBackend,
        responseBuilder: ResponseBuilder = ResponseBuilder()
    ) {
        self.modelId = modelId
        self.backend = backend
        self.responseBuilder = responseBuilder
    }

    static func handles(_ json: BridgeJSONMessage) -> Bool {
        guard let type = json["type"] as? String else { return false }
        switch type {
        case "chat.completion.chunk",
             "chat.completion.complete",
             "chat.completion.tool_calls",
             "image.generated",
             "audio.generated",
             "model.loading",
             "model.loaded",
             "error":
            return true
        default:
            return false
        }
    }

    func parse(_ json: BridgeJSONMessage) -> VLMParsedResponseEvents? {
        guard let type = json["type"] as? String else { return nil }

        switch type {
        case "chat.completion.chunk":
            guard let content = chunkContent(from: json) else {
                return VLMParsedResponseEvents(events: [], finishesStream: false)
            }
            responseBuilder.append(content)
            return VLMParsedResponseEvents(events: [.token(content)], finishesStream: false)

        case "chat.completion.complete":
            let tokenUsage = Self.tokenUsage(from: json)
            return VLMParsedResponseEvents(
                events: [.complete(completedContent(from: json), usage: tokenUsage)],
                finishesStream: true
            )

        case "chat.completion.tool_calls":
            guard let toolCallDicts = json["tool_calls"] as? [[String: Any]] else {
                return VLMParsedResponseEvents(events: [], finishesStream: false)
            }
            let parsedToolCalls = toolCallDicts.compactMap(Self.executionToolCall(from:))
            let events: [ExecutionEvent] = parsedToolCalls.isEmpty ? [] : [.toolCalls(parsedToolCalls)]
            return VLMParsedResponseEvents(events: events, finishesStream: true)

        case "image.generated":
            guard let path = json["path"] as? String else {
                return VLMParsedResponseEvents(events: [], finishesStream: false)
            }
            return VLMParsedResponseEvents(events: [.image(URL(fileURLWithPath: path))], finishesStream: false)

        case "audio.generated":
            guard let path = json["path"] as? String else {
                return VLMParsedResponseEvents(events: [], finishesStream: false)
            }
            return VLMParsedResponseEvents(events: [.audio(URL(fileURLWithPath: path))], finishesStream: false)

        case "model.loading":
            let progress = ModelLoadProgress.bridgeEvent(
                json,
                fallbackModelId: modelId,
                fallbackBackend: backend
            )
            return VLMParsedResponseEvents(
                events: [
                    .progress(progress.detail ?? progress.phase.displayTitle),
                    .modelLoadProgress(progress)
                ],
                finishesStream: false
            )

        case "model.loaded":
            return VLMParsedResponseEvents(events: [], finishesStream: false)

        case "error":
            let errorMessage = json["message"] as? String ?? "Unknown Python error"
            return VLMParsedResponseEvents(
                events: [.error(ExecutionError.pythonError(errorMessage))],
                finishesStream: true
            )

        default:
            return nil
        }
    }

    private func completedContent(from json: BridgeJSONMessage) -> String {
        if responseBuilder.fullResponse.isEmpty,
           let choices = json["choices"] as? [[String: Any]],
           let first = choices.first,
           let message = first["message"] as? [String: Any],
           let content = message["content"] as? String {
            return content
        }

        return responseBuilder.fullResponse
    }

    private static func tokenUsage(from json: BridgeJSONMessage) -> TokenUsage {
        let usage = json["usage"] as? [String: Any]
        let performance = json["performance"] as? [String: Any]
        return TokenUsage(
            promptTokens: usage?["prompt_tokens"] as? Int ?? 0,
            completionTokens: usage?["completion_tokens"] as? Int ?? 0,
            promptTokensPerSecond: bridgeDouble(performance?["prompt_tokens_per_second"]),
            generationTokensPerSecond: bridgeDouble(performance?["generation_tokens_per_second"])
                ?? bridgeDouble(performance?["tokens_per_second"]),
            peakMemoryGB: bridgeDouble(performance?["peak_memory_gb"]),
            accelerationState: accelerationState(from: json)
        )
    }

    private static func accelerationState(from json: BridgeJSONMessage) -> GenerationAccelerationState? {
        guard let acceleration = json["acceleration"] as? [String: Any] else { return nil }
        if let state = acceleration["state"] as? String {
            return GenerationAccelerationState(rawValue: state)
        }

        guard (acceleration["requested"] as? Bool) == true else { return nil }
        if (acceleration["active"] as? Bool) == true {
            return .active
        }
        return .unavailable
    }

    private static func executionToolCall(from dict: [String: Any]) -> ExecutionToolCall? {
        guard let id = dict["id"] as? String,
              let function = dict["function"] as? [String: Any],
              let name = function["name"] as? String,
              let arguments = function["arguments"] as? String else {
            return nil
        }

        return ExecutionToolCall(
            id: id,
            function: ExecutionToolCallFunction(name: name, arguments: arguments)
        )
    }

    private func chunkContent(from json: BridgeJSONMessage) -> String? {
        guard let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let delta = first["delta"] as? [String: Any] else {
            return nil
        }

        return delta["content"] as? String
    }
}
