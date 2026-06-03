import XCTest
@testable import MLXtra

final class ExecutionTypesTests: XCTestCase {


    func testExecutionRequestDefaultValues() {
        let request = ExecutionRequest(
            modelId: "test-model",
            messages: [ExecutionMessage(role: .user, content: "Hello")]
        )

        XCTAssertEqual(request.backend, .vlm)
        XCTAssertEqual(request.modelId, "test-model")
        XCTAssertEqual(request.messages.count, 1)
        XCTAssertEqual(request.maxTokens, 32768)
        XCTAssertEqual(request.temperature, 0.7)
        XCTAssertNil(request.topP)
        XCTAssertNil(request.topK)
        XCTAssertNil(request.minP)
        XCTAssertNil(request.repetitionPenalty)
        XCTAssertNil(request.images)
        XCTAssertNil(request.outputDirectory)
        XCTAssertNil(request.chatTemplateKwargs)
        XCTAssertNil(request.tools)
        XCTAssertNil(request.parameters)
    }

    func testExecutionRequestCustomValues() {
        let images = [URL(fileURLWithPath: "/test/image.png")]
        let outputDir = URL(fileURLWithPath: "/test/output")
        let tools: [[String: Any]] = [["type": "function"]]
        let params: [String: Any] = ["param1": "value1"]

        let request = ExecutionRequest(
            backend: .music,
            modelId: "music-model",
            messages: [ExecutionMessage(role: .user, content: "Generate music")],
            images: images,
            outputDirectory: outputDir,
            maxTokens: 1000,
            temperature: 0.9,
            topP: 0.95,
            topK: 50,
            minP: 0.1,
            repetitionPenalty: 1.2,
            chatTemplateKwargs: ["enable_thinking": true],
            tools: tools,
            parameters: params
        )

        XCTAssertEqual(request.backend, .music)
        XCTAssertEqual(request.modelId, "music-model")
        XCTAssertEqual(request.images?.count, 1)
        XCTAssertEqual(request.outputDirectory, outputDir)
        XCTAssertEqual(request.maxTokens, 1000)
        XCTAssertEqual(request.temperature, 0.9)
        XCTAssertEqual(request.topP, 0.95)
        XCTAssertEqual(request.topK, 50)
        XCTAssertEqual(request.minP, 0.1)
        XCTAssertEqual(request.repetitionPenalty, 1.2)
        XCTAssertNotNil(request.chatTemplateKwargs)
        XCTAssertEqual(request.tools?.count, 1)
        XCTAssertNotNil(request.parameters)
    }


    func testExecutionMessageBasic() {
        let message = ExecutionMessage(role: .user, content: "Test content")

        XCTAssertEqual(message.role, .user)
        XCTAssertEqual(message.content, "Test content")
        XCTAssertNil(message.toolCalls)
        XCTAssertNil(message.toolCallId)
        XCTAssertNil(message.name)
    }

    func testExecutionMessageWithToolCall() {
        let toolCall = ExecutionToolCall(
            id: "call-123",
            function: ExecutionToolCallFunction(name: "test_function", arguments: "{}")
        )
        let message = ExecutionMessage(
            role: .assistant,
            content: "Using tool",
            toolCalls: [toolCall]
        )

        XCTAssertEqual(message.role, .assistant)
        XCTAssertEqual(message.content, "Using tool")
        XCTAssertEqual(message.toolCalls?.count, 1)
        XCTAssertEqual(message.toolCalls?.first?.id, "call-123")
    }

    func testExecutionMessageToDictionary() {
        let message = ExecutionMessage(role: .user, content: "Test")
        let dict = message.toDictionary()

        XCTAssertEqual(dict["role"] as? String, "user")
        XCTAssertEqual(dict["content"] as? String, "Test")
    }

    func testExecutionMessageToDictionaryWithToolCalls() {
        let toolCall = ExecutionToolCall(
            id: "call-123",
            function: ExecutionToolCallFunction(name: "test_fn", arguments: "{\"arg\": 1}")
        )
        let message = ExecutionMessage(
            role: .assistant,
            content: nil,
            toolCalls: [toolCall],
            toolCallId: "call-123",
            name: "test_name"
        )
        let dict = message.toDictionary()

        XCTAssertEqual(dict["role"] as? String, "assistant")
        XCTAssertEqual(dict["tool_call_id"] as? String, "call-123")
        XCTAssertEqual(dict["name"] as? String, "test_name")
        XCTAssertNotNil(dict["tool_calls"])
    }


    func testExecutionToolCallFunctionToDictionary() {
        let fn = ExecutionToolCallFunction(name: "test", arguments: "{\"key\": \"value\"}")
        let dict = fn.toDictionary()

        XCTAssertEqual(dict["name"] as? String, "test")
        XCTAssertEqual(dict["arguments"] as? String, "{\"key\": \"value\"}")
    }

    func testExecutionToolCallToDictionary() {
        let toolCall = ExecutionToolCall(
            id: "id-123",
            function: ExecutionToolCallFunction(name: "fn", arguments: "{}")
        )
        let dict = toolCall.toDictionary()

        XCTAssertEqual(dict["id"] as? String, "id-123")
        XCTAssertEqual(dict["type"] as? String, "function")
        XCTAssertNotNil(dict["function"])
    }


    func testMessageRoleRawValues() {
        XCTAssertEqual(MessageRole.system.rawValue, "system")
        XCTAssertEqual(MessageRole.user.rawValue, "user")
        XCTAssertEqual(MessageRole.assistant.rawValue, "assistant")
        XCTAssertEqual(MessageRole.tool.rawValue, "tool")
    }


    func testExecutionEventCases() {
        if case .started = ExecutionEvent.started {
        } else {
            XCTFail("Expected .started case")
        }

        if case .token(let text) = ExecutionEvent.token("hello") {
            XCTAssertEqual(text, "hello")
        } else {
            XCTFail("Expected .token case")
        }

        let imageURL = URL(fileURLWithPath: "/test/image.png")
        if case .image(let url) = ExecutionEvent.image(imageURL) {
            XCTAssertEqual(url, imageURL)
        } else {
            XCTFail("Expected .image case")
        }

        let audioURL = URL(fileURLWithPath: "/test/audio.wav")
        if case .audio(let url) = ExecutionEvent.audio(audioURL) {
            XCTAssertEqual(url, audioURL)
        } else {
            XCTFail("Expected .audio case")
        }

        let usage = TokenUsage(promptTokens: 10, completionTokens: 20)
        if case .complete(let text, let u) = ExecutionEvent.complete("response", usage: usage) {
            XCTAssertEqual(text, "response")
            XCTAssertEqual(u.promptTokens, 10)
            XCTAssertEqual(u.completionTokens, 20)
        } else {
            XCTFail("Expected .complete case")
        }

        if case .error(let err) = ExecutionEvent.error(ExecutionError.timeout) {
            XCTAssertNotNil(err)
        } else {
            XCTFail("Expected .error case")
        }

        if case .progress(let msg) = ExecutionEvent.progress("loading...") {
            XCTAssertEqual(msg, "loading...")
        } else {
            XCTFail("Expected .progress case")
        }
    }


    func testTokenUsageTotalTokens() {
        let usage = TokenUsage(promptTokens: 100, completionTokens: 50)
        XCTAssertEqual(usage.totalTokens, 150)
    }

    func testTokenUsageStoresBridgePerformance() {
        let usage = TokenUsage(
            promptTokens: 100,
            completionTokens: 50,
            promptTokensPerSecond: 250,
            generationTokensPerSecond: 25,
            peakMemoryGB: 3.5,
            accelerationState: .active
        )

        XCTAssertEqual(usage.promptTokensPerSecond, 250)
        XCTAssertEqual(usage.tokensPerSecond, 25)
        XCTAssertEqual(usage.peakMemoryGB, 3.5)
        XCTAssertEqual(usage.accelerationState, .active)
    }

    func testTokenUsageZeroTokens() {
        let usage = TokenUsage(promptTokens: 0, completionTokens: 0)
        XCTAssertEqual(usage.totalTokens, 0)
    }
}
