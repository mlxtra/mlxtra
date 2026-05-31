import Foundation

extension RuntimeManager {
    func modelCachePath(modelId: String) -> URL {
        Self.modelCachePath(modelId: modelId)
    }

    nonisolated static func huggingFaceCacheRoot(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub")
    }

    nonisolated static func modelCachePath(
        modelId: String,
        huggingFaceCacheRoot: URL = RuntimeManager.huggingFaceCacheRoot()
    ) -> URL {
        huggingFaceCacheRoot
            .appendingPathComponent("models--" + modelId.replacingOccurrences(of: "/", with: "--"))
    }

    nonisolated static func embeddedModelForRuntimeLookup(modelId: String) -> DownloadableModel? {
        if let model = DownloadableModel.embeddedModel(modelId: modelId) {
            return model
        }

        guard let aceStepLocalId = aceStepLocalModelId(modelId) else {
            return nil
        }

        return ModelCapabilityProfile.embedded.first { profile in
            guard profile.source.helper == .aceStep else { return false }
            return profile.source.components.contains { component in
                guard component.hasPrefix("acestep-v15-") else { return false }
                return aceStepLocalId == component || aceStepLocalId.hasPrefix(component + "-")
            }
        }?.downloadableModel
    }

    private nonisolated static func aceStepLocalModelId(_ modelId: String) -> String? {
        let namespace = "ACE-Step/"
        if modelId.hasPrefix(namespace) {
            return String(modelId.dropFirst(namespace.count))
        }
        if modelId.hasPrefix("acestep-") {
            return modelId
        }
        return nil
    }

    /// Hugging Face models use the default HF cache so downloads can be shared with other apps.
    func modelStoragePath(modelId: String) -> URL {
        if let model = Self.embeddedModelForRuntimeLookup(modelId: modelId) {
            return modelStoragePath(for: model)
        }
        return modelCachePath(modelId: modelId)
    }

    func modelStoragePath(for model: DownloadableModel) -> URL {
        if model.source.usesComponentBundle {
            return checkpointsPath
        }
        return modelCachePath(modelId: model.source.downloadRepository ?? model.modelId)
    }

    func estimatedModelSize(modelId: String) -> Double {
        ModelCapabilityProfile.embeddedProfile(modelId: modelId)?.downloadSizeGB ?? 5.0
    }
}
