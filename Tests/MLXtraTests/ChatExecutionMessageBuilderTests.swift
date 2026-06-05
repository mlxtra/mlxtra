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
        XCTAssertTrue(content.contains("Music rule: Do not write, invent, or draft lyrics"))
        XCTAssertTrue(content.contains("Never put newly written lyrics into generate_music"))
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

    func testInitialContextIncludesGeneratedAssetSummariesAndRecentImages() throws {
        let generatedURL = URL(fileURLWithPath: "/tmp/generated-superman.png")
        let attachedURL = URL(fileURLWithPath: "/tmp/attached-reference.png")
        let chat = Chat(
            title: "Image follow-up",
            messages: [
                Message(
                    content: "superman in london",
                    isUser: true,
                    timestamp: Date(timeIntervalSince1970: 1),
                    imageURLs: [attachedURL]
                ),
                Message(
                    content: "",
                    isUser: false,
                    timestamp: Date(timeIntervalSince1970: 2),
                    toolCall: ToolCall(
                        toolName: "Image generation",
                        status: "superman in london",
                        icon: "photo"
                    ),
                    imageURLs: [generatedURL]
                ),
                Message(
                    content: "make it a movie poster",
                    isUser: true,
                    timestamp: Date(timeIntervalSince1970: 3)
                )
            ],
            timestamp: Date(),
            icon: "photo"
        )

        let context = ChatExecutionMessageBuilder.makeInitialContext(
            chat: chat,
            excluding: UUID(),
            baseSystemPrompt: "Base",
            allowedToolNames: [],
            musicContext: nil
        )

        XCTAssertEqual(context.images, [attachedURL, generatedURL])
        XCTAssertTrue(context.messages.contains { $0.content?.contains("superman in london") == true })
        XCTAssertTrue(context.messages.contains { $0.content?.contains("Image generation: superman in london") == true })
        XCTAssertTrue(context.messages.contains { $0.content?.contains("Generated 1 image in this message.") == true })
        XCTAssertTrue(context.messages.contains { $0.content == "make it a movie poster" })
    }

    func testInitialContextIncludesGeneratedAudioToolSummaries() throws {
        let generatedURL = URL(fileURLWithPath: "/tmp/generated-track.wav")
        let chat = Chat(
            title: "Music follow-up",
            messages: [
                Message(
                    content: "make a moody cyberpunk track",
                    isUser: true,
                    timestamp: Date(timeIntervalSince1970: 1)
                ),
                Message(
                    content: "",
                    isUser: false,
                    timestamp: Date(timeIntervalSince1970: 2),
                    toolCall: ToolCall(
                        toolName: "Music generation",
                        status: "make a moody cyberpunk track",
                        icon: "music.note",
                        details: [
                            ToolCallDetail(label: "Duration", value: "30"),
                            ToolCallDetail(label: "Instrumental", value: "true")
                        ]
                    ),
                    audioURLs: [generatedURL]
                ),
                Message(
                    content: "make it more cinematic",
                    isUser: true,
                    timestamp: Date(timeIntervalSince1970: 3)
                )
            ],
            timestamp: Date(),
            icon: "music.note"
        )

        let context = ChatExecutionMessageBuilder.makeInitialContext(
            chat: chat,
            excluding: UUID(),
            baseSystemPrompt: "Base",
            allowedToolNames: ["generate_music"],
            musicContext: nil
        )

        XCTAssertTrue(context.images.isEmpty)
        XCTAssertTrue(context.messages.contains { $0.content?.contains("Music generation: make a moody cyberpunk track") == true })
        XCTAssertTrue(context.messages.contains { $0.content?.contains("Duration: 30") == true })
        XCTAssertTrue(context.messages.contains { $0.content?.contains("Instrumental: true") == true })
        XCTAssertTrue(context.messages.contains { $0.content?.contains("Generated 1 audio asset in this message.") == true })
        XCTAssertTrue(context.messages.contains { $0.content == "make it more cinematic" })
    }

    func testPromptPreparationMessagesReplaceSystemAndKeepContext() {
        let messages = ChatExecutionMessageBuilder.promptPreparationMessages(
            systemPrompt: "Prepare image prompts",
            contextMessages: [
                ExecutionMessage(role: .system, content: "General chat system"),
                ExecutionMessage(role: .user, content: "superman in london"),
                ExecutionMessage(role: .assistant, content: "Generated 1 image in this message."),
                ExecutionMessage(
                    role: .assistant,
                    toolCalls: [
                        ExecutionToolCall(
                            id: "call-1",
                            function: ExecutionToolCallFunction(
                                name: "generate_image",
                                arguments: "{}"
                            )
                        )
                    ]
                )
            ],
            sourcePrompt: "make it a movie poster"
        )

        XCTAssertEqual(messages.first?.role, .system)
        XCTAssertEqual(messages.first?.content, "Prepare image prompts")
        XCTAssertFalse(messages.contains { $0.content == "General chat system" })
        XCTAssertTrue(messages.contains { $0.content == "superman in london" })
        XCTAssertTrue(messages.contains { $0.content == "Generated 1 image in this message." })
        XCTAssertEqual(messages.last?.content, "make it a movie poster")
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
