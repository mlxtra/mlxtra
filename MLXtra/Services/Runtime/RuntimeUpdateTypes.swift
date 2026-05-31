import Foundation

struct RuntimeDownloadProgress: Equatable {
    let downloadedBytes: Int64
    let totalBytes: Int64?
    let bytesPerSecond: Double?
    let estimatedSecondsRemaining: TimeInterval?

    init(downloadedBytes: Int64, totalBytes: Int64?, bytesPerSecond: Double? = nil) {
        self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond

        if let totalBytes,
           let bytesPerSecond,
           bytesPerSecond > 0,
           totalBytes > downloadedBytes {
            estimatedSecondsRemaining = Double(totalBytes - downloadedBytes) / bytesPerSecond
        } else {
            estimatedSecondsRemaining = nil
        }
    }

    var fractionCompleted: Double? {
        guard let totalBytes, totalBytes > 0 else {
            return nil
        }
        return min(max(Double(downloadedBytes) / Double(totalBytes), 0), 1)
    }
}

struct RuntimeActivationProgress: Equatable {
    let title: String
    let detail: String?
    let completedStep: Int
    let totalSteps: Int

    var fractionCompleted: Double {
        guard totalSteps > 0 else { return 0 }
        return min(max(Double(completedStep) / Double(totalSteps), 0), 1)
    }

    var stepText: String {
        "Step \(completedStep) of \(totalSteps)"
    }
}

typealias RuntimeArchiveInstaller = @Sendable (
    _ archiveURL: URL,
    _ progressHandler: @escaping @Sendable (RuntimeActivationProgress) -> Void
) throws -> URL

enum RuntimeInstallPhase: Equatable {
    case idle
    case downloading
    case verifying
    case activating
}

struct RuntimeAppUpdateRequirement: Equatable {
    let runtime: RuntimeReleaseAsset
    let requiredAppVersion: String
    let currentAppVersion: String?
}

enum RuntimeUpdateError: LocalizedError {
    case channelUnavailable
    case checksumMismatch
    case invalidRuntime
    case unsupportedArchive

    var errorDescription: String? {
        switch self {
        case .channelUnavailable:
            return "No runtime update channel is available yet"
        case .checksumMismatch:
            return "Runtime archive checksum did not match"
        case .invalidRuntime:
            return "Downloaded runtime did not pass validation"
        case .unsupportedArchive:
            return "Runtime archive format is not supported"
        }
    }
}
