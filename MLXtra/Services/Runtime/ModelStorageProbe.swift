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
            for snapshotPath in Self.snapshotCandidates(modelCachePath: path, snapshotsPath: snapshotsPath) {
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

        return huggingFaceModelStorageStatus(
            modelId: model.source.downloadRepository ?? model.modelId,
            huggingFaceCacheRoot: huggingFaceCacheRoot
        )
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

    private nonisolated static func nativeSnapshotStorageStatus(_ snapshotPath: URL) -> ModelStorageStatus? {
        let inProgressURL = snapshotPath.appendingPathComponent(NativeSnapshotCompletionManifest.inProgressFilename)
        if FileManager.default.fileExists(atPath: inProgressURL.path) {
            return .incomplete("Native model download is still incomplete. Repair will resume and verify missing files.")
        }

        let completionURL = snapshotPath.appendingPathComponent(NativeSnapshotCompletionManifest.filename)
        guard FileManager.default.fileExists(atPath: completionURL.path) else {
            return nil
        }

        guard let data = try? Data(contentsOf: completionURL),
              let marker = try? JSONDecoder().decode(NativeSnapshotCompletionManifest.self, from: data),
              marker.schemaVersion == NativeSnapshotCompletionManifest.currentSchemaVersion,
              !marker.files.isEmpty else {
            return .incomplete("Native model completion marker is invalid. Repair will verify and redownload missing files.")
        }

        let incompleteFiles = marker.manifestFiles.compactMap { file -> String? in
            let fileURL = snapshotPath.appendingPathComponent(file.path)
            return nativeSnapshotFileIsComplete(fileURL, expectedSize: file.size) ? nil : file.path
        }

        guard incompleteFiles.isEmpty else {
            let displayedFiles = incompleteFiles.prefix(3).joined(separator: ", ")
            let suffix = incompleteFiles.count > 3 ? " and \(incompleteFiles.count - 3) more" : ""
            return .incomplete("Native model snapshot is incomplete: \(displayedFiles)\(suffix). Repair will redownload missing files.")
        }

        return .downloaded
    }

    private nonisolated static func nativeSnapshotFileIsComplete(_ fileURL: URL, expectedSize: Int64?) -> Bool {
        let resolvedURL = fileURL.resolvingSymlinksInPath()
        let pathToCheck = resolvedURL.path == fileURL.path ? fileURL.path : resolvedURL.path
        guard FileManager.default.fileExists(atPath: pathToCheck),
              let attributes = try? FileManager.default.attributesOfItem(atPath: pathToCheck),
              let fileType = attributes[.type] as? FileAttributeType,
              fileType == .typeRegular,
              let fileSize = attributes[.size] as? NSNumber else {
            return false
        }

        guard let expectedSize else {
            return fileSize.int64Value > 0
        }
        return fileSize.int64Value == expectedSize
    }

    private nonisolated static func snapshotCandidates(modelCachePath: URL, snapshotsPath: URL) -> [URL] {
        var candidates: [URL] = []
        let refsPath = modelCachePath.appendingPathComponent("refs/main")
        if let revision = try? String(contentsOf: refsPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !revision.isEmpty {
            candidates.append(snapshotsPath.appendingPathComponent(revision))
        }

        guard let snapshots = try? FileManager.default.contentsOfDirectory(
            at: snapshotsPath,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return candidates
        }

        let sortedSnapshots = snapshots
            .filter { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhsDate > rhsDate
            }

        for snapshot in sortedSnapshots where !candidates.contains(snapshot) {
            candidates.append(snapshot)
        }
        return candidates
    }

    nonisolated static func containsModelWeights(at path: URL, maximumDepth: Int = 2) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return false
        }

        let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: path,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return false
        }

        for case let fileURL as URL in enumerator {
            let relativeDepth = Self.relativePathDepth(fileURL, root: path)
            if relativeDepth > maximumDepth {
                if (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard isModelWeightArtifact(fileURL),
                  modelWeightArtifactHasContent(fileURL) else {
                continue
            }
            return true
        }

        return false
    }

    private nonisolated static func weightIndexFiles(at path: URL, maximumDepth: Int = 3) -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let enumerator = FileManager.default.enumerator(
                at: path,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
              ) else {
            return []
        }

        var indexes: [URL] = []
        for case let fileURL as URL in enumerator {
            let relativeDepth = Self.relativePathDepth(fileURL, root: path)
            if relativeDepth > maximumDepth {
                if (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            if Self.isWeightIndexArtifact(fileURL) {
                indexes.append(fileURL)
            }
        }
        return indexes
    }

    private nonisolated static func declaredWeightFilesAreComplete(indexURL: URL) -> Bool {
        guard let data = try? Data(contentsOf: indexURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let weightMap = json["weight_map"] as? [String: String],
              !weightMap.isEmpty else {
            return false
        }

        let baseURL = indexURL.deletingLastPathComponent()
        let declaredFiles = Set(weightMap.values)
        guard !declaredFiles.isEmpty else { return false }

        for filename in declaredFiles {
            let weightURL = baseURL.appendingPathComponent(filename)
            guard Self.isModelWeightArtifact(weightURL),
                  Self.modelWeightArtifactHasContent(weightURL) else {
                return false
            }
        }
        return true
    }

    private nonisolated static func modelWeightArtifactHasContent(_ fileURL: URL) -> Bool {
        let resolvedURL = fileURL.resolvingSymlinksInPath()
        let pathToCheck = resolvedURL.path == fileURL.path ? fileURL.path : resolvedURL.path

        guard FileManager.default.fileExists(atPath: pathToCheck),
              let attributes = try? FileManager.default.attributesOfItem(atPath: pathToCheck),
              let fileType = attributes[.type] as? FileAttributeType,
              fileType == .typeRegular,
              let fileSize = attributes[.size] as? NSNumber else {
            return false
        }

        return fileSize.int64Value > 0
    }

    nonisolated static func snapshotContainsModelFiles(_ snapshotPath: URL) -> Bool {
        guard snapshotContainsModelMetadata(snapshotPath) else { return false }

        let indexes = weightIndexFiles(at: snapshotPath)
        if !indexes.isEmpty {
            return indexes.allSatisfy { declaredWeightFilesAreComplete(indexURL: $0) }
        }

        return containsModelWeights(at: snapshotPath)
    }

    private nonisolated static func snapshotContainsModelMetadata(_ snapshotPath: URL) -> Bool {
        let metadataFilenames = [
            "config.json",
            "model_index.json",
            "tokenizer_config.json",
            "preprocessor_config.json",
            "processor_config.json"
        ]

        for filename in metadataFilenames {
            if FileManager.default.fileExists(atPath: snapshotPath.appendingPathComponent(filename).path) {
                return true
            }
        }

        let subdirectories = ["transformer", "vae", "unet", "text_encoder"]
        for subdir in subdirectories {
            let subdirPath = snapshotPath.appendingPathComponent(subdir)
            for filename in metadataFilenames {
                if FileManager.default.fileExists(atPath: subdirPath.appendingPathComponent(filename).path) {
                    return true
                }
            }
        }

        return false
    }

    private nonisolated static func relativePathDepth(_ fileURL: URL, root: URL) -> Int {
        let rootPath = root.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath) else { return Int.max }

        let relative = filePath.dropFirst(rootPath.count)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !relative.isEmpty else { return 0 }
        return relative.split(separator: "/").count
    }

    private nonisolated static func isModelWeightArtifact(_ fileURL: URL) -> Bool {
        let filename = fileURL.lastPathComponent
        let knownWeightFilenames = Set([
            "model.safetensors",
            "pytorch_model.bin",
            "model.bin",
            "diffusion_pytorch_model.safetensors",
            "diffusion_pytorch_model.bin"
        ])

        if knownWeightFilenames.contains(filename) {
            return true
        }
        if filename.hasSuffix(".safetensors") || filename.hasSuffix(".gguf") || filename.hasSuffix(".ckpt") {
            return true
        }
        if filename.hasSuffix(".bin") {
            return filename.contains("model") || filename.contains("weight") || filename.contains("diffusion")
        }
        return false
    }

    private nonisolated static func isWeightIndexArtifact(_ fileURL: URL) -> Bool {
        let filename = fileURL.lastPathComponent
        return filename.hasSuffix(".safetensors.index.json")
            || filename.hasSuffix(".bin.index.json")
    }

    func estimatedModelSize(modelId: String) -> Double {
        ModelCapabilityProfile.embeddedProfile(modelId: modelId)?.downloadSizeGB ?? 5.0
    }
}
