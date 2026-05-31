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
            return message.contains("incomplete")
                || message.contains("not found in cache")
                || message.contains("missing files")
                || message.contains("missing components")
                || message.contains("redownload")
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
    case stoppedByUser

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let message):
            return message
        case .stoppedByUser:
            return "Download stopped."
        }
    }
}
