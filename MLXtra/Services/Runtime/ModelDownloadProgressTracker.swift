import Foundation

@MainActor
final class ModelDownloadProgressTracker {
    private var lastProgress: [String: ModelDownloadManager.DownloadProgress] = [:]

    func initialProgress(
        for modelId: String,
        currentState: ModelDownloadManager.DownloadState?
    ) -> ModelDownloadManager.DownloadProgress? {
        if currentState?.isPaused == true {
            return currentState?.progress ?? lastProgress[modelId]
        }

        lastProgress[modelId] = nil
        return nil
    }

    func pauseProgress(
        for modelId: String,
        currentState: ModelDownloadManager.DownloadState?
    ) -> ModelDownloadManager.DownloadProgress? {
        currentState?.progress ?? lastProgress[modelId]
    }

    func clear(for modelId: String) {
        lastProgress[modelId] = nil
    }

    func recordNativeProgress(
        _ nativeProgress: NativeModelDownloadProgress,
        modelId: String
    ) -> ModelDownloadManager.DownloadProgress {
        let progress = ModelDownloadManager.DownloadProgress(
            status: nativeProgress.status,
            description: nativeProgress.description,
            unit: nativeProgress.downloadedBytes == nil ? nil : "B",
            progressKind: nativeProgress.downloadedBytes == nil ? nil : "bytes",
            downloadedBytes: nativeProgress.downloadedBytes,
            totalBytes: nativeProgress.totalBytes,
            percent: ModelDownloadEventParser.monotonicPercent(
                nativeProgress.percent,
                previous: lastProgress[modelId]?.percent
            )
        )
        lastProgress[modelId] = progress
        return progress
    }

    func recordEventProgress(
        _ event: ModelDownloadEvent,
        modelId: String
    ) -> ModelDownloadManager.DownloadProgress? {
        guard let progress = ModelDownloadEventParser.downloadProgress(
            for: event,
            previousPercent: lastProgress[modelId]?.percent
        ) else {
            return nil
        }
        lastProgress[modelId] = progress
        return progress
    }
}
