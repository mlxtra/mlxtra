import Foundation

enum VLMRequestPayloadBuilder {
    static func executionPayload(for request: ExecutionRequest) -> [String: Any] {
        var payload: [String: Any] = [
            "request_id": request.requestID,
            "type": messageType(for: request.backend),
            "model": request.modelId,
            "messages": request.messages.map { $0.toDictionary() },
            "max_tokens": request.maxTokens,
            "temperature": request.temperature,
            "images": request.images?.map(\.path) ?? []
        ]

        if let outputDirectory = request.outputDirectory {
            payload["output_dir"] = outputDirectory.path
        }
        if let topP = request.topP {
            payload["top_p"] = topP
        }
        if let topK = request.topK {
            payload["top_k"] = topK
        }
        if let minP = request.minP {
            payload["min_p"] = minP
        }
        if let repetitionPenalty = request.repetitionPenalty {
            payload["repetition_penalty"] = repetitionPenalty
        }
        if let chatTemplateKwargs = request.chatTemplateKwargs {
            payload["chat_template_kwargs"] = chatTemplateKwargs
        }
        if let tools = request.tools {
            payload["tools"] = tools
        }
        if let parameters = request.parameters {
            payload["parameters"] = parameters
        }

        return payload
    }

    static func modelLoadPayload(
        requestID: String,
        modelId: String,
        backend: RuntimeBackend,
        parameters: [String: Any]? = nil
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "request_id": requestID,
            "type": "init",
            "model_id": modelId,
            "backend": backend.rawValue
        ]

        if let parameters {
            payload["parameters"] = parameters
        }

        return payload
    }

    static func messageType(for backend: RuntimeBackend) -> String {
        switch backend {
        case .image:
            return "image.generate"
        case .audio:
            return "audio.speech"
        case .music:
            return "music.generate"
        case .vlm, .llm:
            return "chat.completions"
        }
    }
}
