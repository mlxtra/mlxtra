import XCTest
@testable import MLXHub

final class AIModelTests: XCTestCase {

    // MARK: - AIModel Cases

    func testAIModelAllCases() {
        let allCases = AIModel.allCases
        XCTAssertEqual(allCases.count, 3)
        XCTAssertTrue(allCases.contains(.qwen35))
        XCTAssertTrue(allCases.contains(.gemma4))
        XCTAssertTrue(allCases.contains(.mini))
    }

    func testAIModelRawValues() {
        XCTAssertEqual(AIModel.qwen35.rawValue, "Qwen 3.5")
        XCTAssertEqual(AIModel.gemma4.rawValue, "Gemma 4")
        XCTAssertEqual(AIModel.mini.rawValue, "Qwen 3.5 Mini")
    }

    // MARK: - ID and Display Name

    func testAIModelId() {
        XCTAssertEqual(AIModel.qwen35.id, "Qwen 3.5")
        XCTAssertEqual(AIModel.gemma4.id, "Gemma 4")
        XCTAssertEqual(AIModel.mini.id, "Qwen 3.5 Mini")
    }

    func testAIModelDisplayName() {
        XCTAssertEqual(AIModel.qwen35.displayName, "Qwen 3.5")
        XCTAssertEqual(AIModel.gemma4.displayName, "Gemma 4")
        XCTAssertEqual(AIModel.mini.displayName, "Qwen 3.5 Mini")
    }

    func testAIModelSubtitle() {
        XCTAssertEqual(AIModel.qwen35.subtitle, "Vision language model (9B parameters)")
        XCTAssertEqual(AIModel.gemma4.subtitle, "Google vision model (4B parameters)")
        XCTAssertEqual(AIModel.mini.subtitle, "Lightweight vision model (2B parameters)")
    }

    // MARK: - Model ID (HuggingFace)

    func testAIModelModelId() {
        XCTAssertEqual(AIModel.qwen35.modelId, "mlx-community/Qwen3.5-9B-MLX-4bit")
        XCTAssertEqual(AIModel.gemma4.modelId, "google/gemma-4-e4b-it")
        XCTAssertEqual(AIModel.mini.modelId, "mlx-community/Qwen3.5-2B-MLX-4bit")
    }

    // MARK: - Context Window

    func testAIModelMaxContextWindow() {
        XCTAssertEqual(AIModel.qwen35.maxContextWindow, 32768)
        XCTAssertEqual(AIModel.gemma4.maxContextWindow, 8192)
        XCTAssertEqual(AIModel.mini.maxContextWindow, 32768)
    }

    // MARK: - Default Max Tokens

    func testAIModelDefaultMaxTokens() {
        XCTAssertEqual(AIModel.qwen35.defaultMaxTokens, 4096)
        XCTAssertEqual(AIModel.gemma4.defaultMaxTokens, 4096)
        XCTAssertEqual(AIModel.mini.defaultMaxTokens, 4096)
    }

    // MARK: - Memory Requirement

    func testAIModelMemoryRequirementGB() {
        XCTAssertEqual(AIModel.qwen35.memoryRequirementGB, 6.0)
        XCTAssertEqual(AIModel.gemma4.memoryRequirementGB, 3.0)
        XCTAssertEqual(AIModel.mini.memoryRequirementGB, 3.0)
    }

    // MARK: - Download Size

    func testAIModelDownloadSizeGB() {
        XCTAssertEqual(AIModel.qwen35.downloadSizeGB, 5.6)
        XCTAssertEqual(AIModel.gemma4.downloadSizeGB, 2.5)
        XCTAssertEqual(AIModel.mini.downloadSizeGB, 1.5)
    }

    // MARK: - Vision Support

    func testAIModelSupportsVision() {
        XCTAssertTrue(AIModel.qwen35.supportsVision)
        XCTAssertTrue(AIModel.gemma4.supportsVision)
        XCTAssertTrue(AIModel.mini.supportsVision)
    }

    // MARK: - Temperature Range

    func testAIModelTemperatureRange() {
        let qwenRange = AIModel.qwen35.temperatureRange
        XCTAssertEqual(qwenRange.min, 0.0)
        XCTAssertEqual(qwenRange.max, 2.0)
        XCTAssertEqual(qwenRange.default, 0.7)

        let gemmaRange = AIModel.gemma4.temperatureRange
        XCTAssertEqual(gemmaRange.min, 0.0)
        XCTAssertEqual(gemmaRange.max, 2.0)
        XCTAssertEqual(gemmaRange.default, 0.7)
    }

    // MARK: - Sampling Parameters

    func testAIModelTopP() {
        XCTAssertEqual(AIModel.qwen35.topP, 0.8)
        XCTAssertEqual(AIModel.gemma4.topP, 1.0)
        XCTAssertEqual(AIModel.mini.topP, 0.8)
    }

    func testAIModelTopK() {
        XCTAssertEqual(AIModel.qwen35.topK, 20)
        XCTAssertEqual(AIModel.gemma4.topK, 0)
        XCTAssertEqual(AIModel.mini.topK, 20)
    }

    func testAIModelMinP() {
        XCTAssertEqual(AIModel.qwen35.minP, 0.0)
        XCTAssertEqual(AIModel.gemma4.minP, 0.0)
        XCTAssertEqual(AIModel.mini.minP, 0.0)
    }

    func testAIModelRepetitionPenalty() {
        XCTAssertEqual(AIModel.qwen35.repetitionPenalty, 1.0)
        XCTAssertEqual(AIModel.gemma4.repetitionPenalty, 1.0)
        XCTAssertEqual(AIModel.mini.repetitionPenalty, 1.0)
    }

    // MARK: - Thinking

    func testAIModelEnableThinking() {
        XCTAssertFalse(AIModel.qwen35.enableThinking)
        XCTAssertFalse(AIModel.gemma4.enableThinking)
        XCTAssertFalse(AIModel.mini.enableThinking)
    }

    // MARK: - Backend

    func testAIModelBackend() {
        XCTAssertEqual(AIModel.qwen35.backend, .vlm)
        XCTAssertEqual(AIModel.gemma4.backend, .vlm)
        XCTAssertEqual(AIModel.mini.backend, .vlm)
    }

    // MARK: - Icon

    func testAIModelIcon() {
        XCTAssertEqual(AIModel.qwen35.icon, "eye")
        XCTAssertEqual(AIModel.gemma4.icon, "sparkles")
        XCTAssertEqual(AIModel.mini.icon, "bolt")
    }

    // MARK: - Model Info

    func testAIModelInfo() {
        let info = AIModel.qwen35.info
        XCTAssertEqual(info.name, "Qwen 3.5")
        XCTAssertEqual(info.modelId, "mlx-community/Qwen3.5-9B-MLX-4bit")
        XCTAssertEqual(info.contextWindow, 32768)
        XCTAssertEqual(info.memoryRequired, 6.0)
        XCTAssertEqual(info.downloadSize, 5.6)
        XCTAssertTrue(info.supportsVision)
    }

    // MARK: - Hardware Recommendations

    func testBestModelsForLowMemoryHardwareUsesMiniFallback() {
        XCTAssertEqual(AIModel.bestModelsForHardware(memoryGB: 4.0), [.mini])
    }

    func testBestModelsForEightGBHardwareAvoidsLargestModel() {
        XCTAssertEqual(AIModel.bestModelsForHardware(memoryGB: 8.0), [.gemma4, .mini])
    }

    func testBestModelsForSixteenGBHardwareIncludesLargestModel() {
        XCTAssertEqual(AIModel.bestModelsForHardware(memoryGB: 16.0), [.qwen35, .gemma4, .mini])
    }
}
