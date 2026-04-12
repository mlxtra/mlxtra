import SwiftUI
import UniformTypeIdentifiers

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
        // Extract first name from full name
        let firstName = fullName.components(separatedBy: " ").first ?? fullName
        return firstName.isEmpty ? "there" : firstName
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Greeting
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
                // Pick a random message, avoiding the same one twice in a row
                var newMessage = welcomeMessages.randomElement() ?? welcomeMessages[0]
                if welcomeMessage == newMessage {
                    // If same as current, pick another
                    let remaining = welcomeMessages.filter { $0 != welcomeMessage }
                    if !remaining.isEmpty {
                        newMessage = remaining.randomElement() ?? welcomeMessages[0]
                    }
                }
                    welcomeMessage = newMessage
            }

            // Input area
            ComposerView(viewModel: viewModel)
                .frame(maxWidth: 720)
                .padding(.horizontal, 24)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
}
}

struct ComposerView: View {
    @ObservedObject var viewModel: ChatViewModel
    @FocusState private var isFocused: Bool

    private func showFilePicker() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = true
        openPanel.allowedContentTypes = [.image, .png, .jpeg, .tiff, .gif, .bmp]
        openPanel.message = "Select images to attach"
        openPanel.prompt = "Attach"

        if openPanel.runModal() == .OK {
            viewModel.selectedImagePaths.append(contentsOf: openPanel.urls)
        }
    }

    private func removeImage(at index: Int) {
        if index < viewModel.selectedImagePaths.count {
            viewModel.selectedImagePaths.remove(at: index)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Selected image thumbnails (if any)
            if !viewModel.selectedImagePaths.isEmpty {
                HStack(spacing: 12) {
                    ForEach(0..<viewModel.selectedImagePaths.count, id: \.self) { index in
                        let url = viewModel.selectedImagePaths[index]
                        ImageThumbnailView(
                            imageURL: url,
                            filename: url.lastPathComponent,
                            onRemove: { removeImage(at: index) }
                        )
                    }
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, -8)
            }

            // Text input area with Shift+Enter for new line, Enter to submit
            MultilineTextInput(text: $viewModel.inputText, onSubmit: {
                viewModel.sendMessage()
            })
                .frame(minHeight: viewModel.hasSelectedImages ? 20 : 32, maxHeight: 80)
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 4)

            // Divider
            Divider()
                .padding(.horizontal, 18)

            // Footer with controls
            HStack(spacing: 8) {
                // Left side: Attach + Tool selector
                Button(action: {
                    showFilePicker()
                }) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Attach file")

                // Tool selector (moved to left)
                ToolSelectorInline(viewModel: viewModel)

                Spacer()

                // Right side: Model selector + Voice
                ModelSelectorInline(viewModel: viewModel)

                Button(action: {}) {
                    Image(systemName: "mic")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Voice input")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .shadow(color: Color(NSColor.shadowColor).opacity(0.2), radius: 16, x: 0, y: 4)
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .stroke(Color(NSColor.separatorColor).opacity(0.5), lineWidth: 1)
        )
    }
}

struct ToolSelectorInline: View {
    @ObservedObject var viewModel: ChatViewModel
    @State private var isShowingPopover = false

    private var isActive: Bool {
        viewModel.selectedTool != .auto
    }

    var body: some View {
        Button(action: {
            isShowingPopover.toggle()
        }) {
            HStack(spacing: 6) {
                Image(systemName: viewModel.selectedTool.icon)
                    .font(.system(size: 14))
                Text(viewModel.selectedTool.rawValue)
                    .font(.system(size: 13))
                Image(systemName: "chevron.down")
                    .font(.system(size: 10))
            }
            .foregroundStyle(isActive ? Color.accentColor : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(isActive ? Color.accentColor.opacity(0.15) : Color(NSColor.controlColor))
                    .overlay(
                        Capsule()
                            .stroke(isActive ? Color.accentColor : Color.clear, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isShowingPopover, arrowEdge: .bottom) {
            ToolSelectorPopover(viewModel: viewModel, isPresented: $isShowingPopover)
                .frame(width: 240)
        }
        .fixedSize()
    }
}

struct ToolSelectorPopover: View {
    @ObservedObject var viewModel: ChatViewModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Tool.allCases, id: \.id) { tool in
                ToolRow(
                    tool: tool,
                    isSelected: viewModel.selectedTool == tool,
                    action: {
                        viewModel.selectTool(tool)
                        isPresented = false
                    }
                )
            }
        }
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color(NSColor.separatorColor).opacity(0.3), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.1), radius: 16, x: 0, y: 4)
        )
    }
}

struct ToolRow: View {
    let tool: Tool
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: tool.icon)
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(tool.rawValue)
                        .font(.system(size: 13))
                        .foregroundStyle(isSelected ? Color.accentColor : .primary)
                    Text(tool.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isHovered ? Color(NSColor.selectedControlColor).opacity(0.1) : Color.clear)
        .background(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

struct ModelSelectorInline: View {
    @ObservedObject var viewModel: ChatViewModel

    var body: some View {
        Menu {
            ForEach(AIModel.allCases, id: \.id) { model in
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
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(viewModel.selectedModel.displayName)
                    .font(.system(size: 13))
                Image(systemName: "chevron.down")
                    .font(.system(size: 10))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

struct ImageThumbnailView: View {
    let imageURL: URL
    let filename: String
    let onRemove: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: {}) {
            ZStack(alignment: .topTrailing) {
                Image(nsImage: NSImage(contentsOf: imageURL) ?? NSImage())
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 80, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                if isHovered {
                    Button(action: onRemove) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.white)
                            .shadow(radius: 2)
                    }
                    .buttonStyle(.plain)
                    .background(Color.black.opacity(0.5))
                    .clipShape(Circle())
                    .offset(x: 4, y: -4)
                }
            }
        }
        .buttonStyle(.plain)
        .frame(width: 80, height: 60)
        .onHover { hovering in
            isHovered = hovering
        }
        .help(filename)
    }
}

struct MultilineTextInput: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.font = NSFont.systemFont(ofSize: 16)
        textView.isRichText = false
        textView.isSelectable = true
        textView.isEditable = true
        textView.backgroundColor = NSColor.clear
        textView.textColor = NSColor.labelColor
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = NSSize(width: 0, height: 6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        scrollView.documentView = textView
        context.coordinator.textView = textView

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MultilineTextInput
        var textView: NSTextView?

        init(_ parent: MultilineTextInput) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                let event = NSApp.currentEvent
                if event?.modifierFlags.contains(.shift) == true {
                    // Shift+Enter: insert new line
                    textView.insertNewline(nil)
                    return true
                } else {
                    // Enter: submit
                    parent.onSubmit()
                    return true
                }
            }
            return false
        }
    }
}

#Preview {
    WelcomeView(viewModel: ChatViewModel())
}
