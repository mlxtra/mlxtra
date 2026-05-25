import Foundation

struct NativeModelDownloadProgress: Equatable {
    let status: String
    let description: String?
    let downloadedBytes: Int64?
    let totalBytes: Int64?
    let percent: Double?
}

struct HuggingFaceManifestFile: Equatable {
    let path: String
    let size: Int64?
    let sha256: String?
}

struct HuggingFaceManifest: Equatable {
    let repoID: String
    let revision: String
    let resolvedRevision: String
    let files: [HuggingFaceManifestFile]

    static func parse(data: Data, repoID: String, revision: String) throws -> HuggingFaceManifest {
        let response = try JSONDecoder().decode(HuggingFaceModelAPIResponse.self, from: data)
        let files = response.siblings
            .compactMap { sibling -> HuggingFaceManifestFile? in
                guard let path = sibling.downloadPath?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !path.isEmpty,
                      !path.hasSuffix("/") else {
                    return nil
                }
                return HuggingFaceManifestFile(
                    path: path,
                    size: sibling.lfs?.size ?? sibling.size,
                    sha256: sibling.lfs?.sha256
                )
            }
            .sorted { $0.path < $1.path }

        guard !files.isEmpty else {
            throw NativeModelDownloadError.emptyManifest(repoID)
        }

        return HuggingFaceManifest(
            repoID: repoID,
            revision: revision,
            resolvedRevision: response.sha ?? revision,
            files: files
        )
    }
}

struct NativeSnapshotCompletionManifest: Codable, Equatable {
    struct FileEntry: Codable, Equatable {
        let path: String
        let size: Int64?
        let sha256: String?
    }

    static let filename = ".mlxtra_snapshot_complete.json"
    static let inProgressFilename = ".mlxtra_snapshot_in_progress"
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let repoID: String
    let revision: String
    let resolvedRevision: String
    let files: [FileEntry]

    init(manifest: HuggingFaceManifest) {
        self.schemaVersion = Self.currentSchemaVersion
        self.repoID = manifest.repoID
        self.revision = manifest.revision
        self.resolvedRevision = manifest.resolvedRevision
        self.files = manifest.files.map {
            FileEntry(path: $0.path, size: $0.size, sha256: $0.sha256)
        }
    }

    var manifestFiles: [HuggingFaceManifestFile] {
        files.map { HuggingFaceManifestFile(path: $0.path, size: $0.size, sha256: $0.sha256) }
    }
}

struct AceStepContractCompletionManifest: Codable, Equatable {
    static let filename = ".mlxtra_acestep_contract_complete.json"
    static let inProgressFilename = ".mlxtra_acestep_contract_in_progress"
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let repoID: String
    let revision: String
    let requiredComponents: [String]

    init(plan: AceStepDownloadPlan) {
        self.schemaVersion = Self.currentSchemaVersion
        self.repoID = plan.repoID
        self.revision = plan.revision
        self.requiredComponents = plan.requiredComponents
    }
}

struct AceStepDownloadPlan: Equatable {
    let repoID: String
    let revision: String
    let requiredComponents: [String]
    let checkpointsRoot: URL

    init(
        repoID: String,
        revision: String = "main",
        requiredComponents: [String],
        checkpointsRoot: URL
    ) {
        self.repoID = repoID
        self.revision = revision
        self.requiredComponents = requiredComponents
        self.checkpointsRoot = checkpointsRoot
    }

    func componentURL(component: String) -> URL {
        checkpointsRoot.appendingPathComponent(component)
    }
}

enum NativeModelDownloadError: LocalizedError, Equatable {
    case emptyManifest(String)
    case invalidManifestURL(String)
    case invalidDownloadURL(String)
    case httpStatus(Int, String)
    case sizeMismatch(String, expected: Int64, actual: Int64)
    case checksumMismatch(String)
    case missingDownloadedFile(String)
    case unsupportedComponentBundle(String)

    var errorDescription: String? {
        switch self {
        case .emptyManifest(let repoID):
            return "Hugging Face did not return downloadable files for \(repoID)."
        case .invalidManifestURL(let repoID):
            return "Could not build Hugging Face manifest URL for \(repoID)."
        case .invalidDownloadURL(let path):
            return "Could not build Hugging Face download URL for \(path)."
        case .httpStatus(let statusCode, let context):
            return Self.message(forHTTPStatus: statusCode, context: context)
        case .sizeMismatch(let path, let expected, let actual):
            return "Downloaded file size mismatch for \(path): expected \(expected) bytes, got \(actual) bytes."
        case .checksumMismatch(let path):
            return "Downloaded file checksum did not match for \(path)."
        case .missingDownloadedFile(let path):
            return "Downloaded file is missing after transfer: \(path)."
        case .unsupportedComponentBundle(let modelName):
            return "\(modelName) uses an unsupported component bundle download helper."
        }
    }

    private static func message(forHTTPStatus statusCode: Int, context: String) -> String {
        switch statusCode {
        case 401:
            return "Hugging Face authentication is required for \(context)."
        case 403:
            return "Hugging Face denied access to \(context). Accept the model license or check your account access."
        case 404:
            return "Hugging Face model or file was not found: \(context)."
        case 429:
            return "Hugging Face rate limit reached while downloading \(context). Try again later."
        default:
            return "Hugging Face returned HTTP \(statusCode) for \(context)."
        }
    }
}

final class NativeModelDownloadService: @unchecked Sendable {
    typealias ProgressHandler = @Sendable (NativeModelDownloadProgress) async -> Void
    static let defaultMaximumConcurrentDownloads = 3
    static let defaultProgressEmissionInterval: TimeInterval = 0.5

    private let session: URLSession
    private let fileManager: FileManager
    private let baseURL: URL
    private let downloadSessionConfiguration: URLSessionConfiguration
    private let verifyLargeFileHashes: Bool
    private let hashVerifyMaxBytes: Int64
    private let progressEmissionInterval: TimeInterval
    let maximumConcurrentDownloads: Int

    init(
        session: URLSession = .shared,
        fileManager: FileManager = .default,
        baseURL: URL = URL(string: "https://huggingface.co")!,
        downloadSessionConfiguration: URLSessionConfiguration = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        maximumConcurrentDownloads: Int = NativeModelDownloadService.defaultMaximumConcurrentDownloads,
        progressEmissionInterval: TimeInterval = NativeModelDownloadService.defaultProgressEmissionInterval
    ) {
        self.session = session
        self.fileManager = fileManager
        self.baseURL = baseURL
        self.downloadSessionConfiguration = downloadSessionConfiguration
        self.verifyLargeFileHashes = environment["MLXTRA_VERIFY_LARGE_FILE_HASHES"] == "1"
        self.hashVerifyMaxBytes = Int64(environment["MLXTRA_HASH_VERIFY_MAX_BYTES"] ?? "")
            ?? 64 * 1024 * 1024
        self.progressEmissionInterval = max(0, progressEmissionInterval)
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
        try markSnapshotInProgress(at: snapshotRoot)
        try await downloadManifest(
            manifest,
            destinationRoot: snapshotRoot,
            progress: progress
        )
        try writeCompletionManifest(manifest, destinationRoot: snapshotRoot)
        try clearSnapshotInProgress(at: snapshotRoot)
        try writeRevisionRef(revision: revision, resolvedRevision: manifest.resolvedRevision, modelCacheRoot: modelCacheRoot)
    }

    func downloadAceStepMainSnapshot(
        plan: AceStepDownloadPlan,
        progress: @escaping ProgressHandler
    ) async throws {
        let manifest = try await fetchManifest(repoID: plan.repoID, revision: plan.revision)
        try markAceStepContractInProgress(plan: plan)
        try markSnapshotInProgress(at: plan.checkpointsRoot)
        try await downloadManifest(
            manifest,
            destinationRoot: plan.checkpointsRoot,
            progress: progress
        )
        try writeCompletionManifest(manifest, destinationRoot: plan.checkpointsRoot)
    }

    func markAceStepContractComplete(plan: AceStepDownloadPlan) throws {
        try clearSnapshotInProgress(at: plan.checkpointsRoot)
        try clearCompletionManifest(at: plan.checkpointsRoot)
        try clearAceStepContractInProgress(plan: plan)
        try writeAceStepContractCompletionManifest(plan: plan)
    }

    func removePartialDownloads(at root: URL) throws {
        guard fileManager.fileExists(atPath: root.path) else { return }
        if root.lastPathComponent.hasSuffix(".download") {
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

        for case let url as URL in enumerator where url.lastPathComponent.hasSuffix(".download") {
            try fileManager.removeItem(at: url)
        }
    }

    func fetchManifest(repoID: String, revision: String) async throws -> HuggingFaceManifest {
        guard let url = manifestURL(repoID: repoID, revision: revision) else {
            throw NativeModelDownloadError.invalidManifestURL(repoID)
        }

        var request = URLRequest(url: url)
        applyAuthorizationHeader(to: &request)

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response, context: repoID)
        return try HuggingFaceManifest.parse(data: data, repoID: repoID, revision: revision)
    }

    private func downloadManifest(
        _ manifest: HuggingFaceManifest,
        destinationRoot: URL,
        progress: @escaping ProgressHandler
    ) async throws {
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

        let totalBytes = aggregateSize(for: manifest.files)
        let completedBytes = existingVerifiedBytes(for: manifest.files, destinationRoot: destinationRoot)
        let pendingFiles = manifest.files.filter { file in
            !isFileComplete(destinationRoot.appendingPathComponent(file.path), manifestFile: file)
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
        try verifyManifest(manifest.files, destinationRoot: destinationRoot)
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
        from sourceURL: URL,
        to destinationURL: URL,
        manifestFile: HuggingFaceManifestFile,
        progressAggregator: NativeDownloadProgressAggregator
    ) async throws {
        var request = URLRequest(url: sourceURL)
        applyAuthorizationHeader(to: &request)

        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let temporaryURL = partialDownloadURL(for: destinationURL)
        let resumeOffset = resumablePartialSize(at: temporaryURL, manifestFile: manifestFile)
        var didMoveTemporaryFile = false
        var shouldRemoveTemporaryFile = true
        defer {
            if !didMoveTemporaryFile,
               shouldRemoveTemporaryFile,
               fileManager.fileExists(atPath: temporaryURL.path) {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }

        if resumeOffset > 0 {
            request.setValue("bytes=\(resumeOffset)-", forHTTPHeaderField: "Range")
        }

        let streamingDownload = StreamingFileDownload(
            request: request,
            temporaryURL: temporaryURL,
            resumeOffset: resumeOffset,
            configuration: downloadSessionConfiguration
        ) { bytesWritten in
            Task {
                await progressAggregator.updateActiveBytes(
                    fileID: manifestFile.path,
                    bytesWritten: bytesWritten,
                    description: manifestFile.path
                )
            }
        }
        let result: StreamingFileDownloadResult
        do {
            result = try await streamingDownload.start()
            try validateHTTPResponse(result.response, context: manifestFile.path)
        } catch {
            if shouldPreservePartialDownload(after: error) {
                shouldRemoveTemporaryFile = false
            }
            throw error
        }

        await progressAggregator.updateActiveBytes(
            fileID: manifestFile.path,
            bytesWritten: result.bytesWritten,
            description: manifestFile.path
        )

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        didMoveTemporaryFile = true
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
                let sourceURL = try downloadURL(
                    repoID: manifest.repoID,
                    revision: manifest.resolvedRevision,
                    path: file.path
                )
                let destinationURL = destinationRoot.appendingPathComponent(file.path)
                group.addTask {
                    try Task.checkCancellation()
                    try await self.downloadFile(
                        from: sourceURL,
                        to: destinationURL,
                        manifestFile: file,
                        progressAggregator: progressAggregator
                    )
                    try self.verifyFile(destinationURL, manifestFile: file)
                    let completedSize = file.size ?? self.fileSize(destinationURL) ?? 0
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

    private func verifyManifest(_ files: [HuggingFaceManifestFile], destinationRoot: URL) throws {
        for file in files {
            try verifyFile(destinationRoot.appendingPathComponent(file.path), manifestFile: file)
        }
    }

    private func verifyFile(_ fileURL: URL, manifestFile: HuggingFaceManifestFile) throws {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw NativeModelDownloadError.missingDownloadedFile(manifestFile.path)
        }

        if let expectedSize = manifestFile.size {
            let actualSize = fileSize(fileURL) ?? -1
            guard actualSize == expectedSize else {
                throw NativeModelDownloadError.sizeMismatch(
                    manifestFile.path,
                    expected: expectedSize,
                    actual: actualSize
                )
            }
        }

        guard let expectedSHA256 = manifestFile.sha256,
              shouldVerifyHash(size: manifestFile.size) else {
            return
        }

        let actualSHA256 = try SHA256Checksum.hexDigest(for: fileURL)
        guard actualSHA256.caseInsensitiveCompare(expectedSHA256) == .orderedSame else {
            throw NativeModelDownloadError.checksumMismatch(manifestFile.path)
        }
    }

    private func isFileComplete(_ fileURL: URL, manifestFile: HuggingFaceManifestFile) -> Bool {
        do {
            try verifyFile(fileURL, manifestFile: manifestFile)
            return true
        } catch {
            return false
        }
    }

    private func existingVerifiedBytes(for files: [HuggingFaceManifestFile], destinationRoot: URL) -> Int64 {
        files.reduce(Int64(0)) { total, file in
            let destinationURL = destinationRoot.appendingPathComponent(file.path)
            guard isFileComplete(destinationURL, manifestFile: file) else {
                return total
            }
            return total + (file.size ?? fileSize(destinationURL) ?? 0)
        }
    }

    private func writeRevisionRef(
        revision: String,
        resolvedRevision: String,
        modelCacheRoot: URL
    ) throws {
        let refsRoot = modelCacheRoot.appendingPathComponent("refs")
        let refURL = refsRoot.appendingPathComponent(revision)
        try fileManager.createDirectory(at: refURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(resolvedRevision.utf8).write(to: refURL, options: [.atomic])
    }

    private func markSnapshotInProgress(at destinationRoot: URL) throws {
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        let completionURL = destinationRoot.appendingPathComponent(NativeSnapshotCompletionManifest.filename)
        if fileManager.fileExists(atPath: completionURL.path) {
            try fileManager.removeItem(at: completionURL)
        }
        let markerURL = destinationRoot.appendingPathComponent(NativeSnapshotCompletionManifest.inProgressFilename)
        try Data("in-progress".utf8).write(to: markerURL, options: [.atomic])
    }

    private func clearSnapshotInProgress(at destinationRoot: URL) throws {
        let markerURL = destinationRoot.appendingPathComponent(NativeSnapshotCompletionManifest.inProgressFilename)
        if fileManager.fileExists(atPath: markerURL.path) {
            try fileManager.removeItem(at: markerURL)
        }
    }

    private func clearCompletionManifest(at destinationRoot: URL) throws {
        let manifestURL = destinationRoot.appendingPathComponent(NativeSnapshotCompletionManifest.filename)
        if fileManager.fileExists(atPath: manifestURL.path) {
            try fileManager.removeItem(at: manifestURL)
        }
    }

    private func writeCompletionManifest(
        _ manifest: HuggingFaceManifest,
        destinationRoot: URL
    ) throws {
        let manifestURL = destinationRoot.appendingPathComponent(NativeSnapshotCompletionManifest.filename)
        let data = try JSONEncoder().encode(NativeSnapshotCompletionManifest(manifest: manifest))
        try data.write(to: manifestURL, options: [.atomic])
    }

    private func markAceStepContractInProgress(plan: AceStepDownloadPlan) throws {
        try fileManager.createDirectory(at: plan.checkpointsRoot, withIntermediateDirectories: true)
        let completionURL = plan.checkpointsRoot.appendingPathComponent(AceStepContractCompletionManifest.filename)
        if fileManager.fileExists(atPath: completionURL.path) {
            try fileManager.removeItem(at: completionURL)
        }
        let markerURL = plan.checkpointsRoot.appendingPathComponent(AceStepContractCompletionManifest.inProgressFilename)
        try Data("in-progress".utf8).write(to: markerURL, options: [.atomic])
    }

    private func clearAceStepContractInProgress(plan: AceStepDownloadPlan) throws {
        let markerURL = plan.checkpointsRoot.appendingPathComponent(AceStepContractCompletionManifest.inProgressFilename)
        if fileManager.fileExists(atPath: markerURL.path) {
            try fileManager.removeItem(at: markerURL)
        }
    }

    private func writeAceStepContractCompletionManifest(plan: AceStepDownloadPlan) throws {
        let manifestURL = plan.checkpointsRoot.appendingPathComponent(AceStepContractCompletionManifest.filename)
        let data = try JSONEncoder().encode(AceStepContractCompletionManifest(plan: plan))
        try data.write(to: manifestURL, options: [.atomic])
    }

    private func aggregateSize(for files: [HuggingFaceManifestFile]) -> Int64? {
        var total: Int64 = 0
        for file in files {
            guard let size = file.size else { return nil }
            total += size
        }
        return total
    }

    nonisolated static func percent(downloaded: Int64?, total: Int64?) -> Double? {
        guard let downloaded, let total, total > 0 else { return nil }
        return max(0, min(Double(downloaded) / Double(total) * 100, 100))
    }

    private func percent(downloaded: Int64?, total: Int64?) -> Double? {
        Self.percent(downloaded: downloaded, total: total)
    }

    private func shouldVerifyHash(size: Int64?) -> Bool {
        verifyLargeFileHashes || (size ?? 0) <= hashVerifyMaxBytes
    }

    private func fileSize(_ url: URL) -> Int64? {
        guard let size = try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber else {
            return nil
        }
        return size.int64Value
    }

    private func partialDownloadURL(for destinationURL: URL) -> URL {
        destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(destinationURL.lastPathComponent).download")
    }

    private func resumablePartialSize(at partialURL: URL, manifestFile: HuggingFaceManifestFile) -> Int64 {
        guard let partialSize = fileSize(partialURL), partialSize > 0 else {
            return 0
        }

        if let expectedSize = manifestFile.size, partialSize >= expectedSize {
            try? fileManager.removeItem(at: partialURL)
            return 0
        }

        return partialSize
    }

    private func shouldPreservePartialDownload(after error: Error) -> Bool {
        guard let urlError = error as? URLError else {
            return false
        }
        return [
            .cancelled,
            .networkConnectionLost,
            .timedOut,
            .notConnectedToInternet,
            .cannotConnectToHost,
            .cannotFindHost,
            .dnsLookupFailed
        ].contains(urlError.code)
    }

    private func validateHTTPResponse(_ response: URLResponse, context: String) throws {
        guard let httpResponse = response as? HTTPURLResponse else { return }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw NativeModelDownloadError.httpStatus(httpResponse.statusCode, context)
        }
    }

    private func applyAuthorizationHeader(to request: inout URLRequest) {
        let environment = ProcessInfo.processInfo.environment
        let token = environment["HF_TOKEN"] ?? environment["HUGGING_FACE_HUB_TOKEN"]
        guard let token, !token.isEmpty else { return }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    private func manifestURL(repoID: String, revision: String) -> URL? {
        let base = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(
            string: "\(base)/api/models/\(Self.encodedPath(repoID))/revision/\(Self.encodedPath(revision))?blobs=true&files_metadata=true"
        )
    }

    private func downloadURL(repoID: String, revision: String, path: String) throws -> URL {
        let base = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(
            string: "\(base)/\(Self.encodedPath(repoID))/resolve/\(Self.encodedPath(revision))/\(Self.encodedPath(path))"
        ) else {
            throw NativeModelDownloadError.invalidDownloadURL(path)
        }
        return url
    }

    private static func encodedPath(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false)
            .map { encodedPathSegment(String($0)) }
            .joined(separator: "/")
    }

    private static func encodedPathSegment(_ segment: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#[]@!$&'()*+,;=")
        return segment.addingPercentEncoding(withAllowedCharacters: allowed) ?? segment
    }
}

actor NativeDownloadProgressAggregator {
    private var completedBytes: Int64
    private var activeFileBytes: [String: Int64] = [:]
    private var completedFileIDs: Set<String> = []
    private var lastEmittedBytes: Int64
    private var lastEmissionDate: Date?
    private let totalBytes: Int64?
    private let progress: NativeModelDownloadService.ProgressHandler
    private let minimumEmitInterval: TimeInterval

    init(
        completedBytes: Int64,
        totalBytes: Int64?,
        progress: @escaping NativeModelDownloadService.ProgressHandler,
        minimumEmitInterval: TimeInterval = 0
    ) {
        self.completedBytes = completedBytes
        self.lastEmittedBytes = completedBytes
        self.totalBytes = totalBytes
        self.progress = progress
        self.minimumEmitInterval = max(0, minimumEmitInterval)
    }

    func updateActiveBytes(fileID: String, bytesWritten: Int64, description: String?) async {
        guard !completedFileIDs.contains(fileID) else { return }
        activeFileBytes[fileID] = max(0, bytesWritten)
        await emit(status: "Downloading", description: description)
    }

    func completeFile(fileID: String, completedBytes fileBytes: Int64, description: String?) async {
        activeFileBytes[fileID] = nil
        completedFileIDs.insert(fileID)
        completedBytes += max(0, fileBytes)
        await emit(status: "Downloading", description: description, force: true)
    }

    private func emit(status: String, description: String?, force: Bool = false) async {
        let now = Date()
        if !force,
           minimumEmitInterval > 0,
           let lastEmissionDate,
           now.timeIntervalSince(lastEmissionDate) < minimumEmitInterval {
            return
        }

        let activeBytes = activeFileBytes.values.reduce(Int64(0), +)
        let rawDownloadedBytes = completedBytes + activeBytes
        let downloadedBytes = max(rawDownloadedBytes, lastEmittedBytes)
        lastEmittedBytes = downloadedBytes
        lastEmissionDate = now
        await progress(
            NativeModelDownloadProgress(
                status: status,
                description: description,
                downloadedBytes: downloadedBytes,
                totalBytes: totalBytes,
                percent: NativeModelDownloadService.percent(downloaded: downloadedBytes, total: totalBytes)
            )
        )
    }
}

private struct StreamingFileDownloadResult {
    let response: URLResponse
    let bytesWritten: Int64
}

private final class StreamingFileDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let request: URLRequest
    private let temporaryURL: URL
    private let resumeOffset: Int64
    private let configuration: URLSessionConfiguration
    private let onProgress: @Sendable (Int64) -> Void
    private var continuation: CheckedContinuation<StreamingFileDownloadResult, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var fileHandle: FileHandle?
    private var response: URLResponse?
    private var bytesWritten: Int64 = 0
    private var isCompleted = false

    init(
        request: URLRequest,
        temporaryURL: URL,
        resumeOffset: Int64,
        configuration: URLSessionConfiguration,
        onProgress: @escaping @Sendable (Int64) -> Void
    ) {
        self.request = request
        self.temporaryURL = temporaryURL
        self.resumeOffset = max(0, resumeOffset)
        self.configuration = configuration
        self.onProgress = onProgress
    }

    func start() async throws -> StreamingFileDownloadResult {
        if resumeOffset == 0 {
            try Data().write(to: temporaryURL, options: [.atomic])
        } else if !FileManager.default.fileExists(atPath: temporaryURL.path) {
            try Data().write(to: temporaryURL, options: [.atomic])
        }
        fileHandle = try FileHandle(forWritingTo: temporaryURL)
        try fileHandle?.seekToEnd()
        bytesWritten = resumeOffset

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                let task = session.dataTask(with: request)
                self.session = session
                self.task = task
                lock.unlock()

                task.resume()
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        lock.lock()
        let task = task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        self.response = response
        let shouldRestartFromZero = resumeOffset > 0
            && (response as? HTTPURLResponse)?.statusCode == 200
        let fileHandle = self.fileHandle
        if shouldRestartFromZero {
            bytesWritten = 0
        }
        lock.unlock()

        if shouldRestartFromZero {
            try? fileHandle?.truncate(atOffset: 0)
            try? fileHandle?.seek(toOffset: 0)
            onProgress(0)
        }

        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        do {
            try fileHandle?.write(contentsOf: data)
            lock.lock()
            bytesWritten += Int64(data.count)
            let emittedBytes = bytesWritten
            lock.unlock()
            onProgress(emittedBytes)
        } catch {
            complete(.failure(error))
            dataTask.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            complete(.failure(error))
            return
        }

        lock.lock()
        let response = self.response
        let bytesWritten = self.bytesWritten
        lock.unlock()

        guard let response else {
            complete(.failure(URLError(.badServerResponse)))
            return
        }

        complete(.success(StreamingFileDownloadResult(response: response, bytesWritten: bytesWritten)))
    }

    private func complete(_ result: Result<StreamingFileDownloadResult, Error>) {
        lock.lock()
        guard !isCompleted else {
            lock.unlock()
            return
        }
        isCompleted = true
        let continuation = self.continuation
        self.continuation = nil
        let fileHandle = self.fileHandle
        self.fileHandle = nil
        let session = self.session
        self.session = nil
        self.task = nil
        lock.unlock()

        try? fileHandle?.close()
        session?.finishTasksAndInvalidate()

        switch result {
        case .success(let downloadResult):
            continuation?.resume(returning: downloadResult)
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
    }
}

private struct HuggingFaceModelAPIResponse: Decodable {
    let sha: String?
    let siblings: [Sibling]

    struct Sibling: Decodable {
        let rfilename: String?
        let pathField: String?
        let size: Int64?
        let lfs: LFS?

        var downloadPath: String? { rfilename ?? pathField }

        private enum CodingKeys: String, CodingKey {
            case rfilename
            case path
            case size
            case lfs
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            rfilename = try container.decodeIfPresent(String.self, forKey: .rfilename)
            pathField = try container.decodeIfPresent(String.self, forKey: .path)
            size = try container.decodeFlexibleInt64IfPresent(forKey: .size)
            lfs = try container.decodeIfPresent(LFS.self, forKey: .lfs)
        }
    }

    struct LFS: Decodable {
        let size: Int64?
        let sha256: String?

        private enum CodingKeys: String, CodingKey {
            case size
            case sha256
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            size = try container.decodeFlexibleInt64IfPresent(forKey: .size)
            sha256 = try container.decodeIfPresent(String.self, forKey: .sha256)
        }
    }
}

private extension KeyedDecodingContainer {
    func decodeFlexibleInt64IfPresent(forKey key: Key) throws -> Int64? {
        if let value = try decodeIfPresent(Int64.self, forKey: key) {
            return value
        }
        if let value = try decodeIfPresent(Int.self, forKey: key) {
            return Int64(value)
        }
        if let value = try decodeIfPresent(Double.self, forKey: key) {
            return Int64(value)
        }
        if let value = try decodeIfPresent(String.self, forKey: key) {
            return Int64(value)
        }
        return nil
    }
}
