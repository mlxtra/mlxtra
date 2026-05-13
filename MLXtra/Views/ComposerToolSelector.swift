import SwiftUI

struct ToolSelectorInline: View {
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var downloadManager = ModelDownloadManager.shared
    @State private var isShowingPopover = false

    private var isActive: Bool {
        viewModel.selectedTool != .auto
    }

    var body: some View {
        Button(action: {
            isShowingPopover.toggle()
        }) {
            HStack(spacing: 6) {
                Image(systemName: viewModel.selectedTool.icon)
                    .font(.system(size: MLXtraDesignSystem.Icon.regular))
                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                Text(viewModel.selectedTool.rawValue)
                    .font(MLXtraDesignSystem.Typography.compactBody)
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.down")
                    .font(.system(size: MLXtraDesignSystem.Icon.micro))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(MLXtraDesignSystem.Surface.controlFill(colorScheme: colorScheme))
                    .overlay(
                        Capsule()
                            .stroke(isActive ? Color.accentColor.opacity(0.18) : MLXtraDesignSystem.Surface.quietHairline, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isInputDisabled)
        .popover(isPresented: $isShowingPopover, arrowEdge: .bottom) {
            ToolSelectorPopover(
                viewModel: viewModel,
                downloadManager: downloadManager,
                isPresented: $isShowingPopover
            )
            .frame(width: 300)
        }
        .onAppear {
            downloadManager.refreshStatuses()
        }
        .fixedSize()
        .accessibilityIdentifier("composer.toolSelector")
    }
}

struct ToolSelectorPopover: View {
    @ObservedObject var viewModel: ChatViewModel
    @ObservedObject var downloadManager: ModelDownloadManager
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Tool.allCases, id: \.id) { tool in
                ToolRow(
                    tool: tool,
                    isSelected: viewModel.selectedTool == tool,
                    state: viewModel.downloadRequirement(for: tool).map { downloadManager.state(for: $0) },
                    action: {
                        viewModel.selectTool(tool)
                        downloadManager.refreshStatuses()
                        isPresented = false
                    }
                )
            }
        }
        .padding(.vertical, 6)
        .designPanelSurface(cornerRadius: 14)
        .shadow(color: Color.black.opacity(0.08), radius: 16, x: 0, y: 4)
    }
}

struct ToolRow: View {
    let tool: Tool
    let isSelected: Bool
    let state: ModelDownloadManager.DownloadState?
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: tool.icon)
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(tool.rawValue)
                        .font(MLXtraDesignSystem.Typography.compactBodyMedium)
                        .foregroundStyle(isSelected ? Color.accentColor : .primary)
                    Text(tool.subtitle)
                        .font(MLXtraDesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 6) {
                    readinessBadge

                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isHovered ? MLXtraDesignSystem.Surface.hoverFill : Color.clear)
        .background(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
        .onHover { hovering in
            isHovered = hovering
        }
        .accessibilityIdentifier("tool.\(tool.id)")
    }

    @ViewBuilder
    private var readinessBadge: some View {
        switch state {
        case .downloaded:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .font(MLXtraDesignSystem.Typography.microMedium)
                .foregroundStyle(MLXtraDesignSystem.Palette.secondaryLabel)
                .labelStyle(.titleAndIcon)
        case .downloading:
            Label("Loading", systemImage: "arrow.down.circle.fill")
                .font(MLXtraDesignSystem.Typography.microMedium)
                .foregroundStyle(Color.accentColor)
                .labelStyle(.titleAndIcon)
        case .paused:
            Label("Paused", systemImage: "pause.circle.fill")
                .font(MLXtraDesignSystem.Typography.microMedium)
                .foregroundStyle(Color.orange)
                .labelStyle(.titleAndIcon)
        case .failed(let message):
            let failedState = ModelDownloadManager.DownloadState.failed(message)
            Label(failedState.failureBadgeTitle, systemImage: failedState.failureBadgeIcon)
                .font(MLXtraDesignSystem.Typography.microMedium)
                .foregroundStyle(failedState.failureBadgeTint)
                .labelStyle(.titleAndIcon)
        case .notDownloaded:
            Label("Missing", systemImage: "arrow.down.circle")
                .font(MLXtraDesignSystem.Typography.microMedium)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
        case nil:
            EmptyView()
        }
    }
}


private extension ModelDownloadManager.DownloadState {
    var failureBadgeTitle: String {
        isRepairableFailure ? "Repair" : "Failed"
    }

    var failureBadgeIcon: String {
        isRepairableFailure ? "wrench.and.screwdriver.fill" : "exclamationmark.triangle.fill"
    }

    var failureBadgeTint: Color {
        isRepairableFailure ? .orange : .red
    }
}
