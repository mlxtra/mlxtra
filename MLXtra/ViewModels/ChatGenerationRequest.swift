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
    let selectedModel: AIModel
    let profilesByModality: [ModelModality: ModelCapabilityProfile]
    let parametersByModelId: [String: [String: Any]]
    let selectionDownloadRequirement: DownloadableModel?
    let selectionOperationName: String

    var isImageGeneration: Bool { tool == .image }
    var isSpeechGeneration: Bool { tool == .tts }
    var isMusicGeneration: Bool { tool == .music }
    var isDeepResearch: Bool { tool == .research }

    func profile(for tool: Tool) -> ModelCapabilityProfile {
        let modality = Self.modelModality(for: tool)
        guard let profile = profilesByModality[modality] else {
            preconditionFailure("Missing generation profile for \(modality.rawValue)")
        }
        return profile
    }

    func executionParameters(for profile: ModelCapabilityProfile) -> [String: Any] {
        parametersByModelId[profile.modelId] ?? [:]
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
