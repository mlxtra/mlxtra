import Foundation

struct ModelListSortKey: Comparable {
    let fitRank: Int
    let stateRank: Int
    let memoryRank: Double
    let name: String

    static func < (lhs: ModelListSortKey, rhs: ModelListSortKey) -> Bool {
        if lhs.fitRank != rhs.fitRank {
            return lhs.fitRank < rhs.fitRank
        }
        if lhs.stateRank != rhs.stateRank {
            return lhs.stateRank < rhs.stateRank
        }
        if lhs.memoryRank != rhs.memoryRank {
            return lhs.memoryRank < rhs.memoryRank
        }
        return lhs.name < rhs.name
    }
}

struct ModelSettingsModelSorter {
    static func sorted(
        models: [DownloadableModel],
        selectedModelId: String?,
        recommendedModelId: String?,
        state: (DownloadableModel) -> ModelDownloadManager.DownloadState,
        hardwareMemoryGB: Double = SystemHardware.currentMemoryGB,
        runtimeManifest: RuntimeManifest? = RuntimeManager.activeRuntimeManifest()
    ) -> [DownloadableModel] {
        models.sorted { lhs, rhs in
            sortKey(
                for: lhs,
                selectedModelId: selectedModelId,
                recommendedModelId: recommendedModelId,
                state: state(lhs),
                hardwareMemoryGB: hardwareMemoryGB,
                runtimeManifest: runtimeManifest
            ) < sortKey(
                for: rhs,
                selectedModelId: selectedModelId,
                recommendedModelId: recommendedModelId,
                state: state(rhs),
                hardwareMemoryGB: hardwareMemoryGB,
                runtimeManifest: runtimeManifest
            )
        }
    }

    private static func sortKey(
        for model: DownloadableModel,
        selectedModelId: String?,
        recommendedModelId: String?,
        state: ModelDownloadManager.DownloadState,
        hardwareMemoryGB: Double,
        runtimeManifest: RuntimeManifest?
    ) -> ModelSettingsSortKey {
        ModelSettingsSortKey(
            defaultRank: selectedModelId == model.modelId && state == .downloaded ? 0 : 1,
            recommendedRank: recommendedModelId == model.modelId ? 0 : 1,
            runtimeRank: isRuntimeCompatible(model, manifest: runtimeManifest) ? 0 : 1,
            stateRank: state.sortRank,
            fitRank: ModelFit
                .classify(estimatedMemoryGB: model.estimatedMemoryGB, hardwareMemoryGB: hardwareMemoryGB)
                .settingsSortRank,
            sizeRank: model.downloadSizeGB,
            name: model.name
        )
    }

    private static func isRuntimeCompatible(_ model: DownloadableModel, manifest: RuntimeManifest?) -> Bool {
        model.runtime.isSatisfied(by: manifest)
            && (manifest?.supports(backend: model.backend) ?? true)
            && (manifest?.supports(runtimeOptions: model.runtimeOptions) ?? true)
    }
}

struct ModelSettingsSortKey: Comparable {
    let defaultRank: Int
    let recommendedRank: Int
    let runtimeRank: Int
    let stateRank: Int
    let fitRank: Int
    let sizeRank: Double
    let name: String

    static func < (lhs: ModelSettingsSortKey, rhs: ModelSettingsSortKey) -> Bool {
        if lhs.defaultRank != rhs.defaultRank { return lhs.defaultRank < rhs.defaultRank }
        if lhs.recommendedRank != rhs.recommendedRank { return lhs.recommendedRank < rhs.recommendedRank }
        if lhs.runtimeRank != rhs.runtimeRank { return lhs.runtimeRank < rhs.runtimeRank }
        if lhs.stateRank != rhs.stateRank { return lhs.stateRank < rhs.stateRank }
        if lhs.fitRank != rhs.fitRank { return lhs.fitRank < rhs.fitRank }
        if lhs.sizeRank != rhs.sizeRank { return lhs.sizeRank < rhs.sizeRank }
        return lhs.name < rhs.name
    }
}
