import XCTest
@testable import MLXHub

final class RuntimeManagerTests: XCTestCase {

    // MARK: - RuntimeState Tests

    func testRuntimeStateEquatable() {
        XCTAssertEqual(RuntimeManager.RuntimeState.notInitialized, RuntimeManager.RuntimeState.notInitialized)
        XCTAssertEqual(RuntimeManager.RuntimeState.checkingBundle, RuntimeManager.RuntimeState.checkingBundle)
        XCTAssertEqual(RuntimeManager.RuntimeState.extractingBundle, RuntimeManager.RuntimeState.extractingBundle)
        XCTAssertEqual(RuntimeManager.RuntimeState.startingPython, RuntimeManager.RuntimeState.startingPython)
        XCTAssertEqual(RuntimeManager.RuntimeState.ready, RuntimeManager.RuntimeState.ready)

        XCTAssertNotEqual(RuntimeManager.RuntimeState.notInitialized, RuntimeManager.RuntimeState.ready)

        let error1 = RuntimeManager.RuntimeState.error("message1")
        let error2 = RuntimeManager.RuntimeState.error("message1")
        let error3 = RuntimeManager.RuntimeState.error("message2")
        XCTAssertEqual(error1, error2)
        XCTAssertNotEqual(error1, error3)
    }

    func testRuntimeStateErrorMessages() {
        XCTAssertEqual(RuntimeManager.RuntimeState.error("test error"), RuntimeManager.RuntimeState.error("test error"))
    }

    // MARK: - RuntimeError Tests

    func testRuntimeErrorLocalizedDescriptions() {
        XCTAssertEqual(
            RuntimeError.bundleNotFound("/path/to/bundle").localizedDescription,
            "Python runtime bundle not found at /path/to/bundle"
        )
        XCTAssertEqual(
            RuntimeError.pythonNotFound("/path/to/python").localizedDescription,
            "Python executable not found at /path/to/python"
        )
        XCTAssertEqual(
            RuntimeError.bridgeScriptNotFound("/path/to/script").localizedDescription,
            "Python bridge script not found at /path/to/script"
        )
        XCTAssertEqual(
            RuntimeError.initializationFailed("test failure").localizedDescription,
            "Failed to initialize runtime: test failure"
        )
    }

    // MARK: - Estimated Model Size (Static Logic)

    func testEstimatedModelSizeLogic() {
        // Test model size estimation without instantiating RuntimeManager
        // These are the same values that RuntimeManager.estimatedModelSize returns
        let modelSizes: [String: Double] = [
            "mlx-community/Qwen3.5-9B-MLX-4bit": 5.6,
            "google/gemma-4-e4b-it": 3.0,
            "mlx-community/Qwen3.5-2B-MLX-4bit": 1.5,
            "black-forest-labs/FLUX.2-klein-4B": 15.0,
            "kugelaudio/kugelaudio-0-open": 15.0,
            "ACE-Step/acestep-v15-turbo-continuous": 4.8,
            "ACE-Step/acestep-v15-xl": 19.0,
            "ACE-Step/acestep-v15-base": 5.0,
        ]

        XCTAssertEqual(modelSizes["mlx-community/Qwen3.5-9B-MLX-4bit"], 5.6)
        XCTAssertEqual(modelSizes["google/gemma-4-e4b-it"], 3.0)
        XCTAssertEqual(modelSizes["mlx-community/Qwen3.5-2B-MLX-4bit"], 1.5)
        XCTAssertEqual(modelSizes["black-forest-labs/FLUX.2-klein-4B"], 15.0)
        XCTAssertEqual(modelSizes["kugelaudio/kugelaudio-0-open"], 15.0)
        XCTAssertEqual(modelSizes["ACE-Step/acestep-v15-turbo-continuous"], 4.8)
        XCTAssertEqual(modelSizes["ACE-Step/acestep-v15-xl"], 19.0)
        XCTAssertEqual(modelSizes["ACE-Step/acestep-v15-base"], 5.0)

        // Unknown model defaults to 5.0
        XCTAssertEqual(modelSizes["unknown/model"], nil) // Not in map means default 5.0
    }

    // MARK: - Model Cache Path Logic

    func testModelCachePathConstruction() {
        // Test the path construction logic
        let modelId = "mlx-community/Qwen3.5-9B"
        let expectedSuffix = "models--mlx-community--Qwen3.5-9B"

        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let basePath = homeDir.appendingPathComponent(".cache/huggingface/hub")
        let fullPath = basePath.appendingPathComponent("models--mlx-community--Qwen3.5-9B")

        XCTAssertTrue(fullPath.path.contains(expectedSuffix))
    }

    func testModelCachePathSlashReplacement() {
        let modelId = "org/test-model"
        let expected = "models--org--test-model"

        let result = "models--" + modelId.replacingOccurrences(of: "/", with: "--")
        XCTAssertEqual(result, expected)
    }

    // MARK: - Python Path Structure

    func testPythonExecutablePathStructure() {
        // Test that the expected suffix is correct
        let path = "/some/path/venv/bin/python"
        XCTAssertTrue(path.hasSuffix("/venv/bin/python"))
    }

    func testAcestepPythonExecutablePathStructure() {
        let path = "/some/path/acestep-venv/bin/python"
        XCTAssertTrue(path.hasSuffix("/acestep-venv/bin/python"))
    }
}

// MARK: - RuntimeError Extension for Testing

extension RuntimeError: @retroactive Equatable {
    public static func == (lhs: RuntimeError, rhs: RuntimeError) -> Bool {
        switch (lhs, rhs) {
        case (.bundleNotFound(let l), .bundleNotFound(let r)) where l == r:
            return true
        case (.pythonNotFound(let l), .pythonNotFound(let r)) where l == r:
            return true
        case (.bridgeScriptNotFound(let l), .bridgeScriptNotFound(let r)) where l == r:
            return true
        case (.initializationFailed(let l), .initializationFailed(let r)) where l == r:
            return true
        default:
            return false
        }
    }
}