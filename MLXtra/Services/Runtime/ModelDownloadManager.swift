import Foundation
@MainActor
final class ModelDownloadManager: ObservableObject {
    typealias ModelStorageStatusProvider = (
        _ model: DownloadableModel,
        _ checkpointsPath: URL,
        _ huggingFaceCacheRoot: URL
    ) async -> RuntimeManager.ModelStorageStatus

    static let shared = ModelDownloadManager()
#if DEBUG
    static var terminationKillFallbackDelay: TimeInterval = 3.0
    static var terminationCleanupDelay: TimeInterval = 3.2
    static var terminationWaitPadding: TimeInterval = 2.0
#else
    private static let terminationKillFallbackDelay: TimeInterval = 3.0
    private static let terminationCleanupDelay: TimeInterval = 3.2
    private static let terminationWaitPadding: TimeInterval = 2.0
#endif

    @Published private(set) var states: [String: DownloadState] = [:]

    private let runtimeManager: RuntimeManager
    private let nativeDownloader: any NativeModelDownloading
    private let checkpointsPathOverride: URL?
    private let huggingFaceCacheRootOverride: URL?
    private let modelStorageStatusProvider: ModelStorageStatusProvider
    private let lifecycle: ModelDownloadLifecycle
    private let helperExecutor: ModelDownloadHelperExecutor
    private let progressTracker: ModelDownloadProgressTracker
    private let stopCoordinator: ModelDownloadStopCoordinator
    private let failureResolver: ModelDownloadFailureResolver
    private let errorTracker = DownloadErrorTracker()
    private var stateCoordinator = ModelDownloadStateCoordinator()
#if DEBUG
    private let usesUITestDownloadStates: Bool
#endif

    init(
        refreshStatusesOnInit: Bool = true,
        checkpointsPathOverride: URL? = nil,
        huggingFaceCacheRootOverride: URL? = nil,
        nativeDownloader: any NativeModelDownloading = NativeModelDownloadService(),
        modelStorageStatusProvider: @escaping ModelStorageStatusProvider = { model, checkpointsPath, huggingFaceCacheRoot in
            await ModelDownloadStorage.status(
                for: model,
                checkpointsPath: checkpointsPath,
                huggingFaceCacheRoot: huggingFaceCacheRoot
            )
        }
    ) {
        let runtimeManager = RuntimeManager()
        let lifecycle = ModelDownloadLifecycle()
        let progressTracker = ModelDownloadProgressTracker()
        self.runtimeManager = runtimeManager
        self.checkpointsPathOverride = checkpointsPathOverride
        self.huggingFaceCacheRootOverride = huggingFaceCacheRootOverride
        self.nativeDownloader = nativeDownloader
        self.modelStorageStatusProvider = modelStorageStatusProvider
        self.lifecycle = lifecycle
        self.progressTracker = progressTracker
        self.stopCoordinator = ModelDownloadStopCoordinator(
            lifecycle: lifecycle,
            progressTracker: progressTracker
        )
        self.failureResolver = ModelDownloadFailureResolver(
            progressTracker: progressTracker
        )
        self.helperExecutor = ModelDownloadHelperExecutor(
            runtimeManager: runtimeManager,
            lifecycle: lifecycle
        )
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
                  states[model.id]?.isPaused != true,
                  !lifecycle.hasTrackedWork(for: model.id) else {
                return nil
            }
            return model
        }
        let checkpointsPath = self.checkpointsPath
        let huggingFaceCacheRoot = self.huggingFaceCacheRoot
        let capturedVersions = Dictionary(
            uniqueKeysWithValues: modelsToCheck.map {
                ($0.id, stateCoordinator.captureRefreshSnapshot(for: $0.id))
            }
        )
        let modelStorageStatusProvider = self.modelStorageStatusProvider

        Task { [modelsToCheck, checkpointsPath, huggingFaceCacheRoot, capturedVersions, modelStorageStatusProvider] in
            var results: [(String, RuntimeManager.ModelStorageStatus)] = []
            for model in modelsToCheck {
                let status = await modelStorageStatusProvider(model, checkpointsPath, huggingFaceCacheRoot)
                results.append((model.id, status))
            }

            for (modelId, status) in results {
                guard let capturedVersion = capturedVersions[modelId] else { continue }
                applyRefreshedStatus(
                    status,
                    modelId: modelId,
                    capturedVersion: capturedVersion
                )
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
            setState(state, for: model.id)
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
        let downloadToken = beginDownloadOperation(for: model.id)
        let initialProgress = progressTracker.initialProgress(
            for: model.id,
            currentState: states[model.id]
        )
        setState(.downloading(initialProgress), for: model.id)
        let task = Task { [weak self, downloadToken] in
            guard let self else { return }

            do {
                try await runtimeManager.validateDownloadSupportOffMain(for: model)
                if model.source.helper == .aceStep {
                    try await runAceStepDownload(model: model, downloadToken: downloadToken)
                } else if model.source.usesComponentBundle {
                    try await runComponentBundleDownload(model: model, downloadToken: downloadToken)
                } else {
                    try await runSnapshotDownload(model: model, downloadToken: downloadToken)
                }
                try Task.checkCancellation()
                let storageStatus = await modelStorageStatusOffMain(model: model)
                if isActiveDownloadOperation(downloadToken, for: model.id) {
                    setState(Self.downloadStateAfterDownload(for: storageStatus), for: model.id)
                    if storageStatus.isDownloaded {
                        progressTracker.clear(for: model.id)
                    }
                }
            } catch {
                await handleDownloadFailure(
                    error,
                    model: model,
                    downloadToken: downloadToken
                )
            }

            finishDownloadOperation(downloadToken, for: model.id)
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
            setState(.notDownloaded, for: model.id)
            return
        }
#endif
        if stopCoordinator.removalNeedsTrackedWorkToStop(
            for: model.id,
            currentState: states[model.id]
        ) {
            cancel(model)
            let stopped = await stopCoordinator.waitForTrackedWorkToStop(
                for: model.id,
                killFallbackDelay: Self.terminationKillFallbackDelay,
                cleanupDelay: Self.terminationCleanupDelay,
                waitPadding: Self.terminationWaitPadding
            )
            guard stopped else {
                setState(.failed(ModelDownloadError.removalStillStopping.localizedDescription), for: model.id)
                return
            }
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
            progressTracker.clear(for: model.id)
            setState(.notDownloaded, for: model.id)
        } catch {
            setState(.failed(error.localizedDescription), for: model.id)
        }
    }

    private func stop(_ model: DownloadableModel, reason: DownloadStopReason) {
        guard let state = stopCoordinator.stateAfterStopRequest(
            for: model.id,
            reason: reason,
            currentState: states[model.id],
            killFallbackDelay: Self.terminationKillFallbackDelay,
            cleanupDelay: Self.terminationCleanupDelay
        ) else {
            return
        }
        setState(state, for: model.id)
    }

#if DEBUG
    func installTestDownloadProcess(_ process: Process, for model: DownloadableModel) {
        setState(.downloading(nil), for: model.id)
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

    private func modelStorageStatusOffMain(model: DownloadableModel) async -> RuntimeManager.ModelStorageStatus {
        await modelStorageStatusProvider(model, checkpointsPath, huggingFaceCacheRoot)
    }

    private func runAceStepDownload(model: DownloadableModel, downloadToken: UUID) async throws {
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
            await self?.handleNativeDownloadProgress(progress, modelId: modelId, downloadToken: downloadToken)
        }
        try Task.checkCancellation()
        try await helperExecutor.runAceStepContractValidation(
            plan: plan,
            modelId: model.id,
            onOutputLine: { [weak self] line in
                self?.handleDownloadEventLine(line, modelId: model.id, downloadToken: downloadToken)
            }
        )
        try nativeDownloader.markAceStepContractComplete(plan: plan)
    }

    private func runComponentBundleDownload(model: DownloadableModel, downloadToken: UUID) async throws {
        let repoID = model.source.downloadRepository ?? model.modelId
        guard !model.source.components.isEmpty else {
            throw NativeModelDownloadError.emptyManifest(repoID)
        }
        let plan = ComponentBundleDownloadPlan(
            repoID: repoID,
            revision: model.source.revision ?? "main",
            components: model.source.components,
            destinationRoot: model.source.componentStorageRoot(checkpointsPath: checkpointsPath)
        )

        try await nativeDownloader.downloadComponentBundle(plan: plan) { [weak self] progress in
            await self?.handleNativeDownloadProgress(progress, modelId: model.id, downloadToken: downloadToken)
        }
    }

    private func cleanupNativePartialDownloads(for model: DownloadableModel) async {
        await ModelDownloadStorage.cleanupPartialDownloads(
            for: model,
            checkpointsPath: checkpointsPath,
            huggingFaceCacheRoot: huggingFaceCacheRoot,
            nativeDownloader: nativeDownloader
        )
    }

    private func runSnapshotDownload(model: DownloadableModel, downloadToken: UUID) async throws {
        let modelId = model.id
        for requirement in model.snapshotRequirements {
            try Task.checkCancellation()
            if Self.snapshotRequirementIsAlreadyDownloaded(
                requirement,
                huggingFaceCacheRoot: huggingFaceCacheRoot
            ) {
                continue
            }
            try await nativeDownloader.downloadHuggingFaceSnapshot(
                repoID: requirement.modelId,
                revision: requirement.revision,
                cacheRoot: huggingFaceCacheRoot
            ) { [weak self] progress in
                await self?.handleNativeDownloadProgress(progress, modelId: modelId, downloadToken: downloadToken)
            }
        }
    }

    private nonisolated static func snapshotRequirementIsAlreadyDownloaded(
        _ requirement: ModelSnapshotRequirement,
        huggingFaceCacheRoot: URL
    ) -> Bool {
        RuntimeManager.downloadedSnapshotPath(
            modelId: requirement.modelId,
            revision: requirement.revision,
            huggingFaceCacheRoot: huggingFaceCacheRoot
        ) != nil
    }

    private func handleDownloadFailure(
        _ error: Error,
        model: DownloadableModel,
        downloadToken: UUID
    ) async {
        guard isActiveDownloadOperation(downloadToken, for: model.id) else {
            return
        }

        let action = failureResolver.action(
            for: error,
            modelId: model.id,
            stopReason: lifecycle.stopReason(for: model.id),
            currentState: states[model.id],
            helperErrorWasReceived: errorTracker.errorWasReceived(for: model.id)
        )

        switch action {
        case .pause(let progress):
            setState(.paused(progress), for: model.id)
        case .cancel:
            await cleanupNativePartialDownloads(for: model)
            progressTracker.clear(for: model.id)
            setState(.notDownloaded, for: model.id)
        case .fail(let message):
            setState(.failed(message), for: model.id)
        case .suppress:
            break
        }
    }

    private func handleNativeDownloadProgress(
        _ nativeProgress: NativeModelDownloadProgress,
        modelId: String,
        downloadToken: UUID
    ) {
        guard isActiveDownloadOperation(downloadToken, for: modelId) else { return }
        guard lifecycle.stopReason(for: modelId) == nil,
              states[modelId]?.isTerminal != true else {
            return
        }

        let progress = progressTracker.recordNativeProgress(
            nativeProgress,
            modelId: modelId
        )
        setState(.downloading(progress), for: modelId)
    }

    func handleDownloadEventLine(_ line: String, modelId: String, downloadToken: UUID? = nil) {
        if let downloadToken {
            guard isActiveDownloadOperation(downloadToken, for: modelId) else { return }
        }
        guard lifecycle.stopReason(for: modelId) == nil else { return }

        guard let event = ModelDownloadEventParser.parseDownloadEventLine(line) else {
            return
        }

        switch event {
        case .started, .progress, .verified, .complete:
            guard states[modelId]?.isTerminal != true,
                  let progress = progressTracker.recordEventProgress(
                    event,
                    modelId: modelId
                  ) else {
                return
            }
            setState(.downloading(progress), for: modelId)
        case .error(let message):
            guard states[modelId] != .downloaded else { return }
            errorTracker.setErrorReceived(for: modelId)
            setState(.failed(message), for: modelId)
        }
    }

    private func setState(_ state: DownloadState, for modelId: String) {
        stateCoordinator.recordStateChange(for: modelId)
        states[modelId] = state
    }

    private func beginDownloadOperation(for modelId: String) -> UUID {
        stateCoordinator.beginDownload(for: modelId)
    }

    private func isActiveDownloadOperation(_ token: UUID, for modelId: String) -> Bool {
        stateCoordinator.isActiveDownload(token, for: modelId)
    }

    private func finishDownloadOperation(_ token: UUID, for modelId: String) {
        guard stateCoordinator.finishDownload(token, for: modelId) else { return }
        lifecycle.clearCompletionTracking(for: modelId)
    }

    private func applyRefreshedStatus(
        _ status: RuntimeManager.ModelStorageStatus,
        modelId: String,
        capturedVersion: ModelDownloadStateCoordinator.RefreshSnapshot
    ) {
        guard !lifecycle.hasTrackedWork(for: modelId) else {
            return
        }
        guard stateCoordinator.canApplyRefresh(
            capturedVersion,
            for: modelId,
            currentState: states[modelId]
        ) else {
            return
        }
        setState(Self.downloadState(for: status), for: modelId)
    }

}
