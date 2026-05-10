import XCTest
@testable import MLXHub

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
