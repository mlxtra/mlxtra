import SwiftUI

struct RuntimeUpdateSection: View {
    @ObservedObject var manager: RuntimeUpdateManager

    var body: some View {
        switch manager.state {
        case .available(let asset):
            updateCard(
                title: "Runtime update available",
                detail: "Runtime \(asset.version), \(formatBytes(asset.sizeBytes))",
                icon: "arrow.triangle.2.circlepath.circle.fill",
                tint: .accentColor
            ) {
                Button {
                    Task {
                        await manager.installRuntime(asset)
                    }
                } label: {
                    Label("Install Runtime", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.borderedProminent)
            }
        case .installing:
            updateCard(
                title: "Installing runtime",
                detail: "Verifying and activating the downloaded runtime.",
                icon: "gearshape.2.fill",
                tint: .accentColor
            ) {
                ProgressView()
                    .controlSize(.small)
            }
        case .installed(let version):
            updateCard(
                title: "Runtime installed",
                detail: "Runtime \(version) is ready for compatible models.",
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
                    Task {
                        await manager.refreshStableChannel()
                    }
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

    private func formatBytes(_ bytes: Int64?) -> String {
        guard let bytes else { return "size unknown" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
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
