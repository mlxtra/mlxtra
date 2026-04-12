import SwiftUI

struct ChatView: View {
    @ObservedObject var viewModel: ChatViewModel
    let chatId: UUID

    // Access chat through viewModel so updates are observed
    var chat: Chat? {
        viewModel.chats.first { $0.id == chatId }
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
                                isStreaming: message.isStreaming
                            )
                            .id(message.id)
                        }

                        if viewModel.isGenerating {
                            TypingIndicator()
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
            if viewModel.isPythonLoading || viewModel.isModelLoading {
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
        HStack(spacing: 4) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 6, height: 6)
                    .scaleEffect(animating ? 1.0 : 0.5)
                    .opacity(animating ? 1.0 : 0.5)
                    .animation(
                        .easeInOut(duration: 0.5)
                        .repeatForever(autoreverses: true)
                        .delay(Double(index) * 0.15),
                        value: animating
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 48)
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
