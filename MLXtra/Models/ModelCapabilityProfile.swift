import Foundation

enum SystemHardware {
    static var currentMemoryGB: Double {
        Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
    }
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

extension ModelModality: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "vision", "chat":
            self = .vision
        case "image":
            self = .image
        case "audio", "speech":
            self = .audio
        case "music":
            self = .music
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown model modality \(rawValue)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .vision:
            try container.encode("vision")
        case .image:
            try container.encode("image")
        case .audio:
            try container.encode("audio")
        case .music:
            try container.encode("music")
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

enum ModelParameterType: String, Equatable, Codable {
    case decimal
    case integer
    case boolean
    case option
    case text
}

enum ModelAvailability: String, Equatable, Codable {
    case visible
    case hidden
    case requiresHFAccess = "requires_hf_access"
}

struct ModelParameterDefinition: Identifiable, Equatable, Codable {
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
            guard let value = Double(string) else { return nil }
            return clampedNumber(value)
        case .integer:
            guard let value = integerValue(from: string) else { return nil }
            return Int(clampedNumber(Double(value)).rounded())
        case .boolean:
            guard let value = Self.boolValue(from: string) else { return nil }
            return value
        case .option:
            guard options.isEmpty || options.contains(string) else { return nil }
            return string
        case .text:
            return string
        }
    }

    func normalizedString(from string: String) -> String? {
        switch type {
        case .decimal, .integer:
            guard let value = Double(string) else { return nil }
            if type == .integer, value.rounded() != value {
                return nil
            }
            return clampedString(value)
        case .boolean:
            guard let value = Self.boolValue(from: string) else { return nil }
            return value ? "true" : "false"
        case .option:
            guard options.isEmpty || options.contains(string) else { return nil }
            return string
        case .text:
            return string
        }
    }

    func clampedString(_ value: Double) -> String {
        let clamped = clampedNumber(value)

        switch type {
        case .integer:
            return "\(Int(clamped))"
        case .decimal:
            return Self.decimalFormatter.string(from: NSNumber(value: clamped)) ?? "\(clamped)"
        case .boolean, .option, .text:
            return defaultValue
        }
    }

    private func clampedNumber(_ value: Double) -> Double {
        if let range {
            return min(max(value, range.lowerBound), range.upperBound)
        }
        return value
    }

    private func integerValue(from string: String) -> Int? {
        guard let value = Double(string), value.isFinite, value.rounded() == value else {
            return nil
        }
        return Int(value)
    }

    private static func boolValue(from string: String) -> Bool? {
        switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "yes", "1":
            return true
        case "false", "no", "0":
            return false
        default:
            return nil
        }
    }

    private static let decimalFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private enum CodingKeys: String, CodingKey {
        case key
        case label
        case type
        case defaultValue
        case range
        case step
        case options
        case isAdvanced
    }

    private struct CodableRange: Codable {
        let min: Double
        let max: Double
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let range = try container.decodeIfPresent(CodableRange.self, forKey: .range)
        self.init(
            key: try container.decode(String.self, forKey: .key),
            label: try container.decode(String.self, forKey: .label),
            type: try container.decode(ModelParameterType.self, forKey: .type),
            defaultValue: try container.decode(String.self, forKey: .defaultValue),
            range: range.map { $0.min...$0.max },
            step: try container.decodeIfPresent(Double.self, forKey: .step) ?? 1,
            options: try container.decodeIfPresent([String].self, forKey: .options) ?? [],
            isAdvanced: try container.decodeIfPresent(Bool.self, forKey: .isAdvanced) ?? false
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(label, forKey: .label)
        try container.encode(type, forKey: .type)
        try container.encode(defaultValue, forKey: .defaultValue)
        if let range {
            try container.encode(CodableRange(min: range.lowerBound, max: range.upperBound), forKey: .range)
        }
        try container.encode(step, forKey: .step)
        try container.encode(options, forKey: .options)
        try container.encode(isAdvanced, forKey: .isAdvanced)
    }
}

struct ModelParameterPreset: Identifiable, Equatable, Codable {
    let id: String
    let label: String
    let values: [String: String]
}

enum ModelSourceType: String, Codable, Equatable {
    case huggingFaceSnapshot = "hugging_face_snapshot"
    case componentBundle = "component_bundle"
}

enum ModelDownloadHelper: String, Codable, Equatable {
    case aceStep = "ace_step"
}

struct ModelSource: Codable, Equatable {
    let type: ModelSourceType
    let repo: String?
    let revision: String?
    let components: [String]
    let helper: ModelDownloadHelper?

    init(
        type: ModelSourceType,
        repo: String? = nil,
        revision: String? = nil,
        components: [String] = [],
        helper: ModelDownloadHelper? = nil
    ) {
        self.type = type
        self.repo = repo
        self.revision = revision
        self.components = components
        self.helper = helper
    }

    static func defaultSource(modelId: String) -> ModelSource {
        return ModelSource(type: .huggingFaceSnapshot, repo: modelId, revision: "main")
    }

    var downloadRepository: String? {
        repo
    }

    var usesComponentBundle: Bool {
        type == .componentBundle
    }
}

struct ModelRuntimeRequirement: Codable, Equatable {
    let minVersion: String
    let compatibilityApi: Int

    init(minVersion: String = "0.1.0", compatibilityApi: Int = 1) {
        self.minVersion = minVersion
        self.compatibilityApi = compatibilityApi
    }

    func isSatisfied(by manifest: RuntimeManifest?) -> Bool {
        guard let manifest else { return false }
        guard manifest.compatibilityApi == compatibilityApi else { return false }
        return VersionComparator.compare(manifest.runtimeVersion, minVersion) != .orderedAscending
    }
}

struct ModelRuntimeOptions: Codable, Equatable {
    let mflux: MFluxRuntimeOptions?
    let chatTemplate: ChatTemplateRuntimeOptions?
    let audio: AudioRuntimeOptions?

    init(
        mflux: MFluxRuntimeOptions? = nil,
        chatTemplate: ChatTemplateRuntimeOptions? = nil,
        audio: AudioRuntimeOptions? = nil
    ) {
        self.mflux = mflux
        self.chatTemplate = chatTemplate
        self.audio = audio
    }

    var executionDictionary: [String: Any] {
        var options: [String: Any] = [:]
        if let mflux {
            options["mflux"] = mflux.executionDictionary
        }
        if let audio {
            options["audio"] = audio.executionDictionary
        }
        return options
    }

    func chatTemplateKwargs(from parameters: [String: Any]) -> [String: Any]? {
        chatTemplate?.kwargs(from: parameters)
    }
}

struct MFluxRuntimeOptions: Codable, Equatable {
    let config: String
    let textToImageClass: String
    let editClass: String
    let quantize: Int?

    init(
        config: String,
        textToImageClass: String,
        editClass: String,
        quantize: Int? = nil
    ) {
        self.config = config
        self.textToImageClass = textToImageClass
        self.editClass = editClass
        self.quantize = quantize
    }

    var executionDictionary: [String: Any] {
        var options: [String: Any] = [
            "config": config,
            "textToImageClass": textToImageClass,
            "editClass": editClass
        ]
        if let quantize {
            options["quantize"] = quantize
        }
        return options
    }
}

struct ChatTemplateRuntimeOptions: Codable, Equatable {
    let parameterKwargs: [String: String]

    init(parameterKwargs: [String: String] = [:]) {
        self.parameterKwargs = parameterKwargs
    }

    func kwargs(from parameters: [String: Any]) -> [String: Any]? {
        var kwargs: [String: Any] = [:]
        for (kwarg, parameterKey) in parameterKwargs {
            if let value = parameters[parameterKey] {
                kwargs[kwarg] = value
            }
        }
        return kwargs.isEmpty ? nil : kwargs
    }
}

struct AudioRuntimeOptions: Codable, Equatable {
    let adapter: String
    let defaultVoice: String?
    let languageByVoicePrefix: [String: String]

    private enum CodingKeys: String, CodingKey {
        case adapter
        case defaultVoice
        case languageByVoicePrefix
    }

    init(
        adapter: String,
        defaultVoice: String? = nil,
        languageByVoicePrefix: [String: String] = [:]
    ) {
        self.adapter = adapter
        self.defaultVoice = defaultVoice
        self.languageByVoicePrefix = languageByVoicePrefix
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            adapter: try container.decode(String.self, forKey: .adapter),
            defaultVoice: try container.decodeIfPresent(String.self, forKey: .defaultVoice),
            languageByVoicePrefix: try container.decodeIfPresent([String: String].self, forKey: .languageByVoicePrefix) ?? [:]
        )
    }

    var executionDictionary: [String: Any] {
        var options: [String: Any] = [
            "adapter": adapter
        ]
        if let defaultVoice {
            options["defaultVoice"] = defaultVoice
        }
        if !languageByVoicePrefix.isEmpty {
            options["languageByVoicePrefix"] = languageByVoicePrefix
        }
        return options
    }
}

struct ModelRanking: Codable, Equatable {
    let quality: Int
    let speed: Int
    let defaultForMemoryGB: Double?

    init(quality: Int = 0, speed: Int = 0, defaultForMemoryGB: Double? = nil) {
        self.quality = quality
        self.speed = speed
        self.defaultForMemoryGB = defaultForMemoryGB
    }
}

struct ModelCapabilityProfile: Identifiable, Equatable, Codable {
    let id: String
    let name: String
    let subtitle: String
    let modelId: String
    let modality: ModelModality
    let backend: RuntimeBackend
    let icon: String
    let capabilities: [String]
    let maxContextWindow: Int
    let defaultMaxTokens: Int
    let downloadSizeGB: Double
    let estimatedMemoryGB: Double?
    let source: ModelSource
    let runtime: ModelRuntimeRequirement
    let runtimeOptions: ModelRuntimeOptions?
    let availability: ModelAvailability?
    let ranking: ModelRanking
    let parameters: [ModelParameterDefinition]
    let presets: [ModelParameterPreset]

    init(
        id: String,
        name: String,
        subtitle: String,
        modelId: String,
        modality: ModelModality,
        backend: RuntimeBackend = .vlm,
        icon: String,
        capabilities: [String] = [],
        maxContextWindow: Int = 0,
        defaultMaxTokens: Int = 0,
        downloadSizeGB: Double,
        estimatedMemoryGB: Double?,
        source: ModelSource? = nil,
        runtime: ModelRuntimeRequirement = ModelRuntimeRequirement(),
        runtimeOptions: ModelRuntimeOptions? = nil,
        availability: ModelAvailability? = nil,
        ranking: ModelRanking = ModelRanking(),
        parameters: [ModelParameterDefinition],
        presets: [ModelParameterPreset]
    ) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.modelId = modelId
        self.modality = modality
        self.backend = backend
        self.icon = icon
        self.capabilities = capabilities
        self.maxContextWindow = maxContextWindow
        self.defaultMaxTokens = defaultMaxTokens
        self.downloadSizeGB = downloadSizeGB
        self.estimatedMemoryGB = estimatedMemoryGB
        self.source = source ?? ModelSource.defaultSource(modelId: modelId)
        self.runtime = runtime
        self.runtimeOptions = runtimeOptions
        self.availability = availability
        self.ranking = ranking
        self.parameters = parameters
        self.presets = presets
    }

    var downloadableModel: DownloadableModel {
        DownloadableModel(
            id: id,
            name: name,
            subtitle: subtitle,
            modelId: modelId,
            modality: modality,
            backend: backend,
            downloadSizeGB: downloadSizeGB,
            estimatedMemoryGB: estimatedMemoryGB,
            source: source,
            runtime: runtime,
            runtimeOptions: runtimeOptions
        )
    }

    var supportsVision: Bool {
        capabilities.contains("vision")
    }

    var isCatalogVisible: Bool {
        (availability ?? .visible) == .visible
    }

    func fit(hardwareMemoryGB: Double = SystemHardware.currentMemoryGB) -> ModelFit {
        ModelFit.classify(estimatedMemoryGB: estimatedMemoryGB, hardwareMemoryGB: hardwareMemoryGB)
    }

    func isHardwareCompatible(hardwareMemoryGB: Double = SystemHardware.currentMemoryGB) -> Bool {
        fit(hardwareMemoryGB: hardwareMemoryGB) != .heavy
    }

    func isRuntimeCompatible(manifest: RuntimeManifest? = RuntimeManager.activeRuntimeManifest()) -> Bool {
        guard let manifest else { return false }
        return runtime.isSatisfied(by: manifest)
            && manifest.supports(backend: backend)
            && manifest.supports(runtimeOptions: runtimeOptions)
    }

    func parameterDefinition(key: String) -> ModelParameterDefinition? {
        parameters.first { $0.key == key }
    }

    func doubleParameterDefault(_ key: String, fallback: Double) -> Double {
        Double(parameterDefinition(key: key)?.defaultValue ?? "") ?? fallback
    }

    func intParameterDefault(_ key: String, fallback: Int) -> Int {
        Int(doubleParameterDefault(key, fallback: Double(fallback)))
    }

    func boolParameterDefault(_ key: String, fallback: Bool) -> Bool {
        guard let value = parameterDefinition(key: key)?.defaultValue else {
            return fallback
        }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "yes", "1":
            return true
        case "false", "no", "0":
            return false
        default:
            return fallback
        }
    }

    static var embedded: [ModelCapabilityProfile] {
        ModelCatalogService.shared.profiles
    }

    static func embeddedProfile(modelId: String) -> ModelCapabilityProfile? {
        embedded.first { $0.modelId == modelId }
    }

    static func profiles(for modality: ModelModality) -> [ModelCapabilityProfile] {
        embedded.filter { $0.modality == modality && $0.isCatalogVisible }
    }

    static func visibleProfiles(
        for modality: ModelModality,
        hardwareMemoryGB: Double = SystemHardware.currentMemoryGB
    ) -> [ModelCapabilityProfile] {
        let candidates = profiles(for: modality)
        let compatible = candidates.filter { $0.isHardwareCompatible(hardwareMemoryGB: hardwareMemoryGB) }
        if !compatible.isEmpty {
            return compatible
        }

        return candidates.sorted { lhs, rhs in
            isConstrainedFallbackSortedBefore(lhs, rhs)
        }
        .prefix(1)
        .map { $0 }
    }

    static func visibleProfiles(
        hardwareMemoryGB: Double = SystemHardware.currentMemoryGB
    ) -> [ModelCapabilityProfile] {
        ModelModality.allCases.flatMap { modality in
            visibleProfiles(for: modality, hardwareMemoryGB: hardwareMemoryGB)
        }
    }

    static func bestProfile(
        for modality: ModelModality,
        hardwareMemoryGB: Double = SystemHardware.currentMemoryGB
    ) -> ModelCapabilityProfile? {
        recommendedProfiles(for: modality, hardwareMemoryGB: hardwareMemoryGB).first
    }

    static func recommendedProfiles(
        for modality: ModelModality,
        hardwareMemoryGB: Double = SystemHardware.currentMemoryGB
    ) -> [ModelCapabilityProfile] {
        let allCandidates = profiles(for: modality)
        let compatibleCandidates = allCandidates.filter { $0.isRuntimeCompatible() }
        let candidates = compatibleCandidates.isEmpty ? allCandidates : compatibleCandidates
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
        hardwareMemoryGB: Double = SystemHardware.currentMemoryGB
    ) -> [ModelCapabilityProfile] {
        visibleProfiles(for: modality, hardwareMemoryGB: hardwareMemoryGB).sorted { lhs, rhs in
            isRecommendationSortedBefore(lhs, rhs, hardwareMemoryGB: hardwareMemoryGB)
        }
    }

    fileprivate static func chatParameters(
        defaults: ChatParameterDefaults = .qwen,
        maxContextWindow: Int? = nil
    ) -> [ModelParameterDefinition] {
        let contextWindow = maxContextWindow ?? defaults.maxContextWindow

        return [
            ModelParameterDefinition(key: "temperature", label: "Temperature", type: .decimal, defaultValue: "\(defaults.temperature)", range: defaults.temperatureRange, step: 0.1),
            ModelParameterDefinition(key: "max_tokens", label: "Max Tokens", type: .integer, defaultValue: "\(defaults.defaultMaxTokens)", range: 256...Double(contextWindow), step: 256),
            ModelParameterDefinition(key: "top_p", label: "Top P", type: .decimal, defaultValue: "\(defaults.topP)", range: 0...1, step: 0.05, isAdvanced: true),
            ModelParameterDefinition(key: "top_k", label: "Top K", type: .integer, defaultValue: "\(defaults.topK)", range: 0...100, step: 1, isAdvanced: true),
            ModelParameterDefinition(key: "min_p", label: "Min P", type: .decimal, defaultValue: "\(defaults.minP)", range: 0...1, step: 0.01, isAdvanced: true),
            ModelParameterDefinition(key: "repetition_penalty", label: "Repetition Penalty", type: .decimal, defaultValue: "\(defaults.repetitionPenalty)", range: 0.8...1.5, step: 0.05, isAdvanced: true),
            ModelParameterDefinition(key: "enable_thinking", label: "Reasoning", type: .boolean, defaultValue: "\(defaults.enableThinking)", isAdvanced: true)
        ]
    }

    fileprivate static func chatPresets(defaults: ChatParameterDefaults = .qwen) -> [ModelParameterPreset] {
        return [
            ModelParameterPreset(id: "balanced", label: "Balanced", values: [
                "temperature": "\(defaults.temperature)",
                "max_tokens": "\(defaults.defaultMaxTokens)"
            ]),
            ModelParameterPreset(id: "focused", label: "Focused", values: [
                "temperature": "0.2",
                "top_p": "\(min(defaults.topP, 0.8))"
            ])
        ]
    }

    fileprivate struct ChatParameterDefaults {
        let maxContextWindow: Int
        let defaultMaxTokens: Int
        let temperatureRange: ClosedRange<Double>
        let temperature: Double
        let topP: Double
        let topK: Int
        let minP: Double
        let repetitionPenalty: Double
        let enableThinking: Bool

        static let qwen = ChatParameterDefaults(
            maxContextWindow: 32768,
            defaultMaxTokens: 4096,
            temperatureRange: 0...2,
            temperature: 0.7,
            topP: 0.8,
            topK: 20,
            minP: 0,
            repetitionPenalty: 1,
            enableThinking: false
        )

        static let gemma = ChatParameterDefaults(
            maxContextWindow: 8192,
            defaultMaxTokens: 4096,
            temperatureRange: 0...2,
            temperature: 0.7,
            topP: 1,
            topK: 0,
            minP: 0,
            repetitionPenalty: 1,
            enableThinking: false
        )

        init(
            maxContextWindow: Int,
            defaultMaxTokens: Int,
            temperatureRange: ClosedRange<Double>,
            temperature: Double,
            topP: Double,
            topK: Int,
            minP: Double,
            repetitionPenalty: Double,
            enableThinking: Bool
        ) {
            self.maxContextWindow = maxContextWindow
            self.defaultMaxTokens = defaultMaxTokens
            self.temperatureRange = temperatureRange
            self.temperature = temperature
            self.topP = topP
            self.topK = topK
            self.minP = minP
            self.repetitionPenalty = repetitionPenalty
            self.enableThinking = enableThinking
        }
    }

    private static func isRecommendationSortedBefore(
        _ lhs: ModelCapabilityProfile,
        _ rhs: ModelCapabilityProfile,
        hardwareMemoryGB: Double
    ) -> Bool {
        let lhsCompatible = lhs.isRuntimeCompatible()
        let rhsCompatible = rhs.isRuntimeCompatible()
        if lhsCompatible != rhsCompatible {
            return lhsCompatible
        }

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
        -profile.ranking.quality
    }

    private static func lightweightRank(_ profile: ModelCapabilityProfile) -> Int {
        -profile.ranking.speed
    }
}

enum EmergencyModelCatalog {
    static let profiles: [ModelCapabilityProfile] = [
        chatProfile(
            name: "Qwen 3.5 2B",
            subtitle: "Lightweight vision model (2B parameters)",
            modelId: "mlx-community/Qwen3.5-2B-MLX-4bit",
            maxContextWindow: 32768,
            memoryRequirementGB: 3.0,
            downloadSizeGB: 1.5,
            icon: "bolt",
            ranking: ModelRanking(quality: 70, speed: 92, defaultForMemoryGB: 4)
        )
    ]

    private static func chatProfile(
        name: String,
        subtitle: String,
        modelId: String,
        maxContextWindow: Int,
        memoryRequirementGB: Double,
        downloadSizeGB: Double,
        icon: String,
        ranking: ModelRanking,
        parameterDefaults: ModelCapabilityProfile.ChatParameterDefaults = .qwen
    ) -> ModelCapabilityProfile {
        ModelCapabilityProfile(
            id: modelId,
            name: name,
            subtitle: subtitle,
            modelId: modelId,
            modality: .vision,
            backend: .vlm,
            icon: icon,
            capabilities: ["chat", "vision"],
            maxContextWindow: maxContextWindow,
            defaultMaxTokens: 4096,
            downloadSizeGB: downloadSizeGB,
            estimatedMemoryGB: memoryRequirementGB,
            ranking: ranking,
            parameters: ModelCapabilityProfile.chatParameters(defaults: parameterDefaults, maxContextWindow: maxContextWindow),
            presets: ModelCapabilityProfile.chatPresets(defaults: parameterDefaults)
        )
    }
}
