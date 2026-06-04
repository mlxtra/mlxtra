import Foundation

extension RuntimeManager {
    nonisolated static func downloadedSnapshotPath(
        modelId: String,
        revision: String = "main",
        huggingFaceCacheRoot: URL = RuntimeManager.huggingFaceCacheRoot()
    ) -> URL? {
        let modelCachePath = modelCachePath(modelId: modelId, huggingFaceCacheRoot: huggingFaceCacheRoot)
        let snapshotsPath = modelCachePath.appendingPathComponent("snapshots")
        guard FileManager.default.fileExists(atPath: snapshotsPath.path) else {
            return nil
        }

        for snapshotPath in snapshotCandidates(
            modelCachePath: modelCachePath,
            snapshotsPath: snapshotsPath,
            revision: revision
        ) {
            if let nativeStatus = nativeSnapshotStorageStatus(snapshotPath),
               nativeStatus == .downloaded {
                return snapshotPath
            }
            if snapshotContainsModelFiles(snapshotPath) {
                return snapshotPath
            }
        }
        return nil
    }

    nonisolated static func nativeSnapshotStorageStatus(_ snapshotPath: URL) -> ModelStorageStatus? {
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

    nonisolated static func snapshotCandidates(
        modelCachePath: URL,
        snapshotsPath: URL,
        revision: String
    ) -> [URL] {
        let refsPath = modelCachePath
            .appendingPathComponent("refs")
            .appendingPathComponent(revision)
        if let revision = try? String(contentsOf: refsPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !revision.isEmpty {
            return [snapshotsPath.appendingPathComponent(revision)]
        }

        var candidates: [URL] = []
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
        if filename.hasSuffix(".safetensors")
            || filename.hasSuffix(".gguf")
            || filename.hasSuffix(".ckpt")
            || filename.hasSuffix(".mlxfn")
            || filename.hasSuffix(".tflite") {
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
}
