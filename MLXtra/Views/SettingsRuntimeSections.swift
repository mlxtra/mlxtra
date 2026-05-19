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
                Label("Check", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
        }
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
            return "Runtime \(asset.version) is ready to download."
        case .installing(let progress):
            if progress == nil {
                return "Downloading, verifying, and activating the runtime."
            }
            return "Downloading runtime files. Setup will finish in the background."
        case .installed(let version):
            return "Runtime \(version) is ready for local models."
        case .failed(let message):
            return message
        }
    }

    private var runtimeSubtitle: String {
        switch manager.state {
        case .available(let asset):
            return "Runtime \(asset.version)"
        case .installing:
            if let manifest = RuntimeManager.activeRuntimeManifest() {
                return "Runtime \(manifest.runtimeVersion)"
            }
            return "Runtime setup"
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
        case .failed:
            return MLXtraDesignSystem.Palette.warning
        case .idle:
            return RuntimeManager.activeRuntimeManifest() == nil ? .secondary : MLXtraDesignSystem.Palette.success
        default:
            return .accentColor
        }
    }

    private var runtimeProgress: Double? {
        if case .installing(let progress) = manager.state {
            return progress
        }
        return nil
    }
}

struct UpdateStatusBadge {
    let title: String
    let icon: String
    let tint: Color
}

private struct UpdateSettingsCard<Action: View>: View {
    let title: String
    let subtitle: String
    let detail: String
    let icon: String
    let tint: Color
    let badge: UpdateStatusBadge
    let progress: Double?
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

                    Text("\(Int((progress * 100).rounded()))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .designContentSurface(cornerRadius: MLXtraDesignSystem.Radius.card)
        .accessibilityIdentifier(accessibilityIdentifier)
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
