import XCTest
@testable import MLXtra

final class NativeModelDownloadServiceTests: XCTestCase {
    func testNativeDownloaderUsesBoundedParallelismByDefault() {
        XCTAssertEqual(
            NativeModelDownloadService().maximumConcurrentDownloads,
            NativeModelDownloadService.defaultMaximumConcurrentDownloads
        )
        XCTAssertEqual(
            NativeModelDownloadService.defaultProgressEmissionInterval,
            0.5
        )
        XCTAssertEqual(
            NativeModelDownloadService.defaultMaximumDownloadAttempts,
            4
        )
        XCTAssertEqual(
            NativeModelDownloadService(maximumConcurrentDownloads: 0).maximumConcurrentDownloads,
            1
        )
    }

    func testProgressAggregatorCombinesParallelFileProgress() async {
        let recorder = ProgressRecorder()
        let aggregator = NativeDownloadProgressAggregator(
            completedBytes: 10,
            totalBytes: 100,
            progress: { progress in
                recorder.append(progress)
            }
        )

        await aggregator.updateActiveBytes(fileID: "a.safetensors", bytesWritten: 20, description: "a.safetensors")
        await aggregator.updateActiveBytes(fileID: "b.safetensors", bytesWritten: 5, description: "b.safetensors")
        await aggregator.completeFile(fileID: "a.safetensors", completedBytes: 30, description: "a.safetensors")
        await aggregator.updateActiveBytes(fileID: "b.safetensors", bytesWritten: 40, description: "b.safetensors")
        await aggregator.updateActiveBytes(fileID: "a.safetensors", bytesWritten: 100, description: "a.safetensors")

        let events = recorder.events()
        XCTAssertEqual(events.map(\.downloadedBytes), [30, 35, 45, 80])
        XCTAssertEqual(events.last?.percent, 80)
    }

    func testProgressAggregatorThrottlesIntermediateProgress() async {
        let recorder = ProgressRecorder()
        let aggregator = NativeDownloadProgressAggregator(
            completedBytes: 0,
            totalBytes: 100,
            progress: { progress in
                recorder.append(progress)
            },
            minimumEmitInterval: 0.5
        )

        await aggregator.updateActiveBytes(fileID: "a.safetensors", bytesWritten: 10, description: "a.safetensors")
        await aggregator.updateActiveBytes(fileID: "a.safetensors", bytesWritten: 20, description: "a.safetensors")
        await aggregator.completeFile(fileID: "a.safetensors", completedBytes: 30, description: "a.safetensors")

        let events = recorder.events()
        XCTAssertEqual(events.map(\.downloadedBytes), [10, 30])
        XCTAssertEqual(events.last?.percent, 30)
    }

    func testNativeSnapshotDownloadStreamsProgressFromResponseChunks() async throws {
        let cacheRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: cacheRoot) }

        ChunkedHuggingFaceURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChunkedHuggingFaceURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let service = NativeModelDownloadService(
            session: session,
            baseURL: URL(string: "https://hf.test")!,
            downloadSessionConfiguration: configuration,
            maximumConcurrentDownloads: 1,
            progressEmissionInterval: 0
        )
        let recorder = ProgressRecorder()

        try await service.downloadHuggingFaceSnapshot(
            repoID: "org/model",
            revision: "main",
            cacheRoot: cacheRoot
        ) { progress in
            recorder.append(progress)
        }

        let modelFile = RuntimeManager.modelCachePath(modelId: "org/model", huggingFaceCacheRoot: cacheRoot)
            .appendingPathComponent("snapshots")
            .appendingPathComponent("revision")
            .appendingPathComponent("model.safetensors")
        let completionMarker = modelFile
            .deletingLastPathComponent()
            .appendingPathComponent(NativeSnapshotCompletionManifest.filename)

        XCTAssertEqual(try Data(contentsOf: modelFile), Data([1, 2, 3, 4]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: completionMarker.path))

        let downloadedByteCounts = recorder.events().compactMap(\.downloadedBytes)
        XCTAssertTrue(downloadedByteCounts.contains(4))
    }

    func testNativeSnapshotDownloadUsesInjectedHuggingFaceTokenForManifestAndFiles() async throws {
        let cacheRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: cacheRoot) }

        ChunkedHuggingFaceURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChunkedHuggingFaceURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let service = NativeModelDownloadService(
            session: session,
            baseURL: URL(string: "https://hf.test")!,
            downloadSessionConfiguration: configuration,
            environment: ["HF_TOKEN": "test-token"],
            maximumConcurrentDownloads: 1,
            progressEmissionInterval: 0
        )

        try await service.downloadHuggingFaceSnapshot(
            repoID: "org/model",
            revision: "main",
            cacheRoot: cacheRoot
        ) { _ in }

        XCTAssertEqual(
            ChunkedHuggingFaceURLProtocol.recordedAuthorizationHeaders(),
            ["Bearer test-token", "Bearer test-token"]
        )
    }

    func testNativeSnapshotKeepsInProgressMarkerWhenRevisionRefWriteFails() async throws {
        let cacheRoot = try makeTemporaryDirectory()
        let checkpointsPath = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: cacheRoot)
            try? FileManager.default.removeItem(at: checkpointsPath)
        }

        let modelCacheRoot = RuntimeManager.modelCachePath(
            modelId: "org/model",
            huggingFaceCacheRoot: cacheRoot
        )
        try FileManager.default.createDirectory(at: modelCacheRoot, withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: modelCacheRoot.appendingPathComponent("refs"))

        ChunkedHuggingFaceURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChunkedHuggingFaceURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let service = NativeModelDownloadService(
            session: session,
            baseURL: URL(string: "https://hf.test")!,
            downloadSessionConfiguration: configuration,
            maximumConcurrentDownloads: 1,
            progressEmissionInterval: 0
        )

        do {
            try await service.downloadHuggingFaceSnapshot(
                repoID: "org/model",
                revision: "main",
                cacheRoot: cacheRoot
            ) { _ in }
            XCTFail("Expected revision ref finalization to fail")
        } catch {
            // Expected path.
        }

        let snapshotRoot = modelCacheRoot
            .appendingPathComponent("snapshots")
            .appendingPathComponent("revision")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: snapshotRoot.appendingPathComponent(NativeSnapshotCompletionManifest.filename).path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: snapshotRoot.appendingPathComponent(NativeSnapshotCompletionManifest.inProgressFilename).path
            )
        )

        guard case .incomplete(let message) = RuntimeManager.modelStorageStatus(
            modelId: "org/model",
            checkpointsPath: checkpointsPath,
            huggingFaceCacheRoot: cacheRoot
        ) else {
            return XCTFail("Expected failed finalization to leave the model incomplete")
        }
        XCTAssertTrue(message.contains("Native model download is still incomplete"))
    }

    func testNativeSnapshotFetchFallsBackToHubTokenWhenHFTokenIsBlank() async throws {
        ChunkedHuggingFaceURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChunkedHuggingFaceURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let service = NativeModelDownloadService(
            session: session,
            baseURL: URL(string: "https://hf.test")!,
            downloadSessionConfiguration: configuration,
            environment: ["HF_TOKEN": " ", "HUGGING_FACE_HUB_TOKEN": "fallback-token"]
        )

        _ = try await service.fetchManifest(repoID: "org/model", revision: "main")

        XCTAssertEqual(
            ChunkedHuggingFaceURLProtocol.recordedAuthorizationHeaders(),
            ["Bearer fallback-token"]
        )
    }

    func testNativeSnapshotDownloadResumesPartialFileWithRangeRequest() async throws {
        let cacheRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: cacheRoot) }

        let partialURL = RuntimeManager.modelCachePath(modelId: "org/model", huggingFaceCacheRoot: cacheRoot)
            .appendingPathComponent("snapshots")
            .appendingPathComponent("revision")
            .appendingPathComponent(".model.safetensors.download")
        try FileManager.default.createDirectory(
            at: partialURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([1, 2]).write(to: partialURL)

        ChunkedHuggingFaceURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChunkedHuggingFaceURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let service = NativeModelDownloadService(
            session: session,
            baseURL: URL(string: "https://hf.test")!,
            downloadSessionConfiguration: configuration,
            maximumConcurrentDownloads: 1,
            progressEmissionInterval: 0
        )

        try await service.downloadHuggingFaceSnapshot(
            repoID: "org/model",
            revision: "main",
            cacheRoot: cacheRoot
        ) { _ in }

        let modelFile = partialURL
            .deletingLastPathComponent()
            .appendingPathComponent("model.safetensors")

        XCTAssertEqual(ChunkedHuggingFaceURLProtocol.lastRangeHeader(), "bytes=2-")
        XCTAssertEqual(try Data(contentsOf: modelFile), Data([1, 2, 3, 4]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partialURL.path))
    }

    func testNativeSnapshotDownloadRestartsWhenServerIgnoresRangeRequest() async throws {
        let cacheRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: cacheRoot) }

        let partialURL = RuntimeManager.modelCachePath(modelId: "org/model", huggingFaceCacheRoot: cacheRoot)
            .appendingPathComponent("snapshots")
            .appendingPathComponent("revision")
            .appendingPathComponent(".model.safetensors.download")
        try FileManager.default.createDirectory(
            at: partialURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([9, 9]).write(to: partialURL)

        ChunkedHuggingFaceURLProtocol.reset()
        ChunkedHuggingFaceURLProtocol.setIgnoreRangeRequests(true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChunkedHuggingFaceURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let service = NativeModelDownloadService(
            session: session,
            baseURL: URL(string: "https://hf.test")!,
            downloadSessionConfiguration: configuration,
            maximumConcurrentDownloads: 1,
            progressEmissionInterval: 0
        )

        try await service.downloadHuggingFaceSnapshot(
            repoID: "org/model",
            revision: "main",
            cacheRoot: cacheRoot
        ) { _ in }

        let modelFile = partialURL
            .deletingLastPathComponent()
            .appendingPathComponent("model.safetensors")

        XCTAssertEqual(ChunkedHuggingFaceURLProtocol.lastRangeHeader(), "bytes=2-")
        XCTAssertEqual(try Data(contentsOf: modelFile), Data([1, 2, 3, 4]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partialURL.path))
    }

    func testNativeSnapshotDownloadRetriesTransientFailureAndResumesPartialFile() async throws {
        let cacheRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: cacheRoot) }

        let partialURL = RuntimeManager.modelCachePath(modelId: "org/model", huggingFaceCacheRoot: cacheRoot)
            .appendingPathComponent("snapshots")
            .appendingPathComponent("revision")
            .appendingPathComponent(".model.safetensors.download")
        try FileManager.default.createDirectory(
            at: partialURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([1, 2]).write(to: partialURL)

        ChunkedHuggingFaceURLProtocol.reset(failFirstDownloadBeforeResponse: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChunkedHuggingFaceURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let service = NativeModelDownloadService(
            session: session,
            baseURL: URL(string: "https://hf.test")!,
            downloadSessionConfiguration: configuration,
            maximumConcurrentDownloads: 1,
            maximumDownloadAttempts: 2,
            progressEmissionInterval: 0
        )

        try await service.downloadHuggingFaceSnapshot(
            repoID: "org/model",
            revision: "main",
            cacheRoot: cacheRoot
        ) { _ in }

        let modelFile = RuntimeManager.modelCachePath(modelId: "org/model", huggingFaceCacheRoot: cacheRoot)
            .appendingPathComponent("snapshots")
            .appendingPathComponent("revision")
            .appendingPathComponent("model.safetensors")

        XCTAssertEqual(ChunkedHuggingFaceURLProtocol.recordedRangeHeaders(), ["bytes=2-", "bytes=2-"])
        XCTAssertEqual(try Data(contentsOf: modelFile), Data([1, 2, 3, 4]))
    }

    func testNativeSnapshotDownloadVerifiesHashDespiteSmallHashLimitByDefault() async throws {
        let cacheRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: cacheRoot) }

        ChunkedHuggingFaceURLProtocol.reset(manifestSHA256: String(repeating: "0", count: 64))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChunkedHuggingFaceURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let service = NativeModelDownloadService(
            session: session,
            baseURL: URL(string: "https://hf.test")!,
            downloadSessionConfiguration: configuration,
            environment: ["MLXTRA_HASH_VERIFY_MAX_BYTES": "1"],
            maximumConcurrentDownloads: 1,
            progressEmissionInterval: 0
        )

        do {
            try await service.downloadHuggingFaceSnapshot(
                repoID: "org/model",
                revision: "main",
                cacheRoot: cacheRoot
            ) { _ in }
            XCTFail("Expected hash verification to fail")
        } catch NativeModelDownloadError.checksumMismatch(let path) {
            XCTAssertEqual(path, "model.safetensors")
        }
    }


    func testHuggingFaceManifestParsesFilesMetadata() throws {
        let payload = """
        {
          "sha": "abc123",
          "siblings": [
            {
              "rfilename": "config.json",
              "size": 42
            },
            {
              "rfilename": "model.safetensors",
              "size": 135,
              "lfs": {
                "size": 1024,
                "sha256": "deadbeef"
              }
            }
          ]
        }
        """

        let manifest = try HuggingFaceManifest.parse(
            data: Data(payload.utf8),
            repoID: "org/model",
            revision: "main"
        )

        XCTAssertEqual(manifest.repoID, "org/model")
        XCTAssertEqual(manifest.revision, "main")
        XCTAssertEqual(manifest.resolvedRevision, "abc123")
        XCTAssertEqual(
            manifest.files,
            [
                HuggingFaceManifestFile(path: "config.json", size: 42, sha256: nil),
                HuggingFaceManifestFile(path: "model.safetensors", size: 1024, sha256: "deadbeef")
            ]
        )
    }

    func testHuggingFaceManifestRejectsEmptySiblingList() {
        let payload = #"{"sha":"abc123","siblings":[]}"#

        XCTAssertThrowsError(
            try HuggingFaceManifest.parse(
                data: Data(payload.utf8),
                repoID: "org/empty",
                revision: "main"
            )
        ) { error in
            XCTAssertEqual(error as? NativeModelDownloadError, .emptyManifest("org/empty"))
        }
    }

    func testAceStepPlanUsesOfficialMainRepositoryAndCheckpointComponents() throws {
        let checkpointsRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: checkpointsRoot) }

        let plan = AceStepDownloadPlan(
            repoID: "ACE-Step/Ace-Step1.5",
            requiredComponents: ["acestep-v15-turbo", "vae", "Qwen3-Embedding-0.6B", "acestep-5Hz-lm-1.7B"],
            checkpointsRoot: checkpointsRoot
        )

        XCTAssertEqual(plan.repoID, "ACE-Step/Ace-Step1.5")
        XCTAssertEqual(
            plan.requiredComponents,
            ["acestep-v15-turbo", "vae", "Qwen3-Embedding-0.6B", "acestep-5Hz-lm-1.7B"]
        )
        XCTAssertEqual(
            plan.componentURL(component: "vae"),
            checkpointsRoot.appendingPathComponent("vae")
        )
    }

    func testAceStepContractCompleteClearsGenericNativeMarkersAndWritesContractMarker() throws {
        let checkpointsRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: checkpointsRoot) }

        try Data("in-progress".utf8).write(
            to: checkpointsRoot.appendingPathComponent(AceStepContractCompletionManifest.inProgressFilename)
        )
        try Data("in-progress".utf8).write(
            to: checkpointsRoot.appendingPathComponent(NativeSnapshotCompletionManifest.inProgressFilename)
        )
        try Data("{}".utf8).write(
            to: checkpointsRoot.appendingPathComponent(NativeSnapshotCompletionManifest.filename)
        )

        try NativeModelDownloadService().markAceStepContractComplete(
            plan: AceStepDownloadPlan(
                repoID: "ACE-Step/Ace-Step1.5",
                requiredComponents: ["acestep-v15-turbo", "vae", "Qwen3-Embedding-0.6B", "acestep-5Hz-lm-1.7B"],
                checkpointsRoot: checkpointsRoot
            )
        )

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: checkpointsRoot.appendingPathComponent(NativeSnapshotCompletionManifest.inProgressFilename).path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: checkpointsRoot.appendingPathComponent(NativeSnapshotCompletionManifest.filename).path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: checkpointsRoot.appendingPathComponent(AceStepContractCompletionManifest.inProgressFilename).path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: checkpointsRoot.appendingPathComponent(AceStepContractCompletionManifest.filename).path
            )
        )
    }

    func testMarkerStoreWritesSnapshotCompletionAndRevisionRef() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshotRoot = root
            .appendingPathComponent("snapshots")
            .appendingPathComponent("resolved")
        let staleCompletionURL = snapshotRoot.appendingPathComponent(NativeSnapshotCompletionManifest.filename)
        let markerStore = NativeModelDownloadMarkerStore()

        try FileManager.default.createDirectory(at: snapshotRoot, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: staleCompletionURL)
        try markerStore.markSnapshotInProgress(at: snapshotRoot)

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: snapshotRoot.appendingPathComponent(NativeSnapshotCompletionManifest.inProgressFilename).path
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleCompletionURL.path))

        let manifest = HuggingFaceManifest(
            repoID: "org/model",
            revision: "main",
            resolvedRevision: "resolved",
            files: [HuggingFaceManifestFile(path: "model.safetensors", size: 4, sha256: "abc")]
        )
        try markerStore.writeCompletionManifest(manifest, destinationRoot: snapshotRoot)
        try markerStore.clearSnapshotInProgress(at: snapshotRoot)
        try markerStore.writeRevisionRef(revision: "main", resolvedRevision: "resolved", modelCacheRoot: root)

        let completionData = try Data(contentsOf: staleCompletionURL)
        let completionManifest = try JSONDecoder().decode(NativeSnapshotCompletionManifest.self, from: completionData)
        XCTAssertEqual(completionManifest.repoID, "org/model")
        XCTAssertEqual(completionManifest.files.map(\.path), ["model.safetensors"])
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: snapshotRoot.appendingPathComponent(NativeSnapshotCompletionManifest.inProgressFilename).path
            )
        )
        XCTAssertEqual(
            String(data: try Data(contentsOf: root.appendingPathComponent("refs/main")), encoding: .utf8),
            "resolved"
        )
    }

    func testRemovePartialDownloadsRemovesTransientArtifactsOnly() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let nested = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let partial = nested.appendingPathComponent(".model.safetensors.download")
        let snapshotInProgress = nested.appendingPathComponent(NativeSnapshotCompletionManifest.inProgressFilename)
        let aceStepInProgress = nested.appendingPathComponent(AceStepContractCompletionManifest.inProgressFilename)
        let snapshotComplete = nested.appendingPathComponent(NativeSnapshotCompletionManifest.filename)
        let aceStepComplete = nested.appendingPathComponent(AceStepContractCompletionManifest.filename)
        let complete = nested.appendingPathComponent("model.safetensors")
        try Data([1]).write(to: partial)
        try Data([2]).write(to: snapshotInProgress)
        try Data([3]).write(to: aceStepInProgress)
        try Data([4]).write(to: snapshotComplete)
        try Data([5]).write(to: aceStepComplete)
        try Data([2]).write(to: complete)

        try NativeModelDownloadService().removePartialDownloads(at: root)

        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotInProgress.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: aceStepInProgress.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotComplete.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: aceStepComplete.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: complete.path))
    }

    func testNativeDownloadErrorMapsHuggingFaceStatusCodes() {
        XCTAssertEqual(
            NativeModelDownloadError.httpStatus(401, "org/private").localizedDescription,
            "Hugging Face authentication is required for org/private."
        )
        XCTAssertEqual(
            NativeModelDownloadError.httpStatus(403, "org/gated").localizedDescription,
            "Hugging Face denied access to org/gated. Accept the model license or check your account access."
        )
        XCTAssertEqual(
            NativeModelDownloadError.httpStatus(429, "org/model").localizedDescription,
            "Hugging Face rate limit reached while downloading org/model. Try again later."
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MLXtraTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class ChunkedHuggingFaceURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var rangeHeaders: [String?] = []
    private static var authorizationHeaders: [String?] = []
    private static var ignoreRangeRequests = false
    private static var failFirstDownloadBeforeResponse = false
    private static var hasFailedFirstDownloadBeforeResponse = false
    private static var manifestSHA256: String?

    static func reset(
        manifestSHA256: String? = nil,
        failFirstDownloadBeforeResponse: Bool = false
    ) {
        lock.lock()
        rangeHeaders = []
        authorizationHeaders = []
        ignoreRangeRequests = false
        self.failFirstDownloadBeforeResponse = failFirstDownloadBeforeResponse
        hasFailedFirstDownloadBeforeResponse = false
        self.manifestSHA256 = manifestSHA256
        lock.unlock()
    }

    static func setIgnoreRangeRequests(_ value: Bool) {
        lock.lock()
        ignoreRangeRequests = value
        lock.unlock()
    }

    static func lastRangeHeader() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return rangeHeaders.last ?? nil
    }

    static func recordedRangeHeaders() -> [String?] {
        lock.lock()
        defer { lock.unlock() }
        return rangeHeaders
    }

    static func recordedAuthorizationHeaders() -> [String?] {
        lock.lock()
        defer { lock.unlock() }
        return authorizationHeaders
    }

    private static func shouldIgnoreRangeRequests() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return ignoreRangeRequests
    }

    private static func manifestShaLine() -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let manifestSHA256 else { return "" }
        return #","lfs": {"size": 4, "sha256": "\#(manifestSHA256)"}"#
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "hf.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.lock.lock()
        Self.authorizationHeaders.append(request.value(forHTTPHeaderField: "Authorization"))
        Self.lock.unlock()

        switch url.path {
        case "/api/models/org/model/revision/main":
            respond(
                statusCode: 200,
                data: Data(
                    """
                    {
                      "sha": "revision",
                      "siblings": [
                        {
                          "rfilename": "model.safetensors",
                          "size": 4
                          \(Self.manifestShaLine())
                        }
                      ]
                    }
                    """.utf8
                )
            )
        case "/org/model/resolve/revision/model.safetensors":
            let rangeHeader = request.value(forHTTPHeaderField: "Range")
            Self.lock.lock()
            Self.rangeHeaders.append(rangeHeader)
            let shouldFailBeforeResponse = Self.failFirstDownloadBeforeResponse
                && !Self.hasFailedFirstDownloadBeforeResponse
            if shouldFailBeforeResponse {
                Self.hasFailedFirstDownloadBeforeResponse = true
            }
            Self.lock.unlock()
            if shouldFailBeforeResponse {
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
                return
            }
            let servesRange = rangeHeader == "bytes=2-" && !Self.shouldIgnoreRangeRequests()

            guard let response = HTTPURLResponse(
                url: url,
                statusCode: servesRange ? 206 : 200,
                httpVersion: nil,
                headerFields: servesRange
                    ? ["Content-Length": "2", "Content-Range": "bytes 2-3/4"]
                    : ["Content-Length": "4"]
            ) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            let firstChunk = servesRange ? Data([3]) : Data([1, 2])
            let secondChunk = servesRange ? Data([4]) : Data([3, 4])
            client?.urlProtocol(self, didLoad: firstChunk)
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) { [weak self] in
                guard let self else { return }
                self.client?.urlProtocol(self, didLoad: secondChunk)
                self.client?.urlProtocolDidFinishLoading(self)
            }
        default:
            respond(statusCode: 404, data: Data())
        }
    }

    override func stopLoading() {}

    private func respond(statusCode: Int, data: Data) {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [NativeModelDownloadProgress] = []

    func append(_ event: NativeModelDownloadProgress) {
        lock.lock()
        recordedEvents.append(event)
        lock.unlock()
    }

    func events() -> [NativeModelDownloadProgress] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents
    }
}
