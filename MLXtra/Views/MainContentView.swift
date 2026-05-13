import SwiftUI

struct MainContentView: View {
    @ObservedObject var viewModel: ChatViewModel

    var body: some View {
        if let chat = viewModel.selectedChat {
            if chat.messages.isEmpty {
                WelcomeView(viewModel: viewModel)
            } else {
                ChatView(viewModel: viewModel, chatId: chat.id)
            }
        } else {
            EmptyStateView()
        }
    }
}

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
                .symbolEffect(.pulse)

            Text("Select a chat to start")
                .font(.title2)
                .foregroundStyle(.secondary)

            Text("or create a new one with ⌘N")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MLXtraDesignSystem.Palette.windowBackground)
    }
}

#Preview {
    MainContentView(viewModel: ChatViewModel())
}
