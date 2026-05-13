import AppKit
import SwiftUI

struct WelcomeView: View {
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.openSettings) private var openSettings
    @AppStorage(PromptConfiguration.hasSeenFirstRunGuideKey) private var hasSeenFirstRunGuide = false
    @AppStorage("MLXtra.pendingDownloadModelId") private var pendingDownloadModelId = ""
    @State private var welcomeMessage: String = ""

    private let welcomeMessages = [
        "Where should we start?",
        "What can I help you with?",
        "What would you like to explore?",
        "How can I assist you today?",
        "What are we working on?",
        "Ready when you are",
        "What's on your mind?",
        "What would you like to create?",
        "Ask me anything"
    ]

    private var userName: String {
        let fullName = NSFullUserName()
        let firstName = fullName.components(separatedBy: " ").first ?? fullName
        return firstName.isEmpty ? "there" : firstName
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Spacer(minLength: 0)

                greeting

                WelcomePromptChips { item in
                    viewModel.selectTool(item.tool)
                    if !item.prompt.isEmpty {
                        viewModel.inputText = item.prompt
                    }
                }
                .frame(maxWidth: MLXtraDesignSystem.Layout.messageMaxWidth)

                if !hasSeenFirstRunGuide {
                    FirstRunGuideView(
                        modelName: viewModel.activeModelProfile.name,
                        onOpenModels: {
                            pendingDownloadModelId = viewModel.activeModelProfile.modelId
                            openSettings()
                        },
                        onDeepResearch: {
                            viewModel.selectTool(.research)
                            hasSeenFirstRunGuide = true
                        },
                        onDismiss: {
                            hasSeenFirstRunGuide = true
                        }
                    )
                    .frame(maxWidth: MLXtraDesignSystem.Layout.messageMaxWidth)
                }

                Spacer(minLength: MLXtraDesignSystem.Spacing.loose)
            }
            .frame(maxWidth: MLXtraDesignSystem.Layout.messageMaxWidth, maxHeight: .infinity, alignment: .leading)
            .padding(.horizontal, MLXtraDesignSystem.Layout.chatHorizontalPadding)

            ComposerView(viewModel: viewModel)
                .frame(maxWidth: MLXtraDesignSystem.Layout.composerMaxWidth)
                .padding(.horizontal, MLXtraDesignSystem.Layout.chatHorizontalPadding)
                .padding(.bottom, MLXtraDesignSystem.Layout.floatingAccessoryBottomPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MLXtraDesignSystem.Palette.windowBackground)
    }

    private var greeting: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hi \(userName)")
                .font(MLXtraDesignSystem.Typography.welcomeDisplay)
                .foregroundStyle(.primary)

            Text(welcomeMessage)
                .font(MLXtraDesignSystem.Typography.welcomeSecondary)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: MLXtraDesignSystem.Layout.messageMaxWidth, alignment: .leading)
        .padding(.bottom, MLXtraDesignSystem.Spacing.loose - MLXtraDesignSystem.Spacing.xs)
        .onAppear {
            chooseWelcomeMessage()
        }
    }

    private func chooseWelcomeMessage() {
        var newMessage = welcomeMessages.randomElement() ?? welcomeMessages[0]

        if welcomeMessage == newMessage {
            let remaining = welcomeMessages.filter { $0 != welcomeMessage }
            if !remaining.isEmpty {
                newMessage = remaining.randomElement() ?? welcomeMessages[0]
            }
        }

        welcomeMessage = newMessage
    }
}

private struct WelcomePromptItem: Identifiable {
    let title: String
    let icon: String
    let tool: Tool
    let prompt: String

    var id: String { title }
}

private struct WelcomePromptChips: View {
    let onSelect: (WelcomePromptItem) -> Void

    private let items: [WelcomePromptItem] = [
        WelcomePromptItem(
            title: "Ask",
            icon: "bubble.left.and.bubble.right",
            tool: .chat,
            prompt: ""
        ),
        WelcomePromptItem(
            title: "Analyze image",
            icon: "eye",
            tool: .chat,
            prompt: ""
        ),
        WelcomePromptItem(
            title: "Create image",
            icon: "photo",
            tool: .image,
            prompt: ""
        ),
        WelcomePromptItem(
            title: "Create speech",
            icon: "waveform",
            tool: .tts,
            prompt: ""
        ),
        WelcomePromptItem(
            title: "Make music",
            icon: "music.note",
            tool: .music,
            prompt: ""
        ),
        WelcomePromptItem(
            title: "Research",
            icon: "magnifyingglass",
            tool: .research,
            prompt: ""
        )
    ]

    private let columns = [
        GridItem(.adaptive(minimum: 150), spacing: 8)
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(items) { item in
                WelcomePromptChip(item: item) {
                    onSelect(item)
                }
            }
        }
    }
}

private struct WelcomePromptChip: View {
    let item: WelcomePromptItem
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: MLXtraDesignSystem.Spacing.md) {
                Image(systemName: item.icon)
                    .font(.system(size: MLXtraDesignSystem.Icon.medium, weight: .semibold))
                    .foregroundStyle(isHovered ? Color.accentColor : .secondary)
                    .frame(
                        width: MLXtraDesignSystem.Icon.large + MLXtraDesignSystem.Spacing.xxs,
                        height: MLXtraDesignSystem.Icon.large + MLXtraDesignSystem.Spacing.xxs
                    )

                Text(item.title)
                    .font(MLXtraDesignSystem.Typography.compactBodySemibold)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, MLXtraDesignSystem.Spacing.xl)
            .frame(height: 38)
            .contentShape(RoundedRectangle(cornerRadius: MLXtraDesignSystem.Radius.control, style: .continuous))
        }
        .buttonStyle(WelcomePromptChipButtonStyle(isHovered: isHovered))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: MLXtraDesignSystem.Motion.controlDuration)) {
                isHovered = hovering
            }
        }
        .help(item.title)
        .accessibilityLabel(item.title)
        .accessibilityHint("Starts \(item.title)")
        .accessibilityIdentifier("welcome.tool.\(item.tool.id)")
    }
}

private struct WelcomePromptChipButtonStyle: ButtonStyle {
    let isHovered: Bool
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: MLXtraDesignSystem.Radius.control, style: .continuous)
        let isActive = isHovered || configuration.isPressed

        configuration.label
            .background(chipFill(isPressed: configuration.isPressed), in: shape)
            .overlay {
                shape.stroke(chipStroke(isActive: isActive), lineWidth: 1)
            }
            .shadow(
                color: Color.black.opacity(isHovered ? 0.055 : 0),
                radius: isHovered ? 7 : 0,
                x: 0,
                y: isHovered ? 2 : 0
            )
            .scaleEffect(configuration.isPressed ? 0.985 : (isHovered ? 1.01 : 1))
            .animation(.easeInOut(duration: MLXtraDesignSystem.Motion.controlDuration), value: isHovered)
            .animation(.easeInOut(duration: MLXtraDesignSystem.Motion.hoverDuration), value: configuration.isPressed)
    }

    private func chipFill(isPressed: Bool) -> Color {
        if isPressed {
            return Color.accentColor.opacity(colorScheme == .dark ? 0.18 : 0.12)
        }

        if isHovered {
            return Color.accentColor.opacity(colorScheme == .dark ? 0.14 : 0.08)
        }

        return colorScheme == .dark
            ? Color.white.opacity(0.075)
            : Color(NSColor.controlBackgroundColor).opacity(0.86)
    }

    private func chipStroke(isActive: Bool) -> Color {
        if isActive {
            return Color.accentColor.opacity(colorScheme == .dark ? 0.34 : 0.28)
        }

        return colorScheme == .dark
            ? Color.white.opacity(0.14)
            : MLXtraDesignSystem.Surface.hairline
    }
}

private struct FirstRunGuideView: View {
    let modelName: String
    let onOpenModels: () -> Void
    let onDeepResearch: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 30)
                .designTintSurface(Color.accentColor, cornerRadius: MLXtraDesignSystem.Radius.control)

            VStack(alignment: .leading, spacing: 3) {
                Text("Start with \(modelName)")
                    .font(MLXtraDesignSystem.Typography.compactBodySemibold)
                Text("Download once, then chat locally. Research uses live web results when selected.")
                    .font(MLXtraDesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            Button {
                onOpenModels()
            } label: {
                Label("Open Models", systemImage: "square.grid.2x2")
            }
            .buttonStyle(.borderedProminent)

            Button {
                onDeepResearch()
            } label: {
                Label("Research", systemImage: "magnifyingglass")
            }
            .buttonStyle(.bordered)

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
        }
        .padding(12)
        .designPanelSurface(cornerRadius: MLXtraDesignSystem.Radius.card)
    }
}

#Preview {
    WelcomeView(viewModel: ChatViewModel())
}
