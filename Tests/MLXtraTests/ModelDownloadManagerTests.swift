import Darwin
import XCTest
@testable import MLXtra

final class ModelDownloadManagerTests: XCTestCase {

    // MARK: - DownloadState Tests

    func testDownloadStateEquatable() {
        XCTAssertEqual(ModelDownloadManager.DownloadState.notDownloaded, ModelDownloadManager.DownloadState.notDownloaded)
        XCTAssertEqual(ModelDownloadManager.DownloadState.downloading(nil), ModelDownloadManager.DownloadState.downloading(nil))
        XCTAssertEqual(ModelDownloadManager.DownloadState.paused(nil), ModelDownloadManager.DownloadState.paused(nil))
        XCTAssertEqual(ModelDownloadManager.DownloadState.downloaded, ModelDownloadManager.DownloadState.downloaded)
        XCTAssertEqual(ModelDownloadManager.DownloadState.failed("error"), ModelDownloadManager.DownloadState.failed("error"))
        XCTAssertNotEqual(ModelDownloadManager.DownloadState.notDownloaded, ModelDownloadManager.DownloadState.downloaded)
        XCTAssertNotEqual(ModelDownloadManager.DownloadState.failed("error1"), ModelDownloadManager.DownloadState.failed("error2"))
    }

    func testDownloadStateIsDownloading() {
        XCTAssertFalse(ModelDownloadManager.DownloadState.notDownloaded.isDownloading)
        XCTAssertTrue(ModelDownloadManager.DownloadState.downloading(nil).isDownloading)
        XCTAssertFalse(ModelDownloadManager.DownloadState.paused(nil).isDownloading)
        XCTAssertFalse(ModelDownloadManager.DownloadState.downloaded.isDownloading)
        XCTAssertFalse(ModelDownloadManager.DownloadState.failed("error").isDownloading)
    }

    func testDownloadStatePausedAndProgress() {
        let progress = ModelDownloadManager.DownloadProgress(
            status: "Downloading",
            description: nil,
            unit: "files",
            progressKind: "files",
            downloadedBytes: 2,
            totalBytes: 4,
            percent: 50
        )

        XCTAssertTrue(ModelDownloadManager.DownloadState.paused(progress).isPaused)
        XCTAssertEqual(ModelDownloadManager.DownloadState.paused(progress).progress, progress)
        XCTAssertEqual(ModelDownloadManager.DownloadState.downloading(progress).progress, progress)
        XCTAssertNil(ModelDownloadManager.DownloadState.notDownloaded.progress)
    }

    func testByteProgressDoesNotUsePercentDisplay() {
        let progress = ModelDownloadManager.DownloadProgress(
            status: "Downloading",
            description: "model.safetensors",
            unit: "B",
            progressKind: "bytes",
            downloadedBytes: 1_048_576,
            totalBytes: 2_097_152,
            percent: nil
        )

        XCTAssertNil(progress.fractionCompleted)
        XCTAssertEqual(progress.displayText, "Downloading")
        XCTAssertEqual(progress.detailText, "1 MB of 2.1 MB")
    }

    func testDownloadProgressFormatting() {
        let progress = ModelDownloadManager.DownloadProgress(
            status: "downloading",
            description: "Downloading",
            unit: "B",
            progressKind: "bytes",
            downloadedBytes: 1_048_576,
            totalBytes: 2_097_152,
            percent: 50.0
        )

        XCTAssertEqual(progress.displayText, "50%")
        XCTAssertEqual(progress.fractionCompleted, 0.5)
        XCTAssertNotNil(progress.detailText)
    }

    func testDownloadProgressClampsDisplayedPercent() {
        let progress = ModelDownloadManager.DownloadProgress(
            status: "downloading",
            description: nil,
            unit: "B",
            progressKind: "bytes",
            downloadedBytes: nil,
            totalBytes: nil,
            percent: 142.0
        )

        XCTAssertEqual(progress.displayText, "100%")
        XCTAssertEqual(progress.fractionCompleted, 1.0)
    }

    func testDownloadManagerIgnoresUntrustedProgressPercent() {
        let event: [String: Any] = [
            "percent": 100.0,
            "percent_reliable": false
        ]

        XCTAssertNil(ModelDownloadManager.reliableDownloadPercent(from: event, progressKind: "files"))
        XCTAssertNil(ModelDownloadManager.reliableDownloadPercent(from: event, progressKind: "bytes"))
    }

    func testDownloadManagerAcceptsReliableAggregateBytePercent() {
        let event: [String: Any] = [
            "percent": 42.5,
            "progress_scope": "aggregate"
        ]

        XCTAssertEqual(
            ModelDownloadManager.reliableDownloadPercent(from: event, progressKind: "bytes"),
            42.5
        )
    }

    func testDownloadManagerAcceptsExplicitReliablePercent() {
        let event: [String: Any] = [
            "percent": 12,
            "percent_reliable": true
        ]

        XCTAssertEqual(
            ModelDownloadManager.reliableDownloadPercent(from: event, progressKind: "activity"),
            12.0
        )
    }

    func testDownloadManagerClampsReliablePercent() {
        XCTAssertEqual(
            ModelDownloadManager.reliableDownloadPercent(
                from: ["percent": 142.0, "percent_reliable": true],
                progressKind: "activity"
            ),
            100.0
        )
        XCTAssertEqual(
            ModelDownloadManager.reliableDownloadPercent(
                from: ["percent": -12.0, "percent_reliable": true],
                progressKind: "activity"
            ),
            0.0
        )
    }

    @MainActor
    func testDownloadProgressDoesNotMoveBackward() {
        let manager = ModelDownloadManager(refreshStatusesOnInit: false)
        let modelId = "test-model"

        manager.handleDownloadEventLine(
            #"{"type":"download.progress","status":"Downloading","progress_kind":"activity","percent":60,"percent_reliable":true}"#,
            modelId: modelId
        )
        manager.handleDownloadEventLine(
            #"{"type":"download.progress","status":"Downloading","progress_kind":"activity","percent":20,"percent_reliable":true}"#,
            modelId: modelId
        )

        XCTAssertEqual(manager.states[modelId]?.progress?.percent, 60.0)
        XCTAssertEqual(manager.states[modelId]?.progress?.displayText, "60%")
    }

    @MainActor
    func testDownloadCancelClearsPausedOrPartialProgress() {
        let manager = ModelDownloadManager(refreshStatusesOnInit: false)
        let model = DownloadableModel(
            id: "test-download",
            name: "Test Download",
            subtitle: "Test model",
            modelId: "test/download",
            modality: .vision,
            downloadSizeGB: 1.0
        )

        manager.handleDownloadEventLine(
            #"{"type":"download.progress","status":"Downloading","progress_kind":"activity","percent":40,"percent_reliable":true}"#,
            modelId: model.id
        )
        manager.cancel(model)

        XCTAssertEqual(manager.state(for: model), .notDownloaded)
    }

    @MainActor
    func testCancelTerminatesRunningDownloadProcessAndCleansTracking() async throws {
        let manager = ModelDownloadManager(refreshStatusesOnInit: false)
        let model = makeLifecycleTestModel(id: "test-cancel-running-process")
        let process = try startLongRunningProcess(ignoresTermination: true)
        defer { terminateIfNeeded(process) }
        let originalKillDelay = ModelDownloadManager.terminationKillFallbackDelay
        let originalCleanupDelay = ModelDownloadManager.terminationCleanupDelay
        ModelDownloadManager.terminationKillFallbackDelay = 0.1
        ModelDownloadManager.terminationCleanupDelay = 0.15
        defer {
            ModelDownloadManager.terminationKillFallbackDelay = originalKillDelay
            ModelDownloadManager.terminationCleanupDelay = originalCleanupDelay
        }

        manager.installTestDownloadProcess(process, for: model)
        manager.cancel(model)

        XCTAssertEqual(manager.state(for: model), .notDownloaded)
        await waitUntil { !process.isRunning }
        await waitUntil { !manager.hasTrackedProcess(for: model) }
        await waitUntil { !manager.hasTrackedTask(for: model) }
    }

    @MainActor
    func testPauseTerminatesRunningDownloadProcessAndKeepsPausedState() async throws {
        let manager = ModelDownloadManager(refreshStatusesOnInit: false)
        let model = makeLifecycleTestModel(id: "test-pause-running-process")
        let process = try startLongRunningProcess()
        defer { terminateIfNeeded(process) }
        let originalKillDelay = ModelDownloadManager.terminationKillFallbackDelay
        let originalCleanupDelay = ModelDownloadManager.terminationCleanupDelay
        ModelDownloadManager.terminationKillFallbackDelay = 0.1
        ModelDownloadManager.terminationCleanupDelay = 0.15
        defer {
            ModelDownloadManager.terminationKillFallbackDelay = originalKillDelay
            ModelDownloadManager.terminationCleanupDelay = originalCleanupDelay
        }

        manager.installTestDownloadProcess(process, for: model)
        manager.handleDownloadEventLine(
            #"{"type":"download.progress","status":"Downloading","progress_kind":"activity","percent":35,"percent_reliable":true}"#,
            modelId: model.id
        )
        manager.pause(model)

        guard case .paused(let progress) = manager.state(for: model) else {
            return XCTFail("Expected paused state after pausing a running download")
        }
        XCTAssertEqual(progress?.percent, 35.0)
        await waitUntil { !process.isRunning }
        await waitUntil { !manager.hasTrackedProcess(for: model) }
        await waitUntil { !manager.hasTrackedTask(for: model) }
    }

    func testDownloadErrorTrackerCanClearStaleErrorForRetry() {
        let tracker = DownloadErrorTracker()
        let modelId = "org/model"

        tracker.setErrorReceived(for: modelId)
        XCTAssertTrue(tracker.errorWasReceived(for: modelId))

        tracker.clearErrorReceived(for: modelId)
        XCTAssertFalse(tracker.errorWasReceived(for: modelId))
    }

    func testDownloadStateTerminalStatus() {
        XCTAssertFalse(ModelDownloadManager.DownloadState.notDownloaded.isTerminal)
        XCTAssertFalse(ModelDownloadManager.DownloadState.downloading(nil).isTerminal)
        XCTAssertFalse(ModelDownloadManager.DownloadState.paused(nil).isTerminal)
        XCTAssertTrue(ModelDownloadManager.DownloadState.downloaded.isTerminal)
        XCTAssertTrue(ModelDownloadManager.DownloadState.failed("error").isTerminal)
    }

    func testDownloadStateIdentifiesRepairableFailures() {
        XCTAssertTrue(
            ModelDownloadManager.DownloadState
                .failed("Local Hugging Face cache is incomplete.")
                .isRepairableFailure
        )
        XCTAssertTrue(
            ModelDownloadManager.DownloadState
                .failed("Download finished, but model files were not found in cache.")
                .isRepairableFailure
        )
        XCTAssertFalse(
            ModelDownloadManager.DownloadState
                .failed("Network connection lost.")
                .isRepairableFailure
        )
    }

    func testRemoveLocalFilesDeletesHuggingFaceCacheDirectory() throws {
        let cacheRoot = try makeTemporaryDirectory()
        let checkpointsPath = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: cacheRoot)
            try? FileManager.default.removeItem(at: checkpointsPath)
        }

        let model = DownloadableModel(
            id: "org/example-model",
            name: "Example",
            subtitle: "Test model",
            modelId: "org/example-model",
            modality: .vision,
            downloadSizeGB: 1.0,
            source: ModelSource(type: .huggingFaceSnapshot, repo: "org/example-model", revision: "main")
        )
        let modelCachePath = RuntimeManager.modelCachePath(
            modelId: "org/example-model",
            huggingFaceCacheRoot: cacheRoot
        )
        try FileManager.default.createDirectory(at: modelCachePath, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: modelCachePath.appendingPathComponent("model.safetensors"))

        try ModelDownloadManager.removeLocalFiles(
            for: model,
            checkpointsPath: checkpointsPath,
            huggingFaceCacheRoot: cacheRoot
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: modelCachePath.path))
    }

    func testRemoveLocalFilesDeletesOnlyCatalogComponentFolders() throws {
        let cacheRoot = try makeTemporaryDirectory()
        let checkpointsPath = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: cacheRoot)
            try? FileManager.default.removeItem(at: checkpointsPath)
        }

        let model = DownloadableModel(
            id: "component-model",
            name: "Component Model",
            subtitle: "Test model",
            modelId: "components/model",
            modality: .music,
            backend: .music,
            downloadSizeGB: 1.0,
            source: ModelSource(
                type: .componentBundle,
                repo: "components/model",
                components: ["component-a", "component-b"]
            )
        )
        let componentA = checkpointsPath.appendingPathComponent("component-a")
        let componentB = checkpointsPath.appendingPathComponent("component-b")
        let unrelated = checkpointsPath.appendingPathComponent("unrelated-component")
        try FileManager.default.createDirectory(at: componentA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: componentB, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)

        try ModelDownloadManager.removeLocalFiles(
            for: model,
            checkpointsPath: checkpointsPath,
            huggingFaceCacheRoot: cacheRoot
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: componentA.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: componentB.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testAceStepDownloadHelperUsageErrorUsesTypedEvent() throws {
        let helperPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("MLXtra/Resources/runtime/macos-arm64/acestep_download_helper.py")

        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [helperPath.path]
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        try process.run()
        process.waitUntilExit()

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let firstLine = try XCTUnwrap(output.split(separator: "\n").first)
        let data = Data(firstLine.utf8)
        let event = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertNotEqual(process.terminationStatus, 0)
        XCTAssertEqual(event["type"] as? String, "download.error")
        XCTAssertEqual(event["message"] as? String, "Usage: acestep_download_helper.py <repo_id> <local_dir>")
    }

    // MARK: - ModelDownloadError Tests

    func testModelDownloadErrorLocalizedDescription() {
        XCTAssertEqual(
            ModelDownloadError.downloadFailed("Download failed").errorDescription,
            "Download failed"
        )
        XCTAssertEqual(
            ModelDownloadError.downloadFailed("").errorDescription,
            ""
        )
        XCTAssertEqual(
            ModelDownloadError.stoppedByUser.errorDescription,
            "Download stopped."
        )
    }

    private func makeLifecycleTestModel(id: String) -> DownloadableModel {
        DownloadableModel(
            id: id,
            name: "Lifecycle Test",
            subtitle: "Test model",
            modelId: "test/lifecycle",
            modality: .vision,
            downloadSizeGB: 1.0
        )
    }

    private func startLongRunningProcess(ignoresTermination: Bool = false) throws -> Process {
        let process = Process()
        if ignoresTermination {
            let readyPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [
                "-c",
                "import signal, sys, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); print('ready', flush=True); time.sleep(30)"
            ]
            process.standardOutput = readyPipe
            try process.run()
            _ = readyPipe.fileHandleForReading.readData(ofLength: 6)
            return process
        } else {
            process.executableURL = URL(fileURLWithPath: "/bin/sleep")
            process.arguments = ["30"]
            try process.run()
            return process
        }
    }

    private func terminateIfNeeded(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(1.0)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MLXtraTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 2.0,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for condition")
    }
}
