import Foundation

enum ChatExecutionRequestBuilder {
    static func makeRequest(
        generation: ChatGenerationRequest,
        activeChatProfile: ModelCapabilityProfile,
        executionProfile: ModelCapabilityProfile,
        messages: [ExecutionMessage],
        tools: [[String: Any]]?,
        outputDirectory: URL?,
        contextImages: [URL] = [],
        responseFormat: [String: Any]? = nil
    ) -> ExecutionRequest {
        let isDirectMediaGeneration = executionProfile.backend == .image || executionProfile.backend == .audio
        let requestImages = requestImages(
            generationImages: generation.images,
            contextImages: contextImages,
            includeContextImages: !isDirectMediaGeneration && tools == nil
        )
        let chatExecutionParameters = generation.executionParameters(for: activeChatProfile)
        let runtimeExecutionParameters = isDirectMediaGeneration
            ? nil
            : generation.runtimeExecutionParameters(for: activeChatProfile)
        let mediaExecutionParameters = isDirectMediaGeneration
            ? generation.executionParameters(for: executionProfile)
            : nil
        let chatTemplateKwargs = shouldUseChatTemplateKwargs(
            for: generation,
            isDirectMediaGeneration: isDirectMediaGeneration
        )
            ? generation.chatTemplateKwargs(for: activeChatProfile)
            : nil
        let imageCaption = executionProfile.backend == .image
            ? generation.directIdeogramCaption
            : nil

        let maxTokens = (chatExecutionParameters["max_tokens"] as? Int)
            ?? activeChatProfile.defaultMaxTokens
        let temperature = (chatExecutionParameters["temperature"] as? Double)
            ?? activeChatProfile.doubleParameterDefault("temperature", fallback: 0.7)
        let topP = (chatExecutionParameters["top_p"] as? Double)
            ?? activeChatProfile.doubleParameterDefault("top_p", fallback: 1.0)
        let topK = (chatExecutionParameters["top_k"] as? Int)
            ?? activeChatProfile.intParameterDefault("top_k", fallback: 0)
        let minP = (chatExecutionParameters["min_p"] as? Double)
            ?? activeChatProfile.doubleParameterDefault("min_p", fallback: 0)
        let repetitionPenalty = (chatExecutionParameters["repetition_penalty"] as? Double)
            ?? activeChatProfile.doubleParameterDefault("repetition_penalty", fallback: 1.0)

        return ExecutionRequest(
            backend: executionProfile.backend,
            modelId: executionProfile.modelId,
            messages: isDirectMediaGeneration
                ? [ExecutionMessage(role: .user, content: generation.prompt)]
                : messages,
            images: requestImages.isEmpty ? nil : requestImages,
            imageCaption: imageCaption,
            outputDirectory: outputDirectory,
            maxTokens: isDirectMediaGeneration ? 0 : maxTokens,
            temperature: isDirectMediaGeneration ? 1.0 : temperature,
            topP: isDirectMediaGeneration ? nil : topP,
            topK: isDirectMediaGeneration ? nil : topK,
            minP: isDirectMediaGeneration ? nil : minP,
            repetitionPenalty: isDirectMediaGeneration ? nil : repetitionPenalty,
            chatTemplateKwargs: chatTemplateKwargs,
            tools: tools,
            responseFormat: responseFormat,
            parameters: mediaExecutionParameters ?? runtimeExecutionParameters
        )
    }

    private static func shouldUseChatTemplateKwargs(
        for generation: ChatGenerationRequest,
        isDirectMediaGeneration: Bool
    ) -> Bool {
        !isDirectMediaGeneration && !generation.isMusicGeneration
    }

    private static func requestImages(
        generationImages: [URL],
        contextImages: [URL],
        includeContextImages: Bool
    ) -> [URL] {
        var seen = Set<String>()
        let candidates = (includeContextImages ? contextImages : []) + generationImages
        return candidates.filter { url in
            seen.insert(url.standardizedFileURL.path).inserted
        }
    }
}
