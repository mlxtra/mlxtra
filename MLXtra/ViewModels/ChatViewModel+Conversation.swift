import Foundation

@MainActor
extension ChatViewModel {
    var hasSelectedImages: Bool {
        !selectedImagePaths.isEmpty
    }

    var selectedChat: Chat? {
        chats.first { $0.id == selectedChatId }
    }

    var recentChats: [Chat] {
        if chatsSortRevision == 0 {
            cachedRecentChats = chats.sorted { $0.timestamp > $1.timestamp }
            chatsSortRevision = 1
        } else if _cachedRecentChatsRevision != chatsSortRevision {
            cachedRecentChats = chats.sorted { $0.timestamp > $1.timestamp }
            _cachedRecentChatsRevision = chatsSortRevision
        }
        return cachedRecentChats
    }

    func sidebarMetadata(for chat: Chat) -> ChatSidebarMetadata {
        if _sidebarMetadataRevision != chatsSortRevision {
            sidebarMetadataCache.removeAll(keepingCapacity: true)
            _sidebarMetadataRevision = chatsSortRevision
        }
        if let cached = sidebarMetadataCache[chat.id] { return cached }

        let icon = Self.computeSidebarIcon(for: chat)
        let preview = Self.computeSidebarPreview(for: chat)

        guard _sidebarMetadataRevision == chatsSortRevision else {
            return ChatSidebarMetadata(icon: icon, preview: preview)
        }
        let metadata = ChatSidebarMetadata(icon: icon, preview: preview)
        sidebarMetadataCache[chat.id] = metadata
        return metadata
    }

    var isInputDisabled: Bool {
        isLoadingConversationHistory
            || isPreparingMessage
            || isPythonLoading
            || isModelLoading
            || isGenerating
            || isTerminatingLocalEngine
            || isDraftingMusicLyrics
            || generationTask != nil
    }

    func loadConversationHistory() {
        applyConversationSnapshot(
            ChatPersistenceSnapshot(
                chats: chatPersistence.loadChats(),
                selectedChatId: chatPersistence.loadSelectedChatId()
            )
        )
    }

    func loadConversationHistoryAsync() async {
        isLoadingConversationHistory = true
        defer {
            isLoadingConversationHistory = false
            conversationHistoryLoadTask = nil
        }
        let snapshot = await chatPersistence.loadConversationSnapshot()
        guard !Task.isCancelled else { return }
        applyConversationSnapshot(snapshot)
    }

    private func applyConversationSnapshot(_ snapshot: ChatPersistenceSnapshot) {
        chats = snapshot.chats.map { chat in
            var restoredChat = chat
            restoredChat.messages = chat.messages.map { message in
                var restoredMessage = message
                restoredMessage.isStreaming = false
                return restoredMessage
            }
            return restoredChat
        }

        selectedChatId = snapshot.selectedChatId

        if selectedChatId == nil || !chats.contains(where: { $0.id == selectedChatId }) {
            selectedChatId = recentChats.first?.id
        }

        if chats.isEmpty {
            let newChat = Chat(
                title: "",
                messages: [],
                timestamp: Date(),
                icon: "message"
            )
            chats = [newChat]
            selectedChatId = newChat.id
            persistConversationHistory()
        }
    }

    func persistConversationHistory() {
        chatPersistence.saveChats(chats)
        chatPersistence.saveSelectedChatId(selectedChatId)
    }

    /// Coalesces rapid persistence calls (e.g. finalize + stop in quick succession)
    /// into a single write after a short debounce interval.
    func scheduleConversationPersistence() {
        chatPersistence.scheduleSave(chats, selectedChatId: selectedChatId)
    }

    func createNewChat() {
        if isInputDisabled {
            cancelGeneration()
        }

        let newChat = Chat(
            title: "",
            messages: [],
            timestamp: Date(),
            icon: "message"
        )
        chats.insert(newChat, at: 0)
        selectedChatId = newChat.id
        inputText = ""
        selectedImagePaths = []
        persistConversationHistory()
    }

    func selectChat(_ chat: Chat) {
        selectedChatId = chat.id
        chatPersistence.saveSelectedChatId(selectedChatId)
    }

    func renameChat(_ chatId: UUID, to title: String) {
        let normalizedTitle = ChatDisplayText.singleLine(
            title,
            fallback: "Untitled",
            maxLength: MLXtraDesignSystem.TextLimit.renameTitle
        )
        guard let index = chats.firstIndex(where: { $0.id == chatId }) else { return }

        chats[index].title = normalizedTitle
        persistConversationHistory()
    }

    func deleteChat(_ chat: Chat) {
        if selectedChatId == chat.id, isInputDisabled {
            cancelGeneration()
        }

        chats.removeAll { $0.id == chat.id }
        chatPersistence.deleteAttachments(for: chat.id)

        if selectedChatId == chat.id {
            selectedChatId = recentChats.first?.id
        }

        if chats.isEmpty {
            let newChat = Chat(
                title: "",
                messages: [],
                timestamp: Date(),
                icon: "message"
            )
            chats = [newChat]
            selectedChatId = newChat.id
        }

        persistConversationHistory()
    }

    func sendMessage() {
        guard !isInputDisabled else { return }

        let trimmedInput = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty || !selectedImagePaths.isEmpty else { return }

        if selectedTool == .music, !prepareMusicGenerationIfNeeded(prompt: trimmedInput) {
            return
        }

        if selectedChatId == nil || !chats.contains(where: { $0.id == selectedChatId }) {
            createNewChat()
        }

        guard let chatId = selectedChatId else { return }

        let userMessageId = UUID()
        let selectedImages = selectedImagePaths

        let messageContent = trimmedInput
        if selectedImages.isEmpty && trimmedInput.isEmpty {
            return
        }

        isCommittingComposerInput = true
        inputText = ""
        isCommittingComposerInput = false
        selectedImagePaths = []

        if selectedImages.isEmpty {
            appendPreparedUserMessage(
                chatId: chatId,
                messageId: userMessageId,
                content: messageContent,
                images: []
            )
            startGeneration(makeGenerationRequest(chatId: chatId, prompt: messageContent, images: []))
            return
        }

        startMessagePreparation(
            chatId: chatId,
            messageId: userMessageId,
            content: messageContent,
            selectedImages: selectedImages
        )
    }

    private func startMessagePreparation(
        chatId: UUID,
        messageId: UUID,
        content: String,
        selectedImages: [URL]
    ) {
        guard messagePreparationTask == nil else { return }

        let preparationID = UUID()
        activeMessagePreparationID = preparationID
        isPreparingMessage = true
        loadingMessage = "Preparing attachments..."

        messagePreparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let images = await self.chatPersistence.persistAttachments(
                selectedImages,
                chatId: chatId,
                messageId: messageId
            )
            guard self.activeMessagePreparationID == preparationID, !Task.isCancelled else {
                self.finishMessagePreparation(preparationID)
                return
            }

            self.finishMessagePreparation(preparationID)
            guard !images.isEmpty || !content.isEmpty else { return }
            self.appendPreparedUserMessage(
                chatId: chatId,
                messageId: messageId,
                content: content,
                images: images
            )
            self.startGeneration(self.makeGenerationRequest(chatId: chatId, prompt: content, images: images))
        }
    }

    private func finishMessagePreparation(_ preparationID: UUID) {
        guard activeMessagePreparationID == preparationID else { return }
        isPreparingMessage = false
        activeMessagePreparationID = nil
        messagePreparationTask = nil
        if !isGenerating && !isPythonLoading && !isModelLoading {
            loadingMessage = ""
        }
    }

    private func appendPreparedUserMessage(
        chatId: UUID,
        messageId: UUID,
        content: String,
        images: [URL]
    ) {
        let userMessage = Message(
            id: messageId,
            content: content,
            isUser: true,
            timestamp: Date(),
            imageURLs: images
        )

        if let index = chats.firstIndex(where: { $0.id == chatId }) {
            chats[index].messages.append(userMessage)
            chats[index].timestamp = Date()

            if chats[index].messages.count == 1 {
                chats[index].title = ChatDisplayText.singleLine(
                    content,
                    fallback: "Image attachment",
                    maxLength: MLXtraDesignSystem.TextLimit.generatedTitle
                )
            }

            persistConversationHistory()
        }
    }

    func cancelGeneration() {
        guard generationTask != nil
            || messagePreparationTask != nil
            || isPreparingMessage
            || isGenerating
            || isPythonLoading
            || isModelLoading
            || isDraftingMusicLyrics
            || streamingMessageId != nil else {
            return
        }
#if DEBUG
        ChatStreamDiagnostics.log("generation.cancel")
#endif
        generationTask?.cancel()
        generationTask = nil
        messagePreparationTask?.cancel()
        messagePreparationTask = nil
        activeMessagePreparationID = nil
        isPreparingMessage = false
        activeGenerationID = nil
        cancelMusicLyricsDraft()
        activeMusicGenerationDraft = nil

        if let messageId = streamingMessageId {
            markMessageStopped(messageId)
        }

        isGenerating = false
        streamingMessageId = nil
        isPythonLoading = false
        isModelLoading = false
        modelLoadProgress = nil
        generationProgress = nil
        cancelLaunchModelPreload()
        loadingMessage = ""

        if engineTerminationTask == nil {
            scheduleEngineTermination()
        }

    }

    private static func computeSidebarIcon(for chat: Chat) -> String {
        for message in chat.messages.reversed() {
            if !message.imageURLs.isEmpty { return "photo" }
            if let audioURL = message.audioURLs.first {
                return audioURL.path.localizedCaseInsensitiveContains("music") ? "music.note" : "waveform"
            }
            if let toolCall = message.toolCalls.first {
                if toolCall.icon == "magnifyingglass" { return "magnifyingglass" }
                if toolCall.icon == "photo" { return "photo" }
                if toolCall.icon == "music.note" || toolCall.icon == "waveform" { return toolCall.icon }
            }
        }
        return chat.icon
    }

    private static func computeSidebarPreview(for chat: Chat) -> String {
        guard let message = chat.messages.last else { return "No messages yet" }
        if !message.imageURLs.isEmpty { return "Generated image" }
        if let audioURL = message.audioURLs.first {
            return audioURL.path.localizedCaseInsensitiveContains("music") ? "Generated music" : "Generated speech"
        }
        if let visibleText = ReasoningContentFilter.visibleText(from: message.content), !visibleText.isEmpty {
            return ChatDisplayText.singleLine(
                visibleText,
                fallback: message.isUser ? "Message" : "Assistant response",
                maxLength: MLXtraDesignSystem.TextLimit.sidebarPreview
            )
        }
        return message.isUser ? "Message" : "Assistant response"
    }

    func makeGenerationRequest(chatId: UUID, prompt: String, images: [URL], retryTool: Tool? = nil) -> ChatGenerationRequest {
        let requestTool = retryTool ?? selectedTool
        let modalities = ModelModality.allCases
        var profilesByModality: [ModelModality: ModelCapabilityProfile] = [:]
        var parametersByModelId: [String: [String: Any]] = [:]

        for modality in modalities {
            let profile = profile(for: tool(for: modality))
            profilesByModality[modality] = profile
            parametersByModelId[profile.modelId] = modelParameterStore.executionParameters(for: profile)
        }

        return ChatGenerationRequest(
            chatId: chatId,
            prompt: prompt,
            images: images,
            tool: requestTool,
            profilesByModality: profilesByModality,
            parametersByModelId: parametersByModelId,
            selectionDownloadRequirement: downloadRequirement(for: requestTool),
            selectionOperationName: operationName(for: requestTool)
        )
    }

    func startGeneration(_ request: ChatGenerationRequest) {
        guard generationTask == nil else { return }
#if DEBUG
        ChatStreamDiagnostics.log("generation.start promptChars=\(request.prompt.count)")
#endif
        let generationID = UUID()
        activeGenerationID = generationID
        generationProgress = nil
        isGenerating = true
        loadingMessage = "Starting..."
        generationTask = Task {
            await awaitPendingEngineTermination()
            guard ownsActiveGeneration(generationID) else { return }
            await prepareLaunchModelPreloadForForegroundUse(request)
            guard ownsActiveGeneration(generationID) else { return }
            if request.isMusicGeneration {
                await generateMusicDirectly(for: request, generationID: generationID)
            } else {
                await generateResponse(for: request, generationID: generationID)
            }
        }
    }

    @discardableResult
    func scheduleEngineTermination() -> Task<Void, Never> {
        if let engineTerminationTask {
            isTerminatingLocalEngine = true
            return engineTerminationTask
        }

        let token = UUID()
        engineTerminationToken = token
        isTerminatingLocalEngine = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await vlmExecutor.terminate()
            if engineTerminationToken == token {
                engineTerminationTask = nil
                engineTerminationToken = nil
                isTerminatingLocalEngine = false
                if !isGenerating && !isPythonLoading && !isModelLoading && !isPreparingMessage && !isDraftingMusicLyrics {
                    loadingMessage = ""
                }
            }
        }
        engineTerminationTask = task
        return task
    }

    func awaitPendingEngineTermination() async {
        let task = engineTerminationTask
        await task?.value
    }
}
