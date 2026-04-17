import SwiftUI

struct WelcomeView: View {
    @ObservedObject var viewModel: ChatViewModel
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

#Preview {
    WelcomeView(viewModel: ChatViewModel())
}
