import XCTest
@testable import MLXtra

final class ChatExecutionMessageBuilderTests: XCTestCase {
    func testToolNamesExtractsNonEmptyFunctionNames() {
        let tools: [[String: Any]] = [
            ["type": "function", "function": ["name": "web_search"]],
            ["type": "function", "function": ["name": "  "]],
            ["type": "function", "function": ["name": "generate_music"]],
            ["type": "function", "function": [:]],
            ["type": "function"]
        ]

        XCTAssertEqual(
            ChatExecutionMessageBuilder.toolNames(from: tools),
            ["web_search", "generate_music"]
        )
        XCTAssertEqual(ChatExecutionMessageBuilder.toolNames(from: nil), [])
    }

    func testSystemContentIncludesSortedToolInstructionAndMusicContext() throws {
        let content = ChatExecutionMessageBuilder.systemContent(
            baseSystemPrompt: "Base system",
            allowedToolNames: ["generate_music", "web_search"],
            musicContext: ChatExecutionMusicSystemContext(
                intentState: .needsLyrics,
                composerInstruction: "Composer instruction"
            )
        )

        XCTAssertTrue(content.hasPrefix("Base system\n\nAvailable tools in this mode: generate_music, web_search."))
        XCTAssertTrue(content.contains(MusicIntentState.needsLyrics.systemInstruction))
        XCTAssertTrue(content.hasSuffix("Composer instruction"))

        let noToolsContent = ChatExecutionMessageBuilder.systemContent(
            baseSystemPrompt: "Base system",
            allowedToolNames: [],
            musicContext: nil
        )
        XCTAssertEqual(
            noToolsContent,
            "Base system\n\nAvailable tools in this mode: none. Do not write, simulate, or mention tool calls."
        )
    }

    func testInitialMessagesIncludeSystemAndLastTwentyCompletedContextMessages() throws {
        let excludedId = UUID()
        var chatMessages = (0..<22).map { index in
            Message(
                content: "message-\(index)",
                isUser: index.isMultiple(of: 2),
                timestamp: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
        chatMessages.insert(
            Message(
                id: excludedId,
                content: "excluded",
                isUser: true,
                timestamp: Date(timeIntervalSince1970: 100)
            ),
            at: 10
        )
        chatMessages.append(
            Message(
                content: "streaming",
                isUser: false,
                timestamp: Date(timeIntervalSince1970: 101),
                isStreaming: true
            )
        )
        let chat = Chat(
            title: "Test",
            messages: chatMessages,
            timestamp: Date(),
            icon: "message"
        )

        let messages = ChatExecutionMessageBuilder.makeInitialMessages(
            chat: chat,
            excluding: excludedId,
            baseSystemPrompt: "Base",
            allowedToolNames: [],
            musicContext: nil
        )

        XCTAssertEqual(messages.count, 21)
        XCTAssertEqual(messages.first?.role, .system)
        XCTAssertEqual(messages.dropFirst().map { $0.content ?? "" }, (2..<22).map { "message-\($0)" })
        XCTAssertEqual(messages[1].role, .user)
        XCTAssertEqual(messages[2].role, .assistant)
        XCTAssertFalse(messages.compactMap(\.content).contains("excluded"))
        XCTAssertFalse(messages.compactMap(\.content).contains("streaming"))
    }

    func testInitialMessagesHandleMissingChat() {
        let messages = ChatExecutionMessageBuilder.makeInitialMessages(
            chat: nil,
            excluding: UUID(),
            baseSystemPrompt: "Base",
            allowedToolNames: [],
            musicContext: nil
        )

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.role, .system)
    }
}
