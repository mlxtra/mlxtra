import SwiftUI
import Combine

#if DEBUG
enum ChatStreamDiagnostics {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["MLXTRA_STREAM_DIAGNOSTICS"] == "1"
            || UserDefaults.standard.bool(forKey: "MLXtra.streamDiagnostics")
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
class ChatViewModel: ObservableObject {
    static var generationTimeout: TimeInterval = 300.0
    static let launchModelPreloadEnabledKey = "MLXtra.preloadLocalVLMOnLaunch"
    static let defaultLaunchModelPreloadDelayNanoseconds: UInt64 = 2_500_000_000

    nonisolated static func defaultLaunchModelPreloadPressureCheck() -> Bool {
        let thermalState = ProcessInfo.processInfo.thermalState
        return thermalState == .serious || thermalState == .critical
    }

    nonisolated static func defaultLaunchModelPreloadRuntimeCompatibilityCheck(
        _ profile: ModelCapabilityProfile
    ) -> Bool {
        profile.isRuntimeCompatible()
    }

    private var cachedRecentChats: [Chat] = []
    private var _cachedRecentChatsRevision: UInt = 0
    private var chatsSortRevision: UInt = 0
    private var sidebarMetadataCache: [UUID: ChatSidebarMetadata] = [:]
    private var _sidebarMetadataRevision: UInt = 0

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
    @Published var isToolMenuOpen: Bool = false
    @Published var isModelMenuOpen: Bool = false
    @Published var selectedImagePaths: [URL] = []

    @Published var isPythonLoading: Bool = false
    @Published var isModelLoading: Bool = false
    @Published var isPreloadingLocalModel: Bool = false
    @Published var isGenerating: Bool = false
    @Published var isDraftingMusicLyrics: Bool = false
    @Published var loadingMessage: String = ""
    @Published var modelLoadProgress: ModelLoadProgress?
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
    @Published var composerFocusRequest = 0

    let chatPersistence: ChatPersistenceServicing
    let vlmExecutor: ChatModelExecuting
    let runtimeManager: ChatRuntimeManaging
    let toolExecutor: ChatToolExecutionServicing
    let modelSelectionStore: ModelSelectionStore
    let modelParameterStore: ModelParameterStore
    let userDefaults: UserDefaults
    let launchModelPreloadPressureCheck: () -> Bool
    let launchModelPreloadRuntimeCompatibilityCheck: (ModelCapabilityProfile) -> Bool
    let streamingContentStore = StreamingMessageContentStore()
    var generationTask: Task<Void, Never>?
    var launchModelPreloadTask: Task<Void, Never>?
    let maxAutoToolDepth = 4
    var pendingDownloadMonitorTask: Task<Void, Never>?
    var pendingEngineDownloadReason: PendingEngineDownloadReason?
    var lyricsDraftTask: Task<Void, Never>?
    var activeMusicGenerationDraft: MusicGenerationDraft?
    private var isCommittingComposerInput = false

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

    var isInputDisabled: Bool {
        isPythonLoading || isModelLoading || isGenerating || isDraftingMusicLyrics || generationTask != nil
    }

    private var generatedImagesDirectory: URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return baseURL
            .appendingPathComponent("MLXtra", isDirectory: true)
            .appendingPathComponent("GeneratedImages", isDirectory: true)
    }

    private var generatedSpeechDirectory: URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return baseURL
            .appendingPathComponent("MLXtra", isDirectory: true)
            .appendingPathComponent("GeneratedSpeech", isDirectory: true)
    }

    private var generatedMusicDirectory: URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return baseURL
            .appendingPathComponent("MLXtra", isDirectory: true)
            .appendingPathComponent("GeneratedMusic", isDirectory: true)
    }

    init(
        chatPersistence: ChatPersistenceServicing? = nil,
        vlmExecutor: ChatModelExecuting? = nil,
        runtimeManager: ChatRuntimeManaging? = nil,
        toolExecutor: ChatToolExecutionServicing? = nil,
        userDefaults: UserDefaults = .standard,
        launchModelPreloadPressureCheck: @escaping () -> Bool = ChatViewModel.defaultLaunchModelPreloadPressureCheck,
        launchModelPreloadRuntimeCompatibilityCheck: @escaping (ModelCapabilityProfile) -> Bool = ChatViewModel.defaultLaunchModelPreloadRuntimeCompatibilityCheck
    ) {
        let resolvedChatPersistence = chatPersistence ?? LocalChatPersistenceService()
        let resolvedRuntimeManager = runtimeManager ?? RuntimeManager()
        let resolvedExecutor = vlmExecutor ?? VLMExecutor()

        self.chatPersistence = resolvedChatPersistence
        self.runtimeManager = resolvedRuntimeManager
        self.vlmExecutor = resolvedExecutor
        self.userDefaults = userDefaults
        self.launchModelPreloadPressureCheck = launchModelPreloadPressureCheck
        self.launchModelPreloadRuntimeCompatibilityCheck = launchModelPreloadRuntimeCompatibilityCheck
        self.modelSelectionStore = ModelSelectionStore(userDefaults: userDefaults)
        self.modelParameterStore = ModelParameterStore(userDefaults: userDefaults)
        self.toolExecutor = toolExecutor ?? DefaultChatToolExecutionService(
            modelExecutor: resolvedExecutor,
            runtimeManager: resolvedRuntimeManager,
            webSearchService: MCPWebSearchService()
        )

        loadConversationHistory()
        self.vlmExecutor.delegate = self
    }

    deinit {
        launchModelPreloadTask?.cancel()
    }

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
        let images = chatPersistence.persistAttachments(
            selectedImagePaths,
            chatId: chatId,
            messageId: userMessageId
        )

        let messageContent = trimmedInput
        if images.isEmpty && trimmedInput.isEmpty {
            return
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
            
            if chats[index].messages.count == 1 {
                chats[index].title = ChatDisplayText.singleLine(
                    messageContent,
                    fallback: "Image attachment",
                    maxLength: MLXtraDesignSystem.TextLimit.generatedTitle
                )
            }

            persistConversationHistory()
        }

        let messageText = trimmedInput
        isCommittingComposerInput = true
        inputText = ""
        isCommittingComposerInput = false
        selectedImagePaths = []

        let request = makeGenerationRequest(chatId: chatId, prompt: messageText, images: images)
        startGeneration(request)
    }

    private func makeGenerationRequest(chatId: UUID, prompt: String, images: [URL]) -> ChatGenerationRequest {
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
            tool: selectedTool,
            profilesByModality: profilesByModality,
            parametersByModelId: parametersByModelId,
            selectionDownloadRequirement: downloadRequirementForCurrentSelection(),
            selectionOperationName: operationNameForCurrentSelection()
        )
    }

    private func startGeneration(_ request: ChatGenerationRequest) {
        guard generationTask == nil else { return }
#if DEBUG
        ChatStreamDiagnostics.log("generation.start promptChars=\(request.prompt.count)")
#endif
        generationTask = Task {
            await prepareLaunchModelPreloadForForegroundUse(request)
            if request.isMusicGeneration {
                await generateMusicDirectly(for: request)
            } else {
                await generateResponse(for: request)
            }
        }
    }

    func cancelGeneration() {
#if DEBUG
        ChatStreamDiagnostics.log("generation.cancel")
#endif
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
        cancelLaunchModelPreload()
        loadingMessage = ""

        Task {
            await vlmExecutor.terminate()
        }

        chatPersistence.flushPendingSave()
        persistConversationHistory()
    }

    private func generateMusicDirectly(for request: ChatGenerationRequest) async {
        let trimmedPrompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            finishActiveGeneration(isMusicGeneration: true)
            return
        }

        do {
            let musicProfile = request.profile(for: .music)
            let model = musicProfile.downloadableModel
            setActiveEngineModel(name: musicProfile.name, role: .music)

            guard await requireDownloadedModel(model: model, operation: "Music generation") else {
                finishActiveGeneration(isMusicGeneration: true)
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

            if let index = chats.firstIndex(where: { $0.id == request.chatId }) {
                _ = streamingContentStore.begin(messageId: aiMessage.id)
                chats[index].messages.append(aiMessage)
                chats[index].timestamp = Date()
                streamingMessageId = aiMessage.id
            }

            var parameters = defaultMusicParameters(
                caption: trimmedPrompt,
                profile: musicProfile,
                executionParameters: request.executionParameters(for: musicProfile)
            )
            applyMusicComposerOverrides(to: &parameters, prompt: trimmedPrompt)

            let toolCall = ExecutionToolCall(
                id: "direct-music-\(UUID().uuidString)",
                function: ExecutionToolCallFunction(
                    name: "generate_music",
                    arguments: jsonArguments(parameters)
                )
            )
            var toolMessages = [ExecutionMessage(role: .assistant, toolCalls: [toolCall])]

            await executeMusicGenerationToolCall(toolCall, messages: &toolMessages, prompt: trimmedPrompt, generation: request)

            finishTerminalMediaToolResult(
                messages: toolMessages,
                messageId: aiMessage.id,
                isMusicGeneration: true
            )
        } catch {
            activeMusicGenerationDraft = nil
            isPythonLoading = false
            isModelLoading = false
            isGenerating = false
            generationTask = nil
            loadingMessage = ""
            if Task.isCancelled {
                finishCancelledGeneration(isMusicGeneration: true)
                return
            }
            if let streamingMessageId {
                handleGenerationError(error, replacingMessageId: streamingMessageId)
            } else {
                handleGenerationError(error)
            }
        }
    }

    func generateResponse(for request: ChatGenerationRequest, toolMessages: [ExecutionMessage]? = nil, toolDepth: Int = 0) async {
        let cancellationIsMusicGeneration = request.isMusicGeneration
        do {
            let prompt = request.prompt
            let images = request.images
            let isImageGeneration = request.isImageGeneration
            let isSpeechGeneration = request.isSpeechGeneration
            let isMusicGeneration = request.isMusicGeneration
            let isDeepResearch = request.isDeepResearch

            let selectedCapabilityProfile = request.profile(for: request.tool)
            let activeChatProfile = request.profile(for: .chat)
            let executionProfile = (isImageGeneration || isSpeechGeneration) ? selectedCapabilityProfile : activeChatProfile
            let resolvedModelId = executionProfile.modelId
            let activeModelName = executionProfile.name
            let activeBackend: RuntimeBackend = executionProfile.backend
            let modelWillLoad = !isLoadedEngineModel(modelId: resolvedModelId, backend: activeBackend)
            setActiveEngineModel(
                name: activeModelName,
                role: isImageGeneration ? .image : (isSpeechGeneration ? .speech : .chat)
            )
            let requiredModel = executionProfile.downloadableModel

            if let selectionRequirement = request.selectionDownloadRequirement,
               selectionRequirement.modelId != requiredModel.modelId {
                guard await requireDownloadedModel(
                    model: selectionRequirement,
                    operation: request.selectionOperationName
                ) else {
                    finishActiveGeneration(isMusicGeneration: isMusicGeneration)
                    return
                }
            }

                guard await requireDownloadedModel(model: requiredModel, operation: isImageGeneration ? "Image generation" : (isSpeechGeneration ? "Speech generation" : "Chat")) else {
                finishActiveGeneration(isMusicGeneration: isMusicGeneration)
                return
            }

            if runtimeManager.state != .ready {
                isPythonLoading = true
                loadingMessage = "Initializing Python runtime..."
                modelLoadProgress = ModelLoadProgress(
                    modelId: resolvedModelId,
                    backend: activeBackend,
                    phase: .preparing,
                    detail: "Preparing runtime"
                )
                try await runtimeManager.initialize()
                try await vlmExecutor.initialize()
                isPythonLoading = false
                modelLoadProgress = nil
            }

            if !vlmExecutor.isReady {
                try await vlmExecutor.initialize()
            }

            if modelWillLoad {
                isModelLoading = true
                loadingMessage = "Loading \(activeModelName)..."
                modelLoadProgress = ModelLoadProgress(
                    modelId: resolvedModelId,
                    backend: activeBackend,
                    phase: .preparing,
                    detail: "Preparing \(activeModelName)"
                )

                do {
                    try await loadModel(resolvedModelId)
                } catch {
                    isModelLoading = false
                    modelLoadProgress = nil
                    throw error
                }
            }

            isGenerating = true

            let aiMessage: Message
            let isFollowUp = toolMessages != nil

            if isFollowUp {
                guard let existingId = streamingMessageId,
                      let chatIndex = chats.firstIndex(where: { $0.id == request.chatId }),
                      let messageIndex = chats[chatIndex].messages.firstIndex(where: { $0.id == existingId }) else {
                    finishActiveGeneration(isMusicGeneration: isMusicGeneration)
                    return
                }
                _ = streamingContentStore.begin(messageId: existingId, initialText: chats[chatIndex].messages[messageIndex].content)
                aiMessage = chats[chatIndex].messages[messageIndex]
                loadingMessage = "Using tool result..."
            } else {
                let initialToolCall: ToolCall?
                if isImageGeneration {
                    initialToolCall = ToolCall(
                        toolName: "Image generation",
                        status: prompt,
                        icon: "photo",
                        details: toolCallDetails([], includingModel: executionProfile.name)
                    )
                } else if isSpeechGeneration {
                    initialToolCall = ToolCall(
                        toolName: "Speech generation",
                        status: prompt,
                        icon: "waveform",
                        details: toolCallDetails([], includingModel: executionProfile.name)
                    )
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

                if let index = chats.firstIndex(where: { $0.id == request.chatId }) {
                    _ = streamingContentStore.begin(messageId: aiMessage.id)
                    chats[index].messages.append(aiMessage)
                    chats[index].timestamp = Date()
                    streamingMessageId = aiMessage.id
                }
            }

            let tools: [[String: Any]]? = (isImageGeneration || isSpeechGeneration) ? nil : (isMusicGeneration ? [musicGenerationTool] : availableTools(toolDepth: toolDepth, for: request.tool))
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

                if let chat = chats.first(where: { $0.id == request.chatId }) {
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

            let chatExecutionParameters = request.executionParameters(for: activeChatProfile)
            let mediaExecutionParameters = isImageGeneration || isSpeechGeneration
                ? request.executionParameters(for: executionProfile)
                : nil
            let chatTemplateKwargs: [String: Any]? = !isImageGeneration && !isSpeechGeneration && !isMusicGeneration
                ? request.chatTemplateKwargs(for: activeChatProfile)
                : nil

            let outputDirectory = isImageGeneration ? generatedImagesDirectory : (isSpeechGeneration ? generatedSpeechDirectory : nil)
            let isDirectMediaGeneration = isImageGeneration || isSpeechGeneration
            let maxTokens = (chatExecutionParameters["max_tokens"] as? Int) ?? activeChatProfile.defaultMaxTokens
            let temperature = (chatExecutionParameters["temperature"] as? Double) ?? activeChatProfile.doubleParameterDefault("temperature", fallback: 0.7)
            let topP = (chatExecutionParameters["top_p"] as? Double) ?? activeChatProfile.doubleParameterDefault("top_p", fallback: 1.0)
            let topK = (chatExecutionParameters["top_k"] as? Int) ?? activeChatProfile.intParameterDefault("top_k", fallback: 0)
            let minP = (chatExecutionParameters["min_p"] as? Double) ?? activeChatProfile.doubleParameterDefault("min_p", fallback: 0)
            let repetitionPenalty = (chatExecutionParameters["repetition_penalty"] as? Double) ?? activeChatProfile.doubleParameterDefault("repetition_penalty", fallback: 1.0)

            let executionRequest = ExecutionRequest(
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

            let stream = try await vlmExecutor.execute(request: executionRequest)

            await processStream(
                stream,
                forMessage: aiMessage.id,
                messages: messages,
                request: request,
                toolDepth: toolDepth,
                hasTools: tools != nil,
                allowedToolNames: allowedToolNames,
                isImageGeneration: isImageGeneration,
                isSpeechGeneration: isSpeechGeneration,
                isMusicGeneration: isMusicGeneration
            )

        } catch {
            if Task.isCancelled {
                finishCancelledGeneration(isMusicGeneration: cancellationIsMusicGeneration)
                return
            }
            if let streamingMessageId {
                handleGenerationError(error, replacingMessageId: streamingMessageId)
            } else {
                handleGenerationError(error)
            }
        }
    }

    @discardableResult
    func executeToolCall(_ toolCall: ExecutionToolCall, messages: inout [ExecutionMessage], images: [URL], prompt: String, generation: ChatGenerationRequest) async -> ChatToolCallExecutionResult {
        switch canonicalToolName(toolCall.function.name) {
        case "web_search":
            await executeWebSearchToolCall(toolCall, messages: &messages, prompt: prompt)
            return .nonTerminal
        case "generate_image":
            await executeImageGenerationToolCall(toolCall, messages: &messages, images: images, prompt: prompt, generation: generation)
            return .terminalMedia
        case "create_speech":
            await executeSpeechGenerationToolCall(toolCall, messages: &messages, prompt: prompt, generation: generation)
            return .terminalMedia
        case "generate_music", "create_music":
            return await executeMusicGenerationToolCall(toolCall, messages: &messages, prompt: prompt, generation: generation)
        default:
            messages.append(ExecutionMessage(
                role: .tool,
                content: "Unsupported tool: \(toolCall.function.name)",
                toolCallId: toolCall.id,
                name: toolCall.function.name
            ))
            return .nonTerminal
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

    private func executeImageGenerationToolCall(_ toolCall: ExecutionToolCall, messages: inout [ExecutionMessage], images: [URL], prompt: String, generation: ChatGenerationRequest) async {
        var imagePrompt = prompt
        if let decoded = decodeToolArguments(toolCall),
           let decodedPrompt = decoded["prompt"] as? String,
           !decodedPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            imagePrompt = decodedPrompt
        }

        let imageProfile = generation.profile(for: .image)
        let model = imageProfile.downloadableModel
        await executeMediaToolCall(
            toolCall,
            messages: &messages,
            plan: ChatMediaToolExecutionPlan(
                functionName: "generate_image",
                toolName: "Image generation",
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
                    parameters: generation.executionParameters(for: imageProfile)
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

    private func executeSpeechGenerationToolCall(_ toolCall: ExecutionToolCall, messages: inout [ExecutionMessage], prompt: String, generation: ChatGenerationRequest) async {
        var speechText = prompt
        if let decoded = decodeToolArguments(toolCall),
           let decodedText = decoded["text"] as? String,
           !decodedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            speechText = decodedText
        }

        let speechProfile = generation.profile(for: .tts)
        let model = speechProfile.downloadableModel
        await executeMediaToolCall(
            toolCall,
            messages: &messages,
            plan: ChatMediaToolExecutionPlan(
                functionName: "create_speech",
                toolName: "Speech generation",
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
                    parameters: generation.executionParameters(for: speechProfile)
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

    @discardableResult
    private func executeMusicGenerationToolCall(_ toolCall: ExecutionToolCall, messages: inout [ExecutionMessage], prompt: String, generation: ChatGenerationRequest) async -> ChatToolCallExecutionResult {
        let musicProfile = generation.profile(for: .music)
        var parameters = defaultMusicParameters(
            caption: prompt,
            profile: musicProfile,
            executionParameters: generation.executionParameters(for: musicProfile)
        )
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
            return .blockedTerminalMedia
        }

        let model = musicProfile.downloadableModel
        await executeMediaToolCall(
            toolCall,
            messages: &messages,
            plan: ChatMediaToolExecutionPlan(
                functionName: "generate_music",
                toolName: "Music generation",
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
        return .terminalMedia
    }

}
