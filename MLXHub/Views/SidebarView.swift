import SwiftUI

struct SidebarView: View {
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.openSettings) private var openSettings
    @State private var searchText: String = ""
    @State private var renamingChat: Chat?
    @State private var renameTitle: String = ""

    private var filteredChats: [Chat] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return viewModel.recentChats }

        return viewModel.recentChats.filter { chat in
            ChatDisplayText.singleLine(chat.title, fallback: "Untitled").localizedCaseInsensitiveContains(query)
                || chat.messages.contains { $0.content.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            SidebarHeader(
                searchText: $searchText,
                onNewChat: viewModel.createNewChat
            )

            List {
                Section {
                    ForEach(filteredChats) { chat in
                        let metadata = viewModel.sidebarMetadata(for: chat)
                        ChatHistoryItem(
                            chat: chat,
                            rowIcon: metadata.icon,
                            previewText: metadata.preview,
                            isSelected: viewModel.selectedChatId == chat.id,
                            onRename: {
                                beginRename(chat)
                            },
                            onDelete: {
                                viewModel.deleteChat(chat)
                            }
                        )
                            .onTapGesture {
                                viewModel.selectChat(chat)
                            }
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(
                                top: MLXHubDesignSystem.Spacing.hairline,
                                leading: 0,
                                bottom: MLXHubDesignSystem.Spacing.hairline,
                                trailing: 0
                            ))
                            .contentShape(Rectangle())
                            .contextMenu {
                                Button("Rename") {
                                    beginRename(chat)
                                }
                                Divider()
                                Button("Delete", role: .destructive) {
                                    viewModel.deleteChat(chat)
                                }
                            }
                    }

                    if filteredChats.isEmpty {
                        Text("No chats found")
                            .font(MLXHubDesignSystem.Typography.compactBody)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, MLXHubDesignSystem.Spacing.xxxl + MLXHubDesignSystem.Spacing.xxs)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 0, leading: MLXHubDesignSystem.Spacing.md, bottom: 0, trailing: MLXHubDesignSystem.Spacing.md))
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SidebarSettingsFooter(openSettings: {
                openSettings()
            })
        }
        .navigationTitle("Chats")
        .frame(
            minWidth: MLXHubDesignSystem.Layout.sidebarMinWidth,
            idealWidth: MLXHubDesignSystem.Layout.sidebarIdealWidth,
            maxWidth: MLXHubDesignSystem.Layout.sidebarMaxWidth
        )
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

    private func beginRename(_ chat: Chat) {
        renamingChat = chat
        renameTitle = ChatDisplayText.singleLine(chat.title, fallback: "")
    }
}

private struct SidebarHeader: View {
    @Binding var searchText: String
    let onNewChat: () -> Void
    @State private var isNewChatHovered = false

    var body: some View {
        VStack(spacing: MLXHubDesignSystem.Spacing.md) {
            Button(action: onNewChat) {
                HStack(spacing: MLXHubDesignSystem.Spacing.md) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: MLXHubDesignSystem.Icon.regular, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: MLXHubDesignSystem.Icon.sidebarRowFrame, height: MLXHubDesignSystem.Icon.sidebarRowFrame)

                    Text("New chat")
                        .font(MLXHubDesignSystem.Typography.compactBodyMedium)
                        .foregroundStyle(.primary)

                    Spacer(minLength: MLXHubDesignSystem.Spacing.md)
                }
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .padding(.horizontal, MLXHubDesignSystem.Spacing.xxxl)
                .contentShape(RoundedRectangle(cornerRadius: MLXHubDesignSystem.Radius.row, style: .continuous))
                .background {
                    RoundedRectangle(cornerRadius: MLXHubDesignSystem.Radius.row, style: .continuous)
                        .fill(isNewChatHovered ? MLXHubDesignSystem.Surface.hoverFill : Color.clear)
                        .padding(.horizontal, MLXHubDesignSystem.Spacing.md)
                }
            }
            .buttonStyle(.plain)
            .help("New chat")
            .accessibilityIdentifier("sidebar.newChat")
            .onHover { hovering in
                withAnimation(.easeInOut(duration: MLXHubDesignSystem.Motion.hoverDuration)) {
                    isNewChatHovered = hovering
                }
            }

            NativeSearchField(placeholder: "Search", text: $searchText)
                .frame(height: 30)
                .padding(.horizontal, MLXHubDesignSystem.Spacing.xxxl)
        }
        .padding(.top, MLXHubDesignSystem.Spacing.xl)
        .padding(.bottom, MLXHubDesignSystem.Spacing.md)
        .background(.regularMaterial)
    }
}

private struct SidebarSettingsFooter: View {
    let openSettings: () -> Void
    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 0) {
            Divider()
                .opacity(0.55)

            Button(action: openSettings) {
                HStack(spacing: MLXHubDesignSystem.Spacing.md) {
                    Image(systemName: "gearshape")
                        .font(.system(size: MLXHubDesignSystem.Icon.regular, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: MLXHubDesignSystem.Icon.sidebarRowFrame, height: MLXHubDesignSystem.Icon.sidebarRowFrame)

                    Text("Settings")
                        .font(MLXHubDesignSystem.Typography.compactBodyMedium)
                        .foregroundStyle(.primary)

                    Spacer(minLength: MLXHubDesignSystem.Spacing.md)
                }
                .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                .padding(.horizontal, MLXHubDesignSystem.Spacing.xxxl)
                .contentShape(RoundedRectangle(cornerRadius: MLXHubDesignSystem.Radius.row, style: .continuous))
                .background {
                    RoundedRectangle(cornerRadius: MLXHubDesignSystem.Radius.row, style: .continuous)
                        .fill(isHovered ? MLXHubDesignSystem.Surface.hoverFill : Color.clear)
                        .padding(.horizontal, MLXHubDesignSystem.Spacing.md)
                }
            }
            .buttonStyle(.plain)
            .help("Settings")
            .accessibilityIdentifier("sidebar.settings")
            .onHover { hovering in
                withAnimation(.easeInOut(duration: MLXHubDesignSystem.Motion.hoverDuration)) {
                    isHovered = hovering
                }
            }
            .padding(.vertical, MLXHubDesignSystem.Spacing.sm)
        }
        .background(.regularMaterial)
    }
}

struct ChatHistoryItem: View {
    let chat: Chat
    let rowIcon: String
    let previewText: String
    let isSelected: Bool
    let onRename: () -> Void
    let onDelete: () -> Void
    @State private var isHovered = false
    private let actionButtonHeight = MLXHubDesignSystem.Icon.avatar
    private let rowHorizontalOverhang = MLXHubDesignSystem.Spacing.xl
    private let actionTrailingInset = -MLXHubDesignSystem.Spacing.xs
    private let timestampReserveWidth: CGFloat = 66
    private let timestampTrailingOffset = MLXHubDesignSystem.Spacing.xxl
    private var displayTitle: String {
        ChatDisplayText.singleLine(chat.title, fallback: "Untitled")
    }
    private var showsActionButton: Bool {
        isHovered
    }

    var body: some View {
        HStack(alignment: .top, spacing: MLXHubDesignSystem.Spacing.sm) {
            Image(systemName: rowIcon)
                .font(.system(size: MLXHubDesignSystem.Icon.regular, weight: .regular))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .frame(width: MLXHubDesignSystem.Icon.sidebarRowFrame, height: MLXHubDesignSystem.Icon.sidebarRowFrame)
                .padding(.top, MLXHubDesignSystem.Spacing.xxs + 1)
                .accessibilityIdentifier("sidebar.chat.icon")

            VStack(alignment: .leading, spacing: MLXHubDesignSystem.Spacing.xxs) {
                Text(displayTitle)
                    .font(MLXHubDesignSystem.Typography.rowTitle)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(displayTitle)
                    .accessibilityValue(displayTitle)
                    .accessibilityIdentifier("sidebar.chat.title")

                HStack(alignment: .firstTextBaseline, spacing: MLXHubDesignSystem.Spacing.sm) {
                    Text(previewText)
                        .font(MLXHubDesignSystem.Typography.rowPreview)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("sidebar.chat.preview")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, showsActionButton ? 0 : timestampReserveWidth + MLXHubDesignSystem.Spacing.sm)
                .overlay(alignment: .trailing) {
                    if !showsActionButton {
                        timestampLabel
                            .offset(x: timestampTrailingOffset)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, showsActionButton ? actionButtonHeight + MLXHubDesignSystem.Spacing.xs : 0)
        }
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .padding(.leading, -MLXHubDesignSystem.Spacing.xs)
        .padding(.trailing, MLXHubDesignSystem.Spacing.lg)
        .padding(.vertical, MLXHubDesignSystem.Spacing.xxs + 1)
        .background {
            RoundedRectangle(cornerRadius: MLXHubDesignSystem.Radius.row, style: .continuous)
                .fill(rowBackground)
                .padding(.horizontal, -rowHorizontalOverhang)
        }
#if DEBUG
        .overlay {
            uiTestSelectionFrameProbe
                .padding(.horizontal, -rowHorizontalOverhang)
        }
#endif
        .overlay(alignment: .trailing) {
            if showsActionButton {
                actionMenu
                    .padding(.trailing, actionTrailingInset)
                    .transition(.opacity)
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: MLXHubDesignSystem.Motion.hoverDuration)) {
                isHovered = hovering
            }
        }
    }

    private var actionMenu: some View {
        Menu {
            Button {
                onRename()
            } label: {
                Label("Rename", systemImage: "pencil")
            }

            Divider()

            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: MLXHubDesignSystem.Icon.small, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: actionButtonHeight, height: actionButtonHeight)
                .background(
                    Circle()
                        .fill(Color.primary.opacity(0.06))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Chat actions")
        .accessibilityLabel("Chat actions")
        .accessibilityIdentifier("sidebar.chat.actions")
    }

    private var timestampLabel: some View {
        Text(timestampText)
            .font(MLXHubDesignSystem.Typography.micro)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityIdentifier("sidebar.chat.timestamp")
    }

    private var rowBackground: AnyShapeStyle {
        if isSelected {
            return AnyShapeStyle(MLXHubDesignSystem.Surface.selectedSidebarFill)
        }

        if isHovered {
            return AnyShapeStyle(MLXHubDesignSystem.Surface.hoverFill)
        }

        return AnyShapeStyle(Color.clear)
    }

#if DEBUG
    @ViewBuilder
    private var uiTestSelectionFrameProbe: some View {
        if isSelected && ProcessInfo.processInfo.environment["MLXHUB_UI_TEST_MODE"] == "1" {
            Color.primary.opacity(0.001)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Selected chat row")
                .accessibilityIdentifier("sidebar.chat.selectedRow")
        }
    }
#endif

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
