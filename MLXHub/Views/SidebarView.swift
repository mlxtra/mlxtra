import SwiftUI

struct SidebarView: View {
    @ObservedObject var viewModel: ChatViewModel
    @State private var searchText: String = ""
    @State private var renamingChat: Chat?
    @State private var renameTitle: String = ""
    @Environment(\.openSettings) private var openSettings

    private var filteredChats: [Chat] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return viewModel.recentChats }

        return viewModel.recentChats.filter { chat in
            chat.title.localizedCaseInsensitiveContains(query)
                || chat.messages.contains { $0.content.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Chats")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer()

                Button(action: {
                    viewModel.createNewChat()
                }) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("n", modifiers: .command)
                .help("New Chat (⌘N)")
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            HStack {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                TextField("Search", text: $searchText)
                    .font(.system(size: 13))
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            )
            .padding(.horizontal, 14)
            .padding(.bottom, 8)

            List {
                ForEach(filteredChats) { chat in
                    ChatHistoryItem(
                        chat: chat,
                        isSelected: viewModel.selectedChatId == chat.id,
                        onDelete: {
                            viewModel.deleteChat(chat)
                        }
                    )
                        .tag(chat.id)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            viewModel.selectChat(chat)
                        }
                        .contextMenu {
                            Button("Delete") {
                                viewModel.deleteChat(chat)
                            }
                            Divider()
                            Button("Rename") {
                                renamingChat = chat
                                renameTitle = chat.title
                            }
                        }
                }

                if filteredChats.isEmpty {
                    Text("No chats found")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 18)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(Color.clear)

            Rectangle()
                .fill(Color(NSColor.separatorColor).opacity(0.28))
                .frame(height: 1)

            Button(action: {
                openSettings()
            }) {
                HStack(spacing: 9) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14, weight: .regular))
                        .frame(width: 20, height: 20)

                    Text("Settings")
                        .font(.system(size: 13))

                    Spacer()
                }
                .foregroundStyle(.primary)
                .frame(minHeight: 30)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
                .background {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.thinMaterial.opacity(0.45))
                        .opacity(0.001)
                }
            }
            .buttonStyle(.plain)
            .keyboardShortcut(",", modifiers: .command)
            .help("Settings (⌘,)")
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .frame(minWidth: 240, idealWidth: 280)
        .background(.regularMaterial)
        .overlay(alignment: .trailing) {
            LinearGradient(
                colors: [
                    Color.white.opacity(0.16),
                    Color(NSColor.separatorColor).opacity(0.18)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(width: 1)
        }
        .sheet(item: $renamingChat, onDismiss: clearRenameState) { chat in
            RenameChatSheet(
                title: $renameTitle,
                onSave: {
                    viewModel.renameChat(chat.id, to: renameTitle)
                    clearRenameState()
                },
                onCancel: clearRenameState
            )
        }
    }

    private func clearRenameState() {
        renamingChat = nil
        renameTitle = ""
    }
}

struct ChatHistoryItem: View {
    let chat: Chat
    let isSelected: Bool
    let onDelete: () -> Void
    @State private var isHovered = false
    @State private var isConfirmingDelete = false
    private let actionButtonHeight: CGFloat = 28

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: rowIcon)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(chat.title.isEmpty ? "New chat" : chat.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(previewText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer()

            if isHovered || isConfirmingDelete {
                Button(action: handleDeleteTap) {
                    Group {
                        if isConfirmingDelete {
                            Text("Confirm")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.white)
                                .padding(.horizontal, 12)
                                .frame(height: actionButtonHeight)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.red)
                                )
                        } else {
                            Image(systemName: "trash")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: actionButtonHeight, height: actionButtonHeight)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.white.opacity(isSelected ? 0.12 : 0.08))
                                )
                        }
                    }
                }
                .buttonStyle(.plain)
                .help(isConfirmingDelete ? "Confirm delete" : "Delete chat")
                .transition(.opacity)
            } else {
                Text(timestampText)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(rowBackground)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(rowBorder, lineWidth: 1)
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
                if !hovering {
                    isConfirmingDelete = false
                }
            }
        }
    }

    private var rowBackground: AnyShapeStyle {
        if isSelected {
            return AnyShapeStyle(.thinMaterial)
        }

        if isHovered {
            return AnyShapeStyle(Color.white.opacity(0.08))
        }

        return AnyShapeStyle(Color.clear)
    }

    private var rowBorder: Color {
        guard isSelected else {
            return Color.clear
        }

        return Color.white.opacity(0.18)
    }

    private var rowIcon: String {
        for message in chat.messages.reversed() {
            if !message.imageURLs.isEmpty {
                return "photo"
            }

            if let audioURL = message.audioURLs.first {
                return audioURL.path.localizedCaseInsensitiveContains("music") ? "music.note" : "waveform"
            }

            if let toolCall = message.toolCalls.first {
                if toolCall.icon == "magnifyingglass" {
                    return "magnifyingglass"
                }
                if toolCall.icon == "photo" {
                    return "photo"
                }
                if toolCall.icon == "music.note" || toolCall.icon == "waveform" {
                    return toolCall.icon
                }
            }
        }

        return chat.icon
    }

    private var previewText: String {
        guard let message = chat.messages.last else {
            return "No messages yet"
        }

        if !message.imageURLs.isEmpty {
            return "Generated image"
        }

        if let audioURL = message.audioURLs.first {
            return audioURL.path.localizedCaseInsensitiveContains("music") ? "Generated music" : "Generated speech"
        }

        if let visibleText = ReasoningContentFilter.visibleText(from: message.content), !visibleText.isEmpty {
            return message.isUser ? visibleText : visibleText
        }

        return message.isUser ? "Message" : "Assistant response"
    }

    private var timestampText: String {
        if Calendar.current.isDateInToday(chat.timestamp) {
            return Self.timeFormatter.string(from: chat.timestamp)
        }

        return Self.dateFormatter.string(from: chat.timestamp)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter
    }()

    private func handleDeleteTap() {
        if isConfirmingDelete {
            onDelete()
        } else {
            withAnimation(.easeInOut(duration: 0.12)) {
                isConfirmingDelete = true
            }
        }
    }
}

#Preview {
    SidebarView(viewModel: ChatViewModel())
}

private struct RenameChatSheet: View {
    @Binding var title: String
    let onSave: () -> Void
    let onCancel: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Chat")
                .font(.system(size: 15, weight: .semibold))

            TextField("Chat title", text: $title)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit(onSave)

            HStack {
                Spacer()

                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.escape, modifiers: [])

                Button("Save", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
        .onAppear {
            isFocused = true
        }
    }
}
