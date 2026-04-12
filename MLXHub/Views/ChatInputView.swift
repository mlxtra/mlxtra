import SwiftUI

struct ChatInputView: View {
    @ObservedObject var viewModel: ChatViewModel
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(spacing: 12) {
                // Cancel button during generation
                if viewModel.isGenerating {
                    Button(action: {
                        viewModel.cancelGeneration()
                    }) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(Color.red)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Stop generating")
                }

                // Text input
                TextEditor(text: $viewModel.inputText)
                    .font(.system(size: 14))
                    .lineSpacing(4)
                    .focused($isFocused)
                    .frame(minHeight: 36, maxHeight: 120)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(NSColor.textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isFocused ? Color.accentColor : Color.clear, lineWidth: 1)
                    )
                    .disabled(viewModel.isInputDisabled)
                    .opacity(viewModel.isInputDisabled ? 0.6 : 1.0)

                // Send button
                Button(action: {
                    viewModel.sendMessage()
                }) {
                    Image(systemName: viewModel.isGenerating ? "hourglass" : "arrow.up")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(
                            viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isInputDisabled
                            ? Color.secondary.opacity(0.3)
                            : Color.accentColor
                        )
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(
                    viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || viewModel.isInputDisabled
                )
                .keyboardShortcut(.return, modifiers: .command)
                .help(viewModel.isGenerating ? "Generating..." : "Send message (⌘Return)")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
        }
    }
}

#Preview {
    ChatInputView(viewModel: ChatViewModel())
}
