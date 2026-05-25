import XCTest
@testable import MLXtra

final class VLMExecutorIntegrationTests: XCTestCase {


    func testMessageTypeForBackend() {
        XCTAssertEqual(VLMExecutor.messageType(for: .image), "image.generate")
        XCTAssertEqual(VLMExecutor.messageType(for: .audio), "audio.speech")
        XCTAssertEqual(VLMExecutor.messageType(for: .music), "music.generate")
        XCTAssertEqual(VLMExecutor.messageType(for: .vlm), "chat.completions")
        XCTAssertEqual(VLMExecutor.messageType(for: .llm), "chat.completions")
    }


    func testShouldRetryForProcessCrashed() {
        XCTAssertTrue(VLMExecutor.shouldRetry(error: ExecutionError.processCrashed(retryCount: 0), retryCount: 0, maxRetries: 1))
        XCTAssertTrue(VLMExecutor.shouldRetry(error: ExecutionError.processNotRunning, retryCount: 0, maxRetries: 1))
        XCTAssertTrue(VLMExecutor.shouldRetry(error: ExecutionError.processStopped("traceback"), retryCount: 0, maxRetries: 1))
        XCTAssertTrue(VLMExecutor.shouldRetry(error: ExecutionError.timeout, retryCount: 0, maxRetries: 1))
    }

    func testShouldRetryFalseWhenMaxRetriesReached() {
        XCTAssertFalse(VLMExecutor.shouldRetry(error: ExecutionError.timeout, retryCount: 1, maxRetries: 1))
        XCTAssertFalse(VLMExecutor.shouldRetry(error: ExecutionError.processCrashed(retryCount: 2), retryCount: 2, maxRetries: 2))
    }

    func testShouldRetryFalseForOtherErrors() {
        XCTAssertFalse(VLMExecutor.shouldRetry(error: ExecutionError.notInitialized, retryCount: 0, maxRetries: 3))
        XCTAssertFalse(VLMExecutor.shouldRetry(error: ExecutionError.encodingFailed, retryCount: 0, maxRetries: 3))
        XCTAssertFalse(VLMExecutor.shouldRetry(error: ExecutionError.pythonError("test"), retryCount: 0, maxRetries: 3))
    }


    func testExecutionRequestMessageTypeMapping() {
        let backend = RuntimeBackend.vlm
        let request = ExecutionRequest(
            backend: backend,
            modelId: "test-model",
            messages: [ExecutionMessage(role: .user, content: "test")]
        )

        XCTAssertEqual(request.backend, .vlm)
        XCTAssertEqual(request.modelId, "test-model")
        XCTAssertEqual(request.messages.count, 1)
        XCTAssertFalse(request.requestID.isEmpty)
    }

    func testExecutionRequestUsesProvidedRequestID() {
        let request = ExecutionRequest(
            requestID: "req-explicit",
            backend: .llm,
            modelId: "test-model",
            messages: [ExecutionMessage(role: .user, content: "test")]
        )

        XCTAssertEqual(request.requestID, "req-explicit")
    }

    func testExecutionRequestWithAllParameters() {
        let images = [URL(fileURLWithPath: "/test/image.png")]
        let outputDir = URL(fileURLWithPath: "/test/output")
        let tools: [[String: Any]] = [["type": "function"]]
        let params: [String: Any] = ["caption": "test music"]

        let request = ExecutionRequest(
            backend: .music,
            modelId: "ACE-Step/acestep-v15-turbo-continuous",
            messages: [ExecutionMessage(role: .user, content: "Generate music")],
            images: images,
            outputDirectory: outputDir,
            maxTokens: 1000,
            temperature: 0.9,
            topP: 0.95,
            topK: 40,
            minP: 0.05,
            repetitionPenalty: 1.1,
            chatTemplateKwargs: ["enable_thinking": true],
            tools: tools,
            parameters: params
        )

        XCTAssertEqual(request.backend, .music)
        XCTAssertEqual(request.images?.count, 1)
        XCTAssertEqual(request.outputDirectory, outputDir)
        XCTAssertEqual(request.maxTokens, 1000)
        XCTAssertEqual(request.temperature, 0.9)
        XCTAssertEqual(request.topP, 0.95)
        XCTAssertEqual(request.topK, 40)
        XCTAssertEqual(request.minP, 0.05)
        XCTAssertEqual(request.repetitionPenalty, 1.1)
        XCTAssertNotNil(request.chatTemplateKwargs)
        XCTAssertNotNil(request.tools)
        XCTAssertNotNil(request.parameters)
    }


    func testExecutionMessageToDictionary() {
        let message = ExecutionMessage(
            role: .user,
            content: "Test content",
            toolCalls: nil,
            toolCallId: nil,
            name: nil
        )

        let dict = message.toDictionary()

        XCTAssertEqual(dict["role"] as? String, "user")
        XCTAssertEqual(dict["content"] as? String, "Test content")
    }

    func testExecutionMessageWithToolCallsToDictionary() {
        let toolCall = ExecutionToolCall(
            id: "call-123",
            function: ExecutionToolCallFunction(name: "test_fn", arguments: "{}")
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

    func testExecutionToolCallToDictionary() {
        let toolCall = ExecutionToolCall(
            id: "id-456",
            function: ExecutionToolCallFunction(name: "my_function", arguments: "{\"arg\": 1}")
        )

        let dict = toolCall.toDictionary()

        XCTAssertEqual(dict["id"] as? String, "id-456")
        XCTAssertEqual(dict["type"] as? String, "function")
        XCTAssertNotNil(dict["function"])
    }


    func testParseModelLoadingMessage() {
        let jsonString = "{\"type\": \"model.loading\", \"request_id\": \"req-123\", \"model\": \"test-model\", \"status\": \"loading\"}"

        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String,
              let status = json["status"] as? String,
              let requestID = json["request_id"] as? String else {
            XCTFail("Failed to parse JSON")
            return
        }

        XCTAssertEqual(type, "model.loading")
        XCTAssertEqual(status, "loading")
        XCTAssertEqual(requestID, "req-123")
    }

    func testParseModelLoadedMessage() {
        let jsonString = "{\"type\": \"model.loaded\", \"request_id\": \"req-123\", \"model\": \"test-model\"}"

        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String,
              let requestID = json["request_id"] as? String else {
            XCTFail("Failed to parse JSON")
            return
        }

        XCTAssertEqual(type, "model.loaded")
        XCTAssertEqual(requestID, "req-123")
    }

    func testParseModelInitializedMessage() {
        let jsonString = "{\"type\": \"model.initialized\", \"request_id\": \"req-123\", \"model\": \"test-model\"}"

        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String,
              let requestID = json["request_id"] as? String else {
            XCTFail("Failed to parse JSON")
            return
        }

        XCTAssertEqual(type, "model.initialized")
        XCTAssertEqual(requestID, "req-123")
    }

    func testParseErrorMessage() {
        let jsonString = "{\"type\": \"error\", \"request_id\": \"req-123\", \"message\": \"Something went wrong\"}"

        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String,
              let message = json["message"] as? String,
              let requestID = json["request_id"] as? String else {
            XCTFail("Failed to parse JSON")
            return
        }

        XCTAssertEqual(type, "error")
        XCTAssertEqual(message, "Something went wrong")
        XCTAssertEqual(requestID, "req-123")
    }

    func testParseAudioGeneratedMessage() {
        let jsonString = "{\"type\": \"audio.generated\", \"request_id\": \"req-123\", \"path\": \"/path/to/audio.wav\", \"sample_rate\": 48000}"

        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String,
              let path = json["path"] as? String,
              let sampleRate = json["sample_rate"] as? Int,
              let requestID = json["request_id"] as? String else {
            XCTFail("Failed to parse JSON")
            return
        }

        XCTAssertEqual(type, "audio.generated")
        XCTAssertEqual(path, "/path/to/audio.wav")
        XCTAssertEqual(sampleRate, 48000)
        XCTAssertEqual(requestID, "req-123")
    }

    func testParseChatCompletionChunk() {
        let jsonString = "{\"type\": \"chat.completion.chunk\", \"request_id\": \"req-123\", \"choices\": [{\"delta\": {\"content\": \"Hello\"}}]}"

        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String,
              let requestID = json["request_id"] as? String,
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let delta = firstChoice["delta"] as? [String: Any],
              let content = delta["content"] as? String else {
            XCTFail("Failed to parse JSON")
            return
        }

        XCTAssertEqual(type, "chat.completion.chunk")
        XCTAssertEqual(requestID, "req-123")
        XCTAssertEqual(content, "Hello")
    }
}
