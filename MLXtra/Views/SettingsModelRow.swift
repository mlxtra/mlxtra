import SwiftUI

struct ModelManagerRow: View {
    let model: DownloadableModel
    let mode: SettingsModelMode
    let state: ModelDownloadManager.DownloadState
    let isDefault: Bool
    let isRecommended: Bool
    let isPendingDownload: Bool
    @ObservedObject var runtimeUpdateManager: RuntimeUpdateManager
    let onSetDefault: () -> Void
    let onDownload: () -> Void
    let onPause: () -> Void
    let onCancel: () -> Void
    let onRemove: () -> Void

    @State private var showsDetails = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            rowIcon

            VStack(alignment: .leading, spacing: 10) {
                rowMainLine
                detailsDisclosure
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(isPendingDownload ? Color.accentColor.opacity(0.10) : Color.clear)
        .overlay(alignment: .leading) {
            if isPendingDownload {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 3)
            }
        }
        .accessibilityIdentifier("settings.modelRow.\(model.accessibilityIdentifierComponent)")
    }

    private var rowIcon: some View {
        Image(systemName: mode.icon)
            .font(.system(size: MLXtraDesignSystem.Icon.medium, weight: .semibold))
            .foregroundStyle(rowTint)
            .frame(width: 36, height: 36)
            .designTintSurface(rowTint, cornerRadius: MLXtraDesignSystem.Radius.control)
            .accessibilityIdentifier("settings.modelRow.icon")
    }

    private var rowMainLine: some View {
        HStack(alignment: .top, spacing: 16) {
            modelTextBlock
                .frame(maxWidth: .infinity, alignment: .leading)

            actionCluster
        }
    }

    private var modelTextBlock: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(model.name)
                    .font(MLXtraDesignSystem.Typography.compactBodySemibold)

                if isDefault {
                    Label(mode.defaultTitle, systemImage: "checkmark.circle.fill")
                        .font(MLXtraDesignSystem.Typography.captionMedium)
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(1)
                }
            }

            Text(mode.purpose)
                .font(MLXtraDesignSystem.Typography.compactBody)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            HStack(spacing: 7) {
                readinessBadge
                recommendationBadge
                Text(formatSize(model.totalDownloadSizeGB))
                    .font(MLXtraDesignSystem.Typography.microMedium)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.modelRow.textColumn")
    }

    private var actionCluster: some View {
        HStack(alignment: .top, spacing: 8) {
            actionView
                .frame(width: 176, alignment: .trailing)

            secondaryActionsMenu
                .frame(width: 28, height: 28, alignment: .topTrailing)
        }
        .frame(width: 212, alignment: .trailing)
        .padding(.top, 1)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.modelRow.actionColumn")
    }

    private var detailsDisclosure: some View {
        ClickableDisclosureSection(isExpanded: $showsDetails) {
            VStack(alignment: .leading, spacing: 6) {
                ModelDetailLine(label: "Source", value: model.source.downloadRepository ?? model.modelId)
                ModelDetailLine(label: "Model ID", value: model.modelId)
                ModelDetailLine(label: "Backend", value: model.backend.displayName)
                ModelDetailLine(label: "Runtime", value: "Runtime \(model.runtime.minVersion)+")
                ModelDetailLine(label: "Memory", value: model.estimatedMemoryGB.map(formatSize) ?? "Unknown")
                if let acceleration = model.acceleration {
                    ModelDetailLine(label: "Acceleration", value: "Included, +\(formatSize(acceleration.downloadSizeGB))")
                    ModelDetailLine(label: "Acceleration Source", value: acceleration.downloadRepository)
                }
                ModelDetailLine(label: "Storage", value: storageLabel)
            }
            .padding(.top, 6)
        } label: {
            Text("Details")
                .font(MLXtraDesignSystem.Typography.captionMedium)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.modelRow.details")
    }

    @ViewBuilder
    private var actionView: some View {
        if shouldShowRuntimeRequirement {
            VStack(alignment: .trailing, spacing: 6) {
                Label(runtimeRequirementTitle, systemImage: runtimeRequirementIcon)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.orange)

                Text(runtimeRequirementDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)

                runtimeAction
            }
            .accessibilityIdentifier("settings.modelState.runtimeRequired")
        } else {
            stateAction
        }
    }

    private var shouldShowRuntimeRequirement: Bool {
        guard !model.isRuntimeCompatible else {
            return false
        }
        switch state {
        case .downloading, .paused:
            return false
        default:
            return true
        }
    }

    private var runtimeRequirementTitle: String {
        if case .requiresAppUpdate = runtimeUpdateManager.state {
            return "App update required"
        }
        return "Setup required"
    }

    private var runtimeRequirementIcon: String {
        if case .requiresAppUpdate = runtimeUpdateManager.state {
            return "app.badge"
        }
        return "arrow.triangle.2.circlepath"
    }

    private var runtimeRequirementDetail: String {
        "Requires Runtime \(model.runtime.minVersion)+ before download."
    }

    @ViewBuilder
    private var runtimeAction: some View {
        switch runtimeUpdateManager.state {
        case .available(let asset):
            if asset.component == model.runtime.component {
                if isPendingDownload {
                    queuedRuntimeAction
                } else {
                    runtimeSetupStatus("Setting up")
                }
                Color.clear
                    .frame(width: 0, height: 0)
                    .task(id: asset.id) {
                        runtimeUpdateManager.installRuntimeInBackground(asset)
                    }
            } else {
                queueDownloadButton
            }
        case .installing:
            if isPendingDownload {
                queuedRuntimeAction
            } else {
                queueDownloadButton
            }
        case .checking:
            if isPendingDownload {
                queuedRuntimeAction
            } else {
                queueDownloadButton
            }
        case .failed:
            Button {
                runtimeUpdateManager.bootstrapStableRuntimeInBackground(
                    reportFailures: true,
                    component: model.runtime.component
                )
            } label: {
                Label("Retry Setup", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        case .requiresAppUpdate:
            runtimeBlockedDownloadAction
        case .idle, .installed:
            Button {
                onDownload()
            } label: {
                Label("Setup Runtime", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var runtimeBlockedDownloadAction: some View {
        switch state {
        case .notDownloaded, .failed:
            if isPendingDownload {
                queuedRuntimeAction
            } else {
                queueDownloadButton
            }
        default:
            runtimeUnavailableStatus("Update MLXtra")
        }
    }

    private var queueDownloadButton: some View {
        Button {
            onDownload()
        } label: {
            Label("Queue Download", systemImage: "arrow.down.circle")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var queuedRuntimeAction: some View {
        VStack(alignment: .trailing, spacing: 6) {
            runtimeSetupStatus("Queued")

            Button(role: .cancel) {
                onCancel()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 24, height: 22)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(.red)
            .help("Remove from Queue")
            .accessibilityLabel("Remove from Queue")
            .accessibilityIdentifier("settings.modelState.queued.cancel")
        }
    }

    private func runtimeUnavailableStatus(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
    }

    private func runtimeSetupStatus(_ text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text(text)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var stateAction: some View {
        switch state {
        case .notDownloaded:
            Button {
                onDownload()
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
                    .frame(width: primaryActionWidth)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .accessibilityIdentifier("settings.modelState.missing")

        case .downloading(let progress):
            VStack(alignment: .trailing, spacing: 6) {
                if let fractionCompleted = progress?.fractionCompleted {
                    ProgressView(value: fractionCompleted)
                        .frame(width: 150)
                    Text(downloadProgressText(progress))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Downloading")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                HStack(spacing: 6) {
                    compactActionButton("Pause", systemImage: "pause.fill", action: onPause)
                    compactActionButton("Cancel", systemImage: "xmark", role: .cancel, action: onCancel)
                }
            }
            .accessibilityIdentifier("settings.modelState.downloading")

        case .paused:
            HStack(spacing: 6) {
                Button(action: onDownload) {
                    Label("Resume", systemImage: "play.fill")
                        .frame(width: primaryActionWidth)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                compactActionButton("Cancel", systemImage: "xmark", role: .cancel, action: onCancel)
            }
            .accessibilityIdentifier("settings.modelState.paused")

        case .downloaded:
            if !isDefault {
                Button {
                    onSetDefault()
                } label: {
                    Label("Use for \(mode.title)", systemImage: "checkmark.circle")
                        .frame(width: primaryActionWidth)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("settings.modelState.ready")
            }

        case .failed(let message):
            let failedState = ModelDownloadManager.DownloadState.failed(message)
            VStack(alignment: .trailing, spacing: 6) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)

                Button(action: onDownload) {
                    Label(failedState.recoveryActionTitle, systemImage: failedState.recoveryActionIcon)
                        .frame(width: primaryActionWidth)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .accessibilityIdentifier(
                "settings.modelState.\(failedState.accessibilityKey)"
            )
        }
    }

    @ViewBuilder
    private var secondaryActionsMenu: some View {
        if hasSecondaryActions {
            Menu {
                if canSetDefaultFromMenu {
                    Button {
                        onSetDefault()
                    } label: {
                        Label("Set as Default", systemImage: "checkmark.circle")
                    }
                }

                if canSetDefaultFromMenu && canRemoveFromMenu {
                    Divider()
                }

                if canRemoveFromMenu {
                    Button(role: .destructive) {
                        onRemove()
                    } label: {
                        Label("Remove Model...", systemImage: "trash")
                    }
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("More actions")
            .accessibilityIdentifier("settings.modelState.moreActions")
        }
    }

    private func compactActionButton(
        _ title: String,
        systemImage: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 24, height: 22)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(title)
        .accessibilityLabel(title)
    }

    private var hasSecondaryActions: Bool {
        canSetDefaultFromMenu || canRemoveFromMenu
    }

    private var canSetDefaultFromMenu: Bool {
        false
    }

    private var canRemoveFromMenu: Bool {
        state == .downloaded
    }

    private var primaryActionWidth: CGFloat {
        112
    }

    private func downloadProgressText(_ progress: ModelDownloadManager.DownloadProgress?) -> String {
        guard let progress else { return "Downloading" }
        guard let detailText = progress.detailText else { return progress.displayText }
        return "\(progress.displayText) · \(detailText)"
    }

    private var readinessBadge: some View {
        Label(state.shortStatusTitle, systemImage: state.shortStatusIcon)
            .font(MLXtraDesignSystem.Typography.microMedium)
            .foregroundStyle(state.statusTint)
            .accessibilityIdentifier("settings.modelState.\(state.accessibilityKey)")
    }

    @ViewBuilder
    private var recommendationBadge: some View {
        if isRecommended {
            Label("Best for this Mac", systemImage: "star.circle.fill")
                .font(MLXtraDesignSystem.Typography.microMedium)
                .foregroundStyle(.secondary)
        } else {
            Label(modelFit.alternativeTitle, systemImage: modelFit.systemImage)
                .font(MLXtraDesignSystem.Typography.microMedium)
                .foregroundStyle(modelFit.tint)
        }
    }

    private var modelFit: ModelFit {
        ModelFit.classify(
            estimatedMemoryGB: model.estimatedMemoryGB,
            hardwareMemoryGB: SystemHardware.currentMemoryGB
        )
    }

    private var rowTint: Color {
        isDefault ? .accentColor : .secondary
    }

    private var storageLabel: String {
        model.source.usesComponentBundle ? "MLXtra checkpoints" : "Hugging Face cache"
    }
}

struct ModelDetailLine: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)

            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}
