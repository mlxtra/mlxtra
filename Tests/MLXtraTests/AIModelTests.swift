import XCTest
@testable import MLXtra

final class AIModelTests: XCTestCase {
    private struct ExpectedModelConfiguration {
        let rawValue: String
        let subtitle: String
        let modelId: String
        let maxContextWindow: Int
        let defaultMaxTokens: Int
        let memoryRequirementGB: Double
        let downloadSizeGB: Double
        let supportsVision: Bool
        let temperatureRange: (min: Double, max: Double, default: Double)
        let topP: Double
        let topK: Int
        let minP: Double
        let repetitionPenalty: Double
        let enableThinking: Bool
        let backend: RuntimeBackend
        let icon: String
    }

    private var expectedBuiltInModels: [(model: AIModel, configuration: ExpectedModelConfiguration)] {
        [
            (
                model: .qwen35,
                configuration: ExpectedModelConfiguration(
                    rawValue: "Qwen 3.5",
                    subtitle: "Vision language model (9B parameters)",
                    modelId: "mlx-community/Qwen3.5-9B-MLX-4bit",
                    maxContextWindow: 32768,
                    defaultMaxTokens: 4096,
                    memoryRequirementGB: 6.0,
                    downloadSizeGB: 5.6,
                    supportsVision: true,
                    temperatureRange: (0.0, 2.0, 0.7),
                    topP: 0.8,
                    topK: 20,
                    minP: 0.0,
                    repetitionPenalty: 1.0,
                    enableThinking: false,
                    backend: .vlm,
                    icon: "eye"
                )
            ),
            (
                model: .gemma4,
                configuration: ExpectedModelConfiguration(
                    rawValue: "Gemma 4",
                    subtitle: "Google vision model (4B parameters)",
                    modelId: "google/gemma-4-e4b-it",
                    maxContextWindow: 8192,
                    defaultMaxTokens: 4096,
                    memoryRequirementGB: 3.0,
                    downloadSizeGB: 2.5,
                    supportsVision: true,
                    temperatureRange: (0.0, 2.0, 0.7),
                    topP: 1.0,
                    topK: 0,
                    minP: 0.0,
                    repetitionPenalty: 1.0,
                    enableThinking: false,
                    backend: .vlm,
                    icon: "sparkles"
                )
            ),
            (
                model: .mini,
                configuration: ExpectedModelConfiguration(
                    rawValue: "Qwen 3.5 Mini",
                    subtitle: "Lightweight vision model (2B parameters)",
                    modelId: "mlx-community/Qwen3.5-2B-MLX-4bit",
                    maxContextWindow: 32768,
                    defaultMaxTokens: 4096,
                    memoryRequirementGB: 3.0,
                    downloadSizeGB: 1.5,
                    supportsVision: true,
                    temperatureRange: (0.0, 2.0, 0.7),
                    topP: 0.8,
                    topK: 20,
                    minP: 0.0,
                    repetitionPenalty: 1.0,
                    enableThinking: false,
                    backend: .vlm,
                    icon: "bolt"
                )
            ),
        ]
    }

    // MARK: - AIModel Cases

    func testAIModelAllCases() {
        XCTAssertEqual(AIModel.allCases, expectedBuiltInModels.map(\.model))
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

    func testBuiltInModelConfigurationRemainsStable() {
        for (model, configuration) in expectedBuiltInModels {
            XCTAssertEqual(model.rawValue, configuration.rawValue)
            XCTAssertEqual(model.id, configuration.rawValue)
            XCTAssertEqual(model.displayName, configuration.rawValue)
            XCTAssertEqual(model.subtitle, configuration.subtitle)
            XCTAssertEqual(model.modelId, configuration.modelId)
            XCTAssertEqual(model.maxContextWindow, configuration.maxContextWindow)
            XCTAssertEqual(model.defaultMaxTokens, configuration.defaultMaxTokens)
            XCTAssertEqual(model.memoryRequirementGB, configuration.memoryRequirementGB)
            XCTAssertEqual(model.downloadSizeGB, configuration.downloadSizeGB)
            XCTAssertEqual(model.supportsVision, configuration.supportsVision)
            XCTAssertEqual(model.temperatureRange.min, configuration.temperatureRange.min)
            XCTAssertEqual(model.temperatureRange.max, configuration.temperatureRange.max)
            XCTAssertEqual(model.temperatureRange.default, configuration.temperatureRange.default)
            XCTAssertEqual(model.topP, configuration.topP)
            XCTAssertEqual(model.topK, configuration.topK)
            XCTAssertEqual(model.minP, configuration.minP)
            XCTAssertEqual(model.repetitionPenalty, configuration.repetitionPenalty)
            XCTAssertEqual(model.enableThinking, configuration.enableThinking)
            XCTAssertEqual(model.backend, configuration.backend)
            XCTAssertEqual(model.icon, configuration.icon)
        }
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
        for (model, configuration) in expectedBuiltInModels {
            let info = model.info
            XCTAssertEqual(info.name, configuration.rawValue)
            XCTAssertEqual(info.modelId, configuration.modelId)
            XCTAssertEqual(info.contextWindow, configuration.maxContextWindow)
            XCTAssertEqual(info.memoryRequired, configuration.memoryRequirementGB)
            XCTAssertEqual(info.downloadSize, configuration.downloadSizeGB)
            XCTAssertEqual(info.supportsVision, configuration.supportsVision)
        }
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
