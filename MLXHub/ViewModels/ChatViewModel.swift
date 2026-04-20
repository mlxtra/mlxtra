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

enum MusicIntentState: Equatable {
    case needsInstrumentalOrVocals
    case needsLyrics
    case awaitingLyricsApproval
    case readyToGenerate

    var systemInstruction: String {
        switch self {
        case .needsInstrumentalOrVocals:
            return "Current music intent state: ask whether the user wants instrumental music or vocals with lyrics before calling generate_music."
        case .needsLyrics:
            return "Current music intent state: the user wants vocals, but lyrics are missing. Write lyrics or ask for lyrics, then wait for approval before calling generate_music."
        case .awaitingLyricsApproval:
            return "Current music intent state: lyrics are drafted but not approved. Ask for explicit approval before calling generate_music."
        case .readyToGenerate:
            return "Current music intent state: enough information is available to call generate_music."
        }
    }

    var blockedToolMessage: String? {
        switch self {
        case .needsInstrumentalOrVocals:
            return "Do not call generate_music yet. Ask the user whether they want instrumental music or vocals with lyrics."
        case .needsLyrics:
            return "Do not call generate_music yet. The user wants vocals, but lyrics are missing. Write lyrics or ask the user for lyrics, then wait for approval."
        case .awaitingLyricsApproval:
            return "Do not call generate_music yet. You drafted lyrics, but the user has not explicitly approved them. Ask whether the lyrics look good or need changes."
        case .readyToGenerate:
            return nil
        }
    }

    static func forPrompt(_ prompt: String) -> MusicIntentState {
        let normalized = prompt.lowercased()
        if containsAny(normalized, ["instrumental", "no vocals", "without vocals", "beat", "backing track", "background music"]) {
            return .readyToGenerate
        }
        if containsLyricsMarkers(prompt) {
            return .readyToGenerate
        }
        if containsAny(normalized, ["lyrics", "vocal", "vocals", "sing", "sung"]) {
            return .needsLyrics
        }
        if containsApproval(normalized) {
            return .readyToGenerate
        }
        return .needsInstrumentalOrVocals
    }

    static func forToolCall(prompt: String, parameters: [String: Any]) -> MusicIntentState {
        let caption = (parameters["caption"] as? String) ?? prompt
        let lyrics = ((parameters["lyrics"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let instrumental = boolValue(parameters["instrumental"])
        let normalizedPrompt = prompt.lowercased()
        let normalizedCaption = caption.lowercased()

        if instrumental || containsAny(normalizedPrompt + " " + normalizedCaption, ["instrumental", "no vocals", "without vocals", "beat", "backing track", "background music"]) {
            return .readyToGenerate
        }

        if lyrics.isEmpty {
            if containsAny(normalizedPrompt + " " + normalizedCaption, ["lyrics", "vocal", "vocals", "sing", "sung"]) {
                return .needsLyrics
            }
            return .needsInstrumentalOrVocals
        }

        if userProvidedLyrics(prompt: prompt, lyrics: lyrics) || containsApproval(normalizedPrompt) {
            return .readyToGenerate
        }

        return .awaitingLyricsApproval
    }

    private static func boolValue(_ value: Any?) -> Bool {
        if let bool = value as? Bool {
            return bool
        }
        if let string = value as? String {
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1":
                return true
            default:
                return false
            }
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        return false
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    private static func containsLyricsMarkers(_ text: String) -> Bool {
        let normalized = text.lowercased()
        return containsAny(normalized, ["[verse]", "[chorus]", "[bridge]", "lyrics:"])
    }

    private static func containsApproval(_ text: String) -> Bool {
        let approvalPhrases = [
            "yes",
            "approved",
            "looks good",
            "go ahead",
            "use those lyrics",
            "use the lyrics",
            "use them",
            "that's fine",
            "that works",
            "ok",
            "okay"
        ]
        return approvalPhrases.contains { phrase in
            text == phrase || text.contains(" \(phrase)") || text.contains("\(phrase) ")
        }
    }

    private static func userProvidedLyrics(prompt: String, lyrics: String) -> Bool {
        if containsLyricsMarkers(prompt) {
            return true
        }
        let normalizedPrompt = prompt.lowercased()
        let lyricWords = lyrics
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .filter { $0.count > 3 }
        guard lyricWords.count >= 4 else { return false }
        let matchingWords = lyricWords.filter { normalizedPrompt.contains(String($0)) }
        return matchingWords.count >= min(6, lyricWords.count)
    }
}

@MainActor
class ChatViewModel: ObservableObject {
    // MARK: - Published Properties
    @Published var chats: [Chat] = []
    @Published var selectedChatId: UUID?
    @Published var inputText: String = ""
    @Published var selectedTool: Tool = .auto
    @Published var selectedModel: AIModel = AIModel.defaultForCurrentHardware
    @Published var isToolMenuOpen: Bool = false
    @Published var isModelMenuOpen: Bool = false
    @Published var selectedImagePaths: [URL] = []

    // MARK: - VLM Integration Properties
    @Published var isPythonLoading: Bool = false
    @Published var isModelLoading: Bool = false
    @Published var isGenerating: Bool = false
    @Published var loadingMessage: String = ""
    @Published var streamingMessageId: UUID?
    @Published private(set) var modelDownloadRequest: DownloadableModel?
    @Published private(set) var musicIntentState: MusicIntentState = .needsInstrumentalOrVocals

    // MARK: - Private Properties
    private let chatStore = ChatStore()
    private let vlmExecutor = VLMExecutor()
    private let runtimeManager = RuntimeManager()
    private let mcpWebSearchService = MCPWebSearchService()
    private var generationTask: Task<Void, Never>?
    private let imageGenerationModelId = "black-forest-labs/FLUX.2-klein-4B"
    private let imageGenerationModelName = "FLUX.2-klein-4B"
    private let speechGenerationModelId = "kugelaudio/kugelaudio-0-open"
    private let speechGenerationModelName = "KugelAudio 0 Open"
    private let musicGenerationModelId = "ACE-Step/acestep-v15-turbo-continuous"
    private let musicGenerationModelName = "ACE-Step 1.5 Turbo"
    private let maxAutoToolDepth = 4

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

    func deleteChat(_ chat: Chat) {
        if selectedChatId == chat.id {
            cancelGeneration()
        }

        chats.removeAll { $0.id == chat.id }
        chatStore.deleteAttachments(for: chat.id)

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
        print("[ChatVM] Starting generation task for: \(messageText.prefix(50))...")
        generationTask = Task {
            await generateResponse(for: messageText, images: images)
        }
    }

    func cancelGeneration() {
        print("[ChatVM] cancelGeneration called")
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
    private var webSearchTool: [String: Any] {
        [
            "type": "function",
            "function": [
                "name": "web_search",
                "description": "Search the web for current information, news, facts, or any topic that requires up-to-date data.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "The search query"]
                    ],
                    "required": ["query"]
                ]
            ]
        ]
    }

    private var imageGenerationTool: [String: Any] {
        [
            "type": "function",
            "function": [
                "name": "generate_image",
                "description": "Generate or edit an image when the user explicitly asks for a new visual, image, illustration, photo, mockup, sprite, texture, or image edit. Do not use this tool for describing or analyzing attached images.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "prompt": [
                            "type": "string",
                            "description": "A detailed image generation or image editing prompt."
                        ]
                    ],
                    "required": ["prompt"]
                ]
            ]
        ]
    }

    private var speechGenerationTool: [String: Any] {
        [
            "type": "function",
            "function": [
                "name": "create_speech",
                "description": "Create spoken audio from text when the user asks for text-to-speech, narration, voiceover, or speech audio.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "text": [
                            "type": "string",
                            "description": "The exact text to turn into spoken audio."
                        ]
                    ],
                    "required": ["text"]
                ]
            ]
        ]
    }

    private var musicGenerationTool: [String: Any] {
        [
            "type": "function",
            "function": [
                "name": "generate_music",
                "description": "Create a song, instrumental track, beat, loop, background music, or music sample only after the user has specified instrumental music or approved lyrics for vocals.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "caption": [
                            "type": "string",
                            "description": "A concise music prompt describing genre, mood, instruments, tempo, vocals, and use case."
                        ],
                        "lyrics": [
                            "type": "string",
                            "description": "Optional lyrics with section labels like [verse] and [chorus]."
                        ],
                        "duration": [
                            "type": "number",
                            "description": "Optional duration in seconds. Use 30 unless the user asks otherwise."
                        ],
                        "instrumental": [
                            "type": "boolean",
                            "description": "True when the user asks for instrumental, beat, backing track, or no vocals."
                        ]
                    ],
                    "required": ["caption"]
                ]
            ]
        ]
    }

    private var shouldIncludeAutoTools: Bool {
        selectedTool == .auto
    }

    private var systemPrompt: String {
        """
        You are a helpful assistant.

        When the user asks you to create, generate, draw, edit, or make an image, use the generate_image tool. If the image needs current information, use web_search first, then use generate_image with the current information from the search result. Do not generate markdown image tags, image URLs, data URLs, or links to external image services. After the generate_image tool runs, the app displays the image automatically; respond with concise text only.

        When the user asks you to create speech, narration, voiceover, or text-to-speech audio, use the create_speech tool with the exact text that should be spoken. After the create_speech tool runs, the app displays the audio automatically; respond with concise text only and do not include local file paths.

        When the user asks you to create music, a song, beat, loop, soundtrack, instrumental, or background music, do not call generate_music until the request is ready.

        Music readiness rules:
        - If the user clearly asks for instrumental music, a beat, background music, a backing track, or no vocals, call generate_music with instrumental=true.
        - If the user does not say whether they want instrumental music or vocals, ask: "Would you like instrumental music, or should I include vocals with lyrics? If you'd like lyrics, you can provide your own or I can write them for you."
        - If the user wants vocals and provides lyrics, call generate_music with those lyrics.
        - If the user wants vocals but does not provide lyrics, write lyrics with section labels like [verse], [chorus], and [bridge], then ask: "Here are the lyrics I wrote for your song:\n\n<lyrics>\n\nDo these look good, or would you like me to change anything before I generate the music?"
        - If you wrote or revised lyrics, wait for explicit user approval before calling generate_music.
        - After generate_music runs, the app displays the audio automatically; respond with concise text only and do not include local file paths.
        """
    }

    private var autoTools: [[String: Any]] {
        [webSearchTool, imageGenerationTool, speechGenerationTool, musicGenerationTool]
    }

    private func availableTools(toolDepth: Int) -> [[String: Any]]? {
        guard shouldIncludeAutoTools else { return nil }
        guard toolDepth < maxAutoToolDepth else { return nil }
        return autoTools
    }

    private func downloadableModel(modelId: String, name: String, modality: ModelModality, downloadSizeGB: Double) -> DownloadableModel {
        DownloadableModel.embeddedModel(modelId: modelId) ?? DownloadableModel(
            id: modelId,
            name: name,
            subtitle: "\(modality.rawValue) model",
            modelId: modelId,
            modality: modality,
            downloadSizeGB: downloadSizeGB
        )
    }

    private func requestDownloadBeforeUse(model: DownloadableModel) {
        modelDownloadRequest = model
        loadingMessage = ""
    }

    func clearModelDownloadRequest() {
        modelDownloadRequest = nil
    }

    private func modelDownloadRequiredMessage(for model: DownloadableModel, operation: String) -> String {
        "\(operation) needs \(model.name) (\(String(format: "%.1f", model.downloadSizeGB)) GB). Opened Models so you can download it first, then try again."
    }

    private func appendAssistantMessage(_ content: String) {
        let message = Message(
            content: content,
            isUser: false,
            timestamp: Date()
        )

        if let index = chats.firstIndex(where: { $0.id == selectedChatId }) {
            chats[index].messages.append(message)
            chats[index].timestamp = Date()
            persistConversationHistory()
        }
    }

    private func isModelDownloadedOffMain(modelId: String) async -> Bool {
        let checkpointsPath = runtimeManager.checkpointsPath
        return await Task.detached(priority: .utility) {
            RuntimeManager.isModelDownloaded(modelId: modelId, checkpointsPath: checkpointsPath)
        }.value
    }

    private func requireDownloadedModel(model: DownloadableModel, operation: String) async -> Bool {
        guard !(await isModelDownloadedOffMain(modelId: model.modelId)) else {
            return true
        }

        requestDownloadBeforeUse(model: model)
        appendAssistantMessage(modelDownloadRequiredMessage(for: model, operation: operation))
        isGenerating = false
        isModelLoading = false
        streamingMessageId = nil
        generationTask = nil
        return false
    }

    private func generateResponse(for prompt: String, images: [URL], toolMessages: [ExecutionMessage]? = nil, toolDepth: Int = 0) async {
        do {
            let isImageGeneration = selectedTool == .image
            let isSpeechGeneration = selectedTool == .tts
            let isMusicGeneration = selectedTool == .music

            let activeModelId = isImageGeneration ? imageGenerationModelId : selectedModel.modelId
            let resolvedModelId = isSpeechGeneration ? speechGenerationModelId : activeModelId
            let activeModelName = isImageGeneration ? imageGenerationModelName : (isSpeechGeneration ? speechGenerationModelName : selectedModel.displayName)
            let activeBackend: RuntimeBackend = isImageGeneration ? .image : (isSpeechGeneration ? .audio : .vlm)
            let activeModality: ModelModality = isImageGeneration ? .image : (isSpeechGeneration ? .audio : .vision)
            let downloadSize = (isImageGeneration || isSpeechGeneration) ? runtimeManager.estimatedModelSize(modelId: resolvedModelId) : selectedModel.info.downloadSize
            let requiredModel = downloadableModel(
                modelId: resolvedModelId,
                name: activeModelName,
                modality: activeModality,
                downloadSizeGB: downloadSize
            )

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

            if !vlmExecutor.isModelLoaded {
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
                aiMessage = chats[chatIndex].messages[messageIndex]
                loadingMessage = "Using tool result..."
            } else {
                let initialToolCall: ToolCall?
                if isImageGeneration {
                    initialToolCall = ToolCall(toolName: "FLUX.2 image generation", status: prompt, icon: "photo")
                } else if isSpeechGeneration {
                    initialToolCall = ToolCall(toolName: "KugelAudio speech generation", status: prompt, icon: "waveform")
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
        chats[index].messages.append(aiMessage)
            chats[index].timestamp = Date()
            streamingMessageId = aiMessage.id
                }
            }

            var messages: [ExecutionMessage]
            if let toolMessages {
                messages = toolMessages
            } else {
                messages = []
                messages.append(ExecutionMessage(role: .system, content: systemPrompt))

                if let chat = selectedChat {
                    for message in contextMessages(from: chat, excluding: aiMessage.id) {
                        let role: MessageRole = message.isUser ? .user : .assistant
                        messages.append(ExecutionMessage(role: role, content: message.content))
                    }
                }

                if isMusicGeneration {
                    musicIntentState = MusicIntentState.forPrompt(prompt)
                    messages.append(ExecutionMessage(role: .system, content: musicIntentState.systemInstruction))
                }
            }

            let chatTemplateKwargs: [String: Any]? = !isImageGeneration && !isSpeechGeneration && !isMusicGeneration && selectedModel.modelId.lowercased().contains("qwen")
                ? ["enable_thinking": selectedModel.enableThinking]
                : nil

            let tools: [[String: Any]]? = (isImageGeneration || isSpeechGeneration) ? nil : (isMusicGeneration ? [musicGenerationTool] : availableTools(toolDepth: toolDepth))
            let outputDirectory = isImageGeneration ? generatedImagesDirectory : (isSpeechGeneration ? generatedSpeechDirectory : nil)
            let isDirectMediaGeneration = isImageGeneration || isSpeechGeneration

            let request = ExecutionRequest(
                backend: activeBackend,
                modelId: resolvedModelId,
                messages: isDirectMediaGeneration ? [ExecutionMessage(role: .user, content: prompt)] : messages,
                images: images.isEmpty ? nil : images,
                outputDirectory: outputDirectory,
                maxTokens: isDirectMediaGeneration ? 0 : selectedModel.defaultMaxTokens,
                temperature: isDirectMediaGeneration ? 1.0 : selectedModel.temperatureRange.default,
                topP: isDirectMediaGeneration ? nil : selectedModel.topP,
                topK: isDirectMediaGeneration ? nil : selectedModel.topK,
                minP: isDirectMediaGeneration ? nil : selectedModel.minP,
                repetitionPenalty: isDirectMediaGeneration ? nil : selectedModel.repetitionPenalty,
                chatTemplateKwargs: chatTemplateKwargs,
                tools: tools,
                parameters: nil
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
        switch toolCall.function.name {
        case "web_search":
            await executeWebSearchToolCall(toolCall, messages: &messages, prompt: prompt)
        case "generate_image":
            await executeImageGenerationToolCall(toolCall, messages: &messages, images: images, prompt: prompt)
        case "create_speech":
            await executeSpeechGenerationToolCall(toolCall, messages: &messages, prompt: prompt)
        case "generate_music":
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

    private func defaultMusicParameters(caption: String) -> [String: Any] {
        [
            "caption": caption,
            "duration": 30,
            "batch_size": 1,
            "inference_steps": 8,
            "audio_format": "wav",
            "thinking": false,
            "instrumental": caption.localizedCaseInsensitiveContains("instrumental")
                || caption.localizedCaseInsensitiveContains("beat")
                || caption.localizedCaseInsensitiveContains("background music")
        ]
    }

    private func executeWebSearchToolCall(_ toolCall: ExecutionToolCall, messages: inout [ExecutionMessage], prompt: String) async {
        let args = toolCall.function.arguments
        var searchQuery = prompt
        if let data = args.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let query = decoded["query"] as? String {
            searchQuery = query
        }

        loadingMessage = "Searching for \"\(searchQuery)\"..."
        if let messageId = streamingMessageId {
            if let chatIndex = chats.firstIndex(where: { $0.id == selectedChatId }),
               let messageIndex = chats[chatIndex].messages.firstIndex(where: { $0.id == messageId }) {
                appendToolCall(
                    ToolCall(
                        toolName: "Web search",
                        status: searchQuery,
                        icon: "magnifyingglass"
                    ),
                    toMessage: messageId
                )
            chats[chatIndex].messages[messageIndex].content = ""
        }
    }

    do {
        guard let context = try await mcpWebSearchService.searchContext(for: searchQuery) else {
                messages.append(ExecutionMessage(role: .tool, content: "No results found.", toolCallId: toolCall.id, name: "web_search"))
                return
            }

            messages.append(ExecutionMessage(role: .tool, content: context, toolCallId: toolCall.id, name: "web_search"))
        } catch {
            messages.append(ExecutionMessage(role: .tool, content: "Web search unavailable: \(error.localizedDescription)", toolCallId: toolCall.id, name: "web_search"))
        }
    }

    private func executeImageGenerationToolCall(_ toolCall: ExecutionToolCall, messages: inout [ExecutionMessage], images: [URL], prompt: String) async {
        let imageModel = downloadableModel(
            modelId: imageGenerationModelId,
            name: imageGenerationModelName,
            modality: .image,
            downloadSizeGB: runtimeManager.estimatedModelSize(modelId: imageGenerationModelId)
        )
        guard await isModelDownloadedOffMain(modelId: imageModel.modelId) else {
            requestDownloadBeforeUse(model: imageModel)
            messages.append(ExecutionMessage(
                role: .tool,
                content: modelDownloadRequiredMessage(for: imageModel, operation: "Image generation"),
                toolCallId: toolCall.id,
                name: "generate_image"
            ))
            return
        }

        let args = toolCall.function.arguments
        var imagePrompt = prompt
        if let data = args.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let decodedPrompt = decoded["prompt"] as? String,
           !decodedPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            imagePrompt = decodedPrompt
        }

        loadingMessage = "Generating image..."
        if let messageId = streamingMessageId {
            if let chatIndex = chats.firstIndex(where: { $0.id == selectedChatId }),
               let messageIndex = chats[chatIndex].messages.firstIndex(where: { $0.id == messageId }) {
                appendToolCall(
                    ToolCall(
                        toolName: "FLUX.2 image generation",
                        status: imagePrompt,
                        icon: "photo"
                    ),
                    toMessage: messageId
                )
            chats[chatIndex].messages[messageIndex].content = ""
        }
    }

    do {
        let request = ExecutionRequest(
            backend: .image,
                modelId: imageGenerationModelId,
                messages: [ExecutionMessage(role: .user, content: imagePrompt)],
                images: images.isEmpty ? nil : images,
                outputDirectory: generatedImagesDirectory,
                maxTokens: 0,
                temperature: 1.0
            )

            let stream = try await vlmExecutor.execute(request: request)
            var generatedImageURL: URL?
            var generationSummary = "Image generation completed."

            for await event in stream {
                if Task.isCancelled {
                    break
                }

                switch event {
                case .image(let imageURL):
                    generatedImageURL = imageURL
                    if let messageId = streamingMessageId {
                        appendGeneratedImage(imageURL, toMessage: messageId)
                    }
                case .complete(let response, _):
                    if !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        generationSummary = response
                    }
                case .progress(let message):
                    loadingMessage = message
                case .error(let error):
                    throw error
                case .started, .token, .toolCalls, .audio:
                    break
                }
            }

            if generatedImageURL != nil {
                messages.append(ExecutionMessage(
                    role: .tool,
                    content: "\(generationSummary)\nThe generated image is already displayed in the app UI. In your final response, use text only. Do not include markdown image syntax, image URLs, local file paths, HTML image tags, data URLs, or links to external image services such as Pollinations.",
                    toolCallId: toolCall.id,
                    name: "generate_image"
                ))
            } else {
                messages.append(ExecutionMessage(
                    role: .tool,
                    content: "Image generation finished without returning an image.",
                    toolCallId: toolCall.id,
                    name: "generate_image"
                ))
            }
        } catch {
            messages.append(ExecutionMessage(
                role: .tool,
                content: "Image generation unavailable: \(error.localizedDescription)",
                toolCallId: toolCall.id,
                name: "generate_image"
            ))
        }
    }

    private func executeSpeechGenerationToolCall(_ toolCall: ExecutionToolCall, messages: inout [ExecutionMessage], prompt: String) async {
        let speechModel = downloadableModel(
            modelId: speechGenerationModelId,
            name: speechGenerationModelName,
            modality: .audio,
            downloadSizeGB: runtimeManager.estimatedModelSize(modelId: speechGenerationModelId)
        )
        guard await isModelDownloadedOffMain(modelId: speechModel.modelId) else {
            requestDownloadBeforeUse(model: speechModel)
            messages.append(ExecutionMessage(
                role: .tool,
                content: modelDownloadRequiredMessage(for: speechModel, operation: "Speech generation"),
                toolCallId: toolCall.id,
                name: "create_speech"
            ))
            return
        }

        let args = toolCall.function.arguments
        var speechText = prompt
        if let data = args.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let decodedText = decoded["text"] as? String,
           !decodedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            speechText = decodedText
        }

        loadingMessage = "Generating speech..."
        if let messageId = streamingMessageId {
            appendToolCall(
                ToolCall(
                    toolName: "KugelAudio speech generation",
                    status: speechText,
                    icon: "waveform"
                ),
                toMessage: messageId
            )
            if let chatIndex = chats.firstIndex(where: { $0.id == selectedChatId }),
               let messageIndex = chats[chatIndex].messages.firstIndex(where: { $0.id == messageId }) {
            chats[chatIndex].messages[messageIndex].content = ""
        }
    }

    do {
        let request = ExecutionRequest(
            backend: .audio,
                modelId: speechGenerationModelId,
                messages: [ExecutionMessage(role: .user, content: speechText)],
                outputDirectory: generatedSpeechDirectory,
                maxTokens: 0,
                temperature: 1.0
            )

            let stream = try await vlmExecutor.execute(request: request)
            var generatedAudioURL: URL?
            var generationSummary = "Speech generation completed."

            for await event in stream {
                if Task.isCancelled {
                    break
                }

                switch event {
                case .audio(let audioURL):
                    generatedAudioURL = audioURL
                    if let messageId = streamingMessageId {
                        appendGeneratedAudio(audioURL, toMessage: messageId)
                    }
                case .complete(let response, _):
                    if !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        generationSummary = response
                    }
                case .progress(let message):
                    loadingMessage = message
                case .error(let error):
                    throw error
                case .started, .token, .toolCalls, .image:
                    break
                }
            }

            if generatedAudioURL != nil {
                messages.append(ExecutionMessage(
                    role: .tool,
                    content: "\(generationSummary)\nThe generated audio is already displayed in the app UI. In your final response, use text only. Do not include local file paths.",
                    toolCallId: toolCall.id,
                    name: "create_speech"
                ))
            } else {
                messages.append(ExecutionMessage(
                    role: .tool,
                    content: "Speech generation finished without returning audio.",
                    toolCallId: toolCall.id,
                    name: "create_speech"
                ))
            }
        } catch {
            messages.append(ExecutionMessage(
                role: .tool,
                content: "Speech generation unavailable: \(error.localizedDescription)",
                toolCallId: toolCall.id,
                name: "create_speech"
            ))
        }
    }

    private func executeMusicGenerationToolCall(_ toolCall: ExecutionToolCall, messages: inout [ExecutionMessage], prompt: String) async {
        let args = toolCall.function.arguments
        var parameters = defaultMusicParameters(caption: prompt)
        if let data = args.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
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
        }

        let musicPrompt = (parameters["caption"] as? String) ?? prompt
        musicIntentState = MusicIntentState.forToolCall(prompt: prompt, parameters: parameters)
        if let blockedToolMessage = musicIntentState.blockedToolMessage {
            messages.append(ExecutionMessage(
                role: .tool,
                content: blockedToolMessage,
                toolCallId: toolCall.id,
                name: "generate_music"
            ))
            return
        }

        let musicModel = downloadableModel(
            modelId: musicGenerationModelId,
            name: musicGenerationModelName,
            modality: .music,
            downloadSizeGB: runtimeManager.estimatedModelSize(modelId: musicGenerationModelId)
        )
        guard await isModelDownloadedOffMain(modelId: musicModel.modelId) else {
            requestDownloadBeforeUse(model: musicModel)
            messages.append(ExecutionMessage(
                role: .tool,
                content: modelDownloadRequiredMessage(for: musicModel, operation: "Music generation"),
                toolCallId: toolCall.id,
                name: "generate_music"
            ))
            return
        }

        loadingMessage = "Generating music..."
        if let messageId = streamingMessageId {
            appendToolCall(
                ToolCall(
                    toolName: "ACE-Step music generation",
                    status: musicPrompt,
                    icon: "music.note",
                    details: musicToolCallDetails(parameters)
                ),
                toMessage: messageId
            )
            if let chatIndex = chats.firstIndex(where: { $0.id == selectedChatId }),
               let messageIndex = chats[chatIndex].messages.firstIndex(where: { $0.id == messageId }) {
            chats[chatIndex].messages[messageIndex].content = ""
        }
    }

    do {
        let request = ExecutionRequest(
            backend: .music,
                modelId: musicGenerationModelId,
                messages: [ExecutionMessage(role: .user, content: musicPrompt)],
                outputDirectory: generatedMusicDirectory,
                maxTokens: 0,
                temperature: 1.0,
                parameters: parameters
            )

            let stream = try await vlmExecutor.execute(request: request)
            var generatedAudioURL: URL?
            var generationSummary = "Music generation completed."

            for await event in stream {
                if Task.isCancelled {
                    break
                }

                switch event {
                case .audio(let audioURL):
                    generatedAudioURL = audioURL
                    if let messageId = streamingMessageId {
                        appendGeneratedAudio(audioURL, toMessage: messageId)
                    }
                case .complete(let response, _):
                    if !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        generationSummary = response
                    }
                case .progress(let message):
                    loadingMessage = message
                case .error(let error):
                    throw error
                case .started, .token, .toolCalls, .image:
                    break
                }
            }

            if generatedAudioURL != nil {
                messages.append(ExecutionMessage(
                    role: .tool,
                    content: "\(generationSummary)\nThe generated music is already displayed in the app UI. In your final response, use text only. Do not include local file paths.",
                    toolCallId: toolCall.id,
                    name: "generate_music"
                ))
            } else {
                messages.append(ExecutionMessage(
                    role: .tool,
                    content: "Music generation finished without returning audio.",
                    toolCallId: toolCall.id,
                    name: "generate_music"
                ))
            }
        } catch {
            messages.append(ExecutionMessage(
                role: .tool,
                content: "Music generation unavailable: \(error.localizedDescription)",
                toolCallId: toolCall.id,
                name: "generate_music"
            ))
        }
    }

    private func normalizedMusicNumber(_ value: Any) -> Any {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if let intValue = Int(trimmed) {
                return intValue
            }
            if let doubleValue = Double(trimmed) {
                return doubleValue
            }
        }
        return value
    }

    private func normalizedMusicBool(_ value: Any) -> Bool? {
        if let bool = value as? Bool {
            return bool
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let string = value as? String {
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1":
                return true
            case "false", "no", "0":
                return false
            default:
                return nil
            }
        }
        return nil
    }

    private func musicToolCallDetails(_ parameters: [String: Any]) -> [ToolCallDetail] {
        let userFacingKeys = [
            "caption",
            "lyrics",
            "duration",
            "instrumental"
        ]

        var details: [ToolCallDetail] = []

        for key in userFacingKeys {
            if let value = parameters[key],
               let displayValue = musicParameterDisplayValue(value) {
                details.append(ToolCallDetail(label: musicParameterLabel(key), value: displayValue))
            }
        }

        return details
    }

    private func musicParameterDisplayValue(_ value: Any) -> String? {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let bool = value as? Bool {
            return bool ? "true" : "false"
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted]),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return String(describing: value)
    }

    private func musicParameterLabel(_ key: String) -> String {
        switch key {
        case "caption": return "Caption"
        case "lyrics": return "Lyrics"
        case "duration": return "Duration"
        case "instrumental": return "Instrumental"
        case "inference_steps": return "Inference steps"
        case "batch_size": return "Batch size"
        case "audio_format": return "Audio format"
        case "thinking": return "Thinking"
        case "seed": return "Seed"
        case "bpm": return "BPM"
        case "keyscale": return "Key"
        case "vocal_language": return "Vocal language"
        default:
            return key
                .split(separator: "_")
                .map { part in
                    part.prefix(1).uppercased() + part.dropFirst()
                }
                .joined(separator: " ")
        }
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
        isImageGeneration: Bool = false,
        isSpeechGeneration: Bool = false,
        isMusicGeneration: Bool = false
    ) async {
        var fullResponse = ""
        var renderedResponse = ""
        var lastRenderTime = Date.distantPast
        let minimumRenderInterval: TimeInterval = 1.0 / 30.0
#if DEBUG
        var tokenIndex = 0
#endif

        func renderStreamingResponse(force: Bool = false, tokenIndex: Int? = nil, tokenReceivedAt: TimeInterval? = nil) {
            guard fullResponse != renderedResponse else { return }

            let now = Date()
            guard force || renderedResponse.isEmpty || now.timeIntervalSince(lastRenderTime) >= minimumRenderInterval else {
                return
            }

            updateStreamingMessage(messageId, content: fullResponse)
            renderedResponse = fullResponse
            lastRenderTime = now

#if DEBUG
            if let tokenIndex, let tokenReceivedAt {
                let updateFinishedAt = ChatStreamDiagnostics.now()
                ChatStreamDiagnostics.log("message.rendered index=\(tokenIndex) responseChars=\(fullResponse.count) elapsedMs=\(String(format: "%.2f", (updateFinishedAt - tokenReceivedAt) * 1000))")
            }
#endif
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

                fullResponse += token
                if hasTools && shouldBufferToolEnabledOutput(fullResponse) {
                    loadingMessage = "Thinking..."
#if DEBUG
                    ChatStreamDiagnostics.log("token.buffered index=\(tokenIndex) responseChars=\(fullResponse.count)")
#endif
                } else {
#if DEBUG
                    renderStreamingResponse(force: renderedResponse.isEmpty, tokenIndex: tokenIndex, tokenReceivedAt: tokenReceivedAt)
#else
                    renderStreamingResponse(force: renderedResponse.isEmpty)
#endif
                }

            case .image(let imageURL):
                appendGeneratedImage(imageURL, toMessage: messageId)

            case .audio(let audioURL):
                appendGeneratedAudio(audioURL, toMessage: messageId)
                
            case .complete(let response, let usage):
#if DEBUG
                ChatStreamDiagnostics.log("stream.complete responseChars=\(response.count)")
#endif
                fullResponse = response
                finalizeMessage(
                    messageId,
                    content: (isImageGeneration || isSpeechGeneration) ? "" : fullResponse,
                    usage: usage,
                    clearToolCall: isImageGeneration || isSpeechGeneration
                )
                isGenerating = false
                streamingMessageId = nil
                generationTask = nil
                loadingMessage = ""
                
            case .toolCalls(let toolCalls):
                guard var currentMessages = messages, let currentImages = images, let currentPrompt = prompt else { break }
                guard toolDepth < maxAutoToolDepth else {
                    // Max tool depth reached, skip recursive tool execution
                    currentMessages.append(ExecutionMessage(role: .assistant, content: "Maximum tool call depth reached. Cannot execute more tool calls."))
                    return
                }
                let hasTerminalMediaTool = toolCalls.contains { isTerminalMediaTool($0.function.name) }
                for toolCall in toolCalls {
                    currentMessages.append(ExecutionMessage(role: .assistant, toolCalls: [toolCall]))
                    await executeToolCall(toolCall, messages: &currentMessages, images: currentImages, prompt: currentPrompt)
                }
                if hasTerminalMediaTool {
                    if let toolContent = currentMessages.last(where: { $0.role == .tool })?.content,
                       !toolContent.contains("already displayed") {
                        updateStreamingMessage(messageId, content: toolContent)
                    }
                    markMessageStopped(messageId)
                    isGenerating = false
                    isModelLoading = false
                    streamingMessageId = nil
                    generationTask = nil
                    loadingMessage = ""
                    return
                }
                await generateResponse(for: currentPrompt, images: currentImages, toolMessages: currentMessages, toolDepth: toolDepth + 1)
                return

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

    private func shouldBufferToolEnabledOutput(_ output: String) -> Bool {
        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOutput.isEmpty else { return true }

        let toolPrefixes = ["<tool_call>", "<function=", "<|tool_call|>"]
        return toolPrefixes.contains { prefix in
            prefix.hasPrefix(trimmedOutput) || trimmedOutput.hasPrefix(prefix)
        }
    }

    private func isTerminalMediaTool(_ name: String) -> Bool {
        name == "generate_image" || name == "create_speech" || name == "generate_music"
    }

    private func updateStreamingMessage(_ messageId: UUID, content: String) {
        if let chatIndex = chats.firstIndex(where: { $0.id == selectedChatId }),
           let messageIndex = chats[chatIndex].messages.firstIndex(where: { $0.id == messageId }) {
            // Create new array reference to trigger ObservableObject update
            var updatedMessages = chats[chatIndex].messages
            updatedMessages[messageIndex].content = content
            chats[chatIndex].messages = updatedMessages
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
        }
    }

    private func appendGeneratedAudio(_ audioURL: URL, toMessage messageId: UUID) {
        if let chatIndex = chats.firstIndex(where: { $0.id == selectedChatId }),
           let messageIndex = chats[chatIndex].messages.firstIndex(where: { $0.id == messageId }) {
            var updatedMessages = chats[chatIndex].messages
            if !updatedMessages[messageIndex].audioURLs.contains(audioURL) {
                updatedMessages[messageIndex].audioURLs.append(audioURL)
            }
            chats[chatIndex].messages = updatedMessages
        }
    }

    private func appendToolCall(_ toolCall: ToolCall, toMessage messageId: UUID) {
        if let chatIndex = chats.firstIndex(where: { $0.id == selectedChatId }),
           let messageIndex = chats[chatIndex].messages.firstIndex(where: { $0.id == messageId }) {
            var updatedMessages = chats[chatIndex].messages
            updatedMessages[messageIndex].toolCalls.append(toolCall)
            chats[chatIndex].messages = updatedMessages
        }
    }

    private func finalizeMessage(_ messageId: UUID, content: String, usage: TokenUsage, clearToolCall: Bool = false) {
        if let chatIndex = chats.firstIndex(where: { $0.id == selectedChatId }),
           let messageIndex = chats[chatIndex].messages.firstIndex(where: { $0.id == messageId }) {
            chats[chatIndex].messages[messageIndex].content = content
            chats[chatIndex].messages[messageIndex].isStreaming = false
            if clearToolCall {
                chats[chatIndex].messages[messageIndex].toolCalls = []
            }
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
           var toolCall = chats[chatIndex].messages[messageIndex].toolCalls.last {
            toolCall.status = status
            chats[chatIndex].messages[messageIndex].toolCalls[chats[chatIndex].messages[messageIndex].toolCalls.count - 1] = toolCall
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
        let errorDesc = String(describing: error)
        if error is CancellationError || errorDesc.contains("CancellationError") || (error as NSError).code == NSUserCancelledError {
            print("[ChatVM] Ignoring cancellation error: \(errorDesc)")
            return
        }

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
        isModelLoading = false
        streamingMessageId = nil
        loadingMessage = ""
    }

    func selectTool(_ tool: Tool) {
        selectedTool = tool
        if tool == .music {
            musicIntentState = .needsInstrumentalOrVocals
        }
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

    func deleteAttachments(for chatId: UUID) {
        let chatAttachmentsDirectory = attachmentsDirectory
            .appendingPathComponent(chatId.uuidString, isDirectory: true)

        guard fileManager.fileExists(atPath: chatAttachmentsDirectory.path) else { return }

        do {
            try fileManager.removeItem(at: chatAttachmentsDirectory)
        } catch {
            print("Failed to delete attachments for chat \(chatId): \(error)")
        }
    }
}

// MARK: - VLMExecutionDelegate
extension ChatViewModel: VLMExecutionDelegate {
    func modelLoadingStarted(modelId: String) {
        // Already handled in generateResponse
    }

    func modelLoadingCompleted(modelId: String) {
        isModelLoading = false
        loadingMessage = ""
    }

    func modelLoadingFailed(modelId: String, error: Error) {
        isModelLoading = false
        loadingMessage = ""
        // Note: handleGenerationError is called by the main task catch block
    }

    func executionWillRetry(attempt: Int) {
        loadingMessage = "Retrying (attempt \(attempt))..."
    }

    func executionDidFail(error: Error) {
        // Note: handleGenerationError is called by the main task catch block
    }
}
