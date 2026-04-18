import Foundation

enum AIModel: String, CaseIterable, Identifiable {
    case qwen35 = "Qwen 3.5"
    case gemma4 = "Gemma 4"
    case mini = "Qwen 3.5 Mini"

    var id: String { rawValue }

    var displayName: String { rawValue }

    var subtitle: String {
        switch self {
        case .qwen35: return "Vision language model (9B parameters)"
        case .gemma4: return "Google vision model (4B parameters)"
        case .mini: return "Lightweight vision model (2B parameters)"
        }
    }

    // MARK: - Model Configuration

    /// HuggingFace model ID for mlx-vlm
    var modelId: String {
        switch self {
        case .qwen35:
            return "mlx-community/Qwen3.5-9B-MLX-4bit"
        case .gemma4:
            return "google/gemma-4-e4b-it"
        case .mini:
            return "mlx-community/Qwen3.5-2B-MLX-4bit"
        }
    }

    /// Maximum context window size (in tokens)
    var maxContextWindow: Int {
        switch self {
        case .qwen35:
            return 32768 // 32k context
        case .gemma4:
            return 8192  // 8k context
        case .mini:
            return 32768 // 32k context
        }
    }

    /// Default max tokens for generation
    var defaultMaxTokens: Int {
        switch self {
        case .qwen35, .mini:
            return 4096
        case .gemma4:
            return 4096
        }
    }

    /// Estimated memory requirement in GB
    var memoryRequirementGB: Double {
        switch self {
        case .qwen35:
            return 6.0 // ~5.6GB model + overhead
        case .gemma4:
            return 3.0 // ~2-3GB
        case .mini:
            return 3.0 // Smaller model
        }
    }

    /// Model download size in GB
    var downloadSizeGB: Double {
        switch self {
        case .qwen35:
            return 5.6
        case .gemma4:
            return 2.5
        case .mini:
            return 1.5
        }
    }

    /// Whether the model supports vision (images)
    var supportsVision: Bool {
        return true // All current models support vision
    }

    /// Temperature range (min, max, default)
    var temperatureRange: (min: Double, max: Double, default: Double) {
        switch self {
        case .qwen35, .mini:
            return (0.0, 2.0, 0.7)
        case .gemma4:
            return (0.0, 2.0, 0.7)
        }
    }

    /// Nucleus sampling value used by the runtime.
    var topP: Double {
        switch self {
        case .qwen35, .mini:
            return 0.8
        case .gemma4:
            return 1.0
        }
    }

    /// Top-k sampling value used by the runtime.
    var topK: Int {
        switch self {
        case .qwen35, .mini:
            return 20
        case .gemma4:
            return 0
        }
    }

    /// Minimum probability threshold used by the runtime.
    var minP: Double {
        return 0.0
    }

    /// Repetition penalty used by the runtime.
    var repetitionPenalty: Double {
        return 1.0
    }

    /// Whether to ask the model chat template for reasoning content.
    var enableThinking: Bool {
        switch self {
        case .qwen35, .mini:
            return false
        case .gemma4:
            return false
        }
    }

    /// Backend type
    var backend: RuntimeBackend {
        return .vlm
    }

    /// Icon for the model
    var icon: String {
        switch self {
        case .qwen35:
            return "eye"
        case .gemma4:
            return "sparkles"
        case .mini:
            return "bolt"
        }
    }

    /// Get model info for display
    var info: ModelInfo {
        return ModelInfo(
            name: displayName,
            modelId: modelId,
            contextWindow: maxContextWindow,
            memoryRequired: memoryRequirementGB,
            downloadSize: downloadSizeGB,
            supportsVision: supportsVision
        )
    }

    static var currentHardwareMemoryGB: Double {
        Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
    }

    static var defaultForCurrentHardware: AIModel {
        bestModelsForHardware(memoryGB: currentHardwareMemoryGB).first ?? .mini
    }

    static var currentHardwareRecommendationText: String {
        let models = bestModelsForHardware(memoryGB: currentHardwareMemoryGB)
            .map(\.displayName)
            .joined(separator: ", ")

        return "These are the best models that should run comfortably on your hardware: \(models)."
    }

    static func bestModelsForHardware(memoryGB: Double) -> [AIModel] {
        let comfortableBudgetGB = memoryGB * 0.65
        let preferredOrder: [AIModel] = [.qwen35, .gemma4, .mini]
        let comfortableModels = preferredOrder.filter { $0.memoryRequirementGB <= comfortableBudgetGB }
        return comfortableModels.isEmpty ? [.mini] : comfortableModels
    }
}

// MARK: - Supporting Types

struct ModelInfo {
    let name: String
    let modelId: String
    let contextWindow: Int
    let memoryRequired: Double
    let downloadSize: Double
    let supportsVision: Bool
}

enum ModelModality: String, CaseIterable, Identifiable {
    case vision = "Vision"
    case image = "Image"
    case audio = "Audio"
    case music = "Music"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .vision: return "eye"
        case .image: return "photo"
        case .audio: return "waveform"
        case .music: return "music.note"
        }
    }
}

struct DownloadableModel: Identifiable, Equatable {
    let id: String
    let name: String
    let subtitle: String
    let modelId: String
    let modality: ModelModality
    let downloadSizeGB: Double

    static func embeddedModel(modelId: String) -> DownloadableModel? {
        embedded.first { $0.modelId == modelId }
    }

    static var embedded: [DownloadableModel] {
        let visionModels = AIModel.allCases.map { model in
            DownloadableModel(
                id: model.modelId,
                name: model.displayName,
                subtitle: model.subtitle,
                modelId: model.modelId,
                modality: .vision,
                downloadSizeGB: model.downloadSizeGB
            )
        }

        return visionModels + [
            DownloadableModel(
                id: "black-forest-labs/FLUX.2-klein-4B",
                name: "FLUX.2-klein-4B",
                subtitle: "Image generation model",
                modelId: "black-forest-labs/FLUX.2-klein-4B",
                modality: .image,
                downloadSizeGB: 15.0
            ),
            DownloadableModel(
                id: "kugelaudio/kugelaudio-0-open",
                name: "KugelAudio 0 Open",
                subtitle: "Speech generation model",
                modelId: "kugelaudio/kugelaudio-0-open",
                modality: .audio,
                downloadSizeGB: 15.0
            ),
            DownloadableModel(
                id: "ACE-Step/acestep-v15-turbo-continuous",
                name: "ACE-Step 1.5 Turbo",
                subtitle: "Music generation model",
                modelId: "ACE-Step/acestep-v15-turbo-continuous",
                modality: .music,
                downloadSizeGB: 4.8
            ),
        ]
    }
}
