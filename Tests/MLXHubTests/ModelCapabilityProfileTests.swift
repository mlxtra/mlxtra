import XCTest
@testable import MLXHub

final class ModelCapabilityProfileTests: XCTestCase {
    func testHardwareRankingForLowMediumAndHighMemoryMachines() {
        XCTAssertEqual(ModelCapabilityProfile.bestProfile(for: .vision, hardwareMemoryGB: 4.0)?.aiModel, .mini)
        XCTAssertEqual(ModelCapabilityProfile.bestProfile(for: .vision, hardwareMemoryGB: 8.0)?.aiModel, .gemma4)
        XCTAssertEqual(ModelCapabilityProfile.bestProfile(for: .vision, hardwareMemoryGB: 16.0)?.aiModel, .qwen35)

        XCTAssertEqual(ModelFit.classify(estimatedMemoryGB: 3.0, hardwareMemoryGB: 4.0), .compatible)
        XCTAssertEqual(ModelFit.classify(estimatedMemoryGB: 6.0, hardwareMemoryGB: 8.0), .compatible)
        XCTAssertEqual(ModelFit.classify(estimatedMemoryGB: 8.0, hardwareMemoryGB: 8.0), .heavy)
        XCTAssertEqual(ModelFit.classify(estimatedMemoryGB: nil, hardwareMemoryGB: 16.0), .unknown)
    }

    func testPerModeSelectionUsesRememberedModelThenRecommendedDefault() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let store = ModelSelectionStore(userDefaults: defaults)

        XCTAssertEqual(store.selectedProfile(for: .vision, hardwareMemoryGB: 16.0)?.aiModel, .qwen35)
        XCTAssertEqual(store.selectedProfile(for: .image, hardwareMemoryGB: 16.0)?.modelId, "black-forest-labs/FLUX.2-klein-4B")

        store.setSelectedModelId(AIModel.gemma4.modelId, for: .vision)
        XCTAssertEqual(store.selectedProfile(for: .vision, hardwareMemoryGB: 16.0)?.aiModel, .gemma4)
    }

    func testPerModeSelectionFallsBackWhenRememberedModelIsInvalidForMode() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let store = ModelSelectionStore(userDefaults: defaults)
        store.setSelectedModelId(AIModel.qwen35.modelId, for: .image)

        XCTAssertEqual(store.selectedProfile(for: .image, hardwareMemoryGB: 16.0)?.modelId, "black-forest-labs/FLUX.2-klein-4B")
    }

    func testParameterPersistenceIsPerModelAndRestoredAfterSwapping() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let store = ModelParameterStore(userDefaults: defaults)
        let qwen = ModelCapabilityProfile.embeddedProfile(modelId: AIModel.qwen35.modelId)!
        let gemma = ModelCapabilityProfile.embeddedProfile(modelId: AIModel.gemma4.modelId)!

        store.setValue("0.2", for: "temperature", modelId: qwen.modelId)

        XCTAssertEqual(store.values(for: qwen)["temperature"], "0.2")
        XCTAssertEqual(store.values(for: gemma)["temperature"], "0.7")
        XCTAssertEqual(store.executionParameters(for: qwen)["temperature"] as? Double, 0.2)
    }

    func testUnsupportedParameterValuesAreIgnoredButNotDeleted() throws {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let qwen = ModelCapabilityProfile.embeddedProfile(modelId: AIModel.qwen35.modelId)!
        let encoded = try JSONEncoder().encode([
            qwen.modelId: [
                "temperature": "0.4",
                "future_parameter": "keep"
            ]
        ])
        defaults.set(encoded, forKey: ModelParameterStore.storageKey)

        let store = ModelParameterStore(userDefaults: defaults)
        let values = store.values(for: qwen)

        XCTAssertEqual(values["temperature"], "0.4")
        XCTAssertNil(values["future_parameter"])
        XCTAssertEqual(store.storedValues()[qwen.modelId]?["future_parameter"], "keep")
    }

    private var defaultsSuiteName: String {
        "MLXHubTests.ModelCapabilityProfileTests"
    }

    private func makeDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: defaultsSuiteName)!
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        return defaults
    }
}
