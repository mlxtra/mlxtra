import Foundation

extension ModelDownloadManager {
    nonisolated static func reliableDownloadPercent(from event: [String: Any], progressKind: String?) -> Double? {
        guard let percent = doubleValue(event["percent"]) else { return nil }

        let isReliable = boolValue(event["percent_reliable"]) == true
            || (progressKind == "bytes" && event["progress_scope"] as? String == "aggregate")
        return isReliable ? clampedPercent(percent) : nil
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
