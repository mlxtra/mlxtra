import Foundation

struct ChatSidebarMetadata {
    let icon: String
    let preview: String
}

struct ChatGenerationRequest {
    let chatId: UUID
    let prompt: String
    let images: [URL]
    let tool: Tool
    let profilesByModality: [ModelModality: ModelCapabilityProfile]
    let parametersByModelId: [String: [String: Any]]
    let selectionDownloadRequirement: DownloadableModel?
    let selectionOperationName: String

    var isImageGeneration: Bool { tool == .image }
    var isSpeechGeneration: Bool { tool == .tts }
    var isMusicGeneration: Bool { tool == .music }
    var isDeepResearch: Bool { tool == .research }
    var shouldPrepareDirectImagePrompt: Bool {
        let imageProfile = profile(for: .image)
        guard isImageGeneration else { return false }
        if imageProfile.imagePromptAdapter == .ideogram4JSON,
           directIdeogramCaption != nil {
            return false
        }
        return shouldPrepareImagePrompt(for: imageProfile)
    }

    var directIdeogramCaption: [String: Any]? {
        let imageProfile = profile(for: .image)
        guard isImageGeneration,
              imageProfile.imagePromptAdapter == .ideogram4JSON else {
            return nil
        }
        if case .caption(let caption) = ChatMediaToolPlanBuilder.ideogramCaptionInput(from: prompt) {
            return caption
        }
        return nil
    }

    var ideogramCaptionFallbackReason: String? {
        let imageProfile = profile(for: .image)
        guard isImageGeneration,
              imageProfile.imagePromptAdapter == .ideogram4JSON else {
            return nil
        }
        if case .invalid(let reason) = ChatMediaToolPlanBuilder.ideogramCaptionInput(from: prompt) {
            return reason
        }
        return nil
    }

    func profile(for tool: Tool) -> ModelCapabilityProfile {
        let modality = Self.modelModality(for: tool)
        return profilesByModality[modality] ?? ModelCapabilityProfile.fallbackProfile(for: modality)
    }

    func executionParameters(for profile: ModelCapabilityProfile) -> [String: Any] {
        profile.executionParameters(merging: parametersByModelId[profile.modelId] ?? [:])
    }

    func shouldImproveImagePrompt(for profile: ModelCapabilityProfile) -> Bool {
        (parametersByModelId[profile.modelId]?["improve_prompt"] as? Bool)
            ?? profile.boolParameterDefault("improve_prompt", fallback: false)
    }

    func shouldPrepareImagePrompt(for profile: ModelCapabilityProfile) -> Bool {
        profile.imagePromptAdapter != .plainText || shouldImproveImagePrompt(for: profile)
    }

    func imageDimension(_ key: String, for profile: ModelCapabilityProfile, fallback: Int = 1024) -> Int {
        (parametersByModelId[profile.modelId]?[key] as? Int)
            ?? profile.intParameterDefault(key, fallback: fallback)
    }

    func runtimeExecutionParameters(for profile: ModelCapabilityProfile) -> [String: Any]? {
        let runtimeOptions = profile.runtimeExecutionOptions()
        guard !runtimeOptions.isEmpty else { return nil }
        return ["runtimeOptions": runtimeOptions]
    }

    func chatTemplateKwargs(for profile: ModelCapabilityProfile) -> [String: Any]? {
        profile.runtimeOptions?.chatTemplateKwargs(from: executionParameters(for: profile))
    }

    static func modelModality(for tool: Tool) -> ModelModality {
        switch tool {
        case .auto, .chat, .research:
            return .vision
        case .image:
            return .image
        case .tts:
            return .audio
        case .music:
            return .music
        }
    }
}
