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
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: isCompact ? 78 : 120)
            } else {
                EmptyView()
            }
        default:
            EmptyView()
        }
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
            return "Downloading and activating local files. Choose your first model while setup finishes."
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
