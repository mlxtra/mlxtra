import SwiftUI

struct ChatView: View {
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.openSettings) private var openSettings
    let chatId: UUID

    private let bottomAnchorID = "chat-bottom-anchor"

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

    var body: some View {
        VStack(spacing: 0) {
            // Chat title in toolbar area
            HStack {
                Spacer()
                Text(chat?.title ?? "Chat")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.vertical, 8)
            .background(Color(NSColor.windowBackgroundColor))

            // Messages list
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 16) {
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
                            .frame(height: 1)
                            .id(bottomAnchorID)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .onAppear {
                    DispatchQueue.main.async {
                        scrollToBottom(proxy)
                    }
                }
                .onChange(of: chat?.messages.count) { _, _ in
                    scrollToBottom(proxy)
                }
                .onChange(of: viewModel.isGenerating) { _, isGenerating in
                    if isGenerating {
                        scrollToBottom(proxy)
                    }
                }
            }

            // Input area
            ComposerView(viewModel: viewModel)
                .frame(maxWidth: 720)
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            proxy.scrollTo(bottomAnchorID, anchor: .bottom)
        }
    }
}

struct TypingIndicator: View {
    @State private var animating = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkle")
                .font(.system(size: 14))
                .foregroundStyle(Color.white)
                .frame(width: 28, height: 28)
                .background(Color.accentColor)
                .clipShape(Circle())

            HStack(spacing: 8) {
                Text("Responding")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

                HStack(spacing: 4) {
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
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color(NSColor.separatorColor).opacity(0.35), lineWidth: 1)
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
