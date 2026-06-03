import XCTest
@testable import MLXtra

final class DownloadableModelTests: XCTestCase {


    func testDownloadableModelProperties() {
        let model = DownloadableModel(
            id: "test-id",
            name: "Test Model",
            subtitle: "Test subtitle",
            modelId: "org/test-model",
            modality: .vision,
            downloadSizeGB: 5.0
        )

        XCTAssertEqual(model.id, "test-id")
        XCTAssertEqual(model.name, "Test Model")
        XCTAssertEqual(model.subtitle, "Test subtitle")
        XCTAssertEqual(model.modelId, "org/test-model")
        XCTAssertEqual(model.modality, .vision)
        XCTAssertEqual(model.downloadSizeGB, 5.0)
    }

    func testDownloadableModelEquatable() {
        let model1 = DownloadableModel(
            id: "test-id",
            name: "Test Model",
            subtitle: "Test subtitle",
            modelId: "org/test-model",
            modality: .vision,
            downloadSizeGB: 5.0
        )
        let model2 = DownloadableModel(
            id: "test-id",
            name: "Test Model",
            subtitle: "Test subtitle",
            modelId: "org/test-model",
            modality: .vision,
            downloadSizeGB: 5.0
        )
        let model3 = DownloadableModel(
            id: "different-id",
            name: "Different Model",
            subtitle: "Different subtitle",
            modelId: "org/different-model",
            modality: .image,
            downloadSizeGB: 10.0
        )

        XCTAssertEqual(model1, model2)
        XCTAssertNotEqual(model1, model3)
    }


    func testEmbeddedModelsContainsVisionModels() {
        let embedded = DownloadableModel.embedded
        XCTAssertFalse(embedded.isEmpty)

        let visionModels = embedded.filter { $0.modality == .vision }
        XCTAssertGreaterThanOrEqual(visionModels.count, 3)
    }

    func testEmbeddedModelsMatchCatalogVisibleModels() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: "MLXtra/Resources/model-catalog.json"))
        let catalog = try ModelCatalogService.decodeCatalog(data: data, appVersion: nil)
        let catalogModelsById = Dictionary(uniqueKeysWithValues: catalog.profiles
            .filter(\.isCatalogVisible)
            .map { ($0.modelId, $0.downloadableModel) })
        let embeddedModelsById = Dictionary(uniqueKeysWithValues: DownloadableModel.embedded
            .map { ($0.modelId, $0) })

        XCTAssertEqual(Set(embeddedModelsById.keys), Set(catalogModelsById.keys))
        for (modelId, catalogModel) in catalogModelsById {
            let embeddedModel = try XCTUnwrap(embeddedModelsById[modelId])
            XCTAssertEqual(embeddedModel, catalogModel)
        }
    }

    func testEmbeddedModelsContainsAllModalities() {
        let embedded = DownloadableModel.embedded

        XCTAssertTrue(embedded.contains { $0.modality == .vision })
        XCTAssertTrue(embedded.contains { $0.modality == .image })
        XCTAssertTrue(embedded.contains { $0.modality == .audio })
        XCTAssertTrue(embedded.contains { $0.modality == .music })
    }

    func testFirstRunStarterModelsIncludeAllModalities() {
        let starterModels = FirstRunStarterModel.recommended()
        let modalities = Set(starterModels.map { $0.model.modality })
        let ids = starterModels.map(\.id)

        XCTAssertEqual(modalities, Set(ModelModality.allCases))
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    func testFirstRunBestChatModelUsesHardwareRecommendation() {
        let hardwareMemoryGB = 8.0
        let starterModel = FirstRunStarterModel.bestChatForThisMac(hardwareMemoryGB: hardwareMemoryGB)
        let expectedProfile = ModelCapabilityProfile.bestProfile(
            for: .vision,
            hardwareMemoryGB: hardwareMemoryGB
        )

        XCTAssertEqual(starterModel?.title, "Chat")
        XCTAssertEqual(starterModel?.badge, "Best for this Mac")
        XCTAssertEqual(starterModel?.model.modelId, expectedProfile?.modelId)
    }

    func testEmbeddedModelsHaveUniqueIds() {
        let embedded = DownloadableModel.embedded
        let ids = embedded.map { $0.id }
        let uniqueIds = Set(ids)
        XCTAssertEqual(ids.count, uniqueIds.count, "Embedded models should have unique IDs")
    }

    func testEmbeddedModelLookupByModelId() throws {
        let expectedModel = try XCTUnwrap(DownloadableModel.embedded.first)
        let model = DownloadableModel.embeddedModel(modelId: expectedModel.modelId)

        XCTAssertEqual(model, expectedModel)
    }

    func testEmbeddedModelLookupReturnsNilForUnknownModel() {
        XCTAssertNil(DownloadableModel.embeddedModel(modelId: "unknown/model"))
    }

    func testRuntimeSetupRequirementUsesModelRuntimeVersion() {
        let model = DownloadableModel(
            id: "future-model",
            name: "Future Model",
            subtitle: "Requires a newer runtime",
            modelId: "org/future-model",
            modality: .vision,
            backend: .vlm,
            downloadSizeGB: 1.0,
            runtime: ModelRuntimeRequirement(minVersion: "0.1.6", compatibilityApi: 1)
        )
        let oldRuntime = RuntimeManifest(
            runtimeVersion: "0.1.5",
            compatibilityApi: 1,
            supportedBackends: [.vlm]
        )
        let newRuntime = RuntimeManifest(
            runtimeVersion: "0.1.6",
            compatibilityApi: 1,
            supportedBackends: [.vlm]
        )

        XCTAssertTrue(model.requiresRuntimeSetupBeforeDownload(manifest: oldRuntime))
        XCTAssertFalse(model.requiresRuntimeSetupBeforeDownload(manifest: newRuntime))
    }

    func testRuntimeSetupRequirementUsesCompatibilityApiAndBackend() {
        let model = DownloadableModel(
            id: "vlm-model",
            name: "VLM Model",
            subtitle: "Requires VLM backend",
            modelId: "org/vlm-model",
            modality: .vision,
            backend: .vlm,
            downloadSizeGB: 1.0,
            runtime: ModelRuntimeRequirement(minVersion: "0.1.6", compatibilityApi: 1)
        )
        let wrongAPIRuntime = RuntimeManifest(
            runtimeVersion: "0.1.6",
            compatibilityApi: 2,
            supportedBackends: [.vlm]
        )
        let wrongBackendRuntime = RuntimeManifest(
            runtimeVersion: "0.1.6",
            compatibilityApi: 1,
            supportedBackends: [.image]
        )

        XCTAssertTrue(model.requiresRuntimeSetupBeforeDownload(manifest: wrongAPIRuntime))
        XCTAssertTrue(model.requiresRuntimeSetupBeforeDownload(manifest: wrongBackendRuntime))
    }

    func testDownloadableModelIdentifiable() {
        let model = DownloadableModel(
            id: "unique-id",
            name: "Test",
            subtitle: "Test",
            modelId: "test/model",
            modality: .vision,
            downloadSizeGB: 1.0
        )
        XCTAssertEqual(model.id, "unique-id")
    }
}


final class ModelModalityTests: XCTestCase {

    func testModelModalityAllCases() {
        let allCases = ModelModality.allCases
        XCTAssertEqual(allCases.count, 4)
        XCTAssertTrue(allCases.contains(.vision))
        XCTAssertTrue(allCases.contains(.image))
        XCTAssertTrue(allCases.contains(.audio))
        XCTAssertTrue(allCases.contains(.music))
    }

    func testModelModalityRawValues() {
        XCTAssertEqual(ModelModality.vision.rawValue, "Vision")
        XCTAssertEqual(ModelModality.image.rawValue, "Image")
        XCTAssertEqual(ModelModality.audio.rawValue, "Audio")
        XCTAssertEqual(ModelModality.music.rawValue, "Music")
    }

    func testModelModalityId() {
        XCTAssertEqual(ModelModality.vision.id, "Vision")
        XCTAssertEqual(ModelModality.image.id, "Image")
        XCTAssertEqual(ModelModality.audio.id, "Audio")
        XCTAssertEqual(ModelModality.music.id, "Music")
    }

    func testModelModalityIcons() {
        XCTAssertEqual(ModelModality.vision.icon, "eye")
        XCTAssertEqual(ModelModality.image.icon, "photo")
        XCTAssertEqual(ModelModality.audio.icon, "waveform")
        XCTAssertEqual(ModelModality.music.icon, "music.note")
    }
}
