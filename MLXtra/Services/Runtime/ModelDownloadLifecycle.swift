import Darwin
import Foundation

@MainActor
final class ModelDownloadLifecycle {
    private var tasks: [String: Task<Void, Never>] = [:]
    private var processes: [String: Process] = [:]
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

    func clearTask(for modelId: String) {
        tasks[modelId] = nil
    }

    func setProcess(_ process: Process, for modelId: String) {
        processes[modelId] = process
    }

    func clearProcess(for modelId: String) {
        processes[modelId] = nil
    }

    func clearProcessIfFinished(_ process: Process?, for modelId: String) {
        guard let process,
              processes[modelId] === process,
              !process.isRunning else {
            return
        }
        processes[modelId] = nil
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
        Task { @MainActor [weak self, weak process] in
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
}
