import Foundation
import SwiftUI

struct RuntimeSetupStatusView: View {
    @ObservedObject var runtimeUpdateManager: RuntimeUpdateManager
    let isCompact: Bool

    @State private var didRequestBootstrap = false

    var body: some View {
        HStack(spacing: MLXtraDesignSystem.Spacing.xl) {
            statusIcon

            VStack(alignment: .leading, spacing: MLXtraDesignSystem.Spacing.xs) {
                Text(title)
                    .font(MLXtraDesignSystem.Typography.compactBodySemibold)

                Text(detail)
                    .font(MLXtraDesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(isCompact ? 1 : 2)
            }

            Spacer(minLength: MLXtraDesignSystem.Spacing.md)

            action
        }
        .padding(isCompact ? MLXtraDesignSystem.Spacing.xl : MLXtraDesignSystem.Spacing.xxl)
        .designContentSurface(cornerRadius: MLXtraDesignSystem.Radius.row)
        .onAppear {
            startSetupIfNeeded()
        }
        .onChange(of: runtimeUpdateManager.state) { _, _ in
            startSetupIfNeeded()
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        if showsSpinner {
            ProgressView()
                .controlSize(.small)
                .frame(width: 34, height: 34)
                .designTintSurface(.accentColor, cornerRadius: MLXtraDesignSystem.Radius.control)
        } else {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .designTintSurface(tint, cornerRadius: MLXtraDesignSystem.Radius.control)
        }
    }

    @ViewBuilder
    private var action: some View {
        switch runtimeUpdateManager.state {
        case .failed:
            Button {
                didRequestBootstrap = false
                runtimeUpdateManager.bootstrapStableRuntimeInBackground(reportFailures: true)
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        case .installed:
            EmptyView()
        case .installing(let progress):
            if let progress {
                runtimeProgressView(progress)
            } else if runtimeUpdateManager.installPhase == .activating,
                      let progress = runtimeUpdateManager.runtimeActivationProgress {
                runtimeActivationView(progress)
            } else {
                EmptyView()
            }
        default:
            EmptyView()
        }
    }

    private func runtimeProgressView(_ progress: Double) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: MLXtraDesignSystem.Spacing.sm) {
                Text("\(Int((progress * 100).rounded()))%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 34, alignment: .trailing)

                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: progressWidth)
            }
            .frame(width: progressPanelWidth, alignment: .trailing)

            if let progressStats {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(progressStats.transfer)
                        .frame(width: progressPanelWidth, alignment: .trailing)

                    Text(progressStats.rate)
                        .frame(width: progressPanelWidth, alignment: .trailing)
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.9)
                .frame(width: progressPanelWidth, alignment: .trailing)
            }
        }
        .frame(width: progressPanelWidth, alignment: .trailing)
    }

    private func runtimeActivationView(_ progress: RuntimeActivationProgress) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            ProgressView(value: progress.fractionCompleted)
                .progressViewStyle(.linear)
                .frame(width: progressWidth)

            VStack(alignment: .trailing, spacing: 1) {
                Text(progress.stepText)
                Text(progress.title)
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .minimumScaleFactor(0.9)
        }
        .frame(width: progressPanelWidth, alignment: .trailing)
    }

    private var title: String {
        if RuntimeManager.activeRuntimeManifest() != nil {
            return "MLXtra is ready"
        }

        switch runtimeUpdateManager.state {
        case .idle:
            return "Preparing setup"
        case .checking:
            return "Checking setup"
        case .available:
            return "Starting download"
        case .installing:
            return "Installing local files"
        case .installed:
            return "MLXtra is ready"
        case .failed:
            return "Setup needs attention"
        }
    }

    private var detail: String {
        if let manifest = RuntimeManager.activeRuntimeManifest() {
            return "Version \(manifest.runtimeVersion) is available for local models."
        }

        switch runtimeUpdateManager.state {
        case .idle:
            return "Connecting to the stable channel."
        case .checking:
            return "Finding the current release."
        case .available(let asset):
            return "Version \(asset.version) will download automatically."
        case .installing:
            switch runtimeUpdateManager.installPhase {
            case .verifying:
                return "Verifying local files. Choose your first model while setup finishes."
            case .activating:
                if let activationProgress = runtimeUpdateManager.runtimeActivationProgress {
                    return activationProgress.detail ?? activationProgress.title
                }
                return "Activating local files. Choose your first model while setup finishes."
            default:
                return "Downloading local files. Choose your first model while setup finishes."
            }
        case .installed(let version):
            return "Version \(version) is ready for local models."
        case .failed(let message):
            return message
        }
    }

    private var icon: String {
        switch runtimeUpdateManager.state {
        case .installed:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        default:
            return RuntimeManager.activeRuntimeManifest() == nil ? "arrow.down.circle.fill" : "checkmark.circle.fill"
        }
    }

    private var tint: Color {
        switch runtimeUpdateManager.state {
        case .installed:
            return MLXtraDesignSystem.Palette.success
        case .failed:
            return MLXtraDesignSystem.Palette.warning
        default:
            return RuntimeManager.activeRuntimeManifest() == nil ? .accentColor : MLXtraDesignSystem.Palette.success
        }
    }

    private var showsSpinner: Bool {
        switch runtimeUpdateManager.state {
        case .checking, .available, .installing:
            return RuntimeManager.activeRuntimeManifest() == nil
        default:
            return false
        }
    }

    private var progressWidth: CGFloat {
        isCompact ? 168 : 188
    }

    private var progressPanelWidth: CGFloat {
        isCompact ? 210 : 230
    }

    private var progressStats: RuntimeSetupProgressStats? {
        guard case .installing = runtimeUpdateManager.state,
              runtimeUpdateManager.installPhase == .downloading,
              let progress = runtimeUpdateManager.runtimeDownloadProgress else {
            return nil
        }

        let transfer: String
        if let totalBytes = progress.totalBytes {
            transfer = "\(Self.formattedBytes(progress.downloadedBytes)) of \(Self.formattedBytes(totalBytes))"
        } else {
            transfer = "\(Self.formattedBytes(progress.downloadedBytes)) downloaded"
        }

        var rateParts: [String] = []
        if let bytesPerSecond = progress.bytesPerSecond, bytesPerSecond > 0 {
            rateParts.append("\(Self.formattedBytes(Int64(bytesPerSecond)))/s")
        }
        if let estimatedSecondsRemaining = progress.estimatedSecondsRemaining {
            rateParts.append("\(Self.formattedDuration(estimatedSecondsRemaining)) left")
        }
        return RuntimeSetupProgressStats(
            transfer: transfer,
            rate: rateParts.isEmpty ? "Calculating speed" : rateParts.joined(separator: " · ")
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

    private func startSetupIfNeeded() {
        guard RuntimeManager.activeRuntimeManifest() == nil else {
            return
        }

        switch runtimeUpdateManager.state {
        case .idle:
            guard !didRequestBootstrap else {
                return
            }
            didRequestBootstrap = true
            runtimeUpdateManager.bootstrapStableRuntimeInBackground(reportFailures: true)
        case .available(let asset):
            runtimeUpdateManager.installRuntimeInBackground(asset)
        default:
            return
        }
    }
}

private struct RuntimeSetupProgressStats {
    let transfer: String
    let rate: String
}
