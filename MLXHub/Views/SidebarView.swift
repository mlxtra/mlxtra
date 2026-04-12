import SwiftUI

struct SidebarView: View {
    @ObservedObject var viewModel: ChatViewModel
    @State private var searchText: String = ""
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
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Color(NSColor.separatorColor).opacity(0.35), lineWidth: 1)
            )
            .padding(.horizontal, 14)
            .padding(.bottom, 8)

            List(selection: $viewModel.selectedChatId) {
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
                                // Handle rename
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

            Divider()

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
            }
            .buttonStyle(.plain)
            .keyboardShortcut(",", modifiers: .command)
            .help("Settings (⌘,)")
        }
        .frame(minWidth: 240, idealWidth: 280)
        .background(Color(NSColor.controlBackgroundColor))
    }
}

struct ChatHistoryItem: View {
    let chat: Chat
    let isSelected: Bool
    let onDelete: () -> Void
    @State private var isHovered = false
    @State private var isConfirmingDelete = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: chat.icon)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .frame(width: 20, height: 20)

            Text(chat.title.isEmpty ? "New chat" : chat.title)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            if isHovered || isConfirmingDelete {
                Button(action: handleDeleteTap) {
                    Text(isConfirmingDelete ? "Confirm" : "")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isConfirmingDelete ? Color.white : Color.secondary)
                        .frame(minWidth: isConfirmingDelete ? 52 : 24, minHeight: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(isConfirmingDelete ? Color.red : Color.clear)
                        )
                        .overlay {
                            if !isConfirmingDelete {
                                Image(systemName: "trash")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                        }
                }
                .buttonStyle(.plain)
                .help(isConfirmingDelete ? "Confirm delete" : "Delete chat")
                .transition(.opacity)
            }
        }
        .frame(minHeight: 28)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
                if !hovering {
                    isConfirmingDelete = false
                }
            }
        }
    }

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
