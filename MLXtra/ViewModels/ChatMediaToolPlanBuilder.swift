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
        let promptArgument = nonEmptyStringArgument("prompt", from: decodedArguments)
        let promptArgumentIsCaption = imageProfile.imagePromptAdapter == .ideogram4JSON
            && promptArgument.map { prompt in
                if case .caption = ideogramCaptionInput(from: prompt) {
                    return true
                }
                return false
            } == true
        let imagePrompt = (promptArgumentIsCaption ? nil : promptArgument)
            ?? nonEmptyStringArgument("high_level_description", from: imageCaption)
            ?? promptArgument
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
        if let promptCaption = arguments?["prompt"] as? [String: Any] {
            return promptCaption
        }
        let captionText = nonEmptyStringArgument("caption", from: arguments)
            ?? nonEmptyStringArgument("prompt", from: arguments)
        guard let captionText,
              case .caption(let caption) = ideogramCaptionInput(from: captionText) else {
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
        let parameters = generation.executionParameters(for: speechProfile)
        let preflightErrorMessage = speechPreflightError(profile: speechProfile, parameters: parameters)
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
                parameters: parameters
            ),
            preflightErrorMessage: preflightErrorMessage,
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

    private static func speechPreflightError(
        profile: ModelCapabilityProfile,
        parameters: [String: Any]
    ) -> String? {
        guard profile.modelId == "bosonai/higgs-audio-v3-tts-4b" else { return nil }
        let voice = String(describing: parameters["voice"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
        guard voice == "custom_reference" else { return nil }
        guard let referenceAudioDefinition = profile.parameterDefinition(key: "ref_audio") else {
            return "Custom Reference voice requires a local reference audio file."
        }
        let referenceAudio = String(describing: parameters["ref_audio"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !referenceAudio.isEmpty else {
            return "Custom Reference voice requires a local reference audio file."
        }
        guard referenceAudioDefinition.normalizedString(from: referenceAudio) != nil else {
            return "Custom Reference voice requires a WAV, MP3, or FLAC reference audio file."
        }

        let referenceAudioURL = URL(fileURLWithPath: referenceAudio)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: referenceAudioURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return "Custom Reference voice reference audio file was not found."
        }
        guard FileManager.default.isReadableFile(atPath: referenceAudioURL.path) else {
            return "Custom Reference voice reference audio file is not readable."
        }
        return nil
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
