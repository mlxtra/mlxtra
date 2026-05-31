import Foundation
@MainActor
final class ModelDownloadManager: ObservableObject {
    static let shared = ModelDownloadManager()
#if DEBUG
    static var terminationKillFallbackDelay: TimeInterval = 3.0
    static var terminationCleanupDelay: TimeInterval = 3.2
#else
    private static let terminationKillFallbackDelay: TimeInterval = 3.0
    private static let terminationCleanupDelay: TimeInterval = 3.2
#endif

    @Published private(set) var states: [String: DownloadState] = [:]

    private let runtimeManager = RuntimeManager()
    private let nativeDownloader: NativeModelDownloadService
    private let checkpointsPathOverride: URL?
    private let huggingFaceCacheRootOverride: URL?
    private let lifecycle = ModelDownloadLifecycle()
    private var lastProgress: [String: DownloadProgress] = [:]
    private let errorTracker = DownloadErrorTracker()
#if DEBUG
    private let usesUITestDownloadStates: Bool
#endif

    init(
        refreshStatusesOnInit: Bool = true,
        checkpointsPathOverride: URL? = nil,
        huggingFaceCacheRootOverride: URL? = nil,
        nativeDownloader: NativeModelDownloadService = NativeModelDownloadService()
    ) {
        self.checkpointsPathOverride = checkpointsPathOverride
        self.huggingFaceCacheRootOverride = huggingFaceCacheRootOverride
        self.nativeDownloader = nativeDownloader
#if DEBUG
        usesUITestDownloadStates = ProcessInfo.processInfo.environment["MLXTRA_UI_TEST_DOWNLOAD_STATES"] == "1"
        if usesUITestDownloadStates {
            installUITestDownloadStates()
            return
        }
#endif
        if refreshStatusesOnInit {
            refreshStatuses()
        }
    }

    private var checkpointsPath: URL {
        checkpointsPathOverride ?? runtimeManager.checkpointsPath
    }

    private var huggingFaceCacheRoot: URL {
        huggingFaceCacheRootOverride ?? RuntimeManager.huggingFaceCacheRoot()
    }

    func refreshStatuses() {
#if DEBUG
        guard !usesUITestDownloadStates else { return }
#endif
        let modelsToCheck = DownloadableModel.embedded.compactMap { model -> DownloadableModel? in
            guard states[model.id]?.isDownloading != true,
                  states[model.id]?.isPaused != true else {
                return nil
            }
            return model
        }
        let checkpointsPath = self.checkpointsPath
        let huggingFaceCacheRoot = self.huggingFaceCacheRoot

        Task { [modelsToCheck, checkpointsPath, huggingFaceCacheRoot] in
            let results = await Task.detached(priority: .utility) {
                modelsToCheck.map { model in
                    (
                        model.id,
                        RuntimeManager.modelStorageStatus(
                            model: model,
                            checkpointsPath: checkpointsPath,
                            huggingFaceCacheRoot: huggingFaceCacheRoot
                        )
                    )
                }
            }.value

            for (modelId, status) in results
                where states[modelId]?.isDownloading != true && states[modelId]?.isPaused != true {
                states[modelId] = Self.downloadState(for: status)
            }
        }
    }

#if DEBUG
    private func installUITestDownloadStates() {
        let models = DownloadableModel.embedded
        let halfProgress = DownloadProgress(
            status: "Downloading",
            description: "UI test fixture",
            unit: "B",
            progressKind: "bytes",
            downloadedBytes: 512,
            totalBytes: 1024,
            percent: 50
        )
        let pausedProgress = DownloadProgress(
            status: "Paused",
            description: "UI test fixture",
            unit: "B",
            progressKind: "bytes",
            downloadedBytes: 256,
            totalBytes: 1024,
            percent: 25
        )

        let fixtures: [DownloadState] = [
            .downloaded,
            .notDownloaded,
            .downloading(halfProgress),
            .paused(pausedProgress),
            .failed("Incomplete cache: missing files. Redownload to repair."),
            .failed("Network unavailable.")
        ]

        for (model, state) in zip(models, fixtures) {
            states[model.id] = state
        }
    }
#endif

    func state(for model: DownloadableModel) -> DownloadState {
        states[model.id] ?? .notDownloaded
    }

    func cachePath(for model: DownloadableModel) -> String {
        ModelDownloadStorage.storageURLs(
            for: model,
            checkpointsPath: checkpointsPath,
            huggingFaceCacheRoot: huggingFaceCacheRoot
        )
        .first?
        .path ?? runtimeManager.modelStoragePath(for: model).path
    }

    func download(_ model: DownloadableModel) {
#if DEBUG
        guard !usesUITestDownloadStates else { return }
#endif
        guard !lifecycle.hasTask(for: model.id) else { return }

        errorTracker.clearErrorReceived(for: model.id)
        lifecycle.clearStopReason(for: model.id)
        let initialProgress: DownloadProgress?
        if states[model.id]?.isPaused == true {
            initialProgress = states[model.id]?.progress ?? lastProgress[model.id]
        } else {
            lastProgress[model.id] = nil
            initialProgress = nil
        }
        states[model.id] = .downloading(initialProgress)
        let task = Task { [weak self] in
            guard let self else { return }

            do {
                try await runtimeManager.validateDownloadSupportOffMain(for: model)
                if model.source.helper == .aceStep {
                    try await runAceStepDownload(model: model)
                } else if model.source.usesComponentBundle {
                    throw NativeModelDownloadError.unsupportedComponentBundle(model.name)
                } else {
                    try await runSnapshotDownload(model: model)
                }
                let storageStatus = await modelStorageStatusOffMain(model: model)
                states[model.id] = Self.downloadStateAfterDownload(for: storageStatus)
                if storageStatus.isDownloaded {
                    lastProgress[model.id] = nil
                }
            } catch {
                if let stopReason = lifecycle.stopReason(for: model.id) {
                    switch stopReason {
                    case .pause:
                        states[model.id] = .paused(lastProgress[model.id])
                    case .cancel:
                        await cleanupNativePartialDownloads(for: model)
                        lastProgress[model.id] = nil
                        states[model.id] = .notDownloaded
                    }
                } else if !errorTracker.errorWasReceived(for: model.id) {
                    states[model.id] = .failed(error.localizedDescription)
                }
            }

            lifecycle.clearCompletionTracking(for: model.id)
        }
        lifecycle.setTask(task, for: model.id)
    }

    func pause(_ model: DownloadableModel) {
#if DEBUG
        guard !usesUITestDownloadStates else { return }
#endif
        stop(model, reason: .pause)
    }

    func resume(_ model: DownloadableModel) {
#if DEBUG
        guard !usesUITestDownloadStates else { return }
#endif
        download(model)
    }

    func cancel(_ model: DownloadableModel) {
#if DEBUG
        guard !usesUITestDownloadStates else { return }
#endif
        stop(model, reason: .cancel)
    }

    func remove(_ model: DownloadableModel) async {
#if DEBUG
        guard !usesUITestDownloadStates else {
            states[model.id] = .notDownloaded
            return
        }
#endif
        if states[model.id]?.isDownloading == true || states[model.id]?.isPaused == true {
            cancel(model)
        }

        let checkpointsPath = self.checkpointsPath
        let huggingFaceCacheRoot = self.huggingFaceCacheRoot
        do {
            try await Task.detached(priority: .utility) {
                try ModelDownloadStorage.removeLocalFiles(
                    for: model,
                    checkpointsPath: checkpointsPath,
                    huggingFaceCacheRoot: huggingFaceCacheRoot
                )
            }.value
            lastProgress[model.id] = nil
            states[model.id] = .notDownloaded
        } catch {
            states[model.id] = .failed(error.localizedDescription)
        }
    }

    private func stop(_ model: DownloadableModel, reason: DownloadStopReason) {
        guard lifecycle.hasTask(for: model.id) else {
            if reason == .cancel {
                lastProgress[model.id] = nil
                states[model.id] = .notDownloaded
            }
            return
        }

        lifecycle.setStopReason(reason, for: model.id)
        switch reason {
        case .pause:
            states[model.id] = .paused(states[model.id]?.progress ?? lastProgress[model.id])
        case .cancel:
            lastProgress[model.id] = nil
            states[model.id] = .notDownloaded
        }

        lifecycle.cancelTrackedWork(
            for: model.id,
            killFallbackDelay: Self.terminationKillFallbackDelay,
            cleanupDelay: Self.terminationCleanupDelay
        )
    }

#if DEBUG
    func installTestDownloadProcess(_ process: Process, for model: DownloadableModel) {
        states[model.id] = .downloading(nil)
        lifecycle.installTestProcess(
            process,
            modelId: model.id,
            cleanupDelay: Self.terminationCleanupDelay
        )
    }

    func hasTrackedProcess(for model: DownloadableModel) -> Bool {
        lifecycle.hasTrackedProcess(for: model.id)
    }

    func hasTrackedTask(for model: DownloadableModel) -> Bool {
        lifecycle.hasTrackedTask(for: model.id)
    }
#endif

    private func modelStorageStatusOffMain(modelId: String) async -> RuntimeManager.ModelStorageStatus {
        await ModelDownloadStorage.status(
            for: modelId,
            checkpointsPath: checkpointsPath,
            huggingFaceCacheRoot: huggingFaceCacheRoot
        )
    }

    private func modelStorageStatusOffMain(model: DownloadableModel) async -> RuntimeManager.ModelStorageStatus {
        await ModelDownloadStorage.status(
            for: model,
            checkpointsPath: checkpointsPath,
            huggingFaceCacheRoot: huggingFaceCacheRoot
        )
    }

    private func runAceStepDownload(model: DownloadableModel) async throws {
        let modelId = model.id
        let repoID = model.source.downloadRepository ?? model.modelId
        guard !model.source.components.isEmpty else {
            throw NativeModelDownloadError.emptyManifest(repoID)
        }
        let plan = AceStepDownloadPlan(
            repoID: repoID,
            revision: model.source.revision ?? "main",
            requiredComponents: model.source.components,
            checkpointsRoot: checkpointsPath
        )

        try await nativeDownloader.downloadAceStepMainSnapshot(plan: plan) { [weak self] progress in
            await self?.handleNativeDownloadProgress(progress, modelId: modelId)
        }
        try Task.checkCancellation()
        try await runAceStepContractValidation(model: model, plan: plan)
        try nativeDownloader.markAceStepContractComplete(plan: plan)
    }

    private func cleanupNativePartialDownloads(for model: DownloadableModel) async {
        await ModelDownloadStorage.cleanupPartialDownloads(
            for: model,
            checkpointsPath: checkpointsPath,
            huggingFaceCacheRoot: huggingFaceCacheRoot,
            nativeDownloader: nativeDownloader
        )
    }

    private func runAceStepContractValidation(model: DownloadableModel, plan: AceStepDownloadPlan) async throws {
        let helperPath = runtimeManager.acestepDownloadHelperPath()
        let pythonPath = runtimeManager.acestepPythonExecutablePath()
        let localDir = plan.checkpointsRoot.path
        let modelId = model.id

        DownloadDiagnostics.log("[ModelDownloadManager] Running ACE-Step contract validation with Python at \(pythonPath.path)")

        var downloadEnv = bundledPythonEnvironment()
        downloadEnv["ACESTEP_CHECKPOINTS_DIR"] = localDir

        let result = try await runDownloadHelper(
            modelId: modelId,
            executableURL: pythonPath,
            arguments: [helperPath.path, "--contract", localDir],
            environment: downloadEnv
        )

        DownloadDiagnostics.log("[ModelDownloadManager] ACE-Step contract output: \(result.output.prefix(500))")
        if !result.errorOutput.isEmpty {
            DownloadDiagnostics.log("[ModelDownloadManager] ACE-Step contract stderr: \(result.errorOutput.prefix(500))")
        }

        try finishDownloadHelperRun(
            result,
            modelId: modelId,
            failureMessage: result.output.isEmpty ? result.errorOutput : result.output
        )
    }

    private func runSnapshotDownload(model: DownloadableModel) async throws {
        let modelId = model.id
        let repoId = model.source.downloadRepository ?? model.modelId
        let revision = model.source.revision ?? "main"

        try await nativeDownloader.downloadHuggingFaceSnapshot(
            repoID: repoId,
            revision: revision,
            cacheRoot: huggingFaceCacheRoot
        ) { [weak self] progress in
            await self?.handleNativeDownloadProgress(progress, modelId: modelId)
        }
    }

    private func handleNativeDownloadProgress(_ nativeProgress: NativeModelDownloadProgress, modelId: String) {
        guard lifecycle.stopReason(for: modelId) == nil,
              states[modelId]?.isTerminal != true else {
            return
        }

        let progress = DownloadProgress(
            status: nativeProgress.status,
            description: nativeProgress.description,
            unit: nativeProgress.downloadedBytes == nil ? nil : "B",
            progressKind: nativeProgress.downloadedBytes == nil ? nil : "bytes",
            downloadedBytes: nativeProgress.downloadedBytes,
            totalBytes: nativeProgress.totalBytes,
            percent: Self.monotonicPercent(nativeProgress.percent, previous: lastProgress[modelId]?.percent)
        )
        lastProgress[modelId] = progress
        states[modelId] = .downloading(progress)
    }

    private func runDownloadHelper(
        modelId: String,
        executableURL: URL,
        arguments: [String],
        environment: [String: String]
    ) async throws -> DownloadHelperProcessResult {
        do {
            return try await DownloadHelperProcessRunner.run(
                executableURL: executableURL,
                arguments: arguments,
                environment: environment,
                onProcessStarted: { [weak self] process in
                    self?.lifecycle.setProcess(process, for: modelId)
                },
                onOutputLine: { [weak self] line in
                    self?.handleDownloadEventLine(line, modelId: modelId)
                }
            )
        } catch {
            lifecycle.clearProcess(for: modelId)
            throw error
        }
    }

    private func finishDownloadHelperRun(
        _ result: DownloadHelperProcessResult,
        modelId: String,
        failureMessage: String
    ) throws {
        lifecycle.clearProcess(for: modelId)
        handleDownloadEventLines(result.output, modelId: modelId)

        if lifecycle.stopReason(for: modelId) != nil {
            throw ModelDownloadError.stoppedByUser
        }

        guard result.terminationStatus == 0 else {
            throw ModelDownloadError.downloadFailed(failureMessage)
        }
    }

    func handleDownloadEventLines(_ output: String, modelId: String) {
        for line in output.components(separatedBy: .newlines) {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedLine.isEmpty else { continue }
            handleDownloadEventLine(trimmedLine, modelId: modelId)
        }
    }

    func handleDownloadEventLine(_ line: String, modelId: String) {
        guard lifecycle.stopReason(for: modelId) == nil else { return }

        guard let event = Self.parseDownloadEventLine(line) else {
            return
        }

        switch event {
        case .started, .progress, .verified, .complete:
            guard states[modelId]?.isTerminal != true,
                  let progress = Self.downloadProgress(
                    for: event,
                    previousPercent: lastProgress[modelId]?.percent
                  ) else {
                return
            }
            lastProgress[modelId] = progress
            states[modelId] = .downloading(progress)
        case .error(let message):
            guard states[modelId] != .downloaded else { return }
            errorTracker.setErrorReceived(for: modelId)
            states[modelId] = .failed(message)
        }
    }

    private func bundledPythonEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in ["PYTHONPATH", "VIRTUAL_ENV", "CONDA_PREFIX", "CONDA_DEFAULT_ENV", "PYENV_ROOT", "PYENV_VERSION"] {
            environment.removeValue(forKey: key)
        }
        environment["PYTHONHOME"] = runtimeManager.pythonHomePath().path
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["HF_HOME"] = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface").path
        environment["HF_HUB_CACHE"] = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface/hub").path
        return environment
    }
}
