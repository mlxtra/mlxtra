import Foundation

enum ChatMediaToolPlanBuilder {
    enum IdeogramCaptionInput {
        case caption([String: Any])
        case invalid(reason: String)
        case plainPrompt
    }

    static func makeImagePlan(
        decodedArguments: [String: Any]?,
        fallbackPrompt: String,
        images: [URL],
        generation: ChatGenerationRequest,
        outputDirectory: URL
    ) -> ChatMediaToolExecutionPlan {
        let imageProfile = generation.profile(for: .image)
        let imageCaption = imageProfile.imagePromptAdapter == .ideogram4JSON
            ? structuredImageCaption(from: decodedArguments)
            : nil
        let imagePrompt = nonEmptyStringArgument("prompt", from: decodedArguments)
            ?? nonEmptyStringArgument("high_level_description", from: imageCaption)
            ?? fallbackPrompt
        let details = imageCaption.flatMap(structuredCaptionDetail).map { [$0] } ?? []
        let supportedImages = imageProfile.supportsImageEditing ? images : []
        let model = imageProfile.downloadableModel

        return ChatMediaToolExecutionPlan(
            functionName: "generate_image",
            toolName: "Image generation",
            status: imagePrompt,
            icon: "photo",
            details: details,
            model: model,
            request: ExecutionRequest(
                backend: .image,
                modelId: imageProfile.modelId,
                messages: [ExecutionMessage(role: .user, content: imagePrompt)],
                images: supportedImages.isEmpty ? nil : supportedImages,
                imageCaption: imageCaption,
                outputDirectory: outputDirectory,
                maxTokens: 0,
                temperature: 1.0,
                parameters: generation.executionParameters(for: imageProfile)
            ),
            loadingStatus: "Generating image...",
            operationName: "Image generation",
            unavailablePrefix: "Image generation unavailable",
            noOutputMessage: "Image generation finished without returning an image.",
            completionHint: "The generated image is already displayed in the app UI. In your final response, use text only. Do not include markdown image syntax, image URLs, local file paths, HTML image tags, data URLs, or links to external image services such as Pollinations.",
            attachmentKind: .image
        )
    }

    static func resolvedImagePrompt(
        decodedArguments: [String: Any]?,
        fallbackPrompt: String
    ) -> String {
        nonEmptyStringArgument("prompt", from: decodedArguments) ?? fallbackPrompt
    }

    static func structuredImageCaption(from arguments: [String: Any]?) -> [String: Any]? {
        if let caption = arguments?["caption"] as? [String: Any] {
            return caption
        }
        guard let captionText = arguments?["caption"] as? String,
              let data = captionText.data(using: .utf8),
              let caption = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return caption
    }

    static func ideogramCaptionInput(from prompt: String) -> IdeogramCaptionInput {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedPrompt.hasPrefix("{") else {
            return .plainPrompt
        }
        guard let data = trimmedPrompt.data(using: .utf8),
              var caption = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .invalid(reason: "JSON could not be parsed.")
        }
        if let wrappedCaption = structuredImageCaption(from: caption) {
            caption = wrappedCaption
        }
        guard let composition = caption["compositional_deconstruction"] as? [String: Any] else {
            return .invalid(reason: "Missing compositional_deconstruction.")
        }
        guard let background = composition["background"] as? String,
              !background.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .invalid(reason: "compositional_deconstruction.background must be a non-empty string.")
        }
        guard composition["elements"] is [Any] else {
            return .invalid(reason: "compositional_deconstruction.elements must be an array.")
        }
        return .caption(caption)
    }

    static func makeSpeechPlan(
        decodedArguments: [String: Any]?,
        fallbackPrompt: String,
        generation: ChatGenerationRequest,
        outputDirectory: URL
    ) -> ChatMediaToolExecutionPlan {
        let speechText = nonEmptyStringArgument("text", from: decodedArguments) ?? fallbackPrompt
        let speechProfile = generation.profile(for: .tts)
        let model = speechProfile.downloadableModel

        return ChatMediaToolExecutionPlan(
            functionName: "create_speech",
            toolName: "Speech generation",
            status: speechText,
            icon: "waveform",
            details: [],
            model: model,
            request: ExecutionRequest(
                backend: .audio,
                modelId: speechProfile.modelId,
                messages: [ExecutionMessage(role: .user, content: speechText)],
                outputDirectory: outputDirectory,
                maxTokens: 0,
                temperature: 1.0,
                parameters: generation.executionParameters(for: speechProfile)
            ),
            loadingStatus: "Generating speech...",
            operationName: "Speech generation",
            unavailablePrefix: "Speech generation unavailable",
            noOutputMessage: "Speech generation finished without returning audio.",
            completionHint: "The generated audio is already displayed in the app UI. In your final response, use text only. Do not include local file paths.",
            attachmentKind: .audio
        )
    }

    private static func nonEmptyStringArgument(_ key: String, from arguments: [String: Any]?) -> String? {
        guard let value = arguments?[key] as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    private static func structuredCaptionDetail(_ caption: [String: Any]) -> ToolCallDetail? {
        guard JSONSerialization.isValidJSONObject(caption),
              let data = try? JSONSerialization.data(
                withJSONObject: caption,
                options: [.prettyPrinted]
              ),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return ToolCallDetail(label: "Structured caption", value: json)
    }
}
