import Foundation

enum AIModel: String, CaseIterable, Identifiable {
    case qwen35 = "Qwen 3.5"
    case gemma4 = "Gemma 4"
    case mini = "Qwen 3.5 Mini"

    static var allCases: [AIModel] {
        builtInCatalog.map(\.model)
    }

    var id: String { rawValue }

    var displayName: String { rawValue }

    var subtitle: String {
        builtInDefinition.subtitle
    }

    // MARK: - Model Configuration

    /// HuggingFace model ID for mlx-vlm
    var modelId: String {
        builtInDefinition.modelId
    }

    /// Maximum context window size (in tokens)
    var maxContextWindow: Int {
        builtInDefinition.maxContextWindow
    }

    /// Default max tokens for generation
    var defaultMaxTokens: Int {
        builtInDefinition.defaultMaxTokens
    }

    /// Estimated memory requirement in GB
    var memoryRequirementGB: Double {
        builtInDefinition.memoryRequirementGB
    }

    /// Model download size in GB
    var downloadSizeGB: Double {
        builtInDefinition.downloadSizeGB
    }

    /// Whether the model supports vision (images)
    var supportsVision: Bool {
        builtInDefinition.supportsVision
    }

    /// Temperature range (min, max, default)
    var temperatureRange: (min: Double, max: Double, default: Double) {
        builtInDefinition.temperatureRange
    }

    /// Nucleus sampling value used by the runtime.
    var topP: Double {
        builtInDefinition.topP
    }

    /// Top-k sampling value used by the runtime.
    var topK: Int {
        builtInDefinition.topK
    }

    /// Minimum probability threshold used by the runtime.
    var minP: Double {
        builtInDefinition.minP
    }

    /// Repetition penalty used by the runtime.
    var repetitionPenalty: Double {
        builtInDefinition.repetitionPenalty
    }

    /// Whether to ask the model chat template for reasoning content.
    var enableThinking: Bool {
        builtInDefinition.enableThinking
    }

    /// Backend type
    var backend: RuntimeBackend {
        builtInDefinition.backend
    }

    /// Icon for the model
    var icon: String {
        builtInDefinition.icon
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
        let comfortableModels = allCases.filter { $0.memoryRequirementGB <= comfortableBudgetGB }
        return comfortableModels.isEmpty ? [.mini] : comfortableModels
    }

    fileprivate var downloadableModel: DownloadableModel {
        DownloadableModel(
            id: modelId,
            name: displayName,
            subtitle: subtitle,
            modelId: modelId,
            modality: .vision,
            downloadSizeGB: downloadSizeGB
        )
    }

    private var builtInDefinition: BuiltInModelDefinition {
        guard let definition = Self.builtInDefinitions[self] else {
            preconditionFailure("Missing built-in definition for \(self.rawValue)")
        }

        return definition
    }

    private static let builtInCatalog: [(model: AIModel, definition: BuiltInModelDefinition)] = [
        (
            model: .qwen35,
            definition: BuiltInModelDefinition(
                subtitle: "Vision language model (9B parameters)",
                modelId: "mlx-community/Qwen3.5-9B-MLX-4bit",
                maxContextWindow: 32768,
                defaultMaxTokens: 4096,
                memoryRequirementGB: 6.0,
                downloadSizeGB: 5.6,
                supportsVision: true,
                temperatureRange: (0.0, 2.0, 0.7),
                topP: 0.8,
                topK: 20,
                minP: 0.0,
                repetitionPenalty: 1.0,
                enableThinking: false,
                backend: .vlm,
                icon: "eye"
            )
        ),
        (
            model: .gemma4,
            definition: BuiltInModelDefinition(
                subtitle: "Google vision model (4B parameters)",
                modelId: "google/gemma-4-e4b-it",
                maxContextWindow: 8192,
                defaultMaxTokens: 4096,
                memoryRequirementGB: 3.0,
                downloadSizeGB: 2.5,
                supportsVision: true,
                temperatureRange: (0.0, 2.0, 0.7),
                topP: 1.0,
                topK: 0,
                minP: 0.0,
                repetitionPenalty: 1.0,
                enableThinking: false,
                backend: .vlm,
                icon: "sparkles"
            )
        ),
        (
            model: .mini,
            definition: BuiltInModelDefinition(
                subtitle: "Lightweight vision model (2B parameters)",
                modelId: "mlx-community/Qwen3.5-2B-MLX-4bit",
                maxContextWindow: 32768,
                defaultMaxTokens: 4096,
                memoryRequirementGB: 3.0,
                downloadSizeGB: 1.5,
                supportsVision: true,
                temperatureRange: (0.0, 2.0, 0.7),
                topP: 0.8,
                topK: 20,
                minP: 0.0,
                repetitionPenalty: 1.0,
                enableThinking: false,
                backend: .vlm,
                icon: "bolt"
            )
        ),
    ]

    private static let builtInDefinitions: [AIModel: BuiltInModelDefinition] = Dictionary(
        uniqueKeysWithValues: builtInCatalog.map { ($0.model, $0.definition) }
    )
}

// MARK: - Supporting Types

private struct BuiltInModelDefinition {
    let subtitle: String
    let modelId: String
    let maxContextWindow: Int
    let defaultMaxTokens: Int
    let memoryRequirementGB: Double
    let downloadSizeGB: Double
    let supportsVision: Bool
    let temperatureRange: (min: Double, max: Double, default: Double)
    let topP: Double
    let topK: Int
    let minP: Double
    let repetitionPenalty: Double
    let enableThinking: Bool
    let backend: RuntimeBackend
    let icon: String
}

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
        let visionModels = AIModel.allCases.map(\.downloadableModel)

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
