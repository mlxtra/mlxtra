import Foundation

enum AIModel: String, CaseIterable, Identifiable, Codable {
    case qwen35 = "Qwen 3.5"
    case gemma4 = "Gemma 4"
    case mini = "Qwen 3.5 Mini"

    static var allCases: [AIModel] {
        legacyCaseOrder.filter { profile(for: $0) != nil }
    }

    var id: String { rawValue }

    var displayName: String { legacyProfile.name }

    var subtitle: String {
        legacyProfile.subtitle
    }

    var modelId: String {
        legacyProfile.modelId
    }

    var maxContextWindow: Int {
        legacyProfile.maxContextWindow
    }

    var defaultMaxTokens: Int {
        legacyProfile.defaultMaxTokens
    }

    var memoryRequirementGB: Double {
        legacyProfile.estimatedMemoryGB ?? 0
    }

    var downloadSizeGB: Double {
        legacyProfile.downloadSizeGB
    }

    var supportsVision: Bool {
        legacyProfile.supportsVision
    }

    var temperatureRange: (min: Double, max: Double, default: Double) {
        let parameter = legacyProfile.parameterDefinition(key: "temperature")
        return (
            parameter?.range?.lowerBound ?? 0,
            parameter?.range?.upperBound ?? 2,
            Double(parameter?.defaultValue ?? "") ?? 0.7
        )
    }

    var topP: Double {
        parameterDefault("top_p", fallback: 1.0)
    }

    var topK: Int {
        Int(parameterDefault("top_k", fallback: 0))
    }

    var minP: Double {
        parameterDefault("min_p", fallback: 0)
    }

    var repetitionPenalty: Double {
        parameterDefault("repetition_penalty", fallback: 1.0)
    }

    var enableThinking: Bool {
        legacyProfile.parameterDefinition(key: "enable_thinking")?.defaultValue.lowercased() == "true"
    }

    var backend: RuntimeBackend {
        legacyProfile.backend
    }

    var icon: String {
        legacyProfile.icon
    }

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
        let models = ModelCapabilityProfile.recommendedProfiles(
            for: .vision,
            hardwareMemoryGB: memoryGB
        )
        .compactMap(\.aiModel)

        return models.isEmpty ? [.mini] : models
    }

    fileprivate var downloadableModel: DownloadableModel {
        legacyProfile.downloadableModel
    }

    private var legacyProfile: ModelCapabilityProfile {
        guard let profile = Self.profile(for: self) else {
            preconditionFailure("Missing built-in definition for \(self.rawValue)")
        }

        return profile
    }

    private func parameterDefault(_ key: String, fallback: Double) -> Double {
        Double(legacyProfile.parameterDefinition(key: key)?.defaultValue ?? "") ?? fallback
    }

    private static let legacyCaseOrder: [AIModel] = [.qwen35, .gemma4, .mini]

    private static func profile(for model: AIModel) -> ModelCapabilityProfile? {
        ModelCatalogService.shared.profile(legacyModel: model)
    }
}

struct ModelInfo {
    let name: String
    let modelId: String
    let contextWindow: Int
    let memoryRequired: Double
    let downloadSize: Double
    let supportsVision: Bool
}
