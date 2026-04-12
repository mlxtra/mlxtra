import SwiftUI

struct SidebarView: View {
    @ObservedObject var viewModel: ChatViewModel
    @State private var searchText: String = ""

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
                    ChatHistoryItem(chat: chat, isSelected: viewModel.selectedChatId == chat.id)
                        .tag(chat.id)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            viewModel.selectChat(chat)
                        }
                        .contextMenu {
                            Button("Delete") {
                                // Handle delete
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
        }
        .frame(minWidth: 240, idealWidth: 280)
        .background(Color(NSColor.controlBackgroundColor))
    }
}

struct ChatHistoryItem: View {
    let chat: Chat
    let isSelected: Bool

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
        }
        .frame(minHeight: 28)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
    }
}

#Preview {
    SidebarView(viewModel: ChatViewModel())
}
