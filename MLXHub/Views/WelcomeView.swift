import SwiftUI

struct WelcomeView: View {
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.openSettings) private var openSettings
    @AppStorage(PromptConfiguration.hasSeenFirstRunGuideKey) private var hasSeenFirstRunGuide = false
    @AppStorage("MLXHub.pendingDownloadModelId") private var pendingDownloadModelId = ""
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
        "Let's build something amazing",
        "Ask me anything"
    ]

    private var userName: String {
        let fullName = NSFullUserName()
        let firstName = fullName.components(separatedBy: " ").first ?? fullName
        return firstName.isEmpty ? "there" : firstName
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            greeting

            WelcomePromptChips { item in
                viewModel.selectTool(item.tool)
                viewModel.inputText = item.prompt
            }
            .frame(maxWidth: 720)
            .padding(.horizontal, 24)
            .padding(.bottom, 16)

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
                .frame(maxWidth: 720)
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }

            ComposerView(viewModel: viewModel)
                .frame(maxWidth: 720)
                .padding(.horizontal, 24)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var greeting: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hi \(userName)")
                .font(.system(size: 42, weight: .regular))
                .foregroundStyle(.primary)

            Text(welcomeMessage)
                .font(.system(size: 42, weight: .regular))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: 720, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.bottom, 48)
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
            prompt: "Help me think through "
        ),
        WelcomePromptItem(
            title: "Analyze image",
            icon: "eye",
            tool: .chat,
            prompt: "Look at the attached image and tell me what stands out."
        ),
        WelcomePromptItem(
            title: "Create image",
            icon: "photo",
            tool: .image,
            prompt: "Create an image of "
        ),
        WelcomePromptItem(
            title: "Create speech",
            icon: "waveform",
            tool: .tts,
            prompt: "Create speech from this text: "
        ),
        WelcomePromptItem(
            title: "Make music",
            icon: "music.note",
            tool: .music,
            prompt: "Create an instrumental "
        ),
        WelcomePromptItem(
            title: "Research",
            icon: "magnifyingglass",
            tool: .research,
            prompt: "Research the latest information about "
        )
    ]

    private let columns = [
        GridItem(.adaptive(minimum: 150), spacing: 8)
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(items) { item in
                Button {
                    onSelect(item)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: item.icon)
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 18, height: 18)

                        Text(item.title)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)

                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 11)
                    .frame(height: 36)
                    .background(.thinMaterial.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
                .help(item.prompt)
            }
        }
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
                .background(Color.accentColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text("Start with \(modelName)")
                    .font(.system(size: 13, weight: .semibold))
                Text("Download once, then chat locally. Deep Research can use live web results when selected.")
                    .font(.system(size: 12))
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
                Label("Deep Research", systemImage: "magnifyingglass")
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
        .background(.thinMaterial.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }
}

#Preview {
    WelcomeView(viewModel: ChatViewModel())
}
