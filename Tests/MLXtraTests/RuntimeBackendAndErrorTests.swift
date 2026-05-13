import XCTest
@testable import MLXtra

final class RuntimeBackendAndErrorTests: XCTestCase {


    func testRuntimeBackendRawValues() {
        XCTAssertEqual(RuntimeBackend.vlm.rawValue, "vlm")
        XCTAssertEqual(RuntimeBackend.llm.rawValue, "llm")
        XCTAssertEqual(RuntimeBackend.audio.rawValue, "audio")
        XCTAssertEqual(RuntimeBackend.image.rawValue, "image")
        XCTAssertEqual(RuntimeBackend.music.rawValue, "music")
    }

    func testRuntimeBackendDisplayName() {
        XCTAssertEqual(RuntimeBackend.vlm.displayName, "Vision Language Model")
        XCTAssertEqual(RuntimeBackend.llm.displayName, "Text Language Model")
        XCTAssertEqual(RuntimeBackend.audio.displayName, "Audio Processing")
        XCTAssertEqual(RuntimeBackend.image.displayName, "Image Generation")
        XCTAssertEqual(RuntimeBackend.music.displayName, "Music Generation")
    }

    func testRuntimeBackendCaseIterable() {
        let allCases = RuntimeBackend.allCases
        XCTAssertEqual(allCases.count, 5)
        XCTAssertTrue(allCases.contains(.vlm))
        XCTAssertTrue(allCases.contains(.llm))
        XCTAssertTrue(allCases.contains(.audio))
        XCTAssertTrue(allCases.contains(.image))
        XCTAssertTrue(allCases.contains(.music))
    }

    func testRuntimeBackendCodable() throws {
        let backend: RuntimeBackend = .music
        let data = try JSONEncoder().encode(backend)
        let decoded = try JSONDecoder().decode(RuntimeBackend.self, from: data)
        XCTAssertEqual(decoded, backend)
    }


    func testExecutionErrorLocalizedDescriptions() {
        XCTAssertEqual(ExecutionError.notInitialized.localizedDescription, "Executor not initialized")
        XCTAssertEqual(ExecutionError.processNotRunning.localizedDescription, "Python process not running")
        XCTAssertEqual(ExecutionError.modelNotLoaded.localizedDescription, "Model not loaded")
        XCTAssertEqual(ExecutionError.timeout.localizedDescription, "Operation timed out")
        XCTAssertEqual(ExecutionError.invalidResponse.localizedDescription, "Invalid response from Python")
        XCTAssertEqual(ExecutionError.processCrashed(retryCount: 2).localizedDescription, "Python process crashed (retry 2)")
        XCTAssertEqual(ExecutionError.encodingFailed.localizedDescription, "Failed to encode request")
        XCTAssertEqual(ExecutionError.decodingFailed.localizedDescription, "Failed to decode response")
        XCTAssertEqual(ExecutionError.requiresManualRetry(ExecutionError.timeout).localizedDescription, "Requires manual retry")
        XCTAssertEqual(ExecutionError.pythonError("test error").localizedDescription, "Python error: test error")
    }

    func testExecutionErrorProcessCrashedFormatting() {
        XCTAssertEqual(ExecutionError.processCrashed(retryCount: 0).localizedDescription, "Python process crashed (retry 0)")
        XCTAssertEqual(ExecutionError.processCrashed(retryCount: 1).localizedDescription, "Python process crashed (retry 1)")
        XCTAssertEqual(ExecutionError.processCrashed(retryCount: 99).localizedDescription, "Python process crashed (retry 99)")
    }

    func testExecutionErrorPythonErrorWithEmptyString() {
        let error = ExecutionError.pythonError("")
        XCTAssertEqual(error.localizedDescription, "Python error: ")
    }

    func testExecutionErrorPythonErrorWithMultilineString() {
        let error = ExecutionError.pythonError("Error line 1\nError line 2")
        XCTAssertTrue(error.localizedDescription.contains("Error line 1"))
        XCTAssertTrue(error.localizedDescription.contains("Error line 2"))
    }


    func testExecutionErrorIsError() {
        let error: Error = ExecutionError.timeout
        XCTAssertNotNil(error)
    }


    func testExecutionErrorsAreDifferent() {
        let error1 = ExecutionError.timeout
        let error2 = ExecutionError.processNotRunning
        let error3 = ExecutionError.pythonError("test")

        XCTAssertFalse(error1.localizedDescription == error2.localizedDescription)
        XCTAssertFalse(error1.localizedDescription == error3.localizedDescription)
    }
}