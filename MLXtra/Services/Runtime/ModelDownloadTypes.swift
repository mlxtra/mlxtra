import Foundation

enum DownloadStopReason: Equatable {
    case pause
    case cancel
}

enum DownloadDiagnostics {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["MLXTRA_DOWNLOAD_DEBUG"] == "1"
            || UserDefaults.standard.bool(forKey: "MLXtra.downloadDebug")
    }

    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        print(message())
    }
}

final class DownloadErrorTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var receivedError: [String: Bool] = [:]

    func setErrorReceived(for modelId: String) {
        lock.lock()
        defer { lock.unlock() }
        receivedError[modelId] = true
    }

    func clearErrorReceived(for modelId: String) {
        lock.lock()
        defer { lock.unlock() }
        receivedError[modelId] = nil
    }

    func errorWasReceived(for modelId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return receivedError[modelId] ?? false
    }
}

@MainActor
struct ModelDownloadStateCoordinator {
    struct RefreshSnapshot: Equatable {
        let stateVersion: Int
        let refreshVersion: Int
    }

    private var stateVersions: [String: Int] = [:]
    private var refreshVersions: [String: Int] = [:]
    private var downloadTokens: [String: UUID] = [:]

    mutating func captureRefreshSnapshot(for modelId: String) -> RefreshSnapshot {
        refreshVersions[modelId, default: 0] += 1
        return RefreshSnapshot(
            stateVersion: stateVersions[modelId] ?? 0,
            refreshVersion: refreshVersions[modelId] ?? 0
        )
    }

    func canApplyRefresh(
        _ snapshot: RefreshSnapshot,
        for modelId: String,
        currentState: ModelDownloadManager.DownloadState?
    ) -> Bool {
        (stateVersions[modelId] ?? 0) == snapshot.stateVersion
            && (refreshVersions[modelId] ?? 0) == snapshot.refreshVersion
            && currentState?.isDownloading != true
            && currentState?.isPaused != true
    }

    mutating func recordStateChange(for modelId: String) {
        stateVersions[modelId, default: 0] += 1
    }

    mutating func beginDownload(for modelId: String) -> UUID {
        let token = UUID()
        downloadTokens[modelId] = token
        return token
    }

    func isActiveDownload(_ token: UUID, for modelId: String) -> Bool {
        downloadTokens[modelId] == token
    }

    mutating func finishDownload(_ token: UUID, for modelId: String) -> Bool {
        guard isActiveDownload(token, for: modelId) else { return false }
        downloadTokens[modelId] = nil
        return true
    }
}

enum ModelDownloadFailureAction: Equatable {
    case pause(ModelDownloadManager.DownloadProgress?)
    case cancel
    case fail(String)
    case suppress
}

@MainActor
struct ModelDownloadFailureResolver {
    private let progressTracker: ModelDownloadProgressTracker

    init(progressTracker: ModelDownloadProgressTracker) {
        self.progressTracker = progressTracker
    }

    func action(
        for error: Error,
        modelId: String,
        stopReason: DownloadStopReason?,
        currentState: ModelDownloadManager.DownloadState?,
        helperErrorWasReceived: Bool
    ) -> ModelDownloadFailureAction {
        if let stopReason {
            switch stopReason {
            case .pause:
                return .pause(
                    progressTracker.pauseProgress(
                        for: modelId,
                        currentState: currentState
                    )
                )
            case .cancel:
                return .cancel
            }
        }

        guard !helperErrorWasReceived else {
            return .suppress
        }

        return .fail(error.localizedDescription)
    }
}

extension ModelDownloadManager {
    struct DownloadProgress: Equatable {
        let status: String
        let description: String?
        let unit: String?
        let progressKind: String?
        let downloadedBytes: Int64?
        let totalBytes: Int64?
        let percent: Double?

        var fractionCompleted: Double? {
            guard let percent else { return nil }
            return Self.clampedPercent(percent) / 100.0
        }

        var displayText: String {
            if let percent {
                return "\(Int(Self.clampedPercent(percent).rounded()))%"
            }
            return status
        }

        var detailText: String? {
            if let downloadedBytes, let totalBytes, totalBytes > 0 {
                if isByteProgress {
                    return "\(Self.formatBytes(downloadedBytes)) of \(Self.formatBytes(totalBytes))"
                }

                if isFileProgress {
                    return "\(downloadedBytes) of \(totalBytes) \(totalBytes == 1 ? "file" : "files")"
                }

                if let unit, !unit.isEmpty {
                    return "\(downloadedBytes) of \(totalBytes) \(Self.displayUnit(unit, total: totalBytes))"
                }
            }

            guard let description, !description.isEmpty else {
                return nil
            }
            return description
        }

        private var isByteProgress: Bool {
            progressKind == "bytes" || unit == "B"
        }

        private var isFileProgress: Bool {
            progressKind == "files" || unit == "it" || unit == "file" || unit == "files"
        }

        private static func formatBytes(_ bytes: Int64) -> String {
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useMB, .useGB]
            formatter.countStyle = .file
            return formatter.string(fromByteCount: bytes)
        }

        private static func displayUnit(_ unit: String, total: Int64) -> String {
            if unit == "it" {
                return total == 1 ? "item" : "items"
            }
            return unit
        }

        private static func clampedPercent(_ percent: Double) -> Double {
            max(0.0, min(percent, 100.0))
        }
    }

    enum DownloadState: Equatable {
        case notDownloaded
        case downloading(DownloadProgress?)
        case paused(DownloadProgress?)
        case downloaded
        case failed(String)

        var isDownloading: Bool {
            if case .downloading = self {
                return true
            }
            return false
        }

        var isPaused: Bool {
            if case .paused = self {
                return true
            }
            return false
        }

        var progress: DownloadProgress? {
            switch self {
            case .downloading(let progress), .paused(let progress):
                return progress
            case .notDownloaded, .downloaded, .failed:
                return nil
            }
        }

        var isTerminal: Bool {
            switch self {
            case .downloaded, .failed:
                return true
            case .notDownloaded, .downloading, .paused:
                return false
            }
        }

        var failureMessage: String? {
            if case .failed(let message) = self {
                return message
            }
            return nil
        }

        var isRepairableFailure: Bool {
            guard let message = failureMessage?.lowercased() else { return false }
            return isUpdateRequiredFailure
                || message.contains("incomplete")
                || message.contains("not found in cache")
                || message.contains("files are missing")
                || message.contains("missing files")
                || message.contains("missing components")
                || message.contains("repair")
                || message.contains("redownload")
        }

        var isUpdateRequiredFailure: Bool {
            guard let message = failureMessage?.lowercased() else { return false }
            return message.contains("model update required")
        }
    }

    nonisolated static func downloadState(for storageStatus: RuntimeManager.ModelStorageStatus) -> DownloadState {
        switch storageStatus {
        case .downloaded:
            return .downloaded
        case .missing:
            return .notDownloaded
        case .incomplete(let message):
            return .failed(message)
        }
    }

    nonisolated static func downloadStateAfterDownload(
        for storageStatus: RuntimeManager.ModelStorageStatus
    ) -> DownloadState {
        switch storageStatus {
        case .downloaded:
            return .downloaded
        case .missing:
            return .failed("Download finished, but model files were not found in cache.")
        case .incomplete(let message):
            return .failed(message)
        }
    }
}

enum ModelDownloadError: LocalizedError {
    case downloadFailed(String)
    case removalStillStopping
    case stoppedByUser

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let message):
            return message
        case .removalStillStopping:
            return "Model removal is still waiting for the active download to stop. Try again in a moment."
        case .stoppedByUser:
            return "Download stopped."
        }
    }
}
