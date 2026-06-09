import Foundation

struct ModelSelectionStore {
    static let chatKey = "MLXtra.selectedModel.chat"
    static let imageKey = "MLXtra.selectedModel.image"
    static let speechKey = "MLXtra.selectedModel.speech"
    static let musicKey = "MLXtra.selectedModel.music"

    let userDefaults: UserDefaults
    private let activeRuntimeManifestProvider: (RuntimeComponent) -> RuntimeManifest?

    init(
        userDefaults: UserDefaults = .standard,
        activeRuntimeManifestProvider: @escaping (RuntimeComponent) -> RuntimeManifest? = {
            RuntimeManager.activeRuntimeManifest(component: $0)
        }
    ) {
        self.userDefaults = userDefaults
        self.activeRuntimeManifestProvider = activeRuntimeManifestProvider
    }

    func selectedModelId(for modality: ModelModality) -> String? {
        userDefaults.string(forKey: key(for: modality))
    }

    func setSelectedModelId(_ modelId: String, for modality: ModelModality) {
        userDefaults.set(modelId, forKey: key(for: modality))
    }

    func storedProfile(
        for modality: ModelModality,
        hardwareMemoryGB: Double = SystemHardware.currentMemoryGB,
        runtimeManifest: RuntimeManifest? = nil
    ) -> ModelCapabilityProfile? {
        guard let modelId = selectedModelId(for: modality),
              let profile = ModelCapabilityProfile.embeddedProfile(modelId: modelId),
              profile.modality == modality,
              profile.isCatalogVisible else {
            return nil
        }

        return profile
    }

    func selectedProfile(
        for modality: ModelModality,
        hardwareMemoryGB: Double = SystemHardware.currentMemoryGB,
        hardwareChipName: String? = SystemHardware.currentChipName,
        runtimeManifest: RuntimeManifest? = nil
    ) -> ModelCapabilityProfile? {
        if let profile = storedProfile(
            for: modality,
            hardwareMemoryGB: hardwareMemoryGB,
            runtimeManifest: runtimeManifest
        ) {
            return profile
        }

        return ModelCapabilityProfile.bestProfile(
            for: modality,
            hardwareMemoryGB: hardwareMemoryGB,
            hardwareChipName: hardwareChipName,
            runtimeManifestProvider: { profile in
                resolvedRuntimeManifest(for: profile, override: runtimeManifest)
            }
        )
    }

    func selectedAvailableProfile(
        for modality: ModelModality,
        hardwareMemoryGB: Double = SystemHardware.currentMemoryGB,
        hardwareChipName: String? = SystemHardware.currentChipName,
        runtimeManifest: RuntimeManifest? = nil,
        isAvailable: (DownloadableModel) -> Bool
    ) -> ModelCapabilityProfile? {
        if let profile = storedProfile(
            for: modality,
            hardwareMemoryGB: hardwareMemoryGB,
            runtimeManifest: runtimeManifest
        ), isRuntimeCompatible(profile, override: runtimeManifest),
           isAvailable(profile.downloadableModel) {
            return profile
        }

        return availableFallbackProfile(
            for: modality,
            hardwareMemoryGB: hardwareMemoryGB,
            hardwareChipName: hardwareChipName,
            runtimeManifest: runtimeManifest,
            isAvailable: isAvailable
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

    private func availableFallbackProfile(
        for modality: ModelModality,
        hardwareMemoryGB: Double,
        hardwareChipName: String?,
        runtimeManifest: RuntimeManifest?,
        isAvailable: (DownloadableModel) -> Bool
    ) -> ModelCapabilityProfile? {
        let sortedProfiles = ModelCapabilityProfile.sortedProfiles(
            for: modality,
            hardwareMemoryGB: hardwareMemoryGB,
            hardwareChipName: hardwareChipName
        )
        let compatibleProfiles = sortedProfiles.filter { profile in
            guard let manifest = resolvedRuntimeManifest(for: profile, override: runtimeManifest) else {
                return false
            }
            return profile.isRuntimeCompatible(manifest: manifest)
        }
        let candidateProfiles = compatibleProfiles.isEmpty ? sortedProfiles : compatibleProfiles

        return candidateProfiles.first { profile in
            isAvailable(profile.downloadableModel)
        }
    }

    private func resolvedRuntimeManifest(
        for profile: ModelCapabilityProfile,
        override: RuntimeManifest?
    ) -> RuntimeManifest? {
        override ?? activeRuntimeManifestProvider(profile.runtime.component)
    }

    private func isRuntimeCompatible(
        _ profile: ModelCapabilityProfile,
        override: RuntimeManifest?
    ) -> Bool {
        guard let manifest = resolvedRuntimeManifest(for: profile, override: override) else {
            return false
        }
        return profile.isRuntimeCompatible(manifest: manifest)
    }
}

struct ModelParameterStore {
    static let storageKey = "MLXtra.modelParameterValues"

    let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func values(for profile: ModelCapabilityProfile) -> [String: String] {
        let supportedKeys = Set(profile.parameters.map(\.key))
        let saved = migratedValues(storedValues()[profile.modelId] ?? [:], for: profile)
        var resolved = Dictionary(uniqueKeysWithValues: profile.parameters.map { ($0.key, $0.defaultValue) })

        for (key, value) in saved where supportedKeys.contains(key) {
            guard let definition = profile.parameterDefinition(key: key),
                  let normalizedValue = definition.normalizedString(from: value) else {
                continue
            }
            resolved[key] = normalizedValue
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
        for (key, value) in preset.values {
            guard let definition = profile.parameterDefinition(key: key),
                  let normalizedValue = definition.normalizedString(from: value) else {
                continue
            }
            modelValues[key] = normalizedValue
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

    private func migratedValues(_ saved: [String: String], for profile: ModelCapabilityProfile) -> [String: String] {
        guard profile.modelId == "bosonai/higgs-audio-v3-tts-4b" else { return saved }

        var migrated = saved
        switch normalizeHiggsValue(saved["voice"]) {
        case "bright", "calm", "serious", "sad":
            if migrated["emotion"] == nil {
                migrated["emotion"] = normalizeHiggsValue(saved["voice"])
            }
            migrated["voice"] = "default"
        case "custom reference":
            migrated["voice"] = "custom_reference"
        default:
            break
        }
        return migrated
    }

    private func normalizeHiggsValue(_ value: String?) -> String {
        (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .joined(separator: " ")
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
    let runtimeOptions: ModelRuntimeOptions?
    let acceleration: ModelAcceleration?

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
        runtime: ModelRuntimeRequirement = ModelRuntimeRequirement(),
        runtimeOptions: ModelRuntimeOptions? = nil,
        acceleration: ModelAcceleration? = nil
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
        self.runtimeOptions = runtimeOptions
        self.acceleration = acceleration
    }

    static func embeddedModel(modelId: String) -> DownloadableModel? {
        ModelCapabilityProfile.embeddedProfile(modelId: modelId)?.downloadableModel
    }

    static var embedded: [DownloadableModel] {
        ModelCapabilityProfile.embedded
            .filter(\.isCatalogVisible)
            .map(\.downloadableModel)
    }

    var isRuntimeCompatible: Bool {
        isRuntimeCompatible(with: nil)
    }

    var totalDownloadSizeGB: Double {
        downloadSizeGB + (acceleration?.downloadSizeGB ?? 0)
    }

    var snapshotRequirements: [ModelSnapshotRequirement] {
        var requirements: [ModelSnapshotRequirement] = []
        if !source.usesComponentBundle {
            requirements.append(ModelSnapshotRequirement(
                modelId: source.downloadRepository ?? modelId,
                revision: source.revision ?? "main",
                purpose: .base
            ))
        }
        if let accelerationRequirement = acceleration?.snapshotRequirement {
            requirements.append(accelerationRequirement)
        }
        return requirements
    }

    func isRuntimeCompatible(with manifest: RuntimeManifest?) -> Bool {
        let manifest = manifest ?? RuntimeManager.activeRuntimeManifest(component: runtime.component)
        return runtime.isSatisfied(by: manifest)
            && (manifest?.supports(backend: backend) ?? false)
            && (manifest?.supports(runtimeOptions: runtimeOptions) ?? false)
    }

    func requiresRuntimeSetupBeforeDownload(manifest: RuntimeManifest? = nil) -> Bool {
        source.usesComponentBundle
            && source.helper != nil
            && !isRuntimeCompatible(with: manifest)
    }
}
