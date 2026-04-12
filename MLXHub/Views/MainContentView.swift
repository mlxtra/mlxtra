import SwiftUI

struct MainContentView: View {
    @ObservedObject var viewModel: ChatViewModel
    @FocusState private var isInputFocused: Bool

    var body: some View {
        Group {
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
}

struct ToolSelectorView: View {
    @ObservedObject var viewModel: ChatViewModel

    var body: some View {
        Menu {
            ForEach(Tool.allCases) { tool in
                Button(action: {
                    viewModel.selectTool(tool)
                }) {
                    HStack {
                        Image(systemName: tool.icon)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tool.rawValue)
                                .font(.system(size: 13))
                            Text(tool.subtitle)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }

                        if viewModel.selectedTool == tool {
                            Spacer()
                            Image(systemName: "checkmark")
                                .font(.system(size: 10))
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: viewModel.selectedTool.icon)
                    .font(.system(size: 11))
                Text(viewModel.selectedTool.rawValue)
                    .font(.system(size: 12))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(NSColor.controlColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

struct ModelSelectorView: View {
    @ObservedObject var viewModel: ChatViewModel

    var body: some View {
        Menu {
            ForEach(AIModel.allCases) { model in
                Button(action: {
                    viewModel.selectModel(model)
                }) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.displayName)
                                .font(.system(size: 13))
                            Text(model.subtitle)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }

                        if viewModel.selectedModel == model {
                            Spacer()
                            Image(systemName: "checkmark")
                                .font(.system(size: 10))
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(viewModel.selectedModel.displayName)
                    .font(.system(size: 12))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(NSColor.controlColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
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
        .background(.ultraThinMaterial)
    }
}

#Preview {
    MainContentView(viewModel: ChatViewModel())
}
