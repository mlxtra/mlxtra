import Foundation

protocol NativeModelDownloading: Sendable {
    func downloadHuggingFaceSnapshot(
        repoID: String,
        revision: String,
        cacheRoot: URL,
        progress: @escaping NativeModelDownloadService.ProgressHandler
    ) async throws

    func downloadAceStepMainSnapshot(
        plan: AceStepDownloadPlan,
        progress: @escaping NativeModelDownloadService.ProgressHandler
    ) async throws

    func markAceStepContractComplete(plan: AceStepDownloadPlan) throws

    func removePartialDownloads(at root: URL) throws
}

final class NativeModelDownloadService: @unchecked Sendable {
    typealias ProgressHandler = @Sendable (NativeModelDownloadProgress) async -> Void
    static let defaultMaximumConcurrentDownloads = 3
    static let defaultMaximumDownloadAttempts = 4
    static let defaultProgressEmissionInterval: TimeInterval = 0.5

    private let fileManager: FileManager
    private let downloadSessionConfiguration: URLSessionConfiguration
    private let requestBuilder: NativeModelDownloadRequestBuilder
    private let manifestClient: NativeModelManifestClient
    private let fileVerifier: NativeModelFileVerifier
    private let progressEmissionInterval: TimeInterval
    private let maximumDownloadAttempts: Int
    private let markerStore: NativeModelDownloadMarkerStore
    let maximumConcurrentDownloads: Int

    init(
        session: URLSession = .shared,
        fileManager: FileManager = .default,
        baseURL: URL = URL(string: "https://huggingface.co")!,
        downloadSessionConfiguration: URLSessionConfiguration = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        maximumConcurrentDownloads: Int = NativeModelDownloadService.defaultMaximumConcurrentDownloads,
        maximumDownloadAttempts: Int = NativeModelDownloadService.defaultMaximumDownloadAttempts,
        progressEmissionInterval: TimeInterval = NativeModelDownloadService.defaultProgressEmissionInterval
    ) {
        self.fileManager = fileManager
        self.downloadSessionConfiguration = downloadSessionConfiguration
        self.markerStore = NativeModelDownloadMarkerStore(fileManager: fileManager)
        let requestBuilder = NativeModelDownloadRequestBuilder(baseURL: baseURL, environment: environment)
        self.requestBuilder = requestBuilder
        self.manifestClient = NativeModelManifestClient(session: session, requestBuilder: requestBuilder)
        self.fileVerifier = NativeModelFileVerifier(
            fileManager: fileManager,
            skipLargeFileHashVerification: environment["MLXTRA_SKIP_LARGE_FILE_HASHES"] == "1",
            hashVerifyMaxBytes: Int64(environment["MLXTRA_HASH_VERIFY_MAX_BYTES"] ?? "")
                ?? 64 * 1024 * 1024
        )
        self.progressEmissionInterval = max(0, progressEmissionInterval)
        self.maximumDownloadAttempts = max(1, maximumDownloadAttempts)
        self.maximumConcurrentDownloads = max(1, maximumConcurrentDownloads)
    }

    func downloadHuggingFaceSnapshot(
        repoID: String,
        revision: String,
        cacheRoot: URL,
        progress: @escaping ProgressHandler
    ) async throws {
        let manifest = try await fetchManifest(repoID: repoID, revision: revision)
        let modelCacheRoot = RuntimeManager.modelCachePath(modelId: repoID, huggingFaceCacheRoot: cacheRoot)
        let snapshotRoot = modelCacheRoot
            .appendingPathComponent("snapshots")
            .appendingPathComponent(manifest.resolvedRevision)
        try markerStore.markSnapshotInProgress(at: snapshotRoot)
        try await downloadManifest(
            manifest,
            destinationRoot: snapshotRoot,
            progress: progress
        )
        try markerStore.writeCompletionManifest(manifest, destinationRoot: snapshotRoot)
        try markerStore.writeRevisionRef(
            revision: revision,
            resolvedRevision: manifest.resolvedRevision,
            modelCacheRoot: modelCacheRoot
        )
        try markerStore.clearSnapshotInProgress(at: snapshotRoot)
    }

    func downloadAceStepMainSnapshot(
        plan: AceStepDownloadPlan,
        progress: @escaping ProgressHandler
    ) async throws {
        let manifest = try await fetchManifest(repoID: plan.repoID, revision: plan.revision)
        try markerStore.markAceStepContractInProgress(plan: plan)
        try markerStore.markSnapshotInProgress(at: plan.checkpointsRoot)
        try await downloadManifest(
            manifest,
            destinationRoot: plan.checkpointsRoot,
            progress: progress
        )
        try markerStore.writeCompletionManifest(manifest, destinationRoot: plan.checkpointsRoot)
    }

    func markAceStepContractComplete(plan: AceStepDownloadPlan) throws {
        try markerStore.markAceStepContractComplete(plan: plan)
    }

    func removePartialDownloads(at root: URL) throws {
        guard fileManager.fileExists(atPath: root.path) else { return }
        if Self.isTransientDownloadArtifact(root.lastPathComponent) {
            try fileManager.removeItem(at: root)
            return
        }

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else {
            return
        }

        for case let url as URL in enumerator where Self.isTransientDownloadArtifact(url.lastPathComponent) {
            try fileManager.removeItem(at: url)
        }
    }

    private static func isTransientDownloadArtifact(_ filename: String) -> Bool {
        filename.hasSuffix(".download")
            || filename == NativeSnapshotCompletionManifest.inProgressFilename
            || filename == AceStepContractCompletionManifest.inProgressFilename
    }

    func fetchManifest(repoID: String, revision: String) async throws -> HuggingFaceManifest {
        try await manifestClient.fetchManifest(repoID: repoID, revision: revision)
    }

    private func downloadManifest(
        _ manifest: HuggingFaceManifest,
        destinationRoot: URL,
        progress: @escaping ProgressHandler
    ) async throws {
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

        let totalBytes = fileVerifier.aggregateSize(for: manifest.files)
        let completedBytes = fileVerifier.existingVerifiedBytes(for: manifest.files, destinationRoot: destinationRoot)
        let pendingFiles = manifest.files.filter { file in
            !fileVerifier.isFileComplete(destinationRoot.appendingPathComponent(file.path), manifestFile: file)
        }
        await progress(
            NativeModelDownloadProgress(
                status: "Preparing",
                description: manifest.repoID,
                downloadedBytes: completedBytes,
                totalBytes: totalBytes,
                percent: percent(downloaded: completedBytes, total: totalBytes)
            )
        )

        let progressAggregator = NativeDownloadProgressAggregator(
            completedBytes: completedBytes,
            totalBytes: totalBytes,
            progress: progress,
            minimumEmitInterval: progressEmissionInterval
        )
        try await downloadFilesConcurrently(
            pendingFiles,
            manifest: manifest,
            destinationRoot: destinationRoot,
            progressAggregator: progressAggregator
        )

        await progress(
            NativeModelDownloadProgress(
                status: "Verifying",
                description: "Local files verified",
                downloadedBytes: totalBytes,
                totalBytes: totalBytes,
                percent: percent(downloaded: totalBytes, total: totalBytes)
            )
        )
        try fileVerifier.verifyManifest(manifest.files, destinationRoot: destinationRoot)
        await progress(
            NativeModelDownloadProgress(
                status: "Finalizing",
                description: manifest.repoID,
                downloadedBytes: totalBytes,
                totalBytes: totalBytes,
                percent: percent(downloaded: totalBytes, total: totalBytes)
            )
        )
    }

    private func downloadFile(
        request: URLRequest,
        to destinationURL: URL,
        manifestFile: HuggingFaceManifestFile,
        progressAggregator: NativeDownloadProgressAggregator
    ) async throws {
        let downloader = StreamingFileDownloader(
            configuration: downloadSessionConfiguration,
            fileManager: fileManager,
            maxAttempts: maximumDownloadAttempts,
            shouldRetry: { StreamingFileDownloader.isTransientNetworkError($0) },
            shouldPreservePartial: { StreamingFileDownloader.shouldPreservePartialDownload(after: $0) }
        )
        let result = try await downloadWithStructuredProgress(
            downloader: downloader,
            request: request,
            destinationURL: destinationURL,
            manifestFile: manifestFile,
            progressAggregator: progressAggregator
        )

        await progressAggregator.updateActiveBytes(
            fileID: manifestFile.path,
            bytesWritten: result.bytesWritten,
            description: manifestFile.path
        )
    }

    private func downloadWithStructuredProgress(
        downloader: StreamingFileDownloader,
        request: URLRequest,
        destinationURL: URL,
        manifestFile: HuggingFaceManifestFile,
        progressAggregator: NativeDownloadProgressAggregator
    ) async throws -> StreamingFileDownloadResult {
        let (progressStream, progressContinuation) = AsyncStream.makeStream(
            of: Int64.self,
            bufferingPolicy: .unbounded
        )

        return try await withThrowingTaskGroup(
            of: StreamingFileDownloadResult?.self,
            returning: StreamingFileDownloadResult.self
        ) { group in
            group.addTask {
                defer { progressContinuation.finish() }
                return try await downloader.download(
                    request: request,
                    destinationURL: destinationURL,
                    expectedBytes: manifestFile.size,
                    validateResponse: { response in
                        try NativeModelManifestClient.validateHTTPResponse(
                            response,
                            context: manifestFile.path
                        )
                    },
                    onProgress: { bytesWritten in
                        progressContinuation.yield(bytesWritten)
                    }
                )
            }

            group.addTask {
                for await bytesWritten in progressStream {
                    await progressAggregator.updateActiveBytes(
                        fileID: manifestFile.path,
                        bytesWritten: bytesWritten,
                        description: manifestFile.path
                    )
                }
                return nil
            }

            var result: StreamingFileDownloadResult?
            while let nextResult = try await group.next() {
                if let nextResult {
                    result = nextResult
                }
            }

            guard let result else {
                throw URLError(.unknown)
            }
            return result
        }
    }

    private func downloadFilesConcurrently(
        _ files: [HuggingFaceManifestFile],
        manifest: HuggingFaceManifest,
        destinationRoot: URL,
        progressAggregator: NativeDownloadProgressAggregator
    ) async throws {
        guard !files.isEmpty else { return }

        var nextIndex = 0
        let initialTaskCount = min(maximumConcurrentDownloads, files.count)
        try await withThrowingTaskGroup(of: Void.self) { group in
            func enqueue(_ file: HuggingFaceManifestFile) throws {
                let request = try requestBuilder.downloadRequest(
                    repoID: manifest.repoID,
                    revision: manifest.resolvedRevision,
                    path: file.path
                )
                let destinationURL = destinationRoot.appendingPathComponent(file.path)
                group.addTask {
                    try Task.checkCancellation()
                    try await self.downloadFile(
                        request: request,
                        to: destinationURL,
                        manifestFile: file,
                        progressAggregator: progressAggregator
                    )
                    try self.fileVerifier.verifyFile(destinationURL, manifestFile: file)
                    let completedSize = file.size ?? self.fileVerifier.fileSize(destinationURL) ?? 0
                    await progressAggregator.completeFile(
                        fileID: file.path,
                        completedBytes: completedSize,
                        description: file.path
                    )
                }
            }

            while nextIndex < initialTaskCount {
                try enqueue(files[nextIndex])
                nextIndex += 1
            }

            while try await group.next() != nil {
                if nextIndex < files.count {
                    try enqueue(files[nextIndex])
                    nextIndex += 1
                }
            }
        }
    }

    nonisolated static func percent(downloaded: Int64?, total: Int64?) -> Double? {
        guard let downloaded, let total, total > 0 else { return nil }
        return max(0, min(Double(downloaded) / Double(total) * 100, 100))
    }

    private func percent(downloaded: Int64?, total: Int64?) -> Double? {
        Self.percent(downloaded: downloaded, total: total)
    }

}

extension NativeModelDownloadService: NativeModelDownloading {}
