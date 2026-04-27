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
        let models = ModelCapabilityProfile.recommendedProfiles(
            for: .vision,
            hardwareMemoryGB: memoryGB
        )
        .compactMap(\.aiModel)

        return models.isEmpty ? [.mini] : models
    }

    fileprivate var downloadableModel: DownloadableModel {
        DownloadableModel(
            id: modelId,
            name: displayName,
            subtitle: subtitle,
            modelId: modelId,
            modality: .vision,
            downloadSizeGB: downloadSizeGB,
            estimatedMemoryGB: memoryRequirementGB
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

enum ModelFit: String, Equatable, CaseIterable {
    case recommended
    case compatible
    case heavy
    case unknown

    var title: String {
        switch self {
        case .recommended: return "Recommended"
        case .compatible: return "Compatible"
        case .heavy: return "Heavy"
        case .unknown: return "Unknown fit"
        }
    }

    var shortTitle: String {
        switch self {
        case .recommended: return "Recommended"
        case .compatible: return "Fits"
        case .heavy: return "Heavy"
        case .unknown: return "Unknown"
        }
    }

    var systemImage: String {
        switch self {
        case .recommended: return "star.circle.fill"
        case .compatible: return "checkmark.circle.fill"
        case .heavy: return "exclamationmark.triangle.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }

    var sortRank: Int {
        switch self {
        case .recommended: return 0
        case .compatible: return 1
        case .unknown: return 2
        case .heavy: return 3
        }
    }

    static func classify(estimatedMemoryGB: Double?, hardwareMemoryGB: Double) -> ModelFit {
        guard let estimatedMemoryGB, estimatedMemoryGB > 0 else {
            return .unknown
        }

        let recommendedBudgetGB = hardwareMemoryGB * 0.65
        let compatibleBudgetGB = hardwareMemoryGB * 0.85

        if estimatedMemoryGB <= recommendedBudgetGB {
            return .recommended
        }
        if estimatedMemoryGB <= compatibleBudgetGB {
            return .compatible
        }
        return .heavy
    }
}

enum ModelParameterType: String, Equatable {
    case decimal
    case integer
    case boolean
    case option
    case text
}

struct ModelParameterDefinition: Identifiable, Equatable {
    let key: String
    let label: String
    let type: ModelParameterType
    let defaultValue: String
    let range: ClosedRange<Double>?
    let step: Double
    let options: [String]
    let isAdvanced: Bool

    var id: String { key }

    init(
        key: String,
        label: String,
        type: ModelParameterType,
        defaultValue: String,
        range: ClosedRange<Double>? = nil,
        step: Double = 1,
        options: [String] = [],
        isAdvanced: Bool = false
    ) {
        self.key = key
        self.label = label
        self.type = type
        self.defaultValue = defaultValue
        self.range = range
        self.step = step
        self.options = options
        self.isAdvanced = isAdvanced
    }

    func typedValue(from string: String) -> Any? {
        switch type {
        case .decimal:
            return Double(string)
        case .integer:
            return Int(Double(string) ?? 0)
        case .boolean:
            return Self.boolValue(from: string)
        case .option, .text:
            return string
        }
    }

    func clampedString(_ value: Double) -> String {
        let clamped: Double
        if let range {
            clamped = min(max(value, range.lowerBound), range.upperBound)
        } else {
            clamped = value
        }

        switch type {
        case .integer:
            return "\(Int(clamped.rounded()))"
        case .decimal:
            return Self.decimalFormatter.string(from: NSNumber(value: clamped)) ?? "\(clamped)"
        case .boolean, .option, .text:
            return defaultValue
        }
    }

    private static func boolValue(from string: String) -> Bool {
        switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "yes", "1":
            return true
        default:
            return false
        }
    }

    private static let decimalFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}

struct ModelParameterPreset: Identifiable, Equatable {
    let id: String
    let label: String
    let values: [String: String]
}

struct ModelCapabilityProfile: Identifiable, Equatable {
    let id: String
    let name: String
    let subtitle: String
    let modelId: String
    let modality: ModelModality
    let icon: String
    let downloadSizeGB: Double
    let estimatedMemoryGB: Double?
    let parameters: [ModelParameterDefinition]
    let presets: [ModelParameterPreset]
    let aiModel: AIModel?

    var downloadableModel: DownloadableModel {
        DownloadableModel(
            id: id,
            name: name,
            subtitle: subtitle,
            modelId: modelId,
            modality: modality,
            downloadSizeGB: downloadSizeGB,
            estimatedMemoryGB: estimatedMemoryGB
        )
    }

    func fit(hardwareMemoryGB: Double = AIModel.currentHardwareMemoryGB) -> ModelFit {
        ModelFit.classify(estimatedMemoryGB: estimatedMemoryGB, hardwareMemoryGB: hardwareMemoryGB)
    }

    func parameterDefinition(key: String) -> ModelParameterDefinition? {
        parameters.first { $0.key == key }
    }

    static var embedded: [ModelCapabilityProfile] {
        let chatProfiles = AIModel.allCases.map { model in
            ModelCapabilityProfile(
                id: model.modelId,
                name: model.displayName,
                subtitle: model.subtitle,
                modelId: model.modelId,
                modality: .vision,
                icon: model.icon,
                downloadSizeGB: model.downloadSizeGB,
                estimatedMemoryGB: model.memoryRequirementGB,
                parameters: chatParameters(for: model),
                presets: chatPresets(for: model),
                aiModel: model
            )
        }

        return chatProfiles + [
            ModelCapabilityProfile(
                id: "black-forest-labs/FLUX.2-klein-4B",
                name: "FLUX.2-klein-4B",
                subtitle: "Image generation model",
                modelId: "black-forest-labs/FLUX.2-klein-4B",
                modality: .image,
                icon: "photo",
                downloadSizeGB: 15.0,
                estimatedMemoryGB: 13.0,
                parameters: [
                    ModelParameterDefinition(key: "width", label: "Width", type: .integer, defaultValue: "1024", range: 512...1536, step: 128),
                    ModelParameterDefinition(key: "height", label: "Height", type: .integer, defaultValue: "1024", range: 512...1536, step: 128),
                    ModelParameterDefinition(key: "steps", label: "Steps", type: .integer, defaultValue: "4", range: 1...12, step: 1),
                    ModelParameterDefinition(key: "guidance", label: "Guidance", type: .decimal, defaultValue: "1", range: 1...4, step: 0.1),
                    ModelParameterDefinition(key: "seed", label: "Seed", type: .integer, defaultValue: "0", range: 0...2_147_483_647, step: 1, isAdvanced: true)
                ],
                presets: [
                    ModelParameterPreset(id: "fast", label: "Fast", values: ["steps": "4"]),
                    ModelParameterPreset(id: "detail", label: "Detailed", values: ["steps": "8"])
                ],
                aiModel: nil
            ),
            ModelCapabilityProfile(
                id: "kugelaudio/kugelaudio-0-open",
                name: "KugelAudio 0 Open",
                subtitle: "Speech generation model",
                modelId: "kugelaudio/kugelaudio-0-open",
                modality: .audio,
                icon: "waveform",
                downloadSizeGB: 15.0,
                estimatedMemoryGB: 19.0,
                parameters: [
                    ModelParameterDefinition(key: "cfg_scale", label: "Clarity", type: .decimal, defaultValue: "3", range: 1...10, step: 0.5),
                    ModelParameterDefinition(key: "ddpm_steps", label: "Steps", type: .integer, defaultValue: "10", range: 4...40, step: 1, isAdvanced: true)
                ],
                presets: [
                    ModelParameterPreset(id: "fast", label: "Fast", values: ["ddpm_steps": "8"]),
                    ModelParameterPreset(id: "quality", label: "Clear", values: ["ddpm_steps": "16", "cfg_scale": "3.5"])
                ],
                aiModel: nil
            ),
            ModelCapabilityProfile(
                id: "ACE-Step/acestep-v15-turbo-continuous",
                name: "ACE-Step 1.5 Turbo",
                subtitle: "Music generation model",
                modelId: "ACE-Step/acestep-v15-turbo-continuous",
                modality: .music,
                icon: "music.note",
                downloadSizeGB: 4.8,
                estimatedMemoryGB: 4.0,
                parameters: [
                    ModelParameterDefinition(key: "duration", label: "Duration", type: .integer, defaultValue: "30", range: 10...600, step: 5),
                    ModelParameterDefinition(key: "instrumental", label: "Instrumental", type: .boolean, defaultValue: "false"),
                    ModelParameterDefinition(key: "bpm", label: "BPM", type: .integer, defaultValue: "0", range: 0...300, step: 1, isAdvanced: true),
                    ModelParameterDefinition(key: "keyscale", label: "Key", type: .text, defaultValue: "", isAdvanced: true),
                    ModelParameterDefinition(key: "timesignature", label: "Time Signature", type: .option, defaultValue: "", options: ["", "2", "3", "4", "6"], isAdvanced: true),
                    ModelParameterDefinition(key: "vocal_language", label: "Vocal Language", type: .option, defaultValue: "unknown", options: ["unknown", "en", "zh", "ja", "es", "fr", "de", "it", "pt", "tr"], isAdvanced: true),
                    ModelParameterDefinition(key: "inference_steps", label: "Steps", type: .integer, defaultValue: "8", range: 4...40, step: 1, isAdvanced: true),
                    ModelParameterDefinition(key: "shift", label: "Shift", type: .decimal, defaultValue: "3", range: 1...6, step: 0.1, isAdvanced: true),
                    ModelParameterDefinition(key: "infer_method", label: "Method", type: .option, defaultValue: "ode", options: ["ode", "euler"], isAdvanced: true),
                    ModelParameterDefinition(key: "thinking", label: "Planner", type: .boolean, defaultValue: "false", isAdvanced: true),
                    ModelParameterDefinition(key: "seed", label: "Seed", type: .integer, defaultValue: "0", range: 0...2_147_483_647, step: 1, isAdvanced: true)
                ],
                presets: [
                    ModelParameterPreset(id: "fast", label: "Fast", values: ["duration": "20", "inference_steps": "6"]),
                    ModelParameterPreset(id: "full", label: "Full", values: ["duration": "45", "inference_steps": "12"])
                ],
                aiModel: nil
            )
        ]
    }

    static func embeddedProfile(modelId: String) -> ModelCapabilityProfile? {
        embedded.first { $0.modelId == modelId }
    }

    static func profiles(for modality: ModelModality) -> [ModelCapabilityProfile] {
        embedded.filter { $0.modality == modality }
    }

    static func bestProfile(
        for modality: ModelModality,
        hardwareMemoryGB: Double = AIModel.currentHardwareMemoryGB
    ) -> ModelCapabilityProfile? {
        recommendedProfiles(for: modality, hardwareMemoryGB: hardwareMemoryGB).first
    }

    static func recommendedProfiles(
        for modality: ModelModality,
        hardwareMemoryGB: Double = AIModel.currentHardwareMemoryGB
    ) -> [ModelCapabilityProfile] {
        let candidates = profiles(for: modality)
        let comfortable = candidates.filter { $0.fit(hardwareMemoryGB: hardwareMemoryGB) == .recommended }

        if comfortable.isEmpty {
            return candidates.sorted { lhs, rhs in
                isConstrainedFallbackSortedBefore(lhs, rhs)
            }
            .prefix(1)
            .map { $0 }
        }

        return comfortable.sorted { lhs, rhs in
            isQualitySortedBefore(lhs, rhs)
        }
    }

    static func sortedProfiles(
        for modality: ModelModality,
        hardwareMemoryGB: Double = AIModel.currentHardwareMemoryGB
    ) -> [ModelCapabilityProfile] {
        profiles(for: modality).sorted { lhs, rhs in
            isRecommendationSortedBefore(lhs, rhs, hardwareMemoryGB: hardwareMemoryGB)
        }
    }

    private static func chatParameters(for model: AIModel) -> [ModelParameterDefinition] {
        [
            ModelParameterDefinition(key: "temperature", label: "Temperature", type: .decimal, defaultValue: "\(model.temperatureRange.default)", range: model.temperatureRange.min...model.temperatureRange.max, step: 0.1),
            ModelParameterDefinition(key: "max_tokens", label: "Max Tokens", type: .integer, defaultValue: "\(model.defaultMaxTokens)", range: 256...Double(model.maxContextWindow), step: 256),
            ModelParameterDefinition(key: "top_p", label: "Top P", type: .decimal, defaultValue: "\(model.topP)", range: 0...1, step: 0.05, isAdvanced: true),
            ModelParameterDefinition(key: "top_k", label: "Top K", type: .integer, defaultValue: "\(model.topK)", range: 0...100, step: 1, isAdvanced: true),
            ModelParameterDefinition(key: "min_p", label: "Min P", type: .decimal, defaultValue: "\(model.minP)", range: 0...1, step: 0.01, isAdvanced: true),
            ModelParameterDefinition(key: "repetition_penalty", label: "Repetition Penalty", type: .decimal, defaultValue: "\(model.repetitionPenalty)", range: 0.8...1.5, step: 0.05, isAdvanced: true),
            ModelParameterDefinition(key: "enable_thinking", label: "Reasoning", type: .boolean, defaultValue: "\(model.enableThinking)", isAdvanced: true)
        ]
    }

    private static func chatPresets(for model: AIModel) -> [ModelParameterPreset] {
        [
            ModelParameterPreset(id: "balanced", label: "Balanced", values: [
                "temperature": "\(model.temperatureRange.default)",
                "max_tokens": "\(model.defaultMaxTokens)"
            ]),
            ModelParameterPreset(id: "focused", label: "Focused", values: [
                "temperature": "0.2",
                "top_p": "\(min(model.topP, 0.8))"
            ])
        ]
    }

    private static func isRecommendationSortedBefore(
        _ lhs: ModelCapabilityProfile,
        _ rhs: ModelCapabilityProfile,
        hardwareMemoryGB: Double
    ) -> Bool {
        let lhsFitRank = lhs.fit(hardwareMemoryGB: hardwareMemoryGB).sortRank
        let rhsFitRank = rhs.fit(hardwareMemoryGB: hardwareMemoryGB).sortRank
        if lhsFitRank != rhsFitRank {
            return lhsFitRank < rhsFitRank
        }

        let lhsQualityRank = qualityRank(lhs)
        let rhsQualityRank = qualityRank(rhs)
        if lhsQualityRank != rhsQualityRank {
            return lhsQualityRank < rhsQualityRank
        }

        let lhsMemory = lhs.estimatedMemoryGB ?? 0
        let rhsMemory = rhs.estimatedMemoryGB ?? 0
        if lhsMemory != rhsMemory {
            return lhsMemory > rhsMemory
        }

        return lhs.name < rhs.name
    }

    private static func isQualitySortedBefore(
        _ lhs: ModelCapabilityProfile,
        _ rhs: ModelCapabilityProfile
    ) -> Bool {
        let lhsRank = qualityRank(lhs)
        let rhsRank = qualityRank(rhs)
        if lhsRank != rhsRank {
            return lhsRank < rhsRank
        }
        return lhs.name < rhs.name
    }

    private static func isConstrainedFallbackSortedBefore(
        _ lhs: ModelCapabilityProfile,
        _ rhs: ModelCapabilityProfile
    ) -> Bool {
        let lhsMemory = lhs.estimatedMemoryGB ?? .greatestFiniteMagnitude
        let rhsMemory = rhs.estimatedMemoryGB ?? .greatestFiniteMagnitude
        if lhsMemory != rhsMemory {
            return lhsMemory < rhsMemory
        }

        let lhsRank = lightweightRank(lhs)
        let rhsRank = lightweightRank(rhs)
        if lhsRank != rhsRank {
            return lhsRank < rhsRank
        }

        return lhs.name < rhs.name
    }

    private static func qualityRank(_ profile: ModelCapabilityProfile) -> Int {
        switch profile.aiModel {
        case .qwen35:
            return 0
        case .gemma4:
            return 1
        case .mini:
            return 2
        case nil:
            return 0
        }
    }

    private static func lightweightRank(_ profile: ModelCapabilityProfile) -> Int {
        switch profile.aiModel {
        case .mini:
            return 0
        case .gemma4:
            return 1
        case .qwen35:
            return 2
        case nil:
            return 0
        }
    }
}

struct ModelSelectionStore {
    static let chatKey = "MLXHub.selectedModel.chat"
    static let imageKey = "MLXHub.selectedModel.image"
    static let speechKey = "MLXHub.selectedModel.speech"
    static let musicKey = "MLXHub.selectedModel.music"

    let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func selectedModelId(for modality: ModelModality) -> String? {
        userDefaults.string(forKey: key(for: modality))
    }

    func setSelectedModelId(_ modelId: String, for modality: ModelModality) {
        userDefaults.set(modelId, forKey: key(for: modality))
    }

    func selectedProfile(
        for modality: ModelModality,
        hardwareMemoryGB: Double = AIModel.currentHardwareMemoryGB
    ) -> ModelCapabilityProfile? {
        if let modelId = selectedModelId(for: modality),
           let profile = ModelCapabilityProfile.embeddedProfile(modelId: modelId),
           profile.modality == modality {
            return profile
        }

        return ModelCapabilityProfile.bestProfile(
            for: modality,
            hardwareMemoryGB: hardwareMemoryGB
        )
    }

    func key(for modality: ModelModality) -> String {
        switch modality {
        case .vision: return Self.chatKey
        case .image: return Self.imageKey
        case .audio: return Self.speechKey
        case .music: return Self.musicKey
        }
    }
}

struct ModelParameterStore {
    static let storageKey = "MLXHub.modelParameterValues"

    let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func values(for profile: ModelCapabilityProfile) -> [String: String] {
        let supportedKeys = Set(profile.parameters.map(\.key))
        let saved = storedValues()[profile.modelId] ?? [:]
        var resolved = Dictionary(uniqueKeysWithValues: profile.parameters.map { ($0.key, $0.defaultValue) })

        for (key, value) in saved where supportedKeys.contains(key) {
            resolved[key] = value
        }

        return resolved
    }

    func executionParameters(for profile: ModelCapabilityProfile) -> [String: Any] {
        let resolvedValues = values(for: profile)
        var parameters: [String: Any] = [:]

        for definition in profile.parameters {
            guard let value = resolvedValues[definition.key],
                  let typedValue = definition.typedValue(from: value) else {
                continue
            }
            parameters[definition.key] = typedValue
        }

        return parameters
    }

    func setValue(_ value: String, for key: String, modelId: String) {
        var allValues = storedValues()
        var modelValues = allValues[modelId] ?? [:]
        modelValues[key] = value
        allValues[modelId] = modelValues
        save(allValues)
    }

    func applyPreset(_ preset: ModelParameterPreset, to profile: ModelCapabilityProfile) {
        var allValues = storedValues()
        var modelValues = allValues[profile.modelId] ?? [:]
        for (key, value) in preset.values where profile.parameterDefinition(key: key) != nil {
            modelValues[key] = value
        }
        allValues[profile.modelId] = modelValues
        save(allValues)
    }

    func reset(profile: ModelCapabilityProfile) {
        var allValues = storedValues()
        allValues.removeValue(forKey: profile.modelId)
        save(allValues)
    }

    func storedValues() -> [String: [String: String]] {
        guard let data = userDefaults.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([String: [String: String]].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func save(_ values: [String: [String: String]]) {
        guard let data = try? JSONEncoder().encode(values) else { return }
        userDefaults.set(data, forKey: Self.storageKey)
    }
}

struct DownloadableModel: Identifiable, Equatable {
    let id: String
    let name: String
    let subtitle: String
    let modelId: String
    let modality: ModelModality
    let downloadSizeGB: Double
    let estimatedMemoryGB: Double?

    init(
        id: String,
        name: String,
        subtitle: String,
        modelId: String,
        modality: ModelModality,
        downloadSizeGB: Double,
        estimatedMemoryGB: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.modelId = modelId
        self.modality = modality
        self.downloadSizeGB = downloadSizeGB
        self.estimatedMemoryGB = estimatedMemoryGB
    }

    static func embeddedModel(modelId: String) -> DownloadableModel? {
        embedded.first { $0.modelId == modelId }
    }

    static var embedded: [DownloadableModel] {
        ModelCapabilityProfile.embedded.map(\.downloadableModel)
    }
}
