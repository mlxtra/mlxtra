import SwiftUI
import Combine

#if DEBUG
private enum ChatStreamDiagnostics {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["MLXHUB_STREAM_DIAGNOSTICS"] == "1"
            || UserDefaults.standard.bool(forKey: "MLXHub.streamDiagnostics")
    }

    static func now() -> TimeInterval {
        Date().timeIntervalSinceReferenceDate
    }

    static func log(_ message: String) {
        guard isEnabled else { return }
        print("[StreamDiag][ChatVM] \(String(format: "%.6f", now())) \(message)")
    }
}
#endif

@MainActor
final class StreamingMessageContent: ObservableObject, Identifiable {
    let id: UUID
    @Published private(set) var revision = 0
    private(set) var text: String
    private(set) var latestMutation: StreamingMessageContentMutation
    private(set) var containsReasoningMarkup: Bool

    init(id: UUID, text: String = "") {
        self.id = id
        self.text = text
        self.latestMutation = .replace(text)
        self.containsReasoningMarkup = Self.hasReasoningMarkup(text)
    }

    func update(_ text: String) {
        guard self.text != text else { return }
        self.text = text
        latestMutation = .replace(text)
        containsReasoningMarkup = Self.hasReasoningMarkup(text)
        revision &+= 1
    }

    func append(_ text: String) {
        guard !text.isEmpty else { return }
        let detectionWindow = String(self.text.suffix(32)) + text
        self.text += text
        latestMutation = .append(text)
        containsReasoningMarkup = containsReasoningMarkup || Self.hasReasoningMarkup(detectionWindow)
        revision &+= 1
    }

    func clear() {
        update("")
    }

    private static func hasReasoningMarkup(_ text: String) -> Bool {
        text.contains("<think")
            || text.contains("</think")
            || text.contains("<thinking")
            || text.contains("</thinking")
    }
}

enum StreamingMessageContentMutation {
    case append(String)
    case replace(String)
}

@MainActor
final class StreamingMessageContentStore {
    private var entries: [UUID: StreamingMessageContent] = [:]

    func begin(messageId: UUID, initialText: String = "") -> StreamingMessageContent {
        if let existing = entries[messageId] {
            existing.update(initialText)
            return existing
        }

        let content = StreamingMessageContent(id: messageId, text: initialText)
        entries[messageId] = content
        return content
    }

    func content(for messageId: UUID) -> StreamingMessageContent? {
        entries[messageId]
    }

    func update(messageId: UUID, text: String) {
        if let existing = entries[messageId] {
            existing.update(text)
        } else {
            _ = begin(messageId: messageId, initialText: text)
        }
    }

    func append(messageId: UUID, text: String) {
        if let existing = entries[messageId] {
            existing.append(text)
        } else {
            _ = begin(messageId: messageId, initialText: text)
        }
    }

    func clear(messageId: UUID) {
        content(for: messageId)?.clear()
    }

    func end(messageId: UUID) {
        entries.removeValue(forKey: messageId)
    }
}

struct ChatSidebarMetadata {
    let icon: String
    let preview: String
}

@MainActor
class ChatViewModel: ObservableObject {
    // MARK: - Performance Caches
    private var cachedRecentChats: [Chat] = []
    private var _cachedRecentChatsRevision: UInt = 0
    private var chatsSortRevision: UInt = 0
    private var sidebarMetadataCache: [UUID: ChatSidebarMetadata] = [:]
    private var _sidebarMetadataRevision: UInt = 0

    // MARK: - Published Properties
    @Published var chats: [Chat] = [] {
        didSet { chatsSortRevision &+= 1 }
    }
    @Published var selectedChatId: UUID?
    @Published var inputText: String = "" {
        didSet {
            guard inputText != oldValue, selectedTool == .music, !isCommittingComposerInput else { return }
            activeMusicGenerationDraft = nil
            if musicLyricsApproved {
                musicLyricsApproved = false
            }
        }
    }
    @Published var selectedTool: Tool = .auto
    @Published var selectedModel: AIModel = AIModel.defaultForCurrentHardware
    @Published var isToolMenuOpen: Bool = false
    @Published var isModelMenuOpen: Bool = false
    @Published var selectedImagePaths: [URL] = []

    // MARK: - VLM Integration Properties
    @Published var isPythonLoading: Bool = false
    @Published var isModelLoading: Bool = false
    @Published var isGenerating: Bool = false
    @Published var isDraftingMusicLyrics: Bool = false
    @Published var loadingMessage: String = ""
    @Published var streamingMessageId: UUID?
    @Published var modelDownloadRequest: DownloadableModel?
    @Published var pendingEngineDownloadModel: DownloadableModel?
    @Published var musicIntentState: MusicIntentState = .needsInstrumentalOrVocals
    @Published var musicVocalMode: MusicVocalMode = .auto
    @Published var musicLyricsText: String = "" {
        didSet {
            if musicLyricsText != oldValue {
                musicLyricsApproved = false
            }
        }
    }
    @Published var isMusicLyricsEditorVisible: Bool = false
    @Published var musicLyricsApproved: Bool = false
    @Published var activeEngineModelName: String?
    @Published var activeEngineModelRole: LocalEngineModelRole = .chat
    @Published var freedEngineModelName: String?
    @Published var localEngineErrorMessage: String?
    @Published var modelSelectionRevision = 0
    @Published var modelParameterRevision = 0

    // MARK: - Private Properties
    let chatPersistence: ChatPersistenceServicing
    let vlmExecutor: ChatModelExecuting
    let runtimeManager: ChatRuntimeManaging
    let toolExecutor: ChatToolExecutionServicing
    let modelSelectionStore: ModelSelectionStore
    let modelParameterStore: ModelParameterStore
    let streamingContentStore = StreamingMessageContentStore()
    var generationTask: Task<Void, Never>?
    let maxAutoToolDepth = 4
    var pendingDownloadMonitorTask: Task<Void, Never>?
    var pendingEngineDownloadReason: PendingEngineDownloadReason?
    var lyricsDraftTask: Task<Void, Never>?
    var activeMusicGenerationDraft: MusicGenerationDraft?
    private var isCommittingComposerInput = false

    // MARK: - Computed Properties
    var hasSelectedImages: Bool {
        !selectedImagePaths.isEmpty
    }

    var selectedChat: Chat? {
        chats.first { $0.id == selectedChatId }
    }

    var recentChats: [Chat] {
        if chatsSortRevision == 0 {
            // First access after init; populate cache.
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

        // Re-check revision before caching (in case chats were mutated during computation).
        guard _sidebarMetadataRevision == chatsSortRevision else {
            // Fall through to return computed value without caching.
            return ChatSidebarMetadata(icon: icon, preview: preview)
        }
        let metadata = ChatSidebarMetadata(icon: icon, preview: preview)
        sidebarMetadataCache[chat.id] = metadata
        return metadata
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
            return visibleText
        }
        return message.isUser ? "Message" : "Assistant response"
    }

    var isInputDisabled: Bool {
        isPythonLoading || isModelLoading || isGenerating || isDraftingMusicLyrics
    }

    private var generatedImagesDirectory: URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return baseURL
            .appendingPathComponent("MLXHub", isDirectory: true)
            .appendingPathComponent("GeneratedImages", isDirectory: true)
    }

    private var generatedSpeechDirectory: URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return baseURL
            .appendingPathComponent("MLXHub", isDirectory: true)
            .appendingPathComponent("GeneratedSpeech", isDirectory: true)
    }

    private var generatedMusicDirectory: URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return baseURL
            .appendingPathComponent("MLXHub", isDirectory: true)
            .appendingPathComponent("GeneratedMusic", isDirectory: true)
    }

    // MARK: - Initialization
    init(
        chatPersistence: ChatPersistenceServicing? = nil,
        vlmExecutor: ChatModelExecuting? = nil,
        runtimeManager: ChatRuntimeManaging? = nil,
        toolExecutor: ChatToolExecutionServicing? = nil,
        userDefaults: UserDefaults = .standard
    ) {
        let resolvedChatPersistence = chatPersistence ?? LocalChatPersistenceService()
        let resolvedRuntimeManager = runtimeManager ?? RuntimeManager()
        let resolvedExecutor = vlmExecutor ?? VLMExecutor()

        self.chatPersistence = resolvedChatPersistence
        self.runtimeManager = resolvedRuntimeManager
        self.vlmExecutor = resolvedExecutor
        self.modelSelectionStore = ModelSelectionStore(userDefaults: userDefaults)
        self.modelParameterStore = ModelParameterStore(userDefaults: userDefaults)
        self.toolExecutor = toolExecutor ?? DefaultChatToolExecutionService(
            modelExecutor: resolvedExecutor,
            runtimeManager: resolvedRuntimeManager,
            webSearchService: MCPWebSearchService()
        )

        if let storedChatModel = modelSelectionStore.selectedProfile(for: .vision)?.aiModel {
            selectedModel = storedChatModel
        }

        loadConversationHistory()
        self.vlmExecutor.delegate = self
    }

    // MARK: - Persistence
    private func loadConversationHistory() {
        chats = chatPersistence.loadChats().map { chat in
            var restoredChat = chat
            restoredChat.messages = chat.messages.map { message in
                var restoredMessage = message
                restoredMessage.isStreaming = false
                return restoredMessage
            }
            return restoredChat
        }

        selectedChatId = chatPersistence.loadSelectedChatId()

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

    func persistConversationHistory() {
        chatPersistence.saveChats(chats)
        chatPersistence.saveSelectedChatId(selectedChatId)
    }

    /// Coalesces rapid persistence calls (e.g. finalize + stop in quick succession)
    /// into a single write after a short debounce interval.
    func scheduleConversationPersistence() {
        chatPersistence.scheduleSave(chats, selectedChatId: selectedChatId)
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
        chatPersistence.saveSelectedChatId(selectedChatId)
    }

    func renameChat(_ chatId: UUID, to title: String) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = chats.firstIndex(where: { $0.id == chatId }) else { return }

        chats[index].title = trimmedTitle.isEmpty ? "New chat" : trimmedTitle
        chats[index].timestamp = Date()
        persistConversationHistory()
    }

    func deleteChat(_ chat: Chat) {
        if selectedChatId == chat.id {
            cancelGeneration()
        }

        chats.removeAll { $0.id == chat.id }
        chatPersistence.deleteAttachments(for: chat.id)

        if selectedChatId == chat.id {
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
        }

        persistConversationHistory()
    }

    func sendMessage() {
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
        let images = chatPersistence.persistAttachments(
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

        let messageText = trimmedInput
        isCommittingComposerInput = true
        inputText = ""
        isCommittingComposerInput = false
        selectedImagePaths = []

        startGeneration(for: messageText, images: images)
    }

    private func startGeneration(for messageText: String, images: [URL]) {
        // Start generation
        print("[ChatVM] Starting generation task for: \(messageText.prefix(50))...")
        generationTask = Task {
            if selectedTool == .music {
                await generateMusicDirectly(for: messageText)
            } else {
                await generateResponse(for: messageText, images: images)
            }
        }
    }

    func cancelGeneration() {
        print("[ChatVM] cancelGeneration called")
        generationTask?.cancel()
        generationTask = nil
        cancelMusicLyricsDraft()
        activeMusicGenerationDraft = nil
        
        if let messageId = streamingMessageId {
            markMessageStopped(messageId)
        }

        isGenerating = false
        streamingMessageId = nil
        isModelLoading = false
        loadingMessage = ""

        generationTask = Task {
            await vlmExecutor.terminate()
        }

        // Flush any pending debounced writes so state is preserved.
        chatPersistence.flushPendingSave()
        persistConversationHistory()
    }

    private func generateMusicDirectly(for prompt: String) async {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return }

        do {
            let musicProfile = profile(for: .music)
            let model = musicProfile.downloadableModel
            setActiveEngineModel(name: musicProfile.name, role: .music)

            guard await requireDownloadedModel(model: model, operation: "Music generation") else {
                activeMusicGenerationDraft = nil
                return
            }

            try await ensureLocalRuntimeReady()

            isGenerating = true
            loadingMessage = "Generating music..."

            let aiMessage = Message(
                content: "",
                isUser: false,
                timestamp: Date(),
                isStreaming: true
            )

            if let index = chats.firstIndex(where: { $0.id == selectedChatId }) {
                _ = streamingContentStore.begin(messageId: aiMessage.id)
                chats[index].messages.append(aiMessage)
                chats[index].timestamp = Date()
                streamingMessageId = aiMessage.id
            }

            var parameters = defaultMusicParameters(caption: trimmedPrompt)
            applyMusicComposerOverrides(to: &parameters, prompt: trimmedPrompt)

            let toolCall = ExecutionToolCall(
                id: "direct-music-\(UUID().uuidString)",
                function: ExecutionToolCallFunction(
                    name: "generate_music",
                    arguments: jsonArguments(parameters)
                )
            )
            var toolMessages = [ExecutionMessage(role: .assistant, toolCalls: [toolCall])]

            await executeMusicGenerationToolCall(toolCall, messages: &toolMessages, prompt: trimmedPrompt)

            if let toolContent = toolMessages.last(where: { $0.role == .tool })?.content,
               isModelDownloadRequiredMessage(toolContent) {
                removeAssistantMessage(aiMessage.id)
            } else {
                if let toolContent = toolMessages.last(where: { $0.role == .tool })?.content,
                   !toolContent.contains("already displayed") {
                    updateStreamingMessage(aiMessage.id, content: toolContent)
                }
                markMessageStopped(aiMessage.id)
            }

            activeMusicGenerationDraft = nil
            isGenerating = false
            isModelLoading = false
            streamingMessageId = nil
            generationTask = nil
            loadingMessage = ""
        } catch {
            activeMusicGenerationDraft = nil
            isPythonLoading = false
            isModelLoading = false
            isGenerating = false
            generationTask = nil
            loadingMessage = ""
            if Task.isCancelled {
                if let streamingMessageId {
                    markMessageStopped(streamingMessageId)
                }
                streamingMessageId = nil
                return
            }
            if let streamingMessageId {
                handleGenerationError(error, replacingMessageId: streamingMessageId)
            } else {
                handleGenerationError(error)
            }
        }
    }

    private func generateResponse(for prompt: String, images: [URL], toolMessages: [ExecutionMessage]? = nil, toolDepth: Int = 0) async {
        do {
            let isImageGeneration = selectedTool == .image
            let isSpeechGeneration = selectedTool == .tts
            let isMusicGeneration = selectedTool == .music
            let isDeepResearch = selectedTool == .research

            let selectedCapabilityProfile = profile(for: selectedTool)
            let activeChatProfile = profile(for: .chat)
            let activeChatModel = activeChatProfile.aiModel ?? selectedModel
            let executionProfile = (isImageGeneration || isSpeechGeneration) ? selectedCapabilityProfile : activeChatProfile
            let resolvedModelId = executionProfile.modelId
            let activeModelName = executionProfile.name
            let activeBackend: RuntimeBackend = isImageGeneration ? .image : (isSpeechGeneration ? .audio : .vlm)
            let modelWillLoad = !isLoadedEngineModel(modelId: resolvedModelId, backend: activeBackend)
            setActiveEngineModel(
                name: activeModelName,
                role: isImageGeneration ? .image : (isSpeechGeneration ? .speech : .chat)
            )
            let requiredModel = executionProfile.downloadableModel

            if let selectionRequirement = downloadRequirementForCurrentSelection(),
               selectionRequirement.modelId != requiredModel.modelId {
                guard await requireDownloadedModel(
                    model: selectionRequirement,
                    operation: operationNameForCurrentSelection()
                ) else {
                    return
                }
            }

                guard await requireDownloadedModel(model: requiredModel, operation: isImageGeneration ? "Image generation" : (isSpeechGeneration ? "Speech generation" : "Chat")) else {
                return
            }

            if runtimeManager.state != .ready {
                isPythonLoading = true
                loadingMessage = "Initializing Python runtime..."
                try await runtimeManager.initialize()
                try await vlmExecutor.initialize()
                isPythonLoading = false
            }

            if !vlmExecutor.isReady {
                try await vlmExecutor.initialize()
            }

            if modelWillLoad {
                isModelLoading = true
                loadingMessage = "Loading \(activeModelName)..."

                do {
                    try await loadModel(resolvedModelId)
                } catch {
                    isModelLoading = false
                    throw error
                }
                // isModelLoading will be set to false in processStream when .complete or .error is received
            }

            isGenerating = true

            let aiMessage: Message
            let isFollowUp = toolMessages != nil

            if isFollowUp {
                guard let existingId = streamingMessageId,
                      let chatIndex = chats.firstIndex(where: { $0.id == selectedChatId }),
                      let messageIndex = chats[chatIndex].messages.firstIndex(where: { $0.id == existingId }) else {
                    isGenerating = false
                    return
                }
                _ = streamingContentStore.begin(messageId: existingId, initialText: chats[chatIndex].messages[messageIndex].content)
                aiMessage = chats[chatIndex].messages[messageIndex]
                loadingMessage = "Using tool result..."
            } else {
                let initialToolCall: ToolCall?
                if isImageGeneration {
                    initialToolCall = ToolCall(toolName: "\(executionProfile.name) image generation", status: prompt, icon: "photo")
                } else if isSpeechGeneration {
                    initialToolCall = ToolCall(toolName: "\(executionProfile.name) speech generation", status: prompt, icon: "waveform")
                } else {
                    initialToolCall = nil
                }

                aiMessage = Message(
                    content: "",
                    isUser: false,
                    timestamp: Date(),
                    toolCall: initialToolCall,
                    isStreaming: true
                )

                if let index = chats.firstIndex(where: { $0.id == selectedChatId }) {
                    _ = streamingContentStore.begin(messageId: aiMessage.id)
                    chats[index].messages.append(aiMessage)
                    chats[index].timestamp = Date()
                    streamingMessageId = aiMessage.id
                }
            }

            let tools: [[String: Any]]? = (isImageGeneration || isSpeechGeneration) ? nil : (isMusicGeneration ? [musicGenerationTool] : availableTools(toolDepth: toolDepth))
            let allowedToolNames = toolNames(from: tools)

            var messages: [ExecutionMessage]
            if let toolMessages {
                messages = toolMessages
            } else {
                messages = []
                var systemContent = isDeepResearch ? deepResearchSystemPrompt : systemPrompt
                systemContent += "\n\n\(toolAvailabilityInstruction(allowedToolNames: allowedToolNames))"

                if isMusicGeneration {
                    musicIntentState = musicIntentStateForCurrentComposer(prompt: prompt)
                    systemContent += "\n\n\(musicIntentState.systemInstruction)"
                    if let composerInstruction = musicComposerInstruction(prompt: prompt) {
                        systemContent += "\n\n\(composerInstruction)"
                    }
                }

                messages.append(ExecutionMessage(role: .system, content: systemContent))

                if let chat = selectedChat {
                    for message in contextMessages(from: chat, excluding: aiMessage.id) {
                        let role: MessageRole = message.isUser ? .user : .assistant
                        messages.append(ExecutionMessage(role: role, content: message.content))
                    }
                }

                if isDeepResearch {
                    let researchContext = await seedDeepResearchContext(prompt: prompt)
                    messages.append(contentsOf: researchContext)
                }
            }

            let chatExecutionParameters = modelParameterStore.executionParameters(for: activeChatProfile)
            let mediaExecutionParameters = isImageGeneration || isSpeechGeneration
                ? modelParameterStore.executionParameters(for: executionProfile)
                : nil
            let enableThinking = (chatExecutionParameters["enable_thinking"] as? Bool) ?? activeChatModel.enableThinking
            let chatTemplateKwargs: [String: Any]? = !isImageGeneration && !isSpeechGeneration && !isMusicGeneration && activeChatProfile.modelId.lowercased().contains("qwen")
                ? ["enable_thinking": enableThinking]
                : nil

            let outputDirectory = isImageGeneration ? generatedImagesDirectory : (isSpeechGeneration ? generatedSpeechDirectory : nil)
            let isDirectMediaGeneration = isImageGeneration || isSpeechGeneration
            let maxTokens = (chatExecutionParameters["max_tokens"] as? Int) ?? activeChatModel.defaultMaxTokens
            let temperature = (chatExecutionParameters["temperature"] as? Double) ?? activeChatModel.temperatureRange.default
            let topP = (chatExecutionParameters["top_p"] as? Double) ?? activeChatModel.topP
            let topK = (chatExecutionParameters["top_k"] as? Int) ?? activeChatModel.topK
            let minP = (chatExecutionParameters["min_p"] as? Double) ?? activeChatModel.minP
            let repetitionPenalty = (chatExecutionParameters["repetition_penalty"] as? Double) ?? activeChatModel.repetitionPenalty

            let request = ExecutionRequest(
                backend: activeBackend,
                modelId: resolvedModelId,
                messages: isDirectMediaGeneration ? [ExecutionMessage(role: .user, content: prompt)] : messages,
                images: images.isEmpty ? nil : images,
                outputDirectory: outputDirectory,
                maxTokens: isDirectMediaGeneration ? 0 : maxTokens,
                temperature: isDirectMediaGeneration ? 1.0 : temperature,
                topP: isDirectMediaGeneration ? nil : topP,
                topK: isDirectMediaGeneration ? nil : topK,
                minP: isDirectMediaGeneration ? nil : minP,
                repetitionPenalty: isDirectMediaGeneration ? nil : repetitionPenalty,
                chatTemplateKwargs: chatTemplateKwargs,
                tools: tools,
                parameters: mediaExecutionParameters
            )

            let stream = try await vlmExecutor.execute(request: request)

            await processStream(
                stream,
                forMessage: aiMessage.id,
                messages: messages,
                images: images,
                prompt: prompt,
                toolDepth: toolDepth,
                hasTools: tools != nil,
                allowedToolNames: allowedToolNames,
                isImageGeneration: isImageGeneration,
                isSpeechGeneration: isSpeechGeneration,
                isMusicGeneration: isMusicGeneration
            )

        } catch {
            if Task.isCancelled {
                return
            }
            handleGenerationError(error)
        }
    }

    private func executeToolCall(_ toolCall: ExecutionToolCall, messages: inout [ExecutionMessage], images: [URL], prompt: String) async {
        switch canonicalToolName(toolCall.function.name) {
        case "web_search":
            await executeWebSearchToolCall(toolCall, messages: &messages, prompt: prompt)
        case "generate_image":
            await executeImageGenerationToolCall(toolCall, messages: &messages, images: images, prompt: prompt)
        case "create_speech":
            await executeSpeechGenerationToolCall(toolCall, messages: &messages, prompt: prompt)
        case "generate_music", "create_music":
            await executeMusicGenerationToolCall(toolCall, messages: &messages, prompt: prompt)
        default:
            messages.append(ExecutionMessage(
                role: .tool,
                content: "Unsupported tool: \(toolCall.function.name)",
                toolCallId: toolCall.id,
                name: toolCall.function.name
            ))
        }
    }

    private func executeWebSearchToolCall(_ toolCall: ExecutionToolCall, messages: inout [ExecutionMessage], prompt: String) async {
        var searchQuery = prompt
        if let decoded = decodeToolArguments(toolCall),
           let query = decoded["query"] as? String {
            searchQuery = query
        }

        loadingMessage = "Searching for \"\(searchQuery)\"..."
        beginToolCallProgress(
            toolName: "Web search",
            status: searchQuery,
            icon: "magnifyingglass"
        )
        let result = await toolExecutor.executeWebSearch(query: searchQuery)
        messages.append(ExecutionMessage(role: .tool, content: result, toolCallId: toolCall.id, name: "web_search"))
    }

    private func executeImageGenerationToolCall(_ toolCall: ExecutionToolCall, messages: inout [ExecutionMessage], images: [URL], prompt: String) async {
        var imagePrompt = prompt
        if let decoded = decodeToolArguments(toolCall),
           let decodedPrompt = decoded["prompt"] as? String,
           !decodedPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            imagePrompt = decodedPrompt
        }

        let imageProfile = profile(for: .image)
        let model = imageProfile.downloadableModel
        await executeMediaToolCall(
            toolCall,
            messages: &messages,
            plan: ChatMediaToolExecutionPlan(
                functionName: "generate_image",
                toolName: "\(imageProfile.name) image generation",
                status: imagePrompt,
                icon: "photo",
                details: [],
                model: model,
                request: ExecutionRequest(
                    backend: .image,
                    modelId: imageProfile.modelId,
                    messages: [ExecutionMessage(role: .user, content: imagePrompt)],
                    images: images.isEmpty ? nil : images,
                    outputDirectory: generatedImagesDirectory,
                    maxTokens: 0,
                    temperature: 1.0,
                    parameters: modelParameterStore.executionParameters(for: imageProfile)
                ),
                loadingStatus: "Generating image...",
                operationName: "Image generation",
                unavailablePrefix: "Image generation unavailable",
                noOutputMessage: "Image generation finished without returning an image.",
                completionHint: "The generated image is already displayed in the app UI. In your final response, use text only. Do not include markdown image syntax, image URLs, local file paths, HTML image tags, data URLs, or links to external image services such as Pollinations.",
                attachmentKind: .image
            )
        )
    }

    private func executeSpeechGenerationToolCall(_ toolCall: ExecutionToolCall, messages: inout [ExecutionMessage], prompt: String) async {
        var speechText = prompt
        if let decoded = decodeToolArguments(toolCall),
           let decodedText = decoded["text"] as? String,
           !decodedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            speechText = decodedText
        }

        let speechProfile = profile(for: .tts)
        let model = speechProfile.downloadableModel
        await executeMediaToolCall(
            toolCall,
            messages: &messages,
            plan: ChatMediaToolExecutionPlan(
                functionName: "create_speech",
                toolName: "\(speechProfile.name) speech generation",
                status: speechText,
                icon: "waveform",
                details: [],
                model: model,
                request: ExecutionRequest(
                    backend: .audio,
                    modelId: speechProfile.modelId,
                    messages: [ExecutionMessage(role: .user, content: speechText)],
                    outputDirectory: generatedSpeechDirectory,
                    maxTokens: 0,
                    temperature: 1.0,
                    parameters: modelParameterStore.executionParameters(for: speechProfile)
                ),
                loadingStatus: "Generating speech...",
                operationName: "Speech generation",
                unavailablePrefix: "Speech generation unavailable",
                noOutputMessage: "Speech generation finished without returning audio.",
                completionHint: "The generated audio is already displayed in the app UI. In your final response, use text only. Do not include local file paths.",
                attachmentKind: .audio
            )
        )
    }

    private func executeMusicGenerationToolCall(_ toolCall: ExecutionToolCall, messages: inout [ExecutionMessage], prompt: String) async {
        var parameters = defaultMusicParameters(caption: prompt)
        if let decoded = decodeToolArguments(toolCall) {
            if let caption = decoded["caption"] as? String,
               !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parameters["caption"] = caption
            }
            if let lyrics = decoded["lyrics"] as? String {
                parameters["lyrics"] = lyrics
            }
            if let duration = decoded["duration"] {
                parameters["duration"] = normalizedMusicNumber(duration)
            }
            if let instrumental = decoded["instrumental"] {
                parameters["instrumental"] = normalizedMusicBool(instrumental) ?? instrumental
            }
            if let bpm = decoded["bpm"] {
                parameters["bpm"] = normalizedMusicNumber(bpm)
            }
            if let keyscale = decoded["keyscale"] as? String {
                parameters["keyscale"] = keyscale
            }
            if let timesignature = decoded["timesignature"] as? String {
                parameters["timesignature"] = timesignature
            }
            if let vocalLanguage = decoded["vocal_language"] as? String {
                parameters["vocal_language"] = vocalLanguage
            }
        }
        applyMusicComposerOverrides(to: &parameters, prompt: prompt)
        applyAutomaticInstrumentalFallback(to: &parameters, prompt: prompt)

        let musicPrompt = (parameters["caption"] as? String) ?? prompt
        musicIntentState = musicIntentStateForCurrentComposer(prompt: prompt, parameters: parameters)
        if let blockedToolMessage = musicIntentState.blockedToolMessage {
            messages.append(ExecutionMessage(
                role: .tool,
                content: blockedToolMessage,
                toolCallId: toolCall.id,
                name: "generate_music"
            ))
            return
        }

        let musicProfile = profile(for: .music)
        let model = musicProfile.downloadableModel
        await executeMediaToolCall(
            toolCall,
            messages: &messages,
            plan: ChatMediaToolExecutionPlan(
                functionName: "generate_music",
                toolName: "\(musicProfile.name) music generation",
                status: musicPrompt,
                icon: "music.note",
                details: musicToolCallDetails(parameters),
                model: model,
                request: ExecutionRequest(
                    backend: .music,
                    modelId: musicProfile.modelId,
                    messages: [ExecutionMessage(role: .user, content: musicPrompt)],
                    outputDirectory: generatedMusicDirectory,
                    maxTokens: 0,
                    temperature: 1.0,
                    parameters: parameters
                ),
                loadingStatus: "Generating music...",
                operationName: "Music generation",
                unavailablePrefix: "Music generation unavailable",
                noOutputMessage: "Music generation finished without returning audio.",
                completionHint: "The generated music is already displayed in the app UI. In your final response, use text only. Do not include local file paths.",
                attachmentKind: .audio
            )
        )
    }

    private func loadModel(_ modelId: String) async throws {
        // The executor handles lazy loading, we just need to trigger it
        // by sending a request
    }

    private func processStream(
        _ stream: AsyncStream<ExecutionEvent>,
        forMessage messageId: UUID,
        messages: [ExecutionMessage]? = nil,
        images: [URL]? = nil,
        prompt: String? = nil,
        toolDepth: Int = 0,
        hasTools: Bool = false,
        allowedToolNames: Set<String> = [],
        isImageGeneration: Bool = false,
        isSpeechGeneration: Bool = false,
        isMusicGeneration: Bool = false
    ) async {
        var fullResponse = ""
        var renderedResponse = ""
        var pendingRenderDelta = ""
        var lastRenderTime = Date.distantPast
        let minimumRenderInterval: TimeInterval = 1.0 / 60.0
        let generationStartedAt = Date()
        var firstOutputAt: Date?
        var observedTokenEvents = 0
        var toolBufferTokenCount = 0
        let overallTimeout: TimeInterval = 300.0  // 5 minute overall generation timeout
        var timeoutTask: Task<Void, Never>?
#if DEBUG
        var tokenIndex = 0
#endif

        func currentPerformanceMetrics(usage: TokenUsage) -> GenerationPerformanceMetrics {
            let outputTokenCount = usage.completionTokens > 0 ? usage.completionTokens : observedTokenEvents
            let appMeasuredMetrics = GenerationPerformanceMetrics.measured(
                startedAt: generationStartedAt,
                firstOutputAt: firstOutputAt,
                outputTokenCount: outputTokenCount
            )
            let metrics = GenerationPerformanceMetrics.measured(
                startedAt: generationStartedAt,
                firstOutputAt: firstOutputAt,
                outputTokenCount: outputTokenCount,
                backendTokensPerSecond: usage.tokensPerSecond
            )
#if DEBUG
            if let bridgeTokensPerSecond = usage.tokensPerSecond,
               let appTokensPerSecond = appMeasuredMetrics.tokensPerSecond {
                ChatStreamDiagnostics.log("performance.compare bridgeTokS=\(String(format: "%.2f", bridgeTokensPerSecond)) appTokS=\(String(format: "%.2f", appTokensPerSecond)) outputTokens=\(outputTokenCount)")
            }
#endif
            return metrics
        }

        func renderStreamingResponse(force: Bool = false, tokenIndex: Int? = nil, tokenReceivedAt: TimeInterval? = nil) {
            guard !pendingRenderDelta.isEmpty else { return }

            let now = Date()
            guard force || renderedResponse.isEmpty || now.timeIntervalSince(lastRenderTime) >= minimumRenderInterval else {
                return
            }

            appendStreamingMessage(messageId, content: pendingRenderDelta)
            renderedResponse += pendingRenderDelta
            pendingRenderDelta = ""
            lastRenderTime = now

#if DEBUG
            if let tokenIndex, let tokenReceivedAt {
                let updateFinishedAt = ChatStreamDiagnostics.now()
                ChatStreamDiagnostics.log("message.rendered index=\(tokenIndex) responseChars=\(fullResponse.count) elapsedMs=\(String(format: "%.2f", (updateFinishedAt - tokenReceivedAt) * 1000))")
            }
#endif
        }
        
        // Set up a timeout to terminate the executor if generation takes too long
        timeoutTask = Task { [weak vlmExecutor] in
            try? await Task.sleep(nanoseconds: UInt64(overallTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            print("[ChatVM] Generation timed out after \(overallTimeout)s")
            await vlmExecutor?.terminate()
        }

        for await event in stream {
            if Task.isCancelled {
                markMessageStopped(messageId)
                break
            }
            
            switch event {
            case .started:
                break
                
            case .token(let token):
#if DEBUG
                tokenIndex += 1
                let tokenReceivedAt = ChatStreamDiagnostics.now()
                ChatStreamDiagnostics.log("token.received index=\(tokenIndex) tokenChars=\(token.count) responseCharsBefore=\(fullResponse.count)")
#endif
                guard !token.isEmpty else {
#if DEBUG
                    ChatStreamDiagnostics.log("token.emptySkipped index=\(tokenIndex) responseChars=\(fullResponse.count)")
#endif
                    continue
                }

                firstOutputAt = firstOutputAt ?? Date()
                observedTokenEvents += 1
                fullResponse += token
                if hasTools && shouldBufferToolEnabledOutput(fullResponse) {
                    toolBufferTokenCount += 1
                    // Once we detect a tool call, keep buffering — never flash raw tool call
                    // JSON on screen. The tool call will be parsed at .complete time.
                    loadingMessage = "Preparing tool..."
#if DEBUG
                    ChatStreamDiagnostics.log("token.buffered index=\(tokenIndex) responseChars=\(fullResponse.count)")
#endif
                } else {
                    if renderedResponse.isEmpty, pendingRenderDelta.isEmpty, fullResponse != token {
                        pendingRenderDelta = fullResponse
                    } else {
                        pendingRenderDelta += token
                    }
#if DEBUG
                    renderStreamingResponse(force: renderedResponse.isEmpty, tokenIndex: tokenIndex, tokenReceivedAt: tokenReceivedAt)
#else
                    renderStreamingResponse(force: renderedResponse.isEmpty)
#endif
                }
                if observedTokenEvents % 3 == 0 {
                    await Task.yield()
                }

            case .image(let imageURL):
                firstOutputAt = firstOutputAt ?? Date()
                appendGeneratedImage(imageURL, toMessage: messageId)

            case .audio(let audioURL):
                firstOutputAt = firstOutputAt ?? Date()
                appendGeneratedAudio(audioURL, toMessage: messageId)
                
            case .complete(let response, let usage):
#if DEBUG
                ChatStreamDiagnostics.log("stream.complete responseChars=\(response.count)")
#endif
                fullResponse = response
                let performanceMetrics = currentPerformanceMetrics(usage: usage)
                if hasTools,
                   let plainTextToolCall = plainTextToolCall(from: response, prompt: prompt),
                   var currentMessages = messages,
                   let currentImages = images,
                   let currentPrompt = prompt {
                    guard isToolAllowed(plainTextToolCall.function.name, allowedToolNames: allowedToolNames) else {
                        finalizeMessage(
                            messageId,
                            content: "That tool is not available in this mode. Switch to Auto or the matching generation mode to use it.",
                            usage: usage,
                            clearToolCall: false,
                            performanceMetrics: performanceMetrics
                        )
                        isGenerating = false
                        isModelLoading = false
                        streamingMessageId = nil
                        generationTask = nil
                        loadingMessage = ""
                        return
                    }
                    guard isTerminalMediaTool(plainTextToolCall.function.name) || toolDepth < maxAutoToolDepth else {
                        finalizeMessage(
                            messageId,
                            content: "Maximum tool call depth reached. Cannot execute more tool calls.",
                            usage: usage,
                            clearToolCall: false,
                            performanceMetrics: performanceMetrics
                        )
                        isGenerating = false
                        isModelLoading = false
                        streamingMessageId = nil
                        generationTask = nil
                        loadingMessage = ""
                        return
                    }

                    updateStreamingMessage(messageId, content: "")
                    currentMessages.append(ExecutionMessage(role: .assistant, toolCalls: [plainTextToolCall]))
                    await executeToolCall(plainTextToolCall, messages: &currentMessages, images: currentImages, prompt: currentPrompt)

                    if isTerminalMediaTool(plainTextToolCall.function.name) {
                        if let toolContent = currentMessages.last(where: { $0.role == .tool })?.content,
                           !isModelDownloadRequiredMessage(toolContent),
                           !toolContent.contains("already displayed") {
                            updateStreamingMessage(messageId, content: toolContent)
                        }
                        if let toolContent = currentMessages.last(where: { $0.role == .tool })?.content,
                           isModelDownloadRequiredMessage(toolContent) {
                            removeAssistantMessage(messageId)
                        } else {
                            markMessageStopped(messageId)
                        }
                        isGenerating = false
                        isModelLoading = false
                        if isMusicGeneration {
                            activeMusicGenerationDraft = nil
                        }
                        streamingMessageId = nil
                        generationTask = nil
                        loadingMessage = ""
                        return
                    }

                    await generateResponse(for: currentPrompt, images: currentImages, toolMessages: currentMessages, toolDepth: toolDepth + 1)
                    return
                }

                finalizeMessage(
                    messageId,
                    content: (isImageGeneration || isSpeechGeneration) ? "" : fullResponse,
                    usage: usage,
                    clearToolCall: isImageGeneration || isSpeechGeneration,
                    performanceMetrics: performanceMetrics
                )
                if isMusicGeneration {
                    activeMusicGenerationDraft = nil
                }
                isGenerating = false
                streamingMessageId = nil
                generationTask = nil
                loadingMessage = ""
                
            case .toolCalls(let toolCalls):
                guard var currentMessages = messages, let currentImages = images, let currentPrompt = prompt else { break }
                let executableToolCalls = toolCalls
                    .filter { isToolAllowed($0.function.name, allowedToolNames: allowedToolNames) }
                    .map(canonicalToolCall)
                guard !executableToolCalls.isEmpty else {
                    finalizeMessage(
                        messageId,
                        content: "That tool is not available in this mode. Switch to Auto or the matching generation mode to use it.",
                        usage: TokenUsage(promptTokens: 0, completionTokens: 0),
                        clearToolCall: false,
                        performanceMetrics: currentPerformanceMetrics(usage: TokenUsage(promptTokens: 0, completionTokens: 0))
                    )
                    isGenerating = false
                    isModelLoading = false
                    streamingMessageId = nil
                    generationTask = nil
                    loadingMessage = ""
                    return
                }
                guard toolDepth < maxAutoToolDepth else {
                    finalizeMessage(
                        messageId,
                        content: "Maximum tool call depth reached. Cannot execute more tool calls.",
                        usage: TokenUsage(promptTokens: 0, completionTokens: 0),
                        clearToolCall: false,
                        performanceMetrics: currentPerformanceMetrics(usage: TokenUsage(promptTokens: 0, completionTokens: 0))
                    )
                    isGenerating = false
                    isModelLoading = false
                    streamingMessageId = nil
                    generationTask = nil
                    loadingMessage = ""
                    return
                }
                let hasTerminalMediaTool = executableToolCalls.contains { isTerminalMediaTool($0.function.name) }
                for toolCall in executableToolCalls {
                    currentMessages.append(ExecutionMessage(role: .assistant, toolCalls: [toolCall]))
                    await executeToolCall(toolCall, messages: &currentMessages, images: currentImages, prompt: currentPrompt)
                }
                if hasTerminalMediaTool {
                    if let toolContent = currentMessages.last(where: { $0.role == .tool })?.content,
                       !isModelDownloadRequiredMessage(toolContent),
                       !toolContent.contains("already displayed") {
                        updateStreamingMessage(messageId, content: toolContent)
                    }
                    if let toolContent = currentMessages.last(where: { $0.role == .tool })?.content,
                       isModelDownloadRequiredMessage(toolContent) {
                        removeAssistantMessage(messageId)
                    } else {
                        markMessageStopped(messageId)
                    }
                    isGenerating = false
                    isModelLoading = false
                    if isMusicGeneration {
                        activeMusicGenerationDraft = nil
                    }
                    streamingMessageId = nil
                    generationTask = nil
                    loadingMessage = ""
                    return
                }
                await generateResponse(for: currentPrompt, images: currentImages, toolMessages: currentMessages, toolDepth: toolDepth + 1)
                return

            case .error(let error):
                if isMusicGeneration {
                    activeMusicGenerationDraft = nil
                }
                handleGenerationError(error, replacingMessageId: messageId)
                isGenerating = false
                streamingMessageId = nil
                generationTask = nil
                
            case .progress(let message):
                loadingMessage = message
            }
        }

        timeoutTask?.cancel()
        timeoutTask = nil

        if Task.isCancelled {
            renderStreamingResponse(force: true)
            if isMusicGeneration {
                activeMusicGenerationDraft = nil
            }
            isGenerating = false
            streamingMessageId = nil
            generationTask = nil
        }
    }

}
