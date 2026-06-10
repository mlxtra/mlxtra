import SwiftUI

enum ModelDownloadFilter: String, CaseIterable, Identifiable {
    case all
    case missing
    case ready

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .missing: return "Missing"
        case .ready: return "Ready"
        }
    }

    func includes(_ state: ModelDownloadManager.DownloadState) -> Bool {
        switch self {
        case .all:
            return true
        case .missing:
            return state != .downloaded
        case .ready:
            return state == .downloaded
        }
    }
}

extension ModelDownloadManager.DownloadState {
    var sortRank: Int {
        switch self {
        case .downloaded:
            return 0
        case .downloading, .paused:
            return 1
        case .notDownloaded:
            return 2
        case .failed:
            return 3
        }
    }

    var isFailed: Bool {
        if case .failed = self {
            return true
        }
        return false
    }

    var recoveryActionTitle: String {
        switch self {
        case .failed:
            if isUpdateRequiredFailure {
                return "Update"
            }
            return isRepairableFailure ? "Repair" : "Retry"
        case .notDownloaded:
            return "Download"
        case .paused:
            return "Resume"
        case .downloaded, .downloading:
            return ""
        }
    }

    var recoveryActionIcon: String {
        switch self {
        case .failed:
            if isUpdateRequiredFailure {
                return "arrow.triangle.2.circlepath"
            }
            return isRepairableFailure ? "wrench.and.screwdriver" : "arrow.clockwise"
        case .notDownloaded:
            return "arrow.down.circle"
        case .paused:
            return "play.fill"
        case .downloaded, .downloading:
            return "checkmark.circle.fill"
        }
    }

    var failureStatusTitle: String {
        if isUpdateRequiredFailure {
            return "Update needed"
        }
        return isRepairableFailure ? "Needs repair" : "Failed"
    }

    var failureSummaryTitle: String {
        guard case .failed(let message) = self else {
            return failureStatusTitle
        }

        let normalized = message.lowercased()
        if isUpdateRequiredFailure {
            return "Model update required"
        }
        if normalized.contains("hugging face cache") && normalized.contains("incomplete") {
            return "Local cache incomplete"
        }
        if normalized.contains("snapshot") && normalized.contains("incomplete") {
            return "Snapshot incomplete"
        }
        if normalized.contains("components") && normalized.contains("incomplete") {
            return "Components incomplete"
        }
        if normalized.contains("missing") || normalized.contains("not found in cache") {
            return "Missing model files"
        }
        if normalized.contains("rate limit") {
            return "Rate limit reached"
        }
        if normalized.contains("network") || normalized.contains("connection") {
            return "Network unavailable"
        }
        return isRepairableFailure ? "Repair needed" : "Download failed"
    }

    var failureStatusIcon: String {
        if isUpdateRequiredFailure {
            return "arrow.triangle.2.circlepath"
        }
        return isRepairableFailure ? "wrench.and.screwdriver.fill" : "exclamationmark.triangle.fill"
    }

    var failureTint: Color {
        isRepairableFailure ? .orange : .red
    }

    var shortStatusTitle: String {
        switch self {
        case .downloaded:
            return "Ready"
        case .downloading:
            return "Downloading"
        case .paused:
            return "Paused"
        case .notDownloaded:
            return "Missing"
        case .failed:
            return failureStatusTitle
        }
    }

    var shortStatusIcon: String {
        switch self {
        case .downloaded:
            return "checkmark.circle.fill"
        case .downloading:
            return "arrow.down.circle.fill"
        case .paused:
            return "pause.circle.fill"
        case .notDownloaded:
            return "arrow.down.circle"
        case .failed:
            return failureStatusIcon
        }
    }

    var statusTint: Color {
        switch self {
        case .downloaded:
            return .secondary
        case .downloading:
            return .accentColor
        case .paused, .notDownloaded:
            return .orange
        case .failed:
            return failureTint
        }
    }

    var accessibilityKey: String {
        switch self {
        case .downloaded:
            return "ready"
        case .downloading:
            return "downloading"
        case .paused:
            return "paused"
        case .notDownloaded:
            return "missing"
        case .failed:
            if isUpdateRequiredFailure {
                return "update"
            }
            return isRepairableFailure ? "repair" : "failed"
        }
    }
}

extension ModelModality {
    var displayName: String {
        switch self {
        case .vision: return "Chat"
        case .image: return "Image"
        case .audio: return "Speech"
        case .music: return "Music"
        }
    }
}

extension ModelFit {
    var alternativeTitle: String {
        switch self {
        case .recommended: return "Works well"
        case .compatible: return "Works"
        case .heavy: return "Too large"
        case .unknown: return "Unknown fit"
        }
    }

    var settingsSortRank: Int {
        switch self {
        case .recommended: return 0
        case .compatible: return 1
        case .heavy: return 2
        case .unknown: return 3
        }
    }

    var tint: Color {
        switch self {
        case .recommended, .compatible: return .secondary
        case .heavy: return .orange
        case .unknown: return .secondary
        }
    }
}

extension DownloadableModel {
    var accessibilityIdentifierComponent: String {
        id.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : "-"
        }
        .joined()
    }

    func matchesDownloadSearch(_ query: String) -> Bool {
        name.localizedCaseInsensitiveContains(query)
            || subtitle.localizedCaseInsensitiveContains(query)
            || modelId.localizedCaseInsensitiveContains(query)
            || modality.rawValue.localizedCaseInsensitiveContains(query)
    }
}

func formatSize(_ gigabytes: Double) -> String {
    "\(String(format: "%.1f", gigabytes)) GB"
}

#Preview {
    SettingsView()
}
