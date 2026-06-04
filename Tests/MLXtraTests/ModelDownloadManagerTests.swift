import Darwin
import XCTest
@testable import MLXtra

final class ModelDownloadManagerTests: XCTestCase {


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

    @MainActor
    func testStateCoordinatorInvalidatesStaleRefreshSnapshots() {
        var coordinator = ModelDownloadStateCoordinator()
        let modelId = "org/model"

        let firstRefresh = coordinator.captureRefreshSnapshot(for: modelId)
        XCTAssertTrue(
            coordinator.canApplyRefresh(firstRefresh, for: modelId, currentState: .notDownloaded)
        )

        coordinator.recordStateChange(for: modelId)
        XCTAssertFalse(
            coordinator.canApplyRefresh(firstRefresh, for: modelId, currentState: .notDownloaded)
        )

        let olderRefresh = coordinator.captureRefreshSnapshot(for: modelId)
        let newerRefresh = coordinator.captureRefreshSnapshot(for: modelId)

        XCTAssertFalse(
            coordinator.canApplyRefresh(olderRefresh, for: modelId, currentState: .notDownloaded)
        )
        XCTAssertTrue(
            coordinator.canApplyRefresh(newerRefresh, for: modelId, currentState: .notDownloaded)
        )
        XCTAssertFalse(
            coordinator.canApplyRefresh(newerRefresh, for: modelId, currentState: .downloading(nil))
        )
    }

    @MainActor
    func testStateCoordinatorGuardsDownloadTokens() {
        var coordinator = ModelDownloadStateCoordinator()
        let modelId = "org/model"

        let firstToken = coordinator.beginDownload(for: modelId)
        XCTAssertTrue(coordinator.isActiveDownload(firstToken, for: modelId))

        let secondToken = coordinator.beginDownload(for: modelId)
        XCTAssertFalse(coordinator.isActiveDownload(firstToken, for: modelId))
        XCTAssertTrue(coordinator.isActiveDownload(secondToken, for: modelId))
        XCTAssertFalse(coordinator.finishDownload(firstToken, for: modelId))
        XCTAssertTrue(coordinator.finishDownload(secondToken, for: modelId))
        XCTAssertFalse(coordinator.isActiveDownload(secondToken, for: modelId))
    }

    @MainActor
    func testProgressTrackerRestoresPausedProgressAndClearsFreshDownloads() {
        let tracker = ModelDownloadProgressTracker()
        let event = ModelDownloadEvent.progress(
            status: "Downloading",
            description: "weights",
            unit: nil,
            progressKind: "activity",
            downloadedBytes: nil,
            totalBytes: nil,
            percent: 42
        )

        XCTAssertNil(tracker.initialProgress(for: "model", currentState: .notDownloaded))

        let recorded = tracker.recordEventProgress(event, modelId: "model")
        XCTAssertEqual(recorded?.percent, 42)
        XCTAssertEqual(tracker.pauseProgress(for: "model", currentState: nil)?.percent, 42)
        XCTAssertEqual(tracker.initialProgress(for: "model", currentState: .paused(nil))?.percent, 42)

        XCTAssertNil(tracker.initialProgress(for: "model", currentState: .notDownloaded))
        XCTAssertNil(tracker.pauseProgress(for: "model", currentState: nil))
    }

    @MainActor
    func testProgressTrackerKeepsNativeProgressMonotonic() {
        let tracker = ModelDownloadProgressTracker()
        let first = tracker.recordNativeProgress(
            NativeModelDownloadProgress(
                status: "Downloading",
                description: "model.safetensors",
                downloadedBytes: 700,
                totalBytes: 1000,
                percent: 70
            ),
            modelId: "model"
        )
        let second = tracker.recordNativeProgress(
            NativeModelDownloadProgress(
                status: "Downloading",
                description: "model.safetensors",
                downloadedBytes: 200,
                totalBytes: 1000,
                percent: 20
            ),
            modelId: "model"
        )

        XCTAssertEqual(first.percent, 70)
        XCTAssertEqual(first.unit, "B")
        XCTAssertEqual(first.progressKind, "bytes")
        XCTAssertEqual(second.percent, 70)
    }

    @MainActor
    func testProgressTrackerUsesCurrentPausedStateBeforeStoredProgress() {
        let tracker = ModelDownloadProgressTracker()
        _ = tracker.recordEventProgress(
            .progress(
                status: "Downloading",
                description: nil,
                unit: nil,
                progressKind: "activity",
                downloadedBytes: nil,
                totalBytes: nil,
                percent: 10
            ),
            modelId: "model"
        )
        let pausedProgress = ModelDownloadManager.DownloadProgress(
            status: "Paused",
            description: nil,
            unit: nil,
            progressKind: "activity",
            downloadedBytes: nil,
            totalBytes: nil,
            percent: 25
        )

        XCTAssertEqual(
            tracker.pauseProgress(for: "model", currentState: .paused(pausedProgress))?.percent,
            25
        )
        XCTAssertNil(tracker.recordEventProgress(.error("failed"), modelId: "model"))
        tracker.clear(for: "model")
        XCTAssertNil(tracker.pauseProgress(for: "model", currentState: nil))
    }

    @MainActor
    func testFailureResolverPreservesPauseProgressAndCancelAction() {
        let tracker = ModelDownloadProgressTracker()
        let resolver = ModelDownloadFailureResolver(progressTracker: tracker)
        let modelId = "org/model"
        _ = tracker.recordEventProgress(
            .progress(
                status: "Downloading",
                description: nil,
                unit: nil,
                progressKind: "activity",
                downloadedBytes: nil,
                totalBytes: nil,
                percent: 35
            ),
            modelId: modelId
        )
        let error = NSError(domain: "ModelDownloadManagerTests", code: 1)

        let pauseAction = resolver.action(
            for: error,
            modelId: modelId,
            stopReason: .pause,
            currentState: nil,
            helperErrorWasReceived: false
        )
        let cancelAction = resolver.action(
            for: error,
            modelId: modelId,
            stopReason: .cancel,
            currentState: .downloading(nil),
            helperErrorWasReceived: false
        )

        XCTAssertEqual(pauseAction, .pause(ModelDownloadManager.DownloadProgress(
            status: "Downloading",
            description: nil,
            unit: nil,
            progressKind: "activity",
            downloadedBytes: nil,
            totalBytes: nil,
            percent: 35
        )))
        XCTAssertEqual(cancelAction, .cancel)
    }

    @MainActor
    func testFailureResolverSuppressesHelperErrorAndFailsRegularError() {
        let resolver = ModelDownloadFailureResolver(progressTracker: ModelDownloadProgressTracker())
        let error = NSError(
            domain: "ModelDownloadManagerTests",
            code: 7,
            userInfo: [NSLocalizedDescriptionKey: "network failed"]
        )

        XCTAssertEqual(
            resolver.action(
                for: error,
                modelId: "org/model",
                stopReason: nil,
                currentState: .downloading(nil),
                helperErrorWasReceived: true
            ),
            .suppress
        )
        XCTAssertEqual(
            resolver.action(
                for: error,
                modelId: "org/model",
                stopReason: nil,
                currentState: .downloading(nil),
                helperErrorWasReceived: false
            ),
            .fail("network failed")
        )
    }

    @MainActor
    func testStopCoordinatorTreatsTrackedWorkAsRemovalBlocking() {
        let lifecycle = ModelDownloadLifecycle()
        let tracker = ModelDownloadProgressTracker()
        let coordinator = ModelDownloadStopCoordinator(
            lifecycle: lifecycle,
            progressTracker: tracker
        )
        let modelId = "org/model"

        lifecycle.setTask(Task {}, for: modelId)

        XCTAssertTrue(
            coordinator.removalNeedsTrackedWorkToStop(
                for: modelId,
                currentState: .failed("Model removal is still stopping.")
            )
        )

        lifecycle.clearTask(for: modelId)

        XCTAssertFalse(
            coordinator.removalNeedsTrackedWorkToStop(
                for: modelId,
                currentState: .failed("Model removal is still stopping.")
            )
        )
    }

    @MainActor
    func testStopCoordinatorReturnsVisibleStateForPauseAndCancel() {
        let lifecycle = ModelDownloadLifecycle()
        let tracker = ModelDownloadProgressTracker()
        let coordinator = ModelDownloadStopCoordinator(
            lifecycle: lifecycle,
            progressTracker: tracker
        )
        let modelId = "org/model"
        _ = tracker.recordEventProgress(
            .progress(
                status: "Downloading",
                description: nil,
                unit: nil,
                progressKind: "activity",
                downloadedBytes: nil,
                totalBytes: nil,
                percent: 30
            ),
            modelId: modelId
        )
        lifecycle.setTask(Task {}, for: modelId)

        let pausedState = coordinator.stateAfterStopRequest(
            for: modelId,
            reason: .pause,
            currentState: nil,
            killFallbackDelay: 0,
            cleanupDelay: 0
        )
        XCTAssertEqual(pausedState?.progress?.percent, 30)

        lifecycle.clearCompletionTracking(for: modelId)
        lifecycle.setTask(Task {}, for: modelId)

        let cancelledState = coordinator.stateAfterStopRequest(
            for: modelId,
            reason: .cancel,
            currentState: .downloading(nil),
            killFallbackDelay: 0,
            cleanupDelay: 0
        )
        XCTAssertEqual(cancelledState, .notDownloaded)
        XCTAssertNil(tracker.pauseProgress(for: modelId, currentState: nil))

        lifecycle.clearCompletionTracking(for: modelId)
    }

    @MainActor
    func testHelperExecutorRunsContractValidationAndReplaysOutputLines() async throws {
        let lifecycle = ModelDownloadLifecycle()
        let checkpointsRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: checkpointsRoot) }
        let modelId = "ace-step"
        let process = Process()
        var capturedArguments: [String] = []
        var capturedEnvironment: [String: String] = [:]
        let executor = ModelDownloadHelperExecutor(
            runtimeManager: RuntimeManager(),
            lifecycle: lifecycle,
            processRunner: { executableURL, arguments, environment, onProcessStarted in
                XCTAssertFalse(executableURL.path.isEmpty)
                capturedArguments = arguments
                capturedEnvironment = environment
                onProcessStarted(process)
                XCTAssertTrue(lifecycle.hasTrackedProcess(for: modelId))
                return DownloadHelperProcessResult(
                    output: "\n{\"type\":\"download.started\"}\n{\"type\":\"download.complete\"}\n",
                    errorOutput: "",
                    terminationStatus: 0
                )
            }
        )
        var emittedLines: [String] = []
        let plan = AceStepDownloadPlan(
            repoID: "ACE-Step/acestep-v15-turbo-continuous",
            requiredComponents: ["acestep-v15-turbo"],
            checkpointsRoot: checkpointsRoot
        )

        try await executor.runAceStepContractValidation(
            plan: plan,
            modelId: modelId,
            onOutputLine: { emittedLines.append($0) }
        )

        XCTAssertEqual(capturedArguments.count, 3)
        XCTAssertTrue(capturedArguments[0].hasSuffix("acestep_download_helper.py"))
        XCTAssertEqual(capturedArguments[1], "--contract")
        XCTAssertEqual(capturedArguments[2], checkpointsRoot.path)
        XCTAssertEqual(capturedEnvironment["ACESTEP_CHECKPOINTS_DIR"], checkpointsRoot.path)
        XCTAssertEqual(capturedEnvironment["PYTHONDONTWRITEBYTECODE"], "1")
        XCTAssertNil(capturedEnvironment["PYTHONPATH"])
        XCTAssertNil(capturedEnvironment["VIRTUAL_ENV"])
        XCTAssertEqual(emittedLines, ["{\"type\":\"download.started\"}", "{\"type\":\"download.complete\"}"])
        XCTAssertFalse(lifecycle.hasTrackedProcess(for: modelId))
    }

    @MainActor
    func testDownloadHelperProcessRunnerBuffersOutputForExecutorReplay() async throws {
        let script = """
        import sys
        sys.stdout.write('{"type":"download.started"}\\n')
        sys.stdout.flush()
        sys.stdout.write('{"type":"download.complete"}\\n')
        sys.stdout.flush()
        """

        let result = try await DownloadHelperProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-c", script],
            environment: ProcessInfo.processInfo.environment,
            onProcessStarted: { _ in }
        )

        XCTAssertEqual(
            result.output.split(separator: "\n").map(String.init),
            ["{\"type\":\"download.started\"}", "{\"type\":\"download.complete\"}"]
        )
        XCTAssertEqual(result.errorOutput, "")
        XCTAssertEqual(result.terminationStatus, 0)
    }

    func testHelperFailureMessageUsesDownloadErrorEvent() {
        let result = DownloadHelperProcessResult(
            output: """
            {"type":"download.started"}
            {"type":"download.error","message":"component manifest missing"}
            """,
            errorOutput: "lower-level stderr",
            terminationStatus: 2
        )

        XCTAssertEqual(
            ModelDownloadHelperExecutor.failureMessage(for: result),
            "component manifest missing"
        )
    }

    func testHelperFailureMessagePrefersStderrOverStructuredProgressOutput() {
        let result = DownloadHelperProcessResult(
            output: """
            {"type":"download.started"}
            {"type":"download.progress","status":"Downloading","description":"model.safetensors"}
            """,
            errorOutput: "Traceback\nModuleNotFoundError: No module named 'huggingface_hub'",
            terminationStatus: 2
        )

        XCTAssertEqual(
            ModelDownloadHelperExecutor.failureMessage(for: result),
            "Traceback\nModuleNotFoundError: No module named 'huggingface_hub'"
        )
    }

    func testHelperFailureMessageAvoidsRawStructuredProgressWhenNoStderrExists() {
        let result = DownloadHelperProcessResult(
            output: """
            {"type":"download.started"}
            {"type":"download.complete"}
            """,
            errorOutput: "",
            terminationStatus: 3
        )

        XCTAssertEqual(
            ModelDownloadHelperExecutor.failureMessage(for: result),
            "Download helper exited with status 3 while finalizing."
        )
    }

    @MainActor
    func testHelperExecutorUsesStderrForEmptyOutputFailure() async throws {
        let lifecycle = ModelDownloadLifecycle()
        let checkpointsRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: checkpointsRoot) }
        let modelId = "ace-step-failure"
        let process = Process()
        let executor = ModelDownloadHelperExecutor(
            runtimeManager: RuntimeManager(),
            lifecycle: lifecycle,
            processRunner: { _, _, _, onProcessStarted in
                onProcessStarted(process)
                return DownloadHelperProcessResult(
                    output: "",
                    errorOutput: "contract failed",
                    terminationStatus: 2
                )
            }
        )
        let plan = AceStepDownloadPlan(
            repoID: "ACE-Step/acestep-v15-turbo-continuous",
            requiredComponents: ["acestep-v15-turbo"],
            checkpointsRoot: checkpointsRoot
        )

        do {
            try await executor.runAceStepContractValidation(
                plan: plan,
                modelId: modelId,
                onOutputLine: { _ in }
            )
            XCTFail("Expected contract validation to fail")
        } catch {
            let modelError = try XCTUnwrap(error as? ModelDownloadError)
            guard case .downloadFailed(let message) = modelError else {
                return XCTFail("Expected downloadFailed, got \(modelError)")
            }
            XCTAssertEqual(message, "contract failed")
        }

        XCTAssertFalse(lifecycle.hasTrackedProcess(for: modelId))
    }

    @MainActor
    func testHelperExecutorHonorsStopReasonAfterHelperExits() async throws {
        let lifecycle = ModelDownloadLifecycle()
        let checkpointsRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: checkpointsRoot) }
        let modelId = "ace-step-cancel"
        let process = Process()
        let executor = ModelDownloadHelperExecutor(
            runtimeManager: RuntimeManager(),
            lifecycle: lifecycle,
            processRunner: { _, _, _, onProcessStarted in
                onProcessStarted(process)
                return DownloadHelperProcessResult(
                    output: "{\"type\":\"download.complete\"}\n",
                    errorOutput: "",
                    terminationStatus: 0
                )
            }
        )
        let plan = AceStepDownloadPlan(
            repoID: "ACE-Step/acestep-v15-turbo-continuous",
            requiredComponents: ["acestep-v15-turbo"],
            checkpointsRoot: checkpointsRoot
        )
        lifecycle.setStopReason(.cancel, for: modelId)
        var emittedLines: [String] = []

        do {
            try await executor.runAceStepContractValidation(
                plan: plan,
                modelId: modelId,
                onOutputLine: { emittedLines.append($0) }
            )
            XCTFail("Expected stoppedByUser after cancellation")
        } catch {
            let modelError = try XCTUnwrap(error as? ModelDownloadError)
            guard case .stoppedByUser = modelError else {
                return XCTFail("Expected stoppedByUser, got \(modelError)")
            }
        }

        XCTAssertEqual(emittedLines, ["{\"type\":\"download.complete\"}"])
        XCTAssertFalse(lifecycle.hasTrackedProcess(for: modelId))
    }

    @MainActor
    func testHelperExecutorClearsProcessWhenRunnerThrows() async throws {
        let lifecycle = ModelDownloadLifecycle()
        let checkpointsRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: checkpointsRoot) }
        let modelId = "ace-step-runner-error"
        let process = Process()
        let executor = ModelDownloadHelperExecutor(
            runtimeManager: RuntimeManager(),
            lifecycle: lifecycle,
            processRunner: { _, _, _, onProcessStarted in
                onProcessStarted(process)
                throw HelperExecutorTestError.failed
            }
        )
        let plan = AceStepDownloadPlan(
            repoID: "ACE-Step/acestep-v15-turbo-continuous",
            requiredComponents: ["acestep-v15-turbo"],
            checkpointsRoot: checkpointsRoot
        )

        do {
            try await executor.runAceStepContractValidation(
                plan: plan,
                modelId: modelId,
                onOutputLine: { _ in }
            )
            XCTFail("Expected injected runner error")
        } catch HelperExecutorTestError.failed {
            // Expected path.
        } catch {
            XCTFail("Expected injected runner error, got \(error)")
        }

        XCTAssertFalse(lifecycle.hasTrackedProcess(for: modelId))
    }

    @MainActor
    func testLifecycleCancelsStaleProcessCleanupWhenNewProcessStarts() async throws {
        let lifecycle = ModelDownloadLifecycle()
        let modelId = "lifecycle-stale-cleanup"
        let oldProcess = try startLongRunningProcess(ignoresTermination: true)
        let newProcess = try startLongRunningProcess()
        defer {
            terminateIfNeeded(oldProcess)
            terminateIfNeeded(newProcess)
        }

        lifecycle.setTask(Task {}, for: modelId)
        lifecycle.setProcess(oldProcess, for: modelId)
        lifecycle.cancelTrackedWork(
            for: modelId,
            killFallbackDelay: 0.5,
            cleanupDelay: 0.5
        )

        XCTAssertTrue(lifecycle.hasTrackedCleanupTask(for: modelId))

        lifecycle.setProcess(newProcess, for: modelId)

        XCTAssertTrue(lifecycle.hasTrackedProcess(for: modelId))
        XCTAssertFalse(lifecycle.hasTrackedCleanupTask(for: modelId))
        XCTAssertTrue(newProcess.isRunning)
    }

    func testDownloadManagerIgnoresUntrustedProgressPercent() {
        let event: [String: Any] = [
            "percent": 100.0,
            "percent_reliable": false
        ]

        XCTAssertNil(ModelDownloadEventParser.reliableDownloadPercent(from: event, progressKind: "files"))
        XCTAssertNil(ModelDownloadEventParser.reliableDownloadPercent(from: event, progressKind: "bytes"))
    }

    func testDownloadManagerAcceptsReliableAggregateBytePercent() {
        let event: [String: Any] = [
            "percent": 42.5,
            "progress_scope": "aggregate"
        ]

        XCTAssertEqual(
            ModelDownloadEventParser.reliableDownloadPercent(from: event, progressKind: "bytes"),
            42.5
        )
    }

    func testDownloadManagerAcceptsExplicitReliablePercent() {
        let event: [String: Any] = [
            "percent": 12,
            "percent_reliable": true
        ]

        XCTAssertEqual(
            ModelDownloadEventParser.reliableDownloadPercent(from: event, progressKind: "activity"),
            12.0
        )
    }

    func testDownloadManagerClampsReliablePercent() {
        XCTAssertEqual(
            ModelDownloadEventParser.reliableDownloadPercent(
                from: ["percent": 142.0, "percent_reliable": true],
                progressKind: "activity"
            ),
            100.0
        )
        XCTAssertEqual(
            ModelDownloadEventParser.reliableDownloadPercent(
                from: ["percent": -12.0, "percent_reliable": true],
                progressKind: "activity"
            ),
            0.0
        )
    }

    func testDownloadEventParserBuildsTypedProgressEvent() {
        let event = ModelDownloadEventParser.parseDownloadEventLine(
            #"{"type":"download.progress","status":"Downloading","description":"model.safetensors","unit":"B","progress_kind":"bytes","downloaded":1024,"total":2048,"percent":50,"progress_scope":"aggregate"}"#
        )

        XCTAssertEqual(
            event,
            .progress(
                status: "Downloading",
                description: "model.safetensors",
                unit: "B",
                progressKind: "bytes",
                downloadedBytes: 1024,
                totalBytes: 2048,
                percent: 50
            )
        )
    }

    func testDownloadEventParserRejectsMalformedAndUnknownEvents() {
        XCTAssertNil(ModelDownloadEventParser.parseDownloadEventLine("not json"))
        XCTAssertNil(ModelDownloadEventParser.parseDownloadEventLine(#"{"type":"download.ignored"}"#))
        XCTAssertNil(ModelDownloadEventParser.parseDownloadEventLine(#"{"type":"download.error"}"#))
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

    @MainActor
    func testRemoveWaitsForRunningDownloadProcessBeforeDeletingFiles() async throws {
        let cacheRoot = try makeTemporaryDirectory()
        let checkpointsPath = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: cacheRoot)
            try? FileManager.default.removeItem(at: checkpointsPath)
        }

        let manager = ModelDownloadManager(
            refreshStatusesOnInit: false,
            checkpointsPathOverride: checkpointsPath,
            huggingFaceCacheRootOverride: cacheRoot
        )
        let model = DownloadableModel(
            id: "org/remove-process-model",
            name: "Remove Process",
            subtitle: "Test model",
            modelId: "org/remove-process-model",
            modality: .vision,
            downloadSizeGB: 1.0,
            source: ModelSource(type: .huggingFaceSnapshot, repo: "org/remove-process-model", revision: "main")
        )
        let modelCachePath = RuntimeManager.modelCachePath(
            modelId: "org/remove-process-model",
            huggingFaceCacheRoot: cacheRoot
        )
        try FileManager.default.createDirectory(at: modelCachePath, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: modelCachePath.appendingPathComponent("model.safetensors"))

        let process = try startLongRunningProcess(ignoresTermination: true)
        defer { terminateIfNeeded(process) }
        let originalKillDelay = ModelDownloadManager.terminationKillFallbackDelay
        let originalCleanupDelay = ModelDownloadManager.terminationCleanupDelay
        ModelDownloadManager.terminationKillFallbackDelay = 0.05
        ModelDownloadManager.terminationCleanupDelay = 0.12
        defer {
            ModelDownloadManager.terminationKillFallbackDelay = originalKillDelay
            ModelDownloadManager.terminationCleanupDelay = originalCleanupDelay
        }

        manager.installTestDownloadProcess(process, for: model)
        await manager.remove(model)

        XCTAssertFalse(process.isRunning)
        XCTAssertFalse(manager.hasTrackedProcess(for: model))
        XCTAssertFalse(manager.hasTrackedTask(for: model))
        XCTAssertFalse(FileManager.default.fileExists(atPath: modelCachePath.path))
        XCTAssertEqual(manager.state(for: model), .notDownloaded)
    }

    @MainActor
    func testRefreshStatusesDoesNotRestoreStaleStatusAfterRemove() async throws {
        let cacheRoot = try makeTemporaryDirectory()
        let checkpointsPath = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: cacheRoot)
            try? FileManager.default.removeItem(at: checkpointsPath)
        }

        let model = try XCTUnwrap(DownloadableModel.embedded.first)
        let gate = AsyncTestGate()
        let manager = ModelDownloadManager(
            refreshStatusesOnInit: false,
            checkpointsPathOverride: checkpointsPath,
            huggingFaceCacheRootOverride: cacheRoot,
            modelStorageStatusProvider: { checkedModel, _, _ in
                if checkedModel.id == model.id {
                    await gate.markEnteredAndWait()
                    return .downloaded
                }
                return .missing
            }
        )

        manager.refreshStatuses()
        await gate.waitUntilEntered()

        await manager.remove(model)
        XCTAssertEqual(manager.state(for: model), .notDownloaded)

        await gate.release()
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(manager.state(for: model), .notDownloaded)
    }

    @MainActor
    func testNewerRefreshInvalidatesOlderStatusResult() async throws {
        let cacheRoot = try makeTemporaryDirectory()
        let checkpointsPath = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: cacheRoot)
            try? FileManager.default.removeItem(at: checkpointsPath)
        }

        let model = try XCTUnwrap(DownloadableModel.embedded.first)
        let probe = SequencedStatusProbe(statuses: [.downloaded, .missing])
        let manager = ModelDownloadManager(
            refreshStatusesOnInit: false,
            checkpointsPathOverride: checkpointsPath,
            huggingFaceCacheRootOverride: cacheRoot,
            modelStorageStatusProvider: { checkedModel, _, _ in
                if checkedModel.id == model.id {
                    return await probe.nextStatus()
                }
                return .missing
            }
        )

        manager.refreshStatuses()
        await probe.waitForCall(1)

        manager.refreshStatuses()
        await probe.waitForCall(2)

        await probe.releaseCall(1)
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(manager.state(for: model), .notDownloaded)

        await probe.releaseCall(2)
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(manager.state(for: model), .notDownloaded)
    }

    @MainActor
    func testRemoveDoesNotDeleteFilesWhileDownloadIsStillStopping() async throws {
        let cacheRoot = try makeTemporaryDirectory()
        let checkpointsPath = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: cacheRoot)
            try? FileManager.default.removeItem(at: checkpointsPath)
        }

        let controller = SequencedNativeDownloadController()
        let manager = ModelDownloadManager(
            refreshStatusesOnInit: false,
            checkpointsPathOverride: checkpointsPath,
            huggingFaceCacheRootOverride: cacheRoot,
            nativeDownloader: SequencedNativeDownloader(controller: controller),
            modelStorageStatusProvider: { _, _, _ in .missing }
        )
        let model = DownloadableModel(
            id: "org/stale-native-download",
            name: "Stale Native Download",
            subtitle: "Test model",
            modelId: "org/stale-native-download",
            modality: .vision,
            downloadSizeGB: 1.0,
            source: ModelSource(type: .huggingFaceSnapshot, repo: "org/stale-native-download", revision: "main")
        )
        let modelCachePath = RuntimeManager.modelCachePath(
            modelId: "org/stale-native-download",
            huggingFaceCacheRoot: cacheRoot
        )
        try FileManager.default.createDirectory(at: modelCachePath, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: modelCachePath.appendingPathComponent("model.safetensors"))
        let originalKillDelay = ModelDownloadManager.terminationKillFallbackDelay
        let originalCleanupDelay = ModelDownloadManager.terminationCleanupDelay
        let originalWaitPadding = ModelDownloadManager.terminationWaitPadding
        ModelDownloadManager.terminationKillFallbackDelay = 0
        ModelDownloadManager.terminationCleanupDelay = 0
        ModelDownloadManager.terminationWaitPadding = 0
        defer {
            ModelDownloadManager.terminationKillFallbackDelay = originalKillDelay
            ModelDownloadManager.terminationCleanupDelay = originalCleanupDelay
            ModelDownloadManager.terminationWaitPadding = originalWaitPadding
        }

        manager.download(model)
        await controller.waitForCall(1)

        await manager.remove(model)
        XCTAssertEqual(
            manager.state(for: model).failureMessage,
            ModelDownloadError.removalStillStopping.localizedDescription
        )
        XCTAssertTrue(manager.hasTrackedTask(for: model))
        XCTAssertTrue(FileManager.default.fileExists(atPath: modelCachePath.path))

        await controller.releaseCall(1, outcome: .cancellation)
        await waitUntil { !manager.hasTrackedTask(for: model) }
        XCTAssertEqual(manager.state(for: model), .notDownloaded)

        await manager.remove(model)
        XCTAssertFalse(FileManager.default.fileExists(atPath: modelCachePath.path))
    }

    @MainActor
    func testRepeatedRemoveDoesNotDeleteFilesWhileDownloadIsStillStopping() async throws {
        let cacheRoot = try makeTemporaryDirectory()
        let checkpointsPath = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: cacheRoot)
            try? FileManager.default.removeItem(at: checkpointsPath)
        }

        let controller = SequencedNativeDownloadController()
        let manager = ModelDownloadManager(
            refreshStatusesOnInit: false,
            checkpointsPathOverride: checkpointsPath,
            huggingFaceCacheRootOverride: cacheRoot,
            nativeDownloader: SequencedNativeDownloader(controller: controller),
            modelStorageStatusProvider: { _, _, _ in .missing }
        )
        let model = DownloadableModel(
            id: "org/repeated-remove-stopping",
            name: "Repeated Remove",
            subtitle: "Test model",
            modelId: "org/repeated-remove-stopping",
            modality: .vision,
            downloadSizeGB: 1.0,
            source: ModelSource(type: .huggingFaceSnapshot, repo: "org/repeated-remove-stopping", revision: "main")
        )
        let modelCachePath = RuntimeManager.modelCachePath(
            modelId: "org/repeated-remove-stopping",
            huggingFaceCacheRoot: cacheRoot
        )
        try FileManager.default.createDirectory(at: modelCachePath, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: modelCachePath.appendingPathComponent("model.safetensors"))
        let originalKillDelay = ModelDownloadManager.terminationKillFallbackDelay
        let originalCleanupDelay = ModelDownloadManager.terminationCleanupDelay
        let originalWaitPadding = ModelDownloadManager.terminationWaitPadding
        ModelDownloadManager.terminationKillFallbackDelay = 0
        ModelDownloadManager.terminationCleanupDelay = 0
        ModelDownloadManager.terminationWaitPadding = 0
        defer {
            ModelDownloadManager.terminationKillFallbackDelay = originalKillDelay
            ModelDownloadManager.terminationCleanupDelay = originalCleanupDelay
            ModelDownloadManager.terminationWaitPadding = originalWaitPadding
        }

        manager.download(model)
        await controller.waitForCall(1)

        await manager.remove(model)
        XCTAssertEqual(
            manager.state(for: model).failureMessage,
            ModelDownloadError.removalStillStopping.localizedDescription
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: modelCachePath.path))

        await manager.remove(model)
        XCTAssertEqual(
            manager.state(for: model).failureMessage,
            ModelDownloadError.removalStillStopping.localizedDescription
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: modelCachePath.path))

        await controller.releaseCall(1, outcome: .cancellation)
        await waitUntil { !manager.hasTrackedTask(for: model) }

        await manager.remove(model)
        XCTAssertFalse(FileManager.default.fileExists(atPath: modelCachePath.path))
    }

    @MainActor
    func testCancelledDownloadSuccessAfterRemoveDoesNotRestoreDownloadedState() async throws {
        let cacheRoot = try makeTemporaryDirectory()
        let checkpointsPath = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: cacheRoot)
            try? FileManager.default.removeItem(at: checkpointsPath)
        }

        let controller = SequencedNativeDownloadController()
        let manager = ModelDownloadManager(
            refreshStatusesOnInit: false,
            checkpointsPathOverride: checkpointsPath,
            huggingFaceCacheRootOverride: cacheRoot,
            nativeDownloader: SequencedNativeDownloader(controller: controller),
            modelStorageStatusProvider: { _, _, _ in .downloaded }
        )
        let model = DownloadableModel(
            id: "org/cancelled-success",
            name: "Cancelled Success",
            subtitle: "Test model",
            modelId: "org/cancelled-success",
            modality: .vision,
            downloadSizeGB: 1.0,
            source: ModelSource(type: .huggingFaceSnapshot, repo: "org/cancelled-success", revision: "main")
        )
        let originalKillDelay = ModelDownloadManager.terminationKillFallbackDelay
        let originalCleanupDelay = ModelDownloadManager.terminationCleanupDelay
        let originalWaitPadding = ModelDownloadManager.terminationWaitPadding
        ModelDownloadManager.terminationKillFallbackDelay = 0
        ModelDownloadManager.terminationCleanupDelay = 0
        ModelDownloadManager.terminationWaitPadding = 0
        defer {
            ModelDownloadManager.terminationKillFallbackDelay = originalKillDelay
            ModelDownloadManager.terminationCleanupDelay = originalCleanupDelay
            ModelDownloadManager.terminationWaitPadding = originalWaitPadding
        }

        manager.download(model)
        await controller.waitForCall(1)

        await manager.remove(model)
        XCTAssertEqual(
            manager.state(for: model).failureMessage,
            ModelDownloadError.removalStillStopping.localizedDescription
        )

        await controller.releaseCall(1, outcome: .success)
        await waitUntil { !manager.hasTrackedTask(for: model) }

        XCTAssertEqual(manager.state(for: model), .notDownloaded)
    }

    @MainActor
    func testDownloadIncludesAccelerationSnapshot() async throws {
        let cacheRoot = try makeTemporaryDirectory()
        let checkpointsPath = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: cacheRoot)
            try? FileManager.default.removeItem(at: checkpointsPath)
        }

        let controller = SequencedNativeDownloadController()
        let manager = ModelDownloadManager(
            refreshStatusesOnInit: false,
            checkpointsPathOverride: checkpointsPath,
            huggingFaceCacheRootOverride: cacheRoot,
            nativeDownloader: SequencedNativeDownloader(controller: controller),
            modelStorageStatusProvider: { _, _, _ in .downloaded }
        )
        let model = DownloadableModel(
            id: "org/accelerated-model",
            name: "Accelerated Model",
            subtitle: "Test model",
            modelId: "org/accelerated-model",
            modality: .vision,
            downloadSizeGB: 1.0,
            source: ModelSource(type: .huggingFaceSnapshot, repo: "org/accelerated-model", revision: "main"),
            acceleration: ModelAcceleration(modelId: "org/accelerated-drafter", downloadSizeGB: 0.25)
        )

        manager.download(model)
        await controller.waitForCall(1)
        await controller.releaseCall(1, outcome: .success)
        await controller.waitForCall(2)
        await controller.releaseCall(2, outcome: .success)
        await waitUntil { !manager.hasTrackedTask(for: model) }

        let repoIDs = await controller.repoIDs
        XCTAssertEqual(repoIDs, ["org/accelerated-model", "org/accelerated-drafter"])
        XCTAssertEqual(manager.state(for: model), .downloaded)
    }

    @MainActor
    func testDownloadSkipsExistingBaseSnapshotWhenOnlyAccelerationIsMissing() async throws {
        let cacheRoot = try makeTemporaryDirectory()
        let checkpointsPath = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: cacheRoot)
            try? FileManager.default.removeItem(at: checkpointsPath)
        }
        try makeCompletedHuggingFaceSnapshot(
            modelId: "org/accelerated-model",
            cacheRoot: cacheRoot
        )

        let controller = SequencedNativeDownloadController()
        let manager = ModelDownloadManager(
            refreshStatusesOnInit: false,
            checkpointsPathOverride: checkpointsPath,
            huggingFaceCacheRootOverride: cacheRoot,
            nativeDownloader: SequencedNativeDownloader(controller: controller),
            modelStorageStatusProvider: { _, _, _ in .downloaded }
        )
        let model = DownloadableModel(
            id: "org/accelerated-model",
            name: "Accelerated Model",
            subtitle: "Test model",
            modelId: "org/accelerated-model",
            modality: .vision,
            downloadSizeGB: 1.0,
            source: ModelSource(type: .huggingFaceSnapshot, repo: "org/accelerated-model", revision: "main"),
            acceleration: ModelAcceleration(modelId: "org/accelerated-drafter", downloadSizeGB: 0.25)
        )

        manager.download(model)
        await controller.waitForCall(1)
        await controller.releaseCall(1, outcome: .success)
        await waitUntil { !manager.hasTrackedTask(for: model) }

        let repoIDs = await controller.repoIDs
        XCTAssertEqual(repoIDs, ["org/accelerated-drafter"])
        XCTAssertEqual(manager.state(for: model), .downloaded)
    }

    @MainActor
    func testRefreshStatusesDoesNotRestoreStatusWhileCancelledDownloadIsStopping() async throws {
        let cacheRoot = try makeTemporaryDirectory()
        let checkpointsPath = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: cacheRoot)
            try? FileManager.default.removeItem(at: checkpointsPath)
        }

        let model = try XCTUnwrap(DownloadableModel.embedded.first)
        let controller = SequencedNativeDownloadController()
        let manager = ModelDownloadManager(
            refreshStatusesOnInit: false,
            checkpointsPathOverride: checkpointsPath,
            huggingFaceCacheRootOverride: cacheRoot,
            nativeDownloader: SequencedNativeDownloader(controller: controller),
            modelStorageStatusProvider: { checkedModel, _, _ in
                checkedModel.id == model.id ? .downloaded : .missing
            }
        )

        manager.download(model)
        await controller.waitForCall(1)

        manager.cancel(model)
        XCTAssertEqual(manager.state(for: model), .notDownloaded)
        XCTAssertTrue(manager.hasTrackedTask(for: model))

        manager.refreshStatuses()
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(manager.state(for: model), .notDownloaded)

        await controller.releaseCall(1, outcome: .cancellation)
        await waitUntil { !manager.hasTrackedTask(for: model) }
        XCTAssertEqual(manager.state(for: model), .notDownloaded)
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

        try ModelDownloadStorage.removeLocalFiles(
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

        try ModelDownloadStorage.removeLocalFiles(
            for: model,
            checkpointsPath: checkpointsPath,
            huggingFaceCacheRoot: cacheRoot
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: componentA.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: componentB.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testCancelCleanupRemovesNativeInProgressMarkersFromSnapshotCache() async throws {
        let cacheRoot = try makeTemporaryDirectory()
        let checkpointsPath = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: cacheRoot)
            try? FileManager.default.removeItem(at: checkpointsPath)
        }

        let model = DownloadableModel(
            id: "org/cancelled-model",
            name: "Cancelled Model",
            subtitle: "Test model",
            modelId: "org/cancelled-model",
            modality: .vision,
            downloadSizeGB: 1.0,
            source: ModelSource(type: .huggingFaceSnapshot, repo: "org/cancelled-model", revision: "main")
        )
        let snapshotRoot = RuntimeManager.modelCachePath(
            modelId: "org/cancelled-model",
            huggingFaceCacheRoot: cacheRoot
        )
        .appendingPathComponent("snapshots")
        .appendingPathComponent("revision")
        try FileManager.default.createDirectory(at: snapshotRoot, withIntermediateDirectories: true)
        let markerURL = snapshotRoot.appendingPathComponent(NativeSnapshotCompletionManifest.inProgressFilename)
        let partialURL = snapshotRoot.appendingPathComponent(".model.safetensors.download")
        try Data("in-progress".utf8).write(to: markerURL)
        try Data([1, 2]).write(to: partialURL)

        await ModelDownloadStorage.cleanupPartialDownloads(
            for: model,
            checkpointsPath: checkpointsPath,
            huggingFaceCacheRoot: cacheRoot,
            nativeDownloader: NativeModelDownloadService()
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partialURL.path))
    }

    func testAceStepDownloadHelperUsageErrorUsesTypedEvent() throws {
        let helperPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("MLXtra/Resources/runtime/music-macos-arm64/acestep_download_helper.py")

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
            ModelDownloadError.removalStillStopping.errorDescription,
            "Model removal is still waiting for the active download to stop. Try again in a moment."
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

    private enum HelperExecutorTestError: Error {
        case failed
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

    private func makeCompletedHuggingFaceSnapshot(
        modelId: String,
        revision: String = "main",
        resolvedRevision: String = "test-revision",
        cacheRoot: URL
    ) throws {
        let modelCachePath = RuntimeManager.modelCachePath(
            modelId: modelId,
            huggingFaceCacheRoot: cacheRoot
        )
        let snapshotPath = modelCachePath
            .appendingPathComponent("snapshots")
            .appendingPathComponent(resolvedRevision)
        let refsPath = modelCachePath.appendingPathComponent("refs")

        try FileManager.default.createDirectory(at: snapshotPath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: refsPath, withIntermediateDirectories: true)
        try Data(resolvedRevision.utf8).write(to: refsPath.appendingPathComponent(revision))
        try Data("{}".utf8).write(to: snapshotPath.appendingPathComponent("config.json"))
        try Data([1]).write(to: snapshotPath.appendingPathComponent("model.safetensors"))
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

private actor AsyncTestGate {
    private var didEnter = false
    private var didRelease = false
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func markEnteredAndWait() async {
        didEnter = true
        enteredContinuation?.resume()
        enteredContinuation = nil

        guard !didRelease else { return }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilEntered() async {
        guard !didEnter else { return }
        await withCheckedContinuation { continuation in
            enteredContinuation = continuation
        }
    }

    func release() {
        didRelease = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor SequencedStatusProbe {
    private let statuses: [RuntimeManager.ModelStorageStatus]
    private var callCount = 0
    private var releasedCalls: Set<Int> = []
    private var waitContinuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var releaseContinuations: [Int: CheckedContinuation<Void, Never>] = [:]

    init(statuses: [RuntimeManager.ModelStorageStatus]) {
        self.statuses = statuses
    }

    func nextStatus() async -> RuntimeManager.ModelStorageStatus {
        callCount += 1
        let callIndex = callCount
        waitContinuations[callIndex]?.resume()
        waitContinuations[callIndex] = nil

        if !releasedCalls.contains(callIndex) {
            await withCheckedContinuation { continuation in
                releaseContinuations[callIndex] = continuation
            }
        }

        return statuses[min(callIndex - 1, statuses.count - 1)]
    }

    func waitForCall(_ callIndex: Int) async {
        guard callCount < callIndex else { return }
        await withCheckedContinuation { continuation in
            waitContinuations[callIndex] = continuation
        }
    }

    func releaseCall(_ callIndex: Int) {
        releasedCalls.insert(callIndex)
        releaseContinuations[callIndex]?.resume()
        releaseContinuations[callIndex] = nil
    }
}

private final class SequencedNativeDownloader: NativeModelDownloading, @unchecked Sendable {
    private let controller: SequencedNativeDownloadController

    init(controller: SequencedNativeDownloadController) {
        self.controller = controller
    }

    func downloadHuggingFaceSnapshot(
        repoID: String,
        revision: String,
        cacheRoot: URL,
        progress: @escaping NativeModelDownloadService.ProgressHandler
    ) async throws {
        await controller.recordRepoID(repoID)
        let callIndex = await controller.enterCall()
        await progress(
            NativeModelDownloadProgress(
                status: "Downloading",
                description: "download \(callIndex)",
                downloadedBytes: nil,
                totalBytes: nil,
                percent: Double(callIndex)
            )
        )
        try await controller.waitForRelease(callIndex)
    }

    func downloadAceStepMainSnapshot(
        plan: AceStepDownloadPlan,
        progress: @escaping NativeModelDownloadService.ProgressHandler
    ) async throws {
        throw SequencedNativeDownloadError.unexpectedAceStepDownload
    }

    func downloadComponentBundle(
        plan: ComponentBundleDownloadPlan,
        progress: @escaping NativeModelDownloadService.ProgressHandler
    ) async throws {
        throw SequencedNativeDownloadError.unexpectedAceStepDownload
    }

    func markAceStepContractComplete(plan: AceStepDownloadPlan) throws {}

    func removePartialDownloads(at root: URL) throws {}
}

private enum SequencedNativeDownloadOutcome {
    case staleFailure
    case cancellation
    case success
}

private enum SequencedNativeDownloadError: Error {
    case staleFailure
    case unexpectedAceStepDownload
}

private actor SequencedNativeDownloadController {
    private var callCount = 0
    private var callContinuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var releaseOutcomes: [Int: SequencedNativeDownloadOutcome] = [:]
    private var releaseContinuations: [Int: CheckedContinuation<SequencedNativeDownloadOutcome, Never>] = [:]
    private(set) var repoIDs: [String] = []

    func recordRepoID(_ repoID: String) {
        repoIDs.append(repoID)
    }

    func enterCall() -> Int {
        callCount += 1
        let callIndex = callCount
        callContinuations[callIndex]?.resume()
        callContinuations[callIndex] = nil
        return callIndex
    }

    func waitForCall(_ callIndex: Int) async {
        guard callCount < callIndex else { return }
        await withCheckedContinuation { continuation in
            callContinuations[callIndex] = continuation
        }
    }

    func releaseCall(_ callIndex: Int, outcome: SequencedNativeDownloadOutcome) {
        releaseOutcomes[callIndex] = outcome
        releaseContinuations[callIndex]?.resume(returning: outcome)
        releaseContinuations[callIndex] = nil
    }

    func waitForRelease(_ callIndex: Int) async throws {
        let outcome: SequencedNativeDownloadOutcome
        if let releasedOutcome = releaseOutcomes[callIndex] {
            outcome = releasedOutcome
        } else {
            outcome = await withCheckedContinuation { continuation in
                releaseContinuations[callIndex] = continuation
            }
        }

        switch outcome {
        case .staleFailure:
            throw SequencedNativeDownloadError.staleFailure
        case .cancellation:
            throw CancellationError()
        case .success:
            return
        }
    }
}
