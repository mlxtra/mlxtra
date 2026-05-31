import XCTest
@testable import MLXtra

final class VLMRequestPayloadBuilderTests: XCTestCase {
    func testMessageTypeMapping() {
        XCTAssertEqual(VLMRequestPayloadBuilder.messageType(for: .image), "image.generate")
        XCTAssertEqual(VLMRequestPayloadBuilder.messageType(for: .audio), "audio.speech")
        XCTAssertEqual(VLMRequestPayloadBuilder.messageType(for: .music), "music.generate")
        XCTAssertEqual(VLMRequestPayloadBuilder.messageType(for: .vlm), "chat.completions")
        XCTAssertEqual(VLMRequestPayloadBuilder.messageType(for: .llm), "chat.completions")
    }

    func testExecutionPayloadIncludesRequiredFieldsAndMessages() throws {
        let request = ExecutionRequest(
            requestID: "request-123",
            backend: .vlm,
            modelId: "mlx-community/test-vlm",
            messages: [
                ExecutionMessage(role: .system, content: "Be concise"),
                ExecutionMessage(role: .user, content: "Describe this")
            ],
            maxTokens: 128,
            temperature: 0.25
        )

        let payload = VLMRequestPayloadBuilder.executionPayload(for: request)

        XCTAssertEqual(payload["request_id"] as? String, "request-123")
        XCTAssertEqual(payload["type"] as? String, "chat.completions")
        XCTAssertEqual(payload["model"] as? String, "mlx-community/test-vlm")
        XCTAssertEqual(payload["max_tokens"] as? Int, 128)
        XCTAssertEqual(payload["temperature"] as? Double, 0.25)
        XCTAssertEqual(payload["images"] as? [String], [])

        let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[0]["content"] as? String, "Be concise")
        XCTAssertEqual(messages[1]["role"] as? String, "user")
        XCTAssertEqual(messages[1]["content"] as? String, "Describe this")
    }

    func testExecutionPayloadIncludesOptionalSamplingToolsMediaAndParameters() throws {
        let toolCall = ExecutionToolCall(
            id: "call-1",
            function: ExecutionToolCallFunction(name: "web_search", arguments: "{\"q\":\"mlx\"}")
        )
        let tools: [[String: Any]] = [
            [
                "type": "function",
                "function": ["name": "web_search"]
            ]
        ]
        let parameters: [String: Any] = [
            "caption": "ambient piano",
            "duration": 8
        ]
        let chatTemplateKwargs: [String: Any] = [
            "enable_thinking": true
        ]
        let request = ExecutionRequest(
            requestID: "request-456",
            backend: .music,
            modelId: "ACE-Step/acestep-v15-turbo-continuous",
            messages: [
                ExecutionMessage(
                    role: .assistant,
                    toolCalls: [toolCall],
                    toolCallId: "call-1",
                    name: "assistant-tool"
                )
            ],
            images: [
                URL(fileURLWithPath: "/tmp/a.png"),
                URL(fileURLWithPath: "/tmp/b.png")
            ],
            outputDirectory: URL(fileURLWithPath: "/tmp/output"),
            maxTokens: 2048,
            temperature: 0.9,
            topP: 0.95,
            topK: 40,
            minP: 0.05,
            repetitionPenalty: 1.1,
            chatTemplateKwargs: chatTemplateKwargs,
            tools: tools,
            parameters: parameters
        )

        let payload = VLMRequestPayloadBuilder.executionPayload(for: request)

        XCTAssertEqual(payload["type"] as? String, "music.generate")
        XCTAssertEqual(payload["images"] as? [String], ["/tmp/a.png", "/tmp/b.png"])
        XCTAssertEqual(payload["output_dir"] as? String, "/tmp/output")
        XCTAssertEqual(payload["top_p"] as? Double, 0.95)
        XCTAssertEqual(payload["top_k"] as? Int, 40)
        XCTAssertEqual(payload["min_p"] as? Double, 0.05)
        XCTAssertEqual(payload["repetition_penalty"] as? Double, 1.1)

        let payloadChatTemplateKwargs = try XCTUnwrap(payload["chat_template_kwargs"] as? [String: Any])
        XCTAssertEqual(payloadChatTemplateKwargs["enable_thinking"] as? Bool, true)

        let payloadParameters = try XCTUnwrap(payload["parameters"] as? [String: Any])
        XCTAssertEqual(payloadParameters["caption"] as? String, "ambient piano")
        XCTAssertEqual(payloadParameters["duration"] as? Int, 8)

        let payloadTools = try XCTUnwrap(payload["tools"] as? [[String: Any]])
        XCTAssertEqual(payloadTools.count, 1)
        XCTAssertEqual(payloadTools[0]["type"] as? String, "function")

        let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["role"] as? String, "assistant")
        XCTAssertEqual(messages[0]["tool_call_id"] as? String, "call-1")
        XCTAssertEqual(messages[0]["name"] as? String, "assistant-tool")
        let toolCalls = try XCTUnwrap(messages[0]["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(toolCalls.first?["id"] as? String, "call-1")
    }

    func testExecutionPayloadOmitsNilOptionalFields() {
        let request = ExecutionRequest(
            requestID: "request-789",
            backend: .audio,
            modelId: "mlx-community/test-audio",
            messages: [ExecutionMessage(role: .user, content: "Speak this")]
        )

        let payload = VLMRequestPayloadBuilder.executionPayload(for: request)

        XCTAssertEqual(payload["type"] as? String, "audio.speech")
        XCTAssertNil(payload["output_dir"])
        XCTAssertNil(payload["top_p"])
        XCTAssertNil(payload["top_k"])
        XCTAssertNil(payload["min_p"])
        XCTAssertNil(payload["repetition_penalty"])
        XCTAssertNil(payload["chat_template_kwargs"])
        XCTAssertNil(payload["tools"])
        XCTAssertNil(payload["parameters"])
    }

    func testModelLoadPayloadIncludesParametersWhenProvided() throws {
        let payload = VLMRequestPayloadBuilder.modelLoadPayload(
            requestID: "load-123",
            modelId: "mlx-community/test",
            backend: .image,
            parameters: ["quantization": "q4"]
        )

        XCTAssertEqual(payload["request_id"] as? String, "load-123")
        XCTAssertEqual(payload["type"] as? String, "init")
        XCTAssertEqual(payload["model_id"] as? String, "mlx-community/test")
        XCTAssertEqual(payload["backend"] as? String, "image")

        let parameters = try XCTUnwrap(payload["parameters"] as? [String: Any])
        XCTAssertEqual(parameters["quantization"] as? String, "q4")
    }

    func testModelLoadPayloadOmitsNilParameters() {
        let payload = VLMRequestPayloadBuilder.modelLoadPayload(
            requestID: "load-456",
            modelId: "mlx-community/test",
            backend: .llm
        )

        XCTAssertEqual(payload["backend"] as? String, "llm")
        XCTAssertNil(payload["parameters"])
    }
}
