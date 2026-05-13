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
