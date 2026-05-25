import SwiftUI

struct ToolCallView: View {
    let toolCall: ToolCall
    let isStreaming: Bool
    let hasGeneratedMedia: Bool
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(iconTint.opacity(isComplete ? 0.08 : 0.14))
                        .frame(width: 26, height: 26)

                    Image(systemName: toolCall.icon)
                        .font(.system(size: MLXtraDesignSystem.Icon.small, weight: .semibold))
                        .foregroundStyle(iconTint)
                }

                Text(toolCall.displayTitle)
                    .font(MLXtraDesignSystem.Typography.captionMedium)

                Spacer()

                Text(headerStatus)
                    .font(MLXtraDesignSystem.Typography.captionMedium)
                    .foregroundStyle(statusBadgeForeground)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(statusBadgeFill)
                    .clipShape(Capsule())

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: MLXtraDesignSystem.Icon.micro))
                    .foregroundStyle(.secondary)
            }

            if isExpanded, shouldShowDetails {
                VStack(alignment: .leading, spacing: 8) {
                    Text(detailTitle)
                        .font(MLXtraDesignSystem.Typography.microMedium)
                        .foregroundStyle(.secondary)
                    Text(toolCall.status)
                        .font(MLXtraDesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)

                    if !toolCall.displayDetails.isEmpty {
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(Array(toolCall.displayDetails.enumerated()), id: \.offset) { _, detail in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(detail.label)
                                        .font(MLXtraDesignSystem.Typography.microMedium)
                                        .foregroundStyle(.secondary)
                                    Text(detail.value)
                                        .font(MLXtraDesignSystem.Typography.caption)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .padding(.top, 2)
                    }
                }
                .padding(.leading, 20)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: MLXtraDesignSystem.Radius.card, style: .continuous)
                .fill(isComplete ? MLXtraDesignSystem.Surface.contentFill : MLXtraDesignSystem.Surface.tintFill(statusColor))
        )
        .overlay {
            RoundedRectangle(cornerRadius: MLXtraDesignSystem.Radius.card, style: .continuous)
                .stroke(isComplete ? MLXtraDesignSystem.Surface.quietHairline : statusColor.opacity(0.16), lineWidth: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        }
    }

    private var isImageGeneration: Bool {
        toolCall.icon == "photo" || toolCall.toolName.localizedCaseInsensitiveContains("image")
    }

    private var isWebSearch: Bool {
        toolCall.icon == "magnifyingglass" || toolCall.toolName.localizedCaseInsensitiveContains("search")
    }

    private var isAudioGeneration: Bool {
        toolCall.icon == "waveform" || toolCall.icon == "music.note" || toolCall.toolName.localizedCaseInsensitiveContains("speech") || toolCall.toolName.localizedCaseInsensitiveContains("music")
    }

    private var shouldShowDetails: Bool {
        !toolCall.status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !toolCall.displayDetails.isEmpty
    }

    private var isComplete: Bool {
        hasGeneratedMedia || !isStreaming
    }

    private var headerStatus: String {
        if hasGeneratedMedia || !isStreaming {
            if isWebSearch {
                return "Searched"
            }

            if isImageGeneration {
                return "Generated"
            }

            if isAudioGeneration {
                return "Created"
            }

            return "Done"
        }

        if isImageGeneration {
            return "Generating"
        }

        if isAudioGeneration {
            return "Creating"
        }

        if isWebSearch {
            return "Searching"
        }

        return toolCall.status
    }

    private var detailTitle: String {
        if isImageGeneration {
            return "Prompt"
        }

        if isWebSearch {
            return "Query"
        }

        return "Details"
    }

    private var statusColor: Color {
        if isWebSearch {
            return Color(red: 0.28, green: 0.55, blue: 0.95)
        }

        if isImageGeneration {
            return Color(red: 0.88, green: 0.34, blue: 0.68)
        }

        if isAudioGeneration {
            return Color(red: 0.42, green: 0.68, blue: 0.42)
        }

        return Color.accentColor
    }

    private var iconTint: Color {
        isComplete ? MLXtraDesignSystem.Palette.secondaryLabel : statusColor
    }

    private var statusBadgeForeground: Color {
        isComplete ? MLXtraDesignSystem.Palette.secondaryLabel : statusColor
    }

    private var statusBadgeFill: Color {
        isComplete ? Color.primary.opacity(0.045) : statusColor.opacity(0.10)
    }
}
