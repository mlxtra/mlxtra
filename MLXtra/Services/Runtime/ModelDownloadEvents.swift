import Foundation

enum ModelDownloadEvent: Equatable {
    case started
    case progress(
        status: String,
        description: String?,
        unit: String?,
        progressKind: String?,
        downloadedBytes: Int64?,
        totalBytes: Int64?,
        percent: Double?
    )
    case verified(hashCount: Int64)
    case complete
    case error(String)
}

enum ModelDownloadEventParser {
    nonisolated static func parseDownloadEventLine(_ line: String) -> ModelDownloadEvent? {
        guard let data = line.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else {
            return nil
        }

        switch type {
        case "download.started":
            return .started
        case "download.progress":
            let progressKind = event["progress_kind"] as? String
            return .progress(
                status: event["status"] as? String ?? "Downloading",
                description: event["description"] as? String,
                unit: event["unit"] as? String,
                progressKind: progressKind,
                downloadedBytes: int64Value(event["downloaded"]),
                totalBytes: int64Value(event["total"]),
                percent: reliableDownloadPercent(from: event, progressKind: progressKind)
            )
        case "download.verified":
            return .verified(hashCount: int64Value(event["hash_count"]) ?? 0)
        case "download.complete":
            return .complete
        case "download.error":
            guard let message = event["message"] as? String else { return nil }
            return .error(message)
        default:
            return nil
        }
    }

    nonisolated static func downloadProgress(
        for event: ModelDownloadEvent,
        previousPercent: Double?
    ) -> ModelDownloadManager.DownloadProgress? {
        switch event {
        case .started:
            return ModelDownloadManager.DownloadProgress(
                status: "Preparing",
                description: nil,
                unit: nil,
                progressKind: nil,
                downloadedBytes: nil,
                totalBytes: nil,
                percent: nil
            )
        case .progress(
            let status,
            let description,
            let unit,
            let progressKind,
            let downloadedBytes,
            let totalBytes,
            let percent
        ):
            return ModelDownloadManager.DownloadProgress(
                status: status,
                description: description,
                unit: unit,
                progressKind: progressKind,
                downloadedBytes: downloadedBytes,
                totalBytes: totalBytes,
                percent: monotonicPercent(percent, previous: previousPercent)
            )
        case .verified(let hashCount):
            return ModelDownloadManager.DownloadProgress(
                status: "Verifying",
                description: hashCount > 0 ? "Local files and hashes verified" : "Local files verified",
                unit: nil,
                progressKind: nil,
                downloadedBytes: nil,
                totalBytes: nil,
                percent: nil
            )
        case .complete:
            return ModelDownloadManager.DownloadProgress(
                status: "Finalizing",
                description: nil,
                unit: nil,
                progressKind: nil,
                downloadedBytes: nil,
                totalBytes: nil,
                percent: nil
            )
        case .error:
            return nil
        }
    }

    nonisolated static func reliableDownloadPercent(from event: [String: Any], progressKind: String?) -> Double? {
        guard let percent = doubleValue(event["percent"]) else { return nil }

        let isReliable = boolValue(event["percent_reliable"]) == true
            || (progressKind == "bytes" && event["progress_scope"] as? String == "aggregate")
        return isReliable ? clampedPercent(percent) : nil
    }

    nonisolated static func monotonicPercent(_ percent: Double?, previous: Double?) -> Double? {
        guard let percent else { return nil }
        guard let previous else { return percent }
        return max(percent, previous)
    }

    private nonisolated static func int64Value(_ value: Any?) -> Int64? {
        if let value = value as? Int64 {
            return value
        }
        if let value = value as? Int {
            return Int64(value)
        }
        if let value = value as? Double {
            return Int64(value)
        }
        if let value = value as? NSNumber {
            return value.int64Value
        }
        return nil
    }

    private nonisolated static func clampedPercent(_ percent: Double) -> Double {
        max(0.0, min(percent, 100.0))
    }

    private nonisolated static func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double {
            return value
        }
        if let value = value as? Int {
            return Double(value)
        }
        if let value = value as? NSNumber {
            return value.doubleValue
        }
        return nil
    }

    private nonisolated static func boolValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool {
            return value
        }
        if let value = value as? NSNumber {
            return value.boolValue
        }
        if let value = value as? String {
            switch value.lowercased() {
            case "true", "1", "yes":
                return true
            case "false", "0", "no":
                return false
            default:
                return nil
            }
        }
        return nil
    }
}
