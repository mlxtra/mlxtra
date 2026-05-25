import AppKit
import SwiftUI

struct FirstRunAppIcon: View {
    let size: CGFloat

    var body: some View {
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct FirstRunBestChatModelView: View {
    let item: FirstRunStarterModel
    let onSelect: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: MLXtraDesignSystem.Spacing.xxl) {
            Image(systemName: item.icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 48, height: 48)
                .designTintSurface(Color.accentColor, cornerRadius: MLXtraDesignSystem.Radius.card)

            VStack(alignment: .leading, spacing: MLXtraDesignSystem.Spacing.sm) {
                HStack(spacing: MLXtraDesignSystem.Spacing.sm) {
                    if let badge = item.badge {
                        Text(badge)
                            .font(MLXtraDesignSystem.Typography.microMedium)
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, MLXtraDesignSystem.Spacing.sm)
                            .frame(height: 20)
                            .background(
                                Color.accentColor.opacity(0.10),
                                in: Capsule(style: .continuous)
                            )
                    }

                    Text(hardwareLabel)
                        .font(MLXtraDesignSystem.Typography.microMedium)
                        .foregroundStyle(.secondary)
                }

                Text(item.model.name)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text("Recommended for local Chat on this Mac. Download size \(formatSize(item.model.downloadSizeGB)); memory estimate \(memoryEstimateLabel).")
                    .font(MLXtraDesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: MLXtraDesignSystem.Spacing.md)

            Button(action: onSelect) {
                Label("Set Up Chat", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(MLXtraDesignSystem.Spacing.xxl)
        .designPanelSurface(cornerRadius: MLXtraDesignSystem.Radius.card)
        .help("Set up \(item.model.name) for Chat")
        .accessibilityElement(children: .combine)
    }

    private var hardwareLabel: String {
        "\(formatSize(SystemHardware.currentMemoryGB)) unified memory"
    }

    private var memoryEstimateLabel: String {
        item.model.estimatedMemoryGB.map(formatSize) ?? "unknown"
    }
}

struct FirstRunHeroVisual: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
            let phase = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate

            ZStack {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .stroke(ringColor(index: index), lineWidth: 1)
                        .frame(width: ringSize(index: index), height: ringSize(index: index))
                        .scaleEffect(ringScale(index: index, phase: phase))
                        .opacity(ringOpacity(index: index, phase: phase))
                }

                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 82, height: 82)

                Circle()
                    .stroke(Color.accentColor.opacity(0.24), lineWidth: 1)
                    .frame(width: 82, height: 82)

                FirstRunAppIcon(size: 58)

                ForEach(FirstRunOrbitItem.items) { item in
                    Image(systemName: item.icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(item.tint)
                        .frame(width: 34, height: 34)
                        .designTintSurface(item.tint, cornerRadius: MLXtraDesignSystem.Radius.control)
                        .offset(orbitOffset(for: item, phase: phase))
                }
            }
        }
    }

    private func ringSize(index: Int) -> CGFloat {
        CGFloat(112 + index * 32)
    }

    private func ringColor(index: Int) -> Color {
        switch index {
        case 0:
            return Color.accentColor.opacity(0.34)
        case 1:
            return MLXtraDesignSystem.Palette.success.opacity(0.20)
        default:
            return MLXtraDesignSystem.Palette.warning.opacity(0.16)
        }
    }

    private func ringScale(index: Int, phase: TimeInterval) -> CGFloat {
        guard !reduceMotion else { return 1 }
        let wave = sin(phase * 1.4 + Double(index) * 0.8)
        return 1 + CGFloat(wave) * 0.025
    }

    private func ringOpacity(index: Int, phase: TimeInterval) -> Double {
        guard !reduceMotion else { return 0.9 }
        let wave = sin(phase * 1.15 + Double(index) * 0.9)
        return 0.62 + (wave + 1) * 0.13
    }

    private func orbitOffset(for item: FirstRunOrbitItem, phase: TimeInterval) -> CGSize {
        let angle = CGFloat(item.baseAngle + (reduceMotion ? 0 : phase * item.speed))
        return CGSize(
            width: cos(angle) * item.radius,
            height: sin(angle) * item.radius
        )
    }
}

private struct FirstRunOrbitItem: Identifiable {
    let id: String
    let icon: String
    let tint: Color
    let radius: CGFloat
    let baseAngle: Double
    let speed: Double

    static let items = [
        FirstRunOrbitItem(id: "chat", icon: "bubble.left.and.bubble.right", tint: .accentColor, radius: 74, baseAngle: 0.15, speed: 0.32),
        FirstRunOrbitItem(id: "image", icon: "photo", tint: MLXtraDesignSystem.Palette.success, radius: 82, baseAngle: 2.25, speed: 0.24),
        FirstRunOrbitItem(id: "audio", icon: "waveform", tint: MLXtraDesignSystem.Palette.warning, radius: 78, baseAngle: 4.25, speed: 0.28)
    ]
}

struct FirstRunCapabilityPill: View {
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: MLXtraDesignSystem.Spacing.xs) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))

            Text(title)
                .font(MLXtraDesignSystem.Typography.captionMedium)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, MLXtraDesignSystem.Spacing.md)
        .frame(height: 28)
        .designContentSurface(cornerRadius: MLXtraDesignSystem.Radius.control)
    }
}

struct FirstRunStarterModelButton: View {
    let item: FirstRunStarterModel
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: MLXtraDesignSystem.Spacing.lg) {
                HStack(alignment: .center, spacing: MLXtraDesignSystem.Spacing.md) {
                    Image(systemName: item.icon)
                        .font(.system(size: MLXtraDesignSystem.Icon.medium, weight: .semibold))
                        .foregroundStyle(isHovered ? Color.accentColor : .secondary)
                        .frame(width: 28, height: 28)
                        .designTintSurface(isHovered ? Color.accentColor : .secondary, cornerRadius: MLXtraDesignSystem.Radius.control)

                    VStack(alignment: .leading, spacing: MLXtraDesignSystem.Spacing.xxs) {
                        Text(item.title)
                            .font(MLXtraDesignSystem.Typography.compactBodySemibold)
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text(formatSize(item.model.downloadSizeGB))
                            .font(MLXtraDesignSystem.Typography.microMedium)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)
                }

                Text(item.model.name)
                    .font(MLXtraDesignSystem.Typography.captionMedium)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(item.detail)
                    .font(MLXtraDesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: MLXtraDesignSystem.Spacing.xs) {
                    Text("Set up")
                        .font(MLXtraDesignSystem.Typography.captionMedium)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(Color.accentColor)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(MLXtraDesignSystem.Spacing.xl)
            .contentShape(RoundedRectangle(cornerRadius: MLXtraDesignSystem.Radius.row, style: .continuous))
        }
        .buttonStyle(FirstRunStarterModelButtonStyle(isHovered: isHovered))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: MLXtraDesignSystem.Motion.controlDuration)) {
                isHovered = hovering
            }
        }
        .help("Set up \(item.model.name)")
        .accessibilityLabel("Set up \(item.model.name)")
    }
}

private struct FirstRunStarterModelButtonStyle: ButtonStyle {
    let isHovered: Bool
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: MLXtraDesignSystem.Radius.row, style: .continuous)
        let isActive = isHovered || configuration.isPressed

        configuration.label
            .background(fill(isPressed: configuration.isPressed), in: shape)
            .overlay {
                shape.stroke(stroke(isActive: isActive), lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeInOut(duration: MLXtraDesignSystem.Motion.controlDuration), value: isHovered)
            .animation(.easeInOut(duration: MLXtraDesignSystem.Motion.hoverDuration), value: configuration.isPressed)
    }

    private func fill(isPressed: Bool) -> Color {
        if isPressed {
            return Color.accentColor.opacity(colorScheme == .dark ? 0.18 : 0.12)
        }

        if isHovered {
            return Color.accentColor.opacity(colorScheme == .dark ? 0.13 : 0.08)
        }

        return colorScheme == .dark
            ? Color.white.opacity(0.055)
            : Color(NSColor.controlBackgroundColor).opacity(0.66)
    }

    private func stroke(isActive: Bool) -> Color {
        if isActive {
            return Color.accentColor.opacity(colorScheme == .dark ? 0.32 : 0.26)
        }

        return MLXtraDesignSystem.Surface.quietHairline
    }
}
