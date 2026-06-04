import Foundation
import SwiftUI

struct AppUpdateSettingsSection: View {
    let versionText: String
    @ObservedObject var controller: AppUpdateController

    var body: some View {
        UpdateSettingsCard(
            title: "Application",
            subtitle: "MLXtra \(versionText)",
            detail: detailText,
            icon: "app.badge",
            tint: statusTint,
            badge: statusBadge,
            progress: nil,
            isProgressIndeterminate: false,
            progressLabel: nil,
            progressStats: nil,
            accessibilityIdentifier: "settings.appUpdates"
        ) {
            Button {
                controller.checkForUpdates()
            } label: {
                Label(actionTitle, systemImage: actionIcon)
            }
            .buttonStyle(.bordered)
            .disabled(!controller.canCheckForUpdates || controller.status == .checking)
            .help(actionHelp)
        }
    }

    private var detailText: String {
        switch controller.status {
        case .unavailable:
            return "Available in the signed release build."
        case .idle:
            return "Checks GitHub releases through Sparkle."
        case .checking:
            return "Checking GitHub releases."
        case .upToDate:
            return "Checked just now. You're on the latest release."
        case .updateAvailable(let version):
            return "Version \(version) is available."
        case .failed(let message):
            return message
        }
    }

    private var statusBadge: UpdateStatusBadge {
        switch controller.status {
        case .unavailable:
            return UpdateStatusBadge(title: "Local build", icon: "hammer", tint: .secondary)
        case .idle:
            return UpdateStatusBadge(title: "Ready", icon: "checkmark.circle.fill", tint: MLXtraDesignSystem.Palette.success)
        case .checking:
            return UpdateStatusBadge(title: "Checking", icon: "arrow.clockwise", tint: .accentColor)
        case .upToDate:
            return UpdateStatusBadge(title: "Up to date", icon: "checkmark.circle.fill", tint: MLXtraDesignSystem.Palette.success)
        case .updateAvailable:
            return UpdateStatusBadge(title: "Available", icon: "arrow.down.circle.fill", tint: .accentColor)
        case .failed:
            return UpdateStatusBadge(title: "Needs attention", icon: "exclamationmark.triangle.fill", tint: MLXtraDesignSystem.Palette.warning)
        }
    }

    private var statusTint: Color {
        switch controller.status {
        case .idle, .checking, .updateAvailable:
            return .accentColor
        case .upToDate:
            return MLXtraDesignSystem.Palette.success
        case .failed:
            return MLXtraDesignSystem.Palette.warning
        case .unavailable:
            return .secondary
        }
    }

    private var actionTitle: String {
        switch controller.status {
        case .checking:
            return "Checking"
        case .upToDate, .failed:
            return "Check Again"
        case .updateAvailable:
            return "Show Update"
        default:
            return "Check"
        }
    }

    private var actionIcon: String {
        switch controller.status {
        case .checking:
            return "hourglass"
        case .updateAvailable:
            return "arrow.down.circle"
        default:
            return "arrow.clockwise"
        }
    }

    private var actionHelp: String {
        switch controller.status {
        case .unavailable:
            return "Install the signed release build to test app updates"
        case .checking:
            return "Checking for a newer MLXtra release"
        default:
            return "Check for a newer MLXtra release"
        }
    }
}

struct RuntimeUpdateSettingsSection: View {
    @ObservedObject var manager: RuntimeUpdateManager

    var body: some View {
        UpdateSettingsCard(
            title: "Runtime",
            subtitle: runtimeSubtitle,
            detail: detailText,
            icon: "shippingbox",
            tint: statusTint,
            badge: statusBadge,
            progress: runtimeProgress,
            isProgressIndeterminate: isRuntimeProgressIndeterminate,
            progressLabel: runtimeProgressLabel,
            progressStats: runtimeProgressStats,
            accessibilityIdentifier: "settings.runtimeUpdates"
        ) {
            actionView
        }
        .onAppear {
            manager.bootstrapStableRuntimeInBackground(reportFailures: false)
        }
    }

    @ViewBuilder
    private var actionView: some View {
        switch manager.state {
        case .checking:
            EmptyView()
        case .available(let asset):
            Color.clear
                .frame(width: 0, height: 0)
                .task(id: asset.version) {
                    manager.installRuntimeInBackground(asset)
                }
        case .installing:
            EmptyView()
        case .requiresAppUpdate:
            EmptyView()
        case .failed:
            Button {
                manager.bootstrapStableRuntimeInBackground(reportFailures: true)
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
        case .idle, .installed:
            Button {
                manager.bootstrapStableRuntimeInBackground(reportFailures: true)
            } label: {
                Label(runtimeActionTitle, systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
        }
    }

    private var runtimeActionTitle: String {
        if case .installed = manager.state {
            return "Check Again"
        }
        if RuntimeManager.activeRuntimeManifest() != nil {
            return "Check Again"
        }
        return "Check"
    }

    private var detailText: String {
        switch manager.state {
        case .idle:
            if RuntimeManager.activeRuntimeManifest() != nil {
                return "Ready for local model downloads and generation."
            }
            return "Checking the stable runtime channel."
        case .checking:
            return "Checking the stable runtime channel."
        case .available(let asset):
            return appUpdateRequirementSuffix(
                after: "Runtime \(asset.version) is ready to download."
            )
        case .requiresAppUpdate(let requirement):
            return appUpdateRequirementText(requirement)
        case .installing(let progress):
            switch manager.installPhase {
            case .verifying:
                return "Verifying runtime files."
            case .activating:
                if let activationProgress = manager.runtimeActivationProgress {
                    return activationProgress.detail ?? activationProgress.title
                }
                return "Activating runtime files."
            case .downloading where progress != nil:
                return "Downloading runtime files. Setup will finish in the background."
            default:
                return "Downloading, verifying, and activating the runtime."
            }
        case .installed(let version):
            return appUpdateRequirementSuffix(
                after: "Runtime \(version) is ready for local models."
            )
        case .failed(let message):
            return message
        }
    }

    private var runtimeSubtitle: String {
        switch manager.state {
        case .available(let asset):
            return "Runtime \(asset.version)"
        case .requiresAppUpdate(let requirement):
            return "Runtime \(requirement.runtime.version)"
        case .installing:
            return installingRuntimeSubtitle
        case .installed(let version):
            return "Runtime \(version)"
        default:
            if let manifest = RuntimeManager.activeRuntimeManifest() {
                return "Runtime \(manifest.runtimeVersion)"
            }
            return "Runtime files"
        }
    }

    private var statusBadge: UpdateStatusBadge {
        switch manager.state {
        case .checking:
            return UpdateStatusBadge(title: "Checking", icon: "arrow.clockwise", tint: .accentColor)
        case .available:
            return UpdateStatusBadge(title: "Updating", icon: "arrow.down.circle.fill", tint: .accentColor)
        case .requiresAppUpdate:
            return UpdateStatusBadge(title: "Update app", icon: "app.badge", tint: MLXtraDesignSystem.Palette.warning)
        case .installing:
            return UpdateStatusBadge(title: "Installing", icon: "arrow.down.circle.fill", tint: .accentColor)
        case .installed:
            return UpdateStatusBadge(title: "Ready", icon: "checkmark.circle.fill", tint: MLXtraDesignSystem.Palette.success)
        case .failed:
            return UpdateStatusBadge(title: "Needs attention", icon: "exclamationmark.triangle.fill", tint: MLXtraDesignSystem.Palette.warning)
        case .idle:
            if RuntimeManager.activeRuntimeManifest() == nil {
                return UpdateStatusBadge(title: "Pending", icon: "arrow.down.circle", tint: .secondary)
            }
            return UpdateStatusBadge(title: "Ready", icon: "checkmark.circle.fill", tint: MLXtraDesignSystem.Palette.success)
        }
    }

    private var statusTint: Color {
        switch manager.state {
        case .installed:
            return MLXtraDesignSystem.Palette.success
        case .requiresAppUpdate, .failed:
            return MLXtraDesignSystem.Palette.warning
        case .idle:
            return RuntimeManager.activeRuntimeManifest() == nil ? .secondary : MLXtraDesignSystem.Palette.success
        default:
            return .accentColor
        }
    }

    private func appUpdateRequirementSuffix(after base: String) -> String {
        guard let requirement = manager.newerRuntimeRequiringAppUpdate else {
            return base
        }
        return "\(base) \(appUpdateRequirementText(requirement))"
    }

    private func appUpdateRequirementText(_ requirement: RuntimeAppUpdateRequirement) -> String {
        "Runtime \(requirement.runtime.version) requires MLXtra \(requirement.requiredAppVersion) or newer."
    }

    private var runtimeProgress: Double? {
        if case .installing(let progress) = manager.state,
           manager.installPhase == .downloading {
            return progress
        }
        return nil
    }

    private var isRuntimeProgressIndeterminate: Bool {
        guard case .installing = manager.state else {
            return false
        }

        switch manager.installPhase {
        case .downloading:
            return runtimeProgress == nil
        case .verifying, .activating:
            return true
        case .idle:
            return false
        }
    }

    private var runtimeProgressLabel: String? {
        guard case .installing = manager.state else {
            return nil
        }

        switch manager.installPhase {
        case .verifying:
            return "Verifying"
        case .activating:
            return manager.runtimeActivationProgress?.title ?? "Preparing"
        case .downloading where runtimeProgress == nil:
            return "Downloading"
        default:
            return nil
        }
    }

    private var installingRuntimeSubtitle: String {
        if let asset = manager.installingRuntime {
            return "Runtime \(asset.version)"
        }
        if let manifest = RuntimeManager.activeRuntimeManifest() {
            return "Runtime \(manifest.runtimeVersion)"
        }
        return "Runtime setup"
    }

    private var runtimeProgressStats: RuntimeProgressStats? {
        guard case .installing = manager.state,
              manager.installPhase == .downloading,
              let progress = manager.runtimeDownloadProgress else {
            return nil
        }

        let downloaded = Self.formattedBytes(progress.downloadedBytes)
        let transferred: String
        if let totalBytes = progress.totalBytes {
            transferred = "\(downloaded) / \(Self.formattedBytes(totalBytes))"
        } else {
            transferred = downloaded
        }

        var speed: String?
        if let bytesPerSecond = progress.bytesPerSecond, bytesPerSecond > 0 {
            speed = "\(Self.formattedBytes(Int64(bytesPerSecond)))/s"
        }

        var remaining: String?
        if let estimatedSecondsRemaining = progress.estimatedSecondsRemaining {
            remaining = Self.formattedDuration(estimatedSecondsRemaining)
        }

        return RuntimeProgressStats(
            transferred: transferred,
            speed: speed,
            remaining: remaining
        )
    }

    private static func formattedBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private static func formattedDuration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.maximumUnitCount = 2
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: max(seconds, 1)) ?? "calculating"
    }
}

struct UpdateStatusBadge {
    let title: String
    let icon: String
    let tint: Color
}

private struct RuntimeProgressStats {
    let transferred: String
    let speed: String?
    let remaining: String?
}

private struct UpdateSettingsCard<Action: View>: View {
    let title: String
    let subtitle: String
    let detail: String
    let icon: String
    let tint: Color
    let badge: UpdateStatusBadge
    let progress: Double?
    let isProgressIndeterminate: Bool
    let progressLabel: String?
    let progressStats: RuntimeProgressStats?
    let accessibilityIdentifier: String
    @ViewBuilder var action: () -> Action

    var body: some View {
        VStack(alignment: .leading, spacing: MLXtraDesignSystem.Spacing.xxl) {
            HStack(alignment: .center, spacing: MLXtraDesignSystem.Spacing.xxl) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 38, height: 38)
                    .designTintSurface(tint, cornerRadius: MLXtraDesignSystem.Radius.control)

                VStack(alignment: .leading, spacing: MLXtraDesignSystem.Spacing.xs) {
                    HStack(alignment: .firstTextBaseline, spacing: MLXtraDesignSystem.Spacing.md) {
                        Text(title)
                            .font(.headline)

                        StatusBadgeView(badge: badge)
                    }

                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }

                Spacer(minLength: MLXtraDesignSystem.Spacing.section)

                action()
                    .controlSize(.regular)
            }

            if let progress {
                VStack(alignment: .leading, spacing: MLXtraDesignSystem.Spacing.xs) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)

                    HStack(alignment: .top, spacing: MLXtraDesignSystem.Spacing.md) {
                        Text("\(Int((progress * 100).rounded()))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 44, alignment: .leading)

                        Spacer(minLength: MLXtraDesignSystem.Spacing.lg)

                        if let progressStats {
                            RuntimeProgressStatsView(stats: progressStats)
                        }
                    }
                }
            } else if isProgressIndeterminate {
                VStack(alignment: .leading, spacing: MLXtraDesignSystem.Spacing.xs) {
                    ProgressView()
                        .progressViewStyle(.linear)

                    if let progressLabel {
                        Text(progressLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .designContentSurface(cornerRadius: MLXtraDesignSystem.Radius.card)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

private struct RuntimeProgressStatsView: View {
    let stats: RuntimeProgressStats

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            metric(title: "Downloaded", value: stats.transferred, width: 156)
            metric(title: "Speed", value: stats.speed ?? "-", width: 84)
            metric(title: "Remaining", value: stats.remaining ?? "-", width: 88)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func metric(title: String, value: String, width: CGFloat) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.86)
        }
        .frame(width: width, alignment: .trailing)
    }
}

private struct StatusBadgeView: View {
    let badge: UpdateStatusBadge

    var body: some View {
        Label(badge.title, systemImage: badge.icon)
            .font(MLXtraDesignSystem.Typography.microMedium)
            .foregroundStyle(badge.tint)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(badge.tint.opacity(0.10), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(badge.tint.opacity(0.16), lineWidth: 1)
            }
    }
}

struct RuntimeUpdateSection: View {
    @ObservedObject var manager: RuntimeUpdateManager

    var body: some View {
        switch manager.state {
        case .available(let asset):
            Color.clear
                .frame(height: 0)
                .task(id: asset.version) {
                    manager.installRuntimeInBackground(asset)
                }
        case .installing:
            updateCard(
                title: "Installing runtime",
                detail: "Downloading, verifying, and activating the runtime.",
                icon: "gearshape.2.fill",
                tint: .accentColor
            ) {
                ProgressView()
                    .controlSize(.small)
            }
        case .requiresAppUpdate(let requirement):
            updateCard(
                title: "Update MLXtra",
                detail: "Runtime \(requirement.runtime.version) requires MLXtra \(requirement.requiredAppVersion) or newer.",
                icon: "exclamationmark.triangle.fill",
                tint: .orange
            ) {
                EmptyView()
            }
        case .installed(let version):
            updateCard(
                title: "Runtime ready",
                detail: "Runtime \(version) is ready to use.",
                icon: "checkmark.circle.fill",
                tint: .secondary
            ) {
                EmptyView()
            }
        case .failed(let message):
            updateCard(
                title: "Runtime update unavailable",
                detail: message,
                icon: "exclamationmark.triangle.fill",
                tint: .orange
            ) {
                Button {
                    manager.bootstrapStableRuntimeInBackground(reportFailures: true)
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
        case .checking, .idle:
            EmptyView()
        }
    }

    private func updateCard<Action: View>(
        title: String,
        detail: String,
        icon: String,
        tint: Color,
        @ViewBuilder action: () -> Action
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .designTintSurface(tint, cornerRadius: MLXtraDesignSystem.Radius.control)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()
            action()
        }
        .padding(12)
        .designTintSurface(tint, cornerRadius: MLXtraDesignSystem.Radius.card)
    }

}

struct CapabilitySetupSection: View {
    let items: [CapabilitySetupItem]
    let onDownload: (DownloadableModel) -> Void
    let onPause: (DownloadableModel) -> Void
    let onCancel: (DownloadableModel) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 280), spacing: 10)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ready for this Mac")
                .font(.headline)

            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(items) { item in
                    CapabilitySetupCard(
                        item: item,
                        onDownload: onDownload,
                        onPause: onPause,
                        onCancel: onCancel
                    )
                }
            }
        }
    }
}

struct CapabilitySetupCard: View {
    let item: CapabilitySetupItem
    let onDownload: (DownloadableModel) -> Void
    let onPause: (DownloadableModel) -> Void
    let onCancel: (DownloadableModel) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.icon)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .designTintSurface(tint, cornerRadius: MLXtraDesignSystem.Radius.control)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.title)
                        .font(.title3.weight(.semibold))

                    Spacer(minLength: 8)
                    statusLabel
                }

                Text(item.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(item.model.name)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                actionView
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 136, alignment: .topLeading)
        .designTintSurface(tint, cornerRadius: MLXtraDesignSystem.Radius.card)
    }

    @ViewBuilder
    private var actionView: some View {
        if !item.model.isRuntimeCompatible {
            Label("Update needed", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
        } else {
            switch item.state {
            case .downloaded:
                EmptyView()
            case .downloading(let progress):
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progress?.fractionCompleted)
                        .frame(maxWidth: 180)
                    Text(progress?.displayText ?? "Downloading")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Button {
                            onPause(item.model)
                        } label: {
                            Label("Pause", systemImage: "pause.fill")
                        }
                        Button(role: .cancel) {
                            onCancel(item.model)
                        } label: {
                            Label("Cancel", systemImage: "xmark")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            case .paused:
                HStack(spacing: 6) {
                    Button {
                        onDownload(item.model)
                    } label: {
                        Label("Resume", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)

                    Button(role: .cancel) {
                        onCancel(item.model)
                    } label: {
                        Label("Cancel", systemImage: "xmark")
                    }
                }
                .controlSize(.small)
            case .notDownloaded, .failed:
                Button {
                    onDownload(item.model)
                } label: {
                    Label(item.state.recoveryActionTitle, systemImage: item.state.recoveryActionIcon)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
        }
    }

    private var statusLabel: some View {
        Label(statusText, systemImage: statusIcon)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.10))
            .clipShape(Capsule())
    }

    private var statusText: String {
        switch item.state {
        case .downloaded:
            return "Ready"
        case .downloading:
            return "Downloading"
        case .paused:
            return "Paused"
        case .failed:
            return item.state.failureStatusTitle
        case .notDownloaded:
            return "Needs setup"
        }
    }

    private var statusIcon: String {
        switch item.state {
        case .downloaded:
            return "checkmark.circle.fill"
        case .downloading:
            return "arrow.down.circle.fill"
        case .paused:
            return "pause.circle.fill"
        case .failed:
            return item.state.failureStatusIcon
        case .notDownloaded:
            return "arrow.down.circle.fill"
        }
    }

    private var tint: Color {
        switch item.state {
        case .downloaded:
            return .secondary
        case .downloading:
            return .accentColor
        case .paused:
            return .orange
        case .failed:
            return item.state.failureTint
        case .notDownloaded:
            return .orange
        }
    }
}
