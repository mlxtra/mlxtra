import XCTest
@testable import MLXtra

final class VLMResponseEventParserTests: XCTestCase {
    func testHandlesOnlyResponseStreamEvents() {
        XCTAssertTrue(VLMResponseEventParser.handles(["type": "chat.completion.chunk"]))
        XCTAssertTrue(VLMResponseEventParser.handles(["type": "chat.completion.complete"]))
        XCTAssertTrue(VLMResponseEventParser.handles(["type": "chat.completion.tool_calls"]))
        XCTAssertTrue(VLMResponseEventParser.handles(["type": "image.generated"]))
        XCTAssertTrue(VLMResponseEventParser.handles(["type": "audio.generated"]))
        XCTAssertTrue(VLMResponseEventParser.handles(["type": "model.loading"]))
        XCTAssertTrue(VLMResponseEventParser.handles(["type": "model.loaded"]))
        XCTAssertTrue(VLMResponseEventParser.handles(["type": "generation.progress"]))
        XCTAssertTrue(VLMResponseEventParser.handles(["type": "error"]))

        XCTAssertFalse(VLMResponseEventParser.handles(["type": "model.initialized"]))
        XCTAssertFalse(VLMResponseEventParser.handles(["type": "unrelated"]))
        XCTAssertFalse(VLMResponseEventParser.handles([:]))
    }

    func testChunksAccumulateIntoCompletionWithUsage() throws {
        let parser = VLMResponseEventParser(modelId: "mlx-community/test", backend: .llm)

        let firstChunk = try XCTUnwrap(parser.parse([
            "type": "chat.completion.chunk",
            "choices": [
                ["delta": ["content": "Hello"]]
            ]
        ]))
        XCTAssertFalse(firstChunk.finishesStream)
        assertToken(firstChunk.events, equals: "Hello")

        let secondChunk = try XCTUnwrap(parser.parse([
            "type": "chat.completion.chunk",
            "choices": [
                ["delta": ["content": " world"]]
            ]
        ]))
        XCTAssertFalse(secondChunk.finishesStream)
        assertToken(secondChunk.events, equals: " world")

        let complete = try XCTUnwrap(parser.parse([
            "type": "chat.completion.complete",
            "choices": [
                ["message": ["content": "ignored when chunks exist"]]
            ],
            "usage": [
                "prompt_tokens": 7,
                "completion_tokens": 2
            ],
            "performance": [
                "prompt_tokens_per_second": 13.5,
                "tokens_per_second": 22.0,
                "peak_memory_gb": 4.25
            ],
            "acceleration": [
                "requested": true,
                "active": true,
                "state": "active"
            ]
        ]))

        XCTAssertTrue(complete.finishesStream)
        guard case .complete(let content, let usage) = try XCTUnwrap(complete.events.first) else {
            return XCTFail("Expected complete event")
        }
        XCTAssertEqual(content, "Hello world")
        XCTAssertEqual(usage.promptTokens, 7)
        XCTAssertEqual(usage.completionTokens, 2)
        XCTAssertEqual(usage.promptTokensPerSecond, 13.5)
        XCTAssertEqual(usage.generationTokensPerSecond, 22.0)
        XCTAssertEqual(usage.peakMemoryGB, 4.25)
        XCTAssertEqual(usage.accelerationState, .active)
    }

    func testCompletionParsesAccelerationFallbackState() throws {
        let parser = VLMResponseEventParser(modelId: "mlx-community/test", backend: .llm)

        let complete = try XCTUnwrap(parser.parse([
            "type": "chat.completion.complete",
            "choices": [
                ["message": ["content": "Full response"]]
            ],
            "acceleration": [
                "requested": true,
                "active": false,
                "state": "fallback"
            ]
        ]))

        guard case .complete(_, let usage) = try XCTUnwrap(complete.events.first) else {
            return XCTFail("Expected complete event")
        }
        XCTAssertEqual(usage.accelerationState, .fallback)
    }

    func testCompletionFallsBackToMessageContentWhenNoChunksWereSeen() throws {
        let parser = VLMResponseEventParser(modelId: "mlx-community/test", backend: .llm)

        let complete = try XCTUnwrap(parser.parse([
            "type": "chat.completion.complete",
            "choices": [
                ["message": ["content": "Full response"]]
            ]
        ]))

        XCTAssertTrue(complete.finishesStream)
        guard case .complete(let content, let usage) = try XCTUnwrap(complete.events.first) else {
            return XCTFail("Expected complete event")
        }
        XCTAssertEqual(content, "Full response")
        XCTAssertEqual(usage.promptTokens, 0)
        XCTAssertEqual(usage.completionTokens, 0)
    }

    func testToolCallParsingFinishesAndIgnoresMalformedCalls() throws {
        let parser = VLMResponseEventParser(modelId: "mlx-community/test", backend: .llm)

        let parsed = try XCTUnwrap(parser.parse([
            "type": "chat.completion.tool_calls",
            "tool_calls": [
                [
                    "id": "call-1",
                    "function": [
                        "name": "lookup",
                        "arguments": "{\"query\":\"mlx\"}"
                    ]
                ],
                [
                    "id": "bad-call",
                    "function": [
                        "name": "missing_arguments"
                    ]
                ]
            ]
        ]))

        XCTAssertTrue(parsed.finishesStream)
        guard case .toolCalls(let calls) = try XCTUnwrap(parsed.events.first) else {
            return XCTFail("Expected toolCalls event")
        }
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].id, "call-1")
        XCTAssertEqual(calls[0].function.name, "lookup")
        XCTAssertEqual(calls[0].function.arguments, "{\"query\":\"mlx\"}")
    }

    func testEmptyToolCallArrayFinishesWithoutYieldingEvent() throws {
        let parser = VLMResponseEventParser(modelId: "mlx-community/test", backend: .llm)

        let parsed = try XCTUnwrap(parser.parse([
            "type": "chat.completion.tool_calls",
            "tool_calls": []
        ]))

        XCTAssertTrue(parsed.finishesStream)
        XCTAssertTrue(parsed.events.isEmpty)
    }

    func testMissingToolCallsDoesNotFinishStream() throws {
        let parser = VLMResponseEventParser(modelId: "mlx-community/test", backend: .llm)

        let parsed = try XCTUnwrap(parser.parse([
            "type": "chat.completion.tool_calls"
        ]))

        XCTAssertFalse(parsed.finishesStream)
        XCTAssertTrue(parsed.events.isEmpty)
    }

    func testGeneratedMediaEventsMapToFileURLs() throws {
        let parser = VLMResponseEventParser(modelId: "mlx-community/test", backend: .image)

        let image = try XCTUnwrap(parser.parse([
            "type": "image.generated",
            "path": "/tmp/generated.png"
        ]))
        guard case .image(let imageURL) = try XCTUnwrap(image.events.first) else {
            return XCTFail("Expected image event")
        }
        XCTAssertEqual(imageURL.path, "/tmp/generated.png")
        XCTAssertFalse(image.finishesStream)

        let audio = try XCTUnwrap(parser.parse([
            "type": "audio.generated",
            "path": "/tmp/generated.wav"
        ]))
        guard case .audio(let audioURL) = try XCTUnwrap(audio.events.first) else {
            return XCTFail("Expected audio event")
        }
        XCTAssertEqual(audioURL.path, "/tmp/generated.wav")
        XCTAssertFalse(audio.finishesStream)
    }

    func testModelLoadingYieldsDisplayProgressAndStructuredProgress() throws {
        let parser = VLMResponseEventParser(modelId: "fallback-model", backend: .llm)

        let parsed = try XCTUnwrap(parser.parse([
            "type": "model.loading",
            "model": "bridge-model",
            "backend": "vlm",
            "phase": "loading_weights",
            "detail": "Loading tensors",
            "percent": 42
        ]))

        XCTAssertFalse(parsed.finishesStream)
        XCTAssertEqual(parsed.events.count, 2)
        guard case .progress(let detail) = parsed.events[0] else {
            return XCTFail("Expected progress event")
        }
        XCTAssertEqual(detail, "Loading tensors")

        guard case .modelLoadProgress(let progress) = parsed.events[1] else {
            return XCTFail("Expected modelLoadProgress event")
        }
        XCTAssertEqual(progress.modelId, "bridge-model")
        XCTAssertEqual(progress.backend, .vlm)
        XCTAssertEqual(progress.phase, .loadingWeights)
        XCTAssertEqual(try XCTUnwrap(progress.fractionCompleted), 0.42, accuracy: 0.0001)
        XCTAssertEqual(progress.detail, "Loading tensors")
    }

    func testGenerationProgressYieldsStructuredProgress() throws {
        let parser = VLMResponseEventParser(modelId: "fallback-model", backend: .image)

        let parsed = try XCTUnwrap(parser.parse([
            "type": "generation.progress",
            "model": "image-model",
            "backend": "image",
            "phase": "denoising",
            "message": "Denoising image",
            "percent": 42,
            "estimated": false
        ]))

        XCTAssertFalse(parsed.finishesStream)
        XCTAssertEqual(parsed.events.count, 1)
        guard case .generationProgress(let progress) = parsed.events[0] else {
            return XCTFail("Expected generationProgress event")
        }
        XCTAssertEqual(progress.modelId, "image-model")
        XCTAssertEqual(progress.backend, .image)
        XCTAssertEqual(progress.phase, "denoising")
        XCTAssertEqual(progress.message, "Denoising image")
        XCTAssertEqual(try XCTUnwrap(progress.fractionCompleted), 0.42, accuracy: 0.0001)
        XCTAssertFalse(progress.isEstimated)
        XCTAssertEqual(progress.percentText, "42%")
    }

    func testGenerationProgressParsesFallbacksClampsAndEstimatedStrings() throws {
        let parser = VLMResponseEventParser(modelId: "fallback-model", backend: .music)

        let parsed = try XCTUnwrap(parser.parse([
            "type": "generation.progress",
            "phase": "generating",
            "message": "  Generating music  ",
            "fraction": 1.4,
            "estimated": "true"
        ]))

        guard case .generationProgress(let progress) = try XCTUnwrap(parsed.events.first) else {
            return XCTFail("Expected generationProgress event")
        }
        XCTAssertEqual(progress.modelId, "fallback-model")
        XCTAssertEqual(progress.backend, .music)
        XCTAssertEqual(progress.fractionCompleted, 1.0)
        XCTAssertTrue(progress.isEstimated)
        XCTAssertEqual(progress.percentText, "~100%")
        XCTAssertEqual(progress.displayDetail, "Generating music (~100%)")
    }

    func testErrorEventFinishesStream() throws {
        let parser = VLMResponseEventParser(modelId: "mlx-community/test", backend: .llm)

        let parsed = try XCTUnwrap(parser.parse([
            "type": "error",
            "message": "bridge failed"
        ]))

        XCTAssertTrue(parsed.finishesStream)
        guard case .error(let error) = try XCTUnwrap(parsed.events.first),
              let executionError = error as? ExecutionError,
              case .pythonError(let message) = executionError else {
            return XCTFail("Expected pythonError event")
        }
        XCTAssertEqual(message, "bridge failed")
    }

    private func assertToken(
        _ events: [ExecutionEvent],
        equals expectedToken: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .token(let token) = events.first else {
            return XCTFail("Expected token event", file: file, line: line)
        }
        XCTAssertEqual(token, expectedToken, file: file, line: line)
    }
}
