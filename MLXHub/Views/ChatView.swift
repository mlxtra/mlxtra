import SwiftUI

struct ChatView: View {
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.openSettings) private var openSettings
    @State private var composerHeight: CGFloat = 118
    let chatId: UUID

    private let bottomAnchorID = "chat-bottom-anchor"
    private var transcriptBottomSpacerHeight: CGFloat {
        max(
            MLXHubDesignSystem.Layout.defaultTranscriptBottomSpacer,
            composerHeight
                + MLXHubDesignSystem.Layout.floatingAccessoryBottomPadding
                + MLXHubDesignSystem.Layout.composerTranscriptGap
        )
    }

    // Access chat through viewModel so updates are observed
    var chat: Chat? {
        viewModel.chats.first { $0.id == chatId }
    }

    private var streamingAssistantMessage: Message? {
        chat?.messages.last { !$0.isUser && $0.isStreaming }
    }

    private var hasStreamingProgressSurface: Bool {
        streamingAssistantMessage != nil
    }

    private var shouldShowTypingIndicator: Bool {
        viewModel.isGenerating
            && !hasStreamingProgressSurface
            && !viewModel.isPythonLoading
            && !viewModel.isModelLoading
    }

    private var latestMessageContent: String {
        chat?.messages.last?.content ?? ""
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollViewReader { proxy in
                transcriptScrollView
                    .onAppear {
                        DispatchQueue.main.async {
                            scrollToBottom(proxy)
                        }
                    }
                    .onChange(of: chat?.messages.count) { _, _ in
                        scrollToBottom(proxy)
                    }
                    .onChange(of: viewModel.isGenerating) { _, _ in
                        scrollToBottom(proxy)
                    }
                    .onChange(of: latestMessageContent) { _, _ in
                        scrollToBottom(proxy)
                    }
                    .onChange(of: composerHeight) { _, _ in
                        scrollToBottom(proxy)
                    }
            }

            ComposerView(viewModel: viewModel)
                .frame(maxWidth: MLXHubDesignSystem.Layout.composerMaxWidth)
                .padding(.horizontal, MLXHubDesignSystem.Layout.chatHorizontalPadding)
                .padding(.bottom, MLXHubDesignSystem.Layout.floatingAccessoryBottomPadding)
                .background {
                    GeometryReader { proxy in
                        Color.clear
                            .preference(key: ChatComposerHeightPreferenceKey.self, value: proxy.size.height)
                    }
                }
        }
        .onPreferenceChange(ChatComposerHeightPreferenceKey.self) { height in
            guard height > 0 else { return }
            composerHeight = height
        }
        .background(MLXHubDesignSystem.Palette.windowBackground)
    }

    @ViewBuilder
    private var transcriptScrollView: some View {
        let scrollView = ScrollView {
            LazyVStack(spacing: MLXHubDesignSystem.Spacing.xl) {
                ForEach(chat?.messages ?? []) { message in
                    MessageBubble(
                        message: message,
                        isStreaming: message.isStreaming,
                        streamingContent: viewModel.streamingContent(for: message.id),
                        onOpenModels: { openSettings() },
                        onRestartLocalEngine: viewModel.restartLocalEngine
                    )
                    .id(message.id)
                }

                if shouldShowTypingIndicator {
                    TypingIndicator()
                        .id(streamingAssistantMessage?.id)
                }

                Color.clear
                    .frame(height: transcriptBottomSpacerHeight)
                    .id(bottomAnchorID)
            }
            .padding(.top, MLXHubDesignSystem.Layout.chatHorizontalPadding)
            .frame(maxWidth: MLXHubDesignSystem.Layout.transcriptMaxWidth, alignment: .leading)
            .padding(.horizontal, MLXHubDesignSystem.Layout.transcriptHorizontalPadding)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .accessibilityIdentifier("chat.transcript")

        if #available(macOS 26.0, *) {
            scrollView.scrollEdgeEffectStyle(.hard, for: .bottom)
        } else {
            scrollView
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            proxy.scrollTo(bottomAnchorID, anchor: .bottom)
        }
    }
}

private struct ChatComposerHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct TypingIndicator: View {
    @State private var animating = false

    var body: some View {
        HStack(alignment: .top, spacing: MLXHubDesignSystem.Spacing.xl) {
            HStack(spacing: MLXHubDesignSystem.Spacing.md) {
                Text("Responding")
                    .font(MLXHubDesignSystem.Typography.compactBodyMedium)
                    .foregroundStyle(.secondary)

                HStack(spacing: MLXHubDesignSystem.Spacing.xs) {
                    ForEach(0..<3) { index in
                        Circle()
                            .fill(Color.secondary)
                            .frame(width: 5, height: 5)
                            .scaleEffect(animating ? 1.0 : 0.55)
                            .opacity(animating ? 1.0 : 0.45)
                            .animation(
                                .easeInOut(duration: 0.55)
                                .repeatForever(autoreverses: true)
                                .delay(Double(index) * 0.16),
                                value: animating
                            )
                    }
                }
            }
            .padding(.horizontal, MLXHubDesignSystem.Spacing.xl)
            .padding(.vertical, MLXHubDesignSystem.Spacing.md)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: MLXHubDesignSystem.Radius.media))
            .overlay(
                RoundedRectangle(cornerRadius: MLXHubDesignSystem.Radius.media)
                    .stroke(MLXHubDesignSystem.Surface.hairline, lineWidth: MLXHubDesignSystem.Spacing.hairline)
            )

            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            animating = true
        }
    }
}

#Preview {
    let vm = ChatViewModel()
    if let chat = vm.selectedChat {
        ChatView(viewModel: vm, chatId: chat.id)
    } else {
        Text("No chat available")
    }
}
