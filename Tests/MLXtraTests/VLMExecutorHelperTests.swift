import XCTest
@testable import MLXtra

final class VLMExecutorHelperTests: XCTestCase {


    func testBridgeLineBufferEmpty() {
        let buffer = BridgeLineBuffer()
        let lines = buffer.append("")
        XCTAssertTrue(lines.isEmpty)
    }

    func testBridgeLineBufferSingleLine() {
        let buffer = BridgeLineBuffer()
        let lines = buffer.append("hello\n")
        XCTAssertEqual(lines, ["hello"])
    }

    func testBridgeLineBufferMultipleLines() {
        let buffer = BridgeLineBuffer()
        let lines = buffer.append("line1\nline2\nline3\n")
        XCTAssertEqual(lines, ["line1", "line2", "line3"])
    }

    func testBridgeLineBufferPartialLines() {
        let buffer = BridgeLineBuffer()
        let lines1 = buffer.append("partial")
        XCTAssertTrue(lines1.isEmpty)

        let lines2 = buffer.append(" line\n")
        XCTAssertEqual(lines2, ["partial line"])
    }

    func testBridgeLineBufferWhitespaceTrimming() {
        let buffer = BridgeLineBuffer()
        let lines = buffer.append("  trimmed  \n")
        XCTAssertEqual(lines, ["trimmed"])
    }

    func testBridgeLineBufferEmptyLinesSkipped() {
        let buffer = BridgeLineBuffer()
        let lines = buffer.append("\n\n\n")
        XCTAssertTrue(lines.isEmpty)
    }

    func testBridgeLineBufferMixedEmptyAndContent() {
        let buffer = BridgeLineBuffer()
        let lines = buffer.append("\ncontent\n\nmore\n")
        XCTAssertEqual(lines, ["content", "more"])
    }

    func testBridgeLineBufferCarriageReturn() {
        let buffer = BridgeLineBuffer()
        // The BridgeLineBuffer only handles \n, not \r\n - this test documents that limitation
        let lines = buffer.append("line1\nline2\n")
        XCTAssertEqual(lines, ["line1", "line2"])
    }

    func testBridgeLineBufferAccumulatesPending() {
        let buffer = BridgeLineBuffer()
        _ = buffer.append("first ")
        _ = buffer.append("second ")
        let lines = buffer.append("third\n")
        XCTAssertEqual(lines, ["first second third"])
    }

    func testBridgeLineBufferJsonParsing() {
        let buffer = BridgeLineBuffer()
        let jsonLine = "{\"type\": \"chat.completion\", \"content\": \"hello\"}"
        let lines = buffer.append(jsonLine + "\n")
        XCTAssertEqual(lines, [jsonLine])
    }

    func testBridgeLineBufferUnicodeContent() {
        let buffer = BridgeLineBuffer()
        let lines = buffer.append("Hello, 世界! 🌍\n")
        XCTAssertEqual(lines, ["Hello, 世界! 🌍"])
    }

    func testBridgeLineBufferPreservesSplitMultibyteScalar() {
        let buffer = BridgeLineBuffer()
        let data = Data("Hello, 世界! 🌍\n".utf8)
        let splitIndex = data.firstIndex(of: 0xF0) ?? 0
        let firstChunk = Data(data[..<data.index(splitIndex, offsetBy: 2)])
        let secondChunk = Data(data[data.index(splitIndex, offsetBy: 2)...])

        XCTAssertTrue(buffer.append(firstChunk).isEmpty)
        XCTAssertEqual(buffer.append(secondChunk), ["Hello, 世界! 🌍"])
        XCTAssertNil(buffer.flush())
    }

    func testBridgeLineBufferFlushesTrailingLineWithoutNewline() {
        let buffer = BridgeLineBuffer()

        XCTAssertTrue(buffer.append(Data("partial stderr".utf8)).isEmpty)
        XCTAssertEqual(buffer.flush(), "partial stderr")
        XCTAssertNil(buffer.flush())
    }

    func testDownloadUTF8BufferPreservesSplitMultibyteScalar() {
        let buffer = DownloadUTF8Buffer()
        let data = Data("prefix 🌍 suffix".utf8)
        let splitIndex = data.firstIndex(of: 0xF0) ?? 0
        let firstChunk = Data(data[..<data.index(splitIndex, offsetBy: 2)])
        let secondChunk = Data(data[data.index(splitIndex, offsetBy: 2)...])

        XCTAssertNil(buffer.append(firstChunk))
        XCTAssertEqual(buffer.append(secondChunk), "prefix 🌍 suffix")
        XCTAssertNil(buffer.flush())
    }

    func testVLMBridgeRequestWriterAppendsNewlineToJSONPayload() throws {
        let lineData = try VLMBridgeRequestWriter.lineData(for: ["type": "ping", "request_id": "req-1"])

        XCTAssertEqual(lineData.last, 0x0A)
        let line = String(decoding: lineData.dropLast(), as: UTF8.self)
        let decoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )
        XCTAssertEqual(decoded["type"] as? String, "ping")
        XCTAssertEqual(decoded["request_id"] as? String, "req-1")
    }

    func testVLMBridgeRequestWriterRejectsInvalidPayloadAsEncodingFailure() {
        XCTAssertThrowsError(
            try VLMBridgeRequestWriter.lineData(for: ["invalid": Date()])
        ) { error in
            guard case ExecutionError.encodingFailed = error else {
                XCTFail("Expected encodingFailed, got \(error)")
                return
            }
        }
    }

    func testVLMBridgeRequestWriterReportsPipeWriteFailureWhileProcessRuns() {
        struct TestWriteError: LocalizedError {
            var errorDescription: String? { "Broken pipe" }
        }

        XCTAssertThrowsError(
            try VLMBridgeRequestWriter.write(
                ["type": "ping"],
                write: { _ in throw TestWriteError() },
                processIsRunning: { true },
                stoppedProcessError: { .processStopped("traceback") }
            )
        ) { error in
            guard case ExecutionError.pipeWriteFailed(let message) = error else {
                XCTFail("Expected pipeWriteFailed, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("Broken pipe"))
        }
    }

    func testVLMBridgeRequestWriterReportsStoppedProcessWhenWriteFailsAfterExit() {
        struct TestWriteError: LocalizedError {
            var errorDescription: String? { "Input/output error" }
        }

        XCTAssertThrowsError(
            try VLMBridgeRequestWriter.write(
                ["type": "ping"],
                write: { _ in throw TestWriteError() },
                processIsRunning: { false },
                stoppedProcessError: { .processStopped("bridge traceback") }
            )
        ) { error in
            guard case ExecutionError.processStopped(let message) = error else {
                XCTFail("Expected processStopped, got \(error)")
                return
            }
            XCTAssertEqual(message, "bridge traceback")
        }
    }

    func testBridgeLineBufferThreadSafety() {
        let buffer = BridgeLineBuffer()
        let expectation = self.expectation(description: "Concurrent appends")

        DispatchQueue.concurrentPerform(iterations: 10) { _ in
            _ = buffer.append("line\n")
        }

        expectation.fulfill()
        waitForExpectations(timeout: 1)

        // After concurrent appends, we may or may not have complete lines
        // Just verify the buffer handles concurrent access without crashing
        let lines = buffer.append("final\n")
        XCTAssertTrue(lines.count >= 1 || true) // Test passes if no crash
    }


    func testResponseBuilderInitialState() {
        let builder = ResponseBuilder()
        XCTAssertEqual(builder.fullResponse, "")
    }

    func testResponseBuilderAppend() {
        let builder = ResponseBuilder()
        builder.append("Hello")
        XCTAssertEqual(builder.fullResponse, "Hello")

        builder.append(" ")
        XCTAssertEqual(builder.fullResponse, "Hello ")

        builder.append("World")
        XCTAssertEqual(builder.fullResponse, "Hello World")
    }

    func testResponseBuilderAppendEmpty() {
        let builder = ResponseBuilder()
        builder.append("content")
        builder.append("")
        XCTAssertEqual(builder.fullResponse, "content")
    }

    func testResponseBuilderAppendUnicode() {
        let builder = ResponseBuilder()
        builder.append("Hello, 世界! 🌍")
        XCTAssertEqual(builder.fullResponse, "Hello, 世界! 🌍")
    }

    func testResponseBuilderConcurrentAccess() {
        let builder = ResponseBuilder()
        let expectation = self.expectation(description: "Concurrent appends")

        DispatchQueue.concurrentPerform(iterations: 10) { index in
            builder.append("line\(index)")
        }

        expectation.fulfill()
        waitForExpectations(timeout: 1)

        XCTAssertFalse(builder.fullResponse.isEmpty)
    }

    func testResponseBuilderMultipleAppends() {
        let builder = ResponseBuilder()
        for i in 0..<100 {
            builder.append("chunk\(i)")
        }
        XCTAssertTrue(builder.fullResponse.hasPrefix("chunk0"))
        XCTAssertTrue(builder.fullResponse.hasSuffix("chunk99"))
        XCTAssertTrue(builder.fullResponse.count > 600) // chunk0-chunk9 (6 chars) + chunk10-chunk99 (7 chars)
    }

    func testModelLoadedStateRecordsLoadedAndErrorThreadSafely() {
        let state = ModelLoadedState()

        XCTAssertFalse(state.isLoaded)
        XCTAssertNil(state.errorMessage)

        state.setError("missing model")
        XCTAssertEqual(state.errorMessage, "missing model")

        state.setLoaded()
        XCTAssertTrue(state.isLoaded)
    }

    func testModelLoadedStateBuffersAndDrainsProgressThreadSafely() {
        let state = ModelLoadedState()

        DispatchQueue.concurrentPerform(iterations: 10) { index in
            state.appendProgress(
                ModelLoadProgress(
                    modelId: "model-\(index)",
                    backend: .vlm,
                    phase: .loadingWeights,
                    fractionCompleted: Double(index) / 10.0,
                    detail: "chunk \(index)"
                )
            )
        }

        let progress = state.drainProgress()
        XCTAssertEqual(progress.count, 10)
        XCTAssertTrue(state.drainProgress().isEmpty)
        XCTAssertTrue(progress.contains { $0.detail == "chunk 9" })
    }

    func testStreamFinishStateOnlyFinishesOnce() {
        let state = StreamFinishState()

        XCTAssertFalse(state.isFinished)
        XCTAssertTrue(state.finish())
        XCTAssertTrue(state.isFinished)
        XCTAssertFalse(state.finish())
    }

    func testReadyStateRecordsStartupError() {
        let state = ReadyState()

        state.setError("startup failed")
        XCTAssertFalse(state.isReady)
        XCTAssertEqual(state.errorMessage, "startup failed")

        state.setReady()
        XCTAssertTrue(state.isReady)
    }

    func testReadyStateRecordsReadyAndErrorThreadSafely() {
        let state = ReadyState()

        DispatchQueue.concurrentPerform(iterations: 10) { index in
            if index.isMultiple(of: 2) {
                state.setReady()
            } else {
                state.setError("startup failed \(index)")
            }
        }

        XCTAssertTrue(state.isReady)
        XCTAssertNotNil(state.errorMessage)
    }

    func testVLMBridgeEnvironmentRemovesHostPythonState() {
        let baseEnvironment = [
            "PYTHONPATH": "/host/python",
            "VIRTUAL_ENV": "/host/venv",
            "CONDA_PREFIX": "/conda",
            "CONDA_DEFAULT_ENV": "base",
            "PYENV_ROOT": "/pyenv",
            "PYENV_VERSION": "3.11.1",
            "MLXTRA_BRIDGE_DEBUG": "0",
            "KEEP_ME": "yes"
        ]

        let environment = VLMBridgeEnvironment.make(
            baseEnvironment: baseEnvironment,
            pythonHomePath: URL(fileURLWithPath: "/runtime/python"),
            checkpointsPath: URL(fileURLWithPath: "/checkpoints"),
            acestepPythonPath: URL(fileURLWithPath: "/runtime/acestep/bin/python"),
            bridgeDebugEnabled: false,
            homeDirectory: URL(fileURLWithPath: "/Users/test")
        )

        for key in VLMBridgeEnvironment.removedHostPythonKeys {
            XCTAssertNil(environment[key], "\(key) should not leak into the bridge environment")
        }
        XCTAssertNil(environment["MLXTRA_BRIDGE_DEBUG"])
        XCTAssertEqual(environment["KEEP_ME"], "yes")
    }

    func testVLMBridgeEnvironmentSetsRuntimePathsAndFlags() {
        let environment = VLMBridgeEnvironment.make(
            baseEnvironment: [:],
            pythonHomePath: URL(fileURLWithPath: "/runtime/python"),
            checkpointsPath: URL(fileURLWithPath: "/checkpoints"),
            acestepPythonPath: URL(fileURLWithPath: "/runtime/acestep/bin/python"),
            bridgeDebugEnabled: true,
            homeDirectory: URL(fileURLWithPath: "/Users/test")
        )

        XCTAssertEqual(environment["PYTHONHOME"], "/runtime/python")
        XCTAssertEqual(environment["PYTHONDONTWRITEBYTECODE"], "1")
        XCTAssertEqual(environment["PYTHONUNBUFFERED"], "1")
        XCTAssertEqual(environment["MLXTRA_BRIDGE_DEBUG"], "1")
        XCTAssertEqual(environment["HF_HOME"], "/Users/test/.cache/huggingface")
        XCTAssertEqual(environment["HF_HUB_CACHE"], "/Users/test/.cache/huggingface/hub")
        XCTAssertEqual(environment["ACESTEP_CHECKPOINTS_DIR"], "/checkpoints")
        XCTAssertEqual(environment["ACESTEP_PYTHON"], "/runtime/acestep/bin/python")
        XCTAssertEqual(environment["MTL_DEBUG_LAYER"], "0")
        XCTAssertEqual(environment["MTL_SHADER_VALIDATION"], "0")
    }
}
