import SwiftUI

struct ChatView: View {
    @ObservedObject var viewModel: ChatViewModel
    let chatId: UUID

    // Access chat through viewModel so updates are observed
    var chat: Chat? {
        viewModel.chats.first { $0.id == chatId }
    }

    private var streamingAssistantMessage: Message? {
        chat?.messages.last { !$0.isUser && $0.isStreaming }
    }

    private var hasStreamingProgressSurface: Bool {
        guard let message = streamingAssistantMessage else { return false }

        return !message.toolCalls.isEmpty
            || !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !message.imageURLs.isEmpty
            || !message.audioURLs.isEmpty
    }

    private var hasStreamingToolProgress: Bool {
        !(streamingAssistantMessage?.toolCalls.isEmpty ?? true)
    }

    private var shouldShowTypingIndicator: Bool {
        viewModel.isGenerating
            && !hasStreamingProgressSurface
            && !viewModel.isPythonLoading
            && !viewModel.isModelLoading
    }

    private var shouldShowModelLoading: Bool {
        (viewModel.isPythonLoading || viewModel.isModelLoading) && !hasStreamingToolProgress
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
                            if shouldShowTypingIndicator && message.id == streamingAssistantMessage?.id {
                                EmptyView()
                            } else {
                                MessageBubble(
                                    message: message,
                                    isStreaming: message.isStreaming
                                )
                                .id(message.id)
                            }
                        }

                        if shouldShowTypingIndicator {
                            TypingIndicator()
                                .id(streamingAssistantMessage?.id)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
                .onChange(of: viewModel.chats) { _, _ in
                    // Trigger update when chats array changes
                }
                .onChange(of: chat?.messages.count) { _, _ in
                    if let lastMessage = chat?.messages.last {
                        withAnimation {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: viewModel.isGenerating) { _, isGenerating in
                    // Auto-scroll when generation starts
                    if isGenerating, let lastMessage = chat?.messages.last {
                        withAnimation {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: chat?.messages.last?.content) { _, _ in
                    // Auto-scroll when message content updates during streaming
                    if viewModel.isGenerating, let lastMessage = chat?.messages.last {
                        withAnimation {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
            }

            // Loading indicator
            if shouldShowModelLoading {
                ModelLoadingView(message: viewModel.loadingMessage)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Input area
            ComposerView(viewModel: viewModel)
                .frame(maxWidth: 720)
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
        }
        .background(Color(NSColor.windowBackgroundColor))
    }
}

struct ModelLoadingView: View {
    let message: String

    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle())
                .controlSize(.small)

            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
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
