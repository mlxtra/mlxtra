import XCTest
@testable import MLXtra

final class ChatViewModelLogicTests: XCTestCase {
    @MainActor
    func testRenameChatNormalizesPersistsAndKeepsConversationOrderTimestamp() {
        let chatId = UUID()
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let persistence = RecordingChatPersistenceService(
            chats: [
                Chat(
                    id: chatId,
                    title: "Old name",
                    messages: [],
                    timestamp: timestamp,
                    icon: "message"
                )
            ],
            selectedChatId: chatId
        )
        let viewModel = ChatViewModel(chatPersistence: persistence)

        viewModel.renameChat(chatId, to: "  Product\nplanning  ")

        XCTAssertEqual(viewModel.chats.first?.title, "Product planning")
        XCTAssertEqual(viewModel.chats.first?.timestamp, timestamp)
        XCTAssertEqual(persistence.savedChats.last?.title, "Product planning")
        XCTAssertEqual(persistence.savedSelectedChatId, chatId)
    }

    @MainActor
    func testRenameChatFallsBackForEmptyTitle() {
        let chatId = UUID()
        let persistence = RecordingChatPersistenceService(
            chats: [
                Chat(
                    id: chatId,
                    title: "Old name",
                    messages: [],
                    timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                    icon: "message"
                )
            ],
            selectedChatId: chatId
        )
        let viewModel = ChatViewModel(chatPersistence: persistence)

        viewModel.renameChat(chatId, to: " \n\t ")

        XCTAssertEqual(viewModel.chats.first?.title, "Untitled")
        XCTAssertEqual(persistence.savedChats.last?.title, "Untitled")
    }

    func testMusicReadinessSystemInstructionBlocksPrematureGeneration() {
        let instruction = MusicIntentState.needsInstrumentalOrVocals.systemInstruction

        XCTAssertTrue(instruction.contains("ask whether"))
        XCTAssertTrue(instruction.contains("before calling generate_music"))
    }

    func testMusicIntentReadyForInstrumentalPrompt() {
        XCTAssertEqual(MusicIntentState.forPrompt("Create an instrumental synthwave loop"), .readyToGenerate)
    }

    func testMusicIntentNeedsLyricsForVocalPrompt() {
        XCTAssertEqual(MusicIntentState.forPrompt("Create a pop song with vocals"), .needsLyrics)
    }

    func testMusicIntentNeedsInstrumentalOrVocalsWhenAmbiguous() {
        XCTAssertEqual(MusicIntentState.forPrompt("Create a moody cyberpunk track"), .needsInstrumentalOrVocals)
    }

    func testMusicToolCallAllowsAmbiguousPromptToUseDefaultMusicPath() {
        let state = MusicIntentState.forToolCall(
            prompt: "Create a moody cyberpunk track",
            parameters: ["caption": "moody cyberpunk track"]
        )

        XCTAssertEqual(state, .readyToGenerate)
        XCTAssertNil(state.blockedToolMessage)
    }

    func testMusicToolCallBlockedWhenLyricsAreDraftedWithoutApproval() {
        let state = MusicIntentState.forToolCall(
            prompt: "Create a pop song with vocals",
            parameters: [
                "caption": "bright pop song with vocals",
                "lyrics": "[verse]\nNeon hearts are waking\n[chorus]\nWe rise into the light"
            ]
        )

        XCTAssertEqual(state, .awaitingLyricsApproval)
        XCTAssertEqual(
            state.blockedToolMessage,
            "Do not call generate_music yet. You drafted lyrics, but the user has not explicitly approved them. Ask whether the lyrics look good or need changes."
        )
    }

    func testMusicToolCallReadyWhenUserApprovesLyrics() {
        let state = MusicIntentState.forToolCall(
            prompt: "Yes, those lyrics look good. Go ahead.",
            parameters: [
                "caption": "bright pop song with vocals",
                "lyrics": "[verse]\nNeon hearts are waking\n[chorus]\nWe rise into the light"
            ]
        )

        XCTAssertEqual(state, .readyToGenerate)
        XCTAssertNil(state.blockedToolMessage)
    }

    func testMusicToolCallReadyWhenApprovalUsesPunctuation() {
        let state = MusicIntentState.forToolCall(
            prompt: "yes, generate",
            parameters: [
                "caption": "bright pop song with vocals",
                "lyrics": "[verse]\nNeon hearts are waking\n[chorus]\nWe rise into the light",
                "instrumental": false
            ]
        )

        XCTAssertEqual(state, .readyToGenerate)
        XCTAssertNil(state.blockedToolMessage)
    }

    func testMusicToolCallReadyWhenUserProvidesLyrics() {
        let prompt = """
        Create a pop song with these lyrics:
        [verse]
        Neon hearts are waking
        [chorus]
        We rise into the light
        """
        let state = MusicIntentState.forToolCall(
            prompt: prompt,
            parameters: [
                "caption": "bright pop song with vocals",
                "lyrics": "[verse]\nNeon hearts are waking\n[chorus]\nWe rise into the light"
            ]
        )

        XCTAssertEqual(state, .readyToGenerate)
        XCTAssertNil(state.blockedToolMessage)
    }

    func testMusicIntentAcceptsStringInstrumentalToolParameter() {
        let state = MusicIntentState.forToolCall(
            prompt: "Create a mysterious orchestral clockwork garden cue",
            parameters: [
                "caption": "A 1-minute orchestral piece with violin, cello, harp, ticking rhythm, and soft chimes",
                "duration": "60",
                "instrumental": "True"
            ]
        )

        XCTAssertEqual(state, .readyToGenerate)
        XCTAssertNil(state.blockedToolMessage)
    }

    @MainActor
    func testMusicComposerDefaultsAmbiguousPromptToInstrumentalDraft() {
        let viewModel = makeViewModel()
        viewModel.selectedTool = .music
        viewModel.inputText = "Create a moody cyberpunk track"

        let resolution = viewModel.musicComposerResolution()
        let draft = viewModel.composerDraft

        XCTAssertEqual(resolution.resolvedMode, .auto)
        XCTAssertEqual(resolution.generationDraft?.vocalMode, .instrumental)
        XCTAssertEqual(resolution.generationDraft?.lyrics, "[Instrumental]")
        XCTAssertNil(resolution.promptState)
        XCTAssertEqual(viewModel.composerPlaceholder, "Describe the music you want...")
        XCTAssertTrue(viewModel.shouldShowMusicComposerControls)
        XCTAssertEqual(viewModel.composerPrimaryActionTitle, "Create music")
        XCTAssertEqual(viewModel.composerPrimaryActionSystemImage, "music.note")
        XCTAssertEqual(viewModel.composerPrimaryActionHelp, "Create music")
        XCTAssertTrue(viewModel.isComposerPrimaryActionEnabled)
        XCTAssertEqual(draft.primaryAction, .createSong)
    }

    @MainActor
    func testMusicComposerRequestsLyricsForExplicitVocalPrompt() {
        let viewModel = makeViewModel()
        viewModel.selectedTool = .music
        viewModel.inputText = "Create a pop song with vocals"
        viewModel.selectMusicVocalMode(.vocals)

        let resolution = viewModel.musicComposerResolution()

        XCTAssertEqual(resolution.resolvedMode, .vocals)
        XCTAssertEqual(resolution.promptState, .needsLyrics)
        XCTAssertNil(resolution.generationDraft)
        XCTAssertEqual(viewModel.musicComposerPrompt, .needsLyrics)
        XCTAssertEqual(viewModel.composerPrimaryActionHelp, "Add lyrics or choose Instrumental")
        XCTAssertEqual(viewModel.composerPrimaryActionDisabledHelp, "Add lyrics or choose Instrumental")
        XCTAssertFalse(viewModel.isComposerPrimaryActionEnabled)
    }

    @MainActor
    func testPrepareMusicGenerationSetsInstrumentalDraftAndClearsLyricsState() {
        let viewModel = makeViewModel()
        viewModel.selectedTool = .music
        viewModel.musicLyricsText = "[verse]\nOld draft"
        viewModel.musicLyricsApproved = true
        viewModel.isMusicLyricsEditorVisible = true

        let canGenerate = viewModel.prepareMusicGenerationIfNeeded(prompt: "  instrumental synthwave beat  ")

        XCTAssertTrue(canGenerate)
        XCTAssertEqual(viewModel.activeMusicGenerationDraft?.vocalMode, .instrumental)
        XCTAssertEqual(viewModel.activeMusicGenerationDraft?.lyrics, "[Instrumental]")
        XCTAssertFalse(viewModel.musicLyricsApproved)
        XCTAssertFalse(viewModel.isMusicLyricsEditorVisible)
    }

    @MainActor
    func testPrepareMusicGenerationRequiresLyricsForVocalPrompt() {
        let viewModel = makeViewModel()
        viewModel.selectedTool = .music
        viewModel.selectMusicVocalMode(.vocals)

        let canGenerate = viewModel.prepareMusicGenerationIfNeeded(prompt: "Create a bright pop song with vocals")

        XCTAssertFalse(canGenerate)
        XCTAssertNil(viewModel.activeMusicGenerationDraft)
        XCTAssertTrue(viewModel.isMusicLyricsEditorVisible)
    }

    @MainActor
    func testPrepareMusicGenerationUsesApprovedLyrics() {
        let viewModel = makeViewModel()
        viewModel.selectedTool = .music
        viewModel.inputText = "Create a bright pop song"
        viewModel.musicLyricsText = "  [verse]\nNeon hearts wake up  "
        viewModel.approveMusicLyrics()

        let canGenerate = viewModel.prepareMusicGenerationIfNeeded(prompt: viewModel.inputText)

        XCTAssertTrue(canGenerate)
        XCTAssertEqual(viewModel.activeMusicGenerationDraft?.vocalMode, .vocals)
        XCTAssertEqual(viewModel.activeMusicGenerationDraft?.lyrics, "[verse]\nNeon hearts wake up")
        XCTAssertTrue(viewModel.hasApprovedMusicLyrics)
    }

    @MainActor
    func testPrepareMusicGenerationExtractsEmbeddedLyrics() {
        let viewModel = makeViewModel()
        viewModel.selectedTool = .music
        viewModel.selectMusicVocalMode(.vocals)

        let canGenerate = viewModel.prepareMusicGenerationIfNeeded(
            prompt: """
            Create a song:
            [verse]
            Static lights in the rain
            [chorus]
            We keep moving
            """
        )

        XCTAssertTrue(canGenerate)
        XCTAssertEqual(viewModel.activeMusicGenerationDraft?.vocalMode, .vocals)
        XCTAssertEqual(
            viewModel.activeMusicGenerationDraft?.lyrics,
            "[verse]\nStatic lights in the rain\n[chorus]\nWe keep moving"
        )
    }

    @MainActor
    func testMusicVocalModeSelectionUpdatesComposerState() {
        let viewModel = makeViewModel()
        viewModel.selectedTool = .music
        viewModel.inputText = "Create a track"
        viewModel.musicLyricsText = "[verse]\nDraft"
        viewModel.musicLyricsApproved = true

        viewModel.performComposerSlotAction(.chooseInstrumental)
        XCTAssertEqual(viewModel.musicVocalMode, .instrumental)
        XCTAssertFalse(viewModel.musicLyricsApproved)
        XCTAssertFalse(viewModel.isMusicLyricsEditorVisible)

        viewModel.performComposerSlotAction(.chooseVocals)
        XCTAssertEqual(viewModel.musicVocalMode, .vocals)
        XCTAssertTrue(viewModel.isMusicLyricsEditorVisible)

        viewModel.performComposerSlotAction(.showLyricsEditor)
        XCTAssertEqual(viewModel.musicVocalMode, .vocals)
        XCTAssertTrue(viewModel.isMusicLyricsEditorVisible)

        viewModel.selectMusicVocalMode(.auto)
        XCTAssertTrue(viewModel.isMusicLyricsEditorVisible)
    }

    @MainActor
    func testApprovingEmptyLyricsKeepsEditorOpen() {
        let viewModel = makeViewModel()
        viewModel.selectedTool = .music
        viewModel.musicLyricsText = "  \n "

        viewModel.approveMusicLyrics()

        XCTAssertFalse(viewModel.musicLyricsApproved)
        XCTAssertTrue(viewModel.isMusicLyricsEditorVisible)
    }

    @MainActor
    func testComposerPrimaryActionDisabledWhenInputDisabled() {
        let viewModel = makeViewModel()
        viewModel.selectedTool = .music
        viewModel.inputText = "Create an instrumental cue"
        viewModel.isGenerating = true

        XCTAssertFalse(viewModel.isComposerPrimaryActionEnabled)
        XCTAssertEqual(viewModel.composerPrimaryActionDisabledHelp, "Describe the music you want")

        viewModel.performComposerPrimaryAction()
        XCTAssertEqual(viewModel.chats.first?.messages.count, 0)
    }

    @MainActor
    func testDownloadedVisionModelBecomesDefaultWhenNoStoredSelection() async throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("", forKey: ModelSelectionStore.chatKey)
        let downloadedProfile = try XCTUnwrap(testVisionProfiles.last)
        let runtimeManager = DefaultSelectionRuntimeManager(downloadedModelIds: [downloadedProfile.modelId])
        let viewModel = ChatViewModel(
            chatPersistence: RecordingChatPersistenceService(chats: [], selectedChatId: nil),
            vlmExecutor: QuickPromptTestExecutor(),
            runtimeManager: runtimeManager,
            toolExecutor: QuickPromptToolExecutionService(),
            userDefaults: defaults
        )

        let didSelectDownloadedModel = await viewModel.selectDownloadedDefaultModelIfNeeded(for: .vision)

        XCTAssertTrue(didSelectDownloadedModel)
        XCTAssertEqual(viewModel.activeModelProfile.modelId, downloadedProfile.modelId)
        if let aiModel = downloadedProfile.aiModel {
            XCTAssertEqual(viewModel.selectedModel, aiModel)
        }
        XCTAssertEqual(defaults.string(forKey: ModelSelectionStore.chatKey), downloadedProfile.modelId)
    }

    @MainActor
    func testDownloadedDefaultDoesNotOverrideStoredVisionSelection() async throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let storedProfile = try XCTUnwrap(testVisionProfiles.last)
        let downloadedProfile = try XCTUnwrap(testVisionProfiles.first { $0.modelId != storedProfile.modelId })
        ModelSelectionStore(userDefaults: defaults).setSelectedModelId(storedProfile.modelId, for: .vision)
        XCTAssertEqual(defaults.string(forKey: ModelSelectionStore.chatKey), storedProfile.modelId)
        let runtimeManager = DefaultSelectionRuntimeManager(downloadedModelIds: [downloadedProfile.modelId])
        let viewModel = ChatViewModel(
            chatPersistence: RecordingChatPersistenceService(chats: [], selectedChatId: nil),
            vlmExecutor: QuickPromptTestExecutor(),
            runtimeManager: runtimeManager,
            toolExecutor: QuickPromptToolExecutionService(),
            userDefaults: defaults
        )

        let didSelectDownloadedModel = await viewModel.selectDownloadedDefaultModelIfNeeded(for: .vision)

        XCTAssertFalse(didSelectDownloadedModel)
        XCTAssertEqual(viewModel.activeModelProfile.modelId, storedProfile.modelId)
        XCTAssertEqual(defaults.string(forKey: ModelSelectionStore.chatKey), storedProfile.modelId)
    }

    @MainActor
    func testSubmitQuickPromptIgnoresEmptyPrompt() {
        let viewModel = makeQuickPromptViewModel()
        let selectedChatId = viewModel.selectedChatId

        let didSubmit = viewModel.submitQuickPrompt(" \n\t ")

        XCTAssertFalse(didSubmit)
        XCTAssertEqual(viewModel.chats.count, 1)
        XCTAssertEqual(viewModel.selectedChatId, selectedChatId)
        XCTAssertEqual(viewModel.selectedChat?.messages.count, 0)
    }

    @MainActor
    func testSubmitQuickPromptBlocksWhileBusy() {
        let viewModel = makeQuickPromptViewModel()
        viewModel.isGenerating = true

        let didSubmit = viewModel.submitQuickPrompt("Explain this")

        XCTAssertFalse(didSubmit)
        XCTAssertEqual(viewModel.chats.count, 1)
        XCTAssertEqual(viewModel.selectedChat?.messages.count, 0)
    }

    @MainActor
    func testSubmitQuickPromptCreatesNewChatAndSendsUserMessage() {
        let viewModel = makeQuickPromptViewModel()
        let originalChatId = viewModel.selectedChatId

        let didSubmit = viewModel.submitQuickPrompt("  Explain local models  ")

        XCTAssertTrue(didSubmit)
        XCTAssertEqual(viewModel.chats.count, 2)
        XCTAssertNotEqual(viewModel.selectedChatId, originalChatId)
        XCTAssertEqual(viewModel.selectedChat?.messages.count, 1)
        XCTAssertEqual(viewModel.selectedChat?.messages.first?.content, "Explain local models")
        XCTAssertEqual(viewModel.selectedChat?.messages.first?.isUser, true)
        XCTAssertEqual(viewModel.inputText, "")
        viewModel.cancelGeneration()
    }

    @MainActor
    func testSubmitQuickPromptResetsToAutoAndClearsComposerOnlyState() {
        let viewModel = makeQuickPromptViewModel()
        viewModel.selectedTool = .music
        viewModel.selectedImagePaths = [URL(fileURLWithPath: "/tmp/reference.png")]
        viewModel.musicLyricsText = "[verse]\nOld draft"
        viewModel.musicLyricsApproved = true
        viewModel.isMusicLyricsEditorVisible = true
        viewModel.musicVocalMode = .vocals

        let didSubmit = viewModel.submitQuickPrompt("Generate a product image")

        XCTAssertTrue(didSubmit)
        XCTAssertEqual(viewModel.selectedTool, .auto)
        XCTAssertEqual(viewModel.selectedImagePaths, [])
        XCTAssertEqual(viewModel.musicLyricsText, "")
        XCTAssertFalse(viewModel.musicLyricsApproved)
        XCTAssertFalse(viewModel.isMusicLyricsEditorVisible)
        XCTAssertEqual(viewModel.musicVocalMode, .auto)
        XCTAssertEqual(viewModel.selectedChat?.messages.first?.content, "Generate a product image")
        viewModel.cancelGeneration()
    }

    @MainActor
    func testMusicPromptHelpersRecognizeVocalAndLyricsMarkers() {
        let viewModel = makeViewModel()

        XCTAssertTrue(viewModel.promptSoundsVocal("A sung vocal hook"))
        XCTAssertTrue(viewModel.promptContainsLyrics("lyrics: We keep moving"))
        XCTAssertEqual(viewModel.resolvedMusicVocalMode(for: "No vocals, only piano"), .instrumental)
        XCTAssertEqual(viewModel.resolvedMusicVocalMode(for: "A chorus with lyrics"), .vocals)
        XCTAssertEqual(viewModel.resolvedMusicVocalMode(for: "Soft ambient cue"), .auto)
    }

    @MainActor
    private func makeViewModel() -> ChatViewModel {
        ChatViewModel(chatPersistence: RecordingChatPersistenceService(chats: [], selectedChatId: nil))
    }

    @MainActor
    private func makeQuickPromptViewModel() -> ChatViewModel {
        ChatViewModel(
            chatPersistence: RecordingChatPersistenceService(chats: [], selectedChatId: nil),
            vlmExecutor: QuickPromptTestExecutor(),
            runtimeManager: QuickPromptRuntimeManager(),
            toolExecutor: QuickPromptToolExecutionService()
        )
    }

    private func makeDefaults() -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "MLXtraTests.ChatViewModelLogicTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    private var testVisionProfiles: [ModelCapabilityProfile] {
        ModelCapabilityProfile.sortedProfiles(for: .vision)
    }
}

@MainActor
private final class RecordingChatPersistenceService: ChatPersistenceServicing {
    private let initialChats: [Chat]
    private let initialSelectedChatId: UUID?
    private(set) var savedChats: [Chat] = []
    private(set) var savedSelectedChatId: UUID?

    init(chats: [Chat], selectedChatId: UUID?) {
        self.initialChats = chats
        self.initialSelectedChatId = selectedChatId
    }

    func loadChats() -> [Chat] {
        initialChats
    }

    func saveChats(_ chats: [Chat]) {
        savedChats = chats
    }

    func loadSelectedChatId() -> UUID? {
        initialSelectedChatId
    }

    func saveSelectedChatId(_ selectedChatId: UUID?) {
        savedSelectedChatId = selectedChatId
    }

    func persistAttachments(_ urls: [URL], chatId: UUID, messageId: UUID) -> [URL] {
        urls
    }

    func deleteAttachments(for chatId: UUID) {}
}

@MainActor
private final class QuickPromptTestExecutor: ChatModelExecuting {
    let backend: RuntimeBackend = .vlm
    var isReady = true
    var isModelLoaded = false
    var currentModelId: String?
    var currentModelBackend: RuntimeBackend?
    weak var delegate: VLMExecutionDelegate?
    private(set) var receivedRequests: [ExecutionRequest] = []

    func initialize() async throws {
        isReady = true
    }

    func execute(request: ExecutionRequest) async throws -> AsyncStream<ExecutionEvent> {
        receivedRequests.append(request)
        isReady = true
        isModelLoaded = true
        currentModelId = request.modelId
        currentModelBackend = request.backend

        return AsyncStream { continuation in
            continuation.yield(.started)
            continuation.yield(.token("Quick response"))
            continuation.yield(.complete("Quick response", usage: TokenUsage(promptTokens: 1, completionTokens: 2)))
            continuation.finish()
        }
    }

    func terminate() async {
        isReady = false
        isModelLoaded = false
        currentModelId = nil
        currentModelBackend = nil
    }
}

@MainActor
private final class QuickPromptRuntimeManager: ChatRuntimeManaging {
    var state: RuntimeManager.RuntimeState = .ready

    func initialize() async throws {
        state = .ready
    }

    func estimatedModelSize(modelId: String) -> Double {
        1.0
    }

    func isModelDownloadedOffMain(modelId: String) async -> Bool {
        true
    }
}

@MainActor
private final class DefaultSelectionRuntimeManager: ChatRuntimeManaging {
    var state: RuntimeManager.RuntimeState = .ready
    let downloadedModelIds: Set<String>

    init(downloadedModelIds: Set<String>) {
        self.downloadedModelIds = downloadedModelIds
    }

    func initialize() async throws {}

    func estimatedModelSize(modelId: String) -> Double {
        1.0
    }

    func isModelDownloadedOffMain(modelId: String) async -> Bool {
        downloadedModelIds.contains(modelId)
    }
}

@MainActor
private final class QuickPromptToolExecutionService: ChatToolExecutionServicing {
    func executeWebSearch(query: String) async -> String {
        "search context"
    }

    func executeMediaTool(
        plan: ChatMediaToolExecutionPlan,
        onUpdate: @escaping @MainActor (ChatToolExecutionUpdate) -> Void
    ) async -> ChatToolExecutionOutcome {
        onUpdate(.progress(plan.loadingStatus))
        return .toolMessage("Quick media response")
    }
}
