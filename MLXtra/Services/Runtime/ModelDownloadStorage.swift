import Foundation

enum ModelDownloadStorage {
    static func storageURLs(
        for model: DownloadableModel,
        checkpointsPath: URL,
        huggingFaceCacheRoot: URL = RuntimeManager.huggingFaceCacheRoot()
    ) -> [URL] {
        if model.source.usesComponentBundle {
            let storageRoot = model.source.componentStorageRoot(checkpointsPath: checkpointsPath)
            return model.source.components.map { storageRoot.appendingPathComponent($0) }
        }

        return model.snapshotRequirements.map {
            RuntimeManager.modelCachePath(
                modelId: $0.modelId,
                huggingFaceCacheRoot: huggingFaceCacheRoot
            )
        }
    }

    static func removeLocalFiles(
        for model: DownloadableModel,
        checkpointsPath: URL,
        huggingFaceCacheRoot: URL = RuntimeManager.huggingFaceCacheRoot(),
        fileManager: FileManager = .default
    ) throws {
        for url in storageURLs(
            for: model,
            checkpointsPath: checkpointsPath,
            huggingFaceCacheRoot: huggingFaceCacheRoot
        ) where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    static func status(
        for modelId: String,
        checkpointsPath: URL,
        huggingFaceCacheRoot: URL
    ) async -> RuntimeManager.ModelStorageStatus {
        if let model = DownloadableModel.embeddedModel(modelId: modelId) {
            return await status(
                for: model,
                checkpointsPath: checkpointsPath,
                huggingFaceCacheRoot: huggingFaceCacheRoot
            )
        }

        return await Task.detached(priority: .utility) {
            RuntimeManager.modelStorageStatus(
                modelId: modelId,
                checkpointsPath: checkpointsPath,
                huggingFaceCacheRoot: huggingFaceCacheRoot
            )
        }.value
    }

    static func status(
        for model: DownloadableModel,
        checkpointsPath: URL,
        huggingFaceCacheRoot: URL
    ) async -> RuntimeManager.ModelStorageStatus {
        await Task.detached(priority: .utility) {
            RuntimeManager.modelStorageStatus(
                model: model,
                checkpointsPath: checkpointsPath,
                huggingFaceCacheRoot: huggingFaceCacheRoot
            )
        }.value
    }

    static func cleanupPartialDownloads(
        for model: DownloadableModel,
        checkpointsPath: URL,
        huggingFaceCacheRoot: URL,
        nativeDownloader: any NativeModelDownloading
    ) async {
        let roots: [URL]
        if model.source.usesComponentBundle {
            roots = [model.source.componentStorageRoot(checkpointsPath: checkpointsPath)]
        } else {
            roots = model.snapshotRequirements.map {
                RuntimeManager.modelCachePath(
                    modelId: $0.modelId,
                    huggingFaceCacheRoot: huggingFaceCacheRoot
                )
            }
        }

        await Task.detached(priority: .utility) {
            for root in roots {
                try? nativeDownloader.removePartialDownloads(at: root)
            }
        }.value
    }
}
