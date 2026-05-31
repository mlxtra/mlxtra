import Darwin
import Foundation

@MainActor
final class ModelDownloadLifecycle {
    private var tasks: [String: Task<Void, Never>] = [:]
    private var processes: [String: Process] = [:]
    private var cleanupTasks: [String: Task<Void, Never>] = [:]
    private var cleanupTaskTokens: [String: UUID] = [:]
    private var stopReasons: [String: DownloadStopReason] = [:]

    func hasTask(for modelId: String) -> Bool {
        tasks[modelId] != nil
    }

    func taskIsCancelled(for modelId: String) -> Bool {
        tasks[modelId]?.isCancelled == true
    }

    func setTask(_ task: Task<Void, Never>, for modelId: String) {
        tasks[modelId] = task
    }

    func cancelTask(for modelId: String) {
        tasks[modelId]?.cancel()
    }

    func waitForTrackedWorkToStop(for modelId: String, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if trackedWorkIsStopped(for: modelId) { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        return trackedWorkIsStopped(for: modelId)
    }

    func clearTask(for modelId: String) {
        tasks[modelId] = nil
    }

    func setProcess(_ process: Process, for modelId: String) {
        cancelProcessCleanup(for: modelId)
        processes[modelId] = process
    }

    func clearProcess(for modelId: String) {
        cancelProcessCleanup(for: modelId)
        processes[modelId] = nil
    }

    func clearProcessIfFinished(_ process: Process?, for modelId: String) {
        guard let process,
              processes[modelId] === process,
              !process.isRunning else {
            return
        }
        cancelProcessCleanup(for: modelId)
        processes[modelId] = nil
    }

    private func clearFinishedProcess(for modelId: String) {
        guard let process = processes[modelId], !process.isRunning else {
            return
        }
        cancelProcessCleanup(for: modelId)
        processes[modelId] = nil
    }

    private func trackedWorkIsStopped(for modelId: String) -> Bool {
        clearFinishedProcess(for: modelId)
        return tasks[modelId] == nil
            && processes[modelId] == nil
            && cleanupTasks[modelId] == nil
    }

    func hasTrackedWork(for modelId: String) -> Bool {
        !trackedWorkIsStopped(for: modelId)
    }

    func setStopReason(_ reason: DownloadStopReason, for modelId: String) {
        stopReasons[modelId] = reason
    }

    func clearStopReason(for modelId: String) {
        stopReasons[modelId] = nil
    }

    func stopReason(for modelId: String) -> DownloadStopReason? {
        stopReasons[modelId]
    }

    func clearCompletionTracking(for modelId: String) {
        cancelProcessCleanup(for: modelId)
        tasks[modelId] = nil
        processes[modelId] = nil
        stopReasons[modelId] = nil
    }

    func cancelTrackedWork(
        for modelId: String,
        killFallbackDelay: TimeInterval,
        cleanupDelay: TimeInterval
    ) {
        guard let process = processes[modelId] else {
            cancelTask(for: modelId)
            return
        }

        if process.isRunning {
            cancelTask(for: modelId)
            terminate(process, killFallbackDelay: killFallbackDelay)
            scheduleProcessTrackingCleanup(
                process,
                modelId: modelId,
                killFallbackDelay: killFallbackDelay,
                cleanupDelay: cleanupDelay
            )
        }

        if !process.isRunning {
            cancelTask(for: modelId)
            clearCompletionTracking(for: modelId)
        }
    }

    func installTestProcess(
        _ process: Process,
        modelId: String,
        cleanupDelay: TimeInterval
    ) {
        cancelProcessCleanup(for: modelId)
        processes[modelId] = process
        let cleanupNanoseconds = UInt64(cleanupDelay * 1_000_000_000)
        tasks[modelId] = Task { [weak self, weak process] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            try? await Task.sleep(nanoseconds: cleanupNanoseconds)
            guard let self else { return }
            if self.taskIsCancelled(for: modelId) {
                self.clearTask(for: modelId)
            }
            self.clearProcessIfFinished(process, for: modelId)
            self.clearStopReason(for: modelId)
        }
    }

    func hasTrackedProcess(for modelId: String) -> Bool {
        processes[modelId] != nil
    }

    func hasTrackedTask(for modelId: String) -> Bool {
        tasks[modelId] != nil
    }

    func hasTrackedCleanupTask(for modelId: String) -> Bool {
        cleanupTasks[modelId] != nil
    }

    private func terminate(_ process: Process, killFallbackDelay: TimeInterval) {
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + killFallbackDelay) { [weak process] in
            guard let process, process.isRunning else { return }
            var zombieCheck: Int32 = 0
            if waitpid(pid, &zombieCheck, WNOHANG) == 0 {
                kill(pid, SIGKILL)
                process.waitUntilExit()
            }
        }
    }

    private func scheduleProcessTrackingCleanup(
        _ process: Process,
        modelId: String,
        killFallbackDelay: TimeInterval,
        cleanupDelay: TimeInterval
    ) {
        cancelProcessCleanup(for: modelId)
        let token = UUID()
        cleanupTaskTokens[modelId] = token
        cleanupTasks[modelId] = Task { @MainActor [weak self, weak process] in
            defer {
                if let self, self.cleanupTaskTokens[modelId] == token {
                    self.cleanupTasks[modelId] = nil
                    self.cleanupTaskTokens[modelId] = nil
                }
            }
            let timeout = killFallbackDelay + cleanupDelay + 2.0
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                guard let self, let process, self.processes[modelId] === process else {
                    return
                }
                if !process.isRunning {
                    self.processes[modelId] = nil
                    return
                }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
    }

    private func cancelProcessCleanup(for modelId: String) {
        cleanupTasks[modelId]?.cancel()
        cleanupTasks[modelId] = nil
        cleanupTaskTokens[modelId] = nil
    }
}

@MainActor
struct ModelDownloadStopCoordinator {
    private let lifecycle: ModelDownloadLifecycle
    private let progressTracker: ModelDownloadProgressTracker

    init(
        lifecycle: ModelDownloadLifecycle,
        progressTracker: ModelDownloadProgressTracker
    ) {
        self.lifecycle = lifecycle
        self.progressTracker = progressTracker
    }

    func removalNeedsTrackedWorkToStop(
        for modelId: String,
        currentState: ModelDownloadManager.DownloadState?
    ) -> Bool {
        lifecycle.hasTrackedWork(for: modelId)
            || currentState?.isDownloading == true
            || currentState?.isPaused == true
    }

    func stateAfterStopRequest(
        for modelId: String,
        reason: DownloadStopReason,
        currentState: ModelDownloadManager.DownloadState?,
        killFallbackDelay: TimeInterval,
        cleanupDelay: TimeInterval
    ) -> ModelDownloadManager.DownloadState? {
        guard lifecycle.hasTask(for: modelId) else {
            guard reason == .cancel else { return nil }
            progressTracker.clear(for: modelId)
            return .notDownloaded
        }

        lifecycle.setStopReason(reason, for: modelId)
        let state: ModelDownloadManager.DownloadState
        switch reason {
        case .pause:
            state = .paused(
                progressTracker.pauseProgress(
                    for: modelId,
                    currentState: currentState
                )
            )
        case .cancel:
            progressTracker.clear(for: modelId)
            state = .notDownloaded
        }

        lifecycle.cancelTrackedWork(
            for: modelId,
            killFallbackDelay: killFallbackDelay,
            cleanupDelay: cleanupDelay
        )
        return state
    }

    func waitForTrackedWorkToStop(
        for modelId: String,
        killFallbackDelay: TimeInterval,
        cleanupDelay: TimeInterval,
        waitPadding: TimeInterval
    ) async -> Bool {
        await lifecycle.waitForTrackedWorkToStop(
            for: modelId,
            timeout: killFallbackDelay + cleanupDelay + waitPadding
        )
    }
}
