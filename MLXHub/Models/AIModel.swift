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

    // MARK: - Model Configuration

    /// HuggingFace model ID for mlx-vlm
    var modelId: String {
        legacyProfile.modelId
    }

    /// Maximum context window size (in tokens)
    var maxContextWindow: Int {
        legacyProfile.maxContextWindow
    }

    /// Default max tokens for generation
    var defaultMaxTokens: Int {
        legacyProfile.defaultMaxTokens
    }

    /// Estimated memory requirement in GB
    var memoryRequirementGB: Double {
        legacyProfile.estimatedMemoryGB ?? 0
    }

    /// Model download size in GB
    var downloadSizeGB: Double {
        legacyProfile.downloadSizeGB
    }

    /// Whether the model supports vision (images)
    var supportsVision: Bool {
        legacyProfile.supportsVision
    }

    /// Temperature range (min, max, default)
    var temperatureRange: (min: Double, max: Double, default: Double) {
        let parameter = legacyProfile.parameterDefinition(key: "temperature")
        return (
            parameter?.range?.lowerBound ?? 0,
            parameter?.range?.upperBound ?? 2,
            Double(parameter?.defaultValue ?? "") ?? 0.7
        )
    }

    /// Nucleus sampling value used by the runtime.
    var topP: Double {
        parameterDefault("top_p", fallback: 1.0)
    }

    /// Top-k sampling value used by the runtime.
    var topK: Int {
        Int(parameterDefault("top_k", fallback: 0))
    }

    /// Minimum probability threshold used by the runtime.
    var minP: Double {
        parameterDefault("min_p", fallback: 0)
    }

    /// Repetition penalty used by the runtime.
    var repetitionPenalty: Double {
        parameterDefault("repetition_penalty", fallback: 1.0)
    }

    /// Whether to ask the model chat template for reasoning content.
    var enableThinking: Bool {
        legacyProfile.parameterDefinition(key: "enable_thinking")?.defaultValue.lowercased() == "true"
    }

    /// Backend type
    var backend: RuntimeBackend {
        legacyProfile.backend
    }

    /// Icon for the model
    var icon: String {
        legacyProfile.icon
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

struct ReleaseChannelManifest: Codable, Equatable {
    let schemaVersion: Int
    let channel: String
    let catalog: CatalogReleaseAsset
    let runtimes: [RuntimeReleaseAsset]

    static let defaultChannelURL = URL(string: "https://github.com/kimistudio/MLXHub/releases/latest/download/stable-channel.json")!
}

struct CatalogReleaseAsset: Codable, Equatable {
    let version: String
    let url: URL
    let sha256: String
    let sizeBytes: Int64?
}

struct RuntimeReleaseAsset: Codable, Equatable, Identifiable {
    let version: String
    let platform: String
    let arch: String
    let url: URL
    let sha256: String
    let sizeBytes: Int64?
    let compatibilityApi: Int

    var id: String { "\(platform)-\(arch)-\(version)" }
}

struct ModelCatalog: Codable, Equatable {
    let schemaVersion: Int
    let catalogVersion: String
    let minAppVersion: String?
    let models: [ModelCapabilityProfile]

    var profiles: [ModelCapabilityProfile] { models }
}

enum ModelCatalogError: LocalizedError, Equatable {
    case unsupportedSchema(Int)
    case incompatibleAppVersion(String)
    case checksumMismatch
    case emptyCatalog
    case duplicateModelId(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            return "Unsupported model catalog schema \(version)"
        case .incompatibleAppVersion(let version):
            return "Model catalog requires MLXHub \(version) or newer"
        case .checksumMismatch:
            return "Model catalog checksum did not match"
        case .emptyCatalog:
            return "Model catalog does not contain any models"
        case .duplicateModelId(let id):
            return "Model catalog contains duplicate model id \(id)"
        }
    }
}

final class ModelCatalogService: ObservableObject, @unchecked Sendable {
    static let shared = ModelCatalogService()

    @Published private(set) var catalog: ModelCatalog
    @Published private(set) var lastRefreshError: String?

    var profiles: [ModelCapabilityProfile] {
        catalog.profiles
    }

    init(
        fileManager: FileManager = .default,
        bundle: Bundle? = nil,
        loadCachedCatalog: Bool = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
        loadBundledCatalog: Bool = true
    ) {
        self.fileManager = fileManager
        self.bundle = bundle
        self.catalog = Self.loadInitialCatalog(
            fileManager: fileManager,
            bundle: bundle,
            loadCachedCatalog: loadCachedCatalog,
            loadBundledCatalog: loadBundledCatalog
        )
    }

    func profile(legacyModel: AIModel) -> ModelCapabilityProfile? {
        profiles.first { $0.aiModel == legacyModel }
    }

    func profile(modelId: String) -> ModelCapabilityProfile? {
        profiles.first { $0.modelId == modelId }
    }

    @MainActor
    func refreshFromStableChannel(
        channelURL: URL = ReleaseChannelManifest.defaultChannelURL
    ) async {
        do {
            let (channelData, _) = try await URLSession.shared.data(from: channelURL)
            let channel = try JSONDecoder.catalogDecoder.decode(ReleaseChannelManifest.self, from: channelData)
            let (catalogData, _) = try await URLSession.shared.data(from: channel.catalog.url)
            let refreshed = try Self.decodeCatalog(
                data: catalogData,
                expectedSHA256: channel.catalog.sha256,
                appVersion: Self.currentAppVersion
            )
            try saveCachedCatalog(catalogData)
            catalog = refreshed
            lastRefreshError = nil
        } catch {
            lastRefreshError = error.localizedDescription
        }
    }

    static func decodeCatalog(
        data: Data,
        expectedSHA256: String? = nil,
        appVersion: String? = currentAppVersion
    ) throws -> ModelCatalog {
        if let expectedSHA256, !expectedSHA256.isEmpty {
            guard SHA256Checksum.hexDigest(for: data).caseInsensitiveCompare(expectedSHA256) == .orderedSame else {
                throw ModelCatalogError.checksumMismatch
            }
        }

        let catalog = try JSONDecoder.catalogDecoder.decode(ModelCatalog.self, from: data)
        try validate(catalog, appVersion: appVersion)
        return catalog
    }

    private let fileManager: FileManager
    private let bundle: Bundle?

    private static func loadInitialCatalog(
        fileManager: FileManager,
        bundle: Bundle?,
        loadCachedCatalog: Bool,
        loadBundledCatalog: Bool
    ) -> ModelCatalog {
        if loadCachedCatalog,
           let data = try? Data(contentsOf: cachedCatalogURL(fileManager: fileManager)),
           let catalog = try? decodeCatalog(data: data) {
            return catalog
        }

        if loadBundledCatalog,
           let data = bundledCatalogData(bundle: bundle),
           let catalog = try? decodeCatalog(data: data) {
            return catalog
        }

        return legacyFallbackCatalog
    }

    private static func validate(_ catalog: ModelCatalog, appVersion: String?) throws {
        guard catalog.schemaVersion == 1 else {
            throw ModelCatalogError.unsupportedSchema(catalog.schemaVersion)
        }
        guard !catalog.models.isEmpty else {
            throw ModelCatalogError.emptyCatalog
        }
        if let minAppVersion = catalog.minAppVersion,
           let appVersion,
           VersionComparator.compare(appVersion, minAppVersion) == .orderedAscending {
            throw ModelCatalogError.incompatibleAppVersion(minAppVersion)
        }

        var seen = Set<String>()
        for profile in catalog.models {
            guard seen.insert(profile.id).inserted else {
                throw ModelCatalogError.duplicateModelId(profile.id)
            }
        }
    }

    private static func bundledCatalogData(bundle explicitBundle: Bundle?) -> Data? {
        let bundles: [Bundle] = {
            if let explicitBundle {
                return [explicitBundle]
            }
#if SWIFT_PACKAGE
            return [Bundle.module, Bundle.main]
#else
            return [Bundle.main]
#endif
        }()

        for bundle in bundles {
            if let url = bundle.url(forResource: "model-catalog", withExtension: "json"),
               let data = try? Data(contentsOf: url) {
                return data
            }
        }
        return nil
    }

    private func saveCachedCatalog(_ data: Data) throws {
        let url = Self.cachedCatalogURL(fileManager: fileManager)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private static func cachedCatalogURL(fileManager: FileManager) -> URL {
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
        return baseURL
            .appendingPathComponent("MLXHub")
            .appendingPathComponent("Catalog")
            .appendingPathComponent("model-catalog.json")
    }

    private static var currentAppVersion: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    private static var legacyFallbackCatalog: ModelCatalog {
        ModelCatalog(
            schemaVersion: 1,
            catalogVersion: "fallback",
            minAppVersion: nil,
            models: LegacyModelCatalog.profiles
        )
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

struct ModelSource: Codable, Equatable {
    let type: ModelSourceType
    let repo: String?
    let revision: String?
    let components: [String]

    init(
        type: ModelSourceType,
        repo: String? = nil,
        revision: String? = nil,
        components: [String] = []
    ) {
        self.type = type
        self.repo = repo
        self.revision = revision
        self.components = components
    }

    static func defaultSource(modelId: String) -> ModelSource {
        if modelId.hasPrefix("ACE-Step/") {
            return ModelSource(
                type: .componentBundle,
                repo: modelId,
                components: ["acestep-v15-turbo", "vae", "Qwen3-Embedding-0.6B", "acestep-5Hz-lm-1.7B"]
            )
        }
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
        guard let manifest else { return true }
        guard manifest.compatibilityApi == compatibilityApi else { return false }
        return VersionComparator.compare(manifest.runtimeVersion, minVersion) != .orderedAscending
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
    let ranking: ModelRanking
    let parameters: [ModelParameterDefinition]
    let presets: [ModelParameterPreset]
    let aiModel: AIModel?

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
        ranking: ModelRanking = ModelRanking(),
        parameters: [ModelParameterDefinition],
        presets: [ModelParameterPreset],
        aiModel: AIModel?
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
        self.ranking = ranking
        self.parameters = parameters
        self.presets = presets
        self.aiModel = aiModel
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
            runtime: runtime
        )
    }

    var supportsVision: Bool {
        capabilities.contains("vision")
    }

    func fit(hardwareMemoryGB: Double = AIModel.currentHardwareMemoryGB) -> ModelFit {
        ModelFit.classify(estimatedMemoryGB: estimatedMemoryGB, hardwareMemoryGB: hardwareMemoryGB)
    }

    func isRuntimeCompatible(manifest: RuntimeManifest? = RuntimeManager.activeRuntimeManifest()) -> Bool {
        runtime.isSatisfied(by: manifest) && (manifest?.supports(backend: backend) ?? true)
    }

    func parameterDefinition(key: String) -> ModelParameterDefinition? {
        parameters.first { $0.key == key }
    }

    static var embedded: [ModelCapabilityProfile] {
        ModelCatalogService.shared.profiles
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
        hardwareMemoryGB: Double = AIModel.currentHardwareMemoryGB
    ) -> [ModelCapabilityProfile] {
        profiles(for: modality).sorted { lhs, rhs in
            isRecommendationSortedBefore(lhs, rhs, hardwareMemoryGB: hardwareMemoryGB)
        }
    }

    fileprivate static func chatParameters(for model: AIModel) -> [ModelParameterDefinition] {
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

    fileprivate static func chatPresets(for model: AIModel) -> [ModelParameterPreset] {
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
        if profile.ranking.quality != 0 {
            return -profile.ranking.quality
        }

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

private enum LegacyModelCatalog {
    static let profiles: [ModelCapabilityProfile] = [
        chatProfile(
            aiModel: .qwen35,
            subtitle: "Vision language model (9B parameters)",
            modelId: "mlx-community/Qwen3.5-9B-MLX-4bit",
            maxContextWindow: 32768,
            memoryRequirementGB: 6.0,
            downloadSizeGB: 5.6,
            icon: "eye",
            ranking: ModelRanking(quality: 100, speed: 62, defaultForMemoryGB: 16)
        ),
        chatProfile(
            aiModel: .gemma4,
            subtitle: "Google vision model (4B parameters)",
            modelId: "google/gemma-4-e4b-it",
            maxContextWindow: 8192,
            memoryRequirementGB: 3.0,
            downloadSizeGB: 2.5,
            icon: "sparkles",
            ranking: ModelRanking(quality: 82, speed: 78, defaultForMemoryGB: 8)
        ),
        chatProfile(
            aiModel: .mini,
            subtitle: "Lightweight vision model (2B parameters)",
            modelId: "mlx-community/Qwen3.5-2B-MLX-4bit",
            maxContextWindow: 32768,
            memoryRequirementGB: 3.0,
            downloadSizeGB: 1.5,
            icon: "bolt",
            ranking: ModelRanking(quality: 70, speed: 92, defaultForMemoryGB: 4)
        ),
        ModelCapabilityProfile(
            id: "black-forest-labs/FLUX.2-klein-4B",
            name: "FLUX.2-klein-4B",
            subtitle: "Image generation model",
            modelId: "black-forest-labs/FLUX.2-klein-4B",
            modality: .image,
            backend: .image,
            icon: "photo",
            capabilities: ["image-generation", "image-editing"],
            downloadSizeGB: 15.0,
            estimatedMemoryGB: 13.0,
            ranking: ModelRanking(quality: 100, speed: 70),
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
            backend: .audio,
            icon: "waveform",
            capabilities: ["speech-generation"],
            downloadSizeGB: 15.0,
            estimatedMemoryGB: 19.0,
            ranking: ModelRanking(quality: 100, speed: 55),
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
            backend: .music,
            icon: "music.note",
            capabilities: ["music-generation"],
            downloadSizeGB: 4.8,
            estimatedMemoryGB: 4.0,
            ranking: ModelRanking(quality: 100, speed: 85),
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

    private static func chatProfile(
        aiModel: AIModel,
        subtitle: String,
        modelId: String,
        maxContextWindow: Int,
        memoryRequirementGB: Double,
        downloadSizeGB: Double,
        icon: String,
        ranking: ModelRanking
    ) -> ModelCapabilityProfile {
        ModelCapabilityProfile(
            id: modelId,
            name: aiModel.rawValue,
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
            parameters: ModelCapabilityProfile.chatParameters(for: aiModel),
            presets: ModelCapabilityProfile.chatPresets(for: aiModel),
            aiModel: aiModel
        )
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
    let backend: RuntimeBackend
    let downloadSizeGB: Double
    let estimatedMemoryGB: Double?
    let source: ModelSource
    let runtime: ModelRuntimeRequirement

    init(
        id: String,
        name: String,
        subtitle: String,
        modelId: String,
        modality: ModelModality,
        backend: RuntimeBackend = .vlm,
        downloadSizeGB: Double,
        estimatedMemoryGB: Double? = nil,
        source: ModelSource? = nil,
        runtime: ModelRuntimeRequirement = ModelRuntimeRequirement()
    ) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.modelId = modelId
        self.modality = modality
        self.backend = backend
        self.downloadSizeGB = downloadSizeGB
        self.estimatedMemoryGB = estimatedMemoryGB
        self.source = source ?? ModelSource.defaultSource(modelId: modelId)
        self.runtime = runtime
    }

    static func embeddedModel(modelId: String) -> DownloadableModel? {
        embedded.first { $0.modelId == modelId }
    }

    static var embedded: [DownloadableModel] {
        ModelCapabilityProfile.embedded.map(\.downloadableModel)
    }

    var isRuntimeCompatible: Bool {
        runtime.isSatisfied(by: RuntimeManager.activeRuntimeManifest())
            && (RuntimeManager.activeRuntimeManifest()?.supports(backend: backend) ?? true)
    }
}

enum VersionComparator {
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let lhsParts = numericParts(lhs)
        let rhsParts = numericParts(rhs)
        let count = max(lhsParts.count, rhsParts.count)

        for index in 0..<count {
            let left = index < lhsParts.count ? lhsParts[index] : 0
            let right = index < rhsParts.count ? rhsParts[index] : 0
            if left < right { return .orderedAscending }
            if left > right { return .orderedDescending }
        }
        return .orderedSame
    }

    private static func numericParts(_ version: String) -> [Int] {
        version
            .split { character in
                character == "." || character == "-" || character == "+"
            }
            .map { part in
                Int(part.prefix { $0.isNumber }) ?? 0
            }
    }
}

private extension JSONDecoder {
    static var catalogDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .useDefaultKeys
        return decoder
    }
}
