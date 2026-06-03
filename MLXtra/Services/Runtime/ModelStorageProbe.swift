import Foundation

extension RuntimeManager {
    func isModelDownloaded(modelId: String) -> Bool {
        Self.isModelDownloaded(modelId: modelId, checkpointsPath: checkpointsPath)
    }

    nonisolated static func isModelDownloaded(
        modelId: String,
        checkpointsPath: URL,
        huggingFaceCacheRoot: URL = RuntimeManager.huggingFaceCacheRoot()
    ) -> Bool {
        modelStorageStatus(
            modelId: modelId,
            checkpointsPath: checkpointsPath,
            huggingFaceCacheRoot: huggingFaceCacheRoot
        ).isDownloaded
    }

    func modelStorageStatus(modelId: String) -> ModelStorageStatus {
        Self.modelStorageStatus(modelId: modelId, checkpointsPath: checkpointsPath)
    }

    nonisolated static func modelStorageStatus(
        modelId: String,
        checkpointsPath: URL,
        huggingFaceCacheRoot: URL = RuntimeManager.huggingFaceCacheRoot()
    ) -> ModelStorageStatus {
        if let model = embeddedModelForRuntimeLookup(modelId: modelId) {
            return modelStorageStatus(
                model: model,
                checkpointsPath: checkpointsPath,
                huggingFaceCacheRoot: huggingFaceCacheRoot
            )
        }

        return huggingFaceModelStorageStatus(
            modelId: modelId,
            huggingFaceCacheRoot: huggingFaceCacheRoot
        )
    }

    private nonisolated static func huggingFaceModelStorageStatus(
        modelId: String,
        revision: String = "main",
        huggingFaceCacheRoot: URL
    ) -> ModelStorageStatus {
        let path = modelCachePath(modelId: modelId, huggingFaceCacheRoot: huggingFaceCacheRoot)
        RuntimeDiagnostics.log("[RuntimeManager] Checking HF cache for \(modelId) at \(path.path)")

        guard FileManager.default.fileExists(atPath: path.path),
              let contents = try? FileManager.default.contentsOfDirectory(atPath: path.path),
              !contents.isEmpty else {
            RuntimeDiagnostics.log("[RuntimeManager] Model \(modelId) not in HF cache")
            return .missing
        }

        let snapshotsPath = path.appendingPathComponent("snapshots")
        var markerIncompleteMessage: String?
        if FileManager.default.fileExists(atPath: snapshotsPath.path) {
            for snapshotPath in Self.snapshotCandidates(modelCachePath: path, snapshotsPath: snapshotsPath, revision: revision) {
                if let nativeStatus = Self.nativeSnapshotStorageStatus(snapshotPath) {
                    switch nativeStatus {
                    case .downloaded:
                        RuntimeDiagnostics.log("[RuntimeManager] Model \(modelId) found in native HF cache at \(snapshotPath.path)")
                        return .downloaded
                    case .incomplete(let message):
                        markerIncompleteMessage = markerIncompleteMessage ?? message
                        continue
                    case .missing:
                        continue
                    }
                }
                if Self.snapshotContainsModelFiles(snapshotPath) {
                    RuntimeDiagnostics.log("[RuntimeManager] Model \(modelId) found in HF cache at \(snapshotPath.path)")
                    return .downloaded
                }
            }
        }

        if let markerIncompleteMessage {
            RuntimeDiagnostics.log("[RuntimeManager] Model \(modelId) native HF cache is incomplete")
            return .incomplete(markerIncompleteMessage)
        }

        RuntimeDiagnostics.log("[RuntimeManager] Model \(modelId) cache is incomplete")
        return .incomplete("Local Hugging Face cache is incomplete. Repair will verify the snapshot and redownload missing files.")
    }

    nonisolated static func modelStorageStatus(
        model: DownloadableModel,
        checkpointsPath: URL,
        huggingFaceCacheRoot: URL = RuntimeManager.huggingFaceCacheRoot()
    ) -> ModelStorageStatus {
        if model.source.usesComponentBundle {
            if model.source.helper == .aceStep {
                return aceStepModelStorageStatus(
                    checkpointsPath: checkpointsPath,
                    repoID: model.source.downloadRepository ?? model.modelId,
                    components: model.source.components
                )
            }
            return componentBundleStorageStatus(
                checkpointsPath: checkpointsPath,
                components: model.source.components
            )
        }

        return huggingFacePackageStorageStatus(
            requirements: model.snapshotRequirements,
            huggingFaceCacheRoot: huggingFaceCacheRoot
        )
    }

    private nonisolated static func huggingFacePackageStorageStatus(
        requirements: [ModelSnapshotRequirement],
        huggingFaceCacheRoot: URL
    ) -> ModelStorageStatus {
        guard let baseRequirement = requirements.first(where: { $0.purpose == .base }) else {
            return .incomplete("Model package is missing base snapshot metadata.")
        }

        switch huggingFaceModelStorageStatus(
            modelId: baseRequirement.modelId,
            revision: baseRequirement.revision,
            huggingFaceCacheRoot: huggingFaceCacheRoot
        ) {
        case .downloaded:
            break
        case .missing:
            return .missing
        case .incomplete(let message):
            return .incomplete(message)
        }

        for requirement in requirements where requirement.purpose == .acceleration {
            switch huggingFaceModelStorageStatus(
                modelId: requirement.modelId,
                revision: requirement.revision,
                huggingFaceCacheRoot: huggingFaceCacheRoot
            ) {
            case .downloaded:
                continue
            case .missing:
                return .incomplete("Model update required: acceleration files are missing. Update will download the included acceleration files.")
            case .incomplete(let message):
                return .incomplete("Model update required: acceleration files are incomplete. Update will verify the included acceleration files. \(message)")
            }
        }

        return .downloaded
    }

    private nonisolated static func aceStepModelStorageStatus(
        checkpointsPath: URL,
        repoID: String,
        components: [String]
    ) -> ModelStorageStatus {
        if let contractStatus = aceStepContractStorageStatus(
            checkpointsPath: checkpointsPath,
            expectedRepoID: repoID,
            expectedComponents: components
        ) {
            switch contractStatus {
            case .downloaded:
                break
            case .missing, .incomplete:
                return contractStatus
            }
        }
        return componentBundleStorageStatus(checkpointsPath: checkpointsPath, components: components)
    }

    private nonisolated static func componentBundleStorageStatus(
        checkpointsPath: URL,
        components: [String]
    ) -> ModelStorageStatus {
        let requiredComponents = components
        let checkpointsDir = checkpointsPath
        var foundAnyComponent = false
        var incompleteComponents: [String] = []

        guard !requiredComponents.isEmpty else {
            return .incomplete("Component bundle is missing component metadata.")
        }

        RuntimeDiagnostics.log("[RuntimeManager] Checking component bundle at \(checkpointsDir.path)")

        for component in requiredComponents {
            let componentPath = checkpointsDir.appendingPathComponent(component)
            if !FileManager.default.fileExists(atPath: componentPath.path) {
                RuntimeDiagnostics.log("[RuntimeManager] Component missing: \(componentPath.path)")
                incompleteComponents.append(component)
                continue
            }
            foundAnyComponent = true
            if !Self.containsModelWeights(at: componentPath) {
                RuntimeDiagnostics.log("[RuntimeManager] Component missing weight files: \(componentPath.path)")
                incompleteComponents.append(component)
                continue
            }
            RuntimeDiagnostics.log("[RuntimeManager] Component found with weights: \(componentPath.path)")
        }

        if !incompleteComponents.isEmpty {
            guard foundAnyComponent else { return .missing }
            return .incomplete("Model components are incomplete: \(incompleteComponents.joined(separator: ", ")). Repair will redownload missing components.")
        }

        RuntimeDiagnostics.log("[RuntimeManager] Component bundle fully downloaded at \(checkpointsDir.path)")
        return .downloaded
    }

    private nonisolated static func aceStepContractStorageStatus(
        checkpointsPath: URL,
        expectedRepoID: String,
        expectedComponents: [String]
    ) -> ModelStorageStatus? {
        let inProgressURL = checkpointsPath.appendingPathComponent(AceStepContractCompletionManifest.inProgressFilename)
        if FileManager.default.fileExists(atPath: inProgressURL.path) {
            return .incomplete("ACE-Step contract validation is incomplete. Repair will verify model code and checkpoints.")
        }

        let completionURL = checkpointsPath.appendingPathComponent(AceStepContractCompletionManifest.filename)
        guard FileManager.default.fileExists(atPath: completionURL.path) else {
            return nil
        }

        guard let data = try? Data(contentsOf: completionURL),
              let marker = try? JSONDecoder().decode(AceStepContractCompletionManifest.self, from: data),
              marker.schemaVersion == AceStepContractCompletionManifest.currentSchemaVersion,
              marker.repoID == expectedRepoID,
              Set(marker.requiredComponents) == Set(expectedComponents) else {
            return .incomplete("ACE-Step contract marker is invalid. Repair will verify model code and checkpoints.")
        }

        return .downloaded
    }
}
