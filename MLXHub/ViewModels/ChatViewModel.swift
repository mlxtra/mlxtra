import SwiftUI
import Combine

@MainActor
class ChatViewModel: ObservableObject {
    // MARK: - Published Properties
    @Published var chats: [Chat] = []
    @Published var selectedChatId: UUID?
    @Published var inputText: String = ""
    @Published var selectedTool: Tool = .auto
    @Published var selectedModel: AIModel = .qwen35
    @Published var isToolMenuOpen: Bool = false
    @Published var isModelMenuOpen: Bool = false
    @Published var selectedImagePaths: [URL] = []

    // MARK: - VLM Integration Properties
    @Published var isPythonLoading: Bool = false
    @Published var isModelLoading: Bool = false
    @Published var isGenerating: Bool = false
    @Published var loadingMessage: String = ""
    @Published var streamingMessageId: UUID?

    // MARK: - Private Properties
    private let chatStore = ChatStore()
    private let vlmExecutor = VLMExecutor()
    private let runtimeManager = RuntimeManager()
    private let mcpWebSearchService = MCPWebSearchService()
    private var generationTask: Task<Void, Never>?
    private let imageGenerationModelId = "black-forest-labs/FLUX.2-klein-4B"
    private let imageGenerationModelName = "FLUX.2-klein-4B"

    // MARK: - Computed Properties
    var hasSelectedImages: Bool {
        !selectedImagePaths.isEmpty
    }

    var selectedChat: Chat? {
        chats.first { $0.id == selectedChatId }
    }

    var recentChats: [Chat] {
        chats.sorted { $0.timestamp > $1.timestamp }
    }

    var isInputDisabled: Bool {
        isPythonLoading || isModelLoading || isGenerating
    }

    private var generatedImagesDirectory: URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return baseURL
            .appendingPathComponent("MLXHub", isDirectory: true)
            .appendingPathComponent("GeneratedImages", isDirectory: true)
    }

    // MARK: - Initialization
    init() {
        loadConversationHistory()
        vlmExecutor.delegate = self
    }

    // MARK: - Persistence
    private func loadConversationHistory() {
        chats = chatStore.loadChats().map { chat in
            var restoredChat = chat
            restoredChat.messages = chat.messages.map { message in
                var restoredMessage = message
                restoredMessage.isStreaming = false
                return restoredMessage
            }
            return restoredChat
        }

        selectedChatId = chatStore.loadSelectedChatId()

        if selectedChatId == nil || !chats.contains(where: { $0.id == selectedChatId }) {
            selectedChatId = recentChats.first?.id
        }

        if chats.isEmpty {
            let newChat = Chat(
                title: "New chat",
                messages: [],
                timestamp: Date(),
                icon: "message"
            )
            chats = [newChat]
            selectedChatId = newChat.id
            persistConversationHistory()
        }
    }

    private func persistConversationHistory() {
        chatStore.saveChats(chats)
        chatStore.saveSelectedChatId(selectedChatId)
    }

    // MARK: - Actions
    func createNewChat() {
        cancelGeneration()

        let newChat = Chat(
            title: "New chat",
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
        chatStore.saveSelectedChatId(selectedChatId)
    }

    func sendMessage() {
        let trimmedInput = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty || !selectedImagePaths.isEmpty else { return }

        if selectedChatId == nil || !chats.contains(where: { $0.id == selectedChatId }) {
            createNewChat()
        }

        guard let chatId = selectedChatId else { return }

        let userMessageId = UUID()
        let images = chatStore.persistAttachments(
            selectedImagePaths,
            chatId: chatId,
            messageId: userMessageId
        )

        // Build message content
        let messageContent = trimmedInput
        if images.isEmpty && trimmedInput.isEmpty {
            return // Don't send empty messages
        }

        let userMessage = Message(
            id: userMessageId,
            content: messageContent,
            isUser: true,
            timestamp: Date(),
            imageURLs: images
        )

        if let index = chats.firstIndex(where: { $0.id == selectedChatId }) {
            chats[index].messages.append(userMessage)
            chats[index].timestamp = Date()
            
            // Update title if this is the first message
            if chats[index].messages.count == 1 {
                chats[index].title = messageContent.isEmpty ? "Image attachment" : String(messageContent.prefix(30))
            }

            persistConversationHistory()
        }

        let messageText = inputText
        inputText = ""
        selectedImagePaths = []

        // Start generation
        generationTask = Task {
            await generateResponse(for: messageText, images: images)
        }
    }

    func cancelGeneration() {
        generationTask?.cancel()
        generationTask = nil
        
        if let messageId = streamingMessageId {
            markMessageStopped(messageId)
        }

        isGenerating = false
        streamingMessageId = nil
        isModelLoading = false
        loadingMessage = ""

        Task {
            await vlmExecutor.terminate()
        }
    }

    // MARK: - Private Methods
    private func generateResponse(for prompt: String, images: [URL]) async {
        do {
            // 1. Initialize Python runtime (first time only)
            if runtimeManager.state != .ready {
                isPythonLoading = true
                loadingMessage = "Initializing Python runtime..."
                try await runtimeManager.initialize()
                try await vlmExecutor.initialize()
                isPythonLoading = false
            }

            // 2. Initialize VLM executor if not ready
            if !vlmExecutor.isReady {
                try await vlmExecutor.initialize()
            }

            let isImageGeneration = selectedTool == .image
            let activeModelId = isImageGeneration ? imageGenerationModelId : selectedModel.modelId
            let activeModelName = isImageGeneration ? imageGenerationModelName : selectedModel.displayName
            let activeBackend: RuntimeBackend = isImageGeneration ? .image : .vlm

            // 3. Load model (first message only)
            if !vlmExecutor.isModelLoaded {
                isModelLoading = true
                let downloadSize = isImageGeneration ? runtimeManager.estimatedModelSize(modelId: activeModelId) : selectedModel.info.downloadSize
                loadingMessage = "Loading \(activeModelName) (\(String(format: "%.1f", downloadSize)) GB)..."
                
                // Check if already downloaded
                if runtimeManager.isModelDownloaded(modelId: activeModelId) {
                    loadingMessage = "Loading \(activeModelName)..."
                } else {
                    loadingMessage = "Downloading \(activeModelName) (\(String(format: "%.1f", downloadSize)) GB)..."
                }
                
                try await loadModel(activeModelId)
                isModelLoading = false
            }

            // 4. Start generation
            isGenerating = true
            let shouldUseWebSearch = shouldUseWebSearch(for: prompt)
            
            // Create AI message placeholder
            let aiMessage = Message(
                content: "",
                isUser: false,
                timestamp: Date(),
                toolCall: initialToolCall(isImageGeneration: isImageGeneration, shouldUseWebSearch: shouldUseWebSearch),
                isStreaming: true
            )
            
            if let index = chats.firstIndex(where: { $0.id == selectedChatId }) {
                chats[index].messages.append(aiMessage)
                chats[index].timestamp = Date()
                streamingMessageId = aiMessage.id
                persistConversationHistory()
            }

            // Build conversation history
            var messages: [ExecutionMessage] = []
            
            // Add system message
            messages.append(ExecutionMessage(
                role: .system,
                content: "You are a helpful assistant."
            ))
            
            // Add conversation history from current chat
            if let chat = selectedChat {
                for message in contextMessages(from: chat, excluding: aiMessage.id) {
                    let role: MessageRole = message.isUser ? .user : .assistant
                    messages.append(ExecutionMessage(role: role, content: message.content))
                }
            }
            
            let chatTemplateKwargs: [String: Any]? = !isImageGeneration && selectedModel.modelId.lowercased().contains("qwen")
                ? ["enable_thinking": selectedModel.enableThinking]
                : nil
            if shouldUseWebSearch, let searchContext = await fetchWebSearchContext(for: prompt, messageId: aiMessage.id) {
                messages.insert(
                    ExecutionMessage(
                        role: .system,
                        content: webSearchSystemPrompt(searchContext: searchContext)
                    ),
                    at: 0
                )
            }

            let request = ExecutionRequest(
                backend: activeBackend,
                modelId: activeModelId,
                messages: isImageGeneration ? [ExecutionMessage(role: .user, content: prompt)] : messages,
                images: images.isEmpty ? nil : images,
                outputDirectory: isImageGeneration ? generatedImagesDirectory : nil,
                maxTokens: isImageGeneration ? 0 : selectedModel.defaultMaxTokens,
                temperature: isImageGeneration ? 1.0 : selectedModel.temperatureRange.default,
                topP: isImageGeneration ? nil : selectedModel.topP,
                topK: isImageGeneration ? nil : selectedModel.topK,
                minP: isImageGeneration ? nil : selectedModel.minP,
                repetitionPenalty: isImageGeneration ? nil : selectedModel.repetitionPenalty,
                chatTemplateKwargs: chatTemplateKwargs
            )
            
            // Execute and stream
            let stream = try await vlmExecutor.execute(request: request)
            
            await processStream(stream, forMessage: aiMessage.id)

        } catch {
            if Task.isCancelled {
                return
            }
            handleGenerationError(error)
        }
    }

    private func fetchWebSearchContext(for prompt: String, messageId: UUID) async -> String? {
        loadingMessage = "Searching the web with Exa..."
        updateMessageToolCall(messageId, status: "Searching")

        do {
            guard let context = try await mcpWebSearchService.searchContext(for: prompt) else {
                updateMessageToolCall(messageId, status: "No results")
                return nil
            }

            updateMessageToolCall(messageId, status: "Done")
            return context
        } catch {
            print("MCP web search failed: \(error)")
            loadingMessage = "Web search unavailable; answering without live sources..."
            updateMessageToolCall(messageId, status: "Unavailable")
            return nil
        }
    }

    private func webSearchSystemPrompt(searchContext: String) -> String {
        if selectedTool == .research {
            return """
            You are in Deep research mode. Use the live web search context below as primary evidence.

            Requirements:
            - Answer from the provided web context first.
            - Include source URLs when available.
            - Compare sources when they disagree.
            - State what is unknown or missing if the context is insufficient.
            - Do not claim you cannot browse or search; the search has already been performed for you.

            Live web search context:
            \(searchContext)
            """
        }

        return """
        Use the following live web search context when it is relevant. Cite source URLs from the search results when available. If the search context does not answer the question, say what is missing. Do not claim you cannot browse or search; the search has already been performed for you.

        \(searchContext)
        """
    }

    private func initialToolCall(isImageGeneration: Bool, shouldUseWebSearch: Bool) -> ToolCall? {
        if isImageGeneration {
            return ToolCall(toolName: "FLUX.2 image generation", status: "Generating", icon: "photo")
        }

        if shouldUseWebSearch {
            return ToolCall(toolName: "Exa web search", status: "Searching", icon: "magnifyingglass")
        }

        return nil
    }

    private func shouldUseWebSearch(for prompt: String) -> Bool {
        if selectedTool == .research {
            return true
        }

        guard selectedTool == .auto else {
            return false
        }

        let normalizedPrompt = prompt.lowercased()
        let explicitSearchPhrases = [
            "web search",
            "search the web",
            "do a search",
            "look up",
            "google",
            "browse"
        ]
        if explicitSearchPhrases.contains(where: normalizedPrompt.contains) {
            return true
        }

        let currentInfoTerms = [
            "latest",
            "current",
            "right now",
            "today",
            "recent",
            "live",
            "price",
            "stock",
            "bitcoin",
            "btc",
            "weather",
            "news"
        ]
        return currentInfoTerms.contains { term in
            normalizedPrompt.contains(term)
        }
    }

    private func loadModel(_ modelId: String) async throws {
        // The executor handles lazy loading, we just need to trigger it
        // by sending a request
    }

    private func processStream(_ stream: AsyncStream<ExecutionEvent>, forMessage messageId: UUID) async {
        var fullResponse = ""
        
        for await event in stream {
            // Check if cancelled
            if Task.isCancelled {
                markMessageStopped(messageId)
                break
            }
            
            switch event {
            case .started:
                break // Already handled
                
            case .token(let token):
                fullResponse += token
                updateStreamingMessage(messageId, content: fullResponse)

            case .image(let imageURL):
                appendGeneratedImage(imageURL, toMessage: messageId)
                updateMessageToolCall(messageId, status: "Done")
                
            case .complete(let response, let usage):
                fullResponse = response
                finalizeMessage(messageId, content: fullResponse, usage: usage)
                isGenerating = false
                streamingMessageId = nil
                generationTask = nil
                loadingMessage = ""
                
            case .error(let error):
                handleGenerationError(error)
                isGenerating = false
                streamingMessageId = nil
                generationTask = nil
                
            case .progress(let message):
                loadingMessage = message
            }
        }

        if Task.isCancelled {
            isGenerating = false
            streamingMessageId = nil
            generationTask = nil
        }
    }

    private func updateStreamingMessage(_ messageId: UUID, content: String) {
        if let chatIndex = chats.firstIndex(where: { $0.id == selectedChatId }),
           let messageIndex = chats[chatIndex].messages.firstIndex(where: { $0.id == messageId }) {
            // Create new array reference to trigger ObservableObject update
            var updatedMessages = chats[chatIndex].messages
            updatedMessages[messageIndex].content = content
            chats[chatIndex].messages = updatedMessages
            persistConversationHistory()
        }
    }

    private func appendGeneratedImage(_ imageURL: URL, toMessage messageId: UUID) {
        if let chatIndex = chats.firstIndex(where: { $0.id == selectedChatId }),
           let messageIndex = chats[chatIndex].messages.firstIndex(where: { $0.id == messageId }) {
            var updatedMessages = chats[chatIndex].messages
            if !updatedMessages[messageIndex].imageURLs.contains(imageURL) {
                updatedMessages[messageIndex].imageURLs.append(imageURL)
            }
            chats[chatIndex].messages = updatedMessages
            persistConversationHistory()
        }
    }

    private func finalizeMessage(_ messageId: UUID, content: String, usage: TokenUsage) {
        if let chatIndex = chats.firstIndex(where: { $0.id == selectedChatId }),
           let messageIndex = chats[chatIndex].messages.firstIndex(where: { $0.id == messageId }) {
            chats[chatIndex].messages[messageIndex].content = content
            chats[chatIndex].messages[messageIndex].isStreaming = false
            chats[chatIndex].timestamp = Date()
            // Store token usage if needed
            persistConversationHistory()
        }
    }

    private func markMessageStopped(_ messageId: UUID) {
        if let chatIndex = chats.firstIndex(where: { $0.id == selectedChatId }),
           let messageIndex = chats[chatIndex].messages.firstIndex(where: { $0.id == messageId }) {
            chats[chatIndex].messages[messageIndex].isStreaming = false
            persistConversationHistory()
        }
    }

    private func updateMessageToolCall(_ messageId: UUID, status: String) {
        if let chatIndex = chats.firstIndex(where: { $0.id == selectedChatId }),
           let messageIndex = chats[chatIndex].messages.firstIndex(where: { $0.id == messageId }),
           var toolCall = chats[chatIndex].messages[messageIndex].toolCall {
            toolCall.status = status
            chats[chatIndex].messages[messageIndex].toolCall = toolCall
            persistConversationHistory()
        }
    }

    private func contextMessages(from chat: Chat, excluding excludedMessageId: UUID) -> [Message] {
        let completedMessages = chat.messages.filter { message in
            message.id != excludedMessageId && !message.isStreaming
        }

        return Array(completedMessages.suffix(20))
    }

    @MainActor
    private func handleGenerationError(_ error: Error) {
        print("Generation error: \(error)")

        // Build detailed error message
        var errorContent = "Sorry, I encountered an error."

        if let execError = error as? ExecutionError {
            switch execError {
            case .pythonError(let message):
                errorContent = "❌ Python Error:\n\(message)"
            case .notInitialized:
                errorContent = "❌ The AI engine is not initialized. Please try again."
            case .processNotRunning:
                errorContent = "❌ The AI process is not running. Please restart the app."
            case .modelNotLoaded:
                errorContent = "❌ Failed to load the AI model. Please check your internet connection."
            case .timeout:
                errorContent = "⏱️ The operation timed out. Please try again."
            case .invalidResponse:
                errorContent = "❌ Received invalid response from AI engine."
            case .processCrashed(let count):
                errorContent = "💥 The AI process crashed (attempt \(count)). Retrying..."
            case .encodingFailed, .decodingFailed:
                errorContent = "❌ Communication error with AI engine."
            case .requiresManualRetry:
                errorContent = "❌ Please try sending your message again."
            }
        } else {
            errorContent = "Sorry, I encountered an error: \(error.localizedDescription)"
        }

        // Add error message to chat
        let errorMessage = Message(
            content: errorContent,
            isUser: false,
            timestamp: Date()
        )

        if let index = chats.firstIndex(where: { $0.id == selectedChatId }) {
            chats[index].messages.append(errorMessage)
            chats[index].timestamp = Date()
            persistConversationHistory()
        }

        isGenerating = false
        streamingMessageId = nil
    }

    func selectTool(_ tool: Tool) {
        selectedTool = tool
        isToolMenuOpen = false
    }

    func selectModel(_ model: AIModel) {
        selectedModel = model
        isModelMenuOpen = false
    }

    func toggleToolMenu() {
        isToolMenuOpen.toggle()
        if isToolMenuOpen {
            isModelMenuOpen = false
        }
    }

    func toggleModelMenu() {
        isModelMenuOpen.toggle()
        if isModelMenuOpen {
            isToolMenuOpen = false
        }
    }

    func closeMenus() {
        isToolMenuOpen = false
        isModelMenuOpen = false
    }
}

// MARK: - Local Conversation Store
private final class ChatStore {
    private let fileManager = FileManager.default
    private let selectedChatKey = "MLXHub.selectedChatId"

    private var applicationSupportDirectory: URL {
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
        return baseURL.appendingPathComponent("MLXHub", isDirectory: true)
    }

    private var conversationsURL: URL {
        applicationSupportDirectory.appendingPathComponent("conversations.json")
    }

    private var attachmentsDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("Attachments", isDirectory: true)
    }

    func loadChats() -> [Chat] {
        guard fileManager.fileExists(atPath: conversationsURL.path) else {
            return []
        }

        do {
            let data = try Data(contentsOf: conversationsURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([Chat].self, from: data)
        } catch {
            print("Failed to load conversation history: \(error)")
            return []
        }
    }

    func saveChats(_ chats: [Chat]) {
        do {
            try fileManager.createDirectory(
                at: applicationSupportDirectory,
                withIntermediateDirectories: true
            )

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

            let data = try encoder.encode(chats)
            try data.write(to: conversationsURL, options: [.atomic])
        } catch {
            print("Failed to save conversation history: \(error)")
        }
    }

    func loadSelectedChatId() -> UUID? {
        guard let storedValue = UserDefaults.standard.string(forKey: selectedChatKey) else {
            return nil
        }

        return UUID(uuidString: storedValue)
    }

    func saveSelectedChatId(_ selectedChatId: UUID?) {
        if let selectedChatId {
            UserDefaults.standard.set(selectedChatId.uuidString, forKey: selectedChatKey)
        } else {
            UserDefaults.standard.removeObject(forKey: selectedChatKey)
        }
    }

    func persistAttachments(_ urls: [URL], chatId: UUID, messageId: UUID) -> [URL] {
        guard !urls.isEmpty else { return [] }

        let messageAttachmentsDirectory = attachmentsDirectory
            .appendingPathComponent(chatId.uuidString, isDirectory: true)
            .appendingPathComponent(messageId.uuidString, isDirectory: true)

        do {
            try fileManager.createDirectory(
                at: messageAttachmentsDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            print("Failed to create attachment directory: \(error)")
            return urls
        }

        return urls.enumerated().map { index, sourceURL in
            let destinationURL = messageAttachmentsDirectory
                .appendingPathComponent("\(index)-\(sourceURL.lastPathComponent)")

            do {
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.removeItem(at: destinationURL)
                }

                try fileManager.copyItem(at: sourceURL, to: destinationURL)
                return destinationURL
            } catch {
                print("Failed to copy attachment \(sourceURL.path): \(error)")
                return sourceURL
            }
        }
    }
}

// MARK: - VLMExecutionDelegate
extension ChatViewModel: VLMExecutionDelegate {
    func modelLoadingStarted(modelId: String) {
        // Handled in generateResponse
    }
    
    func modelLoadingCompleted(modelId: String) {
        // Handled in generateResponse
    }
    
    func modelLoadingFailed(modelId: String, error: Error) {
        handleGenerationError(error)
    }
    
    func executionWillRetry(attempt: Int) {
        loadingMessage = "Retrying (attempt \(attempt))..."
    }
    
    func executionDidFail(error: Error) {
        handleGenerationError(error)
    }
}
