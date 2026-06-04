import SwiftUI

struct ModeDraftControls: View {
    let draft: ComposerDraft
    @ObservedObject var viewModel: ChatViewModel
    let onAttachReference: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var isLyricsFocused = false

    private let controlTextRailInset = MLXtraDesignSystem.Spacing.xxl

    private var promptIsEmpty: Bool {
        !viewModel.hasMusicDraftPrompt
    }

    private var lyricsAreEmpty: Bool {
        viewModel.musicLyricsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var shouldShowLyricsEditor: Bool {
        draft.showsMusicControls
            && viewModel.selectedMusicModelSupportsLyrics
            && viewModel.musicVocalMode != .instrumental
            && (
                viewModel.musicVocalMode == .vocals
                    || !lyricsAreEmpty
                    || viewModel.isMusicLyricsEditorVisible
                    || viewModel.musicComposerPrompt == .needsLyrics
            )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if draft.showsMusicControls && viewModel.selectedMusicModelSupportsLyrics {
                musicSetupRow
                    .padding(.horizontal, controlTextRailInset)
            }

            ForEach(draft.slots) { slot in
                ComposerDraftSlotRow(slot: slot) { action in
                    perform(slotAction: action)
                }
                .padding(.horizontal, controlTextRailInset)
            }

            if shouldShowLyricsEditor {
                lyricsEditor
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var musicSetupRow: some View {
        HStack(spacing: 10) {
            Text("Vocals")
                .font(MLXtraDesignSystem.Typography.captionMedium)
                .foregroundStyle(.secondary)

            Picker("", selection: vocalModeBinding) {
                ForEach(MusicVocalMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 300)

            Spacer(minLength: 0)
        }
    }

    private var vocalModeBinding: Binding<MusicVocalMode> {
        Binding(
            get: { viewModel.musicVocalMode },
            set: { viewModel.selectMusicVocalMode($0) }
        )
    }

    private func perform(slotAction: ComposerDraftSlotAction) {
        if slotAction == .attachReference {
            onAttachReference()
        } else {
            viewModel.performComposerSlotAction(slotAction)
        }
    }

    private var lyricsEditor: some View {
        VStack(alignment: .leading, spacing: MLXtraDesignSystem.Spacing.sm) {
            HStack {
                Spacer(minLength: 0)
                Button {
                    viewModel.rewriteMusicLyrics()
                } label: {
                    Label(lyricsButtonTitle, systemImage: "sparkles")
                }
                .font(MLXtraDesignSystem.Typography.captionMedium)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(promptIsEmpty || viewModel.isDraftingMusicLyrics)
            }
            .padding(.horizontal, controlTextRailInset)

            MultilineTextInput(
                text: $viewModel.musicLyricsText,
                placeholder: "Add lyrics...",
                isFocused: $isLyricsFocused,
                isEditable: !viewModel.isInputDisabled,
                submitsOnReturn: false,
                accessibilityIdentifier: "composer.musicLyricsInput",
                accessibilityLabel: "Music lyrics"
            )
            .frame(height: MLXtraDesignSystem.Layout.musicLyricsTextHeight)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, MLXtraDesignSystem.Spacing.xxl)
            .padding(.vertical, MLXtraDesignSystem.Spacing.xxs)
            .background {
                RoundedRectangle(cornerRadius: MLXtraDesignSystem.Radius.composerField, style: .continuous)
                    .fill(MLXtraDesignSystem.Surface.fieldFill(colorScheme: colorScheme))
            }
            .overlay {
                RoundedRectangle(cornerRadius: MLXtraDesignSystem.Radius.composerField, style: .continuous)
                    .stroke(
                        isLyricsFocused ? MLXtraDesignSystem.Surface.focusHairline : MLXtraDesignSystem.Surface.quietHairline,
                        lineWidth: MLXtraDesignSystem.Spacing.hairline
                    )
            }
        }
        .accessibilityIdentifier("composer.musicLyricsEditor")
    }

    private var lyricsButtonTitle: String {
        if viewModel.isDraftingMusicLyrics {
            return "Generating..."
        }
        return lyricsAreEmpty ? "Draft lyrics" : "Refresh lyrics"
    }
}

struct ComposerDraftSlotRow: View {
    let slot: ComposerDraftSlot
    let perform: (ComposerDraftSlotAction) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: slot.systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 22, height: 22)
                .designTintSurface(iconColor, cornerRadius: 6)

            VStack(alignment: .leading, spacing: 2) {
                Text(slot.title)
                    .font(MLXtraDesignSystem.Typography.captionMedium)

                if let subtitle = slot.subtitle {
                    Text(subtitle)
                        .font(MLXtraDesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            ForEach(slot.actions) { item in
                Button {
                    perform(item.action)
                } label: {
                    Label(item.title, systemImage: item.systemImage)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: MLXtraDesignSystem.Radius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: MLXtraDesignSystem.Radius.control, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        }
    }

    private var iconColor: Color {
        slot.tone == .needed ? Color.accentColor : Color.secondary
    }

    private var backgroundColor: Color {
        switch slot.tone {
        case .needed:
            return Color.accentColor.opacity(0.07)
        case .neutral:
            return Color.primary.opacity(0.035)
        }
    }

    private var borderColor: Color {
        switch slot.tone {
        case .needed:
            return Color.accentColor.opacity(0.14)
        case .neutral:
            return Color.primary.opacity(0.07)
        }
    }
}

struct SendActionButton: View {
    let isEnabled: Bool
    var title: String? = nil
    var systemImage: String = "arrow.up"
    var help: String = "Send message"
    var disabledHelp: String = "Type a message to send"
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: MLXtraDesignSystem.Icon.medium + 1, weight: .bold))
                .frame(width: MLXtraDesignSystem.Icon.composerButton, height: MLXtraDesignSystem.Icon.composerButton)
            .foregroundStyle(isEnabled ? Color.white : Color.secondary.opacity(0.65))
            .background {
                Circle()
                    .fill(background)
                    .overlay {
                        Circle()
                            .strokeBorder(borderColor, lineWidth: MLXtraDesignSystem.Spacing.hairline)
                    }
            }
            .shadow(
                color: shadowColor,
                radius: isEnabled ? (isHovered ? 7 : 4) : 0,
                x: 0,
                y: isHovered ? MLXtraDesignSystem.Spacing.xxs + 1 : MLXtraDesignSystem.Spacing.hairline
            )
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(isEnabled ? help : disabledHelp)
        .accessibilityIdentifier("composer.primaryAction")
        .accessibilityLabel(help)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: MLXtraDesignSystem.Motion.controlDuration)) {
                isHovered = hovering
            }
        }
    }

    private var background: AnyShapeStyle {
        if isEnabled {
            return AnyShapeStyle(Color.accentColor)
        }

        return AnyShapeStyle(Color.primary.opacity(0.06))
    }

    private var borderColor: Color {
        isEnabled ? Color.white.opacity(0.18) : MLXtraDesignSystem.Palette.separator.opacity(0.28)
    }

    private var shadowColor: Color {
        isEnabled ? MLXtraDesignSystem.Palette.accent.opacity(0.16) : Color.clear
    }
}

struct LocalEngineStatusPopover: View {
    let status: LocalEngineStatus
    let canFreeMemory: Bool
    let onOpenModels: () -> Void
    let onRestart: () -> Void
    let onFreeMemory: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: status.systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(iconTint)
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 4) {
                    Text(status.title)
                        .font(MLXtraDesignSystem.Typography.compactBodySemibold)

                    Text(status.detail)
                        .font(MLXtraDesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if status.primaryAction != nil || canFreeMemory {
                Divider()
            }

            if status.primaryAction == .openModels {
                Button {
                    onOpenModels()
                } label: {
                    Label("Open Models", systemImage: "square.grid.2x2")
                }
                .buttonStyle(.borderedProminent)
            }

            if status.primaryAction == .restart {
                Button {
                    onRestart()
                } label: {
                    Label("Restart", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
            }

            if canFreeMemory {
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        onFreeMemory()
                    } label: {
                        Label("Free Memory", systemImage: "memorychip")
                    }
                    .buttonStyle(.bordered)

                    Text("The model will load again when needed.")
                        .font(MLXtraDesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .frame(width: 280, alignment: .leading)
    }

    private var iconTint: Color {
        status.state == .ready ? MLXtraDesignSystem.Palette.secondaryLabel : status.tone.color
    }
}
