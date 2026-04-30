import XCTest
@testable import MLXHub

final class ChatAndMessageTests: XCTestCase {

    // MARK: - Chat Tests

    func testChatInitialization() {
        let messages = [
            Message(content: "Hello", isUser: true, timestamp: Date()),
            Message(content: "Hi there!", isUser: false, timestamp: Date())
        ]
        let chat = Chat(
            id: UUID(),
            title: "Test Chat",
            messages: messages,
            timestamp: Date(),
            icon: "message"
        )

        XCTAssertEqual(chat.title, "Test Chat")
        XCTAssertEqual(chat.messages.count, 2)
        XCTAssertEqual(chat.icon, "message")
    }

    func testChatEquality() {
        let id = UUID()
        let timestamp = Date()
        let chat1 = Chat(id: id, title: "Chat", messages: [], timestamp: timestamp, icon: "message")
        let chat2 = Chat(id: id, title: "Different Title", messages: [], timestamp: timestamp, icon: "different")
        let chat3 = Chat(id: UUID(), title: "Chat", messages: [], timestamp: timestamp, icon: "message")

        XCTAssertEqual(chat1, chat2) // Same ID
        XCTAssertNotEqual(chat1, chat3) // Different ID
    }

    func testChatCustomId() {
        let customId = UUID()
        let chat = Chat(
            id: customId,
            title: "Test",
            messages: [],
            timestamp: Date(),
            icon: "message"
        )
        XCTAssertEqual(chat.id, customId)
    }

    // MARK: - Message Tests

    func testMessageInitialization() {
        let message = Message(
            id: UUID(),
            content: "Hello, world!",
            isUser: true,
            timestamp: Date()
        )

        XCTAssertEqual(message.content, "Hello, world!")
        XCTAssertTrue(message.isUser)
        XCTAssertTrue(message.toolCalls.isEmpty)
        XCTAssertFalse(message.isStreaming)
        XCTAssertTrue(message.imageURLs.isEmpty)
        XCTAssertTrue(message.audioURLs.isEmpty)
    }

    func testMessageInitializationWithToolCall() {
        let toolCall = ToolCall(
            toolName: "generate_image",
            status: "Generating...",
            icon: "photo"
        )
        let message = Message(
            content: "Creating image",
            isUser: false,
            timestamp: Date(),
            toolCall: toolCall
        )

        XCTAssertEqual(message.toolCalls.count, 1)
        XCTAssertEqual(message.toolCalls.first?.toolName, "generate_image")
    }

    func testMessageInitializationWithImages() {
        let imageURLs = [
            URL(fileURLWithPath: "/test/image1.png"),
            URL(fileURLWithPath: "/test/image2.png")
        ]
        let message = Message(
            content: "Check these images",
            isUser: true,
            timestamp: Date(),
            imageURLs: imageURLs
        )

        XCTAssertEqual(message.imageURLs.count, 2)
    }

    func testMessageInitializationWithAudio() {
        let audioURLs = [URL(fileURLWithPath: "/test/audio.wav")]
        let message = Message(
            content: "Listen to this",
            isUser: false,
            timestamp: Date(),
            audioURLs: audioURLs
        )

        XCTAssertEqual(message.audioURLs.count, 1)
    }

    func testMessageStreaming() {
        let message = Message(
            content: "Streaming response...",
            isUser: false,
            timestamp: Date(),
            isStreaming: true
        )

        XCTAssertTrue(message.isStreaming)
    }

    // MARK: - Message Codable

    func testMessageEncodingDecoding() throws {
        let originalMessage = Message(
            id: UUID(),
            content: "Test content",
            isUser: true,
            timestamp: Date(timeIntervalSince1970: 1000000),
            toolCall: ToolCall(toolName: "test", status: "done", icon: "test"),
            isStreaming: false,
            imageURLs: [URL(fileURLWithPath: "/test.png")],
            audioURLs: [URL(fileURLWithPath: "/test.wav")],
            performanceMetrics: GenerationPerformanceMetrics(
                timeToFirstToken: 0.25,
                tokensPerSecond: 42,
                outputTokenCount: 21,
                totalDuration: 1.2,
                measuredAt: Date(timeIntervalSince1970: 1000001)
            )
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(originalMessage)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decodedMessage = try decoder.decode(Message.self, from: data)

        XCTAssertEqual(decodedMessage.id, originalMessage.id)
        XCTAssertEqual(decodedMessage.content, originalMessage.content)
        XCTAssertEqual(decodedMessage.isUser, originalMessage.isUser)
        XCTAssertEqual(decodedMessage.toolCalls.count, 1)
        XCTAssertEqual(decodedMessage.toolCalls.first?.toolName, "test")
        XCTAssertEqual(decodedMessage.imageURLs.count, 1)
        XCTAssertEqual(decodedMessage.audioURLs.count, 1)
        XCTAssertEqual(decodedMessage.performanceMetrics?.outputTokenCount, 21)
        XCTAssertEqual(decodedMessage.performanceMetrics?.tokensPerSecond, 42)
    }

    func testGenerationPerformanceMetricsPrefersBridgeTokensPerSecond() {
        let startedAt = Date(timeIntervalSince1970: 100)
        let firstOutputAt = Date(timeIntervalSince1970: 101)
        let completedAt = Date(timeIntervalSince1970: 111)

        let metrics = GenerationPerformanceMetrics.measured(
            startedAt: startedAt,
            firstOutputAt: firstOutputAt,
            completedAt: completedAt,
            outputTokenCount: 10,
            backendTokensPerSecond: 4.5
        )

        XCTAssertEqual(metrics.timeToFirstToken, 1)
        XCTAssertEqual(metrics.outputTokenCount, 10)
        XCTAssertEqual(metrics.tokensPerSecond, 4.5)
    }

    func testMessageDecodingWithLegacyToolCallKey() throws {
        let jsonString = """
        {
            "id": "00000000-0000-0000-0000-000000000001",
            "content": "Legacy format",
            "isUser": false,
            "timestamp": "2024-01-01T00:00:00Z",
            "toolCall": {
                "id": "00000000-0000-0000-0000-000000000002",
                "toolName": "legacy_tool",
                "status": "completed",
                "icon": "icon"
            },
            "isStreaming": false,
            "imageURLs": [],
            "audioURLs": []
        }
        """

        let data = jsonString.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decodedMessage = try decoder.decode(Message.self, from: data)

        XCTAssertEqual(decodedMessage.toolCalls.count, 1)
        XCTAssertEqual(decodedMessage.toolCalls.first?.toolName, "legacy_tool")
    }

    func testMessageDecodingWithEmptyToolCalls() throws {
        let jsonString = """
        {
            "id": "00000000-0000-0000-0000-000000000001",
            "content": "No tools",
            "isUser": true,
            "timestamp": "2024-01-01T00:00:00Z",
            "isStreaming": false,
            "imageURLs": [],
            "audioURLs": []
        }
        """

        let data = jsonString.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decodedMessage = try decoder.decode(Message.self, from: data)

        XCTAssertTrue(decodedMessage.toolCalls.isEmpty)
    }

    // MARK: - ToolCall Tests

    func testToolCallInitialization() {
        let toolCall = ToolCall(
            id: UUID(),
            toolName: "generate_music",
            status: "Creating song...",
            icon: "music.note",
            details: [
                ToolCallDetail(label: "Lyrics", value: "[verse]\nTest lyric")
            ]
        )

        XCTAssertEqual(toolCall.toolName, "generate_music")
        XCTAssertEqual(toolCall.status, "Creating song...")
        XCTAssertEqual(toolCall.icon, "music.note")
        XCTAssertEqual(toolCall.details, [
            ToolCallDetail(label: "Lyrics", value: "[verse]\nTest lyric")
        ])
    }

    func testToolCallIdentifiable() {
        let id = UUID()
        let toolCall = ToolCall(
            id: id,
            toolName: "test",
            status: "status",
            icon: "icon"
        )

        XCTAssertEqual(toolCall.id, id)
    }
}
